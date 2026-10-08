<#
.SYNOPSIS
    Builds everything VEVE_FLOW_VR needs: SteamVR driver, dashboard helper and the Flow APK.

.DESCRIPTION
    Outputs:
      pc\flow_steamvr_driver\build\dist\flowvr\          SteamVR driver (registered by install.ps1)
      pc\flow_dashboard_helper\build\dist\               Dashboard helper + keypad capture
      Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk
      pc\flow_desktop_streamer\bin\Release\...           (only with -WithDesktopStreamer)

    Requirements: see README.md ("Build environment").

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -SkipApk
#>
param(
    [switch]$SkipDriver,
    [switch]$SkipHelper,
    [switch]$SkipApk,
    [switch]$WithDesktopStreamer,
    # Visual Studio generator for CMake.
    [string]$Generator = "Visual Studio 17 2022"
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }

function Invoke-Checked([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { Fail "$exe $($arguments -join ' ') failed (exit $LASTEXITCODE)" }
}

function Build-CMakeProject([string]$sourceDir) {
    $buildDir = Join-Path $sourceDir "build"
    if (-not (Test-Path (Join-Path $buildDir "CMakeCache.txt"))) {
        Invoke-Checked "cmake" @("-S", $sourceDir, "-B", $buildDir, "-G", $Generator, "-A", "x64")
    }
    Invoke-Checked "cmake" @("--build", $buildDir, "--config", "Release")
}

# cmake: from PATH, or the copy bundled with Visual Studio / Build Tools ("C++ CMake tools for
# Windows"). Installing only the Build Tools without a separate CMake is common.
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    $pfx = ${env:ProgramFiles(x86)}
    if (-not $pfx) { $pfx = $env:ProgramFiles }
    $vs = $null
    if ($pfx) {
        $vswhere = Join-Path $pfx "Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswhere) {
            $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        }
    }
    if ($vs) {
        $bundled = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
        if (Test-Path (Join-Path $bundled "cmake.exe")) {
            $env:PATH = $bundled + ";" + $env:PATH
            Write-Host "Using the CMake that ships with Visual Studio: $bundled"
        }
    }
}
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    Fail "cmake not found in PATH. Install CMake (winget install Kitware.CMake) or add the 'C++ CMake tools for Windows' component to Visual Studio / Build Tools."
}

# The driver DLL and helper exe are locked while SteamVR runs.
if ((-not $SkipDriver -or -not $SkipHelper) -and (Get-Process vrserver, flow_dashboard_helper -ErrorAction SilentlyContinue)) {
    Fail "SteamVR (or the dashboard helper) is running. Quit SteamVR first, then build again."
}

if (-not $SkipDriver) {
    Step "SteamVR driver (pc\flow_steamvr_driver)"
    if (-not (Test-Path (Join-Path $Root "pc\openvr\headers\openvr_driver.h"))) {
        Fail "pc\openvr is missing. Run: git submodule update --init"
    }
    Build-CMakeProject (Join-Path $Root "pc\flow_steamvr_driver")
}

if (-not $SkipHelper) {
    Step "Dashboard helper (pc\flow_dashboard_helper)"
    Build-CMakeProject (Join-Path $Root "pc\flow_dashboard_helper")
}

if (-not $SkipApk) {
    Step "Flow APK (Wave_Native_SDK\samples\wvr_flow_probe)"
    $probe = Join-Path $Root "Wave_Native_SDK\samples\wvr_flow_probe"

    # The Wave SDK is not in the repository (VIVE SDK license); see README "Wave SDK".
    if (-not (Test-Path (Join-Path $Root "Wave_Native_SDK\repo\com\htc\vr\wvr_client"))) {
        Fail "Wave SDK missing: copy the 'repo' folder of the Wave Native SDK 4.5.0 download to Wave_Native_SDK\repo (see README)."
    }

    # Android Gradle Plugin 3.5 needs a JDK 8 (javac, not just a JRE): JAVA_HOME if it is one,
    # else tools\jdk8\<jdk>.
    $javaHome = $null
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\javac.exe"))) {
        # via cmd: in Windows PowerShell 5.1, redirecting a native exe's stderr throws under "Stop"
        $version = cmd /c "`"$(Join-Path $env:JAVA_HOME 'bin\java.exe')`" -version 2>&1" | Out-String
        if ($version -match 'version "1\.8') { $javaHome = $env:JAVA_HOME }
    }
    if (-not $javaHome) {
        # tools\jdk8\<jdk>\ , and tools\jdk8\ itself for an archive unpacked without its own
        # folder. The version is checked so a stray folder there cannot be picked up.
        $bundledRoot = Join-Path $Root "tools\jdk8"
        $candidates = @($bundledRoot) + @(Get-ChildItem $bundledRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($candidate in $candidates) {
            $java = Join-Path $candidate "bin\java.exe"
            if (-not (Test-Path (Join-Path $candidate "bin\javac.exe"))) { continue }
            $version = cmd /c "`"$java`" -version 2>&1" | Out-String
            if ($version -match 'version "1\.8') { $javaHome = $candidate; break }
        }
    }
    if (-not $javaHome) { Fail "JDK 8 not found. Set JAVA_HOME to a JDK 8, or unpack Temurin JDK 8 into $Root\tools\jdk8 (the folder holding bin\java.exe and bin\javac.exe)." }

    # local.properties is machine specific (ignored by git): write it from the Android SDK location.
    $sdk = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, (Join-Path $env:LOCALAPPDATA "Android\Sdk")) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $sdk) { Fail "Android SDK not found. Install it (Android Studio) or set ANDROID_SDK_ROOT." }
    $ndk = Join-Path $sdk "ndk\21.4.7075529"
    if (-not (Test-Path $ndk)) { Fail "Android NDK 21.4.7075529 not found under $sdk\ndk (install it with the SDK Manager)." }
    $props = "sdk.dir=$($sdk -replace '\\','\\' -replace ':','\:')`nndk.dir=$($ndk -replace '\\','\\' -replace ':','\:')`n"
    [IO.File]::WriteAllText((Join-Path $probe "local.properties"), $props)

    $previousJavaHome = $env:JAVA_HOME
    $env:JAVA_HOME = $javaHome
    Push-Location $probe
    try {
        Invoke-Checked ".\gradlew.bat" @("assembleBit64Debug")
    }
    finally {
        Pop-Location
        $env:JAVA_HOME = $previousJavaHome
    }
}

if ($WithDesktopStreamer) {
    Step "Desktop streamer fallback (pc\flow_desktop_streamer)"
    Invoke-Checked "dotnet" @("build", (Join-Path $Root "pc\flow_desktop_streamer\FlowDesktopStreamer.csproj"), "-c", "Release", "-r", "win-x64", "--no-self-contained")
}

Step "Done"
$artifacts = @(
    "pc\flow_steamvr_driver\build\dist\flowvr\bin\win64\driver_flowvr.dll",
    "pc\flow_dashboard_helper\build\dist\flow_dashboard_helper.exe",
    "Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk"
)
foreach ($artifact in $artifacts) {
    $path = Join-Path $Root $artifact
    $state = if (Test-Path $path) { (Get-Item $path).LastWriteTime.ToString("yyyy-MM-dd HH:mm") } else { "missing" }
    Write-Host ("  {0,-16} {1}" -f $state, $artifact)
}
Write-Host ""
Write-Host "Next: powershell -ExecutionPolicy Bypass -File scripts\install.ps1"
