# 操作流程（目标:手动操作尽量少）

一共两个脚本,对应「机器」和「头显」:

| 脚本 | 管谁 | 需要什么 |
|---|---|---|
| `scripts\setup-pc.ps1` | 这台 PC:建置、注册 SteamVR 驱动、后台程序、防火墙 | 什么都不用插 |
| `scripts\setup-flow.ps1` | VIVE Flow:装 App、查网络、可选一键启动并确认连上 | Flow 用 USB 连着 |
| `scripts\setup.ps1` | 上面两个按顺序各跑一遍(懒人版) | Flow 插着最好,不插也能跑完机器端 |

---

## 0. 一次性准备（只做一次）

需要人装的东西(涉及账号、授权、安装器,脚本不能代劳)。**不用自己逐个确认版本——直接跑第 1 步,脚本会一次把缺的都列出来,并写明怎么装。**

| 要什么 | 去哪拿 |
|---|---|
| Steam + SteamVR | Steam |
| Desktop+ （免费,app 1494460） | Steam。**只在需要「在头显里看 PC 桌面」时装**;只看视频可跳过 |
| Visual Studio 2022 + 「使用 C++ 的桌面开发」 | 微软官网,Community 版免费 |
| Android Studio（含 SDK platform-tools） | 安卓开发者官网 |
| Android NDK **21.4.7075529** | Android Studio 的 SDK Manager |
| JDK **8** | Temurin JDK 8;设 `JAVA_HOME`,或解压到 `tools\jdk8\<资料夹>` |
| **HTC Wave Native SDK 4.5.0** | https://developer.vive.com （需登入）→ 把压缩档里的 `repo` 资料夹整个复制到 `Wave_Native_SDK\repo` |

---

## 1. 机器端（一次）

**先确认工具都装齐了**（推荐先跑这一条，什么都不建、什么都不装）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Check
```

它会逐项列出找到什么、缺什么、怎么装，例如：

```
  [ ok ] CMake                    D:\VS2022\...\CMake\bin\cmake.exe [Visual Studio]
  [ ok ] VS 2022 / Build Tools    D:\VS2022
  [ ok ] SteamVR                  C:\Program Files (x86)\Steam\steamapps\common\SteamVR
  [miss] Wave SDK                 Wave_Native_SDK\repo\com\htc\vr\wvr_client is missing or empty
         -> Download 'Wave Native SDK 4.5.0' from https://developer.vive.com ...
  [ ok ] Android NDK              D:\Android\Sdk\ndk\21.4.7075529 (Pkg.Revision = 21.4.7075529)
  [miss] JDK 8                    not found
         -> Set JAVA_HOME to a JDK 8, or unpack Temurin JDK 8 into tools\jdk8\<jdk> ...
  [ -- ] Desktop+                 not needed with -Video

  4 of 10 checks passed; 2 blocking item(s) to fix.   （全就绪时退出码 0）
```

就绪了就做正式安装：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1
```

它按顺序做:

1. **前置检查**:缺什么一次列全(不会只停在第一个错误);也可以单独跑 `-Check` 先看一眼
2. 自动取 `pc/openvr` 子模组;
3. 建置驱动 + 后台程序 + **Flow 的 APK**(APK 是「产物」,装到头显上是第 2 步的事);
4. `install.ps1 -SkipApk`:注册驱动、写 SteamVR 设定、套用 Desktop+ 设定、注册后台程序;
5. **开防火墙**(需要管理员权限;不是管理员会提示你在管理员 PowerShell 里再跑一次);
6. 验证并印出结果。

只看 VR 视频:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Video
```

`-Video` 会跳过 Desktop+,并改三个设定(写在建置产物里,**重建后要再跑一次**):关掉清晰桌面图层、串流码率拉到 120 Mbit/s、SteamVR 闲置待机改成 24 小时(看片时头会很久不动,原本 10 分钟会当成闲置直接黑屏)。

★ 人需要做的:上面第 4 步若提示 Desktop+ 没装,从 Steam 装一次并**启动一次**,然后重跑本脚本。用 `-Video` 就完全不用管 Desktop+。

---

## 2. 头显端（一次）

1. Flow 用 USB 接上 PC,**开启 USB 调试**(设定 → 开发者选项);
2. 第一次接上时,头显里会跳出「允许 USB 调试」——**戴上头显点允许**(这一步只能人工);
3. 跑:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1
```

它会:装 APK → 验证已安装版本 → 检查 **Flow 和 PC 是否在同一个网段**(Flow 靠 UDP 广播找 PC,不同网段是最常见的失败原因)→ 印出可用的调试开关。头显端没接上时它会告诉你卡在哪一步(未授权 / offline / 没插)。

---

## 3. 日常使用（每次一条命令）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
```

等于把整套启动流程按正确顺序做完:

1. 启动 SteamVR(没在跑就启动,并等它起来);
2. 在头显上启动 Flow Probe;
3. 盯着驱动记录,等它出现 `Flow stream client connected`,**告诉你到底连上没有**;超时就按最可能的三个原因报给你(防火墙 / 不同网段 / 没戴着头显)。

不想用脚本的手动版(一样两步):从 Steam 启动 SteamVR → 戴上头显点 **Flow Probe** 图示。

---

## 4. 只看 VR 视频（DeoVR 之类）

这是这台设备最合适的用途:**180°/360° 视频只需要头部旋转**,正好是 Flow 唯一有的追踪方式。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Video
```

之后每次:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
```

然后在 PC 上开 DeoVR 选片。操作:**手部追踪就是手柄**——拇指捏食指 = 点击/播放暂停,握拳 = 返回;PC 上插个 USB 数字小键盘会多出摇杆和 A/B。

---

## 5. 出问题先看这三处

| 症状 | 看哪 |
|---|---|
| 头显连不上 / 画面全黑 | `Steam\logs\vrserver.txt` 里 `Flow virtual display ...`、`<backend> encoder on ...`;以及驱动记录 `pc\flow_steamvr_driver\build\dist\flowvr\logs\flow_virtual_display_trace.log` 的 `stream stats` 行 |
| 头显端不回应/输错流 | `adb logcat -s FlowProbe vrsample`(看 `socket connected`、`stream rates`、`timewarp poseAge`) |
| 清晰桌面/桌布相关 | `pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.log` |

---

## 6. 一共要人做的操作（最短清单）

1. 一次性:装上面表格里的工具(脚本会告诉你缺哪个,自己确认版本不用做)。
2. 一次性:下载 Wave SDK 的 `repo` 放到 `Wave_Native_SDK\repo`。
3. 一次:`setup-pc.ps1 -Check` 确认工具齐了 → 再 `setup-pc.ps1`(若提示需要管理员,用管理员 PowerShell 再跑一次以加防火墙规则)。
4. 一次:插 USB 跑 `setup-flow.ps1`,头显上点一次「允许 USB 调试」。
5. 每次:`setup-flow.ps1 -Launch`(或在头显点一次 Flow Probe 图示)。

其它(取子模组、建置、注册、装 APK、防火墙、查网段、启动 SteamVR、确认连上)全部自动。
