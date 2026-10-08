<#
.SYNOPSIS
    PC side in one command: check prerequisites, fetch openvr, build everything, register with
    SteamVR, open the firewall. No headset needed.

.DESCRIPTION
    Run this once per PC on a fresh clone, then re-run scripts\setup-flow.ps1 for the headset.

    It checks every prerequisite first and reports all of them at once, builds the SteamVR driver,
    the dashboard helper and the Flow APK (the APK is a file; installing it on the headset is
    scripts\setup-flow.ps1's job), registers everything with SteamVR, and adds the inbound
    firewall rules so the Flow can reach this PC.

    Things it cannot do for you (accounts, licences, interactive installers):
      - Steam + SteamVR, and Desktop+ (free, Steam app 1494460) unless you pass -Video
      - Visual Studio 2022 with the "Desktop development with C++" workload
      - Android SDK + NDK 21.4.7075529, plus a full JDK 8 (JAVA_HOME, or tools\jdk8\<jdk>)
      - the HTC Wave Native SDK 4.5.0 "repo" folder (VIVE SDK licence) -> Wave_Native_SDK\repo
      - Steam login

.PARAMETER Video
    Preset for watching VR video (DeoVR and friends) instead of desktop work: skips Desktop+,
    turns the sharp desktop layer off, raises the stream bitrate to the Flow decoder's maximum
    120 Mbit/s, and stops SteamVR from going to standby after 10 idle minutes. Written to the
    built dist\ settings, which build.ps1 overwrites: re-run with -Video after a rebuild.

.PARAMETER SkipBuild
    Register / configure only, using what is already built.

.PARAMETER SkipApk
    Do not build the Flow APK (use it if you only care about the PC side and will install the
    headset app another way).

.PARAMETER SkipInstall
    Build only; do not register anything with SteamVR.

.PARAMETER NoFirewall
    Do not touch Windows Firewall (see the README note about allowing vrserver on the private
    network instead).

.PARAMETER WithDesktopStreamer
    Also build the optional Python/ffmpeg fallback streamer (needs the .NET SDK).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Video
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -SkipBuild
#>
param(
    [switch]$Video,
    [switch]$SkipBuild,
    [switch]$SkipApk,
    [switch]$SkipInstall,
    [switch]$NoFirewall,
    [switch]$WithDesktopStreamer
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "setup-common.ps1")

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$DriverDir = Join-Path $Root "pc\flow_steamvr_driver\build\dist\flowvr"
$HelperDir = Join-Path $Root "pc\flow_dashboard_helper\build\dist"
$Apk = Join-Path $Root "Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk"

# ---- Preflight: collect everything that is missing, then report it all at once -----------------
Step "Preflight (PC)"

$needsApk = (-not $SkipBuild) -and (-not $SkipApk)
$problems = @()
$notes = @()

if (-not $SkipBuild) {
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        $problems += "cmake not in PATH. Install it (winget install Kitware.CMake) or use the one from Visual Studio's CMake component and add it to PATH."
    }
    if (-not (Test-VisualStudio)) {
        $problems += "Visual Studio 2022 with the 'Desktop development with C++' workload not found (the Community edition is free). cmake needs its compiler."
    }
}

if ($needsApk) {
    if (-not (Test-Path (Join-Path $Root "Wave_Native_SDK\repo\com\htc\vr\wvr_client"))) {
        $problems += "Wave SDK missing. Download 'Wave Native SDK 4.5.0' from https://developer.vive.com (login required), then copy its 'repo' folder to Wave_Native_SDK\repo (see README 'Wave SDK')."
    }
    $sdk = Find-AndroidSdk
    if (-not $sdk) {
        $problems += "Android SDK not found. Install Android Studio (or the command line tools) and set ANDROID_SDK_ROOT."
    } elseif (-not (Find-AndroidNdk $sdk)) {
        $problems += "Android NDK 21.4.7075529 not found under $sdk\ndk. Install exactly that version with the SDK Manager."
    }
    if (-not (Find-Jdk8 $Root)) {
        $problems += "JDK 8 not found. Set JAVA_HOME to a JDK 8, or unpack Temurin JDK 8 into tools\jdk8\<jdk> (see README '建置環境')."
    }
}

if (-not (Get-SteamVRPaths)) {
    $problems += "SteamVR is not installed or was never started (no %LOCALAPPDATA%\openvr\openvrpaths.vrpath). Install SteamVR from Steam and start it once."
}

if ($Video) {
    Note "preset: VR video (-Video): Desktop+ is optional, desktop layer off, 120 Mbit/s, no idle standby"
} else {
    # Desktop+ is only needed to see the PC desktop in VR.
    $pfx = Get-ProgramFilesX86
    $vdf = $null
    if ($pfx) { $vdf = Join-Path $pfx "Steam\steamapps\libraryfolders.vdf" }
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if ($steam) { $vdf = Join-Path $steam "steamapps\libraryfolders.vdf" }
    $desktopPlus = $null
    if ($vdf -and (Test-Path $vdf)) {
        foreach ($library in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' |
                              ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' })) {
            if (Test-Path (Join-Path $library "steamapps\common\DesktopPlus\DesktopPlus.exe")) {
                $desktopPlus = Join-Path $library "steamapps\common\DesktopPlus"
            }
        }
    }
    if (-not $desktopPlus) {
        $notes += "Desktop+ is not installed, so the PC desktop will not be visible in VR. Install it from Steam (free, 1494460), start it once, then re-run; or pass -Video to skip it on purpose."
    }
}

foreach ($note in $notes) { Warn $note }
if ($problems.Count -gt 0) { Fail-Listed $problems "PC" }
Note "all prerequisites present"

# ---- openvr submodule -------------------------------------------------------------------------
if ((-not $SkipBuild) -and (-not (Test-Path (Join-Path $Root "pc\openvr\headers\openvr_driver.h")))) {
    Step "openvr submodule"
    $git = Find-InPath @("git", "git.exe")
    if (-not $git) { Fail "pc\openvr is empty and git is not in PATH. Run 'git submodule update --init' manually." }
    & $git -C $Root submodule update --init
    if ($LASTEXITCODE -ne 0) { Fail "git submodule update --init failed (exit $LASTEXITCODE)" }
    Note "fetched pc\openvr"
}

# ---- Build (driver, helper, APK) --------------------------------------------------------------
if ($SkipBuild) {
    Step "Build skipped"
} else {
    Step "Build (scripts\build.ps1)"
    $buildArgs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "build.ps1"))
    if ($SkipApk) { $buildArgs += "-SkipApk" }
    if ($WithDesktopStreamer) { $buildArgs += "-WithDesktopStreamer" }
    & powershell @buildArgs
    if ($LASTEXITCODE -ne 0) { Fail "build failed (exit $LASTEXITCODE). Scroll up for the first error." }
}

# ---- Install (driver, SteamVR settings, Desktop+, helper) -------------------------------------
if ($SkipInstall) {
    Step "Install skipped"
} else {
    Step "Install (scripts\install.ps1 -SkipApk)"
    $installArgs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "install.ps1"), "-SkipApk")
    if ($Video) { $installArgs += "-SkipDesktopPlus" }
    & powershell @installArgs
    if ($LASTEXITCODE -ne 0) { Fail "install failed (exit $LASTEXITCODE). Scroll up for the first error." }
}

# ---- Firewall: the Flow connects in to this PC, so inbound must be allowed ---------------------
if (-not $NoFirewall) {
    Step "Windows Firewall"
    $steamVr = Get-SteamVRPaths
    $targets = @()
    if ($steamVr -and $steamVr.Runtime) {
        $targets += @{ Name = "VEVE FLOW VR (SteamVR)"; Path = (Join-Path $steamVr.Runtime "bin\win64\vrserver.exe") }
    }
    $targets += @{ Name = "VEVE FLOW VR (dashboard helper)"; Path = (Join-Path $HelperDir "flow_dashboard_helper.exe") }

    if (-not (Test-Elevated)) {
        Warn "not running as administrator: skipped. The Flow cannot connect until inbound is allowed."
        Note "either re-run this script from an elevated PowerShell, or allow SteamVR's vrserver.exe on the private network when Windows asks."
    } else {
        foreach ($target in $targets) {
            $result = Add-FirewallRule $target.Name $target.Path
            switch ($result) {
                "added" { Note "added inbound rule: $($target.Name)" }
                "present" { Note "inbound rule already present: $($target.Name)" }
                "missing" { Warn "not found, skipped: $($target.Path)" }
                "unsupported" { Warn "New-NetFirewallRule unavailable; allow vrserver.exe on the private network when Windows asks." }
                default { Warn "could not add the rule for $($target.Name); allow it when Windows asks instead." }
            }
        }
    }
}

# ---- VR video preset --------------------------------------------------------------------------
if ($Video) {
    Step "VR video preset"

    $driverSettings = Join-Path $DriverDir "resources\settings\default.vrsettings"
    if (Test-Path $driverSettings) {
        Stop-SteamVR
        $settings = Get-Content $driverSettings -Raw | ConvertFrom-Json
        if (-not ($settings.PSObject.Properties.Name -contains "flowvr_display")) {
            Warn "flowvr_display missing in $driverSettings; skipped the encoder tweaks"
        } else {
            $settings.flowvr_display | Add-Member -NotePropertyName "stream_bitrate_mbps" -NotePropertyValue 120 -Force
            Note "flowvr_display.stream_bitrate_mbps = 120 (the Flow decoder's maximum)"
            if ($settings.PSObject.Properties.Name -contains "driver_flowvr") {
                $settings.driver_flowvr | Add-Member -NotePropertyName "enable_desktop_layer" -NotePropertyValue $false -Force
                Note "driver_flowvr.enable_desktop_layer = false (no sharp desktop layer without Desktop+)"
            }
            [IO.File]::WriteAllText($driverSettings, ($settings | ConvertTo-Json -Depth 32), $Utf8NoBom)
        }
    } else {
        Warn "$driverSettings not found (not built?); skipped the encoder tweaks"
    }

    $steamVr = Get-SteamVRPaths
    if ($steamVr -and $steamVr.Config) {
        $settingsPath = Join-Path $steamVr.Config "steamvr.vrsettings"
        if (Test-Path $settingsPath) {
            Stop-SteamVR
            $steamVrSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if (-not ($steamVrSettings.PSObject.Properties.Name -contains "power")) {
                $steamVrSettings | Add-Member -NotePropertyName "power" -NotePropertyValue (New-Object PSObject)
            }
            # 24 h: a film or a long still scene must not be mistaken for an idle headset.
            $steamVrSettings.power | Add-Member -NotePropertyName "turnOffScreensTimeout" -NotePropertyValue 86400.0 -Force
            [IO.File]::WriteAllText($settingsPath, ($steamVrSettings | ConvertTo-Json -Depth 32), $Utf8NoBom)
            Note "power.turnOffScreensTimeout = 86400 s (no standby while watching)"
            Note "the original is backed up as $settingsPath.bak-veve (made by install.ps1)"
        }
    }
    Note "a rebuild overwrites the driver settings: re-run this script with -Video after building"
}

# ---- Verify -----------------------------------------------------------------------------------
Step "Verify (PC)"

$artifacts = @(
    @{ Name = "driver DLL"; Path = (Join-Path $DriverDir "bin\win64\driver_flowvr.dll") },
    @{ Name = "helper exe"; Path = (Join-Path $HelperDir "flow_dashboard_helper.exe") },
    @{ Name = "Flow APK"; Path = $Apk }
)
foreach ($artifact in $artifacts) {
    if (Test-Path $artifact.Path) {
        Note ("{0,-12} {1}" -f $artifact.Name, (Get-Item $artifact.Path).LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
    } else {
        Warn ("{0,-12} missing: {1}" -f $artifact.Name, $artifact.Path)
    }
}

$steamVr = Get-SteamVRPaths
$registered = $false
if ($steamVr -and $steamVr.Runtime) {
    $vrPathReg = Join-Path $steamVr.Runtime "bin\win64\vrpathreg.exe"
    if (Test-Path $vrPathReg) {
        $registered = [bool](& $vrPathReg show | Select-String -SimpleMatch "flowvr")
    }
}
if ($registered) { Note "driver: registered with SteamVR" } else { Warn "driver: not found in 'vrpathreg show'" }

$helperLog = Join-Path $HelperDir "flow_dashboard_helper.log"
if (Test-Path $helperLog) { Note ("helper log: {0}" -f (Get-Content $helperLog -Tail 1)) }

# ---- Next -------------------------------------------------------------------------------------
Step "PC side ready"
Note "Next: connect the Flow over USB (USB debugging on) and run: powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1"
