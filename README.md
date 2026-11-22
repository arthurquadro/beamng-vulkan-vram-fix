# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇧🇷 **Prefere ler em Português?** Veja [README.pt-BR.md](README.pt-BR.md).

A lightweight, non-destructive **BeamNG.drive** mod (`v1.2.0`) that stops progressive **Vulkan VRAM memory leaks** and **non-local system RAM ("SWAP") GPU spillover** — preventing VRAM/shared-memory saturation that causes severe FPS collapses (~10–14 FPS) or `VK_ERROR_DEVICE_LOST` crashes (while changing graphics settings temporarily drops VRAM back down).

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

## What Changed in `v1.2.0` (Anti-SWAP / Non-Local GPU Spillover Protection)

Extended binary reverse engineering uncovered why heavy maps (like **West Coast USA**) could still collapse to ~14 FPS even while VRAM appeared to have ~2.2 GB free and `SWAP` / Shared GPU Memory (`nonLocalUsageBytes`) climbed above 2+ GB:

1. **`Engine.Render.getMemoryInfo()` (`0x140EFBA40`) is completely blind to `SWAP`:** it filters strictly for `VK_MEMORY_HEAP_DEVICE_LOCAL_BIT` and hardcodes `sharedBytes = 0` on discrete GPUs (`0x140EFBBFA`). By contrast, `Engine.Platform.getGPUAdaptersInfo()` (`0x140EFA680` → `0x140EF7C90`) queries `VK_EXT_memory_budget` and exposes exact **`nonLocalUsageBytes` / `nonLocalBudgetBytes`** (`SWAP`). Furthermore, C++ `checkVmaHeapBudgets` (`0x140F0EEA3`) triggers an immediate 1-tap `waitIdle()` purge whenever `nonLocalUsageBytes >= 1 GiB`.
2. **Broken OOM callback & irreversible `SWAP` fallback:** `vku::GenericBuffer` (`0x140EE42DD`) and `vku::GenericImage::create` (`0x14037E22C`) point their VMA OOM callback (`[0x142FC66F8]`, `0x140F0E415`) to an empty no-op function (`0x1401035E0 = ret 0`). When VRAM reaches budget or fragments, map buffers/textures fall back to `Heap 2` (non-local PCIe system RAM), where Vulkan binds them permanently for the rest of their lifetime (~15–20× slower than GDDR5/GDDR6).
3. **Inverted `VK_EXT_memory_priority` under `VK_EXT_pageable_device_local_memory`:** render targets and shadow/lighting scratch buffers (including `1–2 GB` of pooled idle targets) are allocated at `priority = 1.0f` (`0x14037E100` / `0x140EE417C`), while live map meshes, bindless arenas, and textures get `priority = 0.75f`. When Windows WDDM dynamically shrinks `budgetBytes` (e.g., from `7,368 MB` down to `6,879 MB`), it evicts `0.75f` map geometry & textures to slow `SWAP` to protect idle `1.0f` pools.
4. **`v1.2.0` countermeasures:**
   - **Tracks `SWAP` (`nonLocalUsageBytes`) directly** via `Engine.Platform.getGPUAdaptersInfo()` alongside VMA VRAM, resetting backoff when `SWAP` is reclaimed.
   - **Proactive prevention thresholds:** lowers `$gfx::transientPoolBudgetMB` further to **`256 MB`** (reducing idle `1.0f` targets), lowers paused opportunistic cleanup to **`64%`** VMA (or `SWAP` ≥ 512 MB), adds a **WDDM budget contraction guard** (`≥ 78%` when `budgetMB < 87%` of dedicated VRAM), adds a **SWAP growth guard** (`≥ 640 MB` or combined pressure `≥ 86%`), and executes a **1-tap `waitIdle()` at `≥ 1032 MB` `SWAP`** (`0x140F0EEA3`).
   - **Post-load & post-settings purges:** clears leftover staging upload lists (`[r15+0x438]`, `[r15+0x4B8]`, `[r15+0xE38]`) `10s` after level/traffic loading finishes and `2s` after changing graphics quality settings.

### Earlier Milestone (`v1.1.0` — VMA Budget Alignment)

- Disassembling `GFXVkDevice::getMemoryInfo` (`0x140EFBA40`) proved `availableBytes = max(0, budgetBytes - usageBytes)` rather than `dedicatedBytes - usageBytes`. Aligning the active VRAM trigger to `usageBytes / budgetBytes >= 0.852` guaranteed 1-tap flushes via `checkVmaHeapBudgets(0.85f)` in `~198–260 ms` (`16/16` in Italy, `9/9` in West Coast USA pursuits reclaiming `18.5 GB` with `0` fence errors).

---

## What This Mod Does

1. **Caps `$gfx::transientPoolBudgetMB` from `1536 MB` to `256 MB`** on Vulkan (re-applied cleanly on mission start and graphics setting changes, without touching any visual menu option).
2. **Monitors both VRAM and `SWAP` (non-local GPU memory)** via `Engine.Render.getMemoryInfo()` and `Engine.Platform.getGPUAdaptersInfo()`, calling `Canvas:repaintUIThrottled()` safely outside the render pass (`onUpdate`):
   - **VMA pressure (`≥ 85.2%` of `budgetBytes`)** or **`SWAP` hard cap (`≥ 1032 MB`)**: triggers C++ `checkVmaHeapBudgets` on **Tap #1** (`~200–260 ms`).
   - **WDDM budget contraction (`≥ 78%` while WDDM shrunk budget `< 87%` physical VRAM)** & **`SWAP` growth (`≥ 640 MB`, +160 MB over floor)**: proactively runs the 5-tap bypass (`~250 ms`) before Windows WDDM evicts `0.75f` map assets into PCIe RAM.
   - **While paused:** cleans opportunistically at **`≥ 64%` VMA** or **`SWAP ≥ 512 MB`** (+128 MB over floor).
   - **Post-spawn & post-settings:** trims residual staging buffers `10s` after mission load completes and `2s` after changing graphics settings.
   - **Anti-loop backoff & floor tracking:** if static assets fill VRAM (`< 192 MB` VRAM and `< 128 MB` SWAP reclaimed), backs off cleanly (`25 s → 90 s` VRAM, `30 s → 120 s` SWAP) and updates the irreducible `SWAP` floor.

### Verified Telemetry (`beamng.2.log` & `beamng.1.log` — Citybus + 7 Traffic/Police Vehicles, RX 580 8 GB Vulkan)

- **Italy 37-min stress test (`beamng.2.log`):** **16 automatic flushes completed cleanly**, reclaiming **1,972–2,147 MB per flush**, with **0** `Failed to wait for fences` errors.
- **West Coast USA pursuit test (`beamng.1.log`):** **9/9 consecutive 1-tap flushes (`206–285 ms`)**, reclaiming **18,528 MB (~18.5 GB)** in 17 minutes under `~120 MB/s` police-chase pool churn, maintaining a flat baseline (`4,040 MB`) and **0** `VK_ERROR_DEVICE_LOST` / fence errors.

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
| `vulkanVramFix.setBudgetMB(256)` | Changes `$gfx::transientPoolBudgetMB` (`128`–`2048` MB; default `256`). Useful on 12 GB+ GPUs. |
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
- By design in Vulkan, once a buffer or texture has already been bound to non-local system RAM (`SWAP`), it cannot be migrated back to VRAM in place. `v1.2.0` prevents assets from spilling into `SWAP` in the first place and purges accumulated staging/volatile `SWAP` slabs before WDDM eviction happens.
- Tested on **BeamNG.drive v0.40.6.0**. Future BeamNG updates may fix the engine-side Vulkan pool trimming natively, making this workaround unnecessary.

---

## License

Licensed under the **MIT License** — see [LICENSE](LICENSE).
