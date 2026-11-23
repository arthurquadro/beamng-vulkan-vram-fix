-- BeamNG.drive Vulkan VRAM Leak Fix (vulkanVramFix v1.2.1)
-- Non-destructive user-folder extension (does not alter original game files or user graphics settings).
-- Works on AMD, NVIDIA, and Intel GPUs under Vulkan; stays inactive on DirectX 11 / DirectX 12.
--
-- Extension name: vulkanVramFix (no underscores -> maps directly to lua/ge/extensions/vulkanVramFix.lua)
--
-- Root Causes Addressed (BeamNG.drive v0.40.6.0):
--   1. $gfx::transientPoolBudgetMB defaults to 1536 MB (0x600), hoarding priority-1.0f transient
--      render targets that crowd out priority-0.75f map geometry & textures under WDDM paging.
--      Capped at 384 MB (proven crash-free without unnecessary transient RT recreation churn).
--   2. GFXVkDevice::endScene never trims retired 16 MB staging slabs ("Buffer volatile cpu",
--      allocated in non-local SWAP) or per-bucket dynamic VRAM slabs until GFXVkDevice::waitIdle() runs.
--   3. GFXVkDevice::vtable[+0x108] (0x140F10260), BeamNG's built-in VMA heap pressure flusher
--      (checkVmaHeapBudgets(0.85f) @ 0x140F0ED80 -> waitIdle() @ 0x140F1A710), is only called from
--      GuiCanvas::repaintUIThrottled() during loading screens in vanilla Lua.
--   4. v1.1.0 VMA Budget Alignment: GFXVkDevice::getMemoryInfo (0x140EFBA40) reports availableBytes
--      relative to VMA budgetBytes (budgetBytes - usageBytes), not dedicatedBytes. Triggering on
--      usageBytes / budgetBytes >= 0.852 guarantees C++ checkVmaHeapBudgets(0.85f) fires on Tap #1.
--   5. v1.2.0 / v1.2.1 Swap-Assisted Threshold + Anti-Thrash Fix:
--      Engine.Platform.getGPUAdaptersInfo() (0x140EFA680 -> 0x140EF7C90) exposes nonLocalUsageBytes (SWAP).
--      When SWAP >= 1 GiB (1024 MB), C++ checkVmaHeapBudgets (0x140F0EEA3) already permits a 1-tap flush
--      at lower VRAM usage (~78% VMA), preventing the ~78%-84% VRAM plateau where WDDM spills static
--      map geometry into slow PCIe RAM. Conversely, normal rendering keeps ~1.0-1.4 GB of legitimate
--      volatile/transfer staging buffers in SWAP; calling waitIdle() when VRAM is already low (< 78%)
--      only thrashes transferAcc staging slabs and can trigger VK_ERROR_DEVICE_LOST on queue submit.
--      v1.2.1 therefore requires ELEVATED VRAM (vmaBudgetRatio >= 0.78 when SWAP >= 1032 MB, or >= 0.852
--      otherwise, or >= 0.72 while paused), enforces a strict VRAM-only reclaim check (>= 192 MB), uses
--      1-tap bursts when C++ 1-tap is guaranteed, and waits 15s between active flushes.

local M = {}

local logTag = "vulkanVramFix"
local BYTES_PER_MB = 1024 * 1024
local BYTES_PER_GB = 1024 * 1024 * 1024

local config = {
  version = "1.2.1",
  enabled = true,
  autoFlush = true,
  transientPoolBudgetMB = 384,        -- Vanilla default is 1536 MB; 384 MB avoids RT churn
  checkIntervalSec = 1.0,             -- Poll VRAM once per second
  swapCheckEveryNTicks = 2,           -- Poll Engine.Platform.getGPUAdaptersInfo() every 2s & around flushes
  activeVmaBudgetRatio = 0.852,       -- Standard 1-tap VMA threshold when SWAP < 1032 MB
  activeSwapAssistedVmaRatio = 0.78,  -- Early 1-tap VMA threshold when SWAP >= 1032 MB (never flushes if VRAM < 78%)
  activeSwapHardMB = 1032,            -- Just above C++ 1 GiB (1024 MB) threshold -> 1-tap flush
  activeFallbackUsedRatio = 0.78,     -- Fallback ratio only when budgetBytes is unavailable
  activeMinPhysicalFreeGB = 1.60,     -- Physical VRAM safety floor in GiB
  pauseVmaBudgetRatio = 0.72,         -- Safe opportunistic flush while paused in menus
  minReclaimedMB = 192,               -- Strict VRAM-only effectiveness check (MB)
  normalCooldownSec = 15.0,           -- Cooldown after an effective flush so transferAcc streaming settles
  backoffCooldownSec = 30.0,          -- Cooldown if VRAM is genuinely filled by static scene assets
  maxBackoffSec = 90.0,
  burstStepSec = 0.05,                -- Must exceed repaintUIThrottled's 1/30s (0.0333s) throttle
  maxBurstTaps = 5,                   -- Forces C++ checkVmaHeapBudgets 5-call bypass when needed
  verifyDelaySec = 0.25,              -- Wait before measuring post-flush VRAM/SWAP drop
}

local state = {
  isVulkan = false,
  loggedFirstSample = false,
  checkTimer = 0,
  cooldownTimer = 0,
  currentBackoff = config.backoffCooldownSec,
  swapPollTick = 0,
  cachedSwap = nil,
  burstActive = false,
  burstTapsDone = 0,
  burstMaxTaps = config.maxBurstTaps,
  burstStepTimer = 0,
  burstPreUsedMB = 0,
  burstPreSwapMB = 0,
  verifyPending = false,
  verifyTimer = 0,
  flushCount = 0,
  totalReclaimedMB = 0,
  totalSwapReclaimedMB = 0,
  lastFlushReason = "none",
  lastReclaimedMB = 0,
  lastSwapReclaimedMB = 0,
}

local function isVulkanBackend()
  if not (Engine and Engine.Render and Engine.Render.getAdapterType) then
    return false
  end
  local ok, adapter = pcall(Engine.Render.getAdapterType)
  return ok and adapter == "Vulkan"
end

local function isLoadingInProgress()
  if VariableRegistry and VariableRegistry.get and VariableRegistry.get("$loadingLevel") then
    return true
  end
  if core_gamestate and core_gamestate.loading then
    local ok, loading = pcall(core_gamestate.loading)
    if ok and loading then
      return true
    end
  end
  return false
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

local function readNonLocalSwap(dedicatedBytesHint)
  if not (Engine and Engine.Platform and Engine.Platform.getGPUAdaptersInfo) then
    return nil
  end
  local ok, adapters = pcall(Engine.Platform.getGPUAdaptersInfo)
  if not ok or type(adapters) ~= "table" or #adapters == 0 then
    return nil
  end

  local chosen = nil
  local bestScore = -1
  for _, gpu in ipairs(adapters) do
    if type(gpu) == "table" and type(gpu.nonLocalUsageBytes) == "number" then
      local score = 1
      if gpu.api == "Vulkan" then score = score + 100 end
      if gpu.type == "dedicated" then score = score + 50 end
      if dedicatedBytesHint and gpu.dedicatedVideoMemoryBytes == dedicatedBytesHint then
        score = score + 25
      end
      if type(gpu.localUsageBytes) == "number" and gpu.localUsageBytes > 0 then
        score = score + 10
      end
      if score > bestScore
        or (score == bestScore and chosen and (gpu.localUsageBytes or 0) > (chosen.localUsageBytes or 0)) then
        bestScore = score
        chosen = gpu
      end
    end
  end

  if not chosen then
    return nil
  end

  local swapUsedBytes = math.max(0, chosen.nonLocalUsageBytes)
  local swapBudgetBytes = (type(chosen.nonLocalBudgetBytes) == "number" and chosen.nonLocalBudgetBytes > 0)
    and chosen.nonLocalBudgetBytes or nil
  local adapterLocalUsageMB = (type(chosen.localUsageBytes) == "number" and chosen.localUsageBytes >= 0)
    and (chosen.localUsageBytes / BYTES_PER_MB) or nil
  local adapterLocalBudgetMB = (type(chosen.localBudgetBytes) == "number" and chosen.localBudgetBytes > 0)
    and (chosen.localBudgetBytes / BYTES_PER_MB) or nil

  return {
    swapUsedBytes = swapUsedBytes,
    swapUsedMB = swapUsedBytes / BYTES_PER_MB,
    swapBudgetBytes = swapBudgetBytes,
    swapBudgetMB = swapBudgetBytes and (swapBudgetBytes / BYTES_PER_MB) or nil,
    adapterLocalUsageMB = adapterLocalUsageMB,
    adapterLocalBudgetMB = adapterLocalBudgetMB,
    adapterName = type(chosen.name) == "string" and chosen.name or nil,
  }
end

local function readGpuMemory(forceSwapRefresh)
  if not (Engine and Engine.Render and Engine.Render.getMemoryInfo) then
    return nil
  end
  local ok, mem = pcall(Engine.Render.getMemoryInfo)
  if not ok or type(mem) ~= "table" or not mem.valid then
    return nil
  end

  local dedicatedBytes = (type(mem.dedicatedBytes) == "number" and mem.dedicatedBytes > 0) and mem.dedicatedBytes or nil
  local budgetBytes = (type(mem.budgetBytes) == "number" and mem.budgetBytes > 0) and mem.budgetBytes or nil
  local sharedBytes = (type(mem.sharedBytes) == "number" and mem.sharedBytes > 0) and mem.sharedBytes or nil
  local totalBytes = dedicatedBytes or budgetBytes or sharedBytes
  local availBytes = (type(mem.availableBytes) == "number" and mem.availableBytes >= 0) and mem.availableBytes or nil

  if not totalBytes or totalBytes <= 0 then
    return nil
  end

  local vmaUsageBytes = nil
  if type(mem.usageBytes) == "number" and mem.usageBytes > 0 then
    vmaUsageBytes = mem.usageBytes
  elseif budgetBytes and availBytes then
    -- C++ GFXVkDevice::getMemoryInfo sets availableBytes = max(0, budgetBytes - usageBytes)
    vmaUsageBytes = math.max(0, budgetBytes - availBytes)
  elseif availBytes then
    vmaUsageBytes = math.max(0, totalBytes - availBytes)
  end

  if not vmaUsageBytes then
    return nil
  end

  local isDedicated = (mem.isDedicatedMemory == true) or (mem.isDedicatedMemory == nil and dedicatedBytes ~= nil)
  if isDedicated and (forceSwapRefresh or state.cachedSwap == nil or state.swapPollTick >= config.swapCheckEveryNTicks) then
    local freshSwap = readNonLocalSwap(dedicatedBytes)
    if freshSwap then
      state.cachedSwap = freshSwap
      state.swapPollTick = 0
    end
  end

  local swapInfo = isDedicated and state.cachedSwap or nil
  local swapUsedBytes = swapInfo and swapInfo.swapUsedBytes or nil
  local swapUsedMB = swapInfo and swapInfo.swapUsedMB or nil
  local swapBudgetBytes = swapInfo and swapInfo.swapBudgetBytes or nil
  local swapBudgetMB = swapInfo and swapInfo.swapBudgetMB or nil
  local hasSwapInfo = (swapUsedMB ~= nil)

  local hasExactBudget = (budgetBytes ~= nil)
  local vmaBudgetBytes = budgetBytes or totalBytes
  local usedMB = vmaUsageBytes / BYTES_PER_MB
  local vmaBudgetMB = vmaBudgetBytes / BYTES_PER_MB
  local totalMB = totalBytes / BYTES_PER_MB
  local vmaBudgetRatio = (vmaBudgetBytes > 0) and (vmaUsageBytes / vmaBudgetBytes) or 0
  local physicalFreeBytes = math.max(0, totalBytes - vmaUsageBytes)
  local physicalUsedRatio = (totalBytes > 0) and (vmaUsageBytes / totalBytes) or vmaBudgetRatio
  local budgetFreeGB = (availBytes or math.max(0, vmaBudgetBytes - vmaUsageBytes)) / BYTES_PER_GB

  return {
    raw = mem,
    isDedicated = isDedicated,
    hasExactBudget = hasExactBudget,
    usedBytes = vmaUsageBytes,
    usedMB = usedMB,
    budgetBytes = vmaBudgetBytes,
    budgetMB = vmaBudgetMB,
    vmaBudgetRatio = vmaBudgetRatio,
    totalBytes = totalBytes,
    totalMB = totalMB,
    usedRatio = physicalUsedRatio,
    availableBytes = physicalFreeBytes,
    availableGB = physicalFreeBytes / BYTES_PER_GB,
    budgetFreeGB = budgetFreeGB,
    hasSwapInfo = hasSwapInfo,
    swapUsedBytes = swapUsedBytes,
    swapUsedMB = swapUsedMB,
    swapBudgetBytes = swapBudgetBytes,
    swapBudgetMB = swapBudgetMB,
  }
end

local function formatMemSummary(mem)
  if not mem then return "unavailable" end
  local base = string.format(
    "VMA %.0f / %.0f MB (%.1f%% budget) | Physical VRAM %.0f / %.0f MB (%.1f%%, free %.2f GiB)",
    mem.usedMB, mem.budgetMB, mem.vmaBudgetRatio * 100,
    mem.usedMB, mem.totalMB, mem.usedRatio * 100, mem.availableGB
  )
  if mem.hasSwapInfo then
    if mem.swapBudgetMB and mem.swapBudgetMB > 0 then
      return string.format("%s | SWAP %.0f / %.0f MB", base, mem.swapUsedMB, mem.swapBudgetMB)
    end
    return string.format("%s | SWAP %.0f MB", base, mem.swapUsedMB)
  end
  return base
end

local function isSafeToFlush()
  if not state.isVulkan then return false end
  if isLoadingInProgress() then
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

local function startFlushBurst(reason, mem, maxTaps)
  local safe = isSafeToFlush()
  if not safe then return false end

  local resolvedMaxTaps = maxTaps
  if resolvedMaxTaps == nil then
    if mem and ((mem.hasExactBudget and mem.vmaBudgetRatio >= 0.852)
      or (mem.isDedicated and mem.hasSwapInfo and mem.swapUsedMB >= config.activeSwapHardMB)) then
      resolvedMaxTaps = 1
    else
      resolvedMaxTaps = config.maxBurstTaps
    end
  end

  state.burstActive = true
  state.burstTapsDone = 0
  state.burstMaxTaps = resolvedMaxTaps
  state.burstStepTimer = 0
  state.verifyPending = false
  state.verifyTimer = 0
  state.burstPreUsedMB = mem and mem.usedMB or 0
  state.burstPreSwapMB = (mem and mem.hasSwapInfo and mem.swapUsedMB) or 0
  state.lastFlushReason = reason or "threshold"

  log("I", logTag, string.format(
    "Triggering Vulkan pool flush (%s): %s",
    state.lastFlushReason,
    formatMemSummary(mem)
  ))
  return true
end

local function recordEffectiveFlush(curMem, tapCount, isDelayed)
  local vramDelta = curMem and (state.burstPreUsedMB - curMem.usedMB) or 0
  local swapDelta = (curMem and curMem.hasSwapInfo) and (state.burstPreSwapMB - curMem.swapUsedMB) or 0
  local vramGain = math.max(0, vramDelta)
  local swapGain = math.max(0, swapDelta)

  state.flushCount = state.flushCount + 1
  state.totalReclaimedMB = state.totalReclaimedMB + vramGain
  state.totalSwapReclaimedMB = state.totalSwapReclaimedMB + swapGain
  state.lastReclaimedMB = vramDelta
  state.lastSwapReclaimedMB = swapDelta
  state.currentBackoff = config.backoffCooldownSec
  state.cooldownTimer = config.normalCooldownSec

  local prefix = isDelayed
    and "Vulkan pool flush reclaimed"
    or string.format("Vulkan pool flush succeeded after %d tap(s): reclaimed", tapCount)

  if curMem and curMem.hasSwapInfo then
    log("I", logTag, string.format(
      "%s %.0f MB VRAM, %.0f MB SWAP (now %s)",
      prefix, vramDelta, swapDelta, formatMemSummary(curMem)
    ))
  else
    log("I", logTag, string.format(
      "%s %.0f MB VRAM (now %s)",
      prefix, vramDelta, formatMemSummary(curMem)
    ))
  end
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
      local curMem = readGpuMemory(true)
      if curMem then
        local vramDelta = state.burstPreUsedMB - curMem.usedMB
        local effective = (vramDelta >= config.minReclaimedMB)
        if effective then
          state.burstActive = false
          recordEffectiveFlush(curMem, state.burstTapsDone, false)
          return true
        end
      end
    end

    if state.burstTapsDone >= state.burstMaxTaps then
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

    local curMem = readGpuMemory(true)
    local vramDelta = curMem and (state.burstPreUsedMB - curMem.usedMB) or 0
    local swapDelta = (curMem and curMem.hasSwapInfo) and (state.burstPreSwapMB - curMem.swapUsedMB) or 0
    local effective = (vramDelta >= config.minReclaimedMB)

    if effective then
      recordEffectiveFlush(curMem, state.burstTapsDone, true)
    else
      state.lastReclaimedMB = vramDelta
      state.lastSwapReclaimedMB = swapDelta
      state.cooldownTimer = state.currentBackoff
      state.currentBackoff = math.min(config.maxBackoffSec, state.currentBackoff * 1.5)

      log("I", logTag, string.format(
        "Vulkan pool flush reclaimed only %.0f MB VRAM / %.0f MB SWAP (now %s); backing off for %.0fs",
        vramDelta, swapDelta, formatMemSummary(curMem), state.cooldownTimer
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

  state.swapPollTick = state.swapPollTick + 1
  local mem = readGpuMemory(not state.loggedFirstSample)
  if not mem then return end

  if not state.loggedFirstSample then
    state.loggedFirstSample = true
    local swapStr = mem.hasSwapInfo
      and string.format(", SWAP=%.0f/%.0f MB, nonLocalUsage=%s, nonLocalBudget=%s",
        mem.swapUsedMB, mem.swapBudgetMB or 0,
        tostring(mem.swapUsedBytes), tostring(mem.swapBudgetBytes))
      or ""
    log("I", logTag, string.format(
      "First GPU memory sample: VMA=%.0f/%.0f MB (%.1f%% budget), Physical=%.0f/%.0f MB (%.1f%%, free %.2f GiB)%s, dedicated=%s, budget=%s, usage=%s, available=%s",
      mem.usedMB, mem.budgetMB, mem.vmaBudgetRatio * 100,
      mem.usedMB, mem.totalMB, mem.usedRatio * 100, mem.availableGB,
      swapStr,
      tostring(mem.raw.dedicatedBytes), tostring(mem.raw.budgetBytes),
      tostring(mem.raw.usageBytes), tostring(mem.raw.availableBytes)
    ))
  end

  local isPaused = simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() or false
  if isPaused then
    local pauseRatio = mem.hasExactBudget and mem.vmaBudgetRatio or mem.usedRatio
    if pauseRatio >= config.pauseVmaBudgetRatio then
      startFlushBurst("paused_opportunistic", mem)
    end
    return
  end

  -- 1. Standard VMA >= 85.2% (guaranteed 1-tap flush via C++ checkVmaHeapBudgets @ 0x140F0EF05)
  if mem.hasExactBudget and (mem.vmaBudgetRatio >= config.activeVmaBudgetRatio
    or (mem.availableGB <= config.activeMinPhysicalFreeGB and mem.vmaBudgetRatio >= 0.85)) then
    startFlushBurst("vram_pressure", mem, 1)
  -- 2. Swap-Assisted VMA >= 78% when SWAP >= 1 GiB (guaranteed 1-tap flush @ 0x140F0EEA3; never flushes when VRAM < 78%)
  elseif mem.isDedicated and mem.hasExactBudget and mem.hasSwapInfo
    and mem.swapUsedMB >= config.activeSwapHardMB
    and mem.vmaBudgetRatio >= config.activeSwapAssistedVmaRatio then
    startFlushBurst("swap_assisted_vram_pressure", mem, 1)
  -- 3. Fallback when budgetBytes is unavailable
  elseif not mem.hasExactBudget
    and (mem.usedRatio >= config.activeFallbackUsedRatio or mem.availableGB <= config.activeMinPhysicalFreeGB) then
    startFlushBurst("vram_pressure", mem)
  end
end

local function onSettingsChanged()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.currentBackoff = config.backoffCooldownSec
  state.cachedSwap = nil
  state.cooldownTimer = 5.0
end

local function onClientStartMission()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.loggedFirstSample = false
  state.currentBackoff = config.backoffCooldownSec
  state.cachedSwap = nil
  state.cooldownTimer = 15.0
end

local function onExtensionLoaded()
  if setExtensionUnloadMode then
    pcall(setExtensionUnloadMode, M, "manual")
  end
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  log("I", logTag, string.format(
    "Loaded v%s (backend=%s, transientPoolBudgetMB=%d, autoFlush=%s, activeVmaThreshold=%.1f%%, swapAssistedVma=%.1f%%, swapHard=%.0fMB, pauseVmaThreshold=%.1f%%, minPhysicalFree=%.2fGiB, cooldown=%.0fs)",
    config.version,
    state.isVulkan and "Vulkan" or "non-Vulkan",
    config.transientPoolBudgetMB,
    tostring(config.autoFlush),
    config.activeVmaBudgetRatio * 100,
    config.activeSwapAssistedVmaRatio * 100,
    config.activeSwapHardMB,
    config.pauseVmaBudgetRatio * 100,
    config.activeMinPhysicalFreeGB,
    config.normalCooldownSec
  ))
end

local function status()
  local mem = readGpuMemory(true)
  local curBudget = VariableRegistry and VariableRegistry.get and VariableRegistry.get("$gfx::transientPoolBudgetMB")
  local texStr = ""
  if Engine and Engine.Render and Engine.Render.getTextureStreamingStats then
    local ok, ts = pcall(Engine.Render.getTextureStreamingStats)
    if ok and type(ts) == "table" and ts.available then
      texStr = string.format(
        " | texStream(ratio=%.1f%%, pending=%s, inPaused=%s, outReq=%s)",
        (tonumber(ts.budgetUsageRatio) or 0) * 100,
        tostring(ts.pendingRequests),
        tostring(ts.streamInPaused),
        tostring(ts.streamOutRequested)
      )
    end
  end
  local info = string.format(
    "[vulkanVramFix v%s] vulkan=%s autoFlush=%s transientBudget=%sMB flushes=%d reclaimedVRAM=%.0fMB reclaimedSWAP=%.0fMB last=%.0f/%.0fMB(%s) | %s%s",
    config.version,
    tostring(state.isVulkan),
    tostring(config.autoFlush),
    tostring(curBudget),
    state.flushCount,
    state.totalReclaimedMB,
    state.totalSwapReclaimedMB,
    state.lastReclaimedMB,
    state.lastSwapReclaimedMB,
    state.lastFlushReason,
    formatMemSummary(mem),
    texStr
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
  return startFlushBurst("manual_console", readGpuMemory(true))
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
