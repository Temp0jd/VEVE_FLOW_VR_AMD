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

.PARAMETER Check
    Only check that everything is installed and downloaded; build and register nothing. Prints
    one line per prerequisite (what was found, and how to fix what is missing) and exits with
    code 0 when ready to build, 1 otherwise.

.PARAMETER WithDesktopStreamer
    Also build the optional Python/ffmpeg fallback streamer (needs the .NET SDK).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Video
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -Check
    powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1 -SkipBuild
#>
param(
    [switch]$Video,
    [switch]$SkipBuild,
    [switch]$SkipApk,
    [switch]$SkipInstall,
    [switch]$NoFirewall,
    [switch]$Check,
    [switch]$WithDesktopStreamer
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "setup-common.ps1")

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$DriverDir = Join-Path $Root "pc\flow_steamvr_driver\build\dist\flowvr"
$HelperDir = Join-Path $Root "pc\flow_dashboard_helper\build\dist"
$Apk = Join-Path $Root "Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk"

# ---- Preflight: check everything, then report it all at once -----------------------------------
Step "Preflight (PC)"

# -Check means "am I ready to build?": always verify the toolchain, then exit with a plain list.
$needsBuild = -not $SkipBuild
if ($Check) {
    $needsBuild = $true
    $needsApk = $true
} else {
    $needsApk = (-not $SkipBuild) -and (-not $SkipApk)
}

# One entry per prerequisite: Name, Ok, Detail (what was found), Fix, Blocking (does it stop the
# build, or is it informational such as Desktop+ in -Video mode).
$checks = @()

# CMake: from PATH, or the copy bundled with Visual Studio / Build Tools.
$cmake = Find-Cmake
if ($cmake) {
    $checks += @{ Name = "CMake"; Ok = $true; Detail = "$($cmake.Path) [$($cmake.Source)]"; Source = $cmake.Source; Fix = ""; Blocking = $needsBuild }
    if ($cmake.Source -eq "Visual Studio") {
        # build.ps1 runs as a child process and inherits this.
        $env:PATH = (Split-Path $cmake.Path) + ";" + $env:PATH
    }
} else {
    $checks += @{ Name = "CMake"; Ok = $false; Detail = "not found"; Source = ""; Blocking = $needsBuild
        Fix = "Install it (winget install Kitware.CMake), or add the 'C++ CMake tools for Windows' component when installing Visual Studio / Build Tools." }
}

# Visual Studio 2022 (or the standalone Build Tools) with the C++ toolchain. The instance details
# matter: CMake is told to use this exact instance, because its own discovery misses an install in
# a non-default folder and misses Build Tools ('could not find any instance of Visual Studio').
$visualStudio = Get-VisualStudioInstance
if ($visualStudio) {
    $name = $visualStudio.DisplayName
    if (-not $name) { $name = "Visual Studio / Build Tools" }
    $checks += @{ Name = "Visual Studio"; Ok = $true; Fix = ""; Blocking = $needsBuild
        Detail = "$($visualStudio.Path) - $name $($visualStudio.Version)" }
} else {
    $checks += @{ Name = "Visual Studio"; Ok = $false; Detail = "C++ toolchain not found"; Blocking = $needsBuild
        Fix = "Install Visual Studio 2022 or newer (2026 works too) with the 'Desktop development with C++' workload - Community edition is free - or the matching Build Tools." }
}

# CMake's Visual Studio generators are version specific (VS 2026 / v18 needs "Visual Studio 18
# 2026" and CMake 4.2+), so surface that here instead of letting the build fail on it.
if ($visualStudio) {
    $generator = Get-VisualStudioGenerator (Get-MajorVersion $visualStudio.Version)
    if ($generator) {
        $generatorMajor = Get-GeneratorMajorVersion $generator
        $cmakeVersion = $null
        if ($cmake) { $cmakeVersion = Get-CMakeVersion $cmake.Path }
        $hasVersion = [bool]$cmakeVersion
        if ($generatorMajor -ge 18 -and (-not $hasVersion -or $cmakeVersion -lt [version]"4.2")) {
            $bundledCmake = Find-BundledCmake
            if ($bundledCmake) {
                $checks += @{ Name = "CMake generator"; Ok = $true; Fix = ""; Blocking = $needsBuild
                    Detail = "$generator (this CMake cannot create it; the one bundled with Visual Studio will be used)" }
            } else {
                $checks += @{ Name = "CMake generator"; Ok = $false; Blocking = $needsBuild
                    Fix = "Upgrade CMake (winget upgrade Kitware.CMake), or add the 'C++ CMake tools for Windows' component to Visual Studio."
                    Detail = "$generator needs CMake 4.2+$(if ($hasVersion) { ", this one is $cmakeVersion" })" }
            }
        } else {
            $detail = $generator
            if ($hasVersion) { $detail = "$generator (CMake $cmakeVersion)" }
            $checks += @{ Name = "CMake generator"; Ok = $true; Detail = $detail; Fix = ""; Blocking = $needsBuild }
        }
    }
}

# SteamVR: the driver is registered with it and it owns the stream sockets.
$steamVrPaths = Get-SteamVRPaths
if ($steamVrPaths) {
    $checks += @{ Name = "SteamVR"; Ok = $true; Detail = $steamVrPaths.Runtime; Fix = ""; Blocking = $true }
} else {
    $checks += @{ Name = "SteamVR"; Ok = $false; Detail = "%LOCALAPPDATA%\openvr\openvrpaths.vrpath not found"; Blocking = $true
        Fix = "Install SteamVR from Steam and start it once." }
}

if ($needsApk) {
    # Wave SDK (the local Maven package the Flow app builds against).
    $waveRepo = Join-Path $Root "Wave_Native_SDK\repo\com\htc\vr\wvr_client"
    $waveAar = Get-ChildItem -Path $waveRepo -Filter "wvr_client-*.aar" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($waveAar) {
        $checks += @{ Name = "Wave SDK"; Ok = $true; Fix = ""; Blocking = $true
            Detail = "$($waveAar.Name) ($([math]::Round($waveAar.Length / 1MB, 1)) MB)" }
    } else {
        $checks += @{ Name = "Wave SDK"; Ok = $false; Detail = "Wave_Native_SDK\repo\com\htc\vr\wvr_client is missing or empty"; Blocking = $true
            Fix = "Download 'Wave Native SDK 4.5.0' from https://developer.vive.com (login required), then copy its 'repo' folder to Wave_Native_SDK\repo." }
    }

    # Android SDK (platform-tools too, since the headset is driven over adb).
    $sdk = Find-AndroidSdk
    if ($sdk) {
        $adb = Find-Adb
        $detail = $sdk
        if ($adb) { $detail = "$sdk (adb: $adb)" } else { $detail = "$sdk (platform-tools/adb missing)" }
        $checks += @{ Name = "Android SDK"; Ok = [bool]$adb; Detail = $detail; Blocking = $true
            Fix = "Install the platform-tools into the SDK (sdkmanager 'platform-tools') or add them to PATH." }
    } else {
        $checks += @{ Name = "Android SDK"; Ok = $false; Detail = "not found"; Blocking = $true
            Fix = "Install Android Studio (or the command line tools) and set ANDROID_SDK_ROOT." }
    }

    # Android NDK, exactly the version the Wave sample build files ask for.
    if ($sdk) {
        $ndk = Find-AndroidNdk $sdk
        if ($ndk) {
            $revision = ""
            $properties = Join-Path $ndk "source.properties"
            if (Test-Path $properties) {
                $line = Select-String -Path $properties -Pattern "^Pkg\.Revision\s*=\s*(.+)$" | Select-Object -First 1
                if ($line) { $revision = " (Pkg.Revision = $($line.Matches[0].Groups[1].Value.Trim()))" }
            }
            $checks += @{ Name = "Android NDK"; Ok = $true; Detail = "$ndk$revision"; Fix = ""; Blocking = $true }
        } else {
            # Say which versions are actually there: "none" and "the wrong one" need different
            # fixes, and the version is pinned because Application.mk still says
            # APP_PLATFORM := android-10, which newer NDKs reject.
            $installedNdk = @(Get-ChildItem (Join-Path $sdk "ndk") -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $detail = "none installed under $sdk\ndk"
            if ($installedNdk.Count -gt 0) { $detail = "need 21.4.7075529, found: $($installedNdk -join ', ')" }
            $checks += @{ Name = "Android NDK"; Ok = $false; Detail = $detail; Blocking = $true
                Fix = "Install exactly that version with the SDK Manager: sdkmanager 'ndk;21.4.7075529' (in Android Studio: SDK Tools tab, tick 'Show package details' first)." }
        }
    } else {
        $checks += @{ Name = "Android NDK"; Ok = $false; Detail = "unknown (no Android SDK)"; Blocking = $true
            Fix = "Install the Android SDK first, then sdkmanager 'ndk;21.4.7075529'." }
    }

    # JDK 8 (the Wave sample uses Gradle 5.6.1 / AGP 3.5, which need a real JDK 8).
    $jdk8 = Find-Jdk8 $Root
    if ($jdk8) {
        $checks += @{ Name = "JDK 8"; Ok = $true; Detail = $jdk8; Fix = ""; Blocking = $true }
    } else {
        $why = Describe-Jdk8Problem $Root
        $detail = "not found"
        if ($why) { $detail = $why }
        $checks += @{ Name = "JDK 8"; Ok = $false; Detail = $detail; Blocking = $true
            Fix = "Install the Temurin JDK 8 (the JDK: it contains bin\javac.exe, the JRE does not), then either set JAVA_HOME to it or unpack it into $Root\tools\jdk8." }
    }
}

# Desktop+ is informational: only needed to see the PC desktop in VR.
if ($Video) {
    $checks += @{ Name = "Desktop+"; Ok = $true; Detail = "not needed with -Video"; Fix = ""; Blocking = $false }
} else {
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
    if ($desktopPlus) {
        $checks += @{ Name = "Desktop+"; Ok = $true; Detail = $desktopPlus; Fix = ""; Blocking = $false }
    } else {
        $checks += @{ Name = "Desktop+"; Ok = $false; Detail = "not installed"; Blocking = $false
            Fix = "Only needed to see the PC desktop in VR. Install it from Steam (free, 1494460) and start it once, or pass -Video to skip it on purpose." }
    }
}

# openvr submodule: not a download the user does, it is fetched below.
$openVrHeader = Join-Path $Root "pc\openvr\headers\openvr_driver.h"
$checks += @{ Name = "openvr headers"; Ok = (Test-Path $openVrHeader); Blocking = $false
    Detail = $(if (Test-Path $openVrHeader) { "pc\openvr" } else { "pc\openvr is empty (fetched automatically)" })
    Fix = "Nothing to do: setup-pc.ps1 runs 'git submodule update --init' (needs git in PATH)." }

# Disk space: informational, the build writes a few GB into this repository.
$repoDrive = (Get-Item $Root).PSDrive
$systemDriveName = "C"
if ($env:SystemDrive) { $systemDriveName = $env:SystemDrive.TrimEnd(':') }
$systemFree = "?"
$system = Get-PSDrive $systemDriveName -ErrorAction SilentlyContinue
if ($system) { $systemFree = [math]::Round($system.Free / 1GB, 1) }
$checks += @{ Name = "Disk space"; Ok = $true; Blocking = $false; Fix = ""
    Detail = "$($repoDrive.Name): $([math]::Round($repoDrive.Free / 1GB, 1)) GB free (repository); $($systemDriveName): $systemFree GB free" }

# -Check: report and stop here, before anything is built or registered.
if ($Check) {
    Write-Host ""
    $failed = Show-CheckList $checks
    Write-Host ""
    if ($failed -eq 0) {
        Write-Host "Ready to build. Run: powershell -ExecutionPolicy Bypass -File scripts\setup-pc.ps1" -ForegroundColor Green
        exit 0
    }
    Write-Host "Fix the items marked [miss] above, then run this check again." -ForegroundColor Yellow
    exit 1
}

$problems = @()
$notes = @()
# The loop variable must not be called $check: PowerShell variable names are case-insensitive, so
# that would be the -Check switch's own [switch] variable, which only accepts a boolean.
foreach ($item in $checks) {
    if (-not $item.Ok) {
        if ($item.Blocking) { $problems += "$($item.Name): $($item.Detail). $($item.Fix)" }
        else { $notes += "$($item.Name): $($item.Detail). $($item.Fix)" }
    } elseif ($item.Name -eq "CMake" -and $item.Source -eq "Visual Studio") {
        Note "using the CMake that ships with Visual Studio: $($item.Detail -replace ' \[[^\]]+\]$', '')"
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
                "updated" { Note "updated inbound rule (the program path had changed): $($target.Name)" }
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
