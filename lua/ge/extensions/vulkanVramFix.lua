-- BeamNG.drive Vulkan VRAM Leak Fix (vulkanVramFix v1.3.0)
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
--      allocated in non-local SWAP) or per-bucket dynamic VRAM slabs until
--      GFXVkDevice::waitIdleAndFreeResources() (0x140F1A710) runs.
--   3. GFXVkDevice::vtable[+0x108] (0x140F10260), BeamNG's built-in VMA heap pressure flusher
--      (checkVmaHeapBudgets(0.85f) @ 0x140F0ED80 -> waitIdleAndFreeResources() @ 0x140F1A710),
--      is only called from GuiCanvas::repaintUIThrottled() (0x140446360) during loading screens.
--   4. v1.1.0 VMA Budget Alignment: GFXVkDevice::getMemoryInfo (0x140EFBA40) reports availableBytes
--      relative to VMA budgetBytes (budgetBytes - usageBytes), not dedicatedBytes. Triggering on
--      usageBytes / budgetBytes >= 0.852 guarantees C++ checkVmaHeapBudgets(0.85f) fires on Tap #1.
--   5. v1.2.1 Swap-Assisted Threshold + Anti-Thrash Fix:
--      Engine.Platform.getGPUAdaptersInfo() (0x140EFA680) exposes nonLocalUsageBytes (SWAP).
--      When SWAP >= 1 GiB (1024 MB), C++ checkVmaHeapBudgets (0x140F0EEA3) permits a 1-tap flush
--      below 85% VMA, preventing the ~78%-84% VRAM plateau where WDDM spills static map geometry
--      into slow PCIe RAM, while refusing to flush at low VRAM (< 78% at speed) to prevent
--      transferAcc->queue.submit VK_ERROR_DEVICE_LOST crashes.
--   6. v1.3.0 Smooth Opportunistic Flushing & Reduced Stutter:
--      - Lazy SWAP polling: GFXVkDevice::getGPUAdaptersInfo() calls vkEnumeratePhysicalDevices on
--        every invocation, so v1.3.0 skips it completely while VMA < 68% and only queries every 4s
--        in the pressure zone.
--      - Deferred post-flush verification (0.50s & >= 12 frames) so vkEnumeratePhysicalDevices never
--        runs on the first recovery frame while VMA is rebuilding working slabs after waitIdle().
--      - 4-Tier Smooth Scheduling: hides the unavoidable waitIdleAndFreeResources() pause inside
--        invisible UI/menu windows (pause, radial menu, BigMap, non-play routes, focus regain),
--        vehicle reset/switch cuts, and stationary stops (bus stops / red lights), and uses a 20s
--        soft-deferral window (78% -> 83.5% VMA) during high-speed driving to wait for a slowdown,
--        camera cut, or menu open before forcing a flush at the hard safety ceiling.

local M = {}

local logTag = "vulkanVramFix"
local BYTES_PER_MB = 1024 * 1024
local BYTES_PER_GB = 1024 * 1024 * 1024

local config = {
  version = "1.3.0",
  enabled = true,
  autoFlush = true,
  transientPoolBudgetMB = 384,          -- Vanilla default is 1536 MB; 384 MB avoids RT churn
  checkIntervalSec = 1.0,               -- Poll fast VMA budget once per second
  swapPollMinVmaRatio = 0.68,           -- Skip heavy getGPUAdaptersInfo() while VMA < 68%
  swapCheckEveryNTicks = 4,             -- Poll SWAP at most every 4s once VMA >= 68%

  -- Tier 1: Invisible UI / Menu / Pause windows
  menuVmaBudgetRatio = 0.64,            -- Clean invisibly in pause / radial / BigMap / menus
  menuFallbackVmaRatio = 0.72,          -- Threshold if vramFloorMB is not yet calibrated
  menuMinGainMB = 550,                  -- Required MB above observed VRAM floor

  -- Tier 2: Vehicle Reset / Switch / Camera Cut windows
  eventCutVmaBudgetRatio = 0.68,        -- Clean inside player reset / vehicle switch cut
  eventCutMinGainMB = 650,
  cameraCutWindowSec = 1.25,            -- Must exceed checkIntervalSec so the next tick sees it
  uiPollIntervalSec = 0.25,             -- Check focus/menu transitions at 4 Hz (low overhead)

  -- Tier 3: Stationary / Stopped vehicle (bus stops, red lights, parked)
  stoppedSpeedMaxMS = 0.80,             -- <= ~2.9 km/h counts as stopped
  stoppedMinHoldSec = 1.0,              -- Must stay stopped >= 1s (ignores brief bumps/wheelspin)
  stoppedVmaBudgetRatio = 0.72,         -- 1-tap clean while stationary if SWAP >= 1032 MB
  stoppedMinGainMB = 800,

  -- Tier 4: Active driving soft deferral (78% -> 83.5%) and hard ceilings
  activeVmaBudgetRatio = 0.852,         -- Standard 1-tap VMA ceiling (guaranteed @ 0x140F0EF05)
  activeSwapAssistedSoftRatio = 0.78,   -- Enter soft-deferral zone when SWAP >= 1032 MB
  activeSwapAssistedHardRatio = 0.835,  -- Hard 1-tap ceiling when SWAP >= 1032 MB
  activeSwapEscalationMB = 1700,        -- Bypass soft deferral immediately if SWAP climbs >= 1700 MB
  activeSlowSpeedMaxMS = 3.5,           -- <= ~12.6 km/h counts as slowdown inside soft-deferral zone
  activeSoftDeferMaxSec = 20.0,         -- Max seconds to wait for a smooth window at 78%-83.5% VMA
  activeSwapHardMB = 1032,              -- Just above C++ 1 GiB (1024 MB) 1-tap threshold @ 0x140F0EEA3
  activeFallbackUsedRatio = 0.78,       -- Fallback ratio only when budgetBytes is unavailable
  activeMinPhysicalFreeGB = 1.60,       -- Physical VRAM safety floor in GiB

  -- Effectiveness, cooldowns & deferred verification
  minReclaimedMB = 192,                 -- Strict VRAM-only effectiveness check (MB)
  normalCooldownSec = 15.0,             -- Cooldown after an effective flush so transferAcc settles
  backoffCooldownSec = 30.0,            -- Cooldown if VRAM is genuinely filled by static scene assets
  maxBackoffSec = 90.0,
  missionGraceSec = 15.0,               -- Grace period after mission load
  settingsGraceSec = 5.0,               -- Grace period after graphics settings change
  burstStepSec = 0.05,                  -- Must exceed repaintUIThrottled's 1/30s (0.0333s) throttle
  maxBurstTaps = 5,                     -- Forces C++ checkVmaHeapBudgets 5-call bypass when needed
  verifyDelaySec = 0.50,                -- Defer post-flush getGPUAdaptersInfo() until frames recover
  verifyMinFrames = 12,                 -- Require >= 12 smooth rendered frames before verification
}

local state = {
  isVulkan = false,
  loggedFirstSample = false,
  checkTimer = 0,
  cooldownTimer = 0,
  currentBackoff = config.backoffCooldownSec,
  swapPollTick = 0,
  cachedSwap = nil,
  vramFloorMB = 0,
  wasFocused = true,
  wasInMenu = false,
  uiPollTimer = 0,
  stoppedTime = 0,
  softDeferTimer = 0,
  softDeferActive = false,
  recentCameraSwitchTimer = 0,
  burstActive = false,
  burstTapsDone = 0,
  burstMaxTaps = config.maxBurstTaps,
  burstStepTimer = 0,
  burstPreUsedMB = 0,
  burstPreSwapMB = 0,
  burstFlushMs = 0,
  verifyPending = false,
  verifyTimer = 0,
  verifyFramesLeft = 0,
  flushCount = 0,
  totalReclaimedMB = 0,
  totalSwapReclaimedMB = 0,
  lastFlushReason = "none",
  lastReclaimedMB = 0,
  lastSwapReclaimedMB = 0,
  lastFlushMs = 0,
}

local function getSystemTimeMS()
  if Engine and Engine.Platform and Engine.Platform.getSystemTimeMS then
    local ok, ms = pcall(Engine.Platform.getSystemTimeMS)
    if ok and type(ms) == "number" then
      return ms
    end
  end
  return nil
end

local function isVulkanBackend()
  if not (Engine and Engine.Render and Engine.Render.getAdapterType) then
    return false
  end
  local ok, adapter = pcall(Engine.Render.getAdapterType)
  return ok and adapter == "Vulkan"
end

local function isProgramFocused()
  if Engine and Engine.isProgramFocused then
    local ok, focused = pcall(Engine.isProgramFocused)
    if ok and focused == false then
      return false
    end
  end
  return true
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

local function isInInvisibleMenuWindow()
  if simTimeAuthority and simTimeAuthority.getPause then
    local ok, paused = pcall(simTimeAuthority.getPause)
    if ok and paused then
      return true, "paused"
    end
  end
  if core_quickAccess and core_quickAccess.isEnabled then
    local ok, open = pcall(core_quickAccess.isEnabled)
    if ok and open then
      return true, "radial_menu"
    end
  end
  if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive then
    local ok, active = pcall(freeroam_bigMapMode.bigMapActive)
    if ok and active then
      return true, "bigmap"
    end
  end
  local uiRouter = (extensions and extensions.ui_router) or ui_router
  if uiRouter and uiRouter.getCurrent then
    local ok, cur = pcall(uiRouter.getCurrent)
    if ok and type(cur) == "table" then
      local routeName = (type(cur.request) == "table" and cur.request.name)
        or (type(cur.resolved) == "table" and cur.resolved.name)
      if type(routeName) == "string" and routeName ~= "" and routeName ~= "play" then
        return true, "ui_menu"
      end
    end
  end
  return false, nil
end

local function getPlayerSpeedMS()
  local veh = nil
  if be and be.getPlayerVehicle then
    local ok, v = pcall(function() return be:getPlayerVehicle(0) end)
    if ok then veh = v end
  elseif getPlayerVehicle then
    local ok, v = pcall(getPlayerVehicle, 0)
    if ok then veh = v end
  end
  if veh and veh.getVelocity then
    local ok, vel = pcall(function() return veh:getVelocity() end)
    if ok and vel and vel.length then
      local okLen, spd = pcall(function() return vel:length() end)
      if okLen and type(spd) == "number" then
        return spd
      end
    end
  end
  return nil
end

local function getPlayerVehicleIdSafe()
  if be and be.getPlayerVehicleID then
    local ok, vid = pcall(function() return be:getPlayerVehicleID(0) end)
    if ok and type(vid) == "number" then
      return vid
    end
  end
  return nil
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

  return {
    swapUsedBytes = swapUsedBytes,
    swapUsedMB = swapUsedBytes / BYTES_PER_MB,
    swapBudgetBytes = swapBudgetBytes,
    swapBudgetMB = swapBudgetBytes and (swapBudgetBytes / BYTES_PER_MB) or nil,
  }
end

local function readGpuMemory(swapMode)
  -- swapMode: "force" = query getGPUAdaptersInfo now; "lazy" = only if VMA >= 68% & interval elapsed; "none" = skip query (use cache)
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

  local hasExactBudget = (budgetBytes ~= nil)
  local vmaBudgetBytes = budgetBytes or totalBytes
  local usedMB = vmaUsageBytes / BYTES_PER_MB
  local vmaBudgetMB = vmaBudgetBytes / BYTES_PER_MB
  local totalMB = totalBytes / BYTES_PER_MB
  local vmaBudgetRatio = (vmaBudgetBytes > 0) and (vmaUsageBytes / vmaBudgetBytes) or 0
  local physicalFreeBytes = math.max(0, totalBytes - vmaUsageBytes)
  local physicalUsedRatio = (totalBytes > 0) and (vmaUsageBytes / totalBytes) or vmaBudgetRatio
  local budgetFreeGB = (availBytes or math.max(0, vmaBudgetBytes - vmaUsageBytes)) / BYTES_PER_GB

  local isDedicated = (mem.isDedicatedMemory == true) or (mem.isDedicatedMemory == nil and dedicatedBytes ~= nil)
  if isDedicated then
    local mode = swapMode or "lazy"
    local shouldRefreshSwap = false
    if mode == "force" then
      shouldRefreshSwap = true
    elseif mode == "lazy" and vmaBudgetRatio >= config.swapPollMinVmaRatio then
      state.swapPollTick = state.swapPollTick + 1
      if state.cachedSwap == nil or state.swapPollTick >= config.swapCheckEveryNTicks then
        shouldRefreshSwap = true
      end
    end
    if shouldRefreshSwap then
      local freshSwap = readNonLocalSwap(dedicatedBytes)
      if freshSwap then
        state.cachedSwap = freshSwap
        state.swapPollTick = 0
      end
    end
  end

  local swapInfo = isDedicated and state.cachedSwap or nil
  local swapUsedBytes = swapInfo and swapInfo.swapUsedBytes or nil
  local swapUsedMB = swapInfo and swapInfo.swapUsedMB or nil
  local swapBudgetBytes = swapInfo and swapInfo.swapBudgetBytes or nil
  local swapBudgetMB = swapInfo and swapInfo.swapBudgetMB or nil
  local hasSwapInfo = (swapUsedMB ~= nil)

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

local function updateVramFloor(usedMB)
  if type(usedMB) ~= "number" or usedMB <= 0 then return end
  if state.vramFloorMB <= 0 or usedMB < state.vramFloorMB then
    state.vramFloorMB = usedMB
  end
end

local function getEstimatedReclaimableMB(mem)
  if not mem or state.vramFloorMB <= 0 then return 0 end
  return math.max(0, mem.usedMB - state.vramFloorMB)
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
  if not isProgramFocused() then
    return false
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
  state.burstFlushMs = 0
  state.verifyPending = false
  state.verifyTimer = 0
  state.verifyFramesLeft = 0
  state.softDeferTimer = 0
  state.softDeferActive = false
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

local function recordEffectiveFlush(curMem, tapCount)
  local vramDelta = curMem and (state.burstPreUsedMB - curMem.usedMB) or 0
  local swapDelta = (curMem and curMem.hasSwapInfo) and (state.burstPreSwapMB - curMem.swapUsedMB) or 0
  local vramGain = math.max(0, vramDelta)
  local swapGain = math.max(0, swapDelta)

  state.flushCount = state.flushCount + 1
  state.totalReclaimedMB = state.totalReclaimedMB + vramGain
  state.totalSwapReclaimedMB = state.totalSwapReclaimedMB + swapGain
  state.lastReclaimedMB = vramDelta
  state.lastSwapReclaimedMB = swapDelta
  state.lastFlushMs = state.burstFlushMs
  state.currentBackoff = config.backoffCooldownSec
  state.cooldownTimer = config.normalCooldownSec

  if curMem then
    updateVramFloor(curMem.usedMB)
  end

  local msStr = state.burstFlushMs > 0 and string.format(" in %.0fms", state.burstFlushMs) or ""
  if curMem and curMem.hasSwapInfo then
    log("I", logTag, string.format(
      "Vulkan pool flush succeeded after %d tap(s)%s: reclaimed %.0f MB VRAM, %.0f MB SWAP (now %s)",
      tapCount, msStr, vramDelta, swapDelta, formatMemSummary(curMem)
    ))
  else
    log("I", logTag, string.format(
      "Vulkan pool flush succeeded after %d tap(s)%s: reclaimed %.0f MB VRAM (now %s)",
      tapCount, msStr, vramDelta, formatMemSummary(curMem)
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

    -- For multi-tap bursts (> 1), do a fast VMA-only check (no getGPUAdaptersInfo) to stop early if already reclaimed
    if state.burstTapsDone > 0 and state.burstMaxTaps > 1 then
      local curMem = readGpuMemory("none")
      if curMem then
        local vramDelta = state.burstPreUsedMB - curMem.usedMB
        if vramDelta >= config.minReclaimedMB then
          state.burstActive = false
          state.verifyPending = true
          state.verifyTimer = config.verifyDelaySec
          state.verifyFramesLeft = config.verifyMinFrames
          return true
        end
      end
    end

    if state.burstTapsDone >= state.burstMaxTaps then
      state.burstActive = false
      state.verifyPending = true
      state.verifyTimer = config.verifyDelaySec
      state.verifyFramesLeft = config.verifyMinFrames
      return true
    end

    local t0 = getSystemTimeMS()
    local ok, err = pcall(function() canvas:repaintUIThrottled() end)
    local t1 = getSystemTimeMS()
    if t0 and t1 and t1 >= t0 then
      state.burstFlushMs = state.burstFlushMs + (t1 - t0)
    end

    if not ok then
      log("W", logTag, "repaintUIThrottled call failed: " .. tostring(err))
      state.burstActive = false
      state.cooldownTimer = config.backoffCooldownSec
      return true
    end

    state.burstTapsDone = state.burstTapsDone + 1
    if state.burstTapsDone >= state.burstMaxTaps then
      -- Defer verification until frames settle so vkEnumeratePhysicalDevices never runs on frame 1 post-waitIdle
      state.burstActive = false
      state.verifyPending = true
      state.verifyTimer = config.verifyDelaySec
      state.verifyFramesLeft = config.verifyMinFrames
    else
      state.burstStepTimer = config.burstStepSec
    end
    return true
  end

  if state.verifyPending then
    state.verifyTimer = state.verifyTimer - dtReal
    if state.verifyFramesLeft > 0 then
      state.verifyFramesLeft = state.verifyFramesLeft - 1
    end
    if state.verifyTimer > 0 or state.verifyFramesLeft > 0 then
      return true
    end
    state.verifyPending = false

    local curMem = readGpuMemory("force")
    local vramDelta = curMem and (state.burstPreUsedMB - curMem.usedMB) or 0
    local swapDelta = (curMem and curMem.hasSwapInfo) and (state.burstPreSwapMB - curMem.swapUsedMB) or 0
    local effective = (vramDelta >= config.minReclaimedMB)

    if effective then
      recordEffectiveFlush(curMem, state.burstTapsDone)
    else
      state.lastReclaimedMB = vramDelta
      state.lastSwapReclaimedMB = swapDelta
      state.lastFlushMs = state.burstFlushMs
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

local function tryEventCutFlush(reason)
  if not config.enabled or not config.autoFlush or not state.isVulkan then return false end
  if state.burstActive or state.verifyPending or state.cooldownTimer > 0 then return false end
  if not isSafeToFlush() then return false end

  local mem = readGpuMemory("none")
  if not mem then return false end
  local ratio = mem.hasExactBudget and mem.vmaBudgetRatio or mem.usedRatio
  local gainEst = getEstimatedReclaimableMB(mem)
  if ratio < config.eventCutVmaBudgetRatio then return false end
  if state.vramFloorMB > 0 and gainEst < config.eventCutMinGainMB and ratio < 0.78 then
    return false
  end

  -- Refresh SWAP right before starting so we know whether C++ guarantees a 1-tap flush
  local fullMem = readGpuMemory("force") or mem
  local fullRatio = fullMem.hasExactBudget and fullMem.vmaBudgetRatio or fullMem.usedRatio
  local hasOneTap = (fullMem.hasExactBudget and fullRatio >= 0.852)
    or (fullMem.isDedicated and fullMem.hasSwapInfo and fullMem.swapUsedMB >= config.activeSwapHardMB)
  if hasOneTap then
    return startFlushBurst(reason, fullMem, 1)
  end
  return false
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not config.enabled or not state.isVulkan then return end
  local dt = dtReal or dtRaw or 0.016
  if dt <= 0 or dt > 1.0 then dt = 0.016 end

  if state.recentCameraSwitchTimer > 0 then
    state.recentCameraSwitchTimer = math.max(0, state.recentCameraSwitchTimer - dt)
  end

  if stepBurst(dt) then return end

  if state.cooldownTimer > 0 then
    state.cooldownTimer = math.max(0, state.cooldownTimer - dt)
    return
  end

  -- Poll focus/menu transitions at 4 Hz so entering pause/radial/menu or regaining focus is caught fast
  state.uiPollTimer = state.uiPollTimer + dt
  if state.uiPollTimer >= config.uiPollIntervalSec then
    state.uiPollTimer = 0
    local focusedNow = isProgramFocused()
    local inMenuNow = isInInvisibleMenuWindow()
    local enteredMenu = (not state.wasInMenu and inMenuNow)
    local regainedFocusInMenu = (not state.wasFocused and focusedNow and inMenuNow)
    state.wasFocused = focusedNow
    state.wasInMenu = inMenuNow
    if enteredMenu or regainedFocusInMenu then
      state.checkTimer = config.checkIntervalSec
    end
  end

  state.checkTimer = state.checkTimer + dt
  if state.checkTimer < config.checkIntervalSec then return end
  local elapsedSinceCheck = state.checkTimer
  state.checkTimer = 0

  applyTransientBudget()

  if not config.autoFlush then return end

  local mem = readGpuMemory(state.loggedFirstSample and "lazy" or "force")
  if not mem then return end

  if not state.loggedFirstSample then
    state.loggedFirstSample = true
    if mem.vmaBudgetRatio < 0.70 then
      updateVramFloor(mem.usedMB)
    end
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

  local inMenuNow, menuTag = isInInvisibleMenuWindow()
  local ratio = mem.hasExactBudget and mem.vmaBudgetRatio or mem.usedRatio
  local gainEst = getEstimatedReclaimableMB(mem)

  -- Tier 1: Invisible UI / Menu / Pause window (clean completely out of sight!)
  if inMenuNow then
    state.stoppedTime = 0
    local menuReady = false
    if state.vramFloorMB > 0 then
      menuReady = (ratio >= config.menuVmaBudgetRatio and gainEst >= config.menuMinGainMB)
        or (ratio >= config.activeVmaBudgetRatio)
    else
      menuReady = (ratio >= config.menuFallbackVmaRatio)
    end
    if menuReady then
      -- Refresh SWAP once right before starting so we pick 1-tap if SWAP >= 1032 MB
      local fullMem = readGpuMemory("force") or mem
      startFlushBurst((menuTag or "menu") .. "_opportunistic", fullMem)
    end
    return
  end

  -- Only query player vehicle speed when VRAM is high enough to benefit from stopped/slowdown timing
  local speedMS = nil
  if ratio >= config.stoppedVmaBudgetRatio then
    speedMS = getPlayerSpeedMS()
    if speedMS ~= nil and speedMS <= config.stoppedSpeedMaxMS then
      state.stoppedTime = state.stoppedTime + elapsedSinceCheck
    else
      state.stoppedTime = 0
    end
  else
    state.stoppedTime = 0
  end

  -- Tier 3: Stationary / Stopped window (bus stop, red light, parked) -> 1-tap only!
  if state.stoppedTime >= config.stoppedMinHoldSec and ratio >= config.stoppedVmaBudgetRatio
    and (state.vramFloorMB <= 0 or gainEst >= config.stoppedMinGainMB or ratio >= config.activeSwapAssistedSoftRatio) then
    local checkMem = mem
    if checkMem.isDedicated and (not checkMem.hasSwapInfo or checkMem.swapUsedMB < config.activeSwapHardMB) and state.swapPollTick >= 2 then
      checkMem = readGpuMemory("force") or mem
    end
    local hasOneTap = (checkMem.hasExactBudget and checkMem.vmaBudgetRatio >= config.activeVmaBudgetRatio)
      or (checkMem.isDedicated and checkMem.hasSwapInfo and checkMem.swapUsedMB >= config.activeSwapHardMB)
    if hasOneTap then
      startFlushBurst("stopped_opportunistic", checkMem, 1)
      return
    end
  end

  -- Tier 4A: Standard Hard VMA Ceiling >= 85.2% (guaranteed 1-tap @ 0x140F0EF05)
  if mem.hasExactBudget and (mem.vmaBudgetRatio >= config.activeVmaBudgetRatio
    or (mem.availableGB <= config.activeMinPhysicalFreeGB and mem.vmaBudgetRatio >= 0.85)) then
    startFlushBurst("vram_pressure", mem, 1)
    return
  end

  -- Tier 4B: Swap-Assisted Zone when SWAP >= 1 GiB (guaranteed 1-tap @ 0x140F0EEA3)
  if mem.isDedicated and mem.hasExactBudget and mem.hasSwapInfo
    and mem.swapUsedMB >= config.activeSwapHardMB
    and mem.vmaBudgetRatio >= config.activeSwapAssistedSoftRatio then

    -- Hard ceiling or escalating SWAP: flush immediately
    if mem.vmaBudgetRatio >= config.activeSwapAssistedHardRatio
      or mem.swapUsedMB >= config.activeSwapEscalationMB then
      startFlushBurst("swap_assisted_vram_pressure", mem, 1)
      return
    end

    -- Soft deferral zone (78.0% .. 83.5%): wait up to 20s for a slowdown, camera cut, or menu
    state.softDeferActive = true
    local isSlow = (speedMS ~= nil and speedMS <= config.activeSlowSpeedMaxMS)
    local isCamCut = (state.recentCameraSwitchTimer > 0)
    if isSlow then
      startFlushBurst("slowdown_opportunistic", mem, 1)
      return
    elseif isCamCut then
      startFlushBurst("camera_cut_opportunistic", mem, 1)
      return
    end

    state.softDeferTimer = state.softDeferTimer + elapsedSinceCheck
    if state.softDeferTimer >= config.activeSoftDeferMaxSec then
      startFlushBurst("swap_assisted_vram_pressure", mem, 1)
    end
    return
  end

  -- Reset soft deferral state whenever VRAM drops back below 78%
  state.softDeferTimer = 0
  state.softDeferActive = false

  -- Tier 4C: Fallback when budgetBytes is unavailable
  if not mem.hasExactBudget
    and (mem.usedRatio >= config.activeFallbackUsedRatio or mem.availableGB <= config.activeMinPhysicalFreeGB) then
    startFlushBurst("vram_pressure", mem)
  end
end

local function onCameraModeChanged(camName)
  if not config.enabled or not state.isVulkan then return end
  state.recentCameraSwitchTimer = config.cameraCutWindowSec
  if state.softDeferActive then
    state.checkTimer = config.checkIntervalSec
  end
end

local function onVehicleResetted(vehicleID)
  local playerVid = getPlayerVehicleIdSafe()
  if playerVid and vehicleID == playerVid then
    tryEventCutFlush("vehicle_reset_opportunistic")
  end
end

local function onVehicleSwitched(oid, nid, player)
  if player == 0 and nid and nid ~= oid then
    tryEventCutFlush("vehicle_switch_opportunistic")
  end
end

local function onSettingsChanged()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.currentBackoff = config.backoffCooldownSec
  state.cachedSwap = nil
  state.vramFloorMB = 0
  state.softDeferTimer = 0
  state.softDeferActive = false
  state.cooldownTimer = config.settingsGraceSec
end

local function onClientStartMission()
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  state.loggedFirstSample = false
  state.currentBackoff = config.backoffCooldownSec
  state.cachedSwap = nil
  state.vramFloorMB = 0
  state.stoppedTime = 0
  state.softDeferTimer = 0
  state.softDeferActive = false
  state.recentCameraSwitchTimer = 0
  state.uiPollTimer = 0
  state.cooldownTimer = config.missionGraceSec
end

local function onExtensionLoaded()
  if setExtensionUnloadMode then
    pcall(setExtensionUnloadMode, M, "manual")
  end
  state.isVulkan = isVulkanBackend()
  applyTransientBudget()
  log("I", logTag, string.format(
    "Loaded v%s (backend=%s, transientPoolBudgetMB=%d, autoFlush=%s, menuVma=%.0f%%, stoppedVma=%.0f%%, softDeferVma=%.1f%%-%.1f%%, hardVma=%.1f%%, swapHard=%.0fMB, cooldown=%.0fs)",
    config.version,
    state.isVulkan and "Vulkan" or "non-Vulkan",
    config.transientPoolBudgetMB,
    tostring(config.autoFlush),
    config.menuVmaBudgetRatio * 100,
    config.stoppedVmaBudgetRatio * 100,
    config.activeSwapAssistedSoftRatio * 100,
    config.activeSwapAssistedHardRatio * 100,
    config.activeVmaBudgetRatio * 100,
    config.activeSwapHardMB,
    config.normalCooldownSec
  ))
end

local function status()
  local mem = readGpuMemory("force")
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
    "[vulkanVramFix v%s] vulkan=%s autoFlush=%s transientBudget=%sMB flushes=%d reclaimedVRAM=%.0fMB reclaimedSWAP=%.0fMB last=%.0f/%.0fMB(%.0fms,%s) vramFloor=%.0fMB | %s%s",
    config.version,
    tostring(state.isVulkan),
    tostring(config.autoFlush),
    tostring(curBudget),
    state.flushCount,
    state.totalReclaimedMB,
    state.totalSwapReclaimedMB,
    state.lastReclaimedMB,
    state.lastSwapReclaimedMB,
    state.lastFlushMs,
    state.lastFlushReason,
    state.vramFloorMB,
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
  return startFlushBurst("manual_console", readGpuMemory("force"))
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
M.onCameraModeChanged = onCameraModeChanged
M.onVehicleResetted = onVehicleResetted
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.status = status
M.flushNow = flushNow
M.setBudgetMB = setBudgetMB
M.setAutoFlush = setAutoFlush

return M
