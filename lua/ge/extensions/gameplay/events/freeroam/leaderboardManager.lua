local M = {}

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local LEADERBOARD_FILE = "career/rls_career/races_leaderboard.json"

-- ============================================================================
-- STATE
-- ============================================================================

local leaderboard = {}
local level = nil

-- ============================================================================
-- CAREER HELPERS
-- ============================================================================

--- Safely check if career mode is active
-- @return boolean True if career mode is active
local function isCareerActive()
  return career_career and career_career.isActive() or false
end

-- ============================================================================
-- FILE OPERATIONS
-- ============================================================================

--- Load the leaderboard from file
local function loadLeaderboard()
  if not isCareerActive() then
    return
  end
  
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not savePath then
    return
  end
  
  local file = savePath .. '/' .. LEADERBOARD_FILE
  leaderboard = jsonReadFile(file) or {}
end

--- Save the leaderboard to file
-- @param currentSavePath string The save path
local function saveLeaderboard(currentSavePath)
  if not leaderboard then
    leaderboard = {}
  end
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/" .. LEADERBOARD_FILE, leaderboard, true)
end

-- ============================================================================
-- LEADERBOARD QUERIES
-- ============================================================================

--- Get a leaderboard entry for a specific vehicle and race
-- @param inventoryId number|string The vehicle inventory ID
-- @param raceLabel string The race label
-- @return table|nil The leaderboard entry or nil if not found
local function getLeaderboardEntry(inventoryId, raceLabel)
  level = getCurrentLevelIdentifier()
  if not level then
    return nil
  end
  
  if not leaderboard then
    leaderboard = {}
    return nil
  end
  
  if not leaderboard[level] then
    return nil
  end
  
  local levelData = leaderboard[level][tostring(inventoryId)]
  if not levelData then
    return nil
  end
  
  return levelData[raceLabel]
end

--- Check if a new entry would be a new best
-- @param entry table The new entry to check
-- @return boolean True if this is a new best
local function isBestTime(entry)
  level = getCurrentLevelIdentifier()
  if not level or not entry then
    return true
  end
  
  if not leaderboard then
    leaderboard = {}
    return true
  end
  
  local levelData = leaderboard[level]
  if not levelData then
    return true
  end

  local vehicleData = levelData[tostring(entry.inventoryId)]
  if not vehicleData then
    return true
  end

  local leaderboardEntry = vehicleData[entry.raceLabel]
  if not leaderboardEntry then
    return true
  end

  -- Handle drift score comparison
  if entry.driftScore and entry.driftScore > 0 then
    if not leaderboardEntry.driftScore then
      return true
    end
    return entry.driftScore > leaderboardEntry.driftScore
  end

  -- Handle top speed races
  if entry.topSpeed and entry.topSpeed > 0 then
    local utils = require('gameplay/events/freeroam/utils')
    local races = utils.loadRaceData()
    local race = races and races[entry.raceName]
    
    if race and race.topSpeed then
      if not leaderboardEntry.topSpeed then
        return true
      end
      return entry.topSpeed > leaderboardEntry.topSpeed
    end
  end

  -- Handle damage-based races
  if entry.damageFactor and entry.damageFactor > 0 then
    local utils = require('gameplay/events/freeroam/utils')
    local races = utils.loadRaceData()
    local race = races and races[entry.raceName]
    
    if not race then
      return true
    end
    
    local goalTime = race.bestTime
    local baseReward = race.reward
    
    -- Handle alt route and hotlap variations
    if entry.isAltRoute and race.altRoute then
      goalTime = race.altRoute.bestTime
      baseReward = race.altRoute.reward
    end
    if entry.isHotlap and race.hotlap then
      goalTime = race.hotlap
    end
    
    -- Calculate current entry's hybrid score
    local currentScore = utils.hybridRaceReward(goalTime, baseReward, entry.time, entry.damageFactor, entry.damagePercentage)
    
    if not leaderboardEntry.time then
      return true
    end
    
    local existingDamagePercentage = leaderboardEntry.damagePercentage or 0
    local existingScore = utils.hybridRaceReward(goalTime, baseReward, leaderboardEntry.time, entry.damageFactor, existingDamagePercentage)
    
    return currentScore > existingScore
  end

  -- Default time-based comparison
  if not leaderboardEntry.time then
    return true
  end
  
  return entry.time < leaderboardEntry.time
end

-- ============================================================================
-- LEADERBOARD MUTATIONS
-- ============================================================================

--- Add or update a leaderboard entry
-- @param entry table The entry to add
-- @return boolean True if this was a new best
local function addLeaderboardEntry(entry)
  if not entry then
    return false
  end
  
  level = getCurrentLevelIdentifier()
  if not level then
    return false
  end

  -- Save to career inventory if active
  if isCareerActive() and career_modules_inventory and career_modules_inventory.saveFRETimeToVehicle then
    career_modules_inventory.saveFRETimeToVehicle(entry.raceLabel, entry.inventoryId, entry.time, entry.driftScore)
  end
  
  -- Initialize nested tables
  if not leaderboard then
    leaderboard = {}
  end
  if not leaderboard[level] then 
    leaderboard[level] = {}
  end
  if not leaderboard[level][tostring(entry.inventoryId)] then
    leaderboard[level][tostring(entry.inventoryId)] = {}
  end
  
  local vehicleData = leaderboard[level][tostring(entry.inventoryId)]
  
  if isBestTime(entry) then
    local raceLabel = entry.raceLabel
    vehicleData[raceLabel] = vehicleData[raceLabel] or {}
    vehicleData[raceLabel].time = entry.time
    vehicleData[raceLabel].splitTimes = entry.splitTimes
    vehicleData[raceLabel].driftScore = entry.driftScore
    vehicleData[raceLabel].damagePercentage = entry.damagePercentage
    vehicleData[raceLabel].damageFactor = entry.damageFactor
    vehicleData[raceLabel].topSpeed = entry.topSpeed
    return true
  end
  
  return false
end

--- Clear all leaderboard entries for a specific vehicle
-- @param inventoryId number|string The vehicle inventory ID
local function clearLeaderboardForVehicle(inventoryId)
  level = getCurrentLevelIdentifier()
  if not level then
    return
  end
  
  if not leaderboard then
    leaderboard = {}
    return
  end
  
  if not leaderboard[level] then
    return
  end
  
  leaderboard[level][tostring(inventoryId)] = nil
end

-- ============================================================================
-- LIFECYCLE HOOKS
-- ============================================================================

local function onExtensionLoaded()
  print("Initializing Leaderboard Manager")
  level = getCurrentLevelIdentifier()
  if level then
    loadLeaderboard()
  end
end

local function onWorldReadyState(state)
  if state == 2 then
    level = getCurrentLevelIdentifier()
    loadLeaderboard()
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveLeaderboard(currentSavePath)
end

local function onCareerActive(active)
  if active then
    loadLeaderboard()
  else
    leaderboard = {}
  end
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

M.onVehicleRemoved = clearLeaderboardForVehicle
M.onCareerActive = onCareerActive
M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

M.addLeaderboardEntry = addLeaderboardEntry
M.isBestTime = isBestTime
M.getLeaderboardEntry = getLeaderboardEntry

return M
