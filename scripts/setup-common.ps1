# Shared helpers for scripts\setup*.ps1. Dot-source it; do not run it directly.
#
# Everything here has to work on Windows PowerShell 5.1 and on PowerShell 7, and must tolerate
# a machine where an environment variable ($env:LOCALAPPDATA, ${env:ProgramFiles(x86)}) is unset:
# Join-Path throws on a null path, which is how the original install.ps1 could fail on a 32-bit
# or ARM Windows install.

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Note($text) { Write-Host "    $text" }
function Warn($text) { Write-Host "    WARNING: $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "ERROR: $text" -ForegroundColor Red; exit 1 }

# Prints every collected problem with its fix instead of stopping at the first one.
function Fail-Listed([string[]]$problems, [string]$what) {
    Write-Host ""
    Write-Host "Cannot continue with the $what setup until these are fixed:" -ForegroundColor Red
    foreach ($problem in $problems) { Write-Host "  - $problem" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Everything else was already checked; re-run after fixing the items above."
    exit 1
}

function Get-ProgramFilesX86 {
    $value = ${env:ProgramFiles(x86)}
    if (-not $value) { $value = $env:ProgramFiles }
    return $value
}

function Get-VrPathsFile {
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path $env:LOCALAPPDATA "openvr\openvrpaths.vrpath")
}

# SteamVR runtime + config dirs as registered by Steam; $null when SteamVR was never run.
function Get-SteamVRPaths {
    $file = Get-VrPathsFile
    if (-not $file -or -not (Test-Path $file)) { return $null }
    $openVr = Get-Content $file -Raw | ConvertFrom-Json
    $runtime = @($openVr.runtime)[0]
    $config = @($openVr.config)[0]
    return @{ File = $file; Runtime = $runtime; Config = $config }
}

function Stop-SteamVR {
    Get-Process vrmonitor, vrserver, vrcompositor, vrdashboard, DesktopPlus, DesktopPlusUI,
        flow_dashboard_helper -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Find-InPath([string[]]$names) {
    foreach ($name in $names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Find-AndroidSdk {
    $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk") }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate "platform-tools"))) { return $candidate }
    }
    return $null
}

function Find-AndroidNdk([string]$sdk) {
    if (-not $sdk) { return $null }
    $ndk = Join-Path $sdk "ndk\21.4.7075529"
    if (Test-Path $ndk) { return $ndk }
    return $null
}

# adb from PATH or from the Android SDK.
function Find-Adb {
    $adb = Find-InPath @("adb", "adb.exe")
    if ($adb) { return $adb }
    $sdk = Find-AndroidSdk
    if ($sdk) {
        $candidate = Join-Path $sdk "platform-tools\adb.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# AGP 3.5 wants a real JDK 8 (javac, not just a JRE).
function Find-Jdk8([string]$root) {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    # tools\jdk8\<jdk>\ , and tools\jdk8\ itself for an archive unpacked without its own
    # folder (then bin\java.exe sits directly in tools\jdk8).
    $bundledRoot = Join-Path $root "tools\jdk8"
    $candidates += $bundledRoot
    foreach ($dir in (Get-ChildItem $bundledRoot -Directory -ErrorAction SilentlyContinue)) { $candidates += $dir.FullName }
    foreach ($candidate in $candidates) {
        $java = Join-Path $candidate "bin\java.exe"
        if (-not (Test-Path (Join-Path $candidate "bin\javac.exe"))) { continue }
        if (-not (Test-Path $java)) { continue }
        # via cmd: in Windows PowerShell 5.1, redirecting a native exe's stderr throws under "Stop"
        $version = cmd /c "`"$java`" -version 2>&1" | Out-String
        if ($version -match 'version "1\.8') { return $candidate }
    }
    return $null
}

# Visual Studio's own toolchain (full IDE or the standalone Build Tools); $null when neither is
# installed. Build Tools installs the same vswhere and component IDs, so it is found here too.
function Get-VisualStudioPath {
    $pfx = Get-ProgramFilesX86
    if (-not $pfx) { return $null }
    $vswhere = Join-Path $pfx "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }
    $path = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($path) { return $path }
    return $null
}

function Test-VisualStudio {
    return [bool](Get-VisualStudioPath)
}

# cmake from PATH, or the copy that ships with Visual Studio / Build Tools (the "C++ CMake tools
# for Windows" component). Installing Build Tools without a separate CMake is common, and the
# build needs cmake on PATH.
function Find-Cmake {
    $inPath = Find-InPath @("cmake", "cmake.exe")
    if ($inPath) { return @{ Path = $inPath; Source = "PATH" } }
    $vs = Get-VisualStudioPath
    if ($vs) {
        $bundled = Join-Path $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
        if (Test-Path $bundled) { return @{ Path = $bundled; Source = "Visual Studio" } }
    }
    return $null
}

function Test-Elevated {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Inbound rule for one program on the private profile. SteamVR's vrserver.exe owns the video,
# pose and audio sockets (the driver DLL runs inside it), the helper owns the desktop layer.
function Add-FirewallRule([string]$displayName, [string]$program) {
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) { return "unsupported" }
    if (-not (Test-Path $program)) { return "missing" }
    try {
        if (Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue) { return "present" }
        New-NetFirewallRule -DisplayName $displayName -Direction Inbound -Action Allow -Profile Private `
            -Program $program -Description "VEVE_FLOW_VR (HTC VIVE Flow stream)" | Out-Null
        return "added"
    } catch {
        return "failed"
    }
}

function Get-PcIPv4 {
    $addresses = @()
    try {
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress)
    } catch {
        $addresses = @()
    }
    return $addresses
}

# A /24 is enough to tell "same Wi-Fi" from "different network"; the exact prefix length of a
# home access point is never /16 in practice.
function Get-Subnet24([string]$ip) {
    if (-not $ip) { return $null }
    $parts = $ip -split '\.'
    if ($parts.Count -lt 3) { return $null }
    return ($parts[0..2] -join '.')
}

# Prints one line per prerequisite from the setup scripts' check lists. Items that do not stop the
# build (Desktop+, the openvr submodule) are shown as "[ -- ]" instead of a red "[miss]".
# Returns the number of blocking checks that failed.
function Show-CheckList($items) {
    $failed = 0
    $width = 24
    foreach ($item in $items) {
        $mark = "[ -- ]"
        $color = "Yellow"
        if ($item.Ok) {
            $mark = "[ ok ]"
            $color = "Green"
        } elseif ($item.Blocking) {
            $mark = "[miss]"
            $color = "Red"
            $failed++
        }
        Write-Host ("  $mark " + $item.Name.PadRight($width) + " " + $item.Detail) -ForegroundColor $color
        if ((-not $item.Ok) -and $item.Fix) {
            Write-Host ("         -> " + $item.Fix) -ForegroundColor DarkGray
        }
    }
    $total = $items.Count
    $ok = ($items | Where-Object { $_.Ok }).Count
    $optional = $total - $ok - $failed
    Write-Host ""
    if ($failed -eq 0) {
        Write-Host "  $ok of $total checks passed; nothing blocking." -ForegroundColor Green
    } else {
        Write-Host "  $ok of $total checks passed; $failed blocking item(s) to fix." -ForegroundColor Yellow
    }
    if ($optional -gt 0) {
        Write-Host "  ($optional optional item(s) marked [ -- ] do not stop the build)" -ForegroundColor DarkGray
    }
    return $failed
}
