# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇧🇷 **Prefere ler em Português?** Veja [README.pt-BR.md](README.pt-BR.md).

A lightweight, non-destructive **BeamNG.drive** mod (`v1.2.1`) that stops progressive **Vulkan VRAM memory leaks** and **high-VRAM spillover into slow system RAM ("SWAP")** — preventing VRAM saturation that causes severe FPS collapses (~10–14 FPS) or crashes (while changing graphics settings temporarily drops VRAM back down).

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

## What Changed in `v1.2.1` (Anti-SWAP Tuning & `VK_ERROR_DEVICE_LOST` Hotfix)

In `v1.2.0`, flushing unconditionally whenever `SWAP >= 1032 MB` — even while VRAM was already at its clean `55%–60%` floor (`~4,040 MB` used, `3.68–4.04 GiB` physical VRAM free) — fought the engine's legitimate active `SWAP` working set (`~1,015–1,230 MB` of retained volatile/transfer staging slabs plus `+180–450 MB` frame streaming churn). Repeating `GFXVkDevice::waitIdle()` every ~8 seconds at `55%` VRAM interrupted background `transferAcc->queue.submit` uploads and triggered `VK_ERROR_DEVICE_LOST` (`vkGpuCrashBreadcrumbs.cpp:626`).

Meanwhile, telemetry from the exact same sessions proved that flushing **only when `VRAM` is genuinely elevated (`≥ 78%` VMA budget while `SWAP >= 1032 MB`)** consistently triggered a clean **1-tap `waitIdle()`** via `0x140F0EEA3` and reclaimed **`1,520–1,796 MB` of leaked VRAM per flush** without hanging on the `~78%–84%` plateau.

### `v1.2.1` fixes:
1. **Elevated-VRAM gate for Swap-Assisted flushes:** `swap_assisted_vram_pressure` only triggers when **`SWAP >= 1032 MB` AND `VMA >= 78.0%`** (plus standard `vram_pressure` at **`VMA >= 85.2%`**). When VRAM is healthy (`< 78%`), the mod stays completely idle regardless of normal `SWAP` transfer ring activity.
2. **Restores stable `$gfx::transientPoolBudgetMB = 384 MB` and `72%` pause cleanup:** Reverts `v1.2.0`'s `256 MB` / `64%` values back to `v1.1.0`'s crash-free `384 MB` budget and `72%` paused threshold, reducing unnecessary render-target churn.
3. **Strict VRAM-only effectiveness & 1-tap bursts:** Counts a flush as effective **only** if at least **`192 MB` of VRAM** is reclaimed (ignoring staging churn in `SWAP`), caps bursts to **1 tap** when `VMA >= 85.2%` or `SWAP >= 1032 MB`, increases active cooldown to **`15 s`** (`30 s → 90 s` backoff, **`15 s`** post-mission grace period, **`5 s`** post-settings cooldown), and removes aggressive low-VRAM triggers (`swap_growth_preventive`, `wddm_budget_contraction`, `paused_swap_cleanup`, `post_mission_swap_cleanup`, `post_settings_cleanup`).

### Earlier Findings (`v1.2.0` & `v1.1.0`)

- **Non-Local `SWAP` visibility (`0x140EFA680` → `0x140EF7C90`):** `Engine.Render.getMemoryInfo()` (`0x140EFBA40`) is blind to non-local `SWAP` on discrete GPUs (`sharedBytes = 0`), whereas `Engine.Platform.getGPUAdaptersInfo()` reads `VK_EXT_memory_budget` (`nonLocalUsageBytes` / `nonLocalBudgetBytes`). C++ `checkVmaHeapBudgets` (`0x140F0EEA3`) permits a 1-tap flush whenever `nonLocalUsageBytes >= 1 GiB`.
- **Broken OOM callback & priority inversion:** `vku::GenericBuffer` (`0x140EE42DD`) and `vku::GenericImage::create` (`0x14037E22C`) have a no-op OOM callback (`0x1401035E0 = ret 0`), while `VK_EXT_memory_priority` gives idle render targets `1.0f` vs `0.75f` for map geometry/textures — making it critical to keep VRAM below ~78–85% so Windows WDDM does not evict `0.75f` map assets into slow PCIe RAM (`Heap 2`).
- **VMA Budget Alignment (`v1.1.0`):** `GFXVkDevice::getMemoryInfo` reports `availableBytes = max(0, budgetBytes - usageBytes)`. Aligning the standard active threshold to `usageBytes / budgetBytes >= 0.852` guarantees 1-tap flushes in `~198–260 ms`.

---

## What This Mod Does

1. **Caps `$gfx::transientPoolBudgetMB` from `1536 MB` to `384 MB`** on Vulkan (re-applied cleanly on mission start and graphics setting changes, without touching any visual menu option).
2. **Monitors both VRAM and `SWAP` (non-local GPU memory)** via `Engine.Render.getMemoryInfo()` and `Engine.Platform.getGPUAdaptersInfo()`, calling `Canvas:repaintUIThrottled()` safely outside the render pass (`onUpdate`):
   - **Standard VMA pressure (`≥ 85.2%` of `budgetBytes`):** triggers C++ `checkVmaHeapBudgets(0.85f)` in **1 single tap** (`~200–285 ms`).
   - **Swap-Assisted VMA pressure (`≥ 78.0%` VMA while `SWAP ≥ 1032 MB`):** uses C++'s `1 GiB` non-local check (`0x140F0EEA3`) for an early **1-tap** purge before `~78%–84%` VRAM stalls allow map assets to spill into PCIe `SWAP`.
   - **While paused:** cleans opportunistically only when **`VMA ≥ 72.0%`**.
   - **Safety cooldowns & anti-loop backoff:** enforces a **`15 s`** post-flush cooldown (**`15 s`** after map load, **`5 s`** after settings changes) so async `transferAcc` uploads settle cleanly; if `< 192 MB` of VRAM is reclaimed, backs off cleanly (`30 s → 90 s`).

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
- By design in Vulkan, once a buffer or texture has already been bound to non-local system RAM (`SWAP`), it cannot be migrated back to VRAM in place. `v1.2.1` keeps VRAM headroom safely below eviction thresholds without interrupting active `SWAP` staging traffic at low VRAM.
- Tested on **BeamNG.drive v0.40.6.0**. Future BeamNG updates may fix the engine-side Vulkan pool trimming natively, making this workaround unnecessary.

---

## License

Licensed under the **MIT License** — see [LICENSE](LICENSE).
