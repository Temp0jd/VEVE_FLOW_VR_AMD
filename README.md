# VEVE_FLOW_VR — 把 HTC VIVE Flow 当成 SteamVR 头盔

PC 上的 SteamVR 画面用显卡的硬件编码器编成 H.264（NVIDIA 走 NVENC，AMD Radeon 走 AMF），经 Wi-Fi 串流到 VIVE Flow；Flow 把头部姿态与双手回传给 SteamVR。

主要用途：在 Flow 里看 PC 桌面（Desktop+）；Flow 内置的手部追踪当作两支 Index 控制器，USB 数字小键盘补上摇杆与按键（手不在视野内时，小键盘是跟着头部的激光控制器）。PC 播放的声音（Windows 默认输出设备）同步串流到 Flow 的喇叭，PC 喇叭照常出声。控制台里正在显示的 Desktop+ 面板另外串流，在 Flow 上以 Wave 合成器图层显示（清晰桌面，见下方“清晰桌面”）。

> 这个仓库是 [`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR) 的 fork（分支名 `_AMD`）。相对上游多了：**AMD Radeon（AMF）编码支持**、**一键部署脚本**（`scripts\setup-pc.ps1` / `setup-flow.ps1`）与 **VR 视频模式**。其余设计与程序都来自原作者。

---

## 这个项目能做到什么（以及做不到什么）

先讲结论，避免白忙一场。

### 可以

| 能力 | 说明 |
|---|---|
| 在 Flow 上跑 SteamVR 内容 | Flow 原生只能跑 FlowOS 的 Android 应用；这个驱动让 SteamVR 以为它是屏幕，所以 PC 上的整个 SteamVR 游戏库都能用 |
| 无线串流 PC 画面 | Present → GPU 缩放 → 硬件编码 H.264 → TCP → MediaCodec 解码 → Wave timewarp，两眼各 1600×1600 |
| 看 VR 视频（DeoVR 之类） | **这是最合适的用途**：180°/360° 视频只需要头部旋转，正好是 Flow 唯一有的追踪方式 |
| 在头盔里用 PC 桌面 | Desktop+ 面板，还有一条“清晰桌面”图层专门让它清楚 |
| 双手当控制器 | Flow 镜头的手部追踪 → 两支 Valve Index 控制器（捏合 = Trigger、握拳 = Grip、各指弯曲量） |
| 补上摇杆与 A/B | PC 插一个 USB 数字小键盘，自动变成右手的摇杆与按键 |
| 把 PC 声音送到头盔 | Windows 默认输出设备的环回采集，48 kHz 16-bit 立体声 |
| 坐姿 VR 游戏 | 赛车、飞行、太空、坐着玩的 Unity/Unreal 游戏 |

### 不可以

| 限制 | 原因 |
|---|---|
| **没有位置追踪（只有旋转，3DoF）** | Flow 没有 SLAM/深度传感器，只有陀螺仪与加速度计；镜头朝下看手。站起来走动、弯腰闪避都不行，只能原地转头或用摇杆假移动 |
| 取代 Quest 之类的 6DoF 一体机 | 同上，这是硬件天花板，不是软件问题 |
| 画质等同 PC 原生 | 画面会被采样两次（眼睛缓冲 → timewarp/镜片变形），小字偏软、有轻微条纹；只有“清晰桌面”那一层是 1:1 |
| 完美的手 | 没摇杆、没手指骨架、手会挡住视线、环境太暗就失效 |
| 摘下头盔继续用 | Flow 的 OEM 服务在距离传感器判断“没戴”约 5 秒后强制休眠；绕过的方法（开发模式）会让手部追踪失效 |
| 开箱即用 | 需要自行编译（见“需要什么”），不是装个 exe 就能用的产品 |

一句话：**它把一台只能玩 FlowOS 小游戏的头显，变成一台“无线的坐姿 PCVR 显示器 + 手部控制器”。** 这是这台机器最有用的一种用法，但它不会变成通用 6DoF 头盔。

---

## 运作原理（数据流）

```
┌──────────────────────────── PC (Windows) ─────────────────────────────┐          ┌───── VIVE Flow ──────┐
│ SteamVR ── driver_flowvr.dll                                          │          │ Flow Probe APK       │
│             ├ HMD：投影/IPD = Flow 实测值，姿态来自 Flow (UDP 8002)   │◄─ UDP ───┤  ├ 送头部姿态+序号   │
│             │   追踪空间 "FLOW"；Flow 有送姿态 = 用户戴着             │          │  ├ 送双手关节+捏合   │
│             ├ 虚拟显示：Present → GPU 缩放 → [编码线程] NVENC/AMF   ──┼─ TCP ──► │  ├ MediaCodec 解码   │
│             │   FLOWH264 v7，3200×1600 @75，每帧附「渲染用姿态序号」 │  8001    │  ├ 左右眼各取一半    │
│             │   没有连接时在 UDP 8002 广播 discovery                  │          │  └ 以渲染姿态提交给  │
│             ├ 数字键盘控制器 (右手，激光跟随头部) ◄─ UDP 127.0.0.1:8003│          │     Wave timewarp    │
│             └ Index 控制器 ×2：Flow 手部追踪；右手兼收数字键盘        │          │                      │
│ flow_dashboard_helper.exe（SteamVR 自动启动）                         │          └──────────────────────┘
│   ├ Flow 连上 / 游戏结束时，若没有游戏在跑就打开 Desktop+ 分页        │
│   ├ 游戏开始时关闭控制台；坐姿原点未设置时以目前头部位置设置          │
│   ├ 拦截数字键盘（SteamVR 运行中电脑收不到），转送按键给驱动          │
│   └ 清晰桌面：Desktop+ 面板的贴图 → NVENC/AMF ────────────────────────┼─ TCP ──► 合成器图层
│     面板位置经驱动附在 8001 每帧（v7），面板本身染黑                  │  8005    （盖在面板上）
│ Desktop+（Steam 免费工具）：「只在 Desktop+ 分页」显示主屏幕          │
└───────────────────────────────────────────────────────────────────────┘
```

### 五条连接

| 连接 | 方向 | 内容 |
|---|---|---|
| TCP 8001 | PC → Flow | 主画面 H.264（FLOWH264 v7，见附录 A） |
| UDP 8002 | 双向 | Flow → PC：头部姿态、双手关节、捏合强度；PC → Flow：discovery 广播 `FLOWH264_PC <port>` |
| UDP 127.0.0.1:8003 | 背景程序 → 驱动 | 数字键盘按键、Desktop+ 面板位置/曲率、控制台状态（只在同一台 PC 上） |
| TCP 8004 | PC → Flow | 音频（`FLOWAUD1` 标头 + 48 kHz 16-bit 立体声 PCM） |
| TCP 8005 | 背景程序 → Flow | 清晰桌面图层（FLOWH264 v4，单眼） |

Flow **不需要设置 PC 的 IP**：PC 在 UDP 8002 广播 `FLOWH264_PC 8001`，Flow 收到后连 TCP 8001，然后**从这条连接的来源地址**得知 PC 地址，拿去送回姿态与音频/桌面连接。所以唯一的要求是“两台在同一个网段，广播送得到”。

### 延迟预算

往返约 **55 ms**（1 个姿态步 ≈ 13.3 ms @ 75 Hz）。头部转动由 Wave 的 timewarp 依“该帧渲染时用的姿态”补偿（序号随每帧附在 8001 串流里），所以转头感觉不到 55 ms；**平移不补偿**（本来也没有平移）。

---

## 需要什么

### 硬件

| 项目 | 需求 |
|---|---|
| 头盔 | HTC VIVE Flow（含 USB-C 线） |
| PC | Windows 10/11 x64，能跑 SteamVR 的独显 |
| 显卡 | **NVIDIA（NVENC）或 AMD Radeon（AMF）**。两者都不需要另外安装 SDK：NVENC 随 GeForce 驱动、AMF 随 Radeon 驱动（`amfrt64.dll`）提供 |
| 网络 | PC 与 Flow 在同一个 Wi-Fi/网段；PC 建议走有线。这是体验好坏的最大变量 |
| 选用 | USB 数字小键盘（补摇杆与 A/B/菜单键） |

### 软件（都要自己装，脚本不能代劳）

| 项目 | 说明 |
|---|---|
| Steam + SteamVR | Steam |
| Desktop+ | Steam 免费（app 1494460）。**只有“在头盔里看 PC 桌面”才需要**；只看视频可跳过 |
| Visual Studio 2022 | 需勾“使用 C++ 的桌面开发”。CMake 要用它的编译器 |
| CMake ≥ 3.15 | 可用 VS 内附的，或 `winget install Kitware.CMake` |
| Android Studio | 提供 Android SDK 与 platform-tools（adb） |
| Android NDK **21.4.7075529** | 用 SDK Manager 装这个**特定版本** |
| JDK **8** | 需完整 JDK（要有 `javac`，不是 JRE）。设 `JAVA_HOME`，或解压 Temurin JDK 8 到 `tools\jdk8\<文件夹>` |
| HTC Wave Native SDK **4.5.0** | 见下一节（需登录 VIVE 开发者网站） |
| 选用 | .NET 9 SDK、Python 3 + ffmpeg（只有备用直接串流模式需要） |

**为什么卡在 NDK 21.4 / JDK 8**：Flow 端 APK 用 Gradle 5.6.1 + Android Gradle Plugin 3.5（Wave SDK 4.5.0 的范例项目就是这个版本），这组合只吃 JDK 8；NDK 版本也写在范例的建置设置里。升级它会牵动 Wave SDK 的整包范例，所以维持原状。

第一次建置 APK 需要网络（Gradle / AGP 会下载依赖）。

## Wave SDK

HTC Wave SDK 依“VIVE SDK License Agreement”授权，不包含在这个仓库里，请自行下载：

1. 到 VIVE 开发者网站（https://developer.vive.com ，需登录）下载 **Wave Native SDK 4.5.0**。
2. 把压缩档里的 `repo` 文件夹整个拷贝到本项目的 `Wave_Native_SDK\repo`，
   确认存在 `Wave_Native_SDK\repo\com\htc\vr\wvr_client\4.5.0-u02\wvr_client-4.5.0-u02.aar`。

Flow App（`wvr_flow_probe`）最初改写自 Wave SDK 的 hello-VR 范例；没有用到的范例文件（3D 场景、贴图、shader）已移除。

---

## 快速开始

```powershell
git clone <repo> VEVE_FLOW_VR
cd VEVE_FLOW_VR
```

```powershell
# 1) 机器端（一次；换显卡或更新后再跑）—不需要插头盔
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1

# 2) 头显端（一次）—Flow 插 USB、打开 USB 调试、戴上头盔允许一次
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1

# 3) 每天启动（自动开 SteamVR + 头显 App，并确认真的连上）
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
```

只看 VR 视频（不需要 Desktop+）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Video
```

两步合成一步：`powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 [-Video]`。

更短的清单（人一共要动几次手）见 **`SETUP.md`**。

---

## 安装细节（脚本每一步做什么）

### `scripts\setup-pc.ps1`（机器端）

| 步骤 | 内容 |
|---|---|
| 前置检查 | 一次列全缺少的东西（cmake、VS2022、SteamVR、Desktop+、Wave SDK、Android SDK/NDK、JDK 8）并写明怎么装；不会只停在第一个错误 |
| 子模块 | 自动 `git submodule update --init` 取得 `pc/openvr` |
| 建置 | 调用 `build.ps1`：驱动 + 背景程序 + Flow APK（三个产物见下表） |
| 注册 | 调用 `install.ps1 -SkipApk`：`vrpathreg adddriver` 注册驱动、写 SteamVR 设置、套 Desktop+ 设置、注册背景程序自动启动 |
| 防火墙 | （需管理员）为 `vrserver.exe` 与 `flow_dashboard_helper.exe` 加私有网络的入站允许规则。没管理员权限会提示你在管理员 PowerShell 再跑一次 |
| 验证 | 检查三个产物是否存在、驱动是否注册、背景程序记录最后一行 |

建置产物：

| 产物 | 路径 |
|---|---|
| SteamVR 驱动 | `pc\flow_steamvr_driver\build\dist\flowvr\bin\win64\driver_flowvr.dll` |
| 背景程序 | `pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.exe` |
| Flow APK | `Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk` |

注册方式：驱动用 `vrpathreg adddriver <dist\flowvr>`（`flowvr\driver.vrdrivermanifest` 里 `redirectsDisplay: true` 是它能接管屏幕的关键）；背景程序用 `flow_dashboard_helper.exe --install` 注册成 `flowvr.dashboard_helper`（`is_dashboard_overlay`，随 SteamVR 自动启动）。

### `scripts\setup-flow.ps1`（头显端）

| 步骤 | 内容 |
|---|---|
| 前置检查 | adb 是否存在、APK 是否已建置；Flow 没插 / 未授权 / offline 三种情况分别给明确指示 |
| 安装 | `adb install -r`，失败时（例如签名不符）告诉你先 `adb uninstall` |
| 验证 | 确认已安装、印出版本；列出目前的调试属性 |
| 网络 | 读出 Flow 与 PC 的 IP，比对是否同一网段（不同网段 = 最常见的失败原因）；ping 测试仅供参考（Windows 默认挡 ICMP） |
| `-Launch` | 依正确顺序启动：SteamVR（等 vrserver 起来）→ 头显 App → 盯驱动记录等 `Flow stream client connected`，成功/失败都明确告知 |

### 反安装

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1 [-RestoreSettings] [-RemoveApk]
```

移除驱动与背景程序的注册（Desktop+ 保留不安装）。`-RestoreSettings` 从 `*.bak-veve` 还原 `steamvr.vrsettings` 与 Desktop+ `config.ini`；`-RemoveApk` 用 adb 移除头盔上的 App。`install.ps1` 第一次改设置档前都会留备份，所以可以重复运行。

---

## 日常使用

1. Flow 与 PC 在同一个 Wi-Fi（不需要 USB / ADB）。
2. 从 Steam 启动 SteamVR（会一并打开 SteamVR Home、Desktop+、背景程序）。
3. 在 Flow 上打开 **Flow Probe**。连上后约 1.5 秒，Desktop+ 分页自动打开，看到 PC 主屏幕。
4. 开 VR 游戏时控制台（连同桌面）自动关闭；游戏结束（回到 Home）后自动再打开。拿下头盔再戴上也会重新打开。
5. 激光点到 Desktop+ 面板外会关掉控制台、桌面跟着消失：按 `*` 叫回来（SteamVR 会打开上次用的 Desktop+ 分页）。
6. 激光平常不碰面板（见下方“指针门控”），实体鼠标照常可用。
7. 双手举到眼前就变成两支 Index 控制器（见下方“手部追踪”）；手放下约 3 秒后，小键盘回到跟着头部的激光。

### 指针门控（控制台开着时才生效）

控制台开着时，如果激光一直跟着头或手，Desktop+ 的光标就会乱跑。所以：

- **平常激光不碰面板**，光标不会跟着头或手跑，实体鼠标照常可用。
- 按住小键盘按键（`5`、`0`、Enter、方向/`+` `−`）或捏合/握拳时，激光才回来。
- 约 **0.2 秒**后才送出点击（Desktop+ 移动光标要 120–140 ms），放开后激光再停 **0.15 秒**让放开也送达。
- 没在按时，小键盘控制器移到下方 1.5 m（不挡视线）；手部控制器留在手上、激光朝下。白色准星标出小键盘点击的位置，只在手部检测关闭时显示。
- 游戏中（控制台关闭）完全不受影响。实作在 `flow_pointer_gate.h`，控制台状态由背景程序随小键盘封包（UDP 8003）送给驱动。

### 手部追踪（Index 控制器）

Flow 的镜头追踪双手（每手 26 个关节），驱动把它们变成 SteamVR 的 Valve Index 控制器（左右各一）。

| 手势 / 按键 | Index 控制器 |
|---|---|
| 拇指捏食指 | Trigger（模拟；捏紧＝点击） |
| 握拳（中指、无名指、小指弯曲） | Grip |
| 各手指弯曲 | 手指弯曲量（`/input/finger/*`） |
| 右手被追踪时的小键盘：方向键 / + − | 右手摇杆 |
| 　Enter / `/` / `*` | A / B / System |
| 　5 / 0 | Trigger / Grip（与手势合并） |

- 控制器位置在手掌中心，方向由手腕→中指根部与食指↔小指根部算出；激光方向用 `hand_pitch_offset_deg` 微调。
- 手离开镜头视野（例如放到身侧）就失去追踪；连续 3 秒没追踪到才断线，避免短暂遗失时跳动。
- 握拳时捏合强度也会升高，所以会同时触发 Trigger（类似用力握实体 Index）。

### 数字键盘（只在 SteamVR 运行中有效，NumLock 灯号不影响）

右手没有被追踪时，小键盘是独立的右手控制器：

| 键 | VR 控制器 | 用途 |
|---|---|---|
| 5 | Trigger | 选取/点击（按住＝拖曳） |
| 0 / Ins | Grip | 返回 |
| Enter | 触摸板按下 | — |
| + / 8，− / 2 | 触摸板上 / 下 | 卷动 |
| 4 / 6 | 触摸板左 / 右 | 方向 |
| * | System | 开关 SteamVR 控制台（叫回 Desktop+） |
| / | Menu | 游戏菜单 |

用头部对准准星，按键点击（激光只在按住时出现）。

**NumLock = 开关手部检测**：关闭时忽略 Flow 的手（手举起来也不会变成 Index 控制器），小键盘固定是跟着头的激光。控制台里**有准星 = 手部检测关闭，没有准星 = 打开**（SteamVR 启动时为打开）。Flow 端的手部追踪照常运行。

SteamVR 运行期间小键盘（含 NumLock）不会打字到电脑；只有小键盘的 ←（Backspace）照常。

### 清晰桌面（Desktop+ 面板以合成器图层显示）

串流的 SteamVR 画面在 Flow 上会被采样两次（眼睛缓冲 → timewarp/镜片变形），加上 SteamVR 合成时的一次，小字会模糊、有条纹。Flow 自己的系统界面（FlowOS）用的是 Wave 合成器图层，只采样一次，所以清晰（Meta 文档称为 double sampling）。因此：

- 背景程序找出控制台正在显示的 Desktop+ overlay（`elvissteinjr.DesktopPlus<n>`，按 1/2 切换的就是不同的 overlay），以 `IVROverlay::GetOverlayTexture` 读它的贴图、照面板的贴图范围裁切，NVENC/AMF 编码后经 TCP 8005 送给 Flow。内容就是 Desktop+ 显示的画面（含它画的光标）。
- 面板的位置／宽度／曲率由背景程序送给驱动（UDP 8003），驱动换算成 Flow 座标附在 8001 每帧（FLOWH264 v7）。
- Flow 第二个解码器解码后 1:1 拷贝进 Wave 贴图队列，以图层（左右眼成对）放在面板位置；准星也画在这层上。
- 面板本身用 `SetOverlayColor` 染黑：串流画面比头部慢约 55 ms，不染黑的话转头时模糊的那份会从图层后面露出来。**不能改透明度**：Desktop+ 面板 alpha 为 0 或 0.01 时不再接受激光点击，改回来也要重开 Desktop+ 才恢复。
- 控制台关闭时暂停串流（连接保留，按 `*` 叫回来立即清晰）；Flow 断线或串流没在跑时面板恢复原色。
- **限制**：Flow 的 `WVR_GetMaxFrameLayerCount` = 4 是两眼合计，扣掉两眼内容层只剩一组图层；送两组时帧率掉到 14–26 fps。所以同时只有一个 Desktop+ overlay 是清晰的，其他（浮动窗口等）维持串流画面。
- Desktop+ 面板是曲面（`install.ps1` 设 `Curvature=33`，半径约 1.2 m，约等于面板到头的距离）：大面板平放时越往旁边看越斜，光标和准星会越偏。背景程序把曲率一起送出（FLOWH264 v7），Flow 用 Wave 圆柱图层（实验功能）显示，准星也改算激光和圆柱的交点；曲率 0 时照旧用平面。

### 音频

- 采集 Windows **默认输出设备**的环回（loopback），转成 48 kHz 16-bit 立体声 PCM，经 TCP 8004 送到 Flow 播放；PC 喇叭照常出声。
- Flow 端用 `AudioTrack` 播放，缓冲不够时补静音，避免断音累积成延迟（记录里有 `queuedMs` 与补静音次数）。
- 由 `driver_flowvr.enable_audio` 开关。

---

## 显卡与编码器（NVIDIA NVENC / AMD AMF）

驱动与背景程序用同一组 GPU 编码后端（`flow_video_encoder.cpp` 抽象层，两个实作），两者输出同样的 H.264，Flow 端不需要任何改动：

| 后端 | 平台 | 输入 | 特性 |
|---|---|---|---|
| `flow_nvenc_encoder.cpp` | NVIDIA（`nvEncodeAPI64.dll`，随 GeForce 驱动） | 直接吃 BGRA 贴图 | 同步：这一调用拿到的就是刚送进去的帧 |
| `flow_amf_encoder.cpp` | AMD Radeon（`amfrt64.dll`，随 Radeon 驱动） | 只吃 NV12，所以每帧先在 GPU 上做一次 BT.709 有限范围的 BGRA→NV12 转换 | **有一帧管线延迟**（AMF 既有行为） |

选择方式：`flowvr_display.video_encoder` = `auto`（默认）/ `nvenc` / `amf`。`auto` 看 D3D11 设备的显卡厂商；该厂商的后端初始化失败时（例如独显没接屏幕、DLL 不存在）会**自动改试另一个**并在记录里写明，所以整台机器换卡不用改设置。

`flowvr_display.video_encoder_preset`（1–7，旧键名 `nvenc_preset` 仍有效）同时对应两家的质量：NVENC 是 P1（最快）…P7（最好）；AMF 对应 speed（1–2）/ balanced（3–5）/ quality（6–7）。两边都跑超低延迟设置（不用 B 帧、不做前处理、不跳帧）。

**AMD 那一帧延迟怎么处理**：既然同一帧的比特流下一次调用才拿到，驱动与背景程序就改用“封包自己带的 PTS”去回查该帧的姿态序号与来源 slot，再送给 Flow。时间补偿（timewarp）与画质诊断（`flow_stream_input.ppm` 对应 `flow_stream_dump.h264`）都因此仍然正确；代价是编码延迟多约一帧（≈ 13 ms）。AMF 输出缓冲区自带的时间戳不可靠（FFmpeg 也是自己维护队列），所以 AMF 后端用内部的 pending 队列按提交顺序配对。

怎么确认实际用了哪一个：

```
Steam\logs\vrserver.txt
  Flow virtual display encoder 100 Mbit/s, backend auto, preset 4
  Flow virtual display: AMF encoder on <卡名> (vendor 0x1002)
```

---

## 设置参考

### `pc\flow_steamvr_driver\flowvr\resources\settings\default.vrsettings`

改完要**重新建置**（`build.ps1` 会把 `flowvr\` 拷贝到 `build\dist\flowvr\`）再重开 SteamVR。

#### `driver_flowvr`

| 键 | 默认 | 说明 |
|---|---|---|
| `enable` | `true` | 驱动总开关 |
| `serial_number` | `VIVEFLOW-STEAMVR-001` | 显示在 SteamVR 的序号 |
| `model_number` | `HTC VIVE Flow` | 显示在 SteamVR 的型号 |
| `enable_keypad_controller` | `true` | 数字键盘控制器（右手） |
| `enable_hand_controllers` | `true` | 手部追踪 → Index 控制器 |
| `enable_audio` | `true` | PC 声音串流到 Flow |
| `enable_desktop_layer` | `true` | 清晰桌面图层（TCP 8005） |
| `desktop_bitrate_mbps` | `30` | 清晰桌面的比特率（背景程序读取） |
| `desktop_fps` | `60` | 清晰桌面的帧率（背景程序读取） |
| `hand_pitch_offset_deg` | `0.0` | 手部激光的俯仰微调（度） |

#### `flowvr_display`

| 键 | 默认 | 说明 |
|---|---|---|
| `window_x` / `window_y` | `0` / `0` | 虚拟显示器在 Windows 桌面上的位置 |
| `window_width` / `window_height` | `3200` / `1600` | 虚拟显示器的分辨率（两眼并排） |
| `render_width` / `render_height` | `1600` / `1600` | SteamVR 每眼的渲染分辨率 |
| `stream_width` / `stream_height` | `3200` / `1600` | 送给 Flow 的画面大小（左右并排，= 两眼各 1600×1600） |
| `video_encoder` | `auto` | `auto` / `nvenc` / `amf`（见“显卡与编码器”） |
| `video_encoder_preset` | `4` | 1（最快）–7（最好）；两家共用 |
| `nvenc_preset` | `4` | 旧键名，`video_encoder_preset` 不存在时才用 |
| `stream_bitrate_mbps` | `100` | 主画面比特率；Flow 解码器上限约 120 |
| `tan_left` / `tan_right` | `-1.0639` / `1.0639` | 视野（Flow 实测值，约 94°）。**错了画面比例会不对** |
| `tan_top` / `tan_bottom` | `1.0639` / `-1.0639` | 同上（垂直） |
| `ipd_meters` | `0.0605` | 瞳距（Flow 实测 60.5 mm） |
| `vsync_to_photons` | `0.011` | 光子延迟补偿（秒） |
| `display_frequency` | `75` | 面板更新率（Hz） |

### 其他设置

| 设置 | 位置 | 套用方式 |
|---|---|---|
| Flow 手部追踪（默认开） | `hellovr.cpp` 的 `FLOW_DEFAULT_HANDS`；即时开关 `adb shell setprop debug.flow.hands 0/1` | APK 或 setprop |
| Flow 眼睛缓冲 1600、锐化（默认关） | `.../wvr_flow_probe/app/src/main/jni/hellovr.cpp` 开头的 `FLOW_*` | `build.ps1` + `install.ps1` |
| Desktop+ 大小 248 cm、下移 22 cm、曲率 33、只在 Desktop+ 分页 | `scripts\install.ps1` 开头 `$DesktopPlusOverlay` | `install.ps1` |
| SteamVR overlay 质量 High、闲置 10 分钟进入待机 | `scripts\install.ps1` 开头 `$SteamVRSettings` | `install.ps1`（存在 `steamvr.vrsettings`，重启后仍有效） |
| 看片模式（关清晰桌面、120 Mbit/s、待机 24 小时） | `scripts\setup-pc.ps1 -Video` | 重跑该脚本（重建后要再跑一次） |

`-Video` 实际写入（建置产物里）：

| 设置 | 值 |
|---|---|
| `driver_flowvr.enable_desktop_layer` | `false` |
| `flowvr_display.stream_bitrate_mbps` | `120` |
| `power.turnOffScreensTimeout`（`steamvr.vrsettings`） | `86400` |

---

## 开发模式（不戴头盔测试）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1        # 打开
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1 -Off   # 关闭
```

- **Flow 不休眠**：Flow 的 OEM 服务在距离传感器判断“没戴”约 5 秒后强制休眠，Android 的屏幕设置盖不过它。脚本等你遮住鼻梁内侧的传感器（或戴上），检测到“已戴上”后用 `dumpsys sensorservice restrict` 冻结传感器事件，之后拿下也维持清醒。头部追踪不受影响，**但手部追踪会失效**（检测不到手）。需要 ADB；Flow 重启后即失效。
- **SteamVR 闲置 30 分钟才待机**（平常 10 分钟）：头盔放在桌上不动会被视为闲置，待机时画面全黑。SteamVR 运行中通过背景程序的 `--idle-timeout` 修改，否则直接改 `steamvr.vrsettings`；`-Off` 改回 10 分钟。

## 备用模式（不经 SteamVR 直接串流桌面）

只想知道“PC 桌面能不能串到 Flow”时可以走这条路：`pc\flow_desktop_streamer\`（.NET，会调用 Python 脚本）与 `Wave_Native_SDK\samples\wvr_flow_probe\tools\`（`live_h264_socket_sender.py`、`steamvr_compositor_bridge.py`、`h264_socket_sender.py`）。用 ffmpeg 抓桌面（`ddagrab`）/ 接收 SteamVR 驱动的 BGRA 画面再编码，直接送 TCP 8001。

这条路不需要 SteamVR 的显示重导向，但也就没有姿态回馈、控制器、音频与清晰桌面。`--encoder` 可选 `x264` / `nvenc` / `amf` / `qsv` / `mf`。

---

## 疑难排解

### 连不上 / 没有画面

- **Flow 连上了但画面全黑、没有串流**：GPU 编码器没起来。看 `Steam\logs\vrserver.txt`（驱动的 `DriverLog`）是否有 `Flow virtual display encoder ... backend ...` 与 `Flow virtual display: <backend> encoder on <卡名>`，以及 `FLOWH264 encoder initialize failed: ...`（会写出 NVENC/AMF 的失败原因）；驱动记录档 `...\dist\flowvr\logs\flow_virtual_display_trace.log` 也会有同一行。常见原因与依序检查：
  1. 防火墙：让 SteamVR 的 `vrserver.exe` 使用私人网络（或重跑 `setup-pc.ps1` 用管理员权限自动加规则）。
  2. 不同网段：Flow 与 PC 要在同一个 Wi-Fi。
  3. 没戴着头盔（Flow 没送姿态就不算连上）。
  4. `flowvr_display.video_encoder` 明确设成 `nvenc` 或 `amf` 来排除自动判断。
  - 诊断指令：`powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch`（会直接告诉你连上没有）。
- **画面中央“选择 USB 模式”**：Flow 接着 USB 时的系统提示，选“不运行任何动作”，或拔掉 USB。
- **“无法追踪头戴式设备”**：环境太暗或镜头被挡住。

### 画面灰掉 / 变暗 / 不会动

- **进 VR 游戏画面整片灰色（#4F5A64），但电脑上的游戏窗口正常**：SteamVR 判定追踪失效（`trackingLossColor`）。坐姿模式的游戏（Unity 默认）需要追踪空间的坐姿原点；驱动设置追踪空间 "FLOW"，背景程序在 Flow 连上时补设坐姿原点。若仍发生，看背景程序记录是否有 `seated zero pose`，或在 SteamVR 菜单“重置坐姿位置”。
- **游戏画面变暗、分辨率变低、不会动**：控制台还开着（旧版 SteamVR Unity 插件在没有输入焦点时会暂停）。按 `*` 关闭。
- **只看到 SteamVR Home、没有桌面**：按 `*` 打开控制台；或拿下头盔再戴上（Flow 重新连接会再打开）。

### 桌面 / 设置

- **Desktop+ 设置被改回去**：Desktop+ 关闭时会写回自己的设置；改设置前先关闭 SteamVR，或直接重跑 `install.ps1`。

### 建置

- **建置驱动失败（文件被锁定）**：先关闭 SteamVR（`setup-pc.ps1` 会自己检查并提示）。
- **`JDK 8 not found`**：`JAVA_HOME` 指向 JRE 而不是 JDK（要 `bin\javac.exe`），或版本不是 1.8。
- **`Wave SDK missing`**：`Wave_Native_SDK\repo\com\htc\vr\wvr_client` 不存在（见“Wave SDK”）。

### 诊断工具

- 驱动记录：`pc\flow_steamvr_driver\build\dist\flowvr\logs\flow_virtual_display_trace.log`（每 2 秒一行 `stream stats`：SteamVR Present 频率、编码时间、送出帧率）
- SteamVR 实际输出画面：在 `...\dist\flowvr\logs\` 创建空档 `dump_preview.request`，约 1 秒内产生 `flow_compositor_preview.ppm`
- Flow 画面：`adb exec-out screencap -p > flow.png`（很暗，需要调整对比）
- Flow 记录：`adb logcat -s FlowProbe vrsample`（`stream rates` 收/解码帧率、`timewarp poseAge` 往返延迟，1 步 ≈ 13.3 ms）
- 背景程序记录：`pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.log`
- 锐化即时调整：`adb shell setprop debug.flow.sharpen 0.8`（0–2，0 = 关）
- 清晰桌面：Flow 记录 `desktop rates`（收/显示帧率）、`Desktop+ panel shown/hidden`；背景程序记录 `desktop layer: ...`、`Desktop+ panel blacked out/restored`。Flow 上暂时关闭：`adb shell setprop debug.flow.desktop 0`
- 画质诊断（各阶段全分辨率采集）：在 `...\dist\flowvr\logs\` 创建 `dump_stream.request` → 驱动写出 `flow_stream_input.ppm`（编码器输入）与 `flow_stream_dump.h264`（之后 1 秒，用 ffmpeg 解最后一帧比对压缩）；`adb shell setprop debug.flow.dumpeye <新值>` → Flow 写出眼睛缓冲 `files/flow_eye_left.ppm`（`adb exec-out run-as com.htc.vr.samples.wvr_flow_probe cat files/flow_eye_left.ppm`）
- 眼睛缓冲大小：`debug.flow.eyebuffer`（App 启动时读，默认 1600）；Wave 锐化 `debug.flow.fse 0..1`（App 启动时读，只作用于内容层）
- 图层 A/B 测试：`debug.flow.layertest 1` 两眼显示同一张图（`files/test_1080.png` / `test_4k.png`，自行推入），一眼走眼睛缓冲、另一眼走合成器图层；`.eye`、`.image`、`.width`、`.shape`、`.count` 切换
- 声音：SteamVR 记录 `Flow audio: ...`（采集格式、每 10 秒送出秒数）；Flow 记录的 `audio` 行（每 10 秒收到/丢弃的 10 ms 区块、补静音次数、排队延迟 `queuedMs`、断音累计）
- 手部：SteamVR 记录 `Steam\logs\vrserver.txt` 每 2 秒一行 `Flow hand ...`（捏合、Trigger、各指弯曲、Grip、键盘）；Flow 记录的 `hands` 行（追踪频率、左右手有效比例、捏合比例）

---

## 已知限制

- **Flow 只有 3DoF（旋转）追踪**：硬件上没有位置追踪传感器，站起来走动、弯腰都不行。可用性最高的场景是看视频与坐姿游戏。
- Flow 面板每度像素少于桌面：小字偏软，主要靠放大 Desktop+ 画面改善（目前 248 cm）。
- 往返延迟约 55 ms；头部转动由 Wave timewarp 依渲染姿态补偿，平移不补偿。
- 小键盘的 ←（Backspace）与主键盘无法区分，所以不拦截。
- 清晰桌面同时只能一个 Desktop+ overlay（Flow 只有一组额外图层，见“清晰桌面”）。
- 手部控制器还没有手指骨架（`/input/skeleton`）：游戏里看到的是 Index 控制器模型，不会显示手指动作。
- 摇杆只能用小键盘，手势没有对应。
- **AMD（AMF）路径比 NVENC 多约一帧（≈ 13 ms）的编码延迟**，因为 AMD 硬件编码器有管线延迟；姿态与画质诊断都已按帧对齐。实作完成并通过脱机编译检查（mingw-w64 语法/对象），但**尚未在真实 AMD 机器上实测**——第一次跑请照“显卡与编码器”那两行记录确认后端与送出帧率。
- Flow 拿下约 5 秒就休眠，无法在不 root 的情况下永久改长：秒数在 OEM 服务（`vive.wave.vr.oem`）的数据库（`miac_config/psensor_duration`、`auto_shut_screen`），写入需要系统签名权限；建数据库时读的默认属性 `wo_psensor_duration` / `wo_auto_shut_screen` 也被 SELinux 挡住、ADB 设不了。需要时用开发模式（重启后失效）。

## 待办

- 手指骨架：把 Flow 的 26 个关节转成 OpenVR 手部骨架，支持 Index 手指追踪的游戏（Half-Life: Alyx、VRChat 等）就能显示手指。
- 长时间开手部追踪时 Flow 的温度与降频（目前只测过几分钟）。
- 多键同时操作（搁置，之后会做）：手势只有 Trigger、Grip，A/B/摇杆要靠小键盘，左手没有其他按键。方案：
  1. 扩充手势：用关节距离各自判断拇指碰食指 / 中指 / 无名指（Trigger / A / B），可同时成立；摇杆仍无解。
  2. 手部追踪 + 实体按键设备（建议）：两手各握一支蓝牙手把（如 Joy-Con）连 PC，按键、摇杆、扳机来自手把，位置来自 Flow 手部追踪（方向可用手把陀螺仪）。需先实测：握着手把时 Flow 是否还追踪得到手。
  3. 两者并存：没拿手把用手势，拿着手把用手把按键。
- 6DoF 可能性探测：Flow 的 manifest 声明 `NumDoFHmd = "3,6DoF"`，App 也已经在读 `pose.is6DoFPose`（记录里的 `hmdDoF=3|6`）。目前用 `WVR_PoseOriginModel_OriginOnHead` 取姿态，位置恒为原点，所以看不出真相；把 origin model 换成 ground/tracking-observer 再走动，就能从记录里的 `hmdDoF` 与 `hmdXYZ` 确定 FlowOS 到底能不能给 6DoF。**先验证再投入**。
- 简化建置环境（NDK/JDK 升级）以降低安装门槛。

---

## 附录 A：通信协定（FLOWH264 v7）

以下由 `virtual_display_device.cpp`（PC 端送出）与 `MainActivity.java`（Flow 端解析）对照整理；**Flow 端的解析器是唯一权威**，改动前请先看那里。所有整数为**大端**（网络序），float 以其 IEEE-754 比特样式存放。

### 主画面串流（TCP 8001）

连接后先送一次**串流标头**：

| 字段 | 类型 | 说明 |
|---|---|---|
| magic | `char[8]` | `FLOWH264` |
| version | u32 | 目前 `7` |
| width / height | u32 | 串流大小（3200×1600） |
| fps | u32 | 75 |
| layout | u32 | v4 起：`1` = 左右并排立体（主画面）、`0` = 单眼（清晰桌面用） |
| sps_size + sps | u32 + bytes | H.264 SPS |
| pps_size + pps | u32 + bytes | H.264 PPS |

之后每个 **VCL NAL**（type 1–5）一笔，标头固定 92 bytes：

| 字段 | 类型 | 说明 |
|---|---|---|
| size | u32 | 后面 NAL 的字节数 |
| pts_us | i64 | 这一帧的来源时间戳（微秒） |
| encoded_ready_ms | i64 | 编码完成时间（epoch ms） |
| send_start_ms | i64 | 送出开始时间（epoch ms） |
| pose_sequence | u32 | v5 起：**这一帧渲染时用的头部姿态序号**（timewarp 用；0 = 没有新姿态） |
| panel[15] | u32 ×15 | v6/v7：Desktop+ 面板；`[0]` = 旗标（`0` = 隐藏），`[1..12]` = 3×4 列优先变换矩阵（已扣掉站姿高度偏移），`[13]` = 宽度（公尺），`[14]` = 曲率（v7） |
| nal | bytes | NAL 本体 |

版本演进：v4 加 `layout`；v5 加每帧的姿态序号；v6 加面板（旗标、3×4 矩阵、宽度）；v7 加面板曲率。

### 清晰桌面（TCP 8005）

同一个 `FLOWH264` magic，但 `version = 4`、`layout = 0`（单眼），且每笔：

| 字段 | 类型 |
|---|---|
| size | u32（= 起始码 4 bytes + NAL） |
| pts_us | i64 |
| encoded_ms | i64 |
| send_start_ms | i64 |
| frame | bytes（`00 00 00 01` + NAL） |
| send_end_ms | i64（在 frame **之后**） |

（Flow 端版本 ≥5 时会多读一个 u32，但桌面图层目前固定送 version 4。）

### 音频（TCP 8004）

标头 20 bytes：`FLOWAUD1`（8）+ u32 协定版本 + u32 采样率 + u32 声道数；之后是持续的 16-bit 立体声 PCM。

### 姿态与手（UDP 8002，Flow → PC）

`PosePacket`（36 bytes，原生序 = little-endian）：

| 字段 | 类型 |
|---|---|
| magic | u32 = `0x31504C46`（`FLP1`） |
| sequence | u32（每帧递增，就是附在 8001 每帧的那个序号） |
| x / y / z | f32 |
| qx / qy / qz / qw | f32 |

`HandPacket`（644 bytes）：magic u32 = `0x31484C46`（`FLH1`）、sequence u32、`valid[2]`（左/右手是否有效）、`reserved[2]`、`pinch[2]`（食指捏合强度）、`joints[2][26][3]`（双手 26 个关节的位置，单位公尺）。

### Discovery（UDP 8002，PC → Flow）

纯文本，广播 `FLOWH264_PC <port>`（port = 8001），周期性送出直到 Flow 连上。

---

## 附录 B：文件地图

| 文件 | 职责 |
|---|---|
| `scripts/setup-pc.ps1`、`setup-flow.ps1`、`setup.ps1` | 一键部署：机器端 / 头显端 / 两者合跑（见“安装细节”） |
| `scripts/setup-common.ps1` | 一键脚本共用的底层函数（前置检查、SteamVR 路径、adb、防火墙、网段比对） |
| `scripts/build.ps1`、`install.ps1`、`uninstall.ps1` | 实际做事的三支：建置、注册/套设置、移除注册 |
| `scripts/dev-awake.ps1` | 开发模式（Flow 不休眠 + SteamVR 闲置 30 分钟） |
| `SETUP.md` | 操作流程与“人一共要动几次手”清单 |
| `pc/flow_steamvr_driver/src/hmd_driver_factory.cpp`、`device_provider.cpp` | 驱动进入点：创建 HMD 设备与虚拟显示设备 |
| `hmd_device_driver.cpp` | HMD 设备：投影/IPD、姿态（来自 UDP 8002）、追踪空间 "FLOW"、坐姿原点 |
| `virtual_display_device.cpp` | **内核**：桌面上创建虚拟显示器、Present 缩放、编码线程、TCP 8001 串流、discovery、画质诊断 |
| `flow_video_encoder.{h,cpp}` | 编码器抽象层：厂商检测、`auto` 选择与失败回退 |
| `flow_nvenc_encoder.{h,cpp}` | NVIDIA NVENC 实作 |
| `flow_amf_encoder.{h,cpp}` | AMD AMF 实作（BGRA→NV12 GPU 转换 + AMF 会期） |
| `hand_controller.cpp` | 手部关节 → Index 控制器（Trigger/Grip/各指弯曲） |
| `keyboard_mouse_controller.cpp` | 数字小键盘 → VR 控制器 |
| `flow_pointer_gate.h` | 指针门控（激光只在按键时瞄准面板） |
| `flow_shared_input.h` / `flow_pose_sync.h` | 键盘与手部共用输入状态 / 跨模块的姿态序号与常数 |
| `flow_audio_streamer.cpp` | Windows 环回采集 → TCP 8004 |
| `pc/flow_dashboard_helper/main.cpp` | 控制台自动开关、坐姿原点、数字键盘拦截、面板位置送出 |
| `desktop_layer_streamer.cpp` | 清晰桌面：读 Desktop+ overlay 贴图 → 编码 → TCP 8005 |
| `Wave_Native_SDK/samples/wvr_flow_probe/app/src/main/java/.../MainActivity.java` | Flow 端：discovery、TCP 连接、两个 MediaCodec 解码器、AudioTrack、平台集成 |
| `.../jni/hellovr.cpp` | Flow 端：Wave 会期、左右眼绘制、合成器图层、准星、姿态与手部回传、调试 dump |
| `pc/flowvr/resources/input/*.json` | SteamVR 输入绑定（Index 控制器、键盘鼠标、HMD） |
| `flow_probe/` | 从 Flow 采集的硬件信息（编解码器、显示器、传感器、OEM 套件），仅供参考；含设备序号的 `getprop.txt` 不公开 |

## 附录 C：授权与致谢

- 上游项目：[`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR)（设计、驱动、Flow App、清晰桌面、手部追踪都出自该作者）。这个 fork 加上 AMD AMF 支持、一键部署脚本与 VR 视频模式。
- `pc/openvr/`：Valve OpenVR SDK（submodule）。
- `pc/third_party/nv-codec-headers/`：NVENC API 标头。
- `pc/third_party/amf/`：GPUOpen AMF 标头（MIT，见该目录 `LICENSE.txt`）。
  **注意**：该授权不授予媒体技术（含 H.264）的专利授权，散布编码器的人要自行处理权利金；NVIDIA 路径同理。
- `Wave_Native_SDK/`：HTC Wave SDK 依 VIVE SDK License Agreement 授权，**不在本仓库内**。

Flow 端 App 与驱动的文件标头保留了 Valve / HTC 范例的著作权声明（`Copyright (c) Valve Corporation` 的部分来自 OpenVR 范例）。
