# RobloxBooster — a "launch Roblox smoother" helper.
#
# What it does, in order:
#   1. Downloads axstin's rbxfpsunlocker from its GitHub release (first run only; cached afterwards).
#   2. Waits for Roblox to be running.
#   3. Pumps its process priority to High (Roblox launches at Normal).
#   4. Tells Windows' GPU preference to use High Performance for RobloxPlayerBeta.exe.
#   5. Starts the FPS unlocker next to it (uncaps the 60 FPS limit; frame-smoothing left off).
#   6. When Roblox closes, restores priority settings and shuts down the unlocker.
#
# Doesn't do: inject into Roblox, modify network, bypass Hyperion, auto-run any Lua.
# All it does is run a separate, open-source tool and twiddle OS settings around Roblox's process.

param(
    [int]   $FpsCap        = 240,        # 0 = truly uncapped; set a monitor-matched cap for stability
    [string]$Priority      = 'High',     # Normal / AboveNormal / High / RealTime (High is the safe max)
    [switch]$UseUnlocker,                # OPT IN: launch rbxfpsunlocker alongside Roblox. See warning below.
    [switch]$ApplyFastFlags,             # OPT IN: write FastFlags.json into every Roblox Versions\*\ClientSettings\
    [string]$FastFlagsFile = 'FastFlags.json',
    [switch]$StudioOnly,                 # when -ApplyFastFlags: only write to Studio versions (always allowlisted)
    [switch]$Verbose
)

# -------------------------------------------------------------------------------------------------
# IMPORTANT (as of late 2025):
#   * Roblox now ships a native "Maximum Frame Rate" slider in Settings. Use that first.
#   * The standard 64-bit Windows client runs the Hyperion anti-cheat, which detects external
#     memory writes and CRASHES the client. rbxfpsunlocker (which this script would download)
#     is archived and does NOT work on the Hyperion client — enabling -UseUnlocker will almost
#     certainly crash you.
#   * The unlocker only still works on the Microsoft Store build (no Hyperion) and macOS.
#   * The default of this script is therefore SYSTEM-SIDE TWEAKS ONLY: process priority, GPU
#     preference. Those give you 90% of the real-world "feels smoother" win with zero ToS risk.
# -------------------------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# -- paths ------------------------------------------------------------------------------------------

$Root          = $PSScriptRoot
$UnlockerDir   = Join-Path $Root 'rbxfpsunlocker'
$UnlockerExe   = Join-Path $UnlockerDir 'rbxfpsunlocker.exe'
$UnlockerJson  = Join-Path $UnlockerDir 'settings'  # the unlocker's own settings file (no extension)

function Say([string]$msg, [string]$kind='info') {
    $color = @{ info='Gray'; ok='Green'; warn='Yellow'; err='Red' }[$kind]
    Write-Host "[RobloxBooster] $msg" -ForegroundColor $color
}

# -- step 1: fetch the FPS unlocker if we don't have it yet -----------------------------------------

function Ensure-Unlocker {
    if (Test-Path $UnlockerExe) { return }

    Say 'Downloading rbxfpsunlocker (one-time, ~500 KB) from axstin/rbxfpsunlocker…'
    New-Item -ItemType Directory -Path $UnlockerDir -Force | Out-Null

    # GitHub Releases API: pick the latest release's x64 zip asset
    $headers = @{ 'User-Agent' = 'RobloxBooster-PS' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/axstin/rbxfpsunlocker/releases/latest' -Headers $headers

    $asset = $release.assets | Where-Object { $_.name -match '(?i)x64.*\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find an x64 zip asset in the latest release.' }

    $zip = Join-Path $UnlockerDir 'download.zip'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers
    Expand-Archive -Path $zip -DestinationPath $UnlockerDir -Force
    Remove-Item $zip

    if (-not (Test-Path $UnlockerExe)) {
        # some releases put the exe inside a subfolder; flatten it
        $found = Get-ChildItem -Path $UnlockerDir -Filter 'rbxfpsunlocker.exe' -Recurse | Select-Object -First 1
        if ($found) { Move-Item $found.FullName $UnlockerExe -Force }
    }

    if (-not (Test-Path $UnlockerExe)) { throw 'Download finished but the exe is missing.' }
    Say 'Unlocker ready.' 'ok'
}

# -- step 2: write the unlocker's settings file so its FPS cap matches ours -------------------------

function Write-UnlockerSettings {
    # The unlocker's settings file is plain "key value" lines, no extension. FPSCap 0 = uncapped.
    $contents = @"
FPSCap $FpsCap
UnlockClient true
UnlockStudio false
CheckForUpdates false
NonBlockingErrors true
"@
    Set-Content -Path $UnlockerJson -Value $contents -Encoding utf8
}

# -- FastFlag applier -------------------------------------------------------------------------------

function Get-RobloxVersionFolders {
    # standard Windows install paths for both the web Player and Studio
    $candidates = @(
        "$env:LOCALAPPDATA\Roblox\Versions",
        "$env:LOCALAPPDATA\Bloxstrap\Versions"      # Bloxstrap users
    )

    $out = @{ Player = @(); Studio = @() }
    foreach ($root in $candidates) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Directory -Filter 'version-*' -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName 'RobloxPlayerBeta.exe')) { $out.Player += $_.FullName }
            if (Test-Path (Join-Path $_.FullName 'RobloxStudioBeta.exe')) { $out.Studio += $_.FullName }
        }
    }
    return $out
}

function Apply-FastFlags {
    $src = if ([IO.Path]::IsPathRooted($FastFlagsFile)) { $FastFlagsFile } else { Join-Path $Root $FastFlagsFile }
    if (-not (Test-Path $src)) {
        Say "FastFlags file not found: $src" 'err'
        return
    }

    # strip the _comment_* keys so Roblox doesn't see them; everything else is passed through verbatim
    $raw = Get-Content $src -Raw | ConvertFrom-Json
    $clean = [ordered]@{}
    $raw.PSObject.Properties | Where-Object { $_.Name -notlike '_comment*' } | ForEach-Object {
        $clean[$_.Name] = $_.Value
    }
    $json = $clean | ConvertTo-Json -Depth 5 -Compress:$false

    $folders = Get-RobloxVersionFolders
    $targets = @()
    if (-not $StudioOnly) { $targets += $folders.Player  | ForEach-Object { @{ kind = 'Player';  path = $_ } } }
    $targets += $folders.Studio | ForEach-Object { @{ kind = 'Studio';  path = $_ } }

    if (-not $targets.Count) {
        Say 'No Roblox version folders found. Is Roblox installed under %LOCALAPPDATA%\Roblox\Versions?' 'warn'
        return
    }

    foreach ($t in $targets) {
        $dir = Join-Path $t.path 'ClientSettings'
        $dst = Join-Path $dir 'ClientAppSettings.json'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path $dst -Value $json -Encoding utf8
        Say "Applied $($clean.Count) FastFlags to $($t.kind): $dst" 'ok'
    }

    if (-not $StudioOnly) {
        Say 'Reminder: since 2025-09-30 the PCClient ignores non-allowlisted flags. Studio honors them all.' 'warn'
        Say 'Roblox updates overwrite Versions\*; re-run with -ApplyFastFlags after updates.' 'warn'
    }
}

# -- step 3: wait for Roblox, then tweak -----------------------------------------------------------

function Wait-ForRoblox {
    Say 'Waiting for Roblox to start… (launch a game now)'
    while (-not (Get-Process -Name 'RobloxPlayerBeta' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 500
    }
    Get-Process -Name 'RobloxPlayerBeta'
}

function Apply-ProcessTweaks($proc) {
    try {
        $proc.PriorityClass = $Priority
        Say "Set $($proc.ProcessName) (PID $($proc.Id)) priority to $Priority." 'ok'
    } catch {
        Say "Could not set priority: $_" 'warn'
    }
}

function Apply-GpuPreference {
    # Tells Windows to use the discrete / high-perf GPU for RobloxPlayerBeta.exe on laptops with hybrid GPUs.
    # Reg format: "GpuPreference=2" means High Performance.
    $exe = (Get-Process -Name 'RobloxPlayerBeta' -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    if (-not $exe) { return }

    $key = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }

    $current = (Get-ItemProperty -Path $key -Name $exe -ErrorAction SilentlyContinue).$exe
    if ($current -ne 'GpuPreference=2;') {
        Set-ItemProperty -Path $key -Name $exe -Value 'GpuPreference=2;' -Type String
        Say "Set Windows GPU preference to High Performance for $exe (takes effect on next launch)." 'ok'
    }
}

# -- step 4: run the unlocker alongside -------------------------------------------------------------

function Start-Unlocker {
    if (-not $UseUnlocker) {
        Say 'Not launching the FPS unlocker (default, safe). Use Roblox Settings → Graphics → Max FPS instead.'
        return $null
    }
    if (-not (Test-Path $UnlockerExe)) { Say 'Unlocker missing; skipping.' 'warn'; return $null }

    Say "Starting FPS unlocker (cap = $FpsCap, 0 means uncapped)…" 'warn'
    Say 'If Roblox crashes within 10 seconds, Hyperion detected the patch — close the unlocker and use the native slider.' 'warn'
    return Start-Process -FilePath $UnlockerExe -ArgumentList '-silent' -WorkingDirectory $UnlockerDir -PassThru
}

function Stop-Unlocker($proc) {
    if (-not $proc) { return }
    try {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force
            Say 'Unlocker closed.' 'ok'
        }
    } catch {
        Say "Couldn't stop the unlocker cleanly: $_" 'warn'
    }
}

# -- main -------------------------------------------------------------------------------------------

try {
    Say '--- RobloxBooster ---'
    Say "FPS cap: $FpsCap  |  Priority: $Priority  |  Unlocker: $UseUnlocker  |  FastFlags: $ApplyFastFlags"

    if ($ApplyFastFlags) {
        Apply-FastFlags
    }

    if ($UseUnlocker) {
        Ensure-Unlocker
        Write-UnlockerSettings
    }

    $roblox = Wait-ForRoblox
    Apply-ProcessTweaks $roblox
    Apply-GpuPreference
    $unlocker = Start-Unlocker

    Say 'Running. Close Roblox to clean up.' 'ok'
    $roblox.WaitForExit()
    Say 'Roblox closed. Cleaning up…'
    Stop-Unlocker $unlocker
    Say 'Done.' 'ok'
} catch {
    Say "Error: $_" 'err'
    exit 1
}
