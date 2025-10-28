local M = {}

local activeSpeedLimit = nil
local limitActive = false
local applyingLimit = false
local lastThrottleState = 0
local forcingStop = false
local limiterMode = "cruise"

-- Function to get throttle input from vehicle
local function requestThrottleInput()
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  veh:queueLuaCommand([[
    local throttleInput = input.lastInputs["local"].throttle or 0
    obj:queueGameEngineLua('gameplay_events_freeroam_pits.receiveThrottleInput(' .. throttleInput .. ')')
  ]])
end

-- Function to receive throttle input from vehicle
local function receiveThrottleInput(value)
  lastThrottleState = value
end

local function applySpeedLimit(dt)
  if not activeSpeedLimit or not limitActive then return end
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  local vel = veh:getVelocity():length()
  if forcingStop then
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', 0.85, 1, nil, nil, nil, 'code')")
    if vel < 1.0 then
      forcingStop = false
      applyingLimit = false
      if not career_career then
        veh:queueLuaCommand([[ recovery.startRecovering() recovery.stopRecovering() ]])
      end
      veh:queueLuaCommand([[ input.event('brake', 0.5, 1) input.event('throttle', 0.5, 1) input.event('brake', 0, 1) input.event('throttle', 0, 1) ]])
    end
    return
  end
  requestThrottleInput()
  local wasLimiting = applyingLimit
  local speedRatio = 1.0 - (vel / activeSpeedLimit)
  if vel >= activeSpeedLimit then
    local overSpeed = vel - activeSpeedLimit
    local brakeAmount = math.min(1.0, overSpeed * 0.5)
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', " .. brakeAmount .. ", 1, nil, nil, nil, 'code')")
    applyingLimit = true
  else
    if lastThrottleState > 0.01 then
      local underSpeed = activeSpeedLimit - vel
      local proximityFactor = math.min(1.0, speedRatio * 2.0)
      local throttleAmount
      if speedRatio < 0.05 then
        throttleAmount = math.min(lastThrottleState, 0.20)
      elseif speedRatio < 0.15 then
        throttleAmount = math.min(lastThrottleState, lastThrottleState * proximityFactor + 0.1 * underSpeed)
      else
        throttleAmount = math.min(1.0, lastThrottleState + (underSpeed * 0.1 * proximityFactor))
      end
      veh:queueLuaCommand("input.event('throttle', " .. throttleAmount .. ", 1, nil, nil, nil, 'code')")
      veh:queueLuaCommand("input.event('brake', 0, 1)")
      applyingLimit = true
    else
      if wasLimiting then
        applyingLimit = false
      end
    end
  end
end

local function applyGovernorLimit(dt)
  if not activeSpeedLimit or not limitActive then return end
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  local vel = veh:getVelocity():length()
  if forcingStop then
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', 0.85, 1, nil, nil, nil, 'code')")
    if vel < 1.0 then
      forcingStop = false
      applyingLimit = false
      if not career_career then
        veh:queueLuaCommand([[ recovery.startRecovering() recovery.stopRecovering() ]])
      end
      veh:queueLuaCommand([[ input.event('brake', 0.5, 1) input.event('throttle', 0.5, 1) input.event('brake', 0, 1) input.event('throttle', 0, 1) ]])
    end
    return
  end
  requestThrottleInput()
  local maxAllowedThrottle = 1.0
  local governorStartSpeed = activeSpeedLimit * 0.9
  if vel > governorStartSpeed then
    local progress = (vel - governorStartSpeed) / (activeSpeedLimit - governorStartSpeed)
    progress = math.max(0, math.min(1, progress))
    maxAllowedThrottle = 1.0 - progress
  end
  local finalThrottle = math.min(lastThrottleState, maxAllowedThrottle)
  veh:queueLuaCommand("input.event('throttle', " .. finalThrottle .. ", 1, nil, nil, nil, 'code')")
end

local function onUpdate(dt)
  if activeSpeedLimit and limitActive then
    if limiterMode == "governor" then
      applyGovernorLimit(dt)
    else -- Default to cruise control
      applySpeedLimit(dt)
    end
  end
end

local function _baseSetLimit(limit, unit)
  if type(limit) ~= "number" or limit <= 0 then
    activeSpeedLimit, limitActive, applyingLimit, forcingStop = nil, false, false, false
    return false
  end
  local limitInMPS = limit
  if unit then
    unit = string.upper(unit)
    if unit == "MPH" then limitInMPS = limit * 0.44704 end
    if unit == "KPH" then limitInMPS = limit * 0.27778 end
  end
  activeSpeedLimit = limitInMPS
  limitActive = true
  return true
end

-- Original functions now set the mode to "cruise"
local function setSpeedLimit(limit, unit)
  if _baseSetLimit(limit, unit) then
    limiterMode = "cruise"
    log('I', 'pits', 'Cruise Control speed limit set.')
  end
end

local function stopThenLimit(limit, unit)
  if setSpeedLimit(limit, unit) then
    forcingStop = true
    log('I', 'pits', 'Stopping vehicle before applying cruise control limit...')
  end
end

-- New functions to set the mode to "governor"
local function setGovernorLimit(limit, unit)
  if _baseSetLimit(limit, unit) then
    limiterMode = "governor"
    log('I', 'pits', 'Throttle Governor speed limit set.')
  end
end

local function stopThenGovernor(limit, unit)
  if setGovernorLimit(limit, unit) then
    forcingStop = true
    log('I', 'pits', 'Stopping vehicle before applying governor limit...')
  end
end

-- Other public functions
local function toggleSpeedLimit()
  limitActive = not limitActive
  if not limitActive then
    be:getPlayerVehicle(0):queueLuaCommand([[ input.event('throttle', 1, 1) input.event('brake', 0, 1) ]])
    forcingStop = false
  end
  return limitActive
end

local function clearSpeedLimit()
  activeSpeedLimit, limitActive, applyingLimit, forcingStop, limiterMode = nil, false, false, false, "cruise"
end

-- Register this module to receive updates
M.onUpdate = onUpdate
M.receiveThrottleInput = receiveThrottleInput
M.clearSpeedLimit = clearSpeedLimit
M.toggleSpeedLimit = toggleSpeedLimit

-- Expose both sets of functions
M.setSpeedLimit = setSpeedLimit
M.stopThenLimit = stopThenLimit
M.setGovernorLimit = setGovernorLimit
M.stopThenGovernor = stopThenGovernor

return M