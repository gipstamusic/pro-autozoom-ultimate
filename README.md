<div align="center">

<img src="assets/icon.png" width="100" height="100" alt="Pro AutoZoom icon" style="border-radius:20px">

# Pro AutoZoom — Ultimate Community Edition

**The cinematic mouse-tracking zoom engine for OBS Studio.**
Your camera follows your mouse. Automatically. No editing needed.

[![Version](https://img.shields.io/badge/version-1.0-7c5cfc?style=for-the-badge&labelColor=111118)](https://github.com/gipstamusic/pro-autozoom-ultimate/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-34d399?style=for-the-badge&labelColor=111118)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-60a5fa?style=for-the-badge&labelColor=111118)](https://github.com/gipstamusic/pro-autozoom-ultimate/releases/latest)
[![OBS](https://img.shields.io/badge/OBS-29%2B%20%26%2030%2B-fbbf24?style=for-the-badge&labelColor=111118)](https://obsproject.com)

[⬇ Download v1.0](https://github.com/gipstamusic/pro-autozoom-ultimate/releases/latest) &nbsp;·&nbsp;
[📖 Help Guide](help.html) &nbsp;·&nbsp;
[🐛 Report a Bug](https://github.com/gipstamusic/pro-autozoom-ultimate/issues)

</div>

---

![Pro AutoZoom settings panel](assets/screenshot.png)

---

## What is this?

Pro AutoZoom is a free, open-source **Lua script for OBS Studio** that zooms and pans your screen recording in real time to follow your mouse cursor — like a camera operator automatically tracking your work.

You hit a hotkey. The camera turns on. From that point, wherever your mouse goes, the camera follows — smoothly, cinematically, every frame. No post-processing, no editing, no extra software.

**Perfect for:** music producers, developers, designers, streamers, educators, and anyone creating screen recording content for YouTube, Shorts, Reels, or TikTok.

---

## Features

| | Feature | What it does |
|---|---|---|
| 🖱️ | **Real-time mouse tracking** | Smooth, lag-free camera that follows your cursor every frame |
| 🎬 | **Cinematic smoothness** | Adjustable easing, deadzone, and speed — from snappy to slow-mo cinematic |
| 🔍 | **Punch Zoom hotkey** | Hold a key to zoom in tighter; release to glide back |
| ⏸️ | **Freeze Camera hotkey** | Lock the current framing while your mouse moves elsewhere |
| 📱 | **Vertical video (9:16)** | Built-in support for Shorts, Reels, TikTok — record both formats in one take |
| 🖥️ | **Multi-monitor aware** | Auto-detects all monitors via the Windows display API |
| 🎯 | **Cursor indicator** | Optional glowing ring around your cursor, fully customisable |
| 💜 | **Aitum Vertical support** | Manual canvas override fixes the horizontal squash bug |
| ↺ | **One-click reset** | Reset any section back to factory defaults instantly |
| ∞ | **Free forever** | MIT licensed — no subscription, no watermark, no pro plan |

---

## Quick Start

**Requirements:** Windows · OBS Studio 29+ · No admin rights needed

### Install

1. Download `ProAutoZoom_v1.0_Setup.exe` from the [Releases page](https://github.com/gipstamusic/pro-autozoom-ultimate/releases/latest)
2. Run it — the installer places the script in your OBS scripts folder automatically
3. In OBS: **Tools → Scripts → +** → select `Pro_auto_zoom_ultimate_v1.0_community_edition.lua`

### Setup (takes 2 minutes)

1. **Capture Source** — pick your monitor or window capture source from the dropdown
2. **Detected Monitor** — pick the physical monitor your source is recording *(required)*
3. **Canvas Layout** — choose `Full Screen Zoom` for standard recording, or a Split layout for vertical content
4. **Hotkeys** — go to `Settings → Hotkeys`, search `Pro AutoZoom`, assign `Toggle Camera`
5. Press your hotkey and move your mouse — the camera follows

> **Full setup guide →** [help.html](help.html)

---

## Hotkeys

| Hotkey | What it does |
|---|---|
| **Toggle Camera** | Turn tracking on/off. Press once to start, press again to return to full view |
| **Hold for Detail Zoom (Punch)** | Zoom in tighter while held; glides back on release |
| **Hold to Freeze Camera** | Lock framing while held; resumes tracking on release |
| **Toggle Pointer** | Show/hide the cursor indicator ring (when set to Hotkey Triggered) |

---

## Vertical Video Setup (Aitum Vertical)

If you use **Aitum Vertical** or any plugin that creates a **separate vertical canvas**, OBS's API cannot report that canvas size — which causes the zoomed image to appear horizontally squashed.

**Fix:**
1. Under **Source & Layout**, tick **Enable Manual Canvas Override**
2. Set **Vertical Canvas Width** to `1080`
3. Set **Vertical Canvas Height** to `1920`
4. Set **Webcam Height** to your webcam strip height (e.g. `608`) — find this via right-click your webcam source → Edit Transform → Size → Height

Turn on **Debug Mode** and check the `CANVAS DIAG` line in the script log to confirm it's reading the right canvas.

---

## Settings Reference

<details>
<summary><strong>Source & Layout</strong></summary>

| Setting | Default | Description |
|---|---|---|
| Capture Source | — | The OBS source to zoom (monitor, window, or game capture) |
| Canvas Layout | Full Screen Zoom | Arrangement of your canvas — Full, Split (webcam top/bottom), or Ultrawide |
| Webcam Height (px) | 0 | Height of the webcam strip in split layouts (only shown for split layouts) |
| Enable Manual Canvas Override | Off | For separate vertical canvases (e.g. Aitum Vertical) — enter exact dimensions |

</details>

<details>
<summary><strong>Monitor & Display Settings</strong></summary>

| Setting | Default | Description |
|---|---|---|
| Detected Monitor | — | The physical monitor your capture source is recording — **required** |
| Enable Manual Monitor Override | Off | Manually enter monitor width, height, X offset, Y offset for unusual setups |

</details>

<details>
<summary><strong>Camera Engine</strong></summary>

| Setting | Default | Description |
|---|---|---|
| Enable Camera Tracking | On | Master switch — disables all hotkeys when off |
| Base Zoom Factor | 2.0 | How much the camera zooms in (1.0 = no zoom, 2.0 = 2× magnification) |
| Punch Zoom | 4.0 | Zoom level while the Punch hotkey is held |
| Smoothness | 0.12 | How quickly the camera eases to follow (lower = smoother, slower) |
| Deadzone (%) | 15 | Mouse movement near centre that doesn't move the camera — reduces jitter |
| Auto-Return to Center | Off | Camera glides back to centre after idle timeout |
| Idle Timeout (s) | 3.0 | Seconds of stillness before auto-centre triggers |
| Debug Mode | Off | Enables detailed per-frame logging to the OBS script log |

</details>

<details>
<summary><strong>Mouse Indicator</strong></summary>

| Setting | Default | Description |
|---|---|---|
| Visibility | Off | Off / Always On / Hotkey Triggered |
| Ring Color | Yellow | Colour of the cursor indicator ring |
| Ring Opacity (%) | 70 | Transparency of the ring |
| Ring Size (px) | 72 | Diameter of the ring in pixels |

</details>

---

## Troubleshooting

**Hotkey does nothing**
→ Make sure a Detected Monitor is selected and Enable Camera Tracking is ticked. Re-assign the hotkey in Settings → Hotkeys and click Apply.

**Image looks squashed/stretched**
→ You need the Manual Canvas Override. See [Vertical Video Setup](#vertical-video-setup-aitum-vertical) above.

**Camera tracks the wrong area**
→ Wrong monitor selected under Detected Monitor. Try the other one.

**Jittery camera movement**
→ Lower the Smoothness value (e.g. 0.06) and increase the Deadzone (e.g. 25%).

**Log keeps spamming lines**
→ Turn Debug Mode off. It only logs while enabled.

> Full troubleshooting → [help.html](help.html)

---

## Repository Structure

```
pro-autozoom-ultimate/
├── Pro_auto_zoom_ultimate_v1.0_community_edition.lua   # The script
├── help.html                                           # Full interactive help guide
├── README.md                                           # Readme file
├── LICENSE                                             # MIT License
└── assets/
    ├── icon.png                                        # App icon (128px)
    └── screenshot.png                                  # Settings panel screenshot
```

---

## Known Limitations

- **Windows only** — uses Windows-specific APIs for cursor and monitor detection

---

## License

MIT License — see [LICENSE](LICENSE)

Made with ❤️ by [gipstamusic](https://lnk.bio/gipstamusic)
