-- World Editor Freeroam Event Creator
-- Improved version with alt routes, validation, reward graphs, and UI polish

local M = {}
local logTag = 'editor_freeroamEventEditor'
local im = ui_imgui
local ffi = require("ffi")
local toolWindowName = "editor_freeroamEventEditor_window"

local processRoad = require('gameplay/events/freeroam/processRoad')
local checkpointManager = require('gameplay/events/freeroam/checkpointManager')
local utils = require('gameplay/events/freeroam/utils')

-- ============================================================================
-- STATE VARIABLES
-- ============================================================================

local races = {}
local currentRaceName = nil
local modified = false
local raceTypes = {"motorsport", "drift", "drag", "offroad", "rally"}
local levelTriggers = {}
local levelDecalRoads = {}
local pendingTriggerType = nil
local pendingTriggerRace = nil
local pendingTriggerName = nil
local showTriggerPlacementHelp = false
local showingRaceCheckpoints = false
local showingCheckpointsEditor = false
local checkpoints = {}
local altCheckpoints = {}
local roadNodes = {}
local altRoadNodes = {}

-- Reward calculator state
local bestTimeSession = im.BoolPtr(false)
local inRange = im.BoolPtr(false)
local realTime = im.FloatPtr(60)
local driftScore = im.IntPtr(1000)
local lapCount = im.IntPtr(1)
local hardcore = im.BoolPtr(false)
local damagePercentage = im.FloatPtr(0.0)
local topSpeedPreview = im.FloatPtr(100)

local lookingForRoad = false
local roadFilterText = ""
local eventFilterText = ""

-- Validation state
local showValidationModal = false
local validationIssues = {}

-- ============================================================================
-- UI COLORS
-- ============================================================================

local colors = {
  success = im.ImVec4(0.2, 0.8, 0.2, 1.0),
  warning = im.ImVec4(1.0, 0.8, 0.2, 1.0),
  error = im.ImVec4(0.9, 0.2, 0.2, 1.0),
  info = im.ImVec4(0.4, 0.7, 1.0, 1.0),
  dimmed = im.ImVec4(0.6, 0.6, 0.6, 1.0),
  highlight = im.ImVec4(0.95, 0.43, 0.49, 1.0),
}

-- ============================================================================
-- TEMPLATE
-- ============================================================================

local raceTemplate = {
  bestTime = 60,
  reward = 1000,
  label = "New Event",
  checkpointRoad = nil,
  type = {"motorsport"},
  timeout = 10
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function tableContains(tbl, val)
  if not tbl then return false end
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

local function tableIndexOf(tbl, value)
  for i, v in ipairs(tbl) do
    if v == value then return i end
  end
  return nil
end

local function countTableEntries(t)
  local count = 0
  if t then
    for _ in pairs(t) do count = count + 1 end
  end
  return count
end

-- Deep copy a table (handles nested tables)
local function deepCopyTable(orig)
  local copy
  if type(orig) == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[deepCopyTable(orig_key)] = deepCopyTable(orig_value)
    end
    setmetatable(copy, deepCopyTable(getmetatable(orig)))
  else
    copy = orig
  end
  return copy
end

-- ============================================================================
-- HELP POPUP HELPER
-- ============================================================================

local function helpMarker(text, sameLine)
  if sameLine then im.SameLine() end
  im.TextDisabled("(?)")
  if im.IsItemHovered() then
    im.BeginTooltip()
    im.PushTextWrapPos(im.GetFontSize() * 25)
    im.TextUnformatted(text)
    im.PopTextWrapPos()
    im.EndTooltip()
  end
end

-- ============================================================================
-- RACE DATA MANAGEMENT
-- ============================================================================

local function createNewRace()
  local newRaceName = "event_" .. os.time()
  races[newRaceName] = deepCopyTable(raceTemplate)
  races[newRaceName].label = "New Event"
  currentRaceName = newRaceName
  modified = true
  log('I', logTag, "Created new event: " .. newRaceName)
  return newRaceName
end

local function duplicateRace(raceName)
  if not raceName or not races[raceName] then return nil end
  local newRaceName = raceName .. "_copy_" .. os.time()
  races[newRaceName] = deepCopyTable(races[raceName])
  races[newRaceName].label = (races[raceName].label or "Event") .. " (Copy)"
  currentRaceName = newRaceName
  modified = true
  log('I', logTag, "Duplicated event: " .. raceName .. " -> " .. newRaceName)
  return newRaceName
end

local function loadRaceData()
  local level = getCurrentLevelIdentifier()
  if not level then return end
  
  local filePath = "levels/" .. level .. "/race_data.json"
  local raceData = jsonReadFile(filePath) or {races = {}}
  races = raceData.races or {}
  modified = false

  for raceName, race in pairs(races) do
    for _, rType in ipairs(race.type or {}) do
      if not tableContains(raceTypes, rType) then
        table.insert(raceTypes, rType)
      end
    end
  end
  
  log('I', logTag, "Loaded race data for level: " .. level)
end

local function saveRaceData()
  local level = getCurrentLevelIdentifier()
  if not level then 
    log('E', logTag, "No level loaded!")
    return 
  end
  
  local filePath = "levels/" .. level .. "/race_data.json"
  local raceData = {races = races}
  jsonWriteFile(filePath, raceData, true)
  modified = false
  log('I', logTag, "Saved race data to: " .. filePath)
end

local function createNewRaceData()
  races = {}
  currentRaceName = nil
  modified = true
  log('I', logTag, "Created new race data")
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

local function validateRoad(roadName)
  if not roadName or roadName == "" then return false end
  return tableContains(levelDecalRoads, roadName)
end

local function validateCheckpointRoads(race)
  if not race.checkpointRoad then return false, "No checkpoint road set" end
  
  if type(race.checkpointRoad) == "string" then
    if not validateRoad(race.checkpointRoad) then
      return false, "Road '" .. race.checkpointRoad .. "' does not exist"
    end
  elseif type(race.checkpointRoad) == "table" then
    if #race.checkpointRoad == 0 then
      return false, "No checkpoint roads set"
    end
    for _, roadName in ipairs(race.checkpointRoad) do
      if roadName ~= "" and not validateRoad(roadName) then
        return false, "Road '" .. roadName .. "' does not exist"
      end
    end
  end
  
  return true, nil
end

local function triggerExists(prefix, raceName)
  return scenetree.findObject(prefix .. raceName) ~= nil
end

local function isRaceComplete(raceName, race)
  local hasCheckpointRoad = race.checkpointRoad ~= nil
  if type(race.checkpointRoad) == "table" then
    hasCheckpointRoad = #race.checkpointRoad > 0 and race.checkpointRoad[1] ~= ""
  elseif type(race.checkpointRoad) == "string" then
    hasCheckpointRoad = race.checkpointRoad ~= ""
  end
  
  local hasStartTrigger = triggerExists("fre_start_", raceName)
  local hasStagingTrigger = triggerExists("fre_staging_", raceName)
  
  local hasPitTrigger = true
  if race.hasPits then
    hasPitTrigger = triggerExists("fre_pits_", raceName)
  end
  
  if not race.hotlap then
    local hasFinishTrigger = triggerExists("fre_finish_", raceName)
    return hasCheckpointRoad and hasStartTrigger and hasStagingTrigger and hasFinishTrigger and hasPitTrigger
  else
    return hasCheckpointRoad and hasStartTrigger and hasStagingTrigger and hasPitTrigger
  end
end

local function getMissingComponents(raceName, race)
  local missing = {}
  
  if not race.checkpointRoad or race.checkpointRoad == "" then
    table.insert(missing, "Checkpoint road")
  elseif type(race.checkpointRoad) == "table" and #race.checkpointRoad == 0 then
    table.insert(missing, "Checkpoint road")
  end
  
  if not triggerExists("fre_start_", raceName) then
    table.insert(missing, "Start trigger")
  end
  
  if not triggerExists("fre_staging_", raceName) then
    table.insert(missing, "Staging trigger")
  end
  
  if not race.hotlap then
    if not triggerExists("fre_finish_", raceName) then
      table.insert(missing, "Finish trigger")
    end
  end
  
  if race.hasPits and not triggerExists("fre_pits_", raceName) then
    table.insert(missing, "Pit trigger")
  end
  
  return missing
end

local function getEventCompleteness(raceName, race)
  local components = {
    {name = "Checkpoint Road", done = race.checkpointRoad ~= nil and race.checkpointRoad ~= ""},
    {name = "Start Trigger", done = triggerExists("fre_start_", raceName)},
    {name = "Staging Trigger", done = triggerExists("fre_staging_", raceName)},
    {name = "Event Type", done = race.type and #race.type > 0},
    {name = "Best Time", done = race.bestTime and race.bestTime > 0},
    {name = "Reward", done = race.reward and race.reward > 0},
  }
  
  if not race.hotlap then
    table.insert(components, 3, {name = "Finish Trigger", done = triggerExists("fre_finish_", raceName)})
  end
  
  if race.hasPits then
    table.insert(components, {name = "Pit Trigger", done = triggerExists("fre_pits_", raceName)})
  end
  
  local done = 0
  for _, c in ipairs(components) do
    if c.done then done = done + 1 end
  end
  
  return done, #components, components
end

local function validateAllEvents()
  local issues = {}
  
  for raceName, race in pairs(races) do
    local eventIssues = {}
    
    -- Check types
    if not race.type or #race.type == 0 then
      table.insert(eventIssues, "No event types selected")
    end
    
    -- Check checkpoint road
    local roadValid, roadError = validateCheckpointRoads(race)
    if not roadValid then
      table.insert(eventIssues, roadError)
    end
    
    -- Check triggers
    if not triggerExists("fre_start_", raceName) then
      table.insert(eventIssues, "Missing start trigger")
    end
    if not triggerExists("fre_staging_", raceName) then
      table.insert(eventIssues, "Missing staging trigger")
    end
    if not race.hotlap and not triggerExists("fre_finish_", raceName) then
      table.insert(eventIssues, "Missing finish trigger")
    end
    if race.hasPits and not triggerExists("fre_pits_", raceName) then
      table.insert(eventIssues, "Missing pit trigger")
    end
    
    -- Check reward sanity
    if race.reward and race.bestTime then
      local testReward = utils.raceReward(race.bestTime, race.reward, race.bestTime, race.type)
      if testReward <= 0 then
        table.insert(eventIssues, "Reward calculation returns 0 or negative for target time")
      end
    end
    
    -- Check best time
    if not race.bestTime or race.bestTime <= 0 then
      table.insert(eventIssues, "Invalid best time")
    end
    
    -- Check reward
    if not race.reward or race.reward <= 0 then
      table.insert(eventIssues, "Invalid reward amount")
    end
    
    if #eventIssues > 0 then
      issues[raceName] = {
        label = race.label or raceName,
        issues = eventIssues
      }
    end
  end
  
  return issues
end

-- ============================================================================
-- CHECKPOINT AND ROAD VISUALIZATION
-- ============================================================================

local function showRaceCheckpoints()
  if not currentRaceName then return end

  checkpoints, altCheckpoints = processRoad.getCheckpoints(races[currentRaceName])
  checkpointManager.createCheckpoints(checkpoints, altCheckpoints)

  -- Get road nodes for visualization and distance calculation
  roadNodes = processRoad.getRoadNodes() or processRoad.getRoadNodesFromRace(races[currentRaceName])
  if races[currentRaceName].altRoute then
    altRoadNodes = processRoad.getAltRoadNodes() or processRoad.getRoadNodesFromRace(races[currentRaceName].altRoute)
  else
    altRoadNodes = {}
  end
end

local function removeRaceCheckpoints()
  checkpointManager.removeCheckpoints()
  processRoad.reset()
  roadNodes = {}
  altRoadNodes = {}
end

local function drawRoadPath()
  if not showingRaceCheckpoints then return end
  
  local lineWidth = editor.getPreference("gizmos.general.lineThicknessScale") * 2 or 2
  
  -- Draw main route in green
  if roadNodes and #roadNodes > 1 then
    for i = 1, #roadNodes - 1 do
      local p1 = roadNodes[i]
      local p2 = roadNodes[i + 1]
      if p1 and p2 and p1.pos and p2.pos then
        debugDrawer:drawLineInstance(p1.pos, p2.pos, lineWidth, ColorF(0.2, 0.9, 0.2, 0.8))
      end
    end
  end
  
  -- Draw alt route in blue
  if altRoadNodes and #altRoadNodes > 1 then
    for i = 1, #altRoadNodes - 1 do
      local p1 = altRoadNodes[i]
      local p2 = altRoadNodes[i + 1]
      if p1 and p2 and p1.pos and p2.pos then
        debugDrawer:drawLineInstance(p1.pos, p2.pos, lineWidth, ColorF(0.2, 0.5, 0.9, 0.8))
      end
    end
  end
end

-- ============================================================================
-- LEVEL OBJECTS
-- ============================================================================

local function findLevelObjects()
  levelTriggers = {}
  levelDecalRoads = {}
  
  local missionGroup = scenetree.findObject("MissionGroup")
  if not missionGroup then return end
  
  local function searchObjects(group)
    for i, objName in ipairs(group:getObjects()) do
      local obj = scenetree.findObject(objName)
      if obj then
        if obj:getClassName() == "BeamNGTrigger" then
          table.insert(levelTriggers, obj:getName())
        elseif obj:getClassName() == "DecalRoad" then
          table.insert(levelDecalRoads, obj:getName())
        end
        if obj:getClassName() == "SimGroup" then
          searchObjects(obj)
        end
      end
    end
  end
  
  searchObjects(missionGroup)
end

local function findDecalRoads()
  levelDecalRoads = {}
  local missionGroup = scenetree.findObject("MissionGroup")
  if not missionGroup then return end

  local function searchObjects(group)
    for i, objName in ipairs(group:getObjects()) do
      local obj = scenetree.findObject(objName)
      if obj then
        if obj:getClassName() == "DecalRoad" then
          table.insert(levelDecalRoads, obj:getName())
        end
        if obj:getClassName() == "SimGroup" then
          searchObjects(obj)
        end
      end
    end
  end
  
  searchObjects(missionGroup)
end

-- ============================================================================
-- TRIGGER MANAGEMENT
-- ============================================================================

local function triggerPlacementUpdate()
  if not pendingTriggerType or not pendingTriggerRace then return end
  
  local hit = cameraMouseRayCast(true)
  local pos = vec3(worldEditorCppApi.snapPositionToGrid(hit.pos))
  local lineWidth = editor.getPreference("gizmos.general.lineThicknessScale") * 4
  
  debugDrawer:drawLineInstance((pos - vec3(2, 0, 0)), (pos + vec3(2, 0, 0)), lineWidth, ColorF(1, 0, 0, 1))
  debugDrawer:drawLineInstance((pos - vec3(0, 2, 0)), (pos + vec3(0, 2, 0)), lineWidth, ColorF(0, 1, 0, 1))
  debugDrawer:drawLineInstance((pos - vec3(0, 0, 2)), (pos + vec3(0, 0, 2)), lineWidth, ColorF(0, 0, 1, 1))
  
  if im.IsMouseClicked(0) and editor.isViewportHovered() then
    local prefix
    if pendingTriggerType == "start" then prefix = "fre_start_"
    elseif pendingTriggerType == "staging" then prefix = "fre_staging_"
    elseif pendingTriggerType == "finish" then prefix = "fre_finish_"
    elseif pendingTriggerType == "pit" then prefix = "fre_pits_"
    end
    
    local triggerName = prefix .. pendingTriggerRace
    
    local obj = worldEditorCppApi.createObject("BeamNGTrigger")
    if obj then
      obj:setName(triggerName)
      obj:registerObject("")
      obj:setPosition(pos)
      
      local parent = scenetree.MissionGroup
      local selection = editor.selection
      if selection and selection.object and #selection.object > 0 then
        local sel = scenetree.findObjectById(selection.object[1])
        if sel and sel:isSubClassOf("SimGroup") then
          parent = sel
        elseif sel then
          local group = sel:getGroup()
          if group and group:getName() ~= "MissionCleanup" then
            parent = group
          end
        end
      end
      
      if parent then
        parent:addObject(obj)
      end
      
      editor.selectObjectById(obj:getID())
      
      if levelTriggers then
        table.insert(levelTriggers, triggerName)
      end
      
      log('I', logTag, "Created new trigger: " .. triggerName)
      
      pendingTriggerType = nil
      pendingTriggerRace = nil
      showTriggerPlacementHelp = false
    end
  end
end

local function createOrSelectTrigger(triggerType, raceName)
  if not raceName then return end
  
  local prefix
  if triggerType == "start" then prefix = "fre_start_"
  elseif triggerType == "staging" then prefix = "fre_staging_"
  elseif triggerType == "finish" then prefix = "fre_finish_"
  elseif triggerType == "pit" then prefix = "fre_pits_"
  end
  
  local triggerName = prefix .. raceName
  local existingTrigger = scenetree.findObject(triggerName)
  
  if existingTrigger then
    editor.selectObjectById(existingTrigger:getID())
    log('I', logTag, "Selected trigger: " .. triggerName)
  else
    pendingTriggerType = triggerType
    pendingTriggerRace = raceName
    showTriggerPlacementHelp = true
    log('I', logTag, "Ready to place " .. triggerType .. " trigger for race: " .. raceName)
    editor.showNotification("Click on the map to place " .. triggerType .. " trigger")
  end
end

local function getTriggerInfo(triggerName)
  local trigger = scenetree.findObject(triggerName)
  if not trigger then return nil end
  
  local pos = trigger:getPosition()
  local scale = trigger:getScale()
  
  return {
    position = pos,
    scale = scale,
    obj = trigger
  }
end

-- ============================================================================
-- EVENT TESTING
-- ============================================================================

local function teleportToStart(raceName)
  if not raceName then return end
  
  local stagingTrigger = scenetree.findObject("fre_staging_" .. raceName)
  local startTrigger = scenetree.findObject("fre_start_" .. raceName)
  
  -- Need at least one trigger to teleport to
  local targetTrigger = stagingTrigger or startTrigger
  if not targetTrigger then
    editor.showNotification("No staging or start trigger found for this event")
    return
  end
  
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then
    editor.showNotification("No player vehicle found")
    return
  end
  
  if stagingTrigger and startTrigger then
    -- Both exist: position behind staging, facing toward start
    local stagingPos = stagingTrigger:getPosition()
    local startPos = startTrigger:getPosition()
    
    -- Direction from staging to start
    local dir = (startPos - stagingPos)
    dir.z = 0
    dir = dir:normalized()
    
    -- Place vehicle behind staging (offset back along the approach direction)
    local stagingScale = stagingTrigger:getScale()
    local offset = math.max(stagingScale.x, stagingScale.y) + 8 -- behind staging zone + some room
    local spawnPos = stagingPos - dir * offset
    
    -- Snap to ground using surface height
    spawnPos.z = be:getSurfaceHeightBelow(spawnPos + vec3(0, 0, 10)) + 0.5
    
    -- quatFromDir uses -Y as forward in BeamNG, so negate dir to face toward start
    local up = vec3(0, 0, 1)
    local rot = quatFromDir(-dir, up)
    
    playerVeh:setPositionRotation(spawnPos.x, spawnPos.y, spawnPos.z, rot.x, rot.y, rot.z, rot.w)
    editor.showNotification("Teleported behind staging, facing start")
  else
    -- Only one trigger exists, teleport near it
    local pos = targetTrigger:getPosition()
    pos.z = be:getSurfaceHeightBelow(pos + vec3(0, 0, 10)) + 0.5
    local rot = targetTrigger:getRotation()
    playerVeh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    editor.showNotification("Teleported to " .. (stagingTrigger and "staging" or "start") .. " trigger")
  end
end

local function deleteTrigger(triggerType, raceName)
  if not raceName then return end
  
  local prefix
  if triggerType == "start" then prefix = "fre_start_"
  elseif triggerType == "staging" then prefix = "fre_staging_"
  elseif triggerType == "finish" then prefix = "fre_finish_"
  elseif triggerType == "pit" then prefix = "fre_pits_"
  end
  
  local triggerName = prefix .. raceName
  local trigger = scenetree.findObject(triggerName)
  if trigger then
    trigger:delete()
    -- Remove from cached trigger list
    if levelTriggers then
      for i, name in ipairs(levelTriggers) do
        if name == triggerName then
          table.remove(levelTriggers, i)
          break
        end
      end
    end
    editor.showNotification("Deleted " .. triggerType .. " trigger")
    log('I', logTag, "Deleted trigger: " .. triggerName)
  end
end

local function cloneTriggerAs(sourceType, targetType, raceName)
  if not raceName then return end
  
  local sourcePrefix = sourceType == "start" and "fre_start_" or "fre_staging_"
  local targetPrefix = targetType == "start" and "fre_start_" or "fre_staging_"
  
  local sourceTrigger = scenetree.findObject(sourcePrefix .. raceName)
  if not sourceTrigger then
    editor.showNotification("Source trigger not found")
    return
  end
  
  local pos = sourceTrigger:getPosition()
  local rot = sourceTrigger:getRotation()
  local scale = sourceTrigger:getScale()
  
  -- Offset the clone along the trigger's forward direction
  -- Staging goes behind start, start goes ahead of staging
  local fwd = rot * vec3(0, 1, 0) -- trigger's forward axis
  local spacing = math.max(scale.x, scale.y) + 5 -- trigger size + gap
  if targetType == "staging" then
    -- Staging behind start: offset backward
    pos = pos - fwd * spacing
  else
    -- Start ahead of staging: offset forward
    pos = pos + fwd * spacing
  end
  
  local triggerName = targetPrefix .. raceName
  local obj = worldEditorCppApi.createObject("BeamNGTrigger")
  if obj then
    obj:setName(triggerName)
    obj:registerObject("")
    obj:setPosition(pos)
    obj:setRotation(rot)
    obj:setScale(scale)
    
    -- Add to same parent group as source
    local sourceGroup = sourceTrigger:getGroup()
    if sourceGroup then
      sourceGroup:addObject(obj)
    else
      local parent = scenetree.MissionGroup
      if parent then parent:addObject(obj) end
    end
    
    if levelTriggers then
      table.insert(levelTriggers, triggerName)
    end
    
    editor.selectObjectById(obj:getID())
    editor.showNotification("Cloned " .. sourceType .. " as " .. targetType .. " trigger")
    log('I', logTag, "Cloned trigger: " .. sourcePrefix .. raceName .. " -> " .. triggerName)
  end
end

-- ============================================================================
-- CHECKPOINTS EDITOR
-- ============================================================================

local function showCheckpointsEditor(race)
  if not showingCheckpointsEditor then return end
  if not race.checkpointIndexs then 
    race.checkpointIndexs = {}
    for i, checkpoint in ipairs(checkpoints) do
      race.checkpointIndexs[i] = checkpoint.index
    end
  end

  im.TextColored(colors.info, "Manual Checkpoint Editing")
  if im.CollapsingHeader1("Checkpoints##manual") then
    for i, checkpoint in ipairs(checkpoints) do
      im.PushID1("checkpoint_" .. tostring(i))
      
      im.Text("Checkpoint " .. tostring(i))
      im.SameLine()

      if im.Button("X##remove", im.ImVec2(24, 0)) then
        table.remove(race.checkpointIndexs, i)
        removeRaceCheckpoints()
        showRaceCheckpoints()
        im.PopID()
        break
      end
      im.SameLine()
      
      im.SetNextItemWidth(im.GetContentRegionAvail().x * 0.5)
      local index = im.IntPtr(race.checkpointIndexs[i] or 0)
      if im.InputInt("##Index", index, 1, 10) then
        race.checkpointIndexs[i] = index[0]
        removeRaceCheckpoints()
        showRaceCheckpoints()
      end
      im.SameLine()

      if im.Button("Add##add", im.ImVec2(60, 0)) then
        table.insert(race.checkpointIndexs, i + 1, (race.checkpointIndexs[i] or 0) + 1)
        removeRaceCheckpoints()
        showRaceCheckpoints()
        im.PopID()
        break
      end
      
      im.PopID()
    end
  end
end

-- ============================================================================
-- ROAD SELECTOR UI COMPONENT
-- ============================================================================

local function drawRoadSelector(label, roads, index, filterText, onChanged)
  local currentRoad = roads[index] or "Choose a road"
  local comboLabel = label .. "##" .. tostring(index)
  
  -- Validate road exists
  local roadValid = currentRoad == "Choose a road" or validateRoad(currentRoad)
  
  if not roadValid then
    im.PushStyleColor2(im.Col_FrameBg, im.ImVec4(0.5, 0.1, 0.1, 1))
  end
  
  if im.BeginCombo(comboLabel, currentRoad) then
    lookingForRoad = true
    local filterLower = filterText:lower()
    local foundAny = false
    
    if currentRoad ~= "Choose a road" then
      if filterLower == "" or string.find(currentRoad:lower(), filterLower) then
        if im.Selectable1(currentRoad .. " (current)", true) then end
        im.Separator()
        foundAny = true
      end
    end
    
    for _, availableRoad in ipairs(levelDecalRoads) do
      if availableRoad == "" then goto continue end
      if filterLower ~= "" and not string.find(availableRoad:lower(), filterLower) then
        goto continue
      end
      
      foundAny = true
      if im.Selectable1(availableRoad, availableRoad == currentRoad) then
        roads[index] = availableRoad
        if onChanged then onChanged() end
      end
      ::continue::
    end
    
    if not foundAny then
      im.TextColored(colors.dimmed, "No roads match your filter")
    end
    
    im.EndCombo()
  else
    lookingForRoad = false
  end
  
  if not roadValid then
    im.PopStyleColor()
    im.SameLine()
    im.TextColored(colors.error, "!")
    if im.IsItemHovered() then
      im.SetTooltip("Road does not exist in this level")
    end
  end
end

-- ============================================================================
-- REWARD CURVE VISUALIZATION
-- ============================================================================

--- Format a dollar amount as a readable string (no scientific notation)
local function formatMoney(amount)
  amount = math.floor(amount + 0.5)
  if amount >= 1000000 then
    return string.format("$%.1fM", amount / 1000000)
  elseif amount >= 1000 then
    return string.format("$%dk", math.floor(amount / 1000))
  else
    return string.format("$%d", amount)
  end
end

--- Draw a PlotLines graph with readable Y-axis labels instead of scientific notation
local function drawPlot(label, dataTable, overlayMax, graphHeight)
  local data = im.TableToArrayFloat(dataTable)
  local dataLen = im.GetLengthArrayFloat(data)
  local scaleMax = math.max(overlayMax * 1.1, 1)
  
  -- Draw the plot with no overlay text (we'll add our own labels)
  im.PlotLines1(label, data, dataLen, 0, "", 0, scaleMax, im.ImVec2(im.GetContentRegionAvail().x, graphHeight))
  
  -- Draw Y-axis labels above the graph
  local cursorY = im.GetCursorPosY()
  im.SetCursorPosY(cursorY - graphHeight - 2)
  im.TextColored(colors.dimmed, formatMoney(overlayMax))
  im.SetCursorPosY(cursorY - 18)
  im.TextColored(colors.dimmed, "$0")
  im.SetCursorPosY(cursorY)
end

local function drawRewardCurve(race)
  if not race.bestTime or not race.reward then return end
  
  local rewardCap = race.reward * 30  -- MAX_REWARD_MULTIPLIER from utils
  local numPoints = 50
  
  -- For damage-based events, show TWO curves: one for time (at current damage%), one for damage (at current time)
  if race.damageFactor and race.damageFactor > 0 then
    -- Time curve (varying time at fixed damage)
    local timeTable = {}
    local minTime = race.bestTime * 0.5
    local maxTime = race.bestTime * 2.0
    local timeStep = (maxTime - minTime) / (numPoints - 1)
    local maxReward = 0
    
    for i = 0, numPoints - 1 do
      local time = minTime + (i * timeStep)
      local reward = utils.hybridRaceReward(race.bestTime, race.reward, time, race.damageFactor, damagePercentage[0], race.type)
      reward = math.min(reward, rewardCap)
      timeTable[i + 1] = reward
      if reward > maxReward then maxReward = reward end
    end
    
    -- Damage curve (varying damage at fixed time)
    local damageTable = {}
    local damageStep = 1.0 / (numPoints - 1)
    local maxDamageReward = 0
    
    for i = 0, numPoints - 1 do
      local dmg = i * damageStep
      local reward = utils.hybridRaceReward(race.bestTime, race.reward, realTime[0] > 0 and realTime[0] or race.bestTime, race.damageFactor, dmg, race.type)
      reward = math.min(reward, rewardCap)
      damageTable[i + 1] = reward
      if reward > maxDamageReward then maxDamageReward = reward end
    end
    
    im.Text(string.format("Reward vs Time (at %.0f%% damage, factor: %.2f)", damagePercentage[0] * 100, race.damageFactor))
    drawPlot("##RewardTime", timeTable, maxReward, 120)
    im.TextColored(colors.dimmed, string.format("%.1fs", minTime))
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.45)
    im.TextColored(colors.dimmed, string.format("%.1fs (target)", race.bestTime))
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.85)
    im.TextColored(colors.dimmed, string.format("%.1fs", maxTime))
    
    im.Spacing()
    
    local previewTime = realTime[0] > 0 and realTime[0] or race.bestTime
    im.Text(string.format("Reward vs Damage (at %.1fs, factor: %.2f)", previewTime, race.damageFactor))
    drawPlot("##RewardDamage", damageTable, maxDamageReward, 120)
    im.TextColored(colors.dimmed, "0% damage")
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.85)
    im.TextColored(colors.dimmed, "100% damage")
    
    -- Preview with readable numbers
    local previewReward = utils.hybridRaceReward(race.bestTime, race.reward, realTime[0], race.damageFactor, damagePercentage[0], race.type)
    previewReward = math.min(previewReward, rewardCap)
    im.TextColored(colors.info, string.format("Preview: %.1fs at %.0f%% damage = %s", realTime[0], damagePercentage[0] * 100, formatMoney(previewReward)))
    im.TextColored(colors.dimmed, string.format("Reward cap: %s | Base: %s", formatMoney(rewardCap), formatMoney(race.reward)))
    return
  end
  
  -- Standard curve for non-damage events
  local rewardTable = {}
  local minTime, maxTime, timeStep
  local maxReward = 0
  local previewReward = 0
  
  if race.topSpeed then
    -- For top speed: X axis = speed, not time
    local goalSpeed = race.topSpeedGoal or 100
    local minSpeed = goalSpeed * 0.5
    local maxSpeed = goalSpeed * 2.0
    local speedStep = (maxSpeed - minSpeed) / (numPoints - 1)
    
    for i = 0, numPoints - 1 do
      local speed = minSpeed + (i * speedStep)
      local reward = utils.topSpeedReward(goalSpeed, race.reward, speed, race.type)
      reward = math.min(reward, rewardCap)
      rewardTable[i + 1] = reward
      if reward > maxReward then maxReward = reward end
    end
    
    previewReward = utils.topSpeedReward(race.topSpeedGoal or 100, race.reward, topSpeedPreview[0], race.type)
    previewReward = math.min(previewReward, rewardCap)
    
    im.Text("Reward Curve (Speed vs Reward)")
    drawPlot("##RewardCurve", rewardTable, maxReward, 150)
    im.TextColored(colors.dimmed, string.format("%.0f mph", (race.topSpeedGoal or 100) * 0.5))
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.4)
    im.TextColored(colors.dimmed, string.format("%.0f mph (target)", race.topSpeedGoal or 100))
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.85)
    im.TextColored(colors.dimmed, string.format("%.0f mph", (race.topSpeedGoal or 100) * 2))
    im.TextColored(colors.info, string.format("Preview: %.0f mph = %s", topSpeedPreview[0], formatMoney(previewReward)))
  else
    -- Time-based (standard or drift)
    minTime = race.bestTime * 0.5
    maxTime = race.bestTime * 2.0
    timeStep = (maxTime - minTime) / (numPoints - 1)
    
    for i = 0, numPoints - 1 do
      local time = minTime + (i * timeStep)
      local reward
      if race.driftGoal then
        reward = utils.driftReward(race, time, driftScore[0])
      else
        reward = utils.raceReward(race.bestTime, race.reward, time, race.type)
      end
      reward = math.min(reward, rewardCap)
      rewardTable[i + 1] = reward
      if reward > maxReward then maxReward = reward end
    end
    
    if race.driftGoal then
      previewReward = utils.driftReward(race, realTime[0], driftScore[0])
    else
      previewReward = utils.raceReward(race.bestTime, race.reward, realTime[0], race.type)
    end
    previewReward = math.min(previewReward, rewardCap)
    
    im.Text("Reward Curve (Time vs Reward)")
    drawPlot("##RewardCurve", rewardTable, maxReward, 150)
    im.TextColored(colors.dimmed, string.format("%.1fs", minTime))
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.45)
    im.TextColored(colors.dimmed, string.format("%.1fs (target)", race.bestTime))
    im.SameLine()
    im.SetCursorPosX(im.GetContentRegionAvail().x * 0.85)
    im.TextColored(colors.dimmed, string.format("%.1fs", maxTime))
    im.TextColored(colors.info, string.format("Preview: %.1fs = %s", realTime[0], formatMoney(previewReward)))
  end
  
  im.TextColored(colors.dimmed, string.format("Reward cap: %s", formatMoney(rewardCap)))
end

-- ============================================================================
-- ALT ROUTE EDITOR
-- ============================================================================

local altRoadFilterText = ""

local function drawAltRouteEditor(race, changed)
  im.SeparatorText("Alternative Route")
  
  local hasAltRoute = im.BoolPtr(race.altRoute ~= nil)
  if im.Checkbox("Enable Alternative Route", hasAltRoute) then
    if hasAltRoute[0] then
      race.altRoute = {
        checkpointRoad = {},
        bestTime = race.bestTime,
        reward = race.reward,
        mergeCheckpoints = {}
      }
    else
      race.altRoute = nil
    end
    return true
  end
  
  if not race.altRoute then return changed end
  
  local alt = race.altRoute
  
  -- Alt Route Label
  local altLabel = im.ArrayChar(128, alt.label or "")
  if im.InputText("Alt Route Label", altLabel) then
    alt.label = ffi.string(altLabel)
    changed = true
  end
  
  -- Alt Best Time
  local altBestTime = im.FloatPtr(alt.bestTime or race.bestTime)
  if im.InputFloat("Alt Best Time (seconds)", altBestTime, 1, 5, "%.1f") then
    alt.bestTime = altBestTime[0]
    changed = true
  end
  
  -- Alt Reward
  local altReward = im.IntPtr(alt.reward or race.reward)
  if im.InputInt("Alt Reward ($)", altReward, 100, 1000) then
    alt.reward = altReward[0]
    changed = true
  end
  
  -- Alt Hotlap Time
  local hasAltHotlap = im.BoolPtr(alt.hotlap ~= nil)
  if im.Checkbox("Alt Route Hotlap", hasAltHotlap) then
    if hasAltHotlap[0] then
      alt.hotlap = alt.bestTime * 0.9
    else
      alt.hotlap = nil
    end
    changed = true
  end
  
  if alt.hotlap then
    local altHotlap = im.FloatPtr(alt.hotlap)
    if im.InputFloat("Alt Hotlap Time (seconds)", altHotlap, 1, 5, "%.1f") then
      alt.hotlap = altHotlap[0]
      changed = true
    end
  end
  
  -- Alt Damage Factor
  local hasAltDamageFactor = im.BoolPtr(alt.damageFactor ~= nil)
  if im.Checkbox("Alt Damage Factor", hasAltDamageFactor) then
    if hasAltDamageFactor[0] then
      alt.damageFactor = 0.5
    else
      alt.damageFactor = nil
    end
    changed = true
  end
  
  if alt.damageFactor then
    local altDamageFactor = im.FloatPtr(alt.damageFactor)
    if im.SliderFloat("Alt Damage Factor", altDamageFactor, 0.0, 1.0, "%.2f") then
      alt.damageFactor = altDamageFactor[0]
      changed = true
    end
  end
  
  -- Alt Checkpoint Roads
  im.Separator()
  im.Text("Alt Route Checkpoint Roads:")
  
  -- Road filter
  local altRoadFilter = im.ArrayChar(128, altRoadFilterText)
  if im.InputText("Filter Alt Roads", altRoadFilter, 128) then
    altRoadFilterText = ffi.string(altRoadFilter)
  end
  
  -- Initialize checkpoint roads
  if not alt.checkpointRoad then
    alt.checkpointRoad = {}
  elseif type(alt.checkpointRoad) == "string" then
    alt.checkpointRoad = {alt.checkpointRoad}
  end
  
  -- Display alt road selections
  for i, roadName in ipairs(alt.checkpointRoad) do
    im.PushID1("alt_road_" .. tostring(i))
    
    if i > 1 then
      if im.Button("X##remove", im.ImVec2(24, 0)) then
        table.remove(alt.checkpointRoad, i)
        changed = true
        im.PopID()
        break
      end
      im.SameLine()
    end
    
    drawRoadSelector("Select Alt Road #" .. i, alt.checkpointRoad, i, altRoadFilterText, function()
      changed = true
    end)
    
    im.PopID()
  end
  
  if im.Button("+ Add Alt Road", im.ImVec2(im.GetContentRegionAvail().x, 0)) then
    table.insert(alt.checkpointRoad, "")
    changed = true
  end
  
  -- Merge Checkpoints
  im.Separator()
  im.Text("Merge Checkpoints (main route indices where alt merges):")
  helpMarker("Indices of main route checkpoints where the alt route reconnects", true)
  
  if not alt.mergeCheckpoints then
    alt.mergeCheckpoints = {}
  end
  
  for i, cpIndex in ipairs(alt.mergeCheckpoints) do
    im.PushID1("merge_cp_" .. tostring(i))
    
    if im.Button("X##remove", im.ImVec2(24, 0)) then
      table.remove(alt.mergeCheckpoints, i)
      changed = true
      im.PopID()
      break
    end
    im.SameLine()
    
    im.SetNextItemWidth(100)
    local idx = im.IntPtr(cpIndex)
    if im.InputInt("##idx", idx, 1, 1) then
      alt.mergeCheckpoints[i] = idx[0]
      changed = true
    end
    
    im.PopID()
  end
  
  if im.Button("+ Add Merge Point", im.ImVec2(im.GetContentRegionAvail().x, 0)) then
    table.insert(alt.mergeCheckpoints, 1)
    changed = true
  end
  
  return changed
end

-- ============================================================================
-- VALIDATION MODAL
-- ============================================================================

local function drawValidationModal()
  if not showValidationModal then return end
  
  im.SetNextWindowSize(im.ImVec2(500, 400), im.Cond_FirstUseEver)
  
  if im.BeginPopupModal("Validation Issues", nil, im.WindowFlags_AlwaysAutoResize) then
    if countTableEntries(validationIssues) == 0 then
      im.TextColored(colors.success, "All events passed validation!")
      im.Spacing()
      if im.Button("Close & Save", im.ImVec2(im.GetContentRegionAvail().x, 30)) then
        saveRaceData()
        showValidationModal = false
        im.CloseCurrentPopup()
      end
    else
      im.TextColored(colors.warning, "Some events have issues:")
      im.Separator()
      
      im.BeginChild1("ValidationList", im.ImVec2(0, 300), true)
      
      for raceName, eventData in pairs(validationIssues) do
        if im.CollapsingHeader1(eventData.label .. " (" .. #eventData.issues .. " issues)##" .. raceName) then
          for _, issue in ipairs(eventData.issues) do
            im.BulletText(issue)
          end
          
          if im.SmallButton("Go to Event##" .. raceName) then
            currentRaceName = raceName
          end
        end
      end
      
      im.EndChild()
      
      im.Separator()
      
      if im.Button("Save Anyway", im.ImVec2(im.GetContentRegionAvail().x * 0.48, 30)) then
        saveRaceData()
        showValidationModal = false
        im.CloseCurrentPopup()
      end
      im.SameLine()
      if im.Button("Cancel", im.ImVec2(im.GetContentRegionAvail().x, 30)) then
        showValidationModal = false
        im.CloseCurrentPopup()
      end
    end
    
    im.EndPopup()
  end
end

-- ============================================================================
-- TRIGGER INFO DISPLAY
-- ============================================================================

local function drawTriggerInfo(triggerType, raceName)
  local prefix
  if triggerType == "start" then prefix = "fre_start_"
  elseif triggerType == "staging" then prefix = "fre_staging_"
  elseif triggerType == "finish" then prefix = "fre_finish_"
  elseif triggerType == "pit" then prefix = "fre_pits_"
  end
  
  local info = getTriggerInfo(prefix .. raceName)
  if info then
    im.Indent()
    im.TextColored(colors.dimmed, string.format("Pos: %.1f, %.1f, %.1f", 
      info.position.x, info.position.y, info.position.z))
    im.TextColored(colors.dimmed, string.format("Scale: %.1f x %.1f x %.1f", 
      info.scale.x, info.scale.y, info.scale.z))
    -- Clone button: clone start as staging (offset behind) or staging as start (offset ahead)
    if triggerType == "start" or triggerType == "staging" then
      local otherType = triggerType == "start" and "staging" or "start"
      local otherPrefix = triggerType == "start" and "fre_staging_" or "fre_start_"
      local otherExists = scenetree.findObject(otherPrefix .. raceName) ~= nil
      if not otherExists then
        im.SameLine()
        if im.SmallButton("Clone as " .. otherType .. "##clone_" .. triggerType) then
          cloneTriggerAs(triggerType, otherType, raceName)
        end
        if im.IsItemHovered() then
          im.SetTooltip("Clone this trigger as the " .. otherType .. " trigger with spacing offset")
        end
      end
      im.SameLine()
      im.PushStyleColor2(im.Col_Button, im.ImVec4(0.5, 0.1, 0.1, 1))
      if im.SmallButton("Delete##del_" .. triggerType) then
        deleteTrigger(triggerType, raceName)
      end
      im.PopStyleColor()
    end
    im.Unindent()
  end
end

-- ============================================================================
-- MAIN EDITOR GUI
-- ============================================================================

local function onEditorGui()
  if not editor.isWindowVisible(toolWindowName) then return end
  M.onEditorUpdate()
  
  if editor.beginWindow(toolWindowName, "Freeroam Event Editor", im.WindowFlags_MenuBar) then
    local level = getCurrentLevelIdentifier()
    if not level then
      im.TextColored(colors.error, "No level loaded!")
      editor.endWindow()
      return
    end
    
    -- Menu Bar
    if im.BeginMenuBar() then
      if im.BeginMenu("File") then
        if im.MenuItem1("New") then
          createNewRaceData()
        end
        if im.MenuItem1("Load") then
          loadRaceData()
        end
        if im.MenuItem1("Save") then
          validationIssues = validateAllEvents()
          showValidationModal = true
          im.OpenPopup("Validation Issues")
        end
        if im.MenuItem1("Save (Skip Validation)") then
          saveRaceData()
        end
        im.EndMenu()
      end
      if im.BeginMenu("View") then
        if im.MenuItem1("Refresh Roads") then
          findDecalRoads()
        end
        if im.MenuItem1("Refresh All Objects") then
          findLevelObjects()
        end
        im.EndMenu()
      end
      im.EndMenuBar()
    end

    -- Validation Modal
    drawValidationModal()

    -- Status line
    if modified then
      im.TextColored(colors.warning, "* Modified (unsaved)")
    else
      im.TextColored(colors.success, "Saved")
    end
    im.SameLine()
    im.TextColored(colors.dimmed, "| Level: " .. level)
    
    im.Separator()
    
    -- Split layout
    local windowWidth = im.GetContentRegionAvail().x
    local leftPanelWidth = windowWidth * 0.3
    
    -- ========== LEFT PANEL - Event List ==========
    im.BeginChild1("EventsList", im.ImVec2(leftPanelWidth, im.GetContentRegionAvail().y), true)
    
    -- Create & Duplicate buttons
    if im.Button("+ New Event", im.ImVec2(im.GetContentRegionAvail().x * 0.48, 0)) then
      createNewRace()
    end
    im.SameLine()
    local canDuplicate = currentRaceName ~= nil
    if not canDuplicate then im.BeginDisabled(true) end
    if im.Button("Duplicate", im.ImVec2(im.GetContentRegionAvail().x, 0)) then
      duplicateRace(currentRaceName)
    end
    if not canDuplicate then im.EndDisabled() end
    
    im.Spacing()
    
    -- Event filter
    local eventFilter = im.ArrayChar(128, eventFilterText)
    im.SetNextItemWidth(im.GetContentRegionAvail().x)
    if im.InputTextWithHint("##EventFilter", "Filter events...", eventFilter, 128) then
      eventFilterText = ffi.string(eventFilter)
    end
    
    im.Separator()
    
    -- Event count
    local raceCount = countTableEntries(races)
    im.TextColored(colors.dimmed, "Events (" .. raceCount .. "):")
    
    -- Event list
    local filterLower = eventFilterText:lower()
    for raceName, race in pairs(races) do
      -- Apply filter
      local labelLower = (race.label or raceName):lower()
      if filterLower ~= "" and not string.find(labelLower, filterLower) and not string.find(raceName:lower(), filterLower) then
        goto continue
      end
      
      local complete = isRaceComplete(raceName, race)
      local isSelected = raceName == currentRaceName
      
      -- Color based on completeness
      if not complete then
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.5, 0.2, 0.2, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.6, 0.3, 0.3, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.7, 0.4, 0.4, 1.0))
      elseif isSelected then
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.2, 0.4, 0.6, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.3, 0.5, 0.7, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.4, 0.6, 0.8, 1.0))
      end

      if im.Button((race.label or "Unnamed") .. "##" .. raceName, im.ImVec2(im.GetContentRegionAvail().x, 0)) then
        currentRaceName = raceName
        if showingRaceCheckpoints then
          removeRaceCheckpoints()
          showRaceCheckpoints()
        end
      end
      
      if not complete then
        im.PopStyleColor(3)
      elseif isSelected then
        im.PopStyleColor(3)
      end
      
      -- Tooltip
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.Text("ID: " .. raceName)
        
        local done, total, components = getEventCompleteness(raceName, race)
        local progressText = string.format("Progress: %d/%d", done, total)
        
        if done == total then
          im.TextColored(colors.success, progressText .. " - Complete!")
        else
          im.TextColored(colors.warning, progressText)
          im.Separator()
          for _, c in ipairs(components) do
            if c.done then
              im.TextColored(colors.success, "✓ " .. c.name)
            else
              im.TextColored(colors.error, "✗ " .. c.name)
            end
          end
        end
        im.EndTooltip()
      end
      
      ::continue::
    end
    
    im.EndChild()
    
    im.SameLine()
    
    -- ========== RIGHT PANEL - Event Details ==========
    im.BeginChild1("RaceDetails", im.ImVec2(0, im.GetContentRegionAvail().y), true)
    
    if currentRaceName and races[currentRaceName] then
      local race = races[currentRaceName]
      local changed = false
      
      -- Header with progress
      local done, total, _ = getEventCompleteness(currentRaceName, race)
      im.Text("Editing: ")
      im.SameLine()
      im.TextColored(colors.info, race.label or currentRaceName)
      im.SameLine()
      local progressColor = done == total and colors.success or colors.warning
      im.TextColored(progressColor, string.format("(%d/%d)", done, total))
      
      -- Progress bar
      im.ProgressBar(done / total, im.ImVec2(-1, 0), string.format("%d/%d components", done, total))
      
      im.Spacing()
      
      -- ===== BASIC INFO =====
      im.SeparatorText("Basic Information")
      
      -- Event ID
      im.PushID1(currentRaceName .. "_id")
      local raceNameBuf = im.ArrayChar(128, currentRaceName)
      if im.InputText("Event ID", raceNameBuf, 128, im.InputTextFlags_EnterReturnsTrue) then
        local newRaceName = ffi.string(raceNameBuf)
        if newRaceName ~= currentRaceName and newRaceName ~= "" and not races[newRaceName] then
          -- Rename triggers
          local prefixes = {"fre_start_", "fre_staging_", "fre_finish_", "fre_pits_"}
          for _, prefix in ipairs(prefixes) do
            local trigger = scenetree.findObject(prefix .. currentRaceName)
            if trigger then
              trigger:setName(prefix .. newRaceName)
            end
          end
          
          races[newRaceName] = deepCopyTable(race)
          races[currentRaceName] = nil
          currentRaceName = newRaceName
          changed = true
        end
      end
      im.PopID()
      
      -- Event Label
      local eventLabel = im.ArrayChar(128, race.label or "")
      if im.InputText("Event Label", eventLabel) then
        race.label = ffi.string(eventLabel)
        changed = true
      end
      
      -- Best Time
      local bestTime = im.FloatPtr(race.bestTime or 60)
      if im.InputFloat("Best Time (seconds)", bestTime, 1, 5, "%.1f") then
        race.bestTime = bestTime[0]
        changed = true
      end
      
      -- ===== EVENT TYPE =====
      im.SeparatorText("Event Type")
      
      -- Drift Event
      local isDriftGoal = im.BoolPtr(race.driftGoal ~= nil)
      if im.Checkbox("Drift Event", isDriftGoal) then
        if isDriftGoal[0] then
          race.driftGoal = 1000
        else
          race.driftGoal = nil
          race.driftTargetTime = nil
        end
        changed = true
      end
      
      if isDriftGoal[0] then
        im.Indent()
        local driftGoal = im.IntPtr(race.driftGoal or 1000)
        if im.InputInt("Drift Goal Score", driftGoal, 100, 10000) then
          race.driftGoal = driftGoal[0]
          changed = true
        end
        
        -- Drift Target Time
        local hasDriftTargetTime = im.BoolPtr(race.driftTargetTime ~= nil)
        if im.Checkbox("Custom Drift Target Time", hasDriftTargetTime) then
          if hasDriftTargetTime[0] then
            race.driftTargetTime = race.bestTime
          else
            race.driftTargetTime = nil
          end
          changed = true
        end
        
        if race.driftTargetTime then
          local driftTargetTime = im.FloatPtr(race.driftTargetTime)
          if im.InputFloat("Drift Target Time", driftTargetTime, 1, 5, "%.1f") then
            race.driftTargetTime = driftTargetTime[0]
            changed = true
          end
        end
        im.Unindent()
      end
      
      -- Top Speed Event
      local isTopSpeed = im.BoolPtr(race.topSpeed == true)
      if im.Checkbox("Top Speed Event", isTopSpeed) then
        race.topSpeed = isTopSpeed[0] or nil
        if isTopSpeed[0] and not race.topSpeedGoal then
          race.topSpeedGoal = 100
        end
        changed = true
      end
      
      if race.topSpeed then
        im.Indent()
        local topSpeedGoal = im.FloatPtr(race.topSpeedGoal or 100)
        if im.InputFloat("Top Speed Goal (mph)", topSpeedGoal, 5, 10, "%.1f") then
          race.topSpeedGoal = topSpeedGoal[0]
          changed = true
        end
        im.Unindent()
      end
      
      -- Damage Factor
      local hasDamageFactor = im.BoolPtr(race.damageFactor ~= nil)
      if im.Checkbox("Enable Damage Factor", hasDamageFactor) then
        if hasDamageFactor[0] then
          race.damageFactor = 0.5
        else
          race.damageFactor = nil
        end
        changed = true
      end
      
      if hasDamageFactor[0] then
        im.Indent()
        local damageFactor = im.FloatPtr(race.damageFactor or 0.5)
        if im.SliderFloat("Damage Factor", damageFactor, 0.0, 1.0, "%.2f") then
          race.damageFactor = damageFactor[0]
          changed = true
        end
        helpMarker("0.0 = Time only (traditional)\n0.5 = 50/50 time/damage\n1.0 = Damage only", true)
        im.Unindent()
      end
      
      -- Type checkboxes
      im.Spacing()
      im.Text("Event Categories:")
      
      -- Warn if no types selected
      if not race.type or #race.type == 0 then
        im.TextColored(colors.error, "⚠ No event types selected!")
      end
      
      local availableWidth = im.GetContentRegionAvail().x
      local columnsPerRow = math.max(1, math.floor(availableWidth / 120))
      local rowCount = 0

      -- Custom type input
      local customType = im.ArrayChar(128, "")
      im.SetNextItemWidth(150)
      if im.InputText("##CustomType", customType, 128, im.InputTextFlags_EnterReturnsTrue) then
        local newType = ffi.string(customType)
        if newType ~= "" and not tableContains(raceTypes, newType) then
          table.insert(raceTypes, newType)
          if not race.type then race.type = {} end
          table.insert(race.type, newType)
          changed = true
        end
      end
      im.SameLine()
      im.TextColored(colors.dimmed, "(Enter to add custom)")

      for i, rType in ipairs(raceTypes) do
        if not race.type then race.type = {"motorsport"} end
        
        local isSelected = im.BoolPtr(tableContains(race.type, rType))
        
        if rowCount % columnsPerRow ~= 0 then
          im.SameLine()
        end
        
        if im.Checkbox(rType .. "##type", isSelected) then
          if isSelected[0] then
            if not tableContains(race.type, rType) then
              table.insert(race.type, rType)
            end
          else
            local idx = tableIndexOf(race.type, rType)
            if idx then table.remove(race.type, idx) end
          end
          changed = true
        end
        
        rowCount = rowCount + 1
      end
      
      -- ===== REWARD CALCULATOR =====
      im.SeparatorText("Reward Calculator")
      
      -- Reward base value
      local reward = im.IntPtr(race.reward or 1000)
      if im.InputInt("Base Reward ($)", reward, 100, 1000) then
        race.reward = reward[0]
        changed = true
      end
      
      im.Spacing()
      
      -- Calculator inputs in table format
      if im.BeginTable("RewardCalcInputs", 2, im.TableFlags_BordersInnerV) then
        im.TableSetupColumn("Input", im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn("Value", im.TableColumnFlags_WidthStretch)
        
        -- Time input
        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Preview Time (s)")
        im.TableSetColumnIndex(1)
        im.SetNextItemWidth(-1)
        im.InputFloat("##previewTime", realTime, 1, 5, "%.1f")
        
        -- Drift score (if drift event)
        if race.driftGoal then
          im.TableNextRow()
          im.TableSetColumnIndex(0)
          im.Text("Preview Drift Score")
          im.TableSetColumnIndex(1)
          im.SetNextItemWidth(-1)
          im.InputInt("##previewDrift", driftScore, 100, 1000)
        end
        
        -- Top speed (if top speed event)
        if race.topSpeed then
          im.TableNextRow()
          im.TableSetColumnIndex(0)
          im.Text("Preview Speed (mph)")
          im.TableSetColumnIndex(1)
          im.SetNextItemWidth(-1)
          im.InputFloat("##previewSpeed", topSpeedPreview, 5, 10, "%.1f")
        end
        
        -- Damage percentage (if damage factor enabled)
        if race.damageFactor and race.damageFactor > 0 then
          im.TableNextRow()
          im.TableSetColumnIndex(0)
          im.Text("Damage %")
          im.TableSetColumnIndex(1)
          im.SetNextItemWidth(-1)
          im.SliderFloat("##previewDamage", damagePercentage, 0.0, 1.0, "%.2f%%")
        end
        
        -- Lap count
        im.TableNextRow()
        im.TableSetColumnIndex(0)
        im.Text("Lap Count")
        im.TableSetColumnIndex(1)
        im.SetNextItemWidth(-1)
        im.InputInt("##lapCount", lapCount, 1, 10)
        
        im.EndTable()
      end
      
      -- Bonus checkboxes
      im.Spacing()
      im.Checkbox("New Best Time Bonus (+" .. string.format("%.0f%%", (utils.NEW_BEST_BONUS - 1) * 100) .. ")", bestTimeSession)
      im.SameLine()
      im.Checkbox("In Range Bonus (+" .. string.format("%.0f%%", (utils.IN_RANGE_BONUS - 1) * 100) .. ")", inRange)
      im.Checkbox("Hardcore Mode (-50%)", hardcore)
      
      -- Calculate reward using actual utils functions
      local calculatedReward
      if race.driftGoal then
        calculatedReward = utils.driftReward(race, realTime[0], driftScore[0])
      elseif race.topSpeed then
        calculatedReward = utils.topSpeedReward(race.topSpeedGoal or 100, race.reward, topSpeedPreview[0], race.type)
      elseif race.damageFactor and race.damageFactor > 0 then
        calculatedReward = utils.hybridRaceReward(race.bestTime, race.reward, realTime[0], race.damageFactor, damagePercentage[0], race.type)
      else
        calculatedReward = utils.raceReward(race.bestTime, race.reward, realTime[0], race.type)
      end
      
      -- Apply modifiers
      calculatedReward = calculatedReward * utils.hotlapMultiplier(lapCount[0])
      
      if bestTimeSession[0] then
        calculatedReward = calculatedReward * utils.NEW_BEST_BONUS
      end
      if inRange[0] then
        calculatedReward = calculatedReward * utils.IN_RANGE_BONUS
      end
      if hardcore[0] then
        calculatedReward = calculatedReward * 0.5
      end
      
      -- Display result
      im.Spacing()
      im.Separator()
      
      local rewardColor = calculatedReward > 0 and colors.success or colors.error
      im.TextColored(rewardColor, string.format("Calculated Reward: $%.0f", calculatedReward))
      
      if calculatedReward <= 0 then
        im.TextColored(colors.error, "⚠ Warning: Reward is 0 or negative!")
      end
      
      -- Reward curve visualization
      im.Spacing()
      drawRewardCurve(race)
      
      -- ===== EVENT OPTIONS =====
      im.SeparatorText("Event Options")
      
      -- Apex Offset
      local hasApexOffset = im.BoolPtr(race.apexOffset ~= nil)
      if im.Checkbox("Use Apex Offset", hasApexOffset) then
        if hasApexOffset[0] then
          race.apexOffset = 1.0
        else
          race.apexOffset = nil
        end
        changed = true
      end
      helpMarker("Apex Offset shifts checkpoint positions along the road by a number of nodes.\nPositive values move checkpoints forward, negative values move them backward.\nUseful for fine-tuning checkpoint placement on curves.", true)
      
      if hasApexOffset[0] then
        im.Indent()
        local apexOffset = im.FloatPtr(race.apexOffset or 1.0)
        if im.InputFloat("Apex Offset (Nodes)", apexOffset, 0.5, 1.0, "%.1f") then
          race.apexOffset = apexOffset[0]
          changed = true
        end
        im.Unindent()
      end
      
      -- Running Start
      local runningStart = im.BoolPtr(race.runningStart or false)
      if im.Checkbox("Running Start", runningStart) then
        race.runningStart = runningStart[0]
        changed = true
      end
      helpMarker("When enabled, the timer starts when the player crosses the start line at speed.\nWhen disabled, the player must be stationary in the staging area before starting.", true)

      -- Reverse
      local reverse = im.BoolPtr(race.reverse or false)
      if im.Checkbox("Reverse Direction", reverse) then
        race.reverse = reverse[0]
        changed = true
      end
      
      -- Timeout
      local timeout = im.IntPtr(race.timeout or 10)
      if im.InputInt("Stationary Timeout (s)", timeout, 1, 5) then
        race.timeout = math.max(1, timeout[0])
        changed = true
      end
      helpMarker("How long a player can remain stationary before the race is cancelled.\nLower = faster paced, Higher = more technical events.", true)
      
      -- ===== CHECKPOINT SETTINGS =====
      im.SeparatorText("Checkpoint Settings")
      
      -- Loop type
      local loopSelected = im.IntPtr(race.hotlap and 1 or 2)
      
      if im.RadioButton2("Looped (Hotlap)", loopSelected, im.Int(1)) then
        race.hotlap = race.hotlap or (race.bestTime * 0.9)
        changed = true
      end
      im.SameLine()
      if im.RadioButton2("Point-to-Point", loopSelected, im.Int(2)) then
        race.hotlap = nil
        changed = true
      end

      if race.hotlap then
        local hotlap = im.FloatPtr(race.hotlap)
        if im.InputFloat("Hotlap Target Time (s)", hotlap, 1, 5, "%.1f") then
          race.hotlap = hotlap[0]
          changed = true
        end
      end
      
      -- Min checkpoint distance
      local hasMinDist = im.BoolPtr(race.minCheckpointDistance ~= nil)
      if im.Checkbox("Custom Min Checkpoint Distance", hasMinDist) then
        if hasMinDist[0] then
          race.minCheckpointDistance = 50
        else
          race.minCheckpointDistance = nil
        end
        changed = true
      end
      
      if race.minCheckpointDistance then
        im.Indent()
        local minDist = im.FloatPtr(race.minCheckpointDistance)
        if im.InputFloat("Min Distance (m)", minDist, 5, 10, "%.1f") then
          race.minCheckpointDistance = minDist[0]
          changed = true
        end
        im.Unindent()
      end
      
      -- Road selection
      im.Spacing()
      im.Text("Checkpoint Roads:")
      
      local roadFilter = im.ArrayChar(128, roadFilterText)
      im.SetNextItemWidth(im.GetContentRegionAvail().x)
      if im.InputTextWithHint("##RoadFilter", "Filter roads...", roadFilter, 128) then
        roadFilterText = ffi.string(roadFilter)
      end

      -- Initialize checkpoint roads
      if race.checkpointRoad and type(race.checkpointRoad) ~= "table" then
        race.checkpointRoad = {race.checkpointRoad}
      elseif not race.checkpointRoad then
        race.checkpointRoad = {}
      end
      
      -- Display road selections
      for i, roadName in ipairs(race.checkpointRoad) do
        im.PushID1("road_" .. tostring(i))
        
        if i > 1 then
          if im.Button("X##remove", im.ImVec2(24, 0)) then
            table.remove(race.checkpointRoad, i)
            changed = true
            im.PopID()
            break
          end
          im.SameLine()
        end
        
        drawRoadSelector("Road #" .. i, race.checkpointRoad, i, roadFilterText, function()
          changed = true
        end)
        
        im.PopID()
      end
      
      if im.Button("+ Add Road", im.ImVec2(im.GetContentRegionAvail().x, 0)) then
        table.insert(race.checkpointRoad, "")
        changed = true
      end

      -- Checkpoint preview buttons
      im.Spacing()
      if im.Button("Show Checkpoints", im.ImVec2(im.GetContentRegionAvail().x * 0.48, 0)) then
        showingRaceCheckpoints = true
        showRaceCheckpoints()
      end
      im.SameLine()
      if im.Button("Hide Checkpoints", im.ImVec2(im.GetContentRegionAvail().x, 0)) then
        showingRaceCheckpoints = false
        removeRaceCheckpoints()
      end

      -- Checkpoint count display
      if showingRaceCheckpoints and #checkpoints > 0 then
        im.TextColored(colors.info, string.format("Generated %d checkpoints", #checkpoints))
        
        -- Track distance display
        if roadNodes and #roadNodes > 1 then
          local trackDist = processRoad.calculateTrackDistances(roadNodes, checkpoints)
          
          if trackDist and trackDist.totalLength > 0 then
            im.Spacing()
            im.SeparatorText("Track Distance Analysis")
            
            -- Total track length
            local totalMeters = trackDist.totalLength
            im.Text("Total Track Length:")
            im.SameLine()
            im.TextColored(colors.success, string.format("%s (%s)", 
              utils.formatDistance(totalMeters),
              string.format("%.2f km", totalMeters / 1000)))
            
            -- Gap analysis
            if trackDist.segmentLengths and #trackDist.segmentLengths > 0 then
              local minGap = math.huge
              local maxGap = 0
              local totalGap = 0
              local gapCount = 0
              
              for i, gap in ipairs(trackDist.segmentLengths) do
                if gap > 0 then
                  if gap < minGap then minGap = gap end
                  if gap > maxGap then maxGap = gap end
                  totalGap = totalGap + gap
                  gapCount = gapCount + 1
                end
              end
              
              local avgGap = gapCount > 0 and (totalGap / gapCount) or 0
              
              im.Spacing()
              im.Text("Checkpoint Gap Analysis:")
              
              if im.BeginTable("GapAnalysis", 2, im.TableFlags_BordersInnerV) then
                im.TableNextRow()
                im.TableSetColumnIndex(0)
                im.Text("Average Gap")
                im.TableSetColumnIndex(1)
                im.Text(utils.formatDistance(avgGap))
                
                im.TableNextRow()
                im.TableSetColumnIndex(0)
                im.Text("Shortest Gap")
                im.TableSetColumnIndex(1)
                im.Text(minGap < math.huge and utils.formatDistance(minGap) or "N/A")
                
                im.TableNextRow()
                im.TableSetColumnIndex(0)
                im.Text("Longest Gap")
                im.TableSetColumnIndex(1)
                im.Text(utils.formatDistance(maxGap))
                
                im.EndTable()
              end
              
              -- Warning for uneven spacing
              local hasUnevenSpacing = false
              local unevenCheckpoints = {}
              
              if avgGap > 0 then
                for i, gap in ipairs(trackDist.segmentLengths) do
                  if gap > avgGap * 2 or gap < avgGap * 0.5 then
                    hasUnevenSpacing = true
                    table.insert(unevenCheckpoints, i)
                  end
                end
              end
              
              if hasUnevenSpacing then
                im.Spacing()
                im.TextColored(colors.warning, "⚠ Uneven checkpoint spacing detected!")
                im.TextColored(colors.dimmed, string.format("Checkpoints with unusual gaps: %s", table.concat(unevenCheckpoints, ", ")))
              end
              
              -- Per-checkpoint distances (collapsible)
              im.Spacing()
              if im.CollapsingHeader1("Per-Checkpoint Distances") then
                if im.BeginTable("CheckpointDistances", 3, im.TableFlags_Borders + im.TableFlags_RowBg) then
                  im.TableSetupColumn("CP#", im.TableColumnFlags_WidthFixed, 40)
                  im.TableSetupColumn("Cumulative", im.TableColumnFlags_WidthStretch)
                  im.TableSetupColumn("Segment", im.TableColumnFlags_WidthStretch)
                  im.TableHeadersRow()
                  
                  for i, cpDist in ipairs(trackDist.checkpointDistances) do
                    local segDist = trackDist.segmentLengths[i] or 0
                    local isUneven = avgGap > 0 and (segDist > avgGap * 2 or segDist < avgGap * 0.5)
                    
                    im.TableNextRow()
                    im.TableSetColumnIndex(0)
                    im.Text(tostring(i))
                    
                    im.TableSetColumnIndex(1)
                    im.Text(utils.formatDistance(cpDist))
                    
                    im.TableSetColumnIndex(2)
                    if isUneven then
                      im.TextColored(colors.warning, utils.formatDistance(segDist) .. " ⚠")
                    else
                      im.Text(utils.formatDistance(segDist))
                    end
                  end
                  
                  im.EndTable()
                end
              end
            end
          end
        end
      elseif showingRaceCheckpoints and #checkpoints == 0 then
        im.TextColored(colors.warning, "⚠ No checkpoints generated - check road selection")
      end

      -- Manual checkpoint editing
      if showingRaceCheckpoints then
        local buttonText = not showingCheckpointsEditor and "Manual Edit Checkpoints" or "Use Auto Checkpoints"
        if im.Button(buttonText, im.ImVec2(im.GetContentRegionAvail().x, 0)) then
          if not showingCheckpointsEditor then
            showingCheckpointsEditor = true
          else
            race.checkpointIndexs = nil
            showingCheckpointsEditor = false
          end
        end
        showCheckpointsEditor(race)
      end
      
      -- ===== ALTERNATIVE ROUTE =====
      changed = drawAltRouteEditor(race, changed) or changed
      
      -- ===== TRIGGER MANAGEMENT =====
      im.SeparatorText("Trigger Management")
      
      -- Helper function for trigger buttons
      local function triggerButton(triggerType, displayName, raceName)
        local exists = triggerExists("fre_" .. triggerType .. "_", raceName)
        local buttonText = exists and ("Select " .. displayName) or ("Create " .. displayName)
        
        if pendingTriggerType == triggerType and pendingTriggerRace == raceName then
          buttonText = "Cancel " .. displayName .. " Placement"
          im.PushStyleColor2(im.Col_Button, im.ImVec4(0.6, 0.4, 0.1, 1))
        elseif exists then
          im.PushStyleColor2(im.Col_Button, im.ImVec4(0.1, 0.4, 0.2, 1))
        else
          im.PushStyleColor2(im.Col_Button, im.ImVec4(0.4, 0.1, 0.1, 1))
        end
        
        if im.Button(buttonText .. "##" .. triggerType, im.ImVec2(im.GetContentRegionAvail().x, 0)) then
          if pendingTriggerType == triggerType and pendingTriggerRace == raceName then
            pendingTriggerType = nil
            pendingTriggerRace = nil
            showTriggerPlacementHelp = false
          else
            createOrSelectTrigger(triggerType, raceName)
          end
        end
        im.PopStyleColor()
        
        -- Show trigger info if exists
        if exists then
          drawTriggerInfo(triggerType, raceName)
        end
      end
      
      triggerButton("start", "Start Trigger", currentRaceName)
      triggerButton("staging", "Staging Trigger", currentRaceName)
      
      if not race.hotlap then
        triggerButton("finish", "Finish Trigger", currentRaceName)
      end
      
      if showTriggerPlacementHelp then
        im.TextColored(colors.warning, "Click on the map to place the trigger")
      end
      
      -- ===== PITS MANAGEMENT =====
      im.SeparatorText("Pits Management")
      
      local hasPits = im.BoolPtr(race.hasPits or false)
      if im.Checkbox("Enable Pit Lane", hasPits) then
        race.hasPits = hasPits[0]
        changed = true
      end
      
      if race.hasPits then
        im.Indent()
        
        local pitSpeedLimit = im.IntPtr(race.pitSpeedLimit or 60)
        if im.InputInt("Pit Speed Limit", pitSpeedLimit, 5, 10) then
          race.pitSpeedLimit = math.max(5, pitSpeedLimit[0])
          changed = true
        end
        
        local unitOptions = {"KPH", "MPH"}
        local currentUnit = race.pitSpeedUnit or "KPH"
        
        if im.BeginCombo("Speed Unit", currentUnit) then
          for _, unit in ipairs(unitOptions) do
            if im.Selectable1(unit, unit == currentUnit) then
              race.pitSpeedUnit = unit
              changed = true
            end
          end
          im.EndCombo()
        end
        
        triggerButton("pit", "Pit Trigger", currentRaceName)
        
        im.Unindent()
      end
      
      -- ===== TESTING =====
      im.SeparatorText("Testing")
      
      if im.Button("Teleport to Start", im.ImVec2(im.GetContentRegionAvail().x, 30)) then
        teleportToStart(currentRaceName)
      end
      helpMarker("Teleports your vehicle to the start trigger position", true)
      
      -- ===== ACTIONS =====
      im.SeparatorText("Actions")
      
      im.PushStyleColor2(im.Col_Button, im.ImVec4(0.6, 0.1, 0.1, 1))
      if im.Button("Delete Event", im.ImVec2(im.GetContentRegionAvail().x, 30)) then
        im.OpenPopup("Delete Event Confirmation")
      end
      im.PopStyleColor()
      
      -- Delete confirmation modal
      if im.BeginPopupModal("Delete Event Confirmation", nil, im.WindowFlags_AlwaysAutoResize) then
        im.Text("Are you sure you want to delete this event?")
        im.TextColored(colors.warning, race.label or currentRaceName)
        im.Text("This action cannot be undone.")
        im.Separator()
        
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.6, 0.1, 0.1, 1))
        if im.Button("Yes, Delete", im.ImVec2(im.GetContentRegionAvail().x * 0.48, 0)) then
          races[currentRaceName] = nil
          currentRaceName = nil
          changed = true
          im.CloseCurrentPopup()
        end
        im.PopStyleColor()
        
        im.SameLine()
        
        if im.Button("Cancel", im.ImVec2(im.GetContentRegionAvail().x, 0)) then
          im.CloseCurrentPopup()
        end
        
        im.EndPopup()
      end
      
      if changed then
        modified = true
      end
    else
      -- No event selected
      im.TextColored(colors.dimmed, "Select an event from the list or create a new one")
    end
    
    im.EndChild()
    
    editor.endWindow()
  end
end

-- ============================================================================
-- UPDATE LOOP
-- ============================================================================

local internal_onEditorUpdate = 5
local lastOsTime = os.time()

function M.onEditorUpdate()
  -- Trigger placement
  if pendingTriggerType and pendingTriggerRace then
    triggerPlacementUpdate()
  end
  
  -- Draw road path
  drawRoadPath()
  
  -- Periodic refresh
  if os.time() - lastOsTime > internal_onEditorUpdate then
    lastOsTime = os.time()
    findDecalRoads()

    -- Validate checkpoint roads still exist
    for raceName, race in pairs(races) do
      if race.checkpointRoad then
        if type(race.checkpointRoad) == "string" then
          if race.checkpointRoad ~= "" and not tableContains(levelDecalRoads, race.checkpointRoad) then
            -- Road doesn't exist - mark but don't auto-clear
          end
        elseif type(race.checkpointRoad) == "table" then
          -- Just validate, don't auto-remove
        end
      end
    end
  end
end

-- ============================================================================
-- LIFECYCLE
-- ============================================================================

local function onActivate()
  log('I', logTag, "Freeroam Event Editor activated")
  findLevelObjects()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(900, 700))
  editor.addWindowMenuItem("Freeroam Event Editor", onWindowMenuItem)
  log('I', logTag, "Freeroam Event Editor initialized")
  loadRaceData()
  findLevelObjects()
end

local function onExtensionLoaded()
  loadRaceData()
end

local function onWorldReadyState(state)
  if state == 2 then
    loadRaceData()
    utils.onExtensionLoaded()
  end
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onWindowMenuItem = onWindowMenuItem
M.onActivate = onActivate
M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState

return M
