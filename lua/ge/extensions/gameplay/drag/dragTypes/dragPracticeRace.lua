-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_drag_general", "gameplay_drag_utils"}

local dGeneral, dUtils
local dragData
local logTag = "dragPracticeRace"
local freeroamEvents = require("gameplay/events/freeroamEvents")
local freeroamUtils = require("gameplay/events/freeroam/utils")
local hasActivityStarted = false

local function onExtensionLoaded()
  dGeneral = gameplay_drag_general
  dUtils = gameplay_drag_utils

  dragData = dGeneral.getData()
  if not dragData then
    log('E', logTag, 'No drag race data found')
    return
  end
  
  if dragData.prefabs.christmasTree.isUsed then
    extensions.load('gameplay_drag_times')
  end
  if dragData.prefabs.displaySign.isUsed then
    extensions.load('gameplay_drag_display')
  end

  dragData.isStarted = true
  hasActivityStarted = dragData.isStarted
end

local function resetDragRace()
  if not dragData then return end
  extensions.hook("resetDragRaceValues")
  dGeneral.unloadRace()
end

local function startActivity()
  dragData = dGeneral.getData()

  if not dragData then
    log('E', logTag, 'No drag race data found')
    return
  end
  
  dragData.isStarted = true
  hasActivityStarted = dragData.isStarted
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not hasActivityStarted then
    return
  end
  
  if not dragData then
    log('E', logTag, 'No drag data found!')
    return
  end
  
  if not dragData.racers then
    log('E', logTag, 'There is no racers in the drag data.')
    return
  end

  for vehId, racer in pairs(dragData.racers) do
    if racer.isFinished then
      dragData.isCompleted = true
      resetDragRace()
      hasActivityStarted = false
      return
    end

    dUtils.updateRacer(racer)

    local phase = racer.phases[racer.currentPhase]
    dUtils[phase.name](phase, racer, dtSim)
    
    -- Make sure that the vehicle reference is not used outside of phase update
    racer.veh = nil
    
    if phase.completed and not racer.isFinished then
      log('I', logTag, 'Racer: ' .. racer.vehId .. ' completed phase: ' .. phase.name)
      
      if phase.name == "stage" then
        freeroamUtils.displayStagedMessage(racer.vehId, "drag")
      elseif phase.name == "countdown" then
        freeroamUtils.displayStartMessage("drag")
        freeroamUtils.saveAndSetTrafficAmount(0)
      elseif phase.name == "race" then
        -- Use the constant from utils
        local finishSpeed = racer.vehSpeed * freeroamUtils.SPEED_UNIT_MPS_TO_MPH
        freeroamEvents.payoutDragRace("drag", racer.timers.time_1_4.value, finishSpeed, vehId)
        freeroamUtils.restoreTrafficAmount()
      end
      
      dUtils.changeRacerPhase(racer)
    end

    if not dUtils.isRacerInsideBoundary(racer) then
      resetDragRace()
    end
  end
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.startActivity = startActivity
M.resetDragRace = resetDragRace

M.jumpDescualifiedDrag = function()
  -- Stub for disqualification handling
end

return M
