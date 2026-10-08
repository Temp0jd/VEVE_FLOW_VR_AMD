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
# Candidate folders that may hold a Java install: JAVA_HOME, then the documented tools\jdk8 (and
# one level below it), then tools\ itself (and one level below it) so a JDK unpacked a level too
# high is still found.
function Get-Jdk8Candidates([string]$root) {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    foreach ($base in @((Join-Path $root "tools\jdk8"), (Join-Path $root "tools"))) {
        $candidates += $base
        foreach ($dir in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) { $candidates += $dir.FullName }
    }
    return ($candidates | Where-Object { $_ } | Select-Object -Unique)
}

# Output of "<folder>\bin\java.exe -version", or $null when there is no java there.
function Get-JavaVersion([string]$folder) {
    $java = Join-SafePath $folder "bin\java.exe"
    if (-not (Test-SafePath $java)) { return $null }
    # via cmd: in Windows PowerShell 5.1, redirecting a native exe's stderr throws under "Stop".
    # cmd always exists on Windows; elsewhere there is no java.exe either, so a throw is fine to
    # swallow into "no version".
    try { return (cmd /c "`"$java`" -version 2>&1" | Out-String) } catch { return $null }
}

function Find-Jdk8([string]$root) {
    foreach ($candidate in (Get-Jdk8Candidates $root)) {
        if (-not (Test-Path (Join-Path $candidate "bin\javac.exe"))) { continue }
        $version = Get-JavaVersion $candidate
        if ($version -and ($version -match 'version "1\.8')) { return $candidate }
    }
    return $null
}

# Why no JDK 8 was usable: "" when nothing Java-like was found at all, otherwise the reason, so
# the caller can distinguish "not installed" from "a JRE" or "the wrong version".
function Describe-Jdk8Problem([string]$root) {
    foreach ($candidate in (Get-Jdk8Candidates $root)) {
        $hasJava = Test-Path (Join-Path $candidate "bin\java.exe")
        if (-not $hasJava) { continue }
        if (-not (Test-Path (Join-Path $candidate "bin\javac.exe"))) {
            return "$candidate has bin\java.exe but no bin\javac.exe, so it is a JRE: the Android build needs the JDK 8."
        }
        $version = Get-JavaVersion $candidate
        if ($version -and ($version -match 'version "1\.8')) { continue } # usable, keep looking
        $found = "unknown"
        if ($version -and ($version -match 'version "([^"]+)"')) { $found = $Matches[1] }
        if ($found -eq "unknown") { return "$candidate has bin\javac.exe but its version could not be read; 1.8 is required." }
        return "$candidate is Java $found, but 1.8 is required."
    }
    return ""
}

# Test-Path that also survives a path on a drive that does not exist: with
# $ErrorActionPreference = "Stop" (as the setup scripts set it), Test-Path throws instead of
# returning false when the drive is gone, e.g. a Visual Studio install on an unplugged drive.
function Test-SafePath([string]$path) {
    if (-not $path) { return $false }
    try { return [bool](Test-Path -LiteralPath $path) } catch { return $false }
}

# Join-Path that returns $null instead of throwing for an unreachable base path.
function Join-SafePath([string]$base, [string]$child) {
    if (-not (Test-SafePath $base)) { return $null }
    try { return (Join-Path $base $child) } catch { return $null }
}

# Details of the newest Visual Studio / Build Tools installation that has the C++ toolchain, or
# $null when there is none. vswhere is part of the Visual Studio Installer and is the same tool
# CMake uses internally.
function Get-VisualStudioInstance {
    $pfx = Get-ProgramFilesX86
    if (-not $pfx) { return $null }
    $vswhere = Join-Path $pfx "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }
    $arguments = @("-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64")
    $path = & $vswhere @arguments -property installationPath
    if (-not $path) { return $null }
    $version = & $vswhere @arguments -property installationVersion
    $name = & $vswhere @arguments -property displayName
    return @{ Path = "$path".Trim(); Version = "$version".Trim(); DisplayName = "$name".Trim() }
}

# Major version of a version string such as "18.10.12224.181".
function Get-MajorVersion([string]$version) {
    if ($version -match '^\s*(\d+)\.') { return [int]$Matches[1] }
    return 0
}

function Get-VisualStudioPath {
    $instance = Get-VisualStudioInstance
    if ($instance) { return $instance.Path }
    return $null
}

function Test-VisualStudio {
    return [bool](Get-VisualStudioPath)
}

# CMake names its Visual Studio generators after the product year and only accepts an instance of
# that version, so VS 2026 (v18) needs the "Visual Studio 18 2026" generator: with "Visual Studio
# 17 2022" it refuses the instance ("the version field is not 4 integer components starting in
# 17") or reports no instance at all. "Visual Studio 18 2026" needs CMake 4.2 or newer.
function Get-VisualStudioGenerator([int]$major) {
    switch ($major) {
        16 { return "Visual Studio 16 2019" }
        17 { return "Visual Studio 17 2022" }
        18 { return "Visual Studio 18 2026" }
        default { return $null }
    }
}

# The Visual Studio version encoded in a generator name such as "Visual Studio 18 2026".
function Get-GeneratorMajorVersion([string]$generator) {
    if ($generator -match 'Visual Studio\s+(\d+)') { return [int]$Matches[1] }
    return 0
}

# The CMake that Visual Studio / Build Tools bundles (the "C++ CMake tools for Windows"
# component), whether or not cmake is also on PATH.
function Find-BundledCmake {
    $vs = Get-VisualStudioPath
    if ($vs) {
        $bundled = Join-SafePath $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
        if (Test-SafePath $bundled) { return $bundled }
    }
    return $null
}

# "4.2" out of "cmake version 4.2.3", or $null when it cannot be read.
function Get-CMakeVersion([string]$exe) {
    if (-not $exe) { return $null }
    try {
        $first = (& $exe --version 2>$null | Select-Object -First 1)
        if ("$first" -match 'cmake version (\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2])" }
    } catch {
    }
    return $null
}

# cmake from PATH, or the copy that ships with Visual Studio / Build Tools. Installing Build Tools
# without a separate CMake is common, and the build needs cmake on PATH.
function Find-Cmake {
    $inPath = Find-InPath @("cmake", "cmake.exe")
    if ($inPath) { return @{ Path = $inPath; Source = "PATH" } }
    $bundled = Find-BundledCmake
    if ($bundled) { return @{ Path = $bundled; Source = "Visual Studio" } }
    return $null
}

# Ninja that ships with Visual Studio / Build Tools (they place it next to the CMake they bundle).
function Find-Ninja {
    $inPath = Find-InPath @("ninja", "ninja.exe")
    if ($inPath) { return $inPath }
    $vs = Get-VisualStudioPath
    if ($vs) {
        $bundled = Join-SafePath $vs "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
        if (Test-SafePath $bundled) { return $bundled }
    }
    return $null
}

# vcvars64.bat of the given instance: it puts cl.exe, link.exe and ninja on PATH for a shell.
function Get-VcVarsPath([string]$vsPath) {
    $candidate = Join-SafePath $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    if (Test-SafePath $candidate) { return $candidate }
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
# The rule stores an absolute program path, so moving this repository onto another drive leaves it
# stale: an existing rule is repointed rather than trusted by name alone.
function Add-FirewallRule([string]$displayName, [string]$program) {
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) { return "unsupported" }
    if (-not (Test-Path $program)) { return "missing" }
    try {
        $updated = $false
        $existing = Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue
        if ($existing) {
            $current = @($existing | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty Program)
            if ($current -and ($current -eq $program)) { return "present" }
            $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            $updated = $true
        }
        New-NetFirewallRule -DisplayName $displayName -Direction Inbound -Action Allow -Profile Private `
            -Program $program -Description "VEVE_FLOW_VR (HTC VIVE Flow stream)" | Out-Null
        if ($updated) { return "updated" }
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
