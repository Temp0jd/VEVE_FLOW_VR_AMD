<#
.SYNOPSIS
    Headset side in one command: install the Flow app over USB, check the network path to this PC,
    and (with -Launch) bring up SteamVR + the app and confirm the stream actually connected.

.DESCRIPTION
    Needs the Flow connected over USB with "USB debugging" enabled and the APK already built
    (scripts\setup-pc.ps1 builds it). The Flow has to accept the USB debugging prompt the first
    time; this script tells you when it is waiting for that.

    It installs the APK, reports the installed version, checks that the Flow and this PC are on
    the same Wi-Fi subnet (the Flow finds the PC by UDP broadcast and then connects to TCP 8001,
    so a different subnet is the most common reason nothing happens), and optionally starts
    SteamVR, starts the app and waits for the driver's "Flow stream client connected" log line.

.PARAMETER Launch
    Also start SteamVR (if it is not running), start the Flow app, and wait for the stream to
    connect. This is the whole daily start-up sequence in one command.

.PARAMETER SkipInstall
    Do not install the APK; only check / launch (implies the app is already installed).

.PARAMETER Timeout
    Seconds to wait for the stream to connect with -Launch (default 60).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -Launch
    powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1 -SkipInstall -Launch
#>
param(
    [switch]$Launch,
    [switch]$SkipInstall,
    [int]$Timeout = 60
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "setup-common.ps1")

$DriverDir = Join-Path $Root "pc\flow_steamvr_driver\build\dist\flowvr"
$DriverLog = Join-Path $DriverDir "logs\flow_virtual_display_trace.log"
$Apk = Join-Path $Root "Wave_Native_SDK\samples\wvr_flow_probe\app\build\outputs\apk\bit64\debug\app-bit64-debug.apk"
$FlowPackage = "com.htc.vr.samples.wvr_flow_probe"
$FlowActivity = "$FlowPackage/.MainActivity"
$VrMonitor = $null
$streamLogPattern = "Flow stream client connected"

# Reads only what was appended to a log the driver keeps open; a rotated/recreated log restarts
# from zero so an old "connected" line can never be mistaken for a new one.
function Watch-NewLogLine([string]$path, [string]$pattern, [int]$timeoutSeconds) {
    $offset = 0
    if (Test-Path $path) { $offset = (Get-Item $path).Length }
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            $length = (Get-Item $path).Length
            if ($length -lt $offset) { $offset = 0 }
            if ($length -gt $offset) {
                $stream = $null
                $reader = $null
                try {
                    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    $stream.Seek($offset, [IO.SeekOrigin]::Begin) | Out-Null
                    $reader = New-Object IO.StreamReader($stream)
                    $text = $reader.ReadToEnd()
                    $offset = $length
                    if ($text -match $pattern) { return $true }
                } catch {
                    # the driver recreated the file under us; retry on the next poll
                } finally {
                    if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
                }
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---- Preflight: the Flow ----------------------------------------------------------------------
Step "Preflight (headset)"

$problems = @()
$adb = Find-Adb
if (-not $adb) {
    $problems += "adb not found. Install the Android SDK platform-tools (Android Studio) or add platform-tools to PATH."
}
if ((-not $SkipInstall) -and (-not (Test-Path $Apk))) {
    $problems += "Flow APK not built. Run scripts\setup-pc.ps1 first (it needs the Wave SDK and the Android toolchain)."
}
if ($problems.Count -gt 0) { Fail-Listed $problems "headset" }

$devices = @(& $adb devices)
$serial = $null
if ($devices | Select-String "`tdevice$") { $serial = "connected" }
if (-not $serial) {
    if ($devices | Select-String "`tunauthorized$") {
        Fail "The Flow is connected but not authorised: look in the headset, put it on, and accept the 'Allow USB debugging' prompt, then re-run this script."
    }
    if ($devices | Select-String "`toffline$") {
        Fail "The Flow shows as 'offline'. Unplug and replug the USB cable, or restart adb (adb kill-server), then re-run."
    }
    Fail "No Flow found over ADB. Connect it with the USB cable (the Flow shows a 'Select USB mode' prompt - choose 'No action' or 'File transfer', not charging-only), enable USB debugging, then re-run."
}
Note "Flow found over ADB"

# Warn (do not fail) if this is not a Wave device: the app is built for HTC's Wave SDK.
$props = (& $adb shell getprop | Out-String)
if (($props -match "(?m)^\[ro\.product\.(brand|manufacturer)\]: \[[^\]]*HTC") -or ($props -match "vive\.wave")) {
    Note "device looks like an HTC Wave headset"
} else {
    Warn "this does not look like an HTC Wave headset; the Flow app may not run on it"
}

# ---- Install ----------------------------------------------------------------------------------
if ($SkipInstall) {
    Step "Install skipped"
} else {
    Step "Install the Flow app"
    $output = (& $adb install -r $Apk) | Out-String
    if ($output -match "Success") {
        Note "installed $Apk"
    } else {
        Warn $output.Trim()
        Note "if it failed with INSTALL_FAILED_UPDATE_INCOMPATIBLE or a signature error, remove the old copy first:"
        Note "  `"$adb`" uninstall $FlowPackage"
        Note "then re-run this script."
        exit 1
    }
}

# ---- Verify what is on the headset ------------------------------------------------------------
Step "Verify (headset)"

$installed = (& $adb shell pm list packages $FlowPackage) | Select-String -SimpleMatch $FlowPackage
if ($installed) {
    $dump = (& $adb shell dumpsys package $FlowPackage) | Out-String
    $version = "unknown"
    if ($dump -match "versionName=(\S+)") { $version = $Matches[1] }
    Note "installed: $FlowPackage (versionName $version)"
} else {
    Warn "the app is not installed on the headset (run this script without -SkipInstall)"
}

# Current debug properties, so it is obvious what to change and how.
$debugProps = @("debug.flow.hands", "debug.flow.eyebuffer", "debug.flow.sharpen", "debug.flow.desktop")
$current = @()
foreach ($name in $debugProps) {
    $value = (& $adb shell getprop $name | Out-String).Trim()
    if ($value) { $current += "$name=$value" }
}
if ($current.Count -gt 0) {
    Note ("debug props: " + ($current -join " "))
} else {
    Note "debug props: none set (the app's defaults are used)"
}

# ---- Network: the Flow finds the PC by broadcast, then connects to TCP 8001 ---------------------
Step "Network path (Flow -> this PC)"

$flowIp = $null
$addresses = (& $adb shell ip -f inet addr) | Out-String
foreach ($match in [regex]::Matches($addresses, 'inet (\d+\.\d+\.\d+\.\d+)')) {
    $candidate = $match.Groups[1].Value
    if ($candidate -notlike "127.*") { $flowIp = $candidate; break }
}
$pcAddresses = Get-PcIPv4
$sameSubnet = $false
if ($flowIp -and $pcAddresses.Count -eq 0) {
    Warn "could not read this PC's IPv4 address; the subnet check was skipped"
} elseif ($flowIp) {
    $flowSubnet = Get-Subnet24 $flowIp
    foreach ($pcIp in $pcAddresses) {
        if ((Get-Subnet24 $pcIp) -eq $flowSubnet) { $sameSubnet = $true; break }
    }
    Note "Flow: $flowIp   PC: $($pcAddresses -join ', ')"
    if ($sameSubnet) {
        Note "same subnet: the Flow can see this PC's discovery broadcast"
    } else {
        Warn "the Flow and this PC are on different subnets. They must be on the same Wi-Fi/network; this alone stops the stream."
    }
} else {
    Warn "could not read an IP from the Flow (Wi-Fi off?). PC addresses: $($pcAddresses -join ', ')"
}
if ($sameSubnet -and $pcAddresses.Count -gt 0) {
    # Informational only: Windows blocks inbound ICMP by default, so a failed ping proves nothing.
    $ping = (& $adb shell ping -c 2 -W 2 $pcAddresses[0] 2>&1) | Out-String
    if ($ping -match "0% packet loss|2 received|2 packets received") {
        Note "the Flow can ping this PC ($($pcAddresses[0]))"
    } else {
        Note "the Flow could not ping this PC; that is normal (Windows blocks ping by default) and not a problem."
    }
}

# ---- Launch + confirm the stream --------------------------------------------------------------
if (-not $Launch) {
    Step "Headset side ready"
    Note "On the Flow: put the headset on and open the app 'Flow Probe' (or run this script with -Launch)."
    Note "Full guide: README.md / SETUP.md"
    exit 0
}

Step "Launch"
$steamVr = Get-SteamVRPaths
if (-not $steamVr -or -not $steamVr.Runtime) { Fail "SteamVR is not installed; run scripts\setup-pc.ps1 first." }
$VrMonitor = Join-Path $steamVr.Runtime "bin\win64\vrmonitor.exe"

if (Get-Process vrserver -ErrorAction SilentlyContinue) {
    Note "SteamVR is already running"
} else {
    Note "starting SteamVR..."
    Start-Process -FilePath $VrMonitor | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Get-Process vrserver -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if (-not (Get-Process vrserver -ErrorAction SilentlyContinue)) {
        Fail "SteamVR did not start. Start it from Steam once, then re-run with -Launch."
    }
    Start-Sleep -Seconds 8
    Note "SteamVR is up"
}

# A fresh start: the app is singleTask, so force-stopping makes the connect deterministic.
& $adb shell am force-stop $FlowPackage | Out-Null
Start-Sleep -Seconds 1
$start = (& $adb shell am start -n $FlowActivity) | Out-String
if ($start -match "Error") {
    Warn $start.Trim()
    Note "start the app by hand on the Flow instead, then look at: adb logcat -s FlowProbe vrsample"
} else {
    Note "started Flow Probe on the headset"
}

Note "waiting up to $Timeout s for the stream to connect..."
if (Watch-NewLogLine $DriverLog $streamLogPattern $Timeout) {
    Step "Streaming"
    Note "the Flow is connected and receiving video"
    Note "put the headset on; in most VR apps pinch (thumb+index) = click and a fist = grip/back"
    exit 0
}

Step "Not connected yet"
Warn "the driver never logged '$streamLogPattern' within $Timeout s"
Note "most likely causes, in order:"
Note "  1. inbound blocked: allow SteamVR's vrserver.exe on the private network (re-run setup-pc.ps1 as administrator)."
Note "  2. different network: the Flow and the PC must be on the same Wi-Fi (see the check above)."
Note "  3. the app did not stay in the foreground: put the headset on; it must be worn."
Note "then look at the two logs:"
Note "  headset: adb logcat -s FlowProbe vrsample    (look for 'socket connected' and 'stream rates')"
Note "  driver:  $DriverLog"
exit 1
