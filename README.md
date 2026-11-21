# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇧🇷 **Prefere ler em Português?** Veja [README.pt-BR.md](README.pt-BR.md).

A lightweight, non-destructive **BeamNG.drive** mod that stops progressive **Vulkan VRAM memory leaks** — where VRAM keeps climbing in ~100 MB steps with **any vehicle** until it saturates your GPU, collapses FPS, or crashes with `VK_ERROR_DEVICE_LOST` (while changing graphics settings temporarily drops VRAM back down).

- **Works with any vehicle and any map** — does not overwrite any vehicle or game files.
- **Works on AMD, NVIDIA, and Intel GPUs** (Vulkan backend only; automatically stays idle on DirectX 11 / DirectX 12).
- **100% pure Lua (2 small files)** — zero conflicts with other mods.
- **Keeps all your graphics settings intact** — you can change presets, resolution, Depth of Field, mirrors, etc. freely in-game without breaking the fix.

---

## Why This Happens (Root Cause)

Static analysis of `BeamNG.drive.x64.exe` (`v0.40.6.0`) revealed why VRAM climbs continuously under Vulkan (while DirectX 12 stays flat) and why changing any graphics setting immediately drops VRAM back down:

1. **Un-trimmed internal Vulkan pools during gameplay:** `GFXVkDevice::endScene` never trims the retired `16 MB` transfer staging slab pool (`"Buffer volatile cpu"`) and retains up to `32 × 8 MB` dynamic VRAM slabs per usage bucket, plus other internal caches. Changing graphics settings calls `GFXVkWindowTarget::resetModeInternal` → `GFXVkDevice::waitIdle()`, which purges all of those pools at once.
2. **Orphaned built-in VRAM pressure flusher:** BeamNG already ships an automatic VMA heap pressure flusher (`GFXVkDevice::vtable[+0x108]`) that triggers `waitIdle()` when VRAM reaches ≥ 85% of budget or non-local GPU memory reaches ≥ 1 GB. However, its **only caller in the binary** is `GuiCanvas::repaintUIThrottled()`, which vanilla Lua only invokes during **level loading screens** (`updateLoadingProgress`), never during normal gameplay.
3. **High default transient render-target budget:** `$gfx::transientPoolBudgetMB` defaults to **`1536 MB`** (1.5 GB), hoarding unused transient render targets — especially harsh on 8 GB GPUs without Resizable BAR (256 MB BAR).

---

## What This Mod Does

1. **Caps `$gfx::transientPoolBudgetMB` from `1536 MB` to `384 MB`** on Vulkan (re-applied cleanly on mission start and graphics setting changes, without touching any visual menu option).
2. **Re-enables BeamNG's built-in Vulkan pool flusher during gameplay:** monitors `Engine.Render.getMemoryInfo()` once per second (negligible overhead):
   - **Active gameplay:** when VRAM usage hits **≥ 78%** (or free VRAM drops **≤ 1.60 GiB**), safely calls `Canvas:repaintUIThrottled()` outside the render pass (`onUpdate`), purging leaked Vulkan pools **before** VRAM saturates and triggers WDDM paging or `VK_ERROR_DEVICE_LOST`.
   - **While paused:** performs an opportunistic flush at **≥ 65%** VRAM so memory stays clean while the pause menu is open.
   - **Anti-loop backoff:** if a flush frees `< 192 MB` (meaning VRAM is genuinely filled by static scene assets), it automatically backs off (`25 s → 60 s`) to avoid unnecessary retries.

### Verified Results (`beamng.log` — RX 580 8 GB, Vulkan)

Every pressure event flushed on the **first tap (~280 ms)**, keeping VRAM stable between **4.6 GB and 6.4 GB** instead of saturating 8 GB and collapsing to 10 FPS:

```text
Set $gfx::transientPoolBudgetMB = 384 MB (was 1536)
Triggering Vulkan pool flush (vram_pressure): VRAM 6479 / 8192 MB (79.1%, free 1.67 GiB)
Vulkan pool flush succeeded after 1 tap(s): reclaimed 1872 MB (now 4608 / 8192 MB)
Triggering Vulkan pool flush (vram_pressure): VRAM 6441 / 8192 MB (78.6%, free 1.71 GiB)
Vulkan pool flush succeeded after 1 tap(s): reclaimed 1817 MB (now 4624 / 8192 MB)
Triggering Vulkan pool flush (paused_opportunistic): VRAM 5478 / 8192 MB (66.9%, free 2.65 GiB)
Vulkan pool flush succeeded after 1 tap(s): reclaimed 607 MB (now 4871 / 8192 MB)
```

---

## Installation

### Option 1 — Easy Install (Recommended)
1. Download `beamng_vulkan_vram_fix.zip` from the [**Releases**](https://github.com/arthurquadro/beamng-vulkan-vram-fix/releases/latest) page.
2. Drop the `.zip` file (without extracting) into your BeamNG mods folder:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
   ```
   *(Usually `C:\Users\<YourUser>\AppData\Local\BeamNG\BeamNG.drive\current\mods\`.)*
3. Launch **BeamNG.drive** in **Vulkan** mode.

### Option 2 — Unpacked Install (From Repository Source)
1. Download or clone this repository.
2. Copy the `scripts/` and `lua/` folders into:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamng_vulkan_vram_fix\
   ```
3. Launch **BeamNG.drive** in **Vulkan** mode.

---

## Console Commands (Optional)

Open the in-game console (`~` or `'`), switch to **BeamNG - Lua / GE**, and run:

| Command | Description |
| :--- | :--- |
| `vulkanVramFix.status()` | Prints current VRAM usage, `$gfx::transientPoolBudgetMB`, flush count, and total MB reclaimed. |
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

- A flush executes `Canvas:repaintUIThrottled()`, which can cause a brief (~1 frame) visual blink at the moment VRAM hits the 78% safety ceiling.
- Tested on **BeamNG.drive v0.40.6.0**. Future BeamNG updates may fix the engine-side Vulkan pool trimming natively, making this workaround unnecessary.

---

## License

Licensed under the **MIT License** — see [LICENSE](LICENSE).
