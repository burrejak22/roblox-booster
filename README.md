# roblox-booster

PowerShell helper that makes Roblox feel smoother on Windows. Doesn't touch the Roblox process itself. Just twiddles the OS around it.

## What it does

1. Waits for Roblox to start.
2. Raises `RobloxPlayerBeta.exe` priority from Normal to High so Windows schedules it ahead of background work.
3. Sets a High-Performance GPU preference for `RobloxPlayerBeta.exe` in `HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences`. Relevant on laptops with hybrid Intel/NVIDIA or AMD iGPU+dGPU setups. Takes effect on next Roblox launch.
4. Optional opt-in: downloads and launches `rbxfpsunlocker`. See the warning below before you enable this one.
5. Optional opt-in: writes a curated `FastFlags.json` into every Roblox Player and Studio version folder.
6. Cleans up when Roblox closes.

## Running it

Double-click `Launch.bat`. That runs with defaults: system tweaks only, no unlocker, no FastFlags.

To customize:
```
powershell -ExecutionPolicy Bypass -File RobloxBooster.ps1 -FpsCap 165 -Priority AboveNormal
```

Flags:
- `-FpsCap <n>`. Only matters when combined with `-UseUnlocker`. `0` means uncapped.
- `-Priority <Normal|AboveNormal|High|RealTime>`. Default `High`. Don't use `RealTime` unless you want Windows itself to stutter.
- `-UseUnlocker`. Opt in to the external FPS unlocker. Read the warning first.
- `-ApplyFastFlags`. Writes `FastFlags.json` into every Roblox Player AND Studio version folder found.
- `-StudioOnly`. Only touches Studio version folders. Pair with `-ApplyFastFlags`.
- `-FastFlagsFile <path>`. Use a different JSON file than the bundled `FastFlags.json`.

## FastFlags

`FastFlags.json` is a curated "performance preset" that the script writes into `ClientSettings\ClientAppSettings.json` inside every Roblox version folder (Player and Studio both).

**Reality check for late 2025**: Roblox allowlisted FastFlags for the PCClient on 2025-09-30. Flags outside their internal allowlist are silently ignored at runtime by `RobloxPlayerBeta.exe`. Studio still honors everything. So on the Player, many of these probably do nothing. On Studio, the whole file still works.

The preset covers:
- Graphics quality clamp (`DFIntDebugFRMQualityLevelOverride`, `FIntRomarkStartWithGraphicQualityLevel`). Forces starting quality to 1.
- Renderer backend (`FFlagDebugGraphicsPreferD3D11` / `...Vulkan` / `...OpenGL`). Pick one. D3D11 is default.
- Task scheduler FPS target (`DFIntTaskSchedulerTargetFps`). 240.
- Texture quality override, terrain slice size, shadow map checks. Various render shortcuts.
- Telemetry counters off. Small per-frame win.
- Font preload disabled. Faster startup, slightly delayed first text render.

Edit `FastFlags.json` to taste. Comments (`"_comment_*"` keys) are stripped before writing. Each run with `-ApplyFastFlags` re-writes the file, so update `FastFlags.json` and re-run.

**Roblox updates wipe `Versions\*` folders.** Re-run `-ApplyFastFlags` after every Roblox update, or install Bloxstrap which handles FastFlag persistence (Bloxstrap removed its own flag editor after the allowlist landed, so you'd still bring your own JSON).

FastFlag write only, no priority / GPU tweaks:
```
powershell -ExecutionPolicy Bypass -File RobloxBooster.ps1 -ApplyFastFlags -StudioOnly
```
Then close the script before launching Roblox.

## Warning about the FPS unlocker

As of late 2025:
- The standard 64-bit Roblox client ships with the **Hyperion anti-cheat**, which detects external memory writes and crashes the client immediately.
- `rbxfpsunlocker` (the open-source tool this script would download) is archived and no longer compatible with Hyperion-protected clients.
- It only still works on the Microsoft Store build of Roblox (no Hyperion) and on macOS.
- Roblox shipped a native "Maximum Frame Rate" slider in Settings > Graphics. That's the correct way to uncap FPS on the Hyperion client. Zero risk.

So `-UseUnlocker` is off by default. If you enable it and Roblox crashes within 10 seconds, that's Hyperion. Close the unlocker and use the in-game slider.

## What historical "Roblox performance enhancers" used to do

For context on why this script is deliberately small:

| Era | Technique | Status today |
|---|---|---|
| 2013 to 2022 | Editing `ClientSettings\ClientAppSettings.json` with FastFlags (`FFlag*`, `DFInt*`, etc) for quality overrides, forcing D3D11 / Vulkan, tweaking the task scheduler | Mostly dead. Roblox allowlisted FastFlags on 2025-09-30; non-allowlisted flags are silently ignored by the client. Bloxstrap removed its FastFlag editor because of this. |
| 2017 to 2023 | `rbxfpsunlocker` scans Roblox's memory for the 1/60 frame-time float and overwrites it with `WriteProcessMemory` | Blocked by Hyperion on Windows 64-bit. Repo archived in 2024 after Roblox shipped the native slider. |
| 2017 to 2023 | DLL injection for custom render-quality overrides, draw-distance patches, shader swaps | Blocked by Hyperion. Also always violated ToS. |
| 2020s | Launcher wrappers (Bloxstrap, Fishstrap). Process priority, affinity, GPU preference, FastFlag management | Partially still works. The priority / GPU / affinity parts are fine (that's what this script does). FastFlag management is now mostly useless on the client. |
| Always | Lua "script executors" (Synapse, Krnl, etc.) marketed as "boosters" | Always banned. Not actually performance tools, they're code execution exploits. |

The net: the whole category of injection-based FPS boosters is dead on the modern Roblox client. What's left is OS-level scheduling / GPU preference (this script) plus Roblox's own in-game settings.

## Files

- `RobloxBooster.ps1`. The script.
- `Launch.bat`. Double-click wrapper.
- `FastFlags.json`. The FastFlag preset.
- `rbxfpsunlocker/`. Auto-created the first time you pass `-UseUnlocker`.

## Uninstall

Delete the folder. The registry entry for GPU preference sticks around until you clear it:
```
Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences' -Name '<full path to RobloxPlayerBeta.exe>'
```
