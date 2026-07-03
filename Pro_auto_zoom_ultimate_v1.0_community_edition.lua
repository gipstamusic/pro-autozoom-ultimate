git-- ==============================================================================
-- PRO AUTOZOOM (ULTIMATE COMMUNITY EDITION) - v1.0.0
-- Cinematic mouse-tracking zoom engine for OBS Studio (Windows)
-- Developed by: Gipstamusic
-- Website: https://lnk.bio/gipstamusic
-- Github: https://github.com/gipstamusic/pro-autozoom-ultimate
-- License: MIT (see LICENSE)
-- Compatibility: OBS 29.x & OBS 30+ Universal Layer (Windows)
-- ==============================================================================

local obs = obslua
local ffi = require("ffi")

-- Single source of truth for the version. Shown in script_description() so the
-- running version is visible in-app and easy to quote in bug reports. Keep this
-- in sync with the CHANGELOG and any release tag.
local SCRIPT_VERSION = "1.0.0"

ffi.cdef[[
    typedef struct { long x; long y; } POINT;
    int GetCursorPos(POINT* lpPoint);
    typedef long LONG;
    typedef struct { LONG left; LONG top; LONG right; LONG bottom; } RECT;
    typedef struct { unsigned long cbSize; RECT rcMonitor; RECT rcWork; unsigned long dwFlags; wchar_t szDevice[32]; } MONITORINFOEXW;
    void* MonitorFromPoint(POINT pt, unsigned long dwFlags);
    int GetMonitorInfoW(void* hMonitor, MONITORINFOEXW* lpmi);

    // dwData is LPARAM, which is pointer-sized (8 bytes on x64 Windows) - using
    // intptr_t here (not "long", which stays 32-bit under Windows' LLP64 model)
    // is required for the callback ABI to marshal correctly.
    typedef int (*MONITORENUMPROC)(void* hMonitor, void* hdcMonitor, RECT* lprcMonitor, intptr_t dwData);
    int EnumDisplayMonitors(void* hdc, RECT* lprcClip, MONITORENUMPROC lpfnEnum, intptr_t dwData);
]]

-- ------------------------------------------------------------------------------
-- Global State & Cache
-- ------------------------------------------------------------------------------
local cache = {
    source_name       = "",
    mon_w             = 1920,
    mon_h             = 1080,
    mon_x_offset      = 0,
    mon_y_offset      = 0,
    manual_hw_override= false,
    layout_style      = "full",

    -- Output canvas geometry. OBS's obs_get_video_info() only reports the MAIN
    -- (usually horizontal) canvas base resolution. Multi-canvas plugins like
    -- Aitum Vertical render to a SEPARATE canvas that this API does not expose,
    -- so reading video info gave the wrong dimensions (e.g. 1920x1080 instead
    -- of 1080x1920) and the crop aspect came out ~4:1 instead of the intended
    -- portrait ratio - the "squash". These explicit fields are the target the
    -- crop aspect is locked to. Set them to your vertical canvas size.
    out_canvas_w      = 1080,
    out_canvas_h      = 1920,
    webcam_h          = 0,   -- webcam strip height; only used by split layouts
    manual_canvas_override = false,

    -- Picked monitor (Windows EnumDisplayMonitors picker) - sits between
    -- manual override and auto-detect in priority. See get_active_monitor_geometry.
    has_picked_monitor= false,
    picked_mon_w      = 0,
    picked_mon_h      = 0,
    picked_mon_x      = 0,
    picked_mon_y      = 0,

    -- Camera Engine
    zoom_enabled      = true,
    base_zoom         = 2.0,
    punch_zoom        = 4.0,
    tracking_speed    = 0.12,
    deadzone          = 15,
    auto_center       = false,
    auto_center_delay = 3.0,
    debug_mode        = false,

    -- Indicator
    ind_mode    = "Off",
    ind_color   = 16776960,
    ind_opacity = 70,
    ind_size    = 72
}

-- Runtime state
local cur_crop    = { left = 0, top = 0, right = 0, bottom = 0 }
local target_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local last_cam    = { x = 960, y = 540 }
local cur_zoom    = 1.0

local last_mouse_time = os.clock()
local last_debug_time = os.clock() -- Used to throttle tick logs

-- Hotkey handles & states
local hk_zoom_id, hk_ind_id, hk_punch_id, hk_pause_id
local zoom_active        = false
local internal_ind_active = true
local is_punch_active    = false
local is_pause_active    = false
local last_source_name   = ""

-- Captured every script_update() call - the reset buttons write into this
-- rather than trusting a "settings" argument from the button callback itself.
-- OBS's Lua button callbacks only pass (properties, property), no settings;
-- obs_data_set_* on a missing/nil third arg silently no-ops instead of
-- erroring, which is why writes made straight to a callback-local settings
-- variable never showed up in the UI.
local live_settings = nil

-- ------------------------------------------------------------------------------
-- Debug helper
-- ------------------------------------------------------------------------------
local function debug_log(msg, throttle)
    if cache.debug_mode then
        if throttle then
            local now = os.clock()
            if now - last_debug_time > 1.0 then 
                obs.script_log(obs.LOG_INFO, "ProAutoZoom [TICK]: " .. tostring(msg))
                last_debug_time = now
            end
        else
            obs.script_log(obs.LOG_INFO, "ProAutoZoom: " .. tostring(msg))
        end
    end
end

-- Same gating as debug_log, but at LOG_WARNING severity for things that are
-- worth calling out specifically (e.g. "tracking can't start"). Writes
-- nothing at all when Debug Mode is off, by design - the script should be
-- silent unless the user asked for diagnostics.
local function debug_warn(msg)
    if cache.debug_mode then
        obs.script_log(obs.LOG_WARNING, "ProAutoZoom: " .. tostring(msg))
    end
end

-- ------------------------------------------------------------------------------
-- Windows monitor helpers
-- ------------------------------------------------------------------------------

-- Enumerates every physical monitor via the Win32 API (ground truth - no
-- guessing from OBS source settings). Returns an array of
-- { x, y, w, h, primary } tables, primary-first. Fails safe: any problem
-- creating/running the enumeration callback returns an empty list rather
-- than raising, so a bad environment degrades to "picker just has no
-- entries" instead of breaking script_properties() entirely.
local function enumerate_monitors()
    local monitors = {}

    local function enum_proc(hMonitor, hdcMonitor, lprcMonitor, dwData)
        local mi = ffi.new("MONITORINFOEXW")
        mi.cbSize = ffi.sizeof("MONITORINFOEXW")
        if ffi.C.GetMonitorInfoW(hMonitor, mi) ~= 0 then
            local mx = tonumber(mi.rcMonitor.left)
            local my = tonumber(mi.rcMonitor.top)
            local mw = tonumber(mi.rcMonitor.right  - mi.rcMonitor.left)
            local mh = tonumber(mi.rcMonitor.bottom - mi.rcMonitor.top)
            local is_primary = (tonumber(mi.dwFlags) % 2 == 1) -- MONITORINFOF_PRIMARY = 0x1
            if mw > 0 and mh > 0 then
                table.insert(monitors, { x = mx, y = my, w = mw, h = mh, primary = is_primary })
            end
        end
        return 1 -- BOOL TRUE: keep enumerating
    end

    local cast_ok, cb = pcall(ffi.cast, "MONITORENUMPROC", enum_proc)
    if not cast_ok or not cb then
        debug_log("enumerate_monitors: Could not create Windows callback; picker will be empty.")
        return {}
    end

    local call_ok = pcall(ffi.C.EnumDisplayMonitors, nil, nil, cb, 0)
    cb:free() -- always release the callback slot, whether the call succeeded or not

    if not call_ok then
        debug_log("enumerate_monitors: EnumDisplayMonitors call failed; picker will be empty.")
        return {}
    end

    table.sort(monitors, function(a, b)
        if a.primary ~= b.primary then return a.primary end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)

    debug_log("enumerate_monitors: Found " .. #monitors .. " monitor(s).")
    return monitors
end

-- Single source of truth for "what are the active monitor dimensions/offset
-- right now", in priority order: Manual Override > Picked Monitor (Windows
-- picker) > last-resort cache defaults (only used before the user has
-- configured either). Auto-detecting geometry from the capture source was
-- removed - it silently produced wrong dimensions on multi-monitor setups
-- (e.g. reading a filtered/scaled source size instead of the real monitor
-- resolution), so the user must explicitly pick their monitor above instead.
local function get_active_monitor_geometry()
    if cache.manual_hw_override then
        return cache.mon_w, cache.mon_h, cache.mon_x_offset, cache.mon_y_offset, "manual"
    elseif cache.has_picked_monitor then
        return cache.picked_mon_w, cache.picked_mon_h, cache.picked_mon_x, cache.picked_mon_y, "picked"
    else
        return cache.mon_w, cache.mon_h, cache.mon_x_offset, cache.mon_y_offset, "default"
    end
end

-- ------------------------------------------------------------------------------
-- GUI Callbacks
-- ------------------------------------------------------------------------------
local function toggle_hw_visibility(props, property, settings)
    local is_manual = obs.obs_data_get_bool(settings, "manual_hw_override")
    
    local p_w = obs.obs_properties_get(props, "mon_w")
    local p_h = obs.obs_properties_get(props, "mon_h")
    local p_x = obs.obs_properties_get(props, "mon_x_offset")
    local p_y = obs.obs_properties_get(props, "mon_y_offset")
    
    obs.obs_property_set_visible(p_w, is_manual)
    obs.obs_property_set_visible(p_h, is_manual)
    obs.obs_property_set_visible(p_x, is_manual)
    obs.obs_property_set_visible(p_y, is_manual)
    
    debug_log("UI: Manual Monitor Override toggled to: " .. tostring(is_manual))
    return true
end

-- Shows/hides the two vertical-canvas SIZE fields based on the manual-canvas
-- toggle, mirroring toggle_hw_visibility above. When the override is off the
-- script auto-reads the canvas from OBS; when on, the user sets exact
-- dimensions to match a separate output canvas (e.g. Aitum Vertical).
local function toggle_canvas_visibility(props, property, settings)
    local is_manual = obs.obs_data_get_bool(settings, "manual_canvas_override")

    local p_cw = obs.obs_properties_get(props, "out_canvas_w")
    local p_ch = obs.obs_properties_get(props, "out_canvas_h")

    obs.obs_property_set_visible(p_cw, is_manual)
    obs.obs_property_set_visible(p_ch, is_manual)

    debug_log("UI: Manual Canvas Override toggled to: " .. tostring(is_manual))
    return true
end

-- Shows/hides the Webcam Height field based on the selected Canvas Layout.
-- Webcam height only applies to the split layouts (webcam_top / webcam_bottom);
-- for full-screen / ultrawide / pip it's irrelevant, so it's hidden to avoid
-- implying it does something it doesn't. This ties the field to the layout
-- concept rather than leaving it floating as a parallel setting.
local function toggle_layout_visibility(props, property, settings)
    local style = obs.obs_data_get_string(settings, "layout_style")
    local split = (style == "webcam_top" or style == "webcam_bottom")

    obs.obs_property_set_visible(obs.obs_properties_get(props, "webcam_h"), split)

    debug_log("UI: Canvas Layout set to '" .. style .. "' (webcam field visible: " .. tostring(split) .. ")")
    return true
end

-- Shows/hides the Mouse Indicator styling fields (color/opacity/size) based on
-- whether the indicator is enabled. When Visibility is "Off" those three fields
-- do nothing, so hiding them keeps the panel consistent with how the monitor
-- and canvas overrides already behave - no dead controls on screen.
local function toggle_indicator_visibility(props, property, settings)
    local mode = obs.obs_data_get_string(settings, "ind_mode")
    local on = (mode ~= "Off")

    obs.obs_property_set_visible(obs.obs_properties_get(props, "ind_color"),   on)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "ind_opacity"), on)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "ind_size"),    on)

    debug_log("UI: Mouse Indicator mode '" .. mode .. "' (style fields visible: " .. tostring(on) .. ")")
    return true
end

-- ------------------------------------------------------------------------------
-- GUI
-- ------------------------------------------------------------------------------
function script_description()
    return "<h2>Pro AutoZoom (Ultimate Edition)</h2>" ..
           "<p><i>v" .. SCRIPT_VERSION .. "</i> &mdash; the definitive cinematic mouse-tracking " ..
           "engine for OBS content creators.</p>" ..
           "<p><b>Setup:</b> Select your monitor/window capture source from the dropdown, then " ..
           "select your physical monitor under Monitor / Display Settings. Both are required " ..
           "before tracking can be activated.</p>" ..
           "<p>Assign and press the Toggle Camera hotkey to start/stop.</p>"
end

-- Bold, full-width section header rendered inline in the flat form below -
-- not a real obs_properties_add_group. Groups each get their own
-- independently-sized Qt form layout, so controls in different groups can
-- never be guaranteed to line up with each other; everything in this
-- properties panel is intentionally kept in ONE flat list/one shared form
-- layout so every label column - and therefore every dropdown, slider, and
-- input - lines up at exactly the same x position. These headers are the
-- only thing standing in for the old per-section titled boxes.
local function section_header(props, id, text)
    obs.obs_properties_add_text(props, id, "<br><b>" .. text .. "</b>", obs.OBS_TEXT_INFO)
end

function script_properties()
    local props = obs.obs_properties_create()

    section_header(props, "hdr_src", "🎥 Source &amp; Layout")

    local p_sources = obs.obs_properties_add_list(
        props, "source_name", "Capture Source:",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources then
        for _, src in ipairs(sources) do
            local id = obs.obs_source_get_id(src)
            if id and (string.find(id, "monitor_capture") or
                       string.find(id, "window_capture")  or
                       string.find(id, "game_capture")) then
                local name = obs.obs_source_get_name(src)
                obs.obs_property_list_add_string(p_sources, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    local p_layout = obs.obs_properties_add_list(
        props, "layout_style", "Canvas Layout:",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_layout, "Full Screen Zoom",                  "full")
    obs.obs_property_list_add_string(p_layout, "Split: Webcam Top, Screen Bottom",  "webcam_top")
    obs.obs_property_list_add_string(p_layout, "Split: Screen Top, Webcam Bottom",  "webcam_bottom")
    obs.obs_property_list_add_string(p_layout, "Ultrawide Center Strip",            "ultrawide")

    -- Webcam Height belongs to the LAYOUT concept, not the canvas-size concept:
    -- it only means anything for the split layouts (webcam_top / webcam_bottom),
    -- where it sets how much vertical space the webcam strip occupies. It is
    -- shown/hidden by the layout dropdown's modified callback below, so it only
    -- appears when a split layout is actually selected.
    local p_wh = obs.obs_properties_add_int(props, "webcam_h", "Webcam Height (px):", 0, 7680, 1)
    obs.obs_property_set_long_description(p_wh,
        "Height of the webcam strip for split layouts. The screen share fills " ..
        "the remaining canvas height.")

    local p_canvas_override = obs.obs_properties_add_bool(props, "manual_canvas_override",
        "Enable Manual Canvas Override")
    obs.obs_property_set_long_description(p_canvas_override,
        "By default the script reads the vertical canvas size from OBS " ..
        "automatically. Enable this only if your vertical output is a SEPARATE " ..
        "canvas (e.g. Aitum Vertical) that OBS's API can't report - then enter " ..
        "its exact width and height below.")

    -- Explicit OUTPUT canvas geometry, used only when the override is ON. When
    -- OFF, get_canvas_bounds() reads OBS's own base canvas instead (correct for
    -- normal single-canvas setups, no config needed). The override exists for
    -- separate-canvas plugins where obs_get_video_info reports the wrong (main)
    -- canvas - the root cause of the original horizontal "squash".
    local p_cw = obs.obs_properties_add_int(props, "out_canvas_w", "Vertical Canvas Width (px):",  100, 7680, 1)
    obs.obs_property_set_long_description(p_cw, "Full width of your vertical output canvas (e.g. 1080).")

    local p_ch = obs.obs_properties_add_int(props, "out_canvas_h", "Vertical Canvas Height (px):", 100, 7680, 1)
    obs.obs_property_set_long_description(p_ch, "Full height of your vertical output canvas (e.g. 1920).")

    obs.obs_property_set_visible(p_cw, cache.manual_canvas_override)
    obs.obs_property_set_visible(p_ch, cache.manual_canvas_override)

    obs.obs_property_set_modified_callback(p_canvas_override, toggle_canvas_visibility)

    -- Show the webcam-height field only for split layouts. Uses the current
    -- cached value for the initial draw; the modified callback keeps it in sync.
    local split = (cache.layout_style == "webcam_top" or cache.layout_style == "webcam_bottom")
    obs.obs_property_set_visible(p_wh, split)
    obs.obs_property_set_modified_callback(p_layout, toggle_layout_visibility)

    section_header(props, "hdr_hw", "🖥️ Monitor &amp; Display Settings")

    -- Windows-enumerated monitor picker: ground-truth geometry straight from
    -- EnumDisplayMonitors, no guessing from OBS source settings. Re-populated
    -- every time this properties dialog opens. Selecting a monitor here is
    -- required - there is no auto-detect fallback, since guessing from the
    -- capture source's reported dimensions was unreliable on multi-monitor
    -- setups (see get_active_monitor_geometry).
    local p_picked = obs.obs_properties_add_list(
        props, "picked_monitor", "Detected Monitor:",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_picked, "-- Select a Monitor (Required) --", "")
    for i, m in ipairs(enumerate_monitors()) do
        local label = string.format("Monitor %d - %dx%d @ (%d,%d)%s",
            i, m.w, m.h, m.x, m.y, m.primary and "  (Primary)" or "")
        local value = string.format("%d,%d,%d,%d", m.x, m.y, m.w, m.h)
        obs.obs_property_list_add_string(p_picked, label, value)
    end

    local p_override = obs.obs_properties_add_bool(props, "manual_hw_override", "Enable Manual Monitor Settings Override (overrides the picker above)")

    local p_w = obs.obs_properties_add_int(props, "mon_w",         "Width (px):",  100, 7680,   1)
    local p_h = obs.obs_properties_add_int(props, "mon_h",         "Height (px):", 100, 4320,   1)
    local p_x = obs.obs_properties_add_int(props, "mon_x_offset",  "X Offset:",  -10000, 10000, 1)
    local p_y = obs.obs_properties_add_int(props, "mon_y_offset",  "Y Offset:",  -10000, 10000, 1)

    obs.obs_property_set_visible(p_w, cache.manual_hw_override)
    obs.obs_property_set_visible(p_h, cache.manual_hw_override)
    obs.obs_property_set_visible(p_x, cache.manual_hw_override)
    obs.obs_property_set_visible(p_y, cache.manual_hw_override)

    obs.obs_property_set_modified_callback(p_override, toggle_hw_visibility)

    section_header(props, "hdr_cam", "🎬 Camera Engine")

    obs.obs_properties_add_bool(props,         "zoom_enabled",      "Enable Camera Tracking")
    obs.obs_properties_add_float_slider(props, "base_zoom",         "Base Zoom Factor:", 1.0, 5.0,  0.1)
    obs.obs_properties_add_float_slider(props, "punch_zoom",        "Punch Zoom:",        1.0, 10.0, 0.1)
    obs.obs_properties_add_float_slider(props, "tracking_speed",    "Smoothness:",        0.01, 0.50, 0.01)
    obs.obs_properties_add_int_slider(props,   "deadzone",          "Deadzone (%):",      0, 40, 1)
    obs.obs_properties_add_bool(props,         "auto_center",       "Auto-Return to Center when Idle")
    obs.obs_properties_add_float_slider(props, "auto_center_delay", "Idle Timeout (s):",  1.0, 10.0, 0.5)
    obs.obs_properties_add_bool(props,         "debug_mode",        "Debug Mode")
    obs.obs_properties_add_button(props, "reset_cam_defaults", "↺ Reset Camera Engine to Defaults",
        function(properties)
            if not live_settings then return false end
            debug_log("UI: 'Reset Camera Engine to Defaults' clicked.")
            obs.obs_data_set_bool  (live_settings, "zoom_enabled",      true)
            obs.obs_data_set_double(live_settings, "base_zoom",         2.0)
            obs.obs_data_set_double(live_settings, "punch_zoom",        4.0)
            obs.obs_data_set_double(live_settings, "tracking_speed",    0.12)
            obs.obs_data_set_int   (live_settings, "deadzone",          15)
            obs.obs_data_set_bool  (live_settings, "auto_center",       false)
            obs.obs_data_set_double(live_settings, "auto_center_delay", 3.0)
            obs.obs_data_set_bool  (live_settings, "debug_mode",        false)
            -- Returning true alone only tells OBS the property *list* changed;
            -- it does not push new values into already-drawn widgets. This
            -- explicit call is what actually makes the sliders/checkboxes
            -- snap back to the values just written above.
            obs.obs_properties_apply_settings(properties, live_settings)
            return true
        end)

    section_header(props, "hdr_ind", "🎯 Mouse Indicator")

    local p_ind_mode = obs.obs_properties_add_list(
        props, "ind_mode", "Visibility:",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_ind_mode, "Off",             "Off")
    obs.obs_property_list_add_string(p_ind_mode, "Always On",       "Always On")
    obs.obs_property_list_add_string(p_ind_mode, "Hotkey Triggered","Hotkey Triggered")
    local p_ind_color   = obs.obs_properties_add_color(props,      "ind_color",   "Ring Color:")
    local p_ind_opacity = obs.obs_properties_add_int_slider(props, "ind_opacity", "Ring Opacity (%):", 10, 100, 5)
    local p_ind_size    = obs.obs_properties_add_int_slider(props, "ind_size",    "Ring Size (px):",   20, 300, 5)

    -- Hide the styling fields when the indicator is Off (consistent with the
    -- monitor/canvas override show-hide pattern). Initial draw uses the cached
    -- mode; the modified callback keeps it live.
    local ind_on = (cache.ind_mode ~= "Off")
    obs.obs_property_set_visible(p_ind_color,   ind_on)
    obs.obs_property_set_visible(p_ind_opacity, ind_on)
    obs.obs_property_set_visible(p_ind_size,    ind_on)
    obs.obs_property_set_modified_callback(p_ind_mode, toggle_indicator_visibility)
    obs.obs_properties_add_button(props, "reset_ind_defaults", "↺ Reset Mouse Indicator to Defaults",
        function(properties)
            if not live_settings then return false end
            debug_log("UI: 'Reset Mouse Indicator to Defaults' clicked.")
            obs.obs_data_set_string(live_settings, "ind_mode",    "Off")
            obs.obs_data_set_int   (live_settings, "ind_color",   16776960)
            obs.obs_data_set_int   (live_settings, "ind_opacity", 70)
            obs.obs_data_set_int   (live_settings, "ind_size",    72)
            obs.obs_properties_apply_settings(properties, live_settings)
            return true
        end)

    -- A button (unlike text/list/slider properties) spans the full width of the
    -- properties panel with no separate label column, and Qt centers a button's
    -- own text by default - the only way to get a genuinely centered credit line
    -- in this dialog, since OBS_TEXT_INFO fields stay confined to the narrower
    -- value column and only look centered within that column, not the panel.
    obs.obs_properties_add_button(props, "credit_link", "❤️ Made by gipstamusic",
        function()
            -- Best-effort open of the credit link across platforms. Wrapped in
            -- pcall so a restricted environment (or missing shell command) can
            -- never raise out of a UI button callback. ffi.os is provided by
            -- LuaJIT: "Windows" | "OSX" | "Linux" | "BSD" ...
            pcall(function()
                local url = "https://lnk.bio/gipstamusic"
                if ffi.os == "Windows" then
                    os.execute('start "" "' .. url .. '"')
                elseif ffi.os == "OSX" then
                    os.execute('open "' .. url .. '"')
                else
                    os.execute('xdg-open "' .. url .. '"')
                end
            end)
            return false
        end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "source_name",       "")
    obs.obs_data_set_default_string(settings, "picked_monitor",    "")
    obs.obs_data_set_default_bool  (settings, "manual_hw_override",false)
    obs.obs_data_set_default_int   (settings, "mon_w",             1920)
    obs.obs_data_set_default_int   (settings, "mon_h",             1080)
    obs.obs_data_set_default_int   (settings, "mon_x_offset",      0)
    obs.obs_data_set_default_int   (settings, "mon_y_offset",      0)
    obs.obs_data_set_default_string(settings, "layout_style",      "full")
    obs.obs_data_set_default_bool  (settings, "manual_canvas_override", false)
    obs.obs_data_set_default_int   (settings, "out_canvas_w",      1080)
    obs.obs_data_set_default_int   (settings, "out_canvas_h",      1920)
    obs.obs_data_set_default_int   (settings, "webcam_h",          0)
    obs.obs_data_set_default_bool  (settings, "zoom_enabled",      true)
    obs.obs_data_set_default_double(settings, "base_zoom",         2.0)
    obs.obs_data_set_default_double(settings, "punch_zoom",        4.0)
    obs.obs_data_set_default_double(settings, "tracking_speed",    0.12)
    obs.obs_data_set_default_int   (settings, "deadzone",          15)
    obs.obs_data_set_default_bool  (settings, "auto_center",       false)
    obs.obs_data_set_default_double(settings, "auto_center_delay", 3.0)
    obs.obs_data_set_default_bool  (settings, "debug_mode",        false)
    obs.obs_data_set_default_string(settings, "ind_mode",          "Off")
    obs.obs_data_set_default_int   (settings, "ind_color",         16776960)
    obs.obs_data_set_default_int   (settings, "ind_opacity",       70)
    obs.obs_data_set_default_int   (settings, "ind_size",          72)
end

-- ------------------------------------------------------------------------------
-- Camera helpers
-- ------------------------------------------------------------------------------
local function get_canvas_bounds()
    -- Canvas size resolution:
    --   Override ON  -> use the user's explicit Vertical Canvas Width/Height.
    --                   Required for SEPARATE canvases (e.g. Aitum Vertical) that
    --                   obs_get_video_info() cannot report - reading the API in
    --                   that case returns the MAIN (horizontal) canvas and the
    --                   crop aspect comes out wrong (the original "squash").
    --   Override OFF -> auto-read OBS's own base canvas. Correct and zero-config
    --                   for normal single-canvas setups; no hardcoded per-user
    --                   defaults are assumed.
    local cw, ch
    if cache.manual_canvas_override then
        cw = math.max(cache.out_canvas_w or 0, 1)
        ch = math.max(cache.out_canvas_h or 0, 1)
    else
        local ovi = obs.obs_video_info()
        if ovi and obs.obs_get_video_info(ovi) then
            cw = math.max(tonumber(ovi.base_width)  or 0, 1)
            ch = math.max(tonumber(ovi.base_height) or 0, 1)
        else
            -- Last-resort only if the API is entirely unavailable on this build.
            cw = math.max(cache.out_canvas_w or 0, 1)
            ch = math.max(cache.out_canvas_h or 0, 1)
        end
    end

    -- Webcam strip height applies only to the split layouts below.
    local wh = math.max(cache.webcam_h or 0, 0)

    if cache.layout_style == "webcam_top" then return cw, math.max(ch - wh, 1), 0, wh
    elseif cache.layout_style == "webcam_bottom" then return cw, math.max(ch - wh, 1), 0, 0
    elseif cache.layout_style == "ultrawide" then return cw, ch / 3, 0, ch / 3
    -- NOTE: a "pip" (Picture-in-Picture) style was scoped but not implemented,
    -- so it's intentionally NOT offered in the Canvas Layout dropdown. If added
    -- later, give it a real branch here; any unknown style safely falls through
    -- to full-canvas behavior below.
    else return cw, ch, 0, 0 end
end

local function reset_camera_position()
    -- get_active_monitor_geometry is the single source of truth for the
    -- manual/picked/auto precedence chain, so this can't drift out of sync
    -- with reset_crop_filter/calculate_crop/script_tick again.
    local base_w, base_h, off_x, off_y = get_active_monitor_geometry()

    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    local mx = tonumber(m_pos.x) - off_x
    local my = tonumber(m_pos.y) - off_y
    mx = math.max(0, math.min(mx, base_w))
    my = math.max(0, math.min(my, base_h))
    last_cam.x = mx
    last_cam.y = my
    debug_log("reset_camera_position: Resetting to MX=" .. mx .. " MY=" .. my)
end

local function reset_crop_filter()
    if cache.source_name == "" then
        debug_log("reset_crop_filter: Skipped, no source selected.")
        return
    end

    local source = obs.obs_get_source_by_name(cache.source_name)
    if not source then
        debug_log("reset_crop_filter: Skipped, source '" .. cache.source_name .. "' not found.")
        return
    end

    local src_w, src_h = get_active_monitor_geometry()
    
    if src_w == 0 or src_h == 0 then
        src_w, src_h = 1920, 1080 
    end

    local bw, bh = get_canvas_bounds()
    bw = math.max(bw, 1)
    bh = math.max(bh, 1)
    local c_aspect = bw / bh
    local base_w = math.max(src_w, 1)
    local base_h = math.max(src_h, 1)
    
    local zw = base_w
    local zh = zw / c_aspect
    if zh > base_h then
        zh = base_h
        zw = zh * c_aspect
    end

    local left   = (base_w - zw) / 2
    local top    = (base_h - zh) / 2
    local right  = base_w - (left + zw)
    local bottom = base_h - (top + zh)

    local filter = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
    if filter then
        local f_settings = obs.obs_data_create()
        obs.obs_data_set_int(f_settings, "left", math.floor(left))
        obs.obs_data_set_int(f_settings, "top", math.floor(top))
        obs.obs_data_set_int(f_settings, "right", math.floor(right))
        obs.obs_data_set_int(f_settings, "bottom", math.floor(bottom))
        obs.obs_source_update(filter, f_settings)
        obs.obs_data_release(f_settings)
        obs.obs_source_release(filter)
        debug_log("reset_crop_filter: Viewport fully restored to center-cut.")
    end
    obs.obs_source_release(source)

    cur_crop    = { left = left, top = top, right = right, bottom = bottom }
    target_crop = { left = left, top = top, right = right, bottom = bottom }
    cur_zoom    = 1.0
    last_cam.x  = base_w / 2
    last_cam.y  = base_h / 2
end

-- ------------------------------------------------------------------------------
-- Settings update
-- ------------------------------------------------------------------------------
function script_update(settings)
    live_settings = settings
    cache.debug_mode = obs.obs_data_get_bool(settings, "debug_mode")
    debug_log("script_update: Processing UI changes...")

    cache.manual_hw_override = obs.obs_data_get_bool(settings, "manual_hw_override")
    
    if cache.manual_hw_override then
        cache.mon_w        = obs.obs_data_get_int(settings, "mon_w")
        cache.mon_h        = obs.obs_data_get_int(settings, "mon_h")
        cache.mon_x_offset = obs.obs_data_get_int(settings, "mon_x_offset")
        cache.mon_y_offset = obs.obs_data_get_int(settings, "mon_y_offset")
        debug_log("script_update: Manual Override ON -> W:"..cache.mon_w.." H:"..cache.mon_h.." X:"..cache.mon_x_offset.." Y:"..cache.mon_y_offset)
    else
        debug_log("script_update: Manual Override OFF -> Relying on picked monitor.")
    end

    -- Windows monitor picker (see get_active_monitor_geometry for precedence:
    -- manual override still wins over this if both are somehow set).
    local picked_str = obs.obs_data_get_string(settings, "picked_monitor")
    if picked_str and picked_str ~= "" then
        local px, py, pw, ph = string.match(picked_str, "(%-?%d+),(%-?%d+),(%d+),(%d+)")
        if px and py and pw and ph then
            cache.has_picked_monitor = true
            cache.picked_mon_x = tonumber(px)
            cache.picked_mon_y = tonumber(py)
            cache.picked_mon_w = tonumber(pw)
            cache.picked_mon_h = tonumber(ph)
            debug_log("script_update: Picked Monitor -> W:"..pw.." H:"..ph.." X:"..px.." Y:"..py)
        else
            cache.has_picked_monitor = false
            debug_log("script_update: picked_monitor value didn't parse, ignoring: " .. tostring(picked_str))
        end
    else
        cache.has_picked_monitor = false
    end

    local new_source = obs.obs_data_get_string(settings, "source_name")

    -- Every Camera Engine / Mouse Indicator / Canvas Layout field is read
    -- into a "new_*" local first and diffed against the current cache value
    -- before being stored, so Debug Mode logs exactly which field changed
    -- and what it changed to - instead of silently overwriting cache with
    -- no trace, which was the gap that made Debug Mode incomplete.
    local new_layout_style      = obs.obs_data_get_string(settings, "layout_style")
    local new_manual_canvas     = obs.obs_data_get_bool  (settings, "manual_canvas_override")
    local new_out_canvas_w      = obs.obs_data_get_int   (settings, "out_canvas_w")
    local new_out_canvas_h      = obs.obs_data_get_int   (settings, "out_canvas_h")
    local new_webcam_h          = obs.obs_data_get_int   (settings, "webcam_h")
    local new_zoom_enabled      = obs.obs_data_get_bool  (settings, "zoom_enabled")
    local new_base_zoom         = obs.obs_data_get_double(settings, "base_zoom")
    local new_punch_zoom        = obs.obs_data_get_double(settings, "punch_zoom")
    local new_tracking_speed    = obs.obs_data_get_double(settings, "tracking_speed")
    local new_deadzone          = obs.obs_data_get_int   (settings, "deadzone")
    local new_auto_center       = obs.obs_data_get_bool  (settings, "auto_center")
    local new_auto_center_delay = obs.obs_data_get_double(settings, "auto_center_delay")
    local new_ind_mode    = obs.obs_data_get_string(settings, "ind_mode")
    local new_ind_color   = obs.obs_data_get_int   (settings, "ind_color")
    local new_ind_opacity = obs.obs_data_get_int   (settings, "ind_opacity")
    local new_ind_size    = obs.obs_data_get_int   (settings, "ind_size")

    if new_layout_style      ~= cache.layout_style      then debug_log("script_update: Canvas Layout changed -> " .. new_layout_style) end
    if new_out_canvas_w      ~= cache.out_canvas_w      then debug_log("script_update: Vertical Canvas Width changed -> " .. new_out_canvas_w) end
    if new_out_canvas_h      ~= cache.out_canvas_h      then debug_log("script_update: Vertical Canvas Height changed -> " .. new_out_canvas_h) end
    if new_webcam_h          ~= cache.webcam_h          then debug_log("script_update: Webcam Height changed -> " .. new_webcam_h) end
    if new_zoom_enabled      ~= cache.zoom_enabled      then debug_log("script_update: Enable Camera Tracking changed -> " .. tostring(new_zoom_enabled)) end
    if new_base_zoom         ~= cache.base_zoom         then debug_log("script_update: Base Zoom Factor changed -> " .. new_base_zoom) end
    if new_punch_zoom        ~= cache.punch_zoom        then debug_log("script_update: Punch Zoom changed -> " .. new_punch_zoom) end
    if new_tracking_speed    ~= cache.tracking_speed    then debug_log("script_update: Smoothness changed -> " .. new_tracking_speed) end
    if new_deadzone          ~= cache.deadzone          then debug_log("script_update: Deadzone changed -> " .. new_deadzone) end
    if new_auto_center       ~= cache.auto_center       then debug_log("script_update: Auto-Return to Center changed -> " .. tostring(new_auto_center)) end
    if new_auto_center_delay ~= cache.auto_center_delay then debug_log("script_update: Idle Timeout changed -> " .. new_auto_center_delay) end
    if new_ind_mode    ~= cache.ind_mode    then debug_log("script_update: Indicator Visibility changed -> " .. new_ind_mode) end
    if new_ind_color   ~= cache.ind_color   then debug_log("script_update: Ring Color changed -> " .. new_ind_color) end
    if new_ind_opacity ~= cache.ind_opacity then debug_log("script_update: Ring Opacity changed -> " .. new_ind_opacity) end
    if new_ind_size    ~= cache.ind_size    then debug_log("script_update: Ring Size changed -> " .. new_ind_size) end

    cache.layout_style      = new_layout_style
    cache.manual_canvas_override = new_manual_canvas
    cache.out_canvas_w      = new_out_canvas_w
    cache.out_canvas_h      = new_out_canvas_h
    cache.webcam_h          = new_webcam_h
    cache.zoom_enabled      = new_zoom_enabled
    cache.base_zoom         = new_base_zoom
    cache.punch_zoom        = new_punch_zoom
    cache.tracking_speed    = new_tracking_speed
    cache.deadzone          = new_deadzone
    cache.auto_center       = new_auto_center
    cache.auto_center_delay = new_auto_center_delay
    cache.ind_mode    = new_ind_mode
    cache.ind_color   = new_ind_color
    cache.ind_opacity = new_ind_opacity
    cache.ind_size    = new_ind_size

    if new_source ~= last_source_name then
        debug_log("script_update: Source changed from '" .. last_source_name .. "' to '" .. new_source .. "'")
        last_source_name  = new_source
        cache.source_name = new_source
        zoom_active        = false
        cur_zoom            = 1.0
    else
        cache.source_name = new_source
    end

    if not cache.manual_hw_override and not cache.has_picked_monitor then
        debug_warn("No monitor selected. Open script Properties and choose your " ..
            "monitor from the 'Detected Monitor' dropdown before enabling tracking.")
    end

    if not cache.zoom_enabled then
        zoom_active = false
    end

    -- DIAGNOSTIC (Debug Mode only): report what OBS's standard video-info API
    -- returns for the base canvas, alongside the vertical canvas the script is
    -- actually targeting. If api_canvas matches the vertical size, auto-read is
    -- reliable and the manual override is optional; if it reports the MAIN
    -- (horizontal) size instead, the API can't see the separate vertical canvas
    -- and the manual override is required. Logged once per settings change.
    local ovi = obs.obs_video_info()
    if ovi and obs.obs_get_video_info(ovi) then
        debug_log(string.format(
            "CANVAS DIAG: OBS API base=%dx%d | script target=%dx%d (webcam %dpx, override=%s)",
            tonumber(ovi.base_width) or 0, tonumber(ovi.base_height) or 0,
            cache.out_canvas_w, cache.out_canvas_h, cache.webcam_h,
            tostring(cache.manual_canvas_override)))
    else
        debug_log("CANVAS DIAG: obs_get_video_info() unavailable on this OBS build.")
    end
end

-- ------------------------------------------------------------------------------
-- Hotkeys
-- ------------------------------------------------------------------------------
local function hk_zoom(pressed)
    if not pressed or not cache.zoom_enabled then return end

    if not zoom_active and not cache.manual_hw_override and not cache.has_picked_monitor then
        debug_warn("Cannot activate tracking - no monitor selected. Open script " ..
            "Properties and choose your monitor from the 'Detected Monitor' dropdown.")
        return
    end

    zoom_active = not zoom_active

    if zoom_active then
        reset_camera_position()
        cur_zoom = cache.base_zoom
        last_mouse_time = os.clock()
        debug_log("HOTKEY: Tracking ACTIVATED")
    else
        debug_log("HOTKEY: Tracking DEACTIVATED, resetting crop.")
        reset_crop_filter()
    end
end

local function hk_ind  (pressed) if pressed then internal_ind_active = not internal_ind_active; debug_log("HOTKEY: Indicator toggled") end end
local function hk_punch(pressed) is_punch_active = pressed; debug_log("HOTKEY: Punch Zoom state: " .. tostring(pressed)) end
local function hk_pause(pressed) is_pause_active = pressed; debug_log("HOTKEY: Pause Camera state: " .. tostring(pressed)) end

function script_load(settings)
    -- script_update() hasn't run yet at this point in the OBS lifecycle, so
    -- cache.debug_mode is still its default (false) - read it directly from
    -- the saved settings here so the debug_log calls below actually respect
    -- the user's last-saved Debug Mode preference instead of always staying
    -- silent on this first pass.
    cache.debug_mode = obs.obs_data_get_bool(settings, "debug_mode")

    hk_zoom_id  = obs.obs_hotkey_register_frontend("paz_zoom",  "Pro AutoZoom: Toggle Camera",              hk_zoom)
    hk_ind_id   = obs.obs_hotkey_register_frontend("paz_ind",   "Pro AutoZoom: Toggle Pointer",             hk_ind)
    hk_punch_id = obs.obs_hotkey_register_frontend("paz_punch", "Pro AutoZoom: Hold for Detail Zoom (Punch)", hk_punch)
    hk_pause_id = obs.obs_hotkey_register_frontend("paz_pause", "Pro AutoZoom: Hold to Freeze Camera",      hk_pause)
    debug_log("script_load: Hotkeys registered.")

    local arr_z = obs.obs_data_get_array(settings, "arr_z")
    local arr_i = obs.obs_data_get_array(settings, "arr_i")
    local arr_p = obs.obs_data_get_array(settings, "arr_p")
    local arr_f = obs.obs_data_get_array(settings, "arr_f")
    obs.obs_hotkey_load(hk_zoom_id,  arr_z)
    obs.obs_hotkey_load(hk_ind_id,   arr_i)
    obs.obs_hotkey_load(hk_punch_id, arr_p)
    obs.obs_hotkey_load(hk_pause_id, arr_f)
    obs.obs_data_array_release(arr_z)
    obs.obs_data_array_release(arr_i)
    obs.obs_data_array_release(arr_p)
    obs.obs_data_array_release(arr_f)
    debug_log("script_load: Saved hotkey bindings loaded.")
end

function script_save(settings)
    local arr_z = obs.obs_hotkey_save(hk_zoom_id)
    local arr_i = obs.obs_hotkey_save(hk_ind_id)
    local arr_p = obs.obs_hotkey_save(hk_punch_id)
    local arr_f = obs.obs_hotkey_save(hk_pause_id)
    obs.obs_data_set_array(settings, "arr_z", arr_z)
    obs.obs_data_set_array(settings, "arr_i", arr_i)
    obs.obs_data_set_array(settings, "arr_p", arr_p)
    obs.obs_data_set_array(settings, "arr_f", arr_f)
    obs.obs_data_array_release(arr_z)
    obs.obs_data_array_release(arr_i)
    obs.obs_data_array_release(arr_p)
    obs.obs_data_array_release(arr_f)
    debug_log("script_save: Hotkey bindings saved.")
end

function script_unload()
    debug_log("script_unload: Cleaning up before script disable/removal.")

    -- Restore any actively-zoomed source to its normal, uncropped view so
    -- disabling the script doesn't leave the output visually stuck zoomed-in.
    reset_crop_filter()

    -- The mouse indicator source is created on demand in script_tick and is
    -- never referenced again once the script unloads; remove it explicitly so
    -- it doesn't sit orphaned in the user's scene.
    local p_source = obs.obs_get_source_by_name("ProAutoZoom_CirclePointer")
    if p_source then
        obs.obs_source_remove(p_source)
        obs.obs_source_release(p_source)
    end
end

-- ------------------------------------------------------------------------------
-- Source / filter helpers
-- ------------------------------------------------------------------------------
local function get_or_create_filter(source)
    local f = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
    if not f then
        debug_log("get_or_create_filter: Filter not found, creating new one.")
        local s = obs.obs_data_create()
        f = obs.obs_source_create_private("crop_filter", "CoreAutoZoom_Crop", s)
        obs.obs_data_release(s)
        if f then
            obs.obs_source_filter_add(source, f)
            obs.obs_source_release(f)
            f = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
        end
    end
    return f
end

-- ------------------------------------------------------------------------------
-- Crop mathematics
-- ------------------------------------------------------------------------------
local function calculate_crop(mx, my, bw, bh, src_w, src_h, is_on_screen)
    bw = math.max(bw, 1); bh = math.max(bh, 1)
    local c_aspect = bw / bh

    -- src_w/src_h are already the fully-resolved active dimensions (manual
    -- override / picked monitor / auto-detected source - see
    -- get_active_monitor_geometry, called upstream in script_tick). No need
    -- to re-derive from cache here; that duplicated ternary is what let
    -- reset_camera_position drift out of sync in the first place.
    local base_w = math.max(src_w or 0, 1)
    local base_h = math.max(src_h or 0, 1)

    if not is_pause_active then
        -- Zoom level only advances while not frozen, so "Hold to Freeze
        -- Camera" freezes the zoom level too, not just position/pan. (Moved
        -- inside this guard - previously cur_zoom kept smoothing even while
        -- paused, so a Punch press during a freeze would still visibly zoom.)
        local target_z = is_punch_active and cache.punch_zoom or cache.base_zoom
        cur_zoom = cur_zoom + (target_z - cur_zoom) * (cache.tracking_speed * 1.5)
    end

    local zw = base_w / cur_zoom
    local zh = zw / c_aspect
    if zh > base_h then
        zh = base_h
        zw = zh * c_aspect
    end

    if not is_pause_active then
        -- Only move the camera bounds if the mouse is actively on the target screen
        if is_on_screen then
            local dx = mx - last_cam.x
            local dy = my - last_cam.y
            local adx = math.abs(dx)
            local ady = math.abs(dy)
            local thresh_x = zw * (cache.deadzone / 100)
            local thresh_y = zh * (cache.deadzone / 100)

            if adx > thresh_x then last_cam.x = last_cam.x + (dx - (dx > 0 and thresh_x or -thresh_x)) end
            if ady > thresh_y then last_cam.y = last_cam.y + (dy - (dy > 0 and thresh_y or -thresh_y)) end

            -- Only reset the idle timer if the mouse is making significant movements ON the target screen
            if adx > 2 or ady > 2 then
                last_mouse_time = os.clock()
            end
        end

        -- If Auto-Center is enabled, this will pull the camera back to center if time expires
        -- (This naturally triggers when moving to a second monitor because last_mouse_time stops updating)
        if cache.auto_center and (os.clock() - last_mouse_time > cache.auto_center_delay) then
            local speed = cache.tracking_speed * 0.2
            last_cam.x = last_cam.x + ((base_w / 2) - last_cam.x) * speed
            last_cam.y = last_cam.y + ((base_h / 2) - last_cam.y) * speed
        end
    end

    last_cam.x = math.max(zw / 2, math.min(last_cam.x, base_w - zw / 2))
    last_cam.y = math.max(zh / 2, math.min(last_cam.y, base_h - zh / 2))

    local left = last_cam.x - (zw / 2)
    local top  = last_cam.y - (zh / 2)

    return left, top, base_w - (left + zw), base_h - (top + zh)
end

-- ------------------------------------------------------------------------------
-- Main tick
-- ------------------------------------------------------------------------------
function script_tick(seconds)
    if cache.source_name == "" or not zoom_active then return end

    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    
    -- NOTE: for Window Capture / Game Capture sources, this offset reflects a
    -- fixed screen region (from the picker or manual override), not the
    -- live on-screen position of a movable window. If the captured
    -- window is moved mid-stream, mouse tracking will drift out of sync.
    -- Works best with fullscreen/maximized captures, or Monitor Capture sources.
    local active_mon_w, active_mon_h, active_off_x, active_off_y = get_active_monitor_geometry()
    
    if active_mon_w == 0 then active_mon_w = 1920 end
    if active_mon_h == 0 then active_mon_h = 1080 end

    local raw_x = tonumber(m_pos.x)
    local raw_y = tonumber(m_pos.y)
    
    -- Check if the cursor is actually inside the boundaries of the target monitor
    local is_on_screen = (raw_x >= active_off_x and raw_x <= active_off_x + active_mon_w) and
                         (raw_y >= active_off_y and raw_y <= active_off_y + active_mon_h)

    local mx = raw_x - active_off_x
    local my = raw_y - active_off_y

    local source = obs.obs_get_source_by_name(cache.source_name)
    if not source then return end

    local src_w, src_h = active_mon_w, active_mon_h

    local bw, bh, bx, by = get_canvas_bounds()
    if bw <= 0 or bh <= 0 then
        obs.obs_source_release(source)
        return
    end

    -- Pass the on_screen flag to the math calculator
    target_crop.left, target_crop.top, target_crop.right, target_crop.bottom =
        calculate_crop(mx, my, bw, bh, src_w, src_h, is_on_screen)

    local spd = cache.tracking_speed * (is_punch_active and 1.5 or 1.0)

    -- Capture pre-lerp values so we can measure how much the camera actually
    -- moved this tick. When the mouse sits still (or is off-screen and not being
    -- auto-centered), cur_crop converges on target_crop and the per-frame delta
    -- falls to ~0. Past that point, re-writing identical values to the crop
    -- filter every frame is wasted work AND spams the debug log with identical
    -- lines (the "counter kept incrementing with no mouse movement" report).
    -- Below a sub-pixel threshold we treat the camera as settled and skip both
    -- the filter write and the tick log for this frame.
    local prev_l, prev_t = cur_crop.left, cur_crop.top
    local prev_r, prev_b = cur_crop.right, cur_crop.bottom

    cur_crop.left   = cur_crop.left   + (target_crop.left   - cur_crop.left)   * spd
    cur_crop.top    = cur_crop.top    + (target_crop.top    - cur_crop.top)    * spd
    cur_crop.right  = cur_crop.right  + (target_crop.right  - cur_crop.right)  * spd
    cur_crop.bottom = cur_crop.bottom + (target_crop.bottom - cur_crop.bottom) * spd

    -- Total absolute movement across all four edges this frame.
    local moved = math.abs(cur_crop.left   - prev_l) +
                  math.abs(cur_crop.top    - prev_t) +
                  math.abs(cur_crop.right  - prev_r) +
                  math.abs(cur_crop.bottom - prev_b)

    -- 0.05px total is well below what math.floor() can even express in the
    -- filter, so anything under it produces no visible change. Snap to target
    -- so we don't leave a permanent sub-pixel residual, then bail early.
    --
    -- Guard: only fast-exit when the indicator isn't being drawn. With the
    -- pointer active, cursor movement INSIDE the deadzone pans nothing (crop is
    -- settled) but the dot must still follow the cursor, so in that case we fall
    -- through to the indicator code below instead of returning here.
    local indicator_active = (cache.ind_mode ~= "Off")
    if moved < 0.05 and not indicator_active then
        cur_crop.left, cur_crop.top     = target_crop.left,  target_crop.top
        cur_crop.right, cur_crop.bottom = target_crop.right, target_crop.bottom
        obs.obs_source_release(source)
        return
    end

    -- vis_w/vis_h are the dimensions that actually remain after the crop; their
    -- ratio should match the target box (bw/bh). If OutRatio != TargetRatio the
    -- image will be distorted, so both are logged for quick verification. Only
    -- logged when the camera actually moved this frame - when settled (e.g.
    -- indicator active but cursor idle in the deadzone) we stay silent instead
    -- of repeating the same line every tick.
    if moved >= 0.05 then
        local vis_w = src_w - cur_crop.left - cur_crop.right
        local vis_h = src_h - cur_crop.top  - cur_crop.bottom
        debug_log(string.format("CROP -> L:%.1f T:%.1f R:%.1f B:%.1f | VIS: %.0fx%.0f OutRatio:%.3f TargetRatio:%.3f | MOUSE: X:%d Y:%d (OnScreen: %s)",
                  cur_crop.left, cur_crop.top, cur_crop.right, cur_crop.bottom,
                  vis_w, vis_h, (vis_h > 0 and vis_w / vis_h or 0), (bh > 0 and bw / bh or 0),
                  mx, my, tostring(is_on_screen)), true)
    end

    local filter = get_or_create_filter(source)
    if filter then
        local f_settings = obs.obs_source_get_settings(filter)
        if f_settings then
            obs.obs_data_set_int(f_settings, "left",   math.floor(cur_crop.left))
            obs.obs_data_set_int(f_settings, "top",    math.floor(cur_crop.top))
            obs.obs_data_set_int(f_settings, "right",  math.floor(cur_crop.right))
            obs.obs_data_set_int(f_settings, "bottom", math.floor(cur_crop.bottom))
            obs.obs_source_update(filter, f_settings)
            obs.obs_data_release(f_settings)
        end
        obs.obs_source_release(filter)
    end
    obs.obs_source_release(source)

    -- Mouse indicator overlay
    if cache.ind_mode == "Off" then return end

    -- Hide the indicator if the mouse is on another screen
    local show = is_on_screen and ( (cache.ind_mode == "Always On") or (cache.ind_mode == "Hotkey Triggered" and internal_ind_active) )

    local current_scene_source = obs.obs_frontend_get_current_scene()
    if not current_scene_source then return end

    local scene = obs.obs_scene_from_source(current_scene_source)
    if not scene then
        obs.obs_source_release(current_scene_source)
        return
    end

    local p_source = obs.obs_get_source_by_name("ProAutoZoom_CirclePointer")

    if show then
        local alpha_val  = math.floor((cache.ind_opacity / 100) * 255)
        local base_color = cache.ind_color % 16777216 
        local final_color = base_color + (alpha_val * 16777216)

        if not p_source then
            local s_settings = obs.obs_data_create()
            local font_obj   = obs.obs_data_create()
            obs.obs_data_set_string(s_settings, "text",  "●")
            obs.obs_data_set_int   (s_settings, "color", final_color)
            obs.obs_data_set_string(font_obj,   "face",  "Arial")
            obs.obs_data_set_int   (font_obj,   "size",  cache.ind_size)
            obs.obs_data_set_obj   (s_settings, "font",  font_obj)
            obs.obs_data_release(font_obj)

            p_source = obs.obs_source_create("text_gdiplus", "ProAutoZoom_CirclePointer", s_settings, nil)
            obs.obs_data_release(s_settings)

            if p_source then
                obs.obs_scene_add(scene, p_source)
            end
        else
            local s_settings = obs.obs_data_create()
            local font_obj   = obs.obs_data_create()
            obs.obs_data_set_int   (s_settings, "color", final_color)
            obs.obs_data_set_string(font_obj,   "face",  "Arial")
            obs.obs_data_set_int   (font_obj,   "size",  cache.ind_size)
            obs.obs_data_set_obj   (s_settings, "font",  font_obj)
            obs.obs_data_release(font_obj)
            obs.obs_source_update(p_source, s_settings)
            obs.obs_data_release(s_settings)
        end

        local target_item  = obs.obs_scene_find_source(scene, cache.source_name)
        local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_CirclePointer")

        if target_item and pointer_item then
            local t_info = obs.obs_transform_info()
            if t_info then
                if obs.obs_sceneitem_get_info2 then
                    obs.obs_sceneitem_get_info2(target_item, t_info)
                else
                    obs.obs_sceneitem_get_info(target_item, t_info)
                end

                -- NOTE: this positioning math only works when the tracked source's scene
                -- item uses a "bounds" (Fit to bounds box) transform, i.e. bounds.x/y > 0.
                -- A source that was simply drag-resized in the scene normally has
                -- bounds_type = NONE (bounds.x/y stay 0), so this branch is skipped and
                -- the indicator silently never appears - no error, no debug log. Worth
                -- documenting for users, or extending this to also support pos+scale
                -- for non-bounds transforms.
                if t_info.bounds and t_info.pos and
                   t_info.bounds.x > 0 and t_info.bounds.y > 0 then

                    local vis_w = src_w - cur_crop.left - cur_crop.right
                    local vis_h = src_h - cur_crop.top  - cur_crop.bottom

                    if vis_w > 0 and vis_h > 0 then
                        local scale_x  = t_info.bounds.x / vis_w
                        local scale_y  = t_info.bounds.y / vis_h
                        local ind_x    = t_info.pos.x + ((mx - cur_crop.left) * scale_x) - (cache.ind_size / 2)
                        -- Divisor is tighter than the /2 used for X because the "●" glyph's
                        -- visual center sits above the geometric center of its GDI+ text
                        -- bounding box; 1.35 was hand-tuned to visually center the dot.
                        local ind_y    = t_info.pos.y + ((my - cur_crop.top)  * scale_y) - (cache.ind_size / 1.35)

                        if obs.vec2 and obs.vec2_set then
                            local pos = obs.vec2()
                            obs.vec2_set(pos, ind_x, ind_y)
                            obs.obs_sceneitem_set_pos(pointer_item, pos)
                            obs.obs_sceneitem_set_visible(pointer_item, true)
                        end
                    end
                end
            end
        end
    else
        local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_CirclePointer")
        if pointer_item then
            obs.obs_sceneitem_set_visible(pointer_item, false)
        end
    end

    if p_source then obs.obs_source_release(p_source) end
    obs.obs_source_release(current_scene_source)
end