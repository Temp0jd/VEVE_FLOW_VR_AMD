# VEVE_FLOW_VR — 把 HTC VIVE Flow 當成 SteamVR 頭盔

PC 上的 SteamVR 畫面用顯示卡的硬體編碼器編成 H.264（NVIDIA 走 NVENC，AMD Radeon 走 AMF），經 Wi-Fi 串流到 VIVE Flow；Flow 把頭部姿態與雙手回傳給 SteamVR。

主要用途：在 Flow 裡看 PC 桌面（Desktop+）；Flow 內建的手部追蹤當作兩支 Index 控制器，USB 數字小鍵盤補上搖桿與按鍵（手不在視野內時，小鍵盤是跟著頭部的雷射控制器）。PC 播放的聲音（Windows 預設輸出裝置）同步串流到 Flow 的喇叭，PC 喇叭照常出聲。控制台裡正在顯示的 Desktop+ 面板另外串流，在 Flow 上以 Wave 合成器圖層顯示（清晰桌面，見下方「清晰桌面」）。

> 這個 repository 是 [`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR) 的 fork（分支名 `_AMD`）。相對上游多了：**AMD Radeon（AMF）編碼支援**、**一鍵部署腳本**（`scripts\setup-pc.ps1` / `setup-flow.ps1`）與 **VR 影片模式**。其餘設計與程式都來自原作者。

---

## 這個專案能做到什麼（以及做不到什麼）

先講結論，避免白忙一場。

### 可以

| 能力 | 說明 |
|---|---|
| 在 Flow 上跑 SteamVR 內容 | Flow 原生只能跑 FlowOS 的 Android 應用；這個驅動讓 SteamVR 以為它是螢幕，所以 PC 上的整個 SteamVR 遊戲庫都能用 |
| 無線串流 PC 畫面 | Present → GPU 縮放 → 硬體編碼 H.264 → TCP → MediaCodec 解碼 → Wave timewarp，兩眼各 1600×1600 |
| 看 VR 影片（DeoVR 之類） | **這是最合適的用途**：180°/360° 影片只需要頭部旋轉，正好是 Flow 唯一有的追蹤方式 |
| 在頭盔裡用 PC 桌面 | Desktop+ 面板，還有一條「清晰桌面」圖層專門讓它清楚 |
| 雙手當控制器 | Flow 鏡頭的手部追蹤 → 兩支 Valve Index 控制器（捏合 = Trigger、握拳 = Grip、各指彎曲量） |
| 補上搖桿與 A/B | PC 插一個 USB 數字小鍵盤，自動變成右手的搖桿與按鍵 |
| 把 PC 聲音送到頭盔 | Windows 預設輸出裝置的迴路擷取，48 kHz 16-bit 立體聲 |
| 坐姿 VR 遊戲 | 賽車、飛行、太空、坐著玩的 Unity/Unreal 遊戲 |

### 不可以

| 限制 | 原因 |
|---|---|
| **沒有位置追蹤（只有旋轉，3DoF）** | Flow 沒有 SLAM/深度感測器，只有陀螺儀與加速度計；鏡頭朝下看手。站起來走動、彎腰閃避都不行，只能原地轉頭或用搖桿假移動 |
| 取代 Quest 之類的 6DoF 一體機 | 同上，這是硬體天花板，不是軟體問題 |
| 畫質等同 PC 原生 | 畫面會被取樣兩次（眼睛緩衝 → timewarp/鏡片變形），小字偏軟、有輕微條紋；只有「清晰桌面」那一層是 1:1 |
| 完美的手 | 沒搖桿、沒手指骨架、手會擋住視線、環境太暗就失效 |
| 摘下頭盔繼續用 | Flow 的 OEM 服務在距離感測器判斷「沒戴」約 5 秒後強制休眠；繞過的方法（開發模式）會讓手部追蹤失效 |
| 開箱即用 | 需要自行編譯（見「需要什麼」），不是裝個 exe 就能用的產品 |

一句話：**它把一台只能玩 FlowOS 小遊戲的頭顯，變成一台「無線的坐姿 PCVR 顯示器 + 手部控制器」。** 這是這台機器最有用的一種用法，但它不會變成通用 6DoF 頭盔。

---

## 運作原理（資料流）

```
┌──────────────────────────── PC (Windows) ─────────────────────────────┐          ┌───── VIVE Flow ──────┐
│ SteamVR ── driver_flowvr.dll                                          │          │ Flow Probe APK       │
│             ├ HMD：投影/IPD = Flow 實測值，姿態來自 Flow (UDP 8002)   │◄─ UDP ───┤  ├ 送頭部姿態+序號   │
│             │   追蹤空間 "FLOW"；Flow 有送姿態 = 使用者戴著           │          │  ├ 送雙手關節+捏合   │
│             ├ 虛擬顯示：Present → GPU 縮放 → [編碼執行緒] NVENC/AMF ──┼─ TCP ──► │  ├ MediaCodec 解碼   │
│             │   FLOWH264 v7，3200×1600 @75，每幀附「渲染用姿態序號」 │  8001    │  ├ 左右眼各取一半    │
│             │   沒有連線時在 UDP 8002 廣播 discovery                  │          │  └ 以渲染姿態提交給  │
│             ├ 數字鍵盤控制器 (右手，雷射跟隨頭部) ◄─ UDP 127.0.0.1:8003│          │     Wave timewarp    │
│             └ Index 控制器 ×2：Flow 手部追蹤；右手兼收數字鍵盤        │          │                      │
│ flow_dashboard_helper.exe（SteamVR 自動啟動）                         │          └──────────────────────┘
│   ├ Flow 連上 / 遊戲結束時，若沒有遊戲在跑就打開 Desktop+ 分頁        │
│   ├ 遊戲開始時關閉控制台；坐姿原點未設定時以目前頭部位置設定          │
│   ├ 攔截數字鍵盤（SteamVR 執行中電腦收不到），轉送按鍵給驅動          │
│   └ 清晰桌面：Desktop+ 面板的貼圖 → NVENC/AMF ────────────────────────┼─ TCP ──► 合成器圖層
│     面板位置經驅動附在 8001 每幀（v7），面板本身染黑                  │  8005    （蓋在面板上）
│ Desktop+（Steam 免費工具）：「只在 Desktop+ 分頁」顯示主螢幕          │
└───────────────────────────────────────────────────────────────────────┘
```

### 五條連線

| 連線 | 方向 | 內容 |
|---|---|---|
| TCP 8001 | PC → Flow | 主畫面 H.264（FLOWH264 v7，見附錄 A） |
| UDP 8002 | 雙向 | Flow → PC：頭部姿態、雙手關節、捏合強度；PC → Flow：discovery 廣播 `FLOWH264_PC <port>` |
| UDP 127.0.0.1:8003 | 背景程式 → 驅動 | 數字鍵盤按鍵、Desktop+ 面板位置/曲率、控制台狀態（只在同一台 PC 上） |
| TCP 8004 | PC → Flow | 音訊（`FLOWAUD1` 標頭 + 48 kHz 16-bit 立體聲 PCM） |
| TCP 8005 | 背景程式 → Flow | 清晰桌面圖層（FLOWH264 v4，單眼） |

Flow **不需要設定 PC 的 IP**：PC 在 UDP 8002 廣播 `FLOWH264_PC 8001`，Flow 收到後連 TCP 8001，然後**從這條連線的來源位址**得知 PC 位址，拿去送回姿態與音訊/桌面連線。所以唯一的要求是「兩台在同一個網段，廣播送得到」。

### 延遲預算

往返約 **55 ms**（1 個姿態步 ≈ 13.3 ms @ 75 Hz）。頭部轉動由 Wave 的 timewarp 依「該幀渲染時用的姿態」補償（序號隨每幀附在 8001 串流裡），所以轉頭感覺不到 55 ms；**平移不補償**（本來也沒有平移）。

---

## 需要什麼

### 硬體

| 項目 | 需求 |
|---|---|
| 頭盔 | HTC VIVE Flow（含 USB-C 線） |
| PC | Windows 10/11 x64，能跑 SteamVR 的獨顯 |
| 顯示卡 | **NVIDIA（NVENC）或 AMD Radeon（AMF）**。兩者都不需要另外安裝 SDK：NVENC 隨 GeForce 驅動、AMF 隨 Radeon 驅動（`amfrt64.dll`）提供 |
| 網路 | PC 與 Flow 在同一個 Wi-Fi/網段；PC 建議走有線。這是體驗好壞的最大變數 |
| 選用 | USB 數字小鍵盤（補搖桿與 A/B/選單鍵） |

### 軟體（都要自己裝，腳本不能代勞）

| 項目 | 說明 |
|---|---|
| Steam + SteamVR | Steam |
| Desktop+ | Steam 免費（app 1494460）。**只有「在頭盔裡看 PC 桌面」才需要**；只看影片可跳過 |
| Visual Studio 2022 | 需勾「使用 C++ 的桌面開發」。CMake 要用它的編譯器 |
| CMake ≥ 3.15 | 可用 VS 內附的，或 `winget install Kitware.CMake` |
| Android Studio | 提供 Android SDK 與 platform-tools（adb） |
| Android NDK **21.4.7075529** | 用 SDK Manager 裝這個**特定版本** |
| JDK **8** | 需完整 JDK（要有 `javac`，不是 JRE）。設 `JAVA_HOME`，或解壓 Temurin JDK 8 到 `tools\jdk8\<資料夾>` |
| HTC Wave Native SDK **4.5.0** | 見下一節（需登入 VIVE 開發者網站） |
| 選用 | .NET 9 SDK、Python 3 + ffmpeg（只有備用直接串流模式需要） |

**為什麼卡在 NDK 21.4 / JDK 8**：Flow 端 APK 用 Gradle 5.6.1 + Android Gradle Plugin 3.5（Wave SDK 4.5.0 的範例專案就是這個版本），這組合只吃 JDK 8；NDK 版本也寫在範例的建置設定裡。升級它會牽動 Wave SDK 的整包範例，所以維持原狀。

第一次建置 APK 需要網路（Gradle / AGP 會下載依賴）。

## Wave SDK

HTC Wave SDK 依「VIVE SDK License Agreement」授權，不包含在這個倉庫裡，請自行下載：

1. 到 VIVE 開發者網站（https://developer.vive.com ，需登入）下載 **Wave Native SDK 4.5.0**。
2. 把壓縮檔裡的 `repo` 資料夾整個複製到本專案的 `Wave_Native_SDK\repo`，
   確認存在 `Wave_Native_SDK\repo\com\htc\vr\wvr_client\4.5.0-u02\wvr_client-4.5.0-u02.aar`。

Flow App（`wvr_flow_probe`）最初改寫自 Wave SDK 的 hello-VR 範例；沒有用到的範例檔案（3D 場景、貼圖、shader）已移除。

---

## 快速開始

```powershell
git clone <repo> VEVE_FLOW_VR
cd VEVE_FLOW_VR
```

```powershell
# 1) 機器端（一次；換顯卡或更新後再跑）—不需要插頭盔
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1

# 2) 頭顯端（一次）—Flow 插 USB、開啟 USB 偵錯、戴上頭盔允許一次
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1

# 3) 每天啟動（自動開 SteamVR + 頭顯 App，並確認真的連上）
powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
```

只看 VR 影片（不需要 Desktop+）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Video
```

兩步合成一步：`powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 [-Video]`。

更短的清單（人一共要動幾次手）見 **`SETUP.md`**。

---

## 安裝細節（腳本每一步做什麼）

### `scripts\setup-pc.ps1`（機器端）

| 步驟 | 內容 |
|---|---|
| 前置檢查 | 一次列全缺少的東西（cmake、VS2022、SteamVR、Desktop+、Wave SDK、Android SDK/NDK、JDK 8）並寫明怎麼裝；不會只停在第一個錯誤 |
| 子模組 | 自動 `git submodule update --init` 取得 `pc/openvr` |
| 建置 | 呼叫 `build.ps1`：驅動 + 背景程式 + Flow APK（三個產物見下表） |
| 註冊 | 呼叫 `install.ps1 -SkipApk`：`vrpathreg adddriver` 註冊驅動、寫 SteamVR 設定、套 Desktop+ 設定、註冊背景程式自動啟動 |
| 防火牆 | （需管理員）為 `vrserver.exe` 與 `flow_dashboard_helper.exe` 加私有網路的入站允許規則。沒管理員權限會提示你在管理員 PowerShell 再跑一次 |
| 驗證 | 檢查三個產物是否存在、驅動是否註冊、背景程式記錄最後一行 |

建置產物：

| 產物 | 路徑 |
|---|---|
| SteamVR 驅動 | `pc\flow_steamvr_driver\build\dist\flowvr\bin\win64\driver_flowvr.dll` |
| 背景程式 | `pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.exe` |
| Flow APK | `Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk` |

註冊方式：驅動用 `vrpathreg adddriver <dist\flowvr>`（`flowvr\driver.vrdrivermanifest` 裡 `redirectsDisplay: true` 是它能接管螢幕的關鍵）；背景程式用 `flow_dashboard_helper.exe --install` 註冊成 `flowvr.dashboard_helper`（`is_dashboard_overlay`，隨 SteamVR 自動啟動）。

### `scripts\setup-flow.ps1`（頭顯端）

| 步驟 | 內容 |
|---|---|
| 前置檢查 | adb 是否存在、APK 是否已建置；Flow 沒插 / 未授權 / offline 三種情況分別給明確指示 |
| 安裝 | `adb install -r`，失敗時（例如簽章不符）告訴你先 `adb uninstall` |
| 驗證 | 確認已安裝、印出版本；列出目前的除錯屬性 |
| 網路 | 讀出 Flow 與 PC 的 IP，比對是否同一網段（不同網段 = 最常見的失敗原因）；ping 測試僅供參考（Windows 預設擋 ICMP） |
| `-Launch` | 依正確順序啟動：SteamVR（等 vrserver 起來）→ 頭顯 App → 盯驅動記錄等 `Flow stream client connected`，成功/失敗都明確告知 |

### 反安裝

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1 [-RestoreSettings] [-RemoveApk]
```

移除驅動與背景程式的註冊（Desktop+ 保留不安裝）。`-RestoreSettings` 從 `*.bak-veve` 還原 `steamvr.vrsettings` 與 Desktop+ `config.ini`；`-RemoveApk` 用 adb 移除頭盔上的 App。`install.ps1` 第一次改設定檔前都會留備份，所以可以重複執行。

---

## 日常使用

1. Flow 與 PC 在同一個 Wi-Fi（不需要 USB / ADB）。
2. 從 Steam 啟動 SteamVR（會一併開啟 SteamVR Home、Desktop+、背景程式）。
3. 在 Flow 上開啟 **Flow Probe**。連上後約 1.5 秒，Desktop+ 分頁自動打開，看到 PC 主螢幕。
4. 開 VR 遊戲時控制台（連同桌面）自動關閉；遊戲結束（回到 Home）後自動再打開。拿下頭盔再戴上也會重新打開。
5. 雷射點到 Desktop+ 面板外會關掉控制台、桌面跟著消失：按 `*` 叫回來（SteamVR 會打開上次用的 Desktop+ 分頁）。
6. 雷射平常不碰面板（見下方「指針門控」），實體滑鼠照常可用。
7. 雙手舉到眼前就變成兩支 Index 控制器（見下方「手部追蹤」）；手放下約 3 秒後，小鍵盤回到跟著頭部的雷射。

### 指針門控（控制台開著時才生效）

控制台開著時，如果雷射一直跟著頭或手，Desktop+ 的游標就會亂跑。所以：

- **平常雷射不碰面板**，游標不會跟著頭或手跑，實體滑鼠照常可用。
- 按住小鍵盤按鍵（`5`、`0`、Enter、方向/`+` `−`）或捏合/握拳時，雷射才回來。
- 約 **0.2 秒**後才送出點擊（Desktop+ 移動游標要 120–140 ms），放開後雷射再停 **0.15 秒**讓放開也送達。
- 沒在按時，小鍵盤控制器移到下方 1.5 m（不擋視線）；手部控制器留在手上、雷射朝下。白色準星標出小鍵盤點擊的位置，只在手部偵測關閉時顯示。
- 遊戲中（控制台關閉）完全不受影響。實作在 `flow_pointer_gate.h`，控制台狀態由背景程式隨小鍵盤封包（UDP 8003）送給驅動。

### 手部追蹤（Index 控制器）

Flow 的鏡頭追蹤雙手（每手 26 個關節），驅動把它們變成 SteamVR 的 Valve Index 控制器（左右各一）。

| 手勢 / 按鍵 | Index 控制器 |
|---|---|
| 拇指捏食指 | Trigger（類比；捏緊＝點擊） |
| 握拳（中指、無名指、小指彎曲） | Grip |
| 各手指彎曲 | 手指彎曲量（`/input/finger/*`） |
| 右手被追蹤時的小鍵盤：方向鍵 / + − | 右手搖桿 |
| 　Enter / `/` / `*` | A / B / System |
| 　5 / 0 | Trigger / Grip（與手勢合併） |

- 控制器位置在手掌中心，方向由手腕→中指根部與食指↔小指根部算出；雷射方向用 `hand_pitch_offset_deg` 微調。
- 手離開鏡頭視野（例如放到身側）就失去追蹤；連續 3 秒沒追蹤到才斷線，避免短暫遺失時跳動。
- 握拳時捏合強度也會升高，所以會同時觸發 Trigger（類似用力握實體 Index）。

### 數字鍵盤（只在 SteamVR 執行中有效，NumLock 燈號不影響）

右手沒有被追蹤時，小鍵盤是獨立的右手控制器：

| 鍵 | VR 控制器 | 用途 |
|---|---|---|
| 5 | Trigger | 選取/點擊（按住＝拖曳） |
| 0 / Ins | Grip | 返回 |
| Enter | 觸控板按下 | — |
| + / 8，− / 2 | 觸控板上 / 下 | 捲動 |
| 4 / 6 | 觸控板左 / 右 | 方向 |
| * | System | 開關 SteamVR 控制台（叫回 Desktop+） |
| / | Menu | 遊戲選單 |

用頭部對準準星，按鍵點擊（雷射只在按住時出現）。

**NumLock = 開關手部偵測**：關閉時忽略 Flow 的手（手舉起來也不會變成 Index 控制器），小鍵盤固定是跟著頭的雷射。控制台裡**有準星 = 手部偵測關閉，沒有準星 = 開啟**（SteamVR 啟動時為開啟）。Flow 端的手部追蹤照常執行。

SteamVR 執行期間小鍵盤（含 NumLock）不會打字到電腦；只有小鍵盤的 ←（Backspace）照常。

### 清晰桌面（Desktop+ 面板以合成器圖層顯示）

串流的 SteamVR 畫面在 Flow 上會被取樣兩次（眼睛緩衝 → timewarp/鏡片變形），加上 SteamVR 合成時的一次，小字會模糊、有條紋。Flow 自己的系統介面（FlowOS）用的是 Wave 合成器圖層，只取樣一次，所以清晰（Meta 文件稱為 double sampling）。因此：

- 背景程式找出控制台正在顯示的 Desktop+ overlay（`elvissteinjr.DesktopPlus<n>`，按 1/2 切換的就是不同的 overlay），以 `IVROverlay::GetOverlayTexture` 讀它的貼圖、照面板的貼圖範圍裁切，NVENC/AMF 編碼後經 TCP 8005 送給 Flow。內容就是 Desktop+ 顯示的畫面（含它畫的游標）。
- 面板的位置／寬度／曲率由背景程式送給驅動（UDP 8003），驅動換算成 Flow 座標附在 8001 每幀（FLOWH264 v7）。
- Flow 第二個解碼器解碼後 1:1 複製進 Wave 貼圖佇列，以圖層（左右眼成對）放在面板位置；準星也畫在這層上。
- 面板本身用 `SetOverlayColor` 染黑：串流畫面比頭部慢約 55 ms，不染黑的話轉頭時模糊的那份會從圖層後面露出來。**不能改透明度**：Desktop+ 面板 alpha 為 0 或 0.01 時不再接受雷射點擊，改回來也要重開 Desktop+ 才恢復。
- 控制台關閉時暫停串流（連線保留，按 `*` 叫回來立即清晰）；Flow 斷線或串流沒在跑時面板恢復原色。
- **限制**：Flow 的 `WVR_GetMaxFrameLayerCount` = 4 是兩眼合計，扣掉兩眼內容層只剩一組圖層；送兩組時幀率掉到 14–26 fps。所以同時只有一個 Desktop+ overlay 是清晰的，其他（浮動視窗等）維持串流畫面。
- Desktop+ 面板是曲面（`install.ps1` 設 `Curvature=33`，半徑約 1.2 m，約等於面板到頭的距離）：大面板平放時越往旁邊看越斜，游標和準星會越偏。背景程式把曲率一起送出（FLOWH264 v7），Flow 用 Wave 圓柱圖層（實驗功能）顯示，準星也改算雷射和圓柱的交點；曲率 0 時照舊用平面。

### 音訊

- 擷取 Windows **預設輸出裝置**的迴路（loopback），轉成 48 kHz 16-bit 立體聲 PCM，經 TCP 8004 送到 Flow 播放；PC 喇叭照常出聲。
- Flow 端用 `AudioTrack` 播放，緩衝不夠時補靜音，避免斷音累積成延遲（記錄裡有 `queuedMs` 與補靜音次數）。
- 由 `driver_flowvr.enable_audio` 開關。

---

## 顯示卡與編碼器（NVIDIA NVENC / AMD AMF）

驅動與背景程式用同一組 GPU 編碼後端（`flow_video_encoder.cpp` 抽象層，兩個實作），兩者輸出同樣的 H.264，Flow 端不需要任何改動：

| 後端 | 平台 | 輸入 | 特性 |
|---|---|---|---|
| `flow_nvenc_encoder.cpp` | NVIDIA（`nvEncodeAPI64.dll`，隨 GeForce 驅動） | 直接吃 BGRA 貼圖 | 同步：這一呼叫拿到的就是剛送進去的幀 |
| `flow_amf_encoder.cpp` | AMD Radeon（`amfrt64.dll`，隨 Radeon 驅動） | 只吃 NV12，所以每幀先在 GPU 上做一次 BT.709 有限範圍的 BGRA→NV12 轉換 | **有一幀管線延遲**（AMF 既有行為） |

選擇方式：`flowvr_display.video_encoder` = `auto`（預設）/ `nvenc` / `amf`。`auto` 看 D3D11 裝置的顯示卡廠商；該廠商的後端初始化失敗時（例如獨顯沒接螢幕、DLL 不存在）會**自動改試另一個**並在記錄裡寫明，所以整台機器換卡不用改設定。

`flowvr_display.video_encoder_preset`（1–7，舊鍵名 `nvenc_preset` 仍有效）同時對應兩家的品質：NVENC 是 P1（最快）…P7（最好）；AMF 對應 speed（1–2）/ balanced（3–5）/ quality（6–7）。兩邊都跑超低延遲設定（不用 B 幀、不做前處理、不跳幀）。

**AMD 那一幀延遲怎麼處理**：既然同一幀的位元流下一次呼叫才拿到，驅動與背景程式就改用「封包自己帶的 PTS」去回查該幀的姿態序號與來源 slot，再送給 Flow。時間補償（timewarp）與畫質診斷（`flow_stream_input.ppm` 對應 `flow_stream_dump.h264`）都因此仍然正確；代價是編碼延遲多約一幀（≈ 13 ms）。AMF 輸出緩衝區自帶的時間戳不可靠（FFmpeg 也是自己維護佇列），所以 AMF 後端用內部的 pending 佇列按提交順序配對。

怎麼確認實際用了哪一個：

```
Steam\logs\vrserver.txt
  Flow virtual display encoder 100 Mbit/s, backend auto, preset 4
  Flow virtual display: AMF encoder on <卡名> (vendor 0x1002)
```

---

## 設定參考

### `pc\flow_steamvr_driver\flowvr\resources\settings\default.vrsettings`

改完要**重新建置**（`build.ps1` 會把 `flowvr\` 複製到 `build\dist\flowvr\`）再重開 SteamVR。

#### `driver_flowvr`

| 鍵 | 預設 | 說明 |
|---|---|---|
| `enable` | `true` | 驅動總開關 |
| `serial_number` | `VIVEFLOW-STEAMVR-001` | 顯示在 SteamVR 的序號 |
| `model_number` | `HTC VIVE Flow` | 顯示在 SteamVR 的型號 |
| `enable_keypad_controller` | `true` | 數字鍵盤控制器（右手） |
| `enable_hand_controllers` | `true` | 手部追蹤 → Index 控制器 |
| `enable_audio` | `true` | PC 聲音串流到 Flow |
| `enable_desktop_layer` | `true` | 清晰桌面圖層（TCP 8005） |
| `desktop_bitrate_mbps` | `30` | 清晰桌面的位元率（背景程式讀取） |
| `desktop_fps` | `60` | 清晰桌面的幀率（背景程式讀取） |
| `hand_pitch_offset_deg` | `0.0` | 手部雷射的俯仰微調（度） |

#### `flowvr_display`

| 鍵 | 預設 | 說明 |
|---|---|---|
| `window_x` / `window_y` | `0` / `0` | 虛擬顯示器在 Windows 桌面上的位置 |
| `window_width` / `window_height` | `3200` / `1600` | 虛擬顯示器的解析度（兩眼並排） |
| `render_width` / `render_height` | `1600` / `1600` | SteamVR 每眼的渲染解析度 |
| `stream_width` / `stream_height` | `3200` / `1600` | 送給 Flow 的畫面大小（左右並排，= 兩眼各 1600×1600） |
| `video_encoder` | `auto` | `auto` / `nvenc` / `amf`（見「顯示卡與編碼器」） |
| `video_encoder_preset` | `4` | 1（最快）–7（最好）；兩家共用 |
| `nvenc_preset` | `4` | 舊鍵名，`video_encoder_preset` 不存在時才用 |
| `stream_bitrate_mbps` | `100` | 主畫面位元率；Flow 解碼器上限約 120 |
| `tan_left` / `tan_right` | `-1.0639` / `1.0639` | 視野（Flow 實測值，約 94°）。**錯了畫面比例會不對** |
| `tan_top` / `tan_bottom` | `1.0639` / `-1.0639` | 同上（垂直） |
| `ipd_meters` | `0.0605` | 瞳距（Flow 實測 60.5 mm） |
| `vsync_to_photons` | `0.011` | 光子延遲補償（秒） |
| `display_frequency` | `75` | 面板更新率（Hz） |

### 其他設定

| 設定 | 位置 | 套用方式 |
|---|---|---|
| Flow 手部追蹤（預設開） | `hellovr.cpp` 的 `FLOW_DEFAULT_HANDS`；即時開關 `adb shell setprop debug.flow.hands 0/1` | APK 或 setprop |
| Flow 眼睛緩衝 1600、銳化（預設關） | `.../wvr_flow_probe/app/src/main/jni/hellovr.cpp` 開頭的 `FLOW_*` | `build.ps1` + `install.ps1` |
| Desktop+ 大小 248 cm、下移 22 cm、曲率 33、只在 Desktop+ 分頁 | `scripts\install.ps1` 開頭 `$DesktopPlusOverlay` | `install.ps1` |
| SteamVR overlay 品質 High、閒置 10 分鐘進入待機 | `scripts\install.ps1` 開頭 `$SteamVRSettings` | `install.ps1`（存在 `steamvr.vrsettings`，重開機仍有效） |
| 看片模式（關清晰桌面、120 Mbit/s、待機 24 小時） | `scripts\setup-pc.ps1 -Video` | 重跑該腳本（重建後要再跑一次） |

`-Video` 實際寫入（建置產物裡）：

| 設定 | 值 |
|---|---|
| `driver_flowvr.enable_desktop_layer` | `false` |
| `flowvr_display.stream_bitrate_mbps` | `120` |
| `power.turnOffScreensTimeout`（`steamvr.vrsettings`） | `86400` |

---

## 開發模式（不戴頭盔測試）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1        # 開啟
powershell -ExecutionPolicy Bypass -File scripts\dev-awake.ps1 -Off   # 關閉
```

- **Flow 不休眠**：Flow 的 OEM 服務在距離感測器判斷「沒戴」約 5 秒後強制休眠，Android 的螢幕設定蓋不過它。腳本等你遮住鼻樑內側的感測器（或戴上），偵測到「已戴上」後用 `dumpsys sensorservice restrict` 凍結感測器事件，之後拿下也維持清醒。頭部追蹤不受影響，**但手部追蹤會失效**（偵測不到手）。需要 ADB；Flow 重開機即失效。
- **SteamVR 閒置 30 分鐘才待機**（平常 10 分鐘）：頭盔放在桌上不動會被視為閒置，待機時畫面全黑。SteamVR 執行中透過背景程式的 `--idle-timeout` 修改，否則直接改 `steamvr.vrsettings`；`-Off` 改回 10 分鐘。

## 備用模式（不經 SteamVR 直接串流桌面）

只想知道「PC 桌面能不能串到 Flow」時可以走這條路：`pc\flow_desktop_streamer\`（.NET，會呼叫 Python 腳本）與 `Wave_Native_SDK\samples\wvr_flow_probe\tools\`（`live_h264_socket_sender.py`、`steamvr_compositor_bridge.py`、`h264_socket_sender.py`）。用 ffmpeg 抓桌面（`ddagrab`）/ 接收 SteamVR 驅動的 BGRA 畫面再編碼，直接送 TCP 8001。

這條路不需要 SteamVR 的顯示重導向，但也就沒有姿態回饋、控制器、音訊與清晰桌面。`--encoder` 可選 `x264` / `nvenc` / `amf` / `qsv` / `mf`。

---

## 疑難排解

### 連不上 / 沒有畫面

- **Flow 連上了但畫面全黑、沒有串流**：GPU 編碼器沒起來。看 `Steam\logs\vrserver.txt`（驅動的 `DriverLog`）是否有 `Flow virtual display encoder ... backend ...` 與 `Flow virtual display: <backend> encoder on <卡名>`，以及 `FLOWH264 encoder initialize failed: ...`（會寫出 NVENC/AMF 的失敗原因）；驅動記錄檔 `...\dist\flowvr\logs\flow_virtual_display_trace.log` 也會有同一行。常見原因與依序檢查：
  1. 防火牆：讓 SteamVR 的 `vrserver.exe` 使用私人網路（或重跑 `setup-pc.ps1` 用管理員權限自動加規則）。
  2. 不同網段：Flow 與 PC 要在同一個 Wi-Fi。
  3. 沒戴著頭盔（Flow 沒送姿態就不算連上）。
  4. `flowvr_display.video_encoder` 明確設成 `nvenc` 或 `amf` 來排除自動判斷。
  - 診斷指令：`powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch`（會直接告訴你連上沒有）。
- **畫面中央「選擇 USB 模式」**：Flow 接著 USB 時的系統提示，選「不執行任何動作」，或拔掉 USB。
- **「無法追蹤頭戴式裝置」**：環境太暗或鏡頭被擋住。

### 畫面灰掉 / 變暗 / 不會動

- **進 VR 遊戲畫面整片灰色（#4F5A64），但電腦上的遊戲視窗正常**：SteamVR 判定追蹤失效（`trackingLossColor`）。坐姿模式的遊戲（Unity 預設）需要追蹤空間的坐姿原點；驅動設定追蹤空間 "FLOW"，背景程式在 Flow 連上時補設坐姿原點。若仍發生，看背景程式記錄是否有 `seated zero pose`，或在 SteamVR 選單「重置坐姿位置」。
- **遊戲畫面變暗、解析度變低、不會動**：控制台還開著（舊版 SteamVR Unity 外掛在沒有輸入焦點時會暫停）。按 `*` 關閉。
- **只看到 SteamVR Home、沒有桌面**：按 `*` 打開控制台；或拿下頭盔再戴上（Flow 重新連線會再打開）。

### 桌面 / 設定

- **Desktop+ 設定被改回去**：Desktop+ 關閉時會寫回自己的設定；改設定前先關閉 SteamVR，或直接重跑 `install.ps1`。

### 建置

- **建置驅動失敗（檔案被鎖定）**：先關閉 SteamVR（`setup-pc.ps1` 會自己檢查並提示）。
- **`JDK 8 not found`**：`JAVA_HOME` 指向 JRE 而不是 JDK（要 `bin\javac.exe`），或版本不是 1.8。
- **`Wave SDK missing`**：`Wave_Native_SDK\repo\com\htc\vr\wvr_client` 不存在（見「Wave SDK」）。

### 診斷工具

- 驅動記錄：`pc\flow_steamvr_driver\build\dist\flowvr\logs\flow_virtual_display_trace.log`（每 2 秒一行 `stream stats`：SteamVR Present 頻率、編碼時間、送出幀率）
- SteamVR 實際輸出畫面：在 `...\dist\flowvr\logs\` 建立空檔 `dump_preview.request`，約 1 秒內產生 `flow_compositor_preview.ppm`
- Flow 畫面：`adb exec-out screencap -p > flow.png`（很暗，需要調整對比）
- Flow 記錄：`adb logcat -s FlowProbe vrsample`（`stream rates` 收/解碼幀率、`timewarp poseAge` 往返延遲，1 步 ≈ 13.3 ms）
- 背景程式記錄：`pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.log`
- 銳化即時調整：`adb shell setprop debug.flow.sharpen 0.8`（0–2，0 = 關）
- 清晰桌面：Flow 記錄 `desktop rates`（收/顯示幀率）、`Desktop+ panel shown/hidden`；背景程式記錄 `desktop layer: ...`、`Desktop+ panel blacked out/restored`。Flow 上暫時關閉：`adb shell setprop debug.flow.desktop 0`
- 畫質診斷（各階段全解析度擷取）：在 `...\dist\flowvr\logs\` 建立 `dump_stream.request` → 驅動寫出 `flow_stream_input.ppm`（編碼器輸入）與 `flow_stream_dump.h264`（之後 1 秒，用 ffmpeg 解最後一幀比對壓縮）；`adb shell setprop debug.flow.dumpeye <新值>` → Flow 寫出眼睛緩衝 `files/flow_eye_left.ppm`（`adb exec-out run-as com.htc.vr.samples.wvr_flow_probe cat files/flow_eye_left.ppm`）
- 眼睛緩衝大小：`debug.flow.eyebuffer`（App 啟動時讀，預設 1600）；Wave 銳化 `debug.flow.fse 0..1`（App 啟動時讀，只作用於內容層）
- 圖層 A/B 測試：`debug.flow.layertest 1` 兩眼顯示同一張圖（`files/test_1080.png` / `test_4k.png`，自行推入），一眼走眼睛緩衝、另一眼走合成器圖層；`.eye`、`.image`、`.width`、`.shape`、`.count` 切換
- 聲音：SteamVR 記錄 `Flow audio: ...`（擷取格式、每 10 秒送出秒數）；Flow 記錄的 `audio` 行（每 10 秒收到/丟棄的 10 ms 區塊、補靜音次數、排隊延遲 `queuedMs`、斷音累計）
- 手部：SteamVR 記錄 `Steam\logs\vrserver.txt` 每 2 秒一行 `Flow hand ...`（捏合、Trigger、各指彎曲、Grip、鍵盤）；Flow 記錄的 `hands` 行（追蹤頻率、左右手有效比例、捏合比例）

---

## 已知限制

- **Flow 只有 3DoF（旋轉）追蹤**：硬體上沒有位置追蹤感測器，站起來走動、彎腰都不行。可用性最高的場景是看影片與坐姿遊戲。
- Flow 面板每度像素少於桌面：小字偏軟，主要靠放大 Desktop+ 畫面改善（目前 248 cm）。
- 往返延遲約 55 ms；頭部轉動由 Wave timewarp 依渲染姿態補償，平移不補償。
- 小鍵盤的 ←（Backspace）與主鍵盤無法區分，所以不攔截。
- 清晰桌面同時只能一個 Desktop+ overlay（Flow 只有一組額外圖層，見「清晰桌面」）。
- 手部控制器還沒有手指骨架（`/input/skeleton`）：遊戲裡看到的是 Index 控制器模型，不會顯示手指動作。
- 搖桿只能用小鍵盤，手勢沒有對應。
- **AMD（AMF）路徑比 NVENC 多約一幀（≈ 13 ms）的編碼延遲**，因為 AMD 硬體編碼器有管線延遲；姿態與畫質診斷都已按幀對齊。實作完成並通過離線編譯檢查（mingw-w64 語法/物件），但**尚未在真實 AMD 機器上實測**——第一次跑請照「顯示卡與編碼器」那兩行記錄確認後端與送出幀率。
- Flow 拿下約 5 秒就休眠，無法在不 root 的情況下永久改長：秒數在 OEM 服務（`vive.wave.vr.oem`）的資料庫（`miac_config/psensor_duration`、`auto_shut_screen`），寫入需要系統簽章權限；建資料庫時讀的預設屬性 `wo_psensor_duration` / `wo_auto_shut_screen` 也被 SELinux 擋住、ADB 設不了。需要時用開發模式（重開機失效）。

## 待辦

- 手指骨架：把 Flow 的 26 個關節轉成 OpenVR 手部骨架，支援 Index 手指追蹤的遊戲（Half-Life: Alyx、VRChat 等）就能顯示手指。
- 長時間開手部追蹤時 Flow 的溫度與降頻（目前只測過幾分鐘）。
- 多鍵同時操作（擱置，之後會做）：手勢只有 Trigger、Grip，A/B/搖桿要靠小鍵盤，左手沒有其他按鍵。方案：
  1. 擴充手勢：用關節距離各自判斷拇指碰食指 / 中指 / 無名指（Trigger / A / B），可同時成立；搖桿仍無解。
  2. 手部追蹤 + 實體按鍵裝置（建議）：兩手各握一支藍牙手把（如 Joy-Con）連 PC，按鍵、搖桿、扳機來自手把，位置來自 Flow 手部追蹤（方向可用手把陀螺儀）。需先實測：握著手把時 Flow 是否還追蹤得到手。
  3. 兩者並存：沒拿手把用手勢，拿著手把用手把按鍵。
- 6DoF 可能性探測：Flow 的 manifest 宣告 `NumDoFHmd = "3,6DoF"`，App 也已經在讀 `pose.is6DoFPose`（記錄裡的 `hmdDoF=3|6`）。目前用 `WVR_PoseOriginModel_OriginOnHead` 取姿態，位置恆為原點，所以看不出真相；把 origin model 換成 ground/tracking-observer 再走動，就能從記錄裡的 `hmdDoF` 與 `hmdXYZ` 確定 FlowOS 到底能不能給 6DoF。**先驗證再投入**。
- 簡化建置環境（NDK/JDK 升級）以降低安裝門檻。

---

## 附錄 A：通訊協定（FLOWH264 v7）

以下由 `virtual_display_device.cpp`（PC 端送出）與 `MainActivity.java`（Flow 端解析）對照整理；**Flow 端的解析器是唯一權威**，改動前請先看那裡。所有整數為**大端**（網路序），float 以其 IEEE-754 位元樣式存放。

### 主畫面串流（TCP 8001）

連線後先送一次**串流標頭**：

| 欄位 | 型別 | 說明 |
|---|---|---|
| magic | `char[8]` | `FLOWH264` |
| version | u32 | 目前 `7` |
| width / height | u32 | 串流大小（3200×1600） |
| fps | u32 | 75 |
| layout | u32 | v4 起：`1` = 左右並排立體（主畫面）、`0` = 單眼（清晰桌面用） |
| sps_size + sps | u32 + bytes | H.264 SPS |
| pps_size + pps | u32 + bytes | H.264 PPS |

之後每個 **VCL NAL**（type 1–5）一筆，標頭固定 92 bytes：

| 欄位 | 型別 | 說明 |
|---|---|---|
| size | u32 | 後面 NAL 的位元組數 |
| pts_us | i64 | 這一幀的來源時間戳（微秒） |
| encoded_ready_ms | i64 | 編碼完成時間（epoch ms） |
| send_start_ms | i64 | 送出開始時間（epoch ms） |
| pose_sequence | u32 | v5 起：**這一幀渲染時用的頭部姿態序號**（timewarp 用；0 = 沒有新姿態） |
| panel[15] | u32 ×15 | v6/v7：Desktop+ 面板；`[0]` = 旗標（`0` = 隱藏），`[1..12]` = 3×4 列優先變換矩陣（已扣掉站姿高度偏移），`[13]` = 寬度（公尺），`[14]` = 曲率（v7） |
| nal | bytes | NAL 本體 |

版本演進：v4 加 `layout`；v5 加每幀的姿態序號；v6 加面板（旗標、3×4 矩陣、寬度）；v7 加面板曲率。

### 清晰桌面（TCP 8005）

同一個 `FLOWH264` magic，但 `version = 4`、`layout = 0`（單眼），且每筆：

| 欄位 | 型別 |
|---|---|
| size | u32（= 起始碼 4 bytes + NAL） |
| pts_us | i64 |
| encoded_ms | i64 |
| send_start_ms | i64 |
| frame | bytes（`00 00 00 01` + NAL） |
| send_end_ms | i64（在 frame **之後**） |

（Flow 端版本 ≥5 時會多讀一個 u32，但桌面圖層目前固定送 version 4。）

### 音訊（TCP 8004）

標頭 20 bytes：`FLOWAUD1`（8）+ u32 協定版本 + u32 取樣率 + u32 聲道數；之後是持續的 16-bit 立體聲 PCM。

### 姿態與手（UDP 8002，Flow → PC）

`PosePacket`（36 bytes，原生序 = little-endian）：

| 欄位 | 型別 |
|---|---|
| magic | u32 = `0x31504C46`（`FLP1`） |
| sequence | u32（每幀遞增，就是附在 8001 每幀的那個序號） |
| x / y / z | f32 |
| qx / qy / qz / qw | f32 |

`HandPacket`（644 bytes）：magic u32 = `0x31484C46`（`FLH1`）、sequence u32、`valid[2]`（左/右手是否有效）、`reserved[2]`、`pinch[2]`（食指捏合強度）、`joints[2][26][3]`（雙手 26 個關節的位置，單位公尺）。

### Discovery（UDP 8002，PC → Flow）

純文字，廣播 `FLOWH264_PC <port>`（port = 8001），週期性送出直到 Flow 連上。

---

## 附錄 B：檔案地圖

| 檔案 | 職責 |
|---|---|
| `scripts/setup-pc.ps1`、`setup-flow.ps1`、`setup.ps1` | 一鍵部署：機器端 / 頭顯端 / 兩者合跑（見「安裝細節」） |
| `scripts/setup-common.ps1` | 一鍵腳本共用的底層函式（前置檢查、SteamVR 路徑、adb、防火牆、網段比對） |
| `scripts/build.ps1`、`install.ps1`、`uninstall.ps1` | 實際做事的三支：建置、註冊/套設定、移除註冊 |
| `scripts/dev-awake.ps1` | 開發模式（Flow 不休眠 + SteamVR 閒置 30 分鐘） |
| `SETUP.md` | 操作流程與「人一共要動幾次手」清單 |
| `pc/flow_steamvr_driver/src/hmd_driver_factory.cpp`、`device_provider.cpp` | 驅動進入點：建立 HMD 裝置與虛擬顯示裝置 |
| `hmd_device_driver.cpp` | HMD 裝置：投影/IPD、姿態（來自 UDP 8002）、追蹤空間 "FLOW"、坐姿原點 |
| `virtual_display_device.cpp` | **核心**：桌面上建立虛擬顯示器、Present 縮放、編碼執行緒、TCP 8001 串流、discovery、畫質診斷 |
| `flow_video_encoder.{h,cpp}` | 編碼器抽象層：廠商偵測、`auto` 選擇與失敗回退 |
| `flow_nvenc_encoder.{h,cpp}` | NVIDIA NVENC 實作 |
| `flow_amf_encoder.{h,cpp}` | AMD AMF 實作（BGRA→NV12 GPU 轉換 + AMF 會期） |
| `hand_controller.cpp` | 手部關節 → Index 控制器（Trigger/Grip/各指彎曲） |
| `keyboard_mouse_controller.cpp` | 數字小鍵盤 → VR 控制器 |
| `flow_pointer_gate.h` | 指針門控（雷射只在按鍵時瞄準面板） |
| `flow_shared_input.h` / `flow_pose_sync.h` | 鍵盤與手部共用輸入狀態 / 跨模組的姿態序號與常數 |
| `flow_audio_streamer.cpp` | Windows 迴路擷取 → TCP 8004 |
| `pc/flow_dashboard_helper/main.cpp` | 控制台自動開關、坐姿原點、數字鍵盤攔截、面板位置送出 |
| `desktop_layer_streamer.cpp` | 清晰桌面：讀 Desktop+ overlay 貼圖 → 編碼 → TCP 8005 |
| `Wave_Native_SDK/samples/wvr_flow_probe/app/src/main/java/.../MainActivity.java` | Flow 端：discovery、TCP 連線、兩個 MediaCodec 解碼器、AudioTrack、平台整合 |
| `.../jni/hellovr.cpp` | Flow 端：Wave 會期、左右眼繪製、合成器圖層、準星、姿態與手部回傳、除錯 dump |
| `pc/flowvr/resources/input/*.json` | SteamVR 輸入繫結（Index 控制器、鍵盤滑鼠、HMD） |
| `flow_probe/` | 從 Flow 擷取的硬體資訊（編解碼器、顯示器、感測器、OEM 套件），僅供參考；含裝置序號的 `getprop.txt` 不公開 |

## 附錄 C：授權與致謝

- 上游專案：[`Mmc1xs/VEVE_FLOW_VR`](https://github.com/Mmc1xs/VEVE_FLOW_VR)（設計、驅動、Flow App、清晰桌面、手部追蹤都出自該作者）。這個 fork 加上 AMD AMF 支援、一鍵部署腳本與 VR 影片模式。
- `pc/openvr/`：Valve OpenVR SDK（submodule）。
- `pc/third_party/nv-codec-headers/`：NVENC API 標頭。
- `pc/third_party/amf/`：GPUOpen AMF 標頭（MIT，見該目錄 `LICENSE.txt`）。
  **注意**：該授權不授予媒體技術（含 H.264）的專利授權，散布編碼器的人要自行處理權利金；NVIDIA 路徑同理。
- `Wave_Native_SDK/`：HTC Wave SDK 依 VIVE SDK License Agreement 授權，**不在本倉庫內**。

Flow 端 App 與驅動的檔案標頭保留了 Valve / HTC 範例的著作權宣告（`Copyright (c) Valve Corporation` 的部分來自 OpenVR 範例）。
