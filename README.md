# VEVE_FLOW_VR — 把 HTC VIVE Flow 变成 SteamVR 头盔

**简体中文** | [English](README_EN.md)

PC 跑 SteamVR，画面由显卡硬件编码器（NVIDIA NVENC / AMD AMF）编成 H.264，经 Wi-Fi 串流到 VIVE Flow；Flow 把头部姿态和双手回传给 PC。

> 本仓库是 [`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR) 的 fork（分支 `_AMD`），比上游多了 **AMD AMF 编码支持**、**一键部署脚本** 和 **VR 视频模式**；其余设计来自原作者。

---

## 30 秒了解

一句话：它把一台只能玩 FlowOS 小游戏的头显，变成**无线的坐姿 PCVR 显示器 + 手部控制器**。

**能做到：**

| 能力 | 说明 |
|---|---|
| 跑整个 SteamVR 游戏库 | 驱动让 SteamVR 把 Flow 当成一块头显屏幕 |
| 看 VR 视频（DeoVR 等） | **最合适的用途**：180°/360° 视频只需要转头 |
| 在头盔里用 PC 桌面 | Desktop+ 面板，外加一条 1:1 的“清晰桌面”图层 |
| 双手当 Index 控制器 | 捏合 = Trigger，握拳 = Grip，含各指弯曲量 |
| 数字小键盘补按键 | 摇杆、A/B、菜单键（手不在镜头前时是跟头的激光） |
| PC 声音进头盔 | 默认输出设备环回采集，48 kHz 立体声 |
| 坐姿 VR 游戏 | 赛车、飞行、太空、坐着玩的 Unity/Unreal 游戏 |

**做不到 / 还没做：**

| 限制 | 原因 |
|---|---|
| **目前只用 3DoF 旋转** | **这不是硬件上限**：Flow 官方规格就是双摄像头 inside-out **6DoF** 头显追踪；是本项目的 App 当前以头部原点取姿态（位置恒为原点）。启用 6DoF 是待办第一项 |
| 取代 Quest 之类的 6DoF 一体机 | 即使启用 6DoF，算力、散热与生态仍有差距 |
| 画质等同 PC 原生 | 画面被采样两次，小字偏软（只有“清晰桌面”图层是 1:1） |
| 摘下头盔继续用 | Flow 摘下约 5 秒强制休眠（开发模式可绕过，但手部追踪会失效） |
| 开箱即用 | 需要自己编译 |

---

## 快速开始

### 1. 准备

**硬件**：HTC VIVE Flow + USB-C 线；Windows 10/11 独显 PC（NVIDIA 或 AMD 显卡均可，编码器随驱动自带，无需另装 SDK）；PC 与 Flow 在同一 Wi-Fi（PC 建议走有线，这是体验好坏的最大变量）；可选 USB 数字小键盘。

**软件**（要自己装，脚本代劳不了）：

| 软件 | 要求 |
|---|---|
| Steam + SteamVR | — |
| Desktop+（Steam 免费，app 1494460） | 只看 VR 视频可以不装 |
| Visual Studio 2022 或更新（2026 也可） | 勾“使用 C++ 的桌面开发” |
| CMake ≥ 3.15 | VS 2026 建议 4.2+；太旧时脚本自动改用 VS 内附的 CMake |
| Android Studio | 提供 Android SDK 与 adb |
| Android NDK **21.4.7075529** | 必须这个版本（SDK Manager 里装） |
| JDK **8** | 要完整的 JDK（有 `javac`）；设 `JAVA_HOME`，或解压到 `tools\jdk8\<任意名>\` |
| HTC Wave Native SDK **4.5.0** | 见下 |

**Wave SDK**（授权原因不在仓库里）：到 [developer.vive.com](https://developer.vive.com)（需登录）下载 **Wave Native SDK 4.5.0**，把压缩包里的 `repo` 文件夹整个拷到本项目的 `Wave_Native_SDK\repo`，确认存在 `Wave_Native_SDK\repo\com\htc\vr\wvr_client\4.5.0-u02\wvr_client-4.5.0-u02.aar`。
（NDK/JDK 版本是 Wave SDK 范例的 Gradle 5.6.1 + AGP 3.5 组合钉死的；第一次建置 APK 需要网络下载依赖。）

### 2. 安装（各跑一次）

```powershell
git clone <repo> VEVE_FLOW_VR
cd VEVE_FLOW_VR

# 机器端：建置 + 注册驱动 + 防火墙（不需要插头盔）
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1

# 头显端：Flow 插 USB、开 USB 调试、戴上头盔允许一次调试授权
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1
```

- 只看 VR 视频：`setup-pc.ps1 -Video`（跳过 Desktop+，120 Mbit/s，关闲置待机）
- 不确定环境装齐没：`setup-pc.ps1 -Check`（纯检查，逐项列出缺什么、怎么装；全就绪退出码为 0）
- 两步合一：`scripts\setup.ps1 [-Video]`；精简人工清单见 **SETUP.md**

### 3. 每天用

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
```

按正确顺序拉起 SteamVR 和头显 App，并盯着驱动日志确认真的连上。手动也行：Steam 里启动 SteamVR → Flow 上打开 **Flow Probe**。

连上约 1.5 秒后 Desktop+ 分页自动打开，看到 PC 桌面。

### 卸载

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1 [-RestoreSettings] [-RemoveApk]
```

移除驱动与背景程序的注册（Desktop+ 保留）。`-RestoreSettings` 还原安装前的设置备份（`*.bak-veve`），`-RemoveApk` 连头盔上的 App 一起卸。

---

## 出问题先看这里

| 症状 | 原因 / 处置 |
|---|---|
| **进游戏整片灰色 #4F5A64，PC 窗口正常** | 坐姿游戏缺“坐姿原点”，背景程序会自动补设（详解见下）；没好的话用 SteamVR 菜单「重置坐姿位置」 |
| 画面全黑、没有串流 | GPU 编码器没起来，看日志（详解见下） |
| Flow 连不上 | 防火墙挡了 `vrserver.exe`、或两台不在同一网段（最常见） |
| 画面中央“选择 USB 模式” | Flow 插着 USB 的系统提示，选“不运行任何动作”或拔掉 USB |
| 游戏变暗、分辨率变低 | 控制台还开着抢输入焦点，按小键盘 `*` 关掉 |
| 只看到 SteamVR Home、没有桌面 | 按 `*` 打开控制台；或摘下头盔再戴上 |

### 详解：灰屏 #4F5A64（坐姿原点）

坐姿游戏（Unity 默认）需要追踪空间的坐姿原点，否则 SteamVR 把画面淡出成灰色 `trackingLossColor`。驱动给设备设了追踪空间 "FLOW"，背景程序在 Flow 连上后自动补设（无效时每 2 秒重试，最多 1 分钟）。看背景程序日志 `pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.log`：

| 日志 | 含义 |
|---|---|
| `seated zero pose is set` | 坐姿原点已就绪；游戏还灰就重启游戏 |
| `seated zero pose was not set: reset it ...` | 自动修复过，属正常 |
| 连 `Flow connected` 都没有 | 背景程序没在跑：SteamVR 运行中执行一次 `flow_dashboard_helper.exe --install`，或重跑 `install.ps1` |
| `still invalid after 60 s` | 自动修复失败，用 SteamVR 菜单「重置坐姿位置」 |

### 详解：全黑 / 没串流（编码器）

看 `Steam\logs\vrserver.txt`（或驱动日志 `...\dist\flowvr\logs\flow_virtual_display_trace.log`）：

- 有 `Flow virtual display: <NVENC/AMF> encoder on <卡名>` → 编码器正常，往下查网络；
- 有 `FLOWH264 encoder initialize failed: ...` → 里面写着 NVENC/AMF 各自的失败原因；可用 `flowvr_display.video_encoder` 明确指定 `nvenc` 或 `amf` 排除自动判断；
- AMD 卡可看 `Flow AMF` 开头的诊断行（NV12 转换、SPS/PPS、丢帧都在里面）。

依序检查：防火墙（让 `vrserver.exe` 过私有网络，或以管理员重跑 `setup-pc.ps1` 自动加规则）→ 同一网段 → 头盔要戴着（Flow 不送姿态不算连上）。诊断命令：`setup-flow.ps1 -Launch` 会直接告诉你连上没有。

### 详解：建置问题

- **先跑 `setup-pc.ps1 -Check`**：它会告诉你缺哪个、缺在哪、怎么装，比逐项手动确认快。
- **Gradle 下载超时**（`services.gradle.org` 不通）：换镜像（与官方逐字节一致，sha256 `f6ea7f48e2823ca7ff8481044b892b24112f5c2c3547d4f423fb9e684c39f710`）：

  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -GradleDistributionUrl https://mirrors.cloud.tencent.com/gradle/gradle-5.6.1-all.zip
  ```

  或指向本地下好的文件：`-GradleDistributionUrl file:///D:/downloads/gradle-5.6.1-all.zip`。想还原：`git checkout -- Wave_Native_SDK/samples/wvr_flow_probe/gradle/wrapper/gradle-wrapper.properties`。
- **`Could not resolve ...`**：发行版下来了但 Maven 仓库不通 → 设代理再跑：`$env:HTTPS_PROXY = 'http://127.0.0.1:7890'`
- **`cmake not found`**：脚本会自动找 VS/Build Tools 内附的 CMake；真没有就 `winget install Kitware.CMake`。
- **`could not find any instance of Visual Studio`** / **`the version field is not 4 integer components starting in 17`**：VS 装在非默认目录、只装了 Build Tools、或装了 VS 2026（v18）——脚本都会自动处理（按 vswhere 报的版本选生成器并把实例直接指给 CMake），不用重装或改设置。
- **建置驱动失败（文件被锁定）**：先关 SteamVR。
- **`JDK 8 not found`**：`JAVA_HOME` 指到了 JRE 或版本不是 1.8（要 `bin\javac.exe`）。
- **`Wave SDK missing`**：`Wave_Native_SDK\repo\com\htc\vr\wvr_client` 不存在（见“快速开始”）。
- **Desktop+ 设置被改回去**：Desktop+ 退出时会写回自己的设置；改之前先关 SteamVR，或直接重跑 `install.ps1`。

---

## 日常使用

1. Flow 与 PC 同 Wi-Fi，不需要 USB。
2. 启动 SteamVR（会一并拉起 SteamVR Home、Desktop+、背景程序）。
3. Flow 上打开 **Flow Probe**，连上约 1.5 秒后看到 PC 桌面。
4. 游戏开始 → 控制台自动关；游戏结束（回到 Home）→ 自动再开。摘下再戴上也会重开。
5. 激光点到面板外会关掉控制台：按 `*` 叫回来。

### 手部追踪（双手 = Index 控制器）

Flow 的镜头追踪双手（每手 26 关节），驱动转成 SteamVR 的 Valve Index 控制器：

| 手势 / 按键 | Index 控制器 |
|---|---|
| 拇指捏食指 | Trigger（捏紧 = 点击） |
| 握拳 | Grip（握拳时捏合也会升高，会顺带触发 Trigger） |
| 各手指弯曲 | 手指弯曲量（`/input/finger/*`） |
| 右手被追踪时的小键盘方向键 / + − | 右手摇杆 |
| 　Enter / `/` / `*` | A / B / System |
| 　5 / 0 | Trigger / Grip（与手势合并） |

手离开镜头视野就失去追踪；连续 3 秒没追到才断线，避免短暂遗失跳动。激光俯仰用 `hand_pitch_offset_deg` 微调。

### 数字小键盘（只在 SteamVR 运行中有效）

右手没被追踪时，小键盘是独立的右手控制器（用头对准准星，按键点击）：

| 键 | VR 控制器 | 键 | VR 控制器 |
|---|---|---|---|
| 5 | Trigger（按住 = 拖曳） | 4 / 6 | 触摸板左 / 右 |
| 0 / Ins | Grip（返回） | * | System（开关控制台） |
| Enter | 触摸板按下 | / | Menu（游戏菜单） |
| + / 8，− / 2 | 触摸板上 / 下（卷动） | | |

**NumLock = 开关手部检测**：关闭时忽略 Flow 的手，小键盘固定是跟头的激光。控制台里**有准星 = 手部检测关，没准星 = 开**。SteamVR 运行期间小键盘不会打字到电脑（只有小键盘的 ← 照常）。

### 指针门控（控制台开着时）

控制台开着时激光若一直跟着头/手，Desktop+ 的光标会乱跑，所以**平常激光不碰面板**（实体鼠标照常可用）；按住小键盘按键或捏合/握拳时激光才出现，约 0.2 秒后送点击。白色准星标出点击落点（只在手部检测关闭时显示）。游戏中不受影响。实作在 `flow_pointer_gate.h`。

### 清晰桌面（Desktop+ 面板的 1:1 图层）

串流画面在 Flow 上被采样两次，小字会糊；合成器图层只采样一次。背景程序把 Desktop+ 面板贴图单独编码（TCP 8005）送过去，以 Wave 圆柱图层 1:1 盖在面板位置：

- 面板本身被染黑（串流画面比头慢约 55 ms，不染黑转头时模糊的那份会露出来）；**不能改透明度**（alpha 0 时面板不吃点击）。
- 控制台关闭时暂停串流（按 `*` 叫回来立即清晰）；Flow 断线时面板恢复原色。
- **限制**：Flow 只有一组额外图层（两眼合计 4 层），所以同时只有一个 Desktop+ overlay 是清晰的。

### 音频

Windows 默认输出设备环回采集 → 48 kHz 16-bit 立体声 PCM → TCP 8004 → Flow 播放；PC 喇叭照常出声。`driver_flowvr.enable_audio` 开关。

---

## 已知限制

- **当前只用 3DoF**（不是硬件上限）：Flow 本身是 6DoF 机器（官网规格：双摄像头 inside-out 6DoF 头显追踪；manifest 声明 `3,6DoF`；Wave 姿态带 `is6DoFPose`），但 App 用 `WVR_PoseOriginModel_OriginOnHead` 取姿态、位置恒为原点，驱动再加固定 1.0 m 身高偏移。启用方法见待办第一项。启用前最合适的场景是看视频与坐姿游戏。
- 小字偏软，主要靠放大 Desktop+ 画面（目前 248 cm）与“清晰桌面”图层改善。
- 往返延迟约 55 ms；转头有 timewarp 补偿，平移没有。
- 小键盘的 ←（Backspace）与主键盘无法区分，不拦截。
- 清晰桌面同时只能一个 overlay（Flow 只有一组额外图层）。
- 手部控制器还没有手指骨架（`/input/skeleton`）：游戏里显示 Index 控制器模型，不会动手指。
- 摇杆只能用小键盘，手势没有对应。
- **AMD（AMF）路径比 NVENC 多约一帧（≈ 13 ms）编码延迟**（硬件管线延迟），姿态与画质诊断已按帧对齐。AMD 路径已在 RX 9070 XT 上实测并修掉了“编码器读到空表面输出纯黑帧”的问题（由驱动自建带 `D3D11_BIND_VIDEO_ENCODER` 的 NV12 纹理交给 AMF 包装）；若画面仍黑，看 `vrserver.txt` 里 `Flow AMF` 开头的行。
- Flow 摘下约 5 秒休眠，不 root 无法永久改长（秒数在 OEM 服务数据库里，写入要系统签名）；需要时用开发模式（重启失效）。

## 待办

- **启用 6DoF（硬件已支持，最优先）**：Flow 官方规格即双摄像头 inside-out 6DoF 头显追踪，manifest 已声明 `NumDoFHmd = "3,6DoF"`，Wave 姿态也带 `is6DoFPose`（日志 `hmdDoF=3|6`）。要做的是：App 把 origin model 从 `OriginOnHead` 换成 `OriginOnGround`（或 tracking observer）并把 x/y/z 透传（`PosePacket` 字段已有）；驱动去掉固定 1.0 m 身高偏移、改用实测高度；实测漂移与追踪丢失恢复。先只换 origin model 走两步，看 `adb logcat -s FlowProbe` 里的 `hmdDoF` / `hmdXYZ` 验证。
- 手指骨架：把 Flow 的 26 关节转成 OpenVR 手部骨架，Half-Life: Alyx、VRChat 等就能显示手指。
- 长时间开手部追踪时 Flow 的温度与降频（目前只测过几分钟）。
- 多键同时操作：方案一是扩手势（拇指碰食指/中指/无名指 = Trigger/A/B），方案二是两手各握一支蓝牙手把（按键摇杆来自手把，位置来自手部追踪；需先实测握着手把时 Flow 是否还追得到手），或两者并存。
- 简化建置环境（NDK/JDK 升级）。

---

<details>
<summary><b>进阶：运作原理、五条连接、编码器、设置参考、开发模式</b></summary>

### 运作原理（数据流）

```
┌──────────────────────────── PC (Windows) ────────────────────────────┐          ┌───── VIVE Flow ──────┐
│ SteamVR ── driver_flowvr.dll                                         │          │ Flow Probe APK       │
│             ├ HMD：投影/IPD = Flow 实测值，姿态来自 Flow (UDP 8002)  │◄─ UDP ───┤  ├ 送头部姿态+序号   │
│             │   追踪空间 "FLOW"；Flow 有送姿态 = 用户戴着            │          │  ├ 送双手关节+捏合   │
│             ├ 虚拟显示：Present → GPU 缩放 → [编码线程] NVENC/AMF  ──┼─ TCP ──► │  ├ MediaCodec 解码   │
│             │   FLOWH264 v7，3200×1600 @75，每帧附「渲染用姿态序号」│  8001    │  ├ 左右眼各取一半    │
│             ├ 数字键盘控制器 ◄─ UDP 127.0.0.1:8003                   │          │  └ 以渲染姿态提交给  │
│             └ Index 控制器 ×2：Flow 手部追踪；右手兼收数字键盘       │          │     Wave timewarp    │
│ flow_dashboard_helper.exe（SteamVR 自动启动）                        │          └──────────────────────┘
│   ├ Flow 连上 / 游戏结束时打开 Desktop+ 分页；游戏开始时关闭         │
│   ├ 坐姿原点未设置时补设（自动重试）；拦截数字键盘转送驱动           │
│   └ 清晰桌面：Desktop+ 面板贴图 → NVENC/AMF ────────────────────────┼─ TCP ──► 合成器图层
│ Desktop+（Steam 免费工具）：「只在 Desktop+ 分页」显示主屏幕         │  8005
└──────────────────────────────────────────────────────────────────────┘
```

### 五条连接

| 连接 | 方向 | 内容 |
|---|---|---|
| TCP 8001 | PC → Flow | 主画面 H.264（FLOWH264 v7，附录 A） |
| UDP 8002 | 双向 | Flow → PC：姿态、双手；PC → Flow：discovery 广播 `FLOWH264_PC <port>` |
| UDP 127.0.0.1:8003 | 背景程序 → 驱动 | 小键盘按键、面板位置/曲率、控制台状态（本机） |
| TCP 8004 | PC → Flow | 音频（`FLOWAUD1` + 48 kHz 立体声 PCM） |
| TCP 8005 | 背景程序 → Flow | 清晰桌面图层（FLOWH264 v4，单眼） |

**Flow 不用设 PC 的 IP**：PC 在 UDP 8002 广播，Flow 连 TCP 8001 后从连接来源得知 PC 地址。唯一要求是同一网段、广播送得到。

往返延迟约 **55 ms**。转头由 Wave timewarp 按“该帧渲染时用的姿态”补偿（序号随每帧附上），所以转头感觉不到延迟；平移本来就没有，不补偿。

### 显卡与编码器（NVENC / AMF）

| 后端 | 平台 | 输入 | 特性 |
|---|---|---|---|
| `flow_nvenc_encoder.cpp` | NVIDIA（`nvEncodeAPI64.dll`，随驱动） | 直接吃 BGRA | 同步：当次调用拿到当次帧 |
| `flow_amf_encoder.cpp` | AMD Radeon（`amfrt64.dll`，随驱动） | 只吃 NV12，每帧先在 GPU 做 BT.709 有限范围转换 | **多一帧管线延迟**（AMF 硬件特性） |

`flowvr_display.video_encoder` = `auto`（默认）/ `nvenc` / `amf`；`auto` 按显卡厂商选，失败自动改试另一家并写日志，换卡不用改设置。`video_encoder_preset`（1–7）两家共用：NVENC 是 P1…P7；AMF 映射 speed / balanced / quality。两边都跑超低延迟设置（无 B 帧、不前处理、不跳帧）。

AMD 的一帧延迟：封包自带的 PTS 回查该帧的姿态序号与来源 slot，timewarp 与画质诊断都仍正确，代价是编码延迟多约 13 ms。AMF 输出时间戳不可靠（FFmpeg 也自己维护队列），所以按提交顺序配对。

确认实际用了哪个后端，看 `Steam\logs\vrserver.txt`：

```
Flow virtual display encoder 100 Mbit/s, backend auto, preset 4
Flow virtual display: AMF encoder on <卡名> (vendor 0x1002)
```

### 设置参考

`pc\flow_steamvr_driver\flowvr\resources\settings\default.vrsettings`，改完**重新建置**（`build.ps1` 会拷到 `build\dist\`）再重开 SteamVR。

#### `driver_flowvr`

| 键 | 默认 | 说明 |
|---|---|---|
| `enable` | `true` | 驱动总开关 |
| `serial_number` / `model_number` | `VIVEFLOW-STEAMVR-001` / `HTC VIVE Flow` | SteamVR 里显示的序号 / 型号 |
| `enable_keypad_controller` | `true` | 数字键盘控制器（右手） |
| `enable_hand_controllers` | `true` | 手部追踪 → Index 控制器 |
| `enable_audio` | `true` | PC 声音串流到 Flow |
| `enable_desktop_layer` | `true` | 清晰桌面图层（TCP 8005） |
| `desktop_bitrate_mbps` / `desktop_fps` | `30` / `60` | 清晰桌面的比特率 / 帧率 |
| `hand_pitch_offset_deg` | `0.0` | 手部激光俯仰微调（度） |

#### `flowvr_display`

| 键 | 默认 | 说明 |
|---|---|---|
| `window_x` / `window_y` | `0` / `0` | 虚拟显示器在桌面上的位置 |
| `window_width` / `window_height` | `3200` / `1600` | 虚拟显示器分辨率（两眼并排） |
| `render_width` / `render_height` | `1600` / `1600` | SteamVR 每眼渲染分辨率 |
| `stream_width` / `stream_height` | `3200` / `1600` | 送给 Flow 的画面大小 |
| `video_encoder` | `auto` | `auto` / `nvenc` / `amf` |
| `video_encoder_preset` | `4` | 1（最快）–7（最好），两家共用；旧键名 `nvenc_preset` 仍有效 |
| `stream_bitrate_mbps` | `100` | 主画面比特率；Flow 解码器上限约 120 |
| `tan_left` / `tan_right` | `-1.0639` / `1.0639` | 视野（Flow 实测，约 94°）。**错了比例会不对** |
| `tan_top` / `tan_bottom` | `1.0639` / `-1.0639` | 同上（垂直） |
| `ipd_meters` | `0.0605` | 瞳距（Flow 实测 60.5 mm） |
| `vsync_to_photons` | `0.011` | 光子延迟补偿（秒） |
| `display_frequency` | `75` | 面板更新率（Hz） |

#### 其他设置

| 设置 | 位置 | 套用方式 |
|---|---|---|
| Flow 手部追踪（默认开） | `hellovr.cpp` 的 `FLOW_DEFAULT_HANDS`；即时开关 `adb shell setprop debug.flow.hands 0/1` | APK 或 setprop |
| Flow 眼睛缓冲 1600、锐化 | `hellovr.cpp` 开头的 `FLOW_*` | `build.ps1` + `install.ps1` |
| Desktop+ 大小 248 cm、下移 22 cm、曲率 33、只在 Desktop+ 分页 | `install.ps1` 开头 `$DesktopPlusOverlay` | `install.ps1` |
| SteamVR overlay 质量 High、闲置 10 分钟待机 | `install.ps1` 开头 `$SteamVRSettings` | `install.ps1` |
| 看片模式（关清晰桌面、120 Mbit/s、待机 24 小时） | `setup-pc.ps1 -Video` | 重跑该脚本（重建后再跑一次） |

### 开发模式（不戴头盔测试）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1        # 打开
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1 -Off   # 关闭
```

遮住鼻梁内侧的传感器（或戴上），脚本检测到“已戴上”后冻结传感器事件，Flow 不再休眠；头部追踪不受影响，**但手部追踪会失效**。Flow 重启后失效。同时把 SteamVR 闲置待机从 10 分钟改到 30 分钟。

### 备用模式（不经 SteamVR 直接串流桌面）

只想验证“PC 桌面能不能串到 Flow”时用：`pc\flow_desktop_streamer\`（.NET + Python）与 `wvr_flow_probe\tools\` 下的脚本，用 ffmpeg 抓桌面直接送 TCP 8001。没有姿态回馈、控制器、音频与清晰桌面。`--encoder` 可选 `x264` / `nvenc` / `amf` / `qsv` / `mf`。

</details>

<details>
<summary><b>附录 A：通信协定（FLOWH264 v7）</b></summary>

由 `virtual_display_device.cpp`（PC 端送出）与 `MainActivity.java`（Flow 端解析）对照整理；**Flow 端解析器是唯一权威**。所有整数为**大端**，float 存 IEEE-754 比特样式。

### 主画面串流（TCP 8001）

连接后先送一次串流标头：

| 字段 | 类型 | 说明 |
|---|---|---|
| magic | `char[8]` | `FLOWH264` |
| version | u32 | 目前 `7` |
| width / height | u32 | 串流大小（3200×1600） |
| fps | u32 | 75 |
| layout | u32 | v4 起：`1` = 左右并排（主画面）、`0` = 单眼（清晰桌面） |
| sps_size + sps | u32 + bytes | H.264 SPS |
| pps_size + pps | u32 + bytes | H.264 PPS |

之后每个 **VCL NAL**（type 1–5）一笔，标头固定 92 bytes：

| 字段 | 类型 | 说明 |
|---|---|---|
| size | u32 | NAL 字节数 |
| pts_us | i64 | 帧来源时间戳（微秒） |
| encoded_ready_ms | i64 | 编码完成时间（epoch ms） |
| send_start_ms | i64 | 送出开始时间（epoch ms） |
| pose_sequence | u32 | v5 起：该帧渲染用的头部姿态序号（0 = 没新姿态） |
| panel[15] | u32 ×15 | v6/v7：`[0]` 旗标（0 = 隐藏），`[1..12]` 3×4 变换，`[13]` 宽度，`[14]` 曲率（v7） |
| nal | bytes | NAL 本体 |

版本演进：v4 加 `layout`；v5 加姿态序号；v6 加面板；v7 加曲率。

### 清晰桌面（TCP 8005）

同一个 `FLOWH264` magic，`version = 4`、`layout = 0`，每笔：u32 size（含起始码）、i64 pts_us、i64 encoded_ms、i64 send_start_ms、frame（`00 00 00 01` + NAL）、i64 send_end_ms（在 frame **之后**）。

### 音频（TCP 8004）

标头 20 bytes：`FLOWAUD1`（8）+ u32 版本 + u32 采样率 + u32 声道数；之后是持续的 16-bit 立体声 PCM。

### 姿态与手（UDP 8002，Flow → PC）

`PosePacket`（36 bytes，little-endian）：u32 magic `0x31504C46`（`FLP1`）、u32 sequence（每帧递增，就是附在 8001 每帧的序号）、x/y/z（f32）、qx/qy/qz/qw（f32）。

`HandPacket`（644 bytes）：u32 magic `0x31484C46`（`FLH1`）、u32 sequence、`valid[2]`、`reserved[2]`、`pinch[2]`、`joints[2][26][3]`（双手 26 关节，公尺）。

### Discovery（UDP 8002，PC → Flow）

纯文本广播 `FLOWH264_PC <port>`（port = 8001），周期性送出直到 Flow 连上。

</details>

<details>
<summary><b>附录 B：文件地图、路径与诊断工具</b></summary>

### 文件地图

| 文件 | 职责 |
|---|---|
| `scripts/setup-pc.ps1`、`setup-flow.ps1`、`setup.ps1` | 一键部署：机器端 / 头显端 / 两者合跑 |
| `scripts/setup-common.ps1` | 一键脚本共用的底层函数 |
| `scripts/build.ps1`、`install.ps1`、`uninstall.ps1` | 建置、注册/套设置、移除注册 |
| `scripts/dev-awake.ps1` | 开发模式（Flow 不休眠 + SteamVR 闲置 30 分钟） |
| `SETUP.md` | 操作流程精简清单 |
| `pc/flow_steamvr_driver/src/hmd_driver_factory.cpp`、`device_provider.cpp` | 驱动进入点 |
| `hmd_device_driver.cpp` | HMD 设备：投影/IPD、姿态、追踪空间 "FLOW" |
| `virtual_display_device.cpp` | **内核**：虚拟显示器、Present 缩放、编码线程、TCP 8001、discovery、画质诊断 |
| `flow_video_encoder.{h,cpp}` | 编码器抽象层：厂商检测、`auto` 选择与失败回退 |
| `flow_nvenc_encoder.{h,cpp}` / `flow_amf_encoder.{h,cpp}` | NVIDIA NVENC / AMD AMF 实作 |
| `hand_controller.cpp` | 手部关节 → Index 控制器 |
| `keyboard_mouse_controller.cpp` | 数字小键盘 → VR 控制器 |
| `flow_pointer_gate.h` | 指针门控 |
| `flow_shared_input.h` / `flow_pose_sync.h` | 共用输入状态 / 姿态序号与常数 |
| `flow_audio_streamer.cpp` | Windows 环回采集 → TCP 8004 |
| `pc/flow_dashboard_helper/main.cpp` | 控制台自动开关、坐姿原点、小键盘拦截、面板位置 |
| `desktop_layer_streamer.cpp` | 清晰桌面：Desktop+ 贴图 → 编码 → TCP 8005 |
| `Wave_Native_SDK/samples/wvr_flow_probe/.../MainActivity.java` | Flow 端：discovery、TCP、两个 MediaCodec、AudioTrack |
| `.../jni/hellovr.cpp` | Flow 端：Wave 会期、双眼绘制、图层、准星、姿态与手部回传 |
| `flowvr/resources/input/*.json` | SteamVR 输入绑定 |
| `flow_probe/` | 从 Flow 采集的硬件信息（仅供参考；含序号的文件不公开） |

### 路径速查

- 要自己放进仓库的两样（`.gitignore`，重 clone 后要再放）：Wave SDK 的 `repo` → `Wave_Native_SDK\repo\`；JDK 8 → `JAVA_HOME` 或 `tools\jdk8\<任意名>\`。
- 脚本自己找的：VS（vswhere）、Android SDK（`ANDROID_SDK_ROOT` / `ANDROID_HOME` / `%LOCALAPPDATA%\Android\Sdk`）、NDK（必须在 `<SDK>\ndk\21.4.7075529\`）、SteamVR（`openvrpaths.vrpath`）、Desktop+（`libraryfolders.vdf`）。
- 建置产物：驱动与日志 `pc\flow_steamvr_driver\build\dist\flowvr\`（`logs\`）；背景程序与日志 `pc\flow_dashboard_helper\build\dist\`；APK `wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk`。
- 备份：`steamvr.vrsettings.bak-veve`、Desktop+ `config.ini.bak-veve`。
- 逐项实际路径：`scripts\setup-pc.ps1 -Check` 会全部印出来。

### 诊断工具

- 驱动日志 `...\dist\flowvr\logs\flow_virtual_display_trace.log`：每 2 秒一行 `stream stats`（Present 频率、编码时间、送出帧率）
- SteamVR 实际输出画面：在 `logs\` 创建空档 `dump_preview.request` → `flow_compositor_preview.ppm`
- Flow 画面：`adb exec-out screencap -p > flow.png`（很暗，要调对比）
- Flow 日志：`adb logcat -s FlowProbe vrsample`（`stream rates`、`timewarp poseAge`，1 步 ≈ 13.3 ms）
- 锐化即时调整：`adb shell setprop debug.flow.sharpen 0.8`（0–2，0 = 关）
- 画质诊断：创建 `dump_stream.request` → `flow_stream_input.ppm`（编码器输入）+ `flow_stream_dump.h264`（之后 1 秒，用 ffmpeg 解最后一帧比对）；`debug.flow.dumpeye` → Flow 写眼睛缓冲 `files/flow_eye_left.ppm`
- 图层 A/B 测试：`debug.flow.layertest 1`（两眼同图，一眼走眼睛缓冲、一眼走图层）
- 声音：SteamVR 日志 `Flow audio: ...`；Flow 日志的 `audio` 行（`queuedMs`、补静音次数）
- 手部：SteamVR 日志每 2 秒一行 `Flow hand ...`；Flow 日志的 `hands` 行

</details>

---

## 授权与致谢

- 上游项目：[`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR)（设计、驱动、Flow App、清晰桌面、手部追踪都出自该作者）；本 fork 加了 AMD AMF 支持、一键部署脚本与 VR 视频模式。
- `pc/openvr/`：Valve OpenVR SDK（submodule）。
- `pc/third_party/nv-codec-headers/`：NVENC API 标头；`pc/third_party/amf/`：GPUOpen AMF 标头（MIT）。
  **注意**：授权不含 H.264 等媒体技术的专利授权，散布编码器的人要自行处理权利金。
- `Wave_Native_SDK/`：HTC Wave SDK 依 VIVE SDK License Agreement 授权，**不在本仓库内**。

Flow 端 App 与驱动的文件标头保留了 Valve / HTC 范例的著作权声明。
