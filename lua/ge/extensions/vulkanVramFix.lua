-- BeamNG.drive Vulkan VRAM Leak Fix (vulkanVramFix)
-- Non-destructive user-folder extension (does not alter original game files or user graphics settings).
-- Works on AMD, NVIDIA, and Intel GPUs under Vulkan; stays inactive on DirectX 11 / DirectX 12.
--
-- Extension name: vulkanVramFix (no underscores -> maps directly to lua/ge/extensions/vulkanVramFix.lua)
--
-- Root Cause Addressed (BeamNG.drive v0.40.6.0):
--   1. $gfx::transientPoolBudgetMB defaults to 1536 MB (0x600), hoarding transient render targets.
--   2. GFXVkDevice::endScene never trims retired 16 MB staging slabs and retains large per-bucket
--      dynamic VRAM buffer pools and internal caches until GFXVkDevice::waitIdle() runs.
--   3. GFXVkDevice::vtable[+0x108], BeamNG's built-in VMA heap pressure flusher that triggers
--      waitIdle(), is only called from GuiCanvas::repaintUIThrottled() (loading screens only).

local M = {}

local logTag = "vulkanVramFix"
local BYTES_PER_MB = 1024 * 1024
local BYTES_PER_GB = 1024 * 1024 * 1024

local config = {
  enabled = true,
  autoFlush = true,
  transientPoolBudgetMB = 384,   -- Vanilla default is 1536 MB
  checkIntervalSec = 1.0,        -- Poll VRAM once per second
  activeFlushRatio = 0.78,       -- Trigger flush during gameplay at >= 78% VRAM used
  activeMinFreeGB = 1.60,        -- Or when free VRAM drops <= 1.60 GiB
  pauseFlushRatio = 0.65,        -- Opportunistic flush while paused at >= 65% VRAM used
  minReclaimedMB = 192,          -- Minimum drop to consider a flush effective
  normalCooldownSec = 6.0,       -- Cooldown after an effective flush
  backoffCooldownSec = 25.0,     -- Cooldown if VRAM is genuinely filled by static scene assets
  maxBackoffSec = 60.0,
  burstStepSec = 0.06,           -- Must exceed repaintUIThrottled's 1/30s (0.0333s) throttle
  maxBurstTaps = 5,              -- 5 calls guarantees internal pressure counter triggers waitIdle()
  verifyDelaySec = 0.25,         -- Wait before measuring post-flush VRAM drop
}

local state = {
  isVulkan = false,
  loggedFirstSample = false,
  checkTimer = 0,
  cooldownTimer = 0,
  currentBackoff = config.backoffCooldownSec,
  burstActive = false,
  burstTapsDone = 0,
  burstStepTimer = 0,
  burstPreUsedMB = 0,
  verifyPending = false,
  verifyTimer = 0,
  flushCount = 0,
  totalReclaimedMB = 0,
  lastFlushReason = "none",
  lastReclaimedMB = 0,
}

local function isVulkanBackend()
  if not (Engine and Engine.Render and Engine.Render.getAdapterType) then
    return false
  end
  local ok, adapter = pcall(Engine.Render.getAdapterType)
  return ok and adapter == "Vulkan"
end

local function applyTransientBudget()
  if not state.isVulkan then return end
  if not (VariableRegistry and VariableRegistry.set) then return end
  local cur = tonumber(VariableRegistry.get and VariableRegistry.get("$gfx::transientPoolBudgetMB"))
  if cur ~= config.transientPoolBudgetMB then
    VariableRegistry.set("$gfx::transientPoolBudgetMB", config.transientPoolBudgetMB)
    log("I", logTag, string.format("Set $gfx::transientPoolBudgetMB = %d MB (was %s)", config.transientPoolBudgetMB, tostring(cur)))
  end
end

local function readGpuMemory()
  if not (Engine and Engine.Render and Engine.Render.getMemoryInfo) then
    return nil
  end
  local ok, mem = pcall(Engine.Render.getMemoryInfo)
  if not ok or type(mem) ~= "table" or not mem.valid then
    return nil
  end

  local totalBytes = nil
  if mem.isDedicatedMemory and mem.dedicatedBytes and mem.dedicatedBytes > 0 then
    totalBytes = mem.dedicatedBytes
  elseif mem.dedicatedBytes and mem.dedicatedBytes > 0 then
    totalBytes = mem.dedicatedBytes
  elseif mem.budgetBytes and mem.budgetBytes > 0 then
    totalBytes = mem.budgetBytes
  elseif mem.sharedBytes and mem.sharedBytes > 0 then
    totalBytes = mem.sharedBytes
  end

  if not totalBytes or totalBytes <= 0 or not mem.availableBytes then
    return nil
  end

  local availableBytes = math.max(0, mem.availableBytes)
  local usedBytes = math.max(0, totalBytes - availableBytes)
  local usedRatio = usedBytes / totalBytes

  return {
    raw = mem,
    totalBytes = totalBytes,
    availableBytes = availableBytes,
    usedBytes = usedBytes,
    usedMB = usedBytes / BYTES_PER_MB,
    totalMB = totalBytes / BYTES_PER_MB,
    availableGB = availableBytes / BYTES_PER_GB,
    usedRatio = usedRatio,
  }
end

local function isSafeToFlush()
  if not state.isVulkan then return false end
  if VariableRegistry and VariableRegistry.get and VariableRegistry.get("$loadingLevel") then
    return false
  end
  if Engine and Engine.isProgramFocused then
    local ok, focused = pcall(Engine.isProgramFocused)
    if ok and focused == false then
      return false
    end
  end
  local canvas = scenetree and scenetree.findObject and scenetree.findObject("Canvas")
  if not canvas or not canvas.repaintUIThrottled then
    return false
  end
  return true, canvas
end

local function startFlushBurst(reason, mem)
  local safe = isSafeToFlush()
  if not safe then return false end

  state.burstActive = true
  state.burstTapsDone = 0
  state.burstStepTimer = 0
  state.verifyPending = false
  state.verifyTimer = 0
  state.burstPreUsedMB = mem and mem.usedMB or 0
  state.lastFlushReason = reason or "threshold"

  log("I", logTag, string.format(
    "Triggering Vulkan pool flush (%s): VRAM %.0f / %.0f MB (%.1f%%, free %.2f GiB)",
    state.lastFlushReason,
    mem and mem.usedMB or 0,
    mem and mem.totalMB or 0,
    mem and (mem.usedRatio * 100) or 0,
    mem and mem.availableGB or 0
  ))
  return true
end

local function stepBurst(dtReal)
  if state.burstActive then
    state.burstStepTimer = state.burstStepTimer - dtReal
    if state.burstStepTimer > 0 then return true end

    local safe, canvas = isSafeToFlush()
    if not safe then
      state.burstActive = false
      state.cooldownTimer = config.normalCooldownSec
      return true
    end

    if state.burstTapsDone > 0 then
      local curMem = readGpuMemory()
      if curMem and (state.burstPreUsedMB - curMem.usedMB) >= config.minReclaimedMB then
        local reclaimed = state.burstPreUsedMB - curMem.usedMB
        state.burstActive = false
        state.flushCount = state.flushCount + 1
        state.totalReclaimedMB = state.totalReclaimedMB + reclaimed
        state.lastReclaimedMB = reclaimed
        state.currentBackoff = config.backoffCooldownSec
        state.cooldownTimer = config.normalCooldownSec
        log("I", logTag, string.format(
          "Vulkan pool flush succeeded after %d tap(s): reclaimed %.0f MB (now %.0f / %.0f MB)",
          state.burstTapsDone, reclaimed, curMem.usedMB, curMem.totalMB
        ))
        return true
      end
    end

    if state.burstTapsDone >= config.maxBurstTaps then
      state.burstActive = false
      state.verifyPending = true
      state.verifyTimer = config.verifyDelaySec
      return true
    end

    local ok, err = pcall(function() canvas:repaintUIThrottled() end)
    if not ok then
      log("W", logTag, "repaintUIThrottled call failed: " .. tostring(err))
      state.burstActive = false
      state.cooldownTimer = config.backoffCooldownSec
      return true
    end

    state.burstTapsDone = state.burstTapsDone + 1
    state.burstStepTimer = config.burstStepSec
    return true
  end

  if state.verifyPending then
    state.verifyTimer = state.verifyTimer - dtReal
    if state.verifyTimer > 0 then return true end
    state.verifyPending = false

    local curMem = readGpuMemory()
    local reclaimed = curMem and (state.burstPreUsedMB - curMem.usedMB) or 0
    if reclaimed >= config.minReclaimedMB then
      state.flushCount = state.flushCount + 1
      state.totalReclaimedMB = state.totalReclaimedMB + reclaimed
      state.lastReclaimedMB = reclaimed
      state.currentBackoff = config.backoffCooldownSec
      state.cooldownTimer = config.normalCooldownSec
      log("I", logTag, string.format(
        "Vulkan pool flush reclaimed %.0f MB (now %.0f / %.0f MB)",
        reclaimed, curMem.usedMB, curMem.totalMB
      ))
    else
      state.lastReclaimedMB = reclaimed
      state.cooldownTimer = state.currentBackoff
      state.currentBackoff = math.min(config.maxBackoffSec, state.currentBackoff * 1.5)
      log("I", logTag, string.format(
        "Vulkan pool flush reclaimed only %.0f MB (now %.0f / %.0f MB); backing off for %.0fs",
        reclaimed, curMem and curMem.usedMB or 0, curMem and curMem.totalMB or 0, state.cooldownTimer
      ))
    end
    return true
  end

  return false
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not config.enabled or not state.isVulkan then return end
  local dt = dtReal or dtRaw or 0.016
  if dt <= 0 or dt > 1.0 then dt = 0.016 end

  if stepBurst(dt) then return end

  if state.cooldownTimer > 0 then
    state.cooldownTimer = state.cooldownTimer - dt
    return
  end

  state.checkTimer = state.checkTimer + dt
  if state.checkTimer < config.checkIntervalSec then return end
  state.checkTimer = 0

  applyTransientBudget()

  if not config.autoFlush then return end

  local mem = readGpuMemory()
  if not mem then return end

  if not state.loggedFirstSample then
    state.loggedFirstSample = true
    log("I", logTag, string.format(
      "First GPU memory sample: used=%.0f/%.0f MB (%.1f%%), free=%.2f GiB, dedicated=%s, budget=%s",
      mem.usedMB, mem.totalMB, mem.usedRatio * 100, mem.availableGB,
      tostring(mem.raw.dedicatedBytes), tostring(mem.raw.budgetBytes)
    ))
  end

  local isPaused = simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() or false
  if isPaused and mem.usedRatio >= config.pauseFlushRatio then
    startFlushBurst("paused_opportunistic", mem)
    return
  end

  if mem.usedRatio >= config.activeFlushRatio or mem.availableGB <= config.activeMinFreeGB then
    startFlushBurst("vram_pressure", mem)
  end
end

local function onSettingsChanged()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.currentBackoff = config.backoffCooldownSec
  state.cooldownTimer = 3.0
end

local function onClientStartMission()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.loggedFirstSample = false
  state.currentBackoff = config.backoffCooldownSec
  state.cooldownTimer = 5.0
end

local function onExtensionLoaded()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  log("I", logTag, string.format(
    "Loaded successfully (backend=%s, transientPoolBudgetMB=%d, autoFlush=%s, activeThreshold=%.0f%%/%.2fGiB)",
    state.isVulkan and "Vulkan" or "non-Vulkan",
    config.transientPoolBudgetMB,
    tostring(config.autoFlush),
    config.activeFlushRatio * 100,
    config.activeMinFreeGB
  ))
end

local function status()
  local mem = readGpuMemory()
  local curBudget = VariableRegistry and VariableRegistry.get and VariableRegistry.get("$gfx::transientPoolBudgetMB")
  local info = string.format(
    "[vulkanVramFix] vulkan=%s autoFlush=%s transientBudget=%sMB flushes=%d totalReclaimed=%.0fMB lastReclaimed=%.0fMB(%s) | VRAM=%s",
    tostring(state.isVulkan),
    tostring(config.autoFlush),
    tostring(curBudget),
    state.flushCount,
    state.totalReclaimedMB,
    state.lastReclaimedMB,
    state.lastFlushReason,
    mem and string.format("%.0f/%.0f MB (%.1f%%, free %.2f GiB)", mem.usedMB, mem.totalMB, mem.usedRatio * 100, mem.availableGB) or "unavailable"
  )
  log("I", logTag, info)
  print(info)
  return info
end

local function flushNow()
  state.isVulkan = isVulkanBackend()
  if not state.isVulkan then
    print("[vulkanVramFix] Not running on Vulkan backend.")
    return false
  end
  state.cooldownTimer = 0
  return startFlushBurst("manual_console", readGpuMemory())
end

local function setBudgetMB(mb)
  local n = tonumber(mb)
  if not n or n < 128 or n > 2048 then
    print("[vulkanVramFix] Budget must be between 128 and 2048 MB.")
    return false
  end
  config.transientPoolBudgetMB = math.floor(n)
  applyTransientBudget()
  return true
end

local function setAutoFlush(enabled)
  config.autoFlush = not not enabled
  log("I", logTag, "autoFlush set to " .. tostring(config.autoFlush))
  return config.autoFlush
end

M.onExtensionLoaded = onExtensionLoaded
M.onSettingsChanged = onSettingsChanged
M.onClientStartMission = onClientStartMission
M.onUpdate = onUpdate
M.status = status
M.flushNow = flushNow
M.setBudgetMB = setBudgetMB
M.setAutoFlush = setAutoFlush

return M
