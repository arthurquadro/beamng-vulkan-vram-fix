-- BeamNG.drive Vulkan VRAM Leak Fix (vulkanVramFix v1.2.0)
-- Non-destructive user-folder extension (does not alter original game files or user graphics settings).
-- Works on AMD, NVIDIA, and Intel GPUs under Vulkan; stays inactive on DirectX 11 / DirectX 12.
--
-- Extension name: vulkanVramFix (no underscores -> maps directly to lua/ge/extensions/vulkanVramFix.lua)
--
-- Root Causes Addressed (BeamNG.drive v0.40.6.0):
--   1. $gfx::transientPoolBudgetMB defaults to 1536 MB (0x600), hoarding priority-1.0f transient
--      render targets that crowd out priority-0.75f map geometry & textures under WDDM paging.
--   2. GFXVkDevice::endScene never trims retired 16 MB staging slabs ("Buffer volatile cpu",
--      allocated in non-local SWAP) or per-bucket dynamic VRAM slabs until GFXVkDevice::waitIdle() runs.
--   3. GFXVkDevice::vtable[+0x108] (0x140F10260), BeamNG's built-in VMA heap pressure flusher
--      (checkVmaHeapBudgets(0.85f) @ 0x140F0ED80 -> waitIdle() @ 0x140F1A710), is only called from
--      GuiCanvas::repaintUIThrottled() during loading screens in vanilla Lua.
--   4. v1.1.0 VMA Budget Alignment: GFXVkDevice::getMemoryInfo (0x140EFBA40) reports availableBytes
--      relative to VMA budgetBytes (budgetBytes - usageBytes), not dedicatedBytes. Triggering on
--      usageBytes / budgetBytes >= 0.852 guarantees C++ checkVmaHeapBudgets(0.85f) fires on Tap #1.
--   5. v1.2.0 Anti-SWAP / Non-Local Spillover Protection: Engine.Render.getMemoryInfo() completely ignores
--      non-device-local heaps (SWAP / Shared GPU Memory in system RAM), whereas
--      Engine.Platform.getGPUAdaptersInfo() (0x140EFA680 -> 0x140EF7C90) exposes nonLocalUsageBytes.
--      C++ checkVmaHeapBudgets also triggers on Tap #1 whenever nonLocalUsageBytes >= 1 GiB (0x140F0EEA3).
--      Monitoring SWAP directly + flushing early on WDDM budget contraction, SWAP growth, post-load,
--      and post-settings changes stops static map assets from slipping irreversibly into slow PCIe RAM.

local M = {}

local logTag = "vulkanVramFix"
local BYTES_PER_MB = 1024 * 1024
local BYTES_PER_GB = 1024 * 1024 * 1024

local config = {
  version = "1.2.0",
  enabled = true,
  autoFlush = true,
  transientPoolBudgetMB = 256,       -- Vanilla default is 1536 MB (v1.1.0 was 384 MB)
  checkIntervalSec = 1.0,            -- Poll VRAM once per second
  swapCheckEveryNTicks = 2,          -- Poll Engine.Platform.getGPUAdaptersInfo() every 2s & around flushes
  activeVmaBudgetRatio = 0.852,      -- Aligns just above C++ checkVmaHeapBudgets(0.85f) for 1-tap flush
  activeContractedVmaRatio = 0.78,   -- Early flush when WDDM contracts budget < 87% of physical VRAM
  activeCombinedPressureRatio = 0.86,-- Early flush when (VRAM + SWAP) / VMA budget >= 86% & SWAP grows
  activeFallbackUsedRatio = 0.78,    -- Fallback ratio only when budgetBytes is unavailable
  activeMinPhysicalFreeGB = 1.60,    -- Physical VRAM safety floor in GiB
  activeSwapHardMB = 1032,           -- Just above C++ 1 GiB (1024 MB) threshold -> 1-tap flush
  activeSwapGrowthTriggerMB = 640,   -- Proactive flush before SWAP reaches 1 GiB eviction zone
  activeSwapMinGrowthMB = 160,       -- Required SWAP growth above irreducible floor to re-trigger
  pauseVmaBudgetRatio = 0.64,        -- Opportunistic flush while paused in menus
  pauseSwapTriggerMB = 512,          -- Opportunistic SWAP purge while paused
  pauseSwapMinGrowthMB = 128,
  postMissionSwapFlushMB = 512,      -- Purge leftover map/traffic upload staging slabs after load
  postMissionDelaySec = 10.0,
  postSettingsDelaySec = 2.0,        -- Purge old priority-1.0f render targets after graphics changes
  minReclaimedMB = 192,              -- Minimum VRAM drop to consider a flush effective
  minSwapReclaimedMB = 128,          -- Minimum SWAP drop to consider a flush effective
  normalCooldownSec = 6.0,           -- Cooldown after an effective flush
  backoffCooldownSec = 25.0,         -- Cooldown if VRAM is genuinely filled by static scene assets
  maxBackoffSec = 90.0,
  swapBackoffSec = 30.0,             -- Cooldown if remaining SWAP is pinned/bound in Heap 2
  maxSwapBackoffSec = 120.0,
  burstStepSec = 0.05,               -- Must exceed repaintUIThrottled's 1/30s (0.0333s) throttle
  maxBurstTaps = 5,                  -- Forces C++ checkVmaHeapBudgets 5-call bypass below 0.85 ratio
  verifyDelaySec = 0.25,             -- Wait before measuring post-flush VRAM/SWAP drop
}

local state = {
  isVulkan = false,
  loggedFirstSample = false,
  checkTimer = 0,
  cooldownTimer = 0,
  currentBackoff = config.backoffCooldownSec,
  swapPollTick = 0,
  cachedSwap = nil,
  swapFloorMB = 0,
  swapBackoffTimer = 0,
  currentSwapBackoff = config.swapBackoffSec,
  burstActive = false,
  burstTapsDone = 0,
  burstStepTimer = 0,
  burstPreUsedMB = 0,
  burstPreSwapMB = 0,
  verifyPending = false,
  verifyTimer = 0,
  postMissionFlushTimer = 0,
  postMissionFlushPending = false,
  postSettingsFlushTimer = 0,
  postSettingsFlushPending = false,
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

  if hasSwapInfo and state.swapFloorMB > 0 and swapUsedMB < state.swapFloorMB then
    state.swapFloorMB = swapUsedMB
  end

  local hasExactBudget = (budgetBytes ~= nil)
  local vmaBudgetBytes = budgetBytes or totalBytes
  local usedMB = vmaUsageBytes / BYTES_PER_MB
  local vmaBudgetMB = vmaBudgetBytes / BYTES_PER_MB
  local totalMB = totalBytes / BYTES_PER_MB
  local vmaBudgetRatio = (vmaBudgetBytes > 0) and (vmaUsageBytes / vmaBudgetBytes) or 0
  local physicalFreeBytes = math.max(0, totalBytes - vmaUsageBytes)
  local physicalUsedRatio = (totalBytes > 0) and (vmaUsageBytes / totalBytes) or vmaBudgetRatio
  local budgetFreeGB = (availBytes or math.max(0, vmaBudgetBytes - vmaUsageBytes)) / BYTES_PER_GB

  local combinedUsedMB = usedMB + (swapUsedMB or 0)
  local combinedBudgetRatio = (vmaBudgetMB > 0) and (combinedUsedMB / vmaBudgetMB) or vmaBudgetRatio
  local wddmContracted = (hasExactBudget and totalMB > 0) and (vmaBudgetMB < totalMB * 0.87) or false

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
    combinedUsedMB = combinedUsedMB,
    combinedBudgetRatio = combinedBudgetRatio,
    wddmContracted = wddmContracted,
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

local function isSwapOrWddmReason(reason)
  if type(reason) ~= "string" then return false end
  return string.sub(reason, 1, 5) == "swap_"
    or string.sub(reason, 1, 5) == "wddm_"
    or string.sub(reason, 1, 11) == "paused_swap"
    or string.sub(reason, 1, 5) == "post_"
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

local function startFlushBurst(reason, mem)
  local safe = isSafeToFlush()
  if not safe then return false end

  state.burstActive = true
  state.burstTapsDone = 0
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

  if curMem and curMem.hasSwapInfo then
    if isSwapOrWddmReason(state.lastFlushReason) then
      state.swapFloorMB = curMem.swapUsedMB
      if swapDelta < config.minSwapReclaimedMB then
        state.swapBackoffTimer = state.currentSwapBackoff
        state.currentSwapBackoff = math.min(config.maxSwapBackoffSec, state.currentSwapBackoff * 1.5)
      else
        state.swapBackoffTimer = 0
        state.currentSwapBackoff = config.swapBackoffSec
      end
    else
      if swapDelta >= config.minSwapReclaimedMB then
        state.swapBackoffTimer = 0
        state.currentSwapBackoff = config.swapBackoffSec
      end
      if state.swapFloorMB <= 0 or curMem.swapUsedMB < state.swapFloorMB then
        state.swapFloorMB = curMem.swapUsedMB
      end
    end
  end

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
        local swapDelta = curMem.hasSwapInfo and (state.burstPreSwapMB - curMem.swapUsedMB) or 0
        local effective = (vramDelta >= config.minReclaimedMB)
          or (swapDelta >= config.minSwapReclaimedMB)
          or ((vramDelta + swapDelta) >= config.minReclaimedMB)
        if effective then
          state.burstActive = false
          recordEffectiveFlush(curMem, state.burstTapsDone, false)
          return true
        end
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

    local curMem = readGpuMemory(true)
    local vramDelta = curMem and (state.burstPreUsedMB - curMem.usedMB) or 0
    local swapDelta = (curMem and curMem.hasSwapInfo) and (state.burstPreSwapMB - curMem.swapUsedMB) or 0
    local effective = (vramDelta >= config.minReclaimedMB)
      or (swapDelta >= config.minSwapReclaimedMB)
      or ((vramDelta + swapDelta) >= config.minReclaimedMB)

    if effective then
      recordEffectiveFlush(curMem, state.burstTapsDone, true)
    else
      state.lastReclaimedMB = vramDelta
      state.lastSwapReclaimedMB = swapDelta
      state.cooldownTimer = state.currentBackoff
      state.currentBackoff = math.min(config.maxBackoffSec, state.currentBackoff * 1.5)

      if isSwapOrWddmReason(state.lastFlushReason) then
        if curMem and curMem.hasSwapInfo then
          state.swapFloorMB = curMem.swapUsedMB
        end
        state.swapBackoffTimer = state.currentSwapBackoff
        state.currentSwapBackoff = math.min(config.maxSwapBackoffSec, state.currentSwapBackoff * 1.5)
      end

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

  if state.swapBackoffTimer > 0 then
    state.swapBackoffTimer = math.max(0, state.swapBackoffTimer - dt)
  end

  local loadingNow = isLoadingInProgress()

  if state.postSettingsFlushPending and not loadingNow then
    state.postSettingsFlushTimer = state.postSettingsFlushTimer - dt
    if state.postSettingsFlushTimer <= 0 and isSafeToFlush() then
      state.postSettingsFlushPending = false
      if config.autoFlush then
        local mem = readGpuMemory(true)
        if mem and (mem.vmaBudgetRatio >= 0.55 or (mem.hasSwapInfo and mem.swapUsedMB >= 384)) then
          if startFlushBurst("post_settings_cleanup", mem) then
            return
          end
        end
      end
    end
  end

  if state.postMissionFlushPending and not loadingNow then
    state.postMissionFlushTimer = state.postMissionFlushTimer - dt
    if state.postMissionFlushTimer <= 0 and isSafeToFlush() then
      state.postMissionFlushPending = false
      local mem = readGpuMemory(true)
      if mem and mem.hasSwapInfo then
        if state.swapFloorMB <= 0 then
          state.swapFloorMB = math.min(mem.swapUsedMB, 256)
        end
        if config.autoFlush and state.swapBackoffTimer <= 0 and mem.swapUsedMB >= config.postMissionSwapFlushMB then
          if startFlushBurst("post_mission_swap_cleanup", mem) then
            return
          end
        end
      end
    end
  end

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
    elseif mem.isDedicated and mem.hasSwapInfo and state.swapBackoffTimer <= 0
      and mem.swapUsedMB >= config.pauseSwapTriggerMB
      and (mem.swapUsedMB - state.swapFloorMB) >= config.pauseSwapMinGrowthMB then
      startFlushBurst("paused_swap_cleanup", mem)
    end
    return
  end

  local swapGrowth = mem.hasSwapInfo and (mem.swapUsedMB - state.swapFloorMB) or 0

  -- 1. Hard SWAP >= 1 GiB (guaranteed 1-tap flush via C++ checkVmaHeapBudgets @ 0x140F0EEA3)
  if mem.isDedicated and mem.hasSwapInfo and state.swapBackoffTimer <= 0
    and mem.swapUsedMB >= config.activeSwapHardMB
    and (state.swapFloorMB < config.activeSwapHardMB or swapGrowth >= config.activeSwapMinGrowthMB) then
    startFlushBurst("swap_pressure", mem)
  -- 2. Standard VMA >= 85.2% (guaranteed 1-tap flush via C++ checkVmaHeapBudgets @ 0x140F0EF05)
  elseif mem.hasExactBudget and (mem.vmaBudgetRatio >= config.activeVmaBudgetRatio
    or (mem.availableGB <= config.activeMinPhysicalFreeGB and mem.vmaBudgetRatio >= 0.85)) then
    startFlushBurst("vram_pressure", mem)
  -- 3. WDDM Budget Contraction Guard (stops VidMm from paging priority-0.75f map assets into SWAP)
  elseif mem.isDedicated and mem.wddmContracted
    and mem.vmaBudgetRatio >= config.activeContractedVmaRatio
    and (not mem.hasSwapInfo or state.swapBackoffTimer <= 0) then
    startFlushBurst("wddm_budget_contraction", mem)
  -- 4. Proactive SWAP Growth / Combined Pressure Guard (purges staging/volatile chunks before 1 GiB)
  elseif mem.isDedicated and mem.hasSwapInfo and state.swapBackoffTimer <= 0
    and swapGrowth >= config.activeSwapMinGrowthMB
    and (mem.swapUsedMB >= config.activeSwapGrowthTriggerMB
      or (mem.combinedBudgetRatio >= config.activeCombinedPressureRatio and mem.vmaBudgetRatio >= 0.70)) then
    startFlushBurst("swap_growth_preventive", mem)
  -- 5. Fallback when budgetBytes is unavailable
  elseif not mem.hasExactBudget
    and (mem.usedRatio >= config.activeFallbackUsedRatio or mem.availableGB <= config.activeMinPhysicalFreeGB) then
    startFlushBurst("vram_pressure", mem)
  end
end

local function onSettingsChanged()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.currentBackoff = config.backoffCooldownSec
  state.currentSwapBackoff = config.swapBackoffSec
  state.swapBackoffTimer = 0
  state.swapFloorMB = 0
  state.cachedSwap = nil
  state.postSettingsFlushPending = true
  state.postSettingsFlushTimer = config.postSettingsDelaySec
  state.cooldownTimer = 1.5
end

local function onClientStartMission()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.loggedFirstSample = false
  state.currentBackoff = config.backoffCooldownSec
  state.currentSwapBackoff = config.swapBackoffSec
  state.swapBackoffTimer = 0
  state.swapFloorMB = 0
  state.cachedSwap = nil
  state.postMissionFlushPending = true
  state.postMissionFlushTimer = config.postMissionDelaySec
  state.cooldownTimer = 5.0
end

local function onExtensionLoaded()
  if setExtensionUnloadMode then
    pcall(setExtensionUnloadMode, M, "manual")
  end
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  log("I", logTag, string.format(
    "Loaded v%s (backend=%s, transientPoolBudgetMB=%d, autoFlush=%s, activeVmaThreshold=%.1f%%, contractedVma=%.1f%%, swapHard=%.0fMB, swapGrowth=%.0fMB, minPhysicalFree=%.2fGiB)",
    config.version,
    state.isVulkan and "Vulkan" or "non-Vulkan",
    config.transientPoolBudgetMB,
    tostring(config.autoFlush),
    config.activeVmaBudgetRatio * 100,
    config.activeContractedVmaRatio * 100,
    config.activeSwapHardMB,
    config.activeSwapGrowthTriggerMB,
    config.activeMinPhysicalFreeGB
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
    "[vulkanVramFix v%s] vulkan=%s autoFlush=%s transientBudget=%sMB flushes=%d reclaimedVRAM=%.0fMB reclaimedSWAP=%.0fMB last=%.0f/%.0fMB(%s) swapFloor=%.0fMB | %s%s",
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
    state.swapFloorMB,
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
  state.swapBackoffTimer = 0
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
