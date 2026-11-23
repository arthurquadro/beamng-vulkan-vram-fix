# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇧🇷 **Prefere ler em Português?** Veja [README.pt-BR.md](README.pt-BR.md).

A lightweight, non-destructive **BeamNG.drive** mod (`v1.3.1`) that stops progressive **Vulkan VRAM memory leaks** and **high-VRAM spillover into slow system RAM ("SWAP")** — preventing VRAM saturation that causes severe FPS collapses (~10–14 FPS) or crashes, while scheduling cleanups inside invisible/low-motion windows to minimize stuttering.

- **Works with any vehicle and any map** — does not overwrite any vehicle or game files.
- **Works on AMD, NVIDIA, and Intel GPUs** (Vulkan backend only; automatically stays idle on DirectX 11 / DirectX 12).
- **100% pure Lua (2 small files)** — zero conflicts with other mods, idempotent startup loader.
- **Keeps all your graphics settings intact** — you can change presets, resolution, Depth of Field, mirrors, etc. freely in-game without breaking the fix.

---

## Why This Happens (Root Cause)

Binary analysis of `BeamNG.drive.x64.exe` (`v0.40.6.0`) revealed why VRAM climbs continuously under Vulkan (while DirectX 12 stays flat), why assets spill into slow PCIe system RAM ("SWAP"), and why changing any graphics setting temporarily relieves it:

1. **Un-trimmed internal Vulkan pools during gameplay:** `GFXVkDevice::endScene` never trims the retired `16 MB` transfer staging slab pool (`"Buffer volatile cpu"` / upload staging lists) and retains up to `32 × 8 MB` dynamic VRAM slabs per usage bucket, plus other internal caches. Changing graphics settings calls `GFXVkWindowTarget::resetModeInternal` → `GFXVkDevice::waitIdle()`, which purges all of those pools at once.
2. **Orphaned built-in VRAM pressure flusher:** BeamNG already ships an automatic VMA heap pressure flusher (`GFXVkDevice::vtable[+0x108]` at `0x140F10260` → `checkVmaHeapBudgets(0.85f)` at `0x140F0ED80` → `waitIdle()` at `0x140F1A710`) that triggers when `DEVICE_LOCAL` VMA usage reaches ≥ 85% of `budgetBytes`, or non-local GPU memory reaches ≥ 1 GiB, or every 5th call. However, its **only caller in the binary** is `GuiCanvas::repaintUIThrottled()`, which vanilla Lua only invokes during **level loading screens** (`updateLoadingProgress`), never during normal gameplay.
3. **High default transient render-target budget:** `$gfx::transientPoolBudgetMB` defaults to **`1536 MB`** (1.5 GB), hoarding idle transient render targets — especially harsh on 8 GB GPUs without Resizable BAR (256 MB BAR).

---

## What Changed in `v1.3.1` (Forensic Audit Refinements & Edge-Case Guards)

Building on `v1.3.0`'s 4-tier smooth opportunistic scheduler, `v1.3.1` hardens gameplay detection, floor tracking, GPU transfer safety, and LuaJIT execution overhead:

1. **Explicit Menu Whitelist (`ui_router` + Photo Mode / World Editor exclusion):** Replaces the old `routeName ~= "play"` check with an explicit whitelist (`"menu"`, `"menu.*"`, `"pause"`, `"pause.*"`, `"scenario.end"`, `"scenario.*.end"`) while explicitly excluding Photo Mode (`pause.photomode`), Radial Mirrors (`radial.mirrors`), and the World Editor (`F11`). Driving routes such as Taxi (`"taxi"`), Track Builder (`"trackBuilder"`), and Split-Screen never mis-trigger menu cleanups anymore.
2. **1-Tap-Only Unpaused Radial Menu:** Keeps semi-transparent unpaused Radial Menu (`core_quickAccess`) restricted to guaranteed **1-tap** cleanups (`SWAP >= 1032 MB` or `VMA >= 85.2%`), eliminating multi-tap flashes over live 3D rendering.
3. **Bidirectional `vramFloorMB` Recalibration:** Recalibrates `vramFloorMB` both upward and downward whenever `waitIdleAndFreeResources()` genuinely runs (`>= 15 ms`), adapting cleanly as traffic/police groups or extra vehicles spawn and despawn without stale floor drift.
4. **Silent `33.3 ms` UI-Throttle Detection & Single Retry:** Detects when `GuiCanvas::repaintUIThrottled()` (`0x140446383`) exits in `< 8 ms` due to the C++ `1/30 s` throttle gate and schedules 1 automatic retry `60 ms` later instead of wasting the flush and backing off.
5. **2-Sample Stationary Confirmation & `3 s` Spawn Grace Window:** Requires `>= 2` consecutive stationary samples (`>= 1 s` hold) before `stopped_opportunistic` runs, and adds an `onVehicleSpawned` `3.0 s` grace window blocking opportunistic flushes while `transferAcc` streams a new vehicle's meshes and textures.
6. **Clean Lifecycle & Rising-Edge `SWAP` Refresh:** Adds `onClientEndMission`, cancels pending bursts/verifications on level loading/settings changes, skips menu-trigger `getGPUAdaptersInfo()` polling while Alt-Tabbed, forces an immediate `SWAP` refresh on the `68%` VMA rising edge, and replaces all anonymous `pcall(function() ... end)` closures with zero-allocation `pcall(fn, self, ...)` calls plus `pcall`-guarded `modScript.lua`.

### Earlier Milestones (`v1.3.0`, `v1.2.1`, `v1.2.0` & `v1.1.0`)

- **`v1.3.0` (Smooth Opportunistic Flushing):** Introduced lazy `SWAP` polling (`>= 68%` VMA, 4 s interval), deferred post-flush verification (`0.50 s` + `>= 12` frames), observed `vramFloorMB`, 4-tier scheduling (invisible UI/menu windows, reset/switch cuts, stationary stops, and `78.0% → 83.5%` active soft deferral up to `20 s` waiting for slowdowns or camera cuts).
- **`v1.2.1` (`VK_ERROR_DEVICE_LOST` Hotfix):** Fixed `v1.2.0`'s low-VRAM `swap_pressure` loop (`transferAcc->queue.submit = VK_ERROR_DEVICE_LOST`) by requiring elevated VRAM (`≥ 78%`), strict VRAM-only reclaim validation (`≥ 192 MB`), 1-tap bursts when `VMA ≥ 85.2%` or `SWAP ≥ 1032 MB`, `15 s` cooldowns, and restoring `$gfx::transientPoolBudgetMB = 384 MB`. Verified in West Coast USA (`v1.2.1` `beamng.log`: 4/4 clean 1-tap flushes reclaiming `1,340–1,615 MB` VRAM each, `0` crashes).
- **`v1.2.0` (`SWAP` Visibility):** Exposed `nonLocalUsageBytes` via `Engine.Platform.getGPUAdaptersInfo()` (`0x140EFA680`), leveraging C++'s `1 GiB` non-local 1-tap check (`0x140F0EEA3`) so map geometry (`priority = 0.75f`) isn't evicted into slow PCIe RAM (`Heap 2`) by WDDM.
- **`v1.1.0` (VMA Budget Alignment):** Aligned the active threshold to `usageBytes / budgetBytes >= 0.852` matching `GFXVkDevice::getMemoryInfo` (`0x140EFBA40`) and `checkVmaHeapBudgets(0.85f)` (`0x140F0ED80`).

---

## What This Mod Does

1. **Caps `$gfx::transientPoolBudgetMB` from `1536 MB` to `384 MB`** on Vulkan (re-applied cleanly on mission start and graphics setting changes, without touching any visual menu option).
2. **Monitors VRAM cleanly (zero-allocation `pcall`s, and `SWAP` lazily only when `VMA ≥ 68%` and focused)**, calling `Canvas:repaintUIThrottled()` safely outside the render pass (`onUpdate`) using 4-tier scheduling:
   - **Invisible menus / pause / BigMap (and 1-tap Radial Menu):** cleans silently at **`≥ 64%` VMA** (`+550 MB` above recalibrated floor), excluding Photo Mode and World Editor.
   - **Player reset / switch & stationary stops:** waits `3 s` after any vehicle spawn (`onVehicleSpawned`), and hides 1-tap flushes inside resets (`≥ 68%`) or confirmed 2-sample stops (`≥ 72%`, `≤ 2.9 km/h` for `≥ 1 s`).
   - **Active driving:** soft-defers **`78.0% → 83.5%`** (with `SWAP ≥ 1032 MB`) up to `20 s` waiting for a slowdown/camera cut/menu, with guaranteed **1-tap** hard ceilings (plus 1 automatic `60 ms` retry if throttled by the `33.3 ms` UI gate) at **`83.5%`** (with `SWAP ≥ 1032 MB`) or **`85.2%`** VMA.
   - **Safety cooldowns & anti-loop backoff:** enforces **`15 s`** post-flush cooldown (**`15 s`** after map load, **`5 s`** after settings changes / level end) and defers post-flush verification by `0.50 s` (`≥ 12` frames); if `< 192 MB` of VRAM is reclaimed, backs off (`30 s → 90 s`).

### Verified Telemetry (`beamng.2.log` & `beamng.1.log` — Citybus + 7 Traffic/Police Vehicles, RX 580 8 GB Vulkan)

- **Italy 37-min stress test (`beamng.2.log`):** **16 automatic flushes completed cleanly**, reclaiming **1,972–2,147 MB per flush**, with **0** `Failed to wait for fences` errors.
- **West Coast USA pursuit test (`beamng.1.log`):** **9/9 consecutive 1-tap flushes (`206–285 ms`)**, reclaiming **18,528 MB (~18.5 GB)** in 17 minutes under `~120 MB/s` police-chase pool churn, maintaining a flat baseline (`4,040 MB`) and **0** `VK_ERROR_DEVICE_LOST` / fence errors.
- **Swap-Assisted 1-Tap Purge verification (`v1.2.x` West Coast USA logs):** 1-tap flushes fired at `78%–80%` VMA when `SWAP >= 1,032 MB` consistently reclaimed **`1,520–1,796 MB` of VRAM** in a single tap (`~290–305 ms`).

---

## Installation

### Option 1 — Easy Install (Recommended)
1. Download `beamng_vulkan_vram_fix.zip` from the [**Releases**](https://github.com/arthurquadro/beamng-vulkan-vram-fix/releases/latest) page.
2. Drop the `.zip` file (without extracting) into your BeamNG mods folder:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
   ```
   *(Usually `C:\Users\<YourUser>\AppData\Local\BeamNG\BeamNG.drive\current\mods\`.)*
3. Make sure the mod is **Active** in BeamNG's Mod Manager (or see Option 3 below so "Deactivate All Mods" cannot turn it off).
4. Launch **BeamNG.drive** in **Vulkan** mode.

### Option 2 — Unpacked Install (From Repository Source)
1. Download or clone this repository.
2. Copy the `scripts/` and `lua/` folders into:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamng_vulkan_vram_fix\
   ```
3. Launch **BeamNG.drive** in **Vulkan** mode.

### Option 3 — Deactivation-Proof Root Install (Optional Power-User Setup)
Because `core_modmanager.initDB()` scans `/scripts/*/modScript.lua` in your BeamNG user root even when Mod Manager mods are deactivated:
1. Extract the `.zip` and copy `lua/ge/extensions/vulkanVramFix.lua` and `scripts/beamng_vulkan_vram_fix/modScript.lua` directly into:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\
   ```
2. It stays active even if you click **"Deactivate All Mods"** in the in-game Mod Manager (and still never modifies any Steam game files).

---

## Console Commands (Optional)

Open the in-game console (`~` or `'`), switch to **BeamNG - Lua / GE**, and run:

| Command | Description |
| :--- | :--- |
| `vulkanVramFix.status()` | Prints version, VMA budget %, physical VRAM, non-local SWAP usage, `$gfx::transientPoolBudgetMB`, flush count, reclaimed MB, and texture streaming stats. |
| `vulkanVramFix.flushNow()` | Triggers an immediate Vulkan pool purge on demand. |
| `vulkanVramFix.setBudgetMB(384)` | Changes `$gfx::transientPoolBudgetMB` (`128`–`2048` MB; default `384`). Useful on 12 GB+ GPUs. |
| `vulkanVramFix.setAutoFlush(false)` | Temporarily disables automatic flushing (`true` to re-enable). |

---

## Optional: Recommended Steam Launch Options (Windows)

Multiple third-party Vulkan Implicit Layers (OBS, Steam Overlay, Steam Fossilize, Epic Online Services, RTSS, AMD Switchable Graphics) can stack on top of the driver and add instability on low-BAR GPUs. You can disable them per-game in **Steam → BeamNG.drive → Properties → Launch Options** (keep no space before `&`):

```cmd
cmd /c "set DISABLE_VULKAN_OBS_CAPTURE=1& set EOS_OVERLAY_DISABLE_VULKAN_WIN64=1& set DISABLE_VK_LAYER_VALVE_steam_overlay_1=1& set DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1& set DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1& set DISABLE_RTSS_LAYER=1& %command% -gfx vk"
```

- Remove `set DISABLE_RTSS_LAYER=1&` if you want to keep MSI Afterburner / RivaTuner OSD visible.
- `DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1` only applies to AMD systems and is safely ignored on NVIDIA/Intel.

---

## Known Notes & Limitations

- A flush executes `Canvas:repaintUIThrottled()`, which can cause a brief (~1 frame) visual blink at the moment a VRAM or SWAP cleanup runs.
- - By design in Vulkan, once a buffer or texture has already been bound to non-local system RAM (`SWAP`), it cannot be migrated back to VRAM in place. `v1.3.1` keeps VRAM headroom safely below eviction thresholds while hiding cleanups inside verified menu, reset, and stationary windows whenever possible.
- Tested on **BeamNG.drive v0.40.6.0**. Future BeamNG updates may fix the engine-side Vulkan pool trimming natively, making this workaround unnecessary.

---

## License

Licensed under the **MIT License** — see [LICENSE](LICENSE).
