# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇧🇷 **Prefere ler em Português?** Veja [README.pt-BR.md](README.pt-BR.md).

A lightweight, non-destructive **BeamNG.drive** mod (`v1.1.0`) that stops progressive **Vulkan VRAM memory leaks** — where VRAM keeps climbing in ~100 MB steps with **any vehicle** until it saturates your GPU, collapses FPS, or crashes with `VK_ERROR_DEVICE_LOST` (while changing graphics settings temporarily drops VRAM back down).

- **Works with any vehicle and any map** — does not overwrite any vehicle or game files.
- **Works on AMD, NVIDIA, and Intel GPUs** (Vulkan backend only; automatically stays idle on DirectX 11 / DirectX 12).
- **100% pure Lua (2 small files)** — zero conflicts with other mods, idempotent startup loader.
- **Keeps all your graphics settings intact** — you can change presets, resolution, Depth of Field, mirrors, etc. freely in-game without breaking the fix.

---

## Why This Happens (Root Cause)

Binary analysis of `BeamNG.drive.x64.exe` (`v0.40.6.0`) revealed why VRAM climbs continuously under Vulkan (while DirectX 12 stays flat) and why changing any graphics setting immediately drops VRAM back down:

1. **Un-trimmed internal Vulkan pools during gameplay:** `GFXVkDevice::endScene` never trims the retired `16 MB` transfer staging slab pool (`"Buffer volatile cpu"`) and retains up to `32 × 8 MB` dynamic VRAM slabs per usage bucket, plus other internal caches. Changing graphics settings calls `GFXVkWindowTarget::resetModeInternal` → `GFXVkDevice::waitIdle()`, which purges all of those pools at once.
2. **Orphaned built-in VRAM pressure flusher:** BeamNG already ships an automatic VMA heap pressure flusher (`GFXVkDevice::vtable[+0x108]` at `0x140F10260` → `checkVmaHeapBudgets(0.85f)` at `0x140F0ED80` → `waitIdle()` at `0x140F1A710`) that triggers when `DEVICE_LOCAL` VMA usage reaches ≥ 85% of `budgetBytes` (or non-local GPU memory reaches ≥ 1 GB, or every 5th call). However, its **only caller in the binary** is `GuiCanvas::repaintUIThrottled()`, which vanilla Lua only invokes during **level loading screens** (`updateLoadingProgress`), never during normal gameplay.
3. **High default transient render-target budget:** `$gfx::transientPoolBudgetMB` defaults to **`1536 MB`** (1.5 GB), hoarding unused transient render targets — especially harsh on 8 GB GPUs without Resizable BAR (256 MB BAR).

---

## What Changed in `v1.1.0` (VMA Budget Alignment)

Disassembling `GFXVkDevice::getMemoryInfo` (`0x140EFBA40`, `vtable[+0x80]`) and `Engine.Render.getMemoryInfo` (`0x14066BA20`) uncovered an important discrepancy in how BeamNG reports Vulkan memory:

- `availableBytes` is computed in C++ as `max(0, budgetBytes - usageBytes)` — **not** `dedicatedBytes - usageBytes` (`7,368 MB` VMA budget vs `8,192 MB` physical VRAM on an 8 GB RX 580).
- Measuring against `dedicatedBytes` overestimated true VMA usage by `~824 MB`. Because of that, triggering at `78%` of `dedicatedBytes` actually caught VMA at `~75.7%` of `budgetBytes`, causing C++ `checkVmaHeapBudgets(0.85f)` to reject Taps 1–4 in 12 of 16 flushes during a 37-minute stress test (`~485–650 ms` across 5 UI taps).
- **`v1.1.0` now reads `usageBytes` and `budgetBytes` directly** and triggers active flushes at **`≥ 85.2%` of VMA `budgetBytes`** (still leaving **~1.87 GiB / 1.9 GB** of physical VRAM free on an 8 GB card):
  - **Guaranteed 1-tap flush (`~198 ms`)** on Tap #1 across AMD, NVIDIA, and Intel GPUs.
  - **~35% longer intervals between flushes** (`+700 MB` more pool accumulation absorbed cleanly before flushing).
  - **Idempotent loader (`modScript.lua`)** checks `extensions.isExtensionLoaded("vulkanVramFix")` to prevent double loading.

---

## What This Mod Does

1. **Caps `$gfx::transientPoolBudgetMB` from `1536 MB` to `384 MB`** on Vulkan (re-applied cleanly on mission start and graphics setting changes, without touching any visual menu option).
2. **Re-enables BeamNG's built-in Vulkan pool flusher during gameplay:** monitors `Engine.Render.getMemoryInfo()` once per second (negligible overhead):
   - **Active gameplay:** when VMA usage hits **≥ 85.2% of `budgetBytes`** (or fallback safety floor when physical free VRAM drops ≤ 1.45 GiB alongside ≥ 85% VMA budget), safely calls `Canvas:repaintUIThrottled()` outside the render pass (`onUpdate`), purging leaked Vulkan pools **in a single tap (~198 ms)** before VRAM saturates or triggers WDDM paging / `VK_ERROR_DEVICE_LOST`.
   - **While paused:** performs an opportunistic flush at **≥ 72% of `budgetBytes`** so memory stays clean while the pause menu is open.
   - **Anti-loop backoff:** if a flush frees `< 192 MB` (meaning VRAM is genuinely filled by static scene assets), it automatically backs off (`25 s → 60 s`) to avoid unnecessary retries.

### Verified Telemetry (`beamng.2.log` — 37-Minute Stress Test, Citybus + 7 Traffic/Police Vehicles, RX 580 8 GB Vulkan)

- **16 automatic flushes completed cleanly** over a continuous 37-minute gameplay session, reclaiming **1,972–2,147 MB per flush** and returning true VMA usage to `~3,525 MB` (`4,349–4,380 MB` physical-relative).
- **1-tap flush time:** `~198 ms` (`Trigger` → `reclaimed 2051–2056 MB`).
- **Engine errors prevented:** **0** `Failed to wait for fences` errors and **0** `bindless: material cbv array exhausted (8192 slots)` warnings during the entire 37-minute protected session (whereas running unprotected in `beamng.log` produced both).

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
| `vulkanVramFix.status()` | Prints version, VMA budget %, physical VRAM usage, `$gfx::transientPoolBudgetMB`, flush count, and total MB reclaimed. |
| `vulkanVramFix.flushNow()` | Triggers an immediate Vulkan pool purge on demand. |
| `vulkanVramFix.setBudgetMB(512)` | Changes `$gfx::transientPoolBudgetMB` (`128`–`2048` MB). Useful on 12 GB+ GPUs. |
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

- A flush executes `Canvas:repaintUIThrottled()`, which can cause a brief (~1 frame) visual blink at the moment VMA usage hits the 85.2% budget threshold.
- Tested on **BeamNG.drive v0.40.6.0**. Future BeamNG updates may fix the engine-side Vulkan pool trimming natively, making this workaround unnecessary.

---

## License

Licensed under the **MIT License** — see [LICENSE](LICENSE).
