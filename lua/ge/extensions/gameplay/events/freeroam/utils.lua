local M = {}

local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- Unit conversions
local SPEED_UNIT_MPS_TO_MPH = 2.2369362921

-- Reward multipliers
local NEW_BEST_BONUS = 1.2
local IN_RANGE_BONUS = 1.05
local IN_RANGE_THRESHOLD = 0.025  -- 2.5% of best time
local XP_DIVISOR = 20
local BEAM_XP_DIVISOR = 10
local MAX_REWARD_MULTIPLIER = 30

-- ============================================================================
-- STATE
-- ============================================================================

local previousTrafficAmount = nil

local leftTimeDigits = {}
local rightTimeDigits = {}
local leftSpeedDigits = {}
local rightSpeedDigits = {}

local races = {}

local checkpointSoundPath = 'art/sound/ui_checkpoint.ogg'
local playerInPursuit = false

-- ============================================================================
-- CAREER MODE HELPERS
-- ============================================================================

--- Safely check if career mode is active
-- @return boolean True if career mode is active
local function isCareerActive()
  return career_career and career_career.isActive() or false
end

--- Safely get inventory ID from vehicle ID
-- @param vehicleId number The vehicle ID
-- @return number|nil The inventory ID or nil if not available
local function getInventoryIdSafe(vehicleId)
  if not isCareerActive() then
    return nil
  end
  if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
    return nil
  end
  return career_modules_inventory.getInventoryIdFromVehicleId(vehicleId)
end

--- Safely get vehicle value for damage calculations
-- @param inventoryId number The inventory ID
-- @return number The vehicle value or default max damage
local function getVehicleValueSafe(inventoryId)
  local defaultMaxDamage = 100000
  if not isCareerActive() then
    return defaultMaxDamage
  end
  if not career_modules_valueCalculator or not career_modules_valueCalculator.getInventoryVehicleValue then
    return defaultMaxDamage
  end
  return career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true) or defaultMaxDamage
end

--- Safely check if hardcore mode is enabled
-- @return boolean True if hardcore mode is enabled
local function isHardcoreModeActive()
  if not isCareerActive() then
    return false
  end
  return career_modules_hardcore and career_modules_hardcore.isHardcoreMode() or false
end

--- Safely save career state
local function saveCareerState()
  if isCareerActive() and career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

-- ============================================================================
-- RACE TYPE HELPERS
-- ============================================================================

--- Check if ALL race types are disabled (multiplier = 0)
-- @param race table The race data
-- @return boolean True if all types are disabled
-- @return table Array of disabled type names
local function areAllTypesDisabled(race)
  if not career_economyAdjuster or not race or not race.type then
    return false, {}
  end
  
  local totalTypes = 0
  local disabledCount = 0
  local disabledTypes = {}
  
  for _, raceType in ipairs(race.type) do
    totalTypes = totalTypes + 1
    local multiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
    if multiplier == 0 then
      disabledCount = disabledCount + 1
      table.insert(disabledTypes, raceType)
    end
  end
  
  local allDisabled = totalTypes > 0 and disabledCount == totalTypes
  return allDisabled, disabledTypes
end

--- Helper function to calculate average multiplier from non-zero race types
-- @param raceTypes table Array of race type strings
-- @return number The average multiplier (1.0 if not in career or no types)
local function calculateAverageMultiplier(raceTypes)
  if not career_economyAdjuster or not raceTypes or #raceTypes == 0 then
    return 1.0
  end

  local totalMultiplier = 0
  local nonZeroCount = 0

  for _, raceType in ipairs(raceTypes) do
    local typeMultiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
    if typeMultiplier > 0 then
      totalMultiplier = totalMultiplier + typeMultiplier
      nonZeroCount = nonZeroCount + 1
    end
  end

  return nonZeroCount > 0 and (totalMultiplier / nonZeroCount) or 0
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Check if a table contains a value
-- @param tbl table The table to search
-- @param val any The value to find
-- @return boolean True if value exists in table
local function tableContains(tbl, val)
  if not tbl then return false end
  for _, v in ipairs(tbl) do
    if v == val then
      return true
    end
  end
  return false
end

--- Format time in MM:SS:CC format
-- @param seconds number Time in seconds
-- @return string Formatted time string
local function formatTime(seconds)
  local sign = seconds < 0 and "-" or ""
  seconds = math.abs(seconds)

  local minutes = math.floor(seconds / 60)
  local remainingSeconds = seconds % 60
  local wholeSeconds = math.floor(remainingSeconds)
  local hundredths = math.floor((remainingSeconds - wholeSeconds) * 100)

  return string.format("%s%02d:%02d:%02d", sign, minutes, wholeSeconds, hundredths)
end

--- Format distance in meters or kilometers
-- @param meters number Distance in meters
-- @return string Formatted distance string
local function formatDistance(meters)
  if not meters or meters < 0 then
    return "0m"
  end
  
  if meters < 1000 then
    return string.format("%dm", math.floor(meters + 0.5))
  else
    return string.format("%.2f km", meters / 1000)
  end
end

--- Get race label with alt route and hotlap suffixes
-- @param raceName string The race name
-- @param altRoute boolean|nil Whether alt route is active
-- @param hotlap boolean|nil Whether hotlap is active
-- @return string The formatted race label
local function getRaceLabel(raceName, altRoute, hotlap)
  local race = races[raceName]
  if not race then return raceName end
  
  local raceLabel = race.label

  if altRoute and race.altRoute then
    raceLabel = race.altRoute.label
  end
  if hotlap then
    raceLabel = raceLabel .. " (Hotlap)"
  end
  return raceLabel
end

-- ============================================================================
-- AUDIO
-- ============================================================================

--- Play checkpoint sound effect
local function playCheckpointSound()
  Engine.Audio.playOnce('AudioGui', checkpointSoundPath, {
    volume = 2
  })
end

-- ============================================================================
-- UI DISPLAY FUNCTIONS
-- ============================================================================

--- Display a UI message
-- @param message string The message to display
-- @param duration number Duration in seconds
-- @param category string|nil Optional category (defaults to "FRE")
-- @param icon string|nil Optional icon (defaults to "info")
local function displayMessage(message, duration, category, icon)
  category = category or "FRE"
  icon = icon or "info"
  ui_message(message, duration, category, icon)
end

--- Update drag race display digits
-- @param side string "l" for left, "r" for right
-- @param finishTime number The finish time
-- @param finishSpeed number The finish speed in mph
local function updateDisplay(side, finishTime, finishSpeed)
  local timeDisplayValue = {}
  local speedDisplayValue = {}
  local timeDigits = {}
  local speedDigits = {}

  if side == "r" then
    timeDigits = rightTimeDigits
    speedDigits = rightSpeedDigits
  elseif side == "l" then
    timeDigits = leftTimeDigits
    speedDigits = leftSpeedDigits
  end

  if finishTime < 10 then
    table.insert(timeDisplayValue, "empty")
  end

  if finishSpeed < 100 then
    table.insert(speedDisplayValue, "empty")
  end

  -- Three decimal points for time
  for num in string.gmatch(string.format("%.3f", finishTime), "%d") do
    table.insert(timeDisplayValue, num)
  end

  -- Two decimal points for speed
  for num in string.gmatch(string.format("%.2f", finishSpeed), "%d") do
    table.insert(speedDisplayValue, num)
  end

  if #timeDisplayValue > 0 and #timeDisplayValue < 6 then
    for i, v in ipairs(timeDisplayValue) do
      timeDigits[i]:preApply()
      timeDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_" .. v .. ".dae")
      timeDigits[i]:setHidden(false)
      timeDigits[i]:postApply()
    end
  end

  for i, v in ipairs(speedDisplayValue) do
    speedDigits[i]:preApply()
    speedDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_" .. v .. ".dae")
    speedDigits[i]:setHidden(false)
    speedDigits[i]:postApply()
  end
end

local function clearDisplay(digits)
  for i = 1, #digits do
    digits[i]:setHidden(true)
  end
end

local function resetDisplays()
  clearDisplay(leftTimeDigits)
  clearDisplay(rightTimeDigits)
  clearDisplay(leftSpeedDigits)
  clearDisplay(rightSpeedDigits)
end

local function initDisplays()
  if #leftTimeDigits > 0 or #rightTimeDigits > 0 or #leftSpeedDigits > 0 or #rightSpeedDigits > 0 then
    return
  end

  for i = 1, 5 do
    local leftTimeDigit = scenetree.findObject("display_time_" .. i .. "_l")
    table.insert(leftTimeDigits, leftTimeDigit)

    local rightTimeDigit = scenetree.findObject("display_time_" .. i .. "_r")
    table.insert(rightTimeDigits, rightTimeDigit)

    local rightSpeedDigit = scenetree.findObject("display_speed_" .. i .. "_r")
    table.insert(rightSpeedDigits, rightSpeedDigit)

    local leftSpeedDigit = scenetree.findObject("display_speed_" .. i .. "_l")
    table.insert(leftSpeedDigits, leftSpeedDigit)
  end
  resetDisplays()
end

--- Set the active light color for an event
-- @param event string Event name
-- @param color string "yellow", "red", or "green"
local function setActiveLight(event, color)
  local yellow = scenetree.findObject(event .. "_Yellow")
  local red = scenetree.findObject(event .. "_Red")
  local green = scenetree.findObject(event .. "_Green")
  if yellow then
    yellow:setHidden(color ~= "yellow")
  end
  if red then
    red:setHidden(color ~= "red")
  end
  if green then
    green:setHidden(color ~= "green")
  end
end

-- ============================================================================
-- TRAFFIC MANAGEMENT
-- ============================================================================

local function hasFinishTrigger(race)
  return scenetree.findObject("fre_finish_" .. race) ~= nil
end

local function saveAndSetTrafficAmount(amount)
  if gameplay_traffic then
    previousTrafficAmount = gameplay_traffic.getNumOfTraffic()
    gameplay_traffic.setActiveAmount(amount or 0)
  else
    print("Warning: gameplay_traffic not available")
  end
end

local function restoreTrafficAmount()
  if gameplay_traffic then
    local settingsAmount = settings.getValue('trafficAmount') == 0 and getMaxVehicleAmount() or
                             settings.getValue('trafficAmount')
    local trafficAmount = settingsAmount or previousTrafficAmount
    local pooledAmount = settings.getValue('trafficExtraAmount') or 0
    gameplay_traffic.setActiveAmount(trafficAmount + pooledAmount, trafficAmount)
  end
end

-- ============================================================================
-- VEHICLE HELPERS
-- ============================================================================

--- Get vehicle damage value
-- @return number The vehicle damage value
local function getVehicleDamage()
  local playerVehicleId = be:getPlayerVehicleID(0)
  return map.objects[playerVehicleId] and map.objects[playerVehicleId].damage or 0
end

-- ============================================================================
-- PURSUIT HANDLING
-- ============================================================================

local function onPursuitAction(id, pursuitData)
  local playerVehicleId = be:getPlayerVehicleID(0)

  if id == playerVehicleId then
    if pursuitData.type == "start" then
      playerInPursuit = true
    elseif pursuitData.type == "evade" or pursuitData.type == "reset" then
      playerInPursuit = false
    elseif pursuitData.type == "arrest" then
      playerInPursuit = false
    end
  end
end

local function isPlayerInPursuit()
  return playerInPursuit
end

-- ============================================================================
-- REWARD CALCULATIONS
-- ============================================================================

--- Calculate race reward based on time performance
-- @param goal number Target time
-- @param reward number Base reward
-- @param time number Actual time
-- @param raceTypes table|nil Array of race types for multiplier
-- @return number Calculated reward
local function raceReward(goal, reward, time, raceTypes)
  if time == 0 then
    return 0
  end

  local ratio = goal / time
  local baseReward
  
  if ratio < 1 then
    baseReward = math.floor(ratio * reward * 100) / 100
  else
    baseReward = math.floor((math.pow(ratio, (1 + (reward / 500)))) * reward * 100) / 100
    if baseReward > reward * MAX_REWARD_MULTIPLIER then
      baseReward = reward * MAX_REWARD_MULTIPLIER
    end
  end

  if raceTypes and career_economyAdjuster then
    local multiplier = calculateAverageMultiplier(raceTypes)
    baseReward = baseReward * multiplier
    baseReward = math.floor(baseReward + 0.5)
  end

  return baseReward
end

--- Calculate drift event reward
-- @param race table Race data
-- @param time number Actual time
-- @param driftScore number The drift score
-- @return number Calculated reward
local function driftReward(race, time, driftScore)
  local goalTime = race.bestTime
  local goalDrift = race.driftGoal
  local timeFactor = (goalTime / time) ^ 1.2
  local driftFactor = (driftScore / goalDrift) ^ 1.2
  return race.reward * timeFactor * driftFactor
end

--- Calculate top speed event reward
-- @param goalSpeed number Target speed
-- @param baseReward number Base reward
-- @param actualSpeed number Actual speed achieved
-- @param raceTypes table|nil Array of race types for multiplier
-- @return number Calculated reward
local function topSpeedReward(goalSpeed, baseReward, actualSpeed, raceTypes)
  if actualSpeed == 0 then
    return 0
  end

  local ratio = actualSpeed / goalSpeed
  local baseRewardValue
  
  if ratio < 1 then
    baseRewardValue = math.floor(ratio * baseReward * 100) / 100
  else
    baseRewardValue = math.floor((math.pow(ratio, (1 + (baseReward / 500)))) * baseReward * 100) / 100
    if baseRewardValue > baseReward * MAX_REWARD_MULTIPLIER then
      baseRewardValue = baseReward * MAX_REWARD_MULTIPLIER
    end
  end

  if raceTypes and career_economyAdjuster then
    local multiplier = calculateAverageMultiplier(raceTypes)
    baseRewardValue = baseRewardValue * multiplier
    baseRewardValue = math.floor(baseRewardValue + 0.5)
  end

  return baseRewardValue
end

--- Calculate hybrid (time + damage) race reward
-- @param goalTime number Target time
-- @param baseReward number Base reward
-- @param actualTime number Actual time
-- @param damageFactor number Damage factor (0-1)
-- @param damagePercentage number Damage taken (0-1)
-- @param raceTypes table|nil Array of race types for multiplier
-- @return number Calculated reward
local function hybridRaceReward(goalTime, baseReward, actualTime, damageFactor, damagePercentage, raceTypes)
  if damageFactor == 0 then
    return raceReward(goalTime, baseReward, actualTime, raceTypes)
  end

  if damageFactor == 1 then
    local damageReward = baseReward * (1 - damagePercentage)
    if raceTypes and career_economyAdjuster then
      local multiplier = calculateAverageMultiplier(raceTypes)
      damageReward = damageReward * multiplier
      damageReward = math.floor(damageReward + 0.5)
    end
    return math.max(0, damageReward)
  end

  local timeReward = raceReward(goalTime, baseReward, actualTime, raceTypes)
  local finalReward = (baseReward * (1 - damagePercentage)) + (damageFactor * timeReward)

  return math.max(0, finalReward)
end

--- Calculate hotlap multiplier based on lap count
-- @param lapCount number Current lap count
-- @return number The hotlap multiplier
local function hotlapMultiplier(lapCount)
  return (10 / (1 + math.exp(-0.07 * (lapCount - 17)))) - 1.35
end

--- Calculate XP from reward
-- @param reward number The monetary reward
-- @return number The XP amount
local function calculateXP(reward)
  return math.floor(reward / XP_DIVISOR)
end

--- Calculate BeamXP from XP
-- @param xp number The XP amount
-- @return number The BeamXP amount
local function calculateBeamXP(xp)
  return math.floor(xp / BEAM_XP_DIVISOR)
end

--- Build career reward structure
-- @param reward number Monetary reward
-- @param raceTypes table Array of race types
-- @return table The reward structure for career_modules_payment
local function buildCareerReward(reward, raceTypes)
  local xp = calculateXP(reward)
  local totalReward = {
    money = { amount = reward },
    beamXP = { amount = calculateBeamXP(xp) }
  }
  
  if raceTypes then
    for _, raceType in ipairs(raceTypes) do
      totalReward[raceType] = { amount = xp }
    end
  end
  
  return totalReward
end

--- Apply career reward with payment module
-- @param reward number The reward amount
-- @param label string The reward label
-- @param tags table Array of tags
local function applyCareerReward(reward, label, tags)
  if not isCareerActive() or reward <= 0 then
    return
  end
  
  if career_modules_payment and career_modules_payment.reward then
    career_modules_payment.reward(reward, {
      label = label,
      tags = tags or {"gameplay", "reward", "mission"}
    }, true)
  end
end

-- ============================================================================
-- STAGED MESSAGE HELPERS
-- ============================================================================

--- Build time info section for staged message
-- @param bestTime number|nil Player's best time
-- @param targetTime number Target time
-- @param reward number Base reward
-- @param label string Section label
-- @param raceData table|nil Race data for type multipliers
-- @return string Formatted info string
local function buildTimeInfo(bestTime, targetTime, reward, label, raceData)
  local careerMode = isCareerActive()
  
  if not bestTime then
    if careerMode then
      local adjustedBaseReward = raceReward(targetTime, reward, targetTime, raceData and raceData.type or nil)
      return string.format("%sTarget Time: %s\n(Achieve this to earn a reward of $%.2f)", label,
        formatTime(targetTime), adjustedBaseReward)
    else
      return string.format("%sTarget Time: %s", label, formatTime(targetTime))
    end
  elseif bestTime > targetTime then
    if careerMode then
      local adjustedBaseReward = raceReward(targetTime, reward, targetTime, raceData and raceData.type or nil)
      return string.format("%sYour Best Time: %s | Target Time: %s\n(Achieve target to earn a reward of $%.2f)",
        label, formatTime(bestTime), formatTime(targetTime), adjustedBaseReward)
    else
      return string.format("%sYour Best Time: %s | Target Time: %s", label, formatTime(bestTime),
        formatTime(targetTime))
    end
  else
    if careerMode then
      local adjustedPotentialReward = raceReward(targetTime, reward, bestTime, raceData and raceData.type or nil)
      return string.format("%sYour Best Time: %s\n(Improve to earn at least $%.2f)", label, formatTime(bestTime),
        adjustedPotentialReward)
    else
      return string.format("%sYour Best Time: %s", label, formatTime(bestTime))
    end
  end
end

--- Build hybrid race info section for staged message
-- @param leaderboardEntry table|nil Leaderboard entry
-- @param targetTime number Target time
-- @param reward number Base reward
-- @param label string Section label
-- @param damageFactor number Damage factor
-- @param raceData table|nil Race data for type multipliers
-- @return string Formatted info string
local function buildHybridRaceInfo(leaderboardEntry, targetTime, reward, label, damageFactor, raceData)
  local careerMode = isCareerActive()
  local bestTime = leaderboardEntry and leaderboardEntry.time or nil
  local bestDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or nil

  if not bestTime then
    if careerMode then
      local adjustedBaseReward = hybridRaceReward(targetTime, reward, targetTime, damageFactor, 0,
        raceData and raceData.type or nil)
      if damageFactor == 1 then
        return string.format(
          "%sTarget Time: %s | Target: No Damage\n(Achieve both to earn a reward of $%.2f and 1 Bonus Star)", label,
          formatTime(targetTime), adjustedBaseReward)
      else
        return string.format(
          "%sTarget Time: %s | Damage Factor: %.0f%%\n(Speed and damage both matter - achieve target time with minimal damage to earn up to $%.2f and 1 Bonus Star)",
          label, formatTime(targetTime), damageFactor * 100, adjustedBaseReward)
      end
    else
      return string.format("%sTarget Time: %s | Damage Factor: %.0f%%", label, formatTime(targetTime),
        damageFactor * 100)
    end
  else
    local damageText = bestDamagePercentage and string.format(" | Best Damage: %.1f%%", bestDamagePercentage * 100) or ""
    if careerMode then
      if damageFactor == 1 then
        return string.format(
          "%sYour Best Time: %s%s | Target: No Damage\n(Improve time or reduce damage to earn more rewards)", label,
          formatTime(bestTime), damageText)
      else
        return string.format(
          "%sYour Best Time: %s%s | Damage Factor: %.0f%%\n(Speed and damage both matter - improve either to earn more rewards)",
          label, formatTime(bestTime), damageText, damageFactor * 100)
      end
    else
      return string.format("%sYour Best Time: %s%s | Damage Factor: %.0f%%", label, formatTime(bestTime), damageText,
        damageFactor * 100)
    end
  end
end

--- Build top speed info section for staged message
-- @param leaderboardEntry table|nil Leaderboard entry
-- @param race table Race data
-- @return string Formatted info string
local function buildTopSpeedInfo(leaderboardEntry, race)
  local careerMode = isCareerActive()
  local bestSpeed = leaderboardEntry and leaderboardEntry.topSpeed or nil
  local bestTime = leaderboardEntry and leaderboardEntry.time or nil
  local targetSpeed = race.topSpeedGoal

  if bestSpeed and bestTime then
    if careerMode then
      local adjustedReward = topSpeedReward(targetSpeed, race.reward, bestSpeed, race.type)
      return string.format(
        "Your Best Speed: %.2f mph | Target Speed: %.2f mph\nYour Best Time: %s\n(Improve to earn at least $%.2f)",
        bestSpeed, targetSpeed, formatTime(bestTime), adjustedReward)
    else
      return string.format("Your Best Speed: %.2f mph | Target Speed: %.2f mph\nYour Best Time: %s", bestSpeed,
        targetSpeed, formatTime(bestTime))
    end
  else
    if careerMode then
      local adjustedReward = topSpeedReward(targetSpeed, race.reward, targetSpeed, race.type)
      return string.format("Target Speed: %.2f mph\n(Achieve this to earn a reward of $%.2f and 1 Bonus Star)",
        targetSpeed, adjustedReward)
    else
      return string.format("Target Speed: %.2f mph", targetSpeed)
    end
  end
end

--- Build drift info section for staged message
-- @param leaderboardEntry table|nil Leaderboard entry
-- @param race table Race data
-- @return string Formatted info string
local function buildDriftInfo(leaderboardEntry, race)
  local careerMode = isCareerActive()
  local bestScore = leaderboardEntry and leaderboardEntry.driftScore or nil
  local bestTime = leaderboardEntry and leaderboardEntry.time or nil
  local targetScore = race.driftGoal
  local targetTime = race.driftTargetTime or race.bestTime

  if bestScore and bestTime then
    if careerMode then
      return string.format(
        "Your Best Drift Score: %d | Target Drift Score: %d\nYour Best Time: %s | Target Time: %s\n(Achieve targets to earn a reward of $%.2f and 1 Bonus Star)",
        bestScore, targetScore, formatTime(bestTime), formatTime(targetTime), race.reward)
    else
      return string.format(
        "Your Best Drift Score: %d | Target Drift Score: %d\nYour Best Time: %s | Target Time: %s", bestScore,
        targetScore, formatTime(bestTime), formatTime(targetTime))
    end
  else
    if careerMode then
      return string.format(
        "Target Drift Score: %d\nTarget Time: %s\n(Achieve these to earn a reward of $%.2f and 1 Bonus Star)",
        targetScore, formatTime(targetTime), race.reward)
    else
      return string.format("Target Drift Score: %d\nTarget Time: %s", targetScore, formatTime(targetTime))
    end
  end
end

-- ============================================================================
-- START/STAGED MESSAGES
-- ============================================================================

local motivationalMessages = {
  -- Enthusiastic
  "Give it your all!", "Time to shine!", "Let's set a new record!", "It's go time!",
  -- Funny
  "Try not to hit any trees this time!", "Remember, the brake is the other pedal!",
  "First one to the finish line gets a cookie!", "Drive like you stole it... wait, you didn't, right?",
  -- Passive-aggressive
  "Try to keep it on the track this time, okay?", "Let's see if you've improved since last time...",
  "Maybe today you'll actually finish the race?",
  "I'm sure you'll do better than your last attempt. It can't get worse, right?",
  -- Encouraging
  "Believe in yourself, you've got this!", "Today could be your personal best!",
  "Focus and breathe, you're ready for this!", "Every second counts, make them all yours!",
  -- Challenging
  "Think you can handle this? Prove it!", "Show us what you're really made of!",
  "This track has beaten you before. Not today!", "Time to separate the rookies from the pros!",
  -- Quirky
  "May the downforce be with you!", "Remember: turn left to go left, right to go right!",
  "Gravity is just a suggestion, right?", "If in doubt, flat out! (Results may vary)",
  -- Intense
  "Push it to the limit!", "Leave nothing on the table!", "Drive like your life depends on it!", "It's now or never!"
}

local function displayStartMessage(raceName)
  local race = races[raceName]
  if not race then return end
  
  local message
  if math.random() < 0.5 then
    message = "GO!"
  else
    message = motivationalMessages[math.random(#motivationalMessages)]
  end

  message = string.format("**%s Event Started!\n%s**", race.label, message)
  displayMessage(message, 5)
end

local function displayStagedMessage(vehId, raceName, getMessage)
  local inventoryId = getInventoryIdSafe(vehId) or vehId
  local race = races[raceName]
  if not race then return end
  
  local leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryId, getRaceLabel(raceName)) or {}
  local careerMode = isCareerActive()

  -- Check if all types are disabled
  local allTypesDisabled, disabledTypes = areAllTypesDisabled(race)

  local message = ""
  if allTypesDisabled then
    local typesString = table.concat(disabledTypes, ", ")
    message = string.format("%s is currently disabled due to %s multiplier(s) being set to 0.", race.label, typesString)
    if not getMessage then
      displayMessage(message, 5)
    end
    return getMessage and message or nil
  else
    if not getMessage then
      message = string.format("Staged for %s.\n", race.label)
    end
  end

  -- Build the appropriate info section based on race type
  if race.topSpeed then
    message = message .. buildTopSpeedInfo(leaderboardEntry, race)
  elseif race.driftGoal then
    message = message .. buildDriftInfo(leaderboardEntry, race)
  elseif race.damageFactor and race.damageFactor > 0 then
    message = message .. buildHybridRaceInfo(leaderboardEntry, race.bestTime, race.reward, "", race.damageFactor, race)
  else
    message = message .. buildTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.bestTime, race.reward, "", race)
  end

  -- Handle hotlap if it exists
  if race.hotlap then
    leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryId, getRaceLabel(raceName, nil, true))
    if race.damageFactor and race.damageFactor > 0 then
      message = message .. "\n\n" .. buildHybridRaceInfo(leaderboardEntry, race.hotlap, race.reward, "Hotlap: ", race.damageFactor, race)
    else
      message = message .. "\n\n" .. buildTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.hotlap, race.reward, "Hotlap: ", race)
    end
  end

  -- Handle alternative route if it exists
  if race.altRoute then
    leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryId, getRaceLabel(raceName, true))
    message = message .. "\n\nAlternative Route:\n"
    if race.altRoute.damageFactor and race.altRoute.damageFactor > 0 then
      message = message .. buildHybridRaceInfo(leaderboardEntry, race.altRoute.bestTime, race.altRoute.reward, "", race.altRoute.damageFactor, race.altRoute)
    else
      message = message .. buildTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.altRoute.bestTime, race.altRoute.reward, "", race.altRoute)
    end

    if race.altRoute.hotlap then
      leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryId, getRaceLabel(raceName, true, true))
      if race.altRoute.damageFactor and race.altRoute.damageFactor > 0 then
        message = message .. "\n\n" .. buildHybridRaceInfo(leaderboardEntry, race.altRoute.hotlap, race.altRoute.reward, "Alt Route Hotlap: ", race.altRoute.damageFactor, race.altRoute)
      else
        message = message .. "\n\n" .. buildTimeInfo(leaderboardEntry and leaderboardEntry.time or nil, race.altRoute.hotlap, race.altRoute.reward, "Alt Route Hotlap: ", race.altRoute)
      end
    end
  end

  -- Add note for time-based events in career mode
  if careerMode and not race.driftGoal and not race.topSpeed then
    if race.damageFactor and race.damageFactor > 0 then
      message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best score. Score is calculated based on both time and damage.**"
    else
      message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best time.**"
    end
  elseif careerMode and race.topSpeed then
    message = message .. "\n\n**Note: All rewards are cut by 50% if they are below your best speed.**"
  end

  if not getMessage then
    displayMessage(message, 15)
    return
  end
  return message
end

-- ============================================================================
-- DATA LOADING
-- ============================================================================

local function loadRaceData()
  if getCurrentLevelIdentifier() then
    local level = "levels/" .. getCurrentLevelIdentifier() .. "/race_data.json"
    local raceData = jsonReadFile(level)
    if raceData then
      races = raceData.races or {}
    end
    return deepcopy(races)
  end
  return {}
end

local function onExtensionLoaded()
  if getCurrentLevelIdentifier() then
    loadRaceData()
  end
  print("Initializing Freeroam Utils and Extensions")
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

-- Constants
M.SPEED_UNIT_MPS_TO_MPH = SPEED_UNIT_MPS_TO_MPH
M.NEW_BEST_BONUS = NEW_BEST_BONUS
M.IN_RANGE_BONUS = IN_RANGE_BONUS
M.IN_RANGE_THRESHOLD = IN_RANGE_THRESHOLD
M.XP_DIVISOR = XP_DIVISOR

-- Career helpers
M.isCareerActive = isCareerActive
M.getInventoryIdSafe = getInventoryIdSafe
M.getVehicleValueSafe = getVehicleValueSafe
M.isHardcoreModeActive = isHardcoreModeActive
M.saveCareerState = saveCareerState
M.areAllTypesDisabled = areAllTypesDisabled
M.calculateAverageMultiplier = calculateAverageMultiplier

-- Utilities
M.tableContains = tableContains
M.formatTime = formatTime
M.formatDistance = formatDistance
M.getRaceLabel = getRaceLabel

-- Audio
M.playCheckpointSound = playCheckpointSound

-- UI
M.displayMessage = displayMessage
M.updateDisplay = updateDisplay
M.initDisplays = initDisplays
M.resetDisplays = resetDisplays
M.setActiveLight = setActiveLight
M.displayStartMessage = displayStartMessage
M.displayStagedMessage = displayStagedMessage

-- Traffic
M.hasFinishTrigger = hasFinishTrigger
M.saveAndSetTrafficAmount = saveAndSetTrafficAmount
M.restoreTrafficAmount = restoreTrafficAmount

-- Vehicle
M.getVehicleDamage = getVehicleDamage

-- Pursuit
M.onPursuitAction = onPursuitAction
M.isPlayerInPursuit = isPlayerInPursuit

-- Rewards
M.raceReward = raceReward
M.driftReward = driftReward
M.topSpeedReward = topSpeedReward
M.hybridRaceReward = hybridRaceReward
M.hotlapMultiplier = hotlapMultiplier
M.calculateXP = calculateXP
M.calculateBeamXP = calculateBeamXP
M.buildCareerReward = buildCareerReward
M.applyCareerReward = applyCareerReward

-- Data
M.loadRaceData = loadRaceData
M.onExtensionLoaded = onExtensionLoaded

return M
