<#
.SYNOPSIS
    Both halves in one command: scripts\setup-pc.ps1 then scripts\setup-flow.ps1.

.DESCRIPTION
    Same thing as running the two scripts by hand, in the right order and with the same switches.
    If the Flow is not connected over USB yet, the PC half still finishes; plug it in and run
    scripts\setup-flow.ps1 (or this script again) afterwards.

    See SETUP.md for the step-by-step flow and README.md for everything else.

.PARAMETER Video
    Preset for watching VR video (DeoVR and friends): skips Desktop+, turns the sharp desktop
    layer off, 120 Mbit/s, no SteamVR idle standby. Passed to setup-pc.ps1.

.PARAMETER Launch
    After installing, start SteamVR and the Flow app and wait for the stream to connect. Passed
    to setup-flow.ps1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Video
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -SkipBuild -Launch
#>
param(
    [switch]$Video,
    [switch]$SkipBuild,
    [switch]$SkipApk,
    [switch]$SkipInstall,
    [switch]$NoFirewall,
    [switch]$WithDesktopStreamer,
    [switch]$Launch,
    # Passed to setup-pc.ps1 / build.ps1: Gradle distribution mirror (see README troubleshooting).
    [string]$GradleDistributionUrl = ""
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "setup-common.ps1")

Step "Step 1 of 2: this PC (scripts\setup-pc.ps1)"
$pcArgs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "setup-pc.ps1"))
if ($Video) { $pcArgs += "-Video" }
if ($SkipBuild) { $pcArgs += "-SkipBuild" }
if ($SkipApk) { $pcArgs += "-SkipApk" }
if ($SkipInstall) { $pcArgs += "-SkipInstall" }
if ($NoFirewall) { $pcArgs += "-NoFirewall" }
if ($WithDesktopStreamer) { $pcArgs += "-WithDesktopStreamer" }
if ($GradleDistributionUrl) { $pcArgs += @("-GradleDistributionUrl", $GradleDistributionUrl) }
& powershell @pcArgs
if ($LASTEXITCODE -ne 0) {
    Fail "the PC half failed; fix the items it listed and run this script again (it picks up where it left off)."
}

Step "Step 2 of 2: the headset (scripts\setup-flow.ps1)"
$flowArgs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "setup-flow.ps1"))
if ($Launch) { $flowArgs += "-Launch" }
& powershell @flowArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Note "the PC half is done and does not need to run again."
    Note "connect the Flow over USB (USB debugging on) and run: powershell -ExecutionPolicy Bypass -File scripts\setup-flow.ps1"
    exit $LASTEXITCODE
}

Step "All done"
Note "Daily use: run 'scripts\setup-flow.ps1 -Launch', or start SteamVR from Steam and open 'Flow Probe' on the Flow."
Note "Full flow and troubleshooting: SETUP.md"
