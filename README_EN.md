# VEVE_FLOW_VR — Use HTC VIVE Flow as a SteamVR headset

[简体中文](README.md) | **English**

The PC runs SteamVR; the picture is encoded to H.264 by the GPU's hardware encoder (NVIDIA NVENC / AMD AMF) and streamed over Wi-Fi to the VIVE Flow; the Flow sends head pose and both hands back to the PC.

> This repository is a fork of [`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR) (branch `_AMD`). It adds **AMD AMF encoding support**, **one-command setup scripts**, and a **VR video mode**; everything else comes from the original author.

---

## The 30-second version

In one sentence: it turns a headset that can only run FlowOS mini-apps into a **wireless seated PCVR display with hand controllers**.

**It can:**

| Capability | Notes |
|---|---|
| Run the entire SteamVR library | The driver makes SteamVR treat the Flow as a headset display |
| Play VR video (DeoVR etc.) | **The best fit**: 180°/360° video only needs head rotation |
| Use the PC desktop in the headset | Desktop+ panel, plus a 1:1 "sharp desktop" layer |
| Use both hands as Index controllers | Pinch = Trigger, fist = Grip, with per-finger curl |
| Numeric keypad fills in buttons | Joystick, A/B, menu (a head-aimed laser when hands aren't visible) |
| PC audio into the headset | Default output device loopback, 48 kHz stereo |
| Seated VR games | Racing, flight, space, seated Unity/Unreal titles |

**It cannot / hasn't yet:**

| Limitation | Why |
|---|---|
| **Currently 3DoF rotation only** | **Not a hardware limit**: the Flow's official spec is inside-out **6DoF** headset tracking via two cameras; it's this project whose app requests head-origin poses (so position is always the origin). Enabling 6DoF is roadmap item #1 |
| Replace a Quest-class 6DoF standalone | Even with 6DoF on, compute, thermals and ecosystem gaps remain |
| Match native PC image quality | The picture is sampled twice, so small text is soft (except the "sharp desktop" layer, which is 1:1) |
| Keep working off-head | The Flow force-sleeps ~5 s after the proximity sensor says "not worn" (dev mode bypasses it, but hand tracking dies) |
| Work out of the box | You have to build it yourself |

---

## Quick start

### 1. Prerequisites

**Hardware**: HTC VIVE Flow + USB-C cable; a Windows 10/11 PC with a discrete GPU (NVIDIA or AMD — the encoder ships with the driver, no SDK needed); PC and Flow on the same Wi-Fi segment (wired PC strongly recommended — it is the single biggest experience factor); optional USB numeric keypad.

**Software** (you install these yourself; the scripts can't):

| Software | Requirement |
|---|---|
| Steam + SteamVR | — |
| Desktop+ (free on Steam, app 1494460) | Not needed if you only watch VR video |
| Visual Studio 2022 or newer (2026 works) | With "Desktop development with C++" |
| CMake ≥ 3.15 | 4.2+ recommended with VS 2026; older CMake falls back to the VS-bundled one automatically |
| Android Studio | Provides the Android SDK and adb |
| Android NDK **21.4.7075529** | Exactly this version (install via SDK Manager) |
| JDK **8** | A full JDK (`javac`); set `JAVA_HOME`, or unpack to `tools\jdk8\<any-name>\` |
| HTC Wave Native SDK **4.5.0** | See below |

**Wave SDK** (not in this repo for licensing reasons): download **Wave Native SDK 4.5.0** from [developer.vive.com](https://developer.vive.com) (login required), copy the archive's `repo` folder into `Wave_Native_SDK\repo`, and confirm `Wave_Native_SDK\repo\com\htc\vr\wvr_client\4.5.0-u02\wvr_client-4.5.0-u02.aar` exists.

Why pinned to NDK 21.4 / JDK 8: the Flow APK inherits the Wave SDK sample's Gradle 5.6.1 + AGP 3.5 combination, which only accepts JDK 8, and the NDK version is written into the sample's build settings. The first APK build needs network access for dependencies.

### 2. Install (run each once)

```powershell
git clone <repo> VEVE_FLOW_VR
cd VEVE_FLOW_VR

# PC side: build + register the driver + firewall (headset not needed)
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1

# Headset side: plug the Flow in over USB, enable USB debugging, wear it once to allow the prompt
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1
```

- VR video only: `setup-pc.ps1 -Video` (skips Desktop+, 120 Mbit/s, no idle standby)
- Not sure the toolchain is complete: `setup-pc.ps1 -Check` (check-only; lists what's missing and how to install it; exit code 0 when ready)
- Both steps in one: `scripts\setup.ps1 [-Video]`
- A shorter "how many manual steps" checklist lives in **SETUP.md**

Uninstall (removes the driver and helper registrations; keeps Desktop+):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1 [-RestoreSettings] [-RemoveApk]
```

`-RestoreSettings` restores the pre-install settings backups (`*.bak-veve`); `-RemoveApk` also uninstalls the headset app.

### 3. Daily use

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
```

It starts SteamVR and the headset app in the right order and watches the driver log to confirm the connection. Manually: start SteamVR from Steam, then open **Flow Probe** on the Flow.

About 1.5 s after connect, the Desktop+ tab opens and shows your PC desktop; starting a game closes the dashboard, returning to SteamVR Home reopens it.

---

## Troubleshooting first

| Symptom | Cause / fix |
|---|---|
| **Solid grey #4F5A64 in games, PC window fine** | SteamVR thinks tracking is lost: seated games need a "seated zero pose". The helper sets it automatically (details below); if that fails, use the SteamVR menu's "reset seated position" |
| Picture all black, no stream | The GPU encoder never started — check the logs (details below) |
| Flow never connects | Firewall blocking `vrserver.exe`, or the two devices are on different subnets (the most common cause) |
| "Select USB mode" in the middle of the view | A Flow system prompt while USB is attached; pick "no action" or unplug USB |
| Game dimmed, low resolution, frozen | The dashboard is still open and stealing input focus; press keypad `*` to close it |
| Only SteamVR Home, no desktop | Press `*` to open the dashboard; or take the headset off and put it back on |

### Details: the grey screen #4F5A64 (seated zero pose)

Seated-mode games (Unity's default) need the seated zero pose of the tracking universe, or SteamVR fades the view to its grey `trackingLossColor`. The driver puts the devices in tracking universe "FLOW", and the helper sets the seated origin automatically after the Flow connects (retrying every 2 s for up to a minute while it's invalid). Check the helper log `pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.log`:

| Log line | Meaning |
|---|---|
| `seated zero pose is set` | Seated origin ready; if a game is still grey, restart the game |
| `seated zero pose was not set: reset it ...` | Auto-fix ran once — normal |
| Not even `Flow connected` | The helper isn't running: with SteamVR up, run `flow_dashboard_helper.exe --install` once, or re-run `install.ps1` |
| `still invalid after 60 s` | Auto-fix failed; use the SteamVR menu's "reset seated position" |

### Details: black picture / no stream (encoder)

Check `Steam\logs\vrserver.txt` (or the driver log `...\dist\flowvr\logs\flow_virtual_display_trace.log`):

- `Flow virtual display: <NVENC/AMF> encoder on <GPU name>` → encoder is fine, look at the network next;
- `FLOWH264 encoder initialize failed: ...` → contains the NVENC/AMF failure reason; set `flowvr_display.video_encoder` to `nvenc` or `amf` explicitly to rule out auto-detection;
- On AMD, look at the `Flow AMF` diagnostic lines (NV12 conversion, SPS/PPS, dropped frames).

In order: firewall (allow `vrserver.exe` on private networks, or re-run `setup-pc.ps1` as administrator to add the rules) → same subnet → wear the headset (no pose from the Flow means "not connected"). Diagnostic: `setup-flow.ps1 -Launch` tells you plainly whether it connected.

### Details: build problems

- **Run `setup-pc.ps1 -Check` first**: it tells you what's missing, where, and how to install it — faster than checking by hand.
- **Gradle download times out** (`services.gradle.org` unreachable): use a mirror (byte-identical to the official file; sha256 `f6ea7f48e2823ca7ff8481044b892b24112f5c2c3547d4f423fb9e684c39f710`):

  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -GradleDistributionUrl https://mirrors.cloud.tencent.com/gradle/gradle-5.6.1-all.zip
  ```

  or point at a local file: `-GradleDistributionUrl file:///D:/downloads/gradle-5.6.1-all.zip`. To revert: `git checkout -- Wave_Native_SDK/samples/wvr_flow_probe/gradle/wrapper/gradle-wrapper.properties`.
- **`Could not resolve ...`**: the distribution downloaded but the Maven repos are unreachable → set a proxy and re-run: `$env:HTTPS_PROXY = 'http://127.0.0.1:7890'`
- **`cmake not found`**: the scripts automatically use the CMake bundled with VS/Build Tools; if there really is none, `winget install Kitware.CMake`.
- **`could not find any instance of Visual Studio`**: with VS in a non-default folder or Build Tools only, CMake's own probe fails; the scripts pass the vswhere-found instance straight to CMake (`-DCMAKE_GENERATOR_INSTANCE`) — no need to reinstall.
- **`the version field is not 4 integer components starting in 17`**: VS 2026 (v18) with the 2022 generator. The scripts pick the generator from the vswhere-reported version automatically (17 → `VS 2022`, 18 → `VS 2026`).
- **Driver build fails (file locked)**: quit SteamVR first.
- **`JDK 8 not found`**: `JAVA_HOME` points at a JRE, or the version isn't 1.8 (needs `bin\javac.exe`).
- **`Wave SDK missing`**: `Wave_Native_SDK\repo\com\htc\vr\wvr_client` doesn't exist (see "Quick start").
- **Desktop+ settings reverted**: Desktop+ rewrites its config on exit; quit SteamVR before editing, or just re-run `install.ps1`.

### Moving the repo to another drive

The code has no hard-coded paths, but **build outputs and registrations store absolute paths**, so reinstall after moving:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1     # 1) unregister the old path first
# 2) quit SteamVR, move the folder
# 3) delete old outputs: pc\*\build, wvr_flow_probe\app\build, .cxx, .gradle, local.properties
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1      # 4) rebuild and re-register
```

`tools\jdk8` and `Wave_Native_SDK\repo` live in the repo and move with it; firewall rules store absolute paths and are updated automatically on re-run. A shorter path (e.g. `D:\VEVE_FLOW_VR_AMD`) is actually safer (Windows' 260-character path limit).

---

## Daily use details

1. Flow and PC on the same Wi-Fi; no USB needed.
2. Start SteamVR (SteamVR Home, Desktop+ and the helper come up with it).
3. Open **Flow Probe** on the Flow; ~1.5 s after connect you see the PC desktop.
4. Starting a game closes the dashboard; exiting the game (back to Home) reopens it. Taking the headset off and back on also reopens it.
5. Clicking the laser outside the panel closes the dashboard: press `*` to bring it back.

### Pointer gating (while the dashboard is open)

If the laser followed the head/hands all the time, Desktop+'s cursor would wander — so **the laser stays off the panel normally** (the physical mouse works as usual); it only appears while a keypad key or pinch/fist is held, and the click is sent ~0.2 s later. A white reticle marks where the click lands (only while hand detection is off). No effect in games. Implementation: `flow_pointer_gate.h`.

### Hand tracking (two Index controllers)

The Flow's cameras track both hands (26 joints each); the driver turns them into SteamVR Valve Index controllers:

| Gesture / key | Index controller |
|---|---|
| Thumb-to-index pinch | Trigger (firm pinch = click) |
| Fist | Grip (a fist also raises pinch, so Trigger fires along) |
| Per-finger curl | Finger curl (`/input/finger/*`) |
| Keypad arrows / + − while the right hand is tracked | Right joystick |
| 　Enter / `/` / `*` | A / B / System |
| 　5 / 0 | Trigger / Grip (merged with the gestures) |

Hands are lost when they leave the cameras' view; a controller disconnects only after 3 s without tracking, to survive brief occlusions. Tune the laser pitch with `hand_pitch_offset_deg`.

### Numeric keypad (only while SteamVR runs)

While the right hand isn't tracked, the keypad is a standalone right-hand controller (aim with your head, press to click):

| Key | VR controller | Key | VR controller |
|---|---|---|---|
| 5 | Trigger (hold = drag) | 4 / 6 | Trackpad left / right |
| 0 / Ins | Grip (back) | * | System (toggle dashboard) |
| Enter | Trackpad click | / | Menu (game menu) |
| + / 8, − / 2 | Trackpad up / down (scroll) | | |

**NumLock toggles hand tracking**: off = the Flow's hands are ignored and the keypad stays the head-aimed laser. In the dashboard: **reticle shown = hand tracking off, no reticle = on**. While SteamVR runs, keypad keys never reach the PC (only the keypad's ← key passes through).

### Sharp desktop (the Desktop+ panel as a 1:1 layer)

The streamed picture is sampled twice on the Flow, so small text blurs; the Flow's own system UI uses compositor layers, sampled only once. So the helper encodes the Desktop+ panel's texture separately (TCP 8005), and the Flow shows it as a Wave cylinder layer exactly over the panel:

- The panel itself is tinted black (the streamed picture lags the head by ~55 ms; without the tint the blurry copy would peek out when you turn). **Don't use transparency instead** (a panel with alpha 0 stops accepting clicks).
- Streaming pauses while the dashboard is closed (press `*` and it's instantly sharp again); the panel regains its color when the Flow disconnects.
- **Limit**: the Flow has only one spare layer pair (4 layers total across both eyes), so only one Desktop+ overlay can be sharp at a time.

### Audio

Windows default output device loopback → 48 kHz 16-bit stereo PCM → TCP 8004 → the Flow plays it; the PC speakers keep working. Toggle: `driver_flowvr.enable_audio`.

---

## In depth

### How it works (data flow)

```
┌──────────────────────────── PC (Windows) ────────────────────────────┐          ┌───── VIVE Flow ──────┐
│ SteamVR ── driver_flowvr.dll                                         │          │ Flow Probe APK       │
│             ├ HMD: projection/IPD = Flow measurements, pose from     │◄─ UDP ───┤  ├ sends head pose+seq│
│             │   Flow (UDP 8002); tracking universe "FLOW"            │          │  ├ sends hand joints  │
│             ├ virtual display: Present → GPU scale → [encode thread]─┼─ TCP ──► │  │  +pinch            │
│             │   NVENC/AMF, FLOWH264 v7, 3200×1600 @75, each frame    │  8001    │  ├ MediaCodec decode  │
│             │   carries the "pose sequence it was rendered with"     │          │  ├ half image per eye │
│             ├ keypad controller ◄─ UDP 127.0.0.1:8003                │          │  └ submits with the  │
│             └ Index controllers ×2: Flow hand tracking; the right    │          │     render pose to   │
│               one also merges keypad input                           │          │     Wave timewarp    │
│ flow_dashboard_helper.exe (auto-started by SteamVR)                  │          └──────────────────────┘
│   ├ opens the Desktop+ tab on Flow connect / game exit; closes it    │
│   │  when a game starts; sets the seated zero pose if missing        │
│   ├ captures the numeric keypad and forwards it to the driver        │
│   └ sharp desktop: Desktop+ panel texture → NVENC/AMF ──────────────┼─ TCP ──► compositor layer
│ Desktop+ (free Steam tool): shows the main monitor "only in a        │  8005
│ Desktop+ tab"                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### The five connections

| Connection | Direction | Content |
|---|---|---|
| TCP 8001 | PC → Flow | Main H.264 picture (FLOWH264 v7, appendix A) |
| UDP 8002 | Both ways | Flow → PC: pose, hands; PC → Flow: discovery broadcast `FLOWH264_PC <port>` |
| UDP 127.0.0.1:8003 | Helper → driver | Keypad buttons, panel pose/curvature, dashboard state (localhost only) |
| TCP 8004 | PC → Flow | Audio (`FLOWAUD1` + 48 kHz stereo PCM) |
| TCP 8005 | Helper → Flow | Sharp desktop layer (FLOWH264 v4, mono) |

**The Flow never needs the PC's IP**: the PC broadcasts on UDP 8002; the Flow connects to TCP 8001 and learns the PC's address from that connection's source. The only requirement is one shared subnet the broadcast can cross.

### Latency

Round trip ≈ **55 ms**. Head rotation is compensated by Wave's timewarp using "the pose the frame was rendered with" (the sequence rides along on every frame), so turning feels immediate; translation isn't compensated (there is none anyway).

### GPUs and encoders (NVENC / AMF)

| Backend | Platform | Input | Behaviour |
|---|---|---|---|
| `flow_nvenc_encoder.cpp` | NVIDIA (`nvEncodeAPI64.dll`, ships with the driver) | BGRA directly | Synchronous: the call returns the frame you just submitted |
| `flow_amf_encoder.cpp` | AMD Radeon (`amfrt64.dll`, ships with the driver) | NV12 only, so every frame gets a GPU-side BT.709 limited-range conversion first | **One extra frame of pipeline delay** (AMF hardware behaviour) |

`flowvr_display.video_encoder` = `auto` (default) / `nvenc` / `amf`; `auto` picks by GPU vendor and falls back to the other backend with a log line if initialization fails, so swapping cards needs no settings change. `video_encoder_preset` (1–7) covers both: NVENC P1…P7; AMF maps to speed / balanced / quality. Both run ultra-low-latency settings (no B-frames, no pre-analysis, no frame skipping).

The AMD frame delay: the packet's own PTS is used to look up that frame's pose sequence and source slot, so timewarp and the quality diagnostics stay correct; the cost is ≈ 13 ms more encode latency. AMF's output timestamps are unreliable (FFmpeg keeps its own queue too), so packets are paired by submission order.

To confirm which backend is actually in use, see `Steam\logs\vrserver.txt`:

```
Flow virtual display encoder 100 Mbit/s, backend auto, preset 4
Flow virtual display: AMF encoder on <GPU name> (vendor 0x1002)
```

### Settings reference

`pc\flow_steamvr_driver\flowvr\resources\settings\default.vrsettings` — **rebuild** after editing (`build.ps1` copies it into `build\dist\`), then restart SteamVR.

#### `driver_flowvr`

| Key | Default | Notes |
|---|---|---|
| `enable` | `true` | Driver master switch |
| `serial_number` / `model_number` | `VIVEFLOW-STEAMVR-001` / `HTC VIVE Flow` | Shown in SteamVR |
| `enable_keypad_controller` | `true` | Numeric keypad controller (right hand) |
| `enable_hand_controllers` | `true` | Hand tracking → Index controllers |
| `enable_audio` | `true` | PC audio to the Flow |
| `enable_desktop_layer` | `true` | Sharp desktop layer (TCP 8005) |
| `desktop_bitrate_mbps` / `desktop_fps` | `30` / `60` | Sharp desktop bitrate / frame rate |
| `hand_pitch_offset_deg` | `0.0` | Hand laser pitch trim (degrees) |

#### `flowvr_display`

| Key | Default | Notes |
|---|---|---|
| `window_x` / `window_y` | `0` / `0` | Virtual display position on the desktop |
| `window_width` / `window_height` | `3200` / `1600` | Virtual display resolution (side-by-side) |
| `render_width` / `render_height` | `1600` / `1600` | SteamVR per-eye render resolution |
| `stream_width` / `stream_height` | `3200` / `1600` | Picture size sent to the Flow |
| `video_encoder` | `auto` | `auto` / `nvenc` / `amf` |
| `video_encoder_preset` | `4` | 1 (fastest) – 7 (best), shared; legacy key `nvenc_preset` still works |
| `stream_bitrate_mbps` | `100` | Main picture bitrate; the Flow's decoder tops out around 120 |
| `tan_left` / `tan_right` | `-1.0639` / `1.0639` | FOV (measured on the Flow, ≈ 94°). **Wrong values distort the aspect** |
| `tan_top` / `tan_bottom` | `1.0639` / `-1.0639` | Same (vertical) |
| `ipd_meters` | `0.0605` | IPD (Flow measures 60.5 mm) |
| `vsync_to_photons` | `0.011` | Photons latency compensation (seconds) |
| `display_frequency` | `75` | Panel refresh rate (Hz) |

### Other settings

| Setting | Where | Applied by |
|---|---|---|
| Flow hand tracking (on by default) | `FLOW_DEFAULT_HANDS` in `hellovr.cpp`; live toggle `adb shell setprop debug.flow.hands 0/1` | APK or setprop |
| Flow eye buffer 1600, sharpening | the `FLOW_*` block at the top of `hellovr.cpp` | `build.ps1` + `install.ps1` |
| Desktop+ 248 cm size, 22 cm down, curvature 33, only-in-tab | `$DesktopPlusOverlay` at the top of `install.ps1` | `install.ps1` |
| SteamVR overlay quality High, 10-minute idle standby | `$SteamVRSettings` at the top of `install.ps1` | `install.ps1` |
| Video mode (sharp desktop off, 120 Mbit/s, 24-hour standby) | `setup-pc.ps1 -Video` | re-run the script (again after rebuilds) |

### Dev mode (testing without wearing the headset)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1        # on
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1 -Off   # off
```

Cover the proximity sensor inside the nose bridge (or wear the headset); once the script sees "worn", it freezes the sensor events so the Flow stops sleeping. Head tracking keeps working, **but hand tracking dies**. Reverted by a Flow reboot. Also stretches SteamVR's idle standby from 10 to 30 minutes.

### Fallback mode (stream the desktop without SteamVR)

Only for proving "can the PC desktop reach the Flow at all": `pc\flow_desktop_streamer\` (.NET + Python) and the scripts under `wvr_flow_probe\tools\` grab the desktop with ffmpeg and send it straight to TCP 8001. No pose feedback, controllers, audio, or sharp desktop. `--encoder` accepts `x264` / `nvenc` / `amf` / `qsv` / `mf`.

---

## Known limitations

- **Currently 3DoF only** (not a hardware limit): the Flow itself is a 6DoF machine (official spec: inside-out 6DoF headset tracking via two cameras; the manifest declares `3,6DoF`; Wave poses carry `is6DoFPose`), but the app takes poses with `WVR_PoseOriginModel_OriginOnHead`, so position is always the origin, and the driver adds a fixed 1.0 m standing-height offset. See roadmap item #1 for how to enable it. Until then the best fits are video and seated games.
- Small text is soft; mitigated mainly by enlarging the Desktop+ panel (currently 248 cm) and the sharp-desktop layer.
- ≈ 55 ms round-trip latency; rotation is timewarp-compensated, translation isn't.
- The keypad's ← (Backspace) is indistinguishable from the main keyboard's, so it isn't captured.
- Only one sharp overlay at a time (the Flow has a single spare layer pair).
- No finger skeleton yet (`/input/skeleton`): games show the Index controller model without finger motion.
- Joystick only via the keypad; no gesture equivalent.
- **The AMD (AMF) path adds about one frame (≈ 13 ms) of encode latency** (hardware pipeline delay); pose matching and quality diagnostics stay frame-aligned. The AMF path was debugged on an RX 9070 XT, where "the encoder reads an empty surface and emits pure black frames" was fixed (the driver now creates the NV12 texture with `D3D11_BIND_VIDEO_ENCODER` and lets AMF wrap it). If your picture is still black, look at the `Flow AMF` lines in `vrserver.txt`.
- The Flow sleeps ~5 s after removal and can't be changed permanently without root (the timeout lives in the OEM service's database, which needs a system signature); use dev mode when needed (reverts on reboot).

## Roadmap

- Finger skeleton: turn the Flow's 26 joints into an OpenVR hand skeleton so Half-Life: Alyx, VRChat etc. show fingers.
- Flow thermals and throttling with hand tracking on for long sessions (only minutes tested so far).
- More simultaneous buttons: either more gestures (thumb touching index/middle/ring = Trigger/A/B), or a Bluetooth gamepad in each hand (buttons/sticks from the gamepad, position from hand tracking — first test whether the Flow still tracks hands holding gamepads), or both.
- **Enable 6DoF (hardware already supports it; top priority)**: the Flow's official spec is inside-out 6DoF headset tracking via two cameras, the manifest declares `NumDoFHmd = "3,6DoF"`, and Wave poses carry `is6DoFPose` (log `hmdDoF=3|6`). What it takes: the app switches the origin model from `OriginOnHead` to `OriginOnGround` (or tracking observer) and passes x/y/z through (the `PosePacket` fields already exist); the driver drops the fixed 1.0 m standing-height offset in favor of the measured height; then drift and tracking-loss recovery get measured in practice. First step: change only the origin model, walk a few steps, and watch `hmdDoF` / `hmdXYZ` in `adb logcat -s FlowProbe`.
- Simplify the build toolchain (NDK/JDK upgrade).

---

## Appendix A: wire protocol (FLOWH264 v7)

Cross-checked between `virtual_display_device.cpp` (PC sender) and `MainActivity.java` (Flow parser); **the Flow parser is the single source of truth**. All integers are **big-endian**; floats are stored as their IEEE-754 bit pattern.

### Main picture stream (TCP 8001)

One stream header right after connect:

| Field | Type | Notes |
|---|---|---|
| magic | `char[8]` | `FLOWH264` |
| version | u32 | currently `7` |
| width / height | u32 | stream size (3200×1600) |
| fps | u32 | 75 |
| layout | u32 | since v4: `1` = side-by-side stereo (main), `0` = mono (sharp desktop) |
| sps_size + sps | u32 + bytes | H.264 SPS |
| pps_size + pps | u32 + bytes | H.264 PPS |

Then one record per **VCL NAL** (type 1–5), fixed 92-byte header:

| Field | Type | Notes |
|---|---|---|
| size | u32 | NAL byte count |
| pts_us | i64 | frame source timestamp (µs) |
| encoded_ready_ms | i64 | encode completion (epoch ms) |
| send_start_ms | i64 | send start (epoch ms) |
| pose_sequence | u32 | since v5: the head-pose sequence this frame was rendered with (0 = no new pose) |
| panel[15] | u32 ×15 | v6/v7: `[0]` flags (0 = hidden), `[1..12]` 3×4 transform, `[13]` width, `[14]` curvature (v7) |
| nal | bytes | the NAL itself |

Version history: v4 added `layout`; v5 the pose sequence; v6 the panel; v7 its curvature.

### Sharp desktop (TCP 8005)

Same `FLOWH264` magic with `version = 4`, `layout = 0`; each record: u32 size (including the start code), i64 pts_us, i64 encoded_ms, i64 send_start_ms, frame (`00 00 00 01` + NAL), i64 send_end_ms (**after** the frame).

### Audio (TCP 8004)

20-byte header: `FLOWAUD1` (8) + u32 version + u32 sample rate + u32 channels; then a continuous 16-bit stereo PCM stream.

### Pose and hands (UDP 8002, Flow → PC)

`PosePacket` (36 bytes, little-endian): u32 magic `0x31504C46` (`FLP1`), u32 sequence (per frame; the same sequence that rides on each 8001 frame), x/y/z (f32), qx/qy/qz/qw (f32).

`HandPacket` (644 bytes): u32 magic `0x31484C46` (`FLH1`), u32 sequence, `valid[2]`, `reserved[2]`, `pinch[2]`, `joints[2][26][3]` (26 joints per hand, meters).

### Discovery (UDP 8002, PC → Flow)

Plain-text broadcast `FLOWH264_PC <port>` (port = 8001), repeated until the Flow connects.

---

## Appendix B: file map

| File | Role |
|---|---|
| `scripts/setup-pc.ps1`, `setup-flow.ps1`, `setup.ps1` | One-command deployment: PC side / headset side / both |
| `scripts/setup-common.ps1` | Shared helpers for the one-command scripts |
| `scripts/build.ps1`, `install.ps1`, `uninstall.ps1` | The workers: build, register/configure, unregister |
| `scripts/dev-awake.ps1` | Dev mode (Flow stays awake + 30-minute SteamVR idle) |
| `SETUP.md` | The condensed manual-steps checklist |
| `pc/flow_steamvr_driver/src/hmd_driver_factory.cpp`, `device_provider.cpp` | Driver entry points |
| `hmd_device_driver.cpp` | The HMD device: projection/IPD, pose, tracking universe "FLOW" |
| `virtual_display_device.cpp` | **The core**: virtual display, Present scaling, encode thread, TCP 8001, discovery, quality diagnostics |
| `flow_video_encoder.{h,cpp}` | Encoder abstraction: vendor detection, `auto` selection and fallback |
| `flow_nvenc_encoder.{h,cpp}` / `flow_amf_encoder.{h,cpp}` | NVIDIA NVENC / AMD AMF backends |
| `hand_controller.cpp` | Hand joints → Index controllers |
| `keyboard_mouse_controller.cpp` | Numeric keypad → VR controller |
| `flow_pointer_gate.h` | Pointer gating |
| `flow_shared_input.h` / `flow_pose_sync.h` | Shared input state / pose sequence and constants |
| `flow_audio_streamer.cpp` | Windows loopback capture → TCP 8004 |
| `pc/flow_dashboard_helper/main.cpp` | Dashboard auto open/close, seated zero pose, keypad capture, panel pose |
| `desktop_layer_streamer.cpp` | Sharp desktop: Desktop+ texture → encode → TCP 8005 |
| `Wave_Native_SDK/samples/wvr_flow_probe/.../MainActivity.java` | Flow side: discovery, TCP, two MediaCodecs, AudioTrack |
| `.../jni/hellovr.cpp` | Flow side: Wave session, eye rendering, layers, reticle, pose/hand reporting |
| `flowvr/resources/input/*.json` | SteamVR input bindings |
| `flow_probe/` | Hardware dumps from the Flow (reference only; files with serial numbers are not published) |

## Appendix C: files and install locations

> Don't want to memorize this? Run `scripts\setup-pc.ps1 -Check` — it prints every item's actual path.

**The two things you place yourself** (both in `.gitignore`; place them again after a fresh clone):

| Item | Where |
|---|---|
| The Wave SDK's `repo` | `<repo>\Wave_Native_SDK\repo\` |
| JDK 8 | point `JAVA_HOME` at it, or unpack to `<repo>\tools\jdk8\<any-name>\` |

**Found by the scripts**: Visual Studio (vswhere), Android SDK (`ANDROID_SDK_ROOT` → `ANDROID_HOME` → `%LOCALAPPDATA%\Android\Sdk`), the NDK (must be at `<SDK>\ndk\21.4.7075529\`), SteamVR (`openvrpaths.vrpath`), Desktop+ (`libraryfolders.vdf`). **Fetched by git**: `pc\openvr` (submodule), `pc\third_party` (NVENC/AMF headers, already in the repo).

**Build outputs** (all in `.gitignore`):

| Output | Path |
|---|---|
| SteamVR driver (the registered directory) and its logs | `pc\flow_steamvr_driver\build\dist\flowvr\` (`logs\`) |
| Helper and its log | `pc\flow_dashboard_helper\build\dist\` |
| Flow APK | `Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk` |

**Logs and backups**: SteamVR main log `<SteamVR>\logs\vrserver.txt`; helper log `flow_dashboard_helper.log`; settings backups `steamvr.vrsettings.bak-veve`, Desktop+ `config.ini.bak-veve`.

### Diagnostic tools

- Driver log `...\dist\flowvr\logs\flow_virtual_display_trace.log`: a `stream stats` line every 2 s (Present rate, encode time, send rate)
- What SteamVR actually outputs: create an empty `dump_preview.request` in `logs\` → `flow_compositor_preview.ppm`
- The Flow's screen: `adb exec-out screencap -p > flow.png` (very dark; stretch the contrast)
- Flow log: `adb logcat -s FlowProbe vrsample` (`stream rates`, `timewarp poseAge`; 1 step ≈ 13.3 ms)
- Live sharpening: `adb shell setprop debug.flow.sharpen 0.8` (0–2, 0 = off)
- Quality diagnosis: create `dump_stream.request` → `flow_stream_input.ppm` (encoder input) + `flow_stream_dump.h264` (the next second; decode the last frame with ffmpeg and compare); `debug.flow.dumpeye` → the Flow writes its eye buffer `files/flow_eye_left.ppm`
- Layer A/B test: `debug.flow.layertest 1` (same image to both eyes, one via eye buffer, one via layer)
- Audio: SteamVR log `Flow audio: ...`; the Flow log's `audio` lines (`queuedMs`, silence-insertion counts)
- Hands: SteamVR log, a `Flow hand ...` line every 2 s; the Flow log's `hands` lines

---

## Appendix D: license and credits

- Upstream project: [`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR) (the design, driver, Flow app, sharp desktop and hand tracking are all that author's work); this fork adds AMD AMF support, the one-command setup scripts and the VR video mode.
- `pc/openvr/`: Valve OpenVR SDK (submodule).
- `pc/third_party/nv-codec-headers/`: NVENC API headers; `pc/third_party/amf/`: GPUOpen AMF headers (MIT).
  **Note**: neither license grants patent rights for media technologies such as H.264; anyone distributing an encoder handles the royalties themselves.
- `Wave_Native_SDK/`: HTC Wave SDK under the VIVE SDK License Agreement, **not included in this repository**.

The Flow app and driver file headers keep the copyright notices of the Valve / HTC samples they were built from.
