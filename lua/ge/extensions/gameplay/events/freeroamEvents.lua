-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {}

local processRoad = require('gameplay/events/freeroam/processRoad')
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
local activeAssets = require('gameplay/events/freeroam/activeAssets')
local checkpointManager = require('gameplay/events/freeroam/checkpointManager')
local utils = require('gameplay/events/freeroam/utils')
local pits = require('gameplay/events/freeroam/pits')
local Assets = activeAssets.ActiveAssets.new()

local loadedExtensions = {}

-- ============================================================================
-- STATE
-- ============================================================================

local timerActive = false
local mActiveRace = nil
local staged = nil
local in_race_time = 0

local lapCount = 0
local currCheckpoint = nil
local mHotlap = nil
local mAltRoute = nil
local mSplitTimes = {}
local isLoop = false
local checkpointsHit = 0
local totalCheckpoints = 0
local currentExpectedCheckpoint = 1
local invalidLap = false

local initialVehicleDamage = 0
local mInventoryId = nil
local newBestSession = false
local maxSpeed = 0

local races = nil
local isReplay = false

-- Track distance state
local trackDistances = nil
local liveDistanceInfo = nil

local previousGameState = nil
local saveGameState = false

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

--- Reset all race state variables to defaults
local function resetRaceState()
  lapCount = 0
  mActiveRace = nil
  timerActive = false
  mHotlap = nil
  currCheckpoint = nil
  mSplitTimes = {}
  mAltRoute = false
  invalidLap = false
  mInventoryId = nil
  maxSpeed = 0
  newBestSession = false
  in_race_time = 0
  checkpointsHit = 0
  totalCheckpoints = 0
  currentExpectedCheckpoint = 1
  initialVehicleDamage = 0
  trackDistances = nil
  liveDistanceInfo = nil
end

-- ============================================================================
-- REWARD HELPERS
-- ============================================================================

--- Build the reward label for career mode
-- @param raceName string The race name
-- @param newBestTime boolean Whether this is a new best time
-- @return string The formatted reward label
local function buildRewardLabel(raceName, newBestTime)
  if not races or not races[raceName] then
    return "Race Completion"
  end
  
  local raceLabel = races[raceName].label
  local timeLabel = utils.formatTime(in_race_time)
  local performanceLabel = newBestTime and "New Best Time!" or "Completion"

  local label = string.format("%s - %s: %s", raceLabel, performanceLabel, timeLabel)

  if mAltRoute then
    label = label .. " (Alternative Route)"
  end

  if mHotlap == raceName then
    label = label .. " (Hotlap)"
  end

  return label
end

--- Get the current drift score and reset drift state
-- @return number The final drift score
local function getDriftScore()
  local finalScore = 0
  if gameplay_drift_scoring then
    local scoreData = gameplay_drift_scoring.getScore()
    if scoreData then
      finalScore = scoreData.score or 0
      if scoreData.cachedScore then
        finalScore = finalScore + math.floor(scoreData.cachedScore * scoreData.combo)
      end
      gameplay_drift_general.reset()
    end
  end
  return finalScore
end

--- Get the current race label with route variations
-- @return string The race label
local function getCurrentRaceLabel()
  if not mActiveRace or not races or not races[mActiveRace] then
    return "Unknown Race"
  end
  return utils.getRaceLabel(mActiveRace, mAltRoute, mHotlap == mActiveRace)
end

--- Calculate damage percentage for damage-based races
-- @param race table The race data
-- @return number Damage percentage (0-1)
local function calculateDamagePercentage(race)
  local damageFactor = race.damageFactor or 0
  if damageFactor <= 0 then
    return 0
  end
  
  local currentDamage = utils.getVehicleDamage()
  local damageTaken = math.max(0, currentDamage - initialVehicleDamage)
  local maxDamage = utils.getVehicleValueSafe(mInventoryId)
  
  return math.min(1, damageTaken / maxDamage)
end

--- Calculate the adjusted reward for a race
-- @param race table The race data
-- @param damagePercentage number Damage percentage (0-1)
-- @param driftScore number Drift score (for drift races)
-- @return number The calculated reward
local function calculateRaceReward(race, damagePercentage, driftScore)
  local time = race.bestTime
  local reward = race.reward
  local damageFactor = race.damageFactor or 0

  -- Get appropriate time and reward based on route type
  if mHotlap == mActiveRace then
    time = race.hotlap
  end
  if mAltRoute and race.altRoute then
    time = race.altRoute.bestTime
    reward = race.altRoute.reward
    if mHotlap == mActiveRace then
      time = race.altRoute.hotlap
    end
  end

  -- Calculate reward based on race type
  if race.topSpeed then
    return utils.topSpeedReward(race.topSpeedGoal, reward, maxSpeed, race.type)
  elseif race.driftGoal then
    return utils.driftReward(race, time, driftScore)
  elseif damageFactor > 0 then
    return utils.hybridRaceReward(time, reward, in_race_time, damageFactor, damagePercentage, race.type)
  else
    return utils.raceReward(time, reward, in_race_time, race.type)
  end
end

--- Build the completion message for race finish
-- @param race table The race data
-- @param raceLabel string The race label
-- @param newBest boolean Whether this is a new best
-- @param leaderboardEntry table|nil Previous leaderboard entry
-- @param damagePercentage number Damage percentage
-- @param driftScore number Drift score
-- @return string The completion message
local function buildCompletionMessage(race, raceLabel, newBest, leaderboardEntry, damagePercentage, driftScore)
  local damageFactor = race.damageFactor or 0
  local message = invalidLap and "Lap Invalidated\n" or ""

  local oldTime = leaderboardEntry and leaderboardEntry.time or 0
  local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0

  if race.topSpeed then
    message = message .. string.format("%s\nTop Speed: %.2f mph\nTime: %s", raceLabel, maxSpeed, utils.formatTime(in_race_time))
    if oldTime and oldTime > 0 then
      local oldSpeed = leaderboardEntry and leaderboardEntry.topSpeed or 0
      message = message .. string.format("\nPrevious Best Speed: %.2f mph\nPrevious Best Time: %s", oldSpeed, utils.formatTime(oldTime))
    end
  elseif race.driftGoal then
    message = message .. string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore, utils.formatTime(in_race_time))
    if oldScore and oldScore > 0 and oldTime and oldTime > 0 then
      message = message .. string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore, utils.formatTime(oldTime))
    end
  else
    if newBest and not invalidLap then
      if damageFactor > 0 then
        message = message .. "New Best Score!\n"
      else
        message = message .. "New Best Time!\n"
      end
    end
    
    -- Build basic time information
    if race.hotlap then
      message = message .. string.format("%s\nTime: %s\nLap: %d", raceLabel, utils.formatTime(in_race_time), lapCount)
    else
      message = message .. string.format("%s\nTime: %s", raceLabel, utils.formatTime(in_race_time))
    end
    
    -- Add track length if available
    if trackDistances and trackDistances.totalLength and trackDistances.totalLength > 0 then
      message = message .. string.format("\nTrack Length: %s", utils.formatDistance(trackDistances.totalLength))
    end
    
    -- Add damage information for damage-based races
    if damageFactor > 0 then
      message = message .. string.format("\nDamage Taken: %.1f%% | Damage Factor: %.0f%%", damagePercentage * 100, damageFactor * 100)
    end
    
    -- Show previous best information
    if newBest and not invalidLap and oldTime and oldTime ~= math.huge and oldTime > 0 then
      if damageFactor > 0 then
        local oldDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or 0
        message = message .. string.format("\nPrevious Best Time: %s | Previous Best Damage: %.1f%%", utils.formatTime(oldTime), oldDamagePercentage * 100)
      else
        message = message .. string.format("\nPrevious Best: %s", utils.formatTime(oldTime))
      end
    end
  end

  return message
end

--- Apply career mode bonuses and rewards
-- @param race table The race data
-- @param reward number Base reward
-- @param newBest boolean Whether this is a new best
-- @param oldTime number|nil Previous best time
-- @return number Adjusted reward
-- @return string Hotlap bonus message
local function applyCareerBonuses(race, reward, newBest, oldTime)
  local hotlapMessage = ""
  
  if not utils.isCareerActive() then
    return reward, hotlapMessage
  end

  -- Half reward if not new best (unless hotlap)
  if not newBest or mHotlap then
    reward = reward / 2
  end
  
  -- No reward for invalid laps
  reward = invalidLap and 0 or reward
  lapCount = invalidLap and 1 or lapCount
  
  -- Hotlap multiplier
  if race.hotlap then
    reward = reward * utils.hotlapMultiplier(lapCount)
    hotlapMessage = string.format("\nHotlap Multiplier: %.2f", utils.hotlapMultiplier(lapCount))
  end

  -- New best session bonus
  if newBest and not newBestSession then
    newBestSession = true
  end

  if newBestSession then
    reward = reward * utils.NEW_BEST_BONUS
    hotlapMessage = hotlapMessage .. string.format("\nNew Best Session Bonus: %.0f%%", (utils.NEW_BEST_BONUS - 1) * 100)
  end

  -- In range bonus
  if oldTime and oldTime > 0 and (in_race_time - (oldTime * utils.IN_RANGE_THRESHOLD) < oldTime) then
    reward = reward * utils.IN_RANGE_BONUS
    hotlapMessage = hotlapMessage .. string.format("\nIn Range Bonus: %.0f%%", (utils.IN_RANGE_BONUS - 1) * 100)
  end

  -- Hardcore mode penalty
  if utils.isHardcoreModeActive() then
    reward = reward / 2
  end

  return reward, hotlapMessage
end

--- Process career reward payment
-- @param race table The race data
-- @param reward number The reward amount
-- @param message string The completion message
-- @param newBest boolean Whether this is a new best
-- @return string Updated message with reward info
local function processCareerReward(race, reward, message, newBest)
  if not utils.isCareerActive() or reward <= 0 then
    return message
  end

  local xp = utils.calculateXP(reward)
  local totalReward = utils.buildCareerReward(reward, race.type)

  career_modules_payment.reward(totalReward, {
    label = buildRewardLabel(mActiveRace, newBest),
    tags = {"gameplay", "reward", "mission"}
  }, true)

  message = message .. string.format("\nXP: %d | Reward: $%.2f", xp, reward)
  
  if utils.isHardcoreModeActive() then
    message = message .. "\nHardcore mode is enabled, all rewards are halved."
  end
  
  utils.saveCareerState()
  
  return message
end

-- ============================================================================
-- RACE PAYOUT FUNCTIONS
-- ============================================================================

--- Payout for completing a standard race
-- @return number The reward amount
local function payoutRace()
  if not mActiveRace or not races or not races[mActiveRace] then
    return 0
  end

  local race = races[mActiveRace]
  local raceLabel = getCurrentRaceLabel()
  local damageFactor = race.damageFactor or 0

  -- Calculate damage and scores
  local damagePercentage = calculateDamagePercentage(race)
  local driftScore = race.driftGoal and getDriftScore() or 0

  -- Calculate base reward
  local reward = calculateRaceReward(race, damagePercentage, driftScore)
  print("Adjusted reward: " .. reward)

  -- Handle leaderboard
  local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
  local oldTime = leaderboardEntry and leaderboardEntry.time or 0
  
  local newEntry = {
    raceName = mActiveRace,
    raceLabel = raceLabel,
    isAltRoute = mAltRoute,
    isHotlap = mHotlap == mActiveRace,
    time = in_race_time,
    splitTimes = mSplitTimes,
    driftScore = driftScore,
    inventoryId = mInventoryId,
    damagePercentage = damagePercentage,
    damageFactor = damageFactor,
    topSpeed = maxSpeed
  }

  local newBest = leaderboardManager.addLeaderboardEntry(newEntry)

  -- Build completion message
  local message = buildCompletionMessage(race, raceLabel, newBest, leaderboardEntry, damagePercentage, driftScore)

  -- Apply career bonuses
  local hotlapMessage
  reward, hotlapMessage = applyCareerBonuses(race, reward, newBest, oldTime)

  -- Process career reward and update message
  message = processCareerReward(race, reward, message, newBest)

  mActiveRace = nil
  utils.displayMessage(message, 20, "Reward")
  
  if hotlapMessage ~= "" then
    ui_message(hotlapMessage, 5, "Hotlap Multiplier")
  end
  
  return reward
end

--- Simplified payout function for drag races
-- @param raceName string The race name
-- @param finishTime number The finish time
-- @param finishSpeed number The finish speed in mph
-- @param vehId number The vehicle ID
-- @return number The reward amount
local function payoutDragRace(raceName, finishTime, finishSpeed, vehId)
  if not races or not races["drag"] then
    return 0
  end

  local inventoryId = utils.getInventoryIdSafe(vehId) or vehId
  local raceData = races[raceName]
  if not raceData then
    return 0
  end

  local leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryId, races["drag"].label)
  local oldTime = leaderboardEntry and leaderboardEntry.time or 0

  local newEntry = {
    raceLabel = races["drag"].label,
    raceName = raceName,
    time = finishTime,
    splitTimes = mSplitTimes,
    inventoryId = inventoryId
  }

  local newBestTime = leaderboardManager.addLeaderboardEntry(newEntry)

  if not utils.isCareerActive() then
    local message = string.format("%s\nTime: %s\nSpeed: %.2f mph", raceData.label, utils.formatTime(finishTime), finishSpeed)
    utils.displayMessage(message, 10)
    return 0
  end

  -- Calculate reward based on performance
  local reward = utils.raceReward(raceData.bestTime, raceData.reward, finishTime, raceData.type)
  if reward <= 0 then
    reward = raceData.reward / 2
  end

  print("Adjusted drag reward: " .. reward)

  -- Apply hardcore penalty
  if utils.isHardcoreModeActive() then
    reward = reward / 2
  end

  -- Half reward if not new best
  reward = newBestTime and reward or reward / 2

  -- Calculate XP and prepare reward
  local xp = utils.calculateXP(reward)
  local totalReward = utils.buildCareerReward(reward, nil)

  local reason = {
    label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
    tags = {"gameplay", "reward", "drag"}
  }

  career_modules_payment.reward(totalReward, reason, true)

  -- Build completion message
  local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nXP: %d | Reward: $%.2f",
    newBestTime and "Congratulations! New Best Time!" or "", raceData.label, utils.formatTime(finishTime), finishSpeed,
    xp, reward)

  if utils.isHardcoreModeActive() then
    message = message .. "\nHardcore mode is enabled, all rewards are halved."
  end

  ui_message(message, 20, "Reward")
  utils.saveCareerState()

  return reward
end

-- ============================================================================
-- SPLIT TIME HELPERS
-- ============================================================================

--- Get time difference for current checkpoint compared to best
-- @param raceName string The race name
-- @param currentCheckpointIndex number The checkpoint index
-- @return number|nil The time difference or nil if not available
local function getDifference(raceName, currentCheckpointIndex)
  local raceLabel = getCurrentRaceLabel()
  local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
  if not leaderboardEntry then
    return nil
  end

  local splitTimes = leaderboardEntry.splitTimes
  if not splitTimes or not splitTimes[currentCheckpointIndex] then
    return nil
  end

  if not mSplitTimes[currentCheckpointIndex] then
    return nil
  end

  local currentSplitDiff
  if currentCheckpointIndex == 1 then
    currentSplitDiff = mSplitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex]
  else
    if not mSplitTimes[currentCheckpointIndex - 1] or not splitTimes[currentCheckpointIndex - 1] then
      return nil
    end
    local previousBestSplit = splitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex - 1]
    local currentSplit = mSplitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex - 1]
    currentSplitDiff = currentSplit - previousBestSplit
  end

  return currentSplitDiff
end

--- Format split time difference with sign
-- @param diff number The time difference
-- @return string Formatted difference string
local function formatSplitDifference(diff)
  local sign = diff >= 0 and "+" or "-"
  return string.format("%s%s", sign, utils.formatTime(math.abs(diff)))
end

-- ============================================================================
-- RACE EXIT
-- ============================================================================

--- Exit the current race
-- @param isCompletion boolean True if completing, false if cancelling
-- @param customMessage string|nil Custom message to display
-- @param raceData table|nil Race data for completion
-- @param subjectID number|nil Vehicle ID for completion
local function exitRace(isCompletion, customMessage, raceData, subjectID)
  if not mActiveRace then
    return
  end
  
  local raceName = mActiveRace
  
  if isCompletion then
    payoutRace()

    -- Race-specific completion handling
    if raceName == "drag" and raceData and subjectID then
      local side = "l"
      utils.updateDisplay(side, in_race_time, math.abs(be:getObjectVelocityXYZ(subjectID)) * utils.SPEED_UNIT_MPS_TO_MPH)
    end

    if raceData and utils.tableContains(raceData.type, "drift") then
      getDriftScore()
      if gameplay_drift_general and gameplay_drift_general.getContext() == "inChallenge" then
        gameplay_drift_general.setContext("inFreeRoam")
      end
    end

    if customMessage then
      utils.displayMessage(customMessage, 10, "Reward")
    end
  else
    local message = customMessage or "You exited the race zone, Race cancelled"
    utils.displayMessage(message, 3)
  end

  utils.setActiveLight(raceName, "red")
  Assets:hideAllAssets()
  checkpointManager.removeCheckpoints()

  -- Common cleanup tasks
  core_jobsystem.create(function(job)
    job.sleep(10)
    utils.restoreTrafficAmount()
  end)
  pits.clearSpeedLimit()
  
  if gameplay_drift_general and gameplay_drift_general.getContext() == "inChallenge" then
    gameplay_drift_general.setContext("inFreeRoam")
    gameplay_drift_general.reset()
  end
  
  if utils.isCareerActive() and career_modules_pauseTime then
    career_modules_pauseTime.enablePauseCounter()
  end
  
  -- Restore game state
  if previousGameState and previousGameState.state then
    core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
  end
  previousGameState = nil
  saveGameState = false
  
  -- Reset state
  resetRaceState()
end

-- ============================================================================
-- TRIGGER HANDLERS
-- ============================================================================

--- Handle staging trigger events
-- @param data table Trigger event data
-- @param raceName string The race name
-- @param event string "enter" or "exit"
local function handleStaging(data, raceName, event)
  if event == "enter" and mActiveRace == nil then
    if utils.isPlayerInPursuit() then
      utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
      return
    end

    saveGameState = true
    core_gamestate.requestGameState()

    local vehicleSpeed = math.abs(be:getObjectVelocityXYZ(data.subjectID)) * utils.SPEED_UNIT_MPS_TO_MPH
    if vehicleSpeed > 5 and mActiveRace then
      return
    end
    
    mHotlap = nil
    if vehicleSpeed > 5 then
      if races[raceName].runningStart then
        utils.displayMessage("Hotlap Staged", 2)
        if races[raceName].hotlap then
          mHotlap = raceName
        end
      else
        utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
        staged = nil
        return
      end
    end
    
    Assets:hideAllAssets()
    lapCount = 0

    -- Check if all race types are disabled
    local allTypesDisabled, disabledTypes = utils.areAllTypesDisabled(races[raceName])

    if allTypesDisabled then
      local typesString = table.concat(disabledTypes, ", ")
      utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
      return
    end

    -- Initialize displays if drag race
    if raceName == "drag" then
      utils.initDisplays()
      utils.resetDisplays()
    end

    -- Set staged race
    staged = raceName
    local vehId = utils.getInventoryIdSafe(data.subjectID) or data.subjectID
    utils.displayStagedMessage(vehId, raceName)
    utils.setActiveLight(raceName, "yellow")
    
  elseif event == "exit" then
    staged = nil
    if not mActiveRace then
      utils.displayMessage("You exited the staging zone", 4)
      utils.setActiveLight(raceName, "red")
    end
  end
end

--- Handle start trigger events
-- @param data table Trigger event data
-- @param raceName string The race name
-- @param event string "enter" or "exit"
local function handleStart(data, raceName, event)
  if event ~= "enter" then
    utils.setActiveLight(raceName, "red")
    return
  end

  -- Handle hotlap lap completion (re-entering start)
  if mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
    if not currCheckpoint or checkpointsHit ~= totalCheckpoints then
      if not invalidLap then
        utils.displayMessage("You have not completed all checkpoints!", 5)
        return
      end
    end
    
    initialVehicleDamage = utils.getVehicleDamage()
    processRoad.setStationaryTimeout(races[raceName].timeout)
    checkpointManager.setRace(races[raceName], raceName)
    Assets:displayAssets(data)
    utils.playCheckpointSound()
    timerActive = false
    lapCount = lapCount + 1
    payoutRace()
    currCheckpoint = nil
    mSplitTimes = {}
    mActiveRace = raceName
    checkpointManager.setAltRoute(false)
    mAltRoute = false
    in_race_time = 0
    maxSpeed = 0
    timerActive = true
    checkpointsHit = 0
    totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
    currentExpectedCheckpoint = 0
    if races[raceName].hotlap then
      mHotlap = raceName
      currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
    end
    invalidLap = false
    return
  end
  
  -- Handle race start
  if staged == raceName then
    if utils.isCareerActive() and career_modules_pauseTime then
      career_modules_pauseTime.enablePauseCounter(true)
    end
    
    initialVehicleDamage = utils.getVehicleDamage()
    utils.saveAndSetTrafficAmount(0)
    checkpointManager.setRace(races[raceName], raceName)
    Assets:displayAssets(data)
    timerActive = true
    in_race_time = 0
    maxSpeed = 0
    mActiveRace = raceName
    lapCount = 0
    mInventoryId = utils.getInventoryIdSafe(data.subjectID) or data.subjectID
    invalidLap = false

    utils.displayStartMessage(raceName)
    utils.setActiveLight(raceName, "green")

    -- Handle drift races
    if utils.tableContains(races[raceName].type, "drift") then
      gameplay_drift_general.setContext("inChallenge")
      gameplay_drift_general.reset()
      if gameplay_drift_drift then
        gameplay_drift_drift.setVehId(data.subjectID)
      end
    end

    -- Initialize checkpoints if applicable
    if races[raceName].checkpointRoad then
      processRoad.reset()
      processRoad.setStationaryTimeout(races[raceName].timeout)
      local checkpoints, altCheckpoints = processRoad.getCheckpoints(races[raceName])

      checkpointManager.createCheckpoints(checkpoints, altCheckpoints)

      isLoop = processRoad.isLoop()
      currCheckpoint = 0
      checkpointsHit = 0
      totalCheckpoints = checkpointManager.calculateTotalCheckpoints(races[raceName])
      currentExpectedCheckpoint = 1
      mAltRoute = false
      checkpointManager.setAltRoute(mAltRoute)

      currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
      
      -- Calculate track distances
      local roadNodes = processRoad.getRoadNodes()
      if roadNodes and #roadNodes > 0 then
        trackDistances = processRoad.calculateTrackDistances(roadNodes, checkpoints)
      else
        trackDistances = nil
      end
    end
  else
    utils.setActiveLight(raceName, "red")
  end
end

--- Handle checkpoint trigger events
-- @param data table Trigger event data
-- @param raceName string The race name
-- @param checkpointIndex number The checkpoint index
-- @param isAlt boolean Whether this is an alt route checkpoint
local function handleCheckpoint(data, raceName, checkpointIndex, isAlt)
  if data.event ~= "enter" or mActiveRace ~= raceName then
    return
  end

  local race = races[raceName]
  local altMergeCheckpoint = race.altRoute and race.altRoute.mergeCheckpoints and race.altRoute.mergeCheckpoints[1] or nil

  -- Check if this is a valid checkpoint
  local isExpected = (checkpointIndex == currentExpectedCheckpoint) or 
                     (checkpointIndex == 1 and isAlt) or
                     (isAlt and altMergeCheckpoint and currentExpectedCheckpoint == altMergeCheckpoint)

  if isExpected then
    checkpointsHit = checkpointsHit + 1
    currCheckpoint = checkpointIndex
    mSplitTimes[checkpointsHit] = in_race_time
    utils.playCheckpointSound()

    if isAlt then
      currentExpectedCheckpoint = checkpointIndex
    end

    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)
    
    if isAlt and not mAltRoute then
      mAltRoute = true
      checkpointManager.setAltRoute(true)
      totalCheckpoints = checkpointManager.calculateTotalCheckpoints(race)
    end

    -- Display checkpoint message with distance info
    local checkpointMessage = ""
    local splitDiff = getDifference(raceName, checkpointsHit)
    
    -- Build distance suffix if track distances are available
    local distanceSuffix = ""
    if trackDistances and trackDistances.totalLength and trackDistances.totalLength > 0 then
      local completedDist = trackDistances.checkpointDistances and trackDistances.checkpointDistances[checkpointsHit] or 0
      distanceSuffix = string.format(" — %s / %s", 
        utils.formatDistance(completedDist), 
        utils.formatDistance(trackDistances.totalLength))
    end
    
    if splitDiff then
      local raceLabel = getCurrentRaceLabel()
      local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
      local totalDiff = in_race_time - (leaderboardEntry and leaderboardEntry.splitTimes and leaderboardEntry.splitTimes[checkpointsHit] or 0)

      checkpointMessage = string.format("Checkpoint %d/%d%s\nTime: %s | Split: %s | Total: %s",
        checkpointsHit, totalCheckpoints, distanceSuffix, utils.formatTime(in_race_time), formatSplitDifference(splitDiff),
        formatSplitDifference(totalDiff))
    else
      checkpointMessage = string.format("Checkpoint %d/%d%s\nTime: %s", checkpointsHit, totalCheckpoints,
        distanceSuffix, utils.formatTime(in_race_time))
    end
    utils.displayMessage(checkpointMessage, 7)
    Assets:displayAssets(data)
  else
    -- Handle missed checkpoints
    local missedCheckpoints = checkpointIndex - currentExpectedCheckpoint
    if missedCheckpoints > 0 then
      invalidLap = true

      currCheckpoint = checkpointIndex
      currentExpectedCheckpoint = currentExpectedCheckpoint + missedCheckpoints
      checkpointsHit = math.min(checkpointsHit + missedCheckpoints + 1, totalCheckpoints)

      currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)

      local message = string.format("Missed a checkpoint\nLap Invalidated.")
      local checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit, totalCheckpoints, utils.formatTime(in_race_time))
      message = message .. "\n" .. checkpointMessage
      utils.displayMessage(message, 10)
    end
  end
end

--- Handle finish trigger events
-- @param data table Trigger event data
-- @param raceName string The race name
local function handleFinish(data, raceName)
  if data.event == "enter" and mActiveRace == raceName then
    exitRace(true, nil, races[raceName], data.subjectID)
  end
end

--- Handle pits trigger events
-- @param data table Trigger event data
-- @param raceName string The race name
-- @param event string "enter" or "exit"
local function handlePits(data, raceName, event)
  if mActiveRace ~= raceName then
    return
  end

  local obj = be:getPlayerVehicle(0)
  
  if event == "enter" then
    if obj then
      obj:queueLuaCommand("obj:setGhostEnabled(true)")
    end
    if races[raceName].pitSpeedLimit then
      pits.stopThenLimit(races[raceName].pitSpeedLimit, races[raceName].pitSpeedLimitUnit)
    else
      pits.stopThenLimit(37, "MPH")
    end
  elseif event == "exit" then
    pits.toggleSpeedLimit()
    if obj then
      obj:queueLuaCommand("obj:setGhostEnabled(false)")
    end
  end
end

-- ============================================================================
-- MAIN TRIGGER HANDLER
-- ============================================================================

local function onBeamNGTrigger(data)
  if be:getPlayerVehicleID(0) ~= data.subjectID or isReplay then
    return
  end
  if gameplay_walk and gameplay_walk.isWalking() then 
    return 
  end
  
  -- Career mode vehicle checks
  if utils.isCareerActive() then
    local inventoryId = utils.getInventoryIdSafe(data.subjectID)
    if not inventoryId then
      return
    end
    local vehicles = career_modules_inventory.getVehicles()
    local vehicle = vehicles and vehicles[inventoryId]
    if vehicle and vehicle.loanType then
      return
    end
  end

  local triggerName = data.triggerName
  local event = data.event

  if not triggerName:match("^fre_") then
    return
  end

  -- Remove the 'fre_' prefix for processing
  triggerName = triggerName:sub(5)

  -- Extract trigger information
  local triggerType, raceName, rest = triggerName:match("^([^_]+)_([^_]+)(.*)$")

  if not triggerType or not raceName or not races or not races[raceName] then
    return
  end

  -- Process the rest of the trigger name
  local altFlag = nil
  local index = nil

  if rest ~= "" then
    rest = rest:gsub("^_+", "")

    if rest:sub(1, 3) == "alt" then
      altFlag = "alt"
      rest = rest:sub(4)
      rest = rest:gsub("^_+", "")
    end

    if rest ~= "" then
      index = rest
    end
  end

  local checkpointIndex = index and tonumber(index) or nil
  local isAlt = altFlag == "alt"

  -- Route to appropriate handler
  if triggerType == "staging" then
    handleStaging(data, raceName, event)
  elseif triggerType == "start" then
    handleStart(data, raceName, event)
  elseif triggerType == "checkpoint" and checkpointIndex then
    handleCheckpoint(data, raceName, checkpointIndex, isAlt)
  elseif triggerType == "finish" then
    handleFinish(data, raceName)
  elseif triggerType == "pits" then
    handlePits(data, raceName, event)
  end
end

-- ============================================================================
-- LIFECYCLE HOOKS
-- ============================================================================

local function onWorldReadyState(state)
  if state == 2 then
    races = utils.loadRaceData()
  end
end

local function loadExtensions()
  print("Initializing Freeroam Events Modules")

  local freeroamPath = "/lua/ge/extensions/gameplay/events/freeroam/"
  local files = FS:findFiles(freeroamPath, "*.lua", -1, true, false)
  
  if files then
    for _, filePath in ipairs(files) do
      local filename = string.match(filePath, "([^/]+)%.lua$")

      if filename then
        local extensionName = "gameplay_events_freeroam_" .. filename
        setExtensionUnloadMode(extensionName, "manual")
        extensions.unload(extensionName)
        table.insert(loadedExtensions, extensionName)
        print("Loaded extension: " .. extensionName)
      end
    end
  end
  loadManualUnloadExtensions()
end

local function unloadExtensions()
  for _, extensionName in ipairs(loadedExtensions) do
    extensions.unload(extensionName)
  end
end

local function onExtensionLoaded()
  print("Initializing Freeroam Events Main")
  loadExtensions()
  if getCurrentLevelIdentifier() then
    races = utils.loadRaceData()
    if races and next(races) then
      print("Race data loaded for level: " .. getCurrentLevelIdentifier())
    else
      print("No race data found for level: " .. getCurrentLevelIdentifier())
    end
  end
end

local function onExtensionUnloaded()
  unloadExtensions()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if mActiveRace and races and races[mActiveRace] and races[mActiveRace].checkpointRoad then
    if processRoad.checkPlayerOnRoad() == false then
      exitRace(false)
    end
    
    -- Calculate live distance if track distances are available
    if timerActive and trackDistances then
      local playerVehicle = be:getPlayerVehicle(0)
      if playerVehicle then
        local playerPos = playerVehicle:getPosition()
        local roadNodes = processRoad.getRoadNodes()
        if roadNodes and #roadNodes > 0 then
          liveDistanceInfo = processRoad.calculateLiveDistance(roadNodes, playerPos, trackDistances, currCheckpoint)
        end
      end
    end
  end
  
  if timerActive then
    in_race_time = in_race_time + dtSim
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId then
      local currentSpeed = math.abs(be:getObjectVelocityXYZ(playerVehicleId)) * utils.SPEED_UNIT_MPS_TO_MPH
      if currentSpeed > maxSpeed then
        maxSpeed = currentSpeed
      end
    end
  else
    in_race_time = 0
  end
end

-- ============================================================================
-- POI GENERATION
-- ============================================================================

local function formatEventPoi(raceName, race)
  local startObj = scenetree.findObject("fre_start_" .. raceName)
  local pos = startObj and startObj:getPosition() or nil
  
  if not pos then return nil end

  local levelIdentifier = getCurrentLevelIdentifier()
  local preview = "/levels/" .. levelIdentifier .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

  local vehId = be:getPlayerVehicleID(0) or 0
  local inventoryId = utils.getInventoryIdSafe(vehId) or vehId

  return {
    id = raceName,
    data = {
      type = "events",
      facility = {}
    },
    markerInfo = {
      bigmapMarker = {
        pos = pos,
        icon = "mission_cup_triangle",
        name = race.label,
        description = utils.displayStagedMessage(inventoryId, raceName, true),
        previews = {preview},
        thumbnail = preview
      }
    }
  }
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not races then
    return
  end
  for raceName, race in pairs(races) do
    local poi = formatEventPoi(raceName, race)
    if poi then
      table.insert(elements, poi)
    end
  end
end

-- ============================================================================
-- STATE CALLBACKS
-- ============================================================================

local function onReplayStateChanged(state)
  if not isReplay and state.state == "playback" then
    isReplay = true
  elseif isReplay and state.state == "inactive" then
    isReplay = false
  end
end

local function onGameStateUpdate(state)
  if saveGameState then
    saveGameState = false
    previousGameState = state
  end
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

M.onGameStateUpdate = onGameStateUpdate
M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

M.payoutRace = payoutRace
M.payoutDragRace = payoutDragRace
M.onWorldReadyState = onWorldReadyState
M.getRace = function(raceName) return races and races[raceName] or nil end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
