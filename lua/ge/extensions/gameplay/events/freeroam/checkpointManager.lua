local M = {}

local checkpoints = {}
local altCheckpoints = {}
local raceName = nil
local isLoop = false
local mAltRoute = nil
local activeCheckpoints = {}

local race

local function createCheckpoint(index, isAlt)
    local checkpoint
    if isAlt then
        checkpoint = altCheckpoints[index]
    else
        checkpoint = checkpoints[index]
    end
    if not checkpoint then
        --print("Error: No checkpoint data found for index " .. index)
        return
    end

    if not checkpoint.node.width then
        print("No width for checkpoint " .. index)
        checkpoint.node.width = 30
    end

    local position = vec3(checkpoint.node.x, checkpoint.node.y, checkpoint.node.z)
    local radius = checkpoint.node.width

    local triggerRadius = radius

    checkpoint.object = createObject('BeamNGTrigger')
    checkpoint.object:setPosition(position)
    checkpoint.object:setScale(vec3(triggerRadius, triggerRadius, triggerRadius))
    checkpoint.object.triggerType = 0 -- Use 0 for Sphere type

    -- Naming the trigger according to the new scheme
    local triggerName
    if isAlt then
        triggerName = string.format("fre_checkpoint_%s_alt_%d", raceName, index)
    else
        triggerName = string.format("fre_checkpoint_%s_%d", raceName, index)
    end

    if scenetree.findObject(triggerName) then
        local existingTrigger = scenetree.findObject(triggerName)
        existingTrigger:delete()
    end
    checkpoint.object:registerObject(triggerName)

    --print("Checkpoint " .. index .. " created at: " .. tostring(position) .. " with radius: " .. radius)
    return checkpoint
end

local function createCheckpointMarker(index, alt)
    local checkpoint = alt and altCheckpoints[index] or checkpoints[index]
    if not checkpoint then
        --print("No checkpoint data for index " .. index)
        return
    end

    local marker = createObject('TSStatic')
    marker.shapeName = "art/shapes/interface/checkpoint_marker.dae"

    marker:setPosRot(checkpoint.node.x, checkpoint.node.y, checkpoint.node.z, 0, 0, 0, 0)

    marker.scale = vec3(checkpoint.node.width, checkpoint.node.width, checkpoint.node.width)
    marker.useInstanceRenderData = true
    marker.instanceColor = ColorF(1, 0, 0, 0.5):asLinear4F() -- Default to red

    local markerName = (alt and "alt_" or "") .. "checkpoint_" .. index .. "_marker"
    if scenetree.findObject(markerName) then
        local existingMarker = scenetree.findObject(markerName)
        existingMarker:delete()
    end
    marker:registerObject(markerName)

    checkpoint.marker = marker
    table.insert(activeCheckpoints, checkpoint)
    return checkpoint
end

local function removeCheckpointMarker(index, alt)
    local checkpoint = {}
    if alt then
        checkpoint = altCheckpoints[index]
    else
        checkpoint = checkpoints[index]
    end
    if checkpoint and checkpoint.marker then
        checkpoint.marker:delete()
        checkpoint.marker = nil
    end
    return checkpoint
end

local function removeCheckpoint(index, alt)
    local checkpoint = {}
    if alt then
        checkpoint = altCheckpoints[index]
    else
        checkpoint = checkpoints[index]
    end
    if checkpoint then
        if checkpoint.object then
            checkpoint.object:delete()
            checkpoint.object = nil
        end
        if checkpoint.marker then
            checkpoint.marker:delete()
            checkpoint.marker = nil
        end
        --print("Checkpoint " .. index .. " removed")
    end
    return checkpoint
end

local function createCheckpoints(check, altCheck)
    checkpoints = check
    altCheckpoints = altCheck
    for i = 1, #checkpoints do
        removeCheckpoint(i)
    end
    for i = 1, #checkpoints do
        --print("Creating checkpoint " .. i)
        createCheckpoint(i)
    end

    if altCheckpoints then
        for i = 1, #altCheckpoints do
            removeCheckpoint(i, true)
        end
        for i = 1, #altCheckpoints do
            createCheckpoint(i, true)
        end
    end
end

local function resetActiveCheckpoints()
    local checkpoint
    for i = 1, #activeCheckpoints do
        checkpoint = activeCheckpoints[i]
        if checkpoint then
            checkpoint.marker:delete()
            checkpoint.marker = nil
        end
    end
    activeCheckpoints = {}
end

local function enableCheckpoint(checkpointIndex, alt)
    resetActiveCheckpoints()

    local expectedIndex

    -- This logic cleanly separates the two states.
    if mAltRoute then
        -- SCENARIO 1: We are currently on an alternate route.
        expectedIndex = checkpointIndex + 1
        
        -- The next checkpoint to display MUST be blue.
        local currentCp = altCheckpoints and altCheckpoints[expectedIndex]
        if currentCp then
            if not currentCp.marker then createCheckpointMarker(expectedIndex, true) end
            currentCp.marker.instanceColor = ColorF(0, 0, 1, 0.7):asLinear4F() -- Blue
        end

        -- The preview checkpoint (red) must also be from the alt route.
        local previewIndex = expectedIndex + 1
        local previewCp = altCheckpoints and altCheckpoints[previewIndex]
        if previewCp then
            if not previewCp.marker then createCheckpointMarker(previewIndex, true) end
            previewCp.marker.instanceColor = ColorF(1, 0, 0, 0.5):asLinear4F() -- Red
        end

    else
        -- SCENARIO 2: We are currently on the main route.
        expectedIndex = checkpointIndex + 1

        -- The next checkpoint to display MUST be green.
        local currentCp = checkpoints and checkpoints[expectedIndex]
        if currentCp then
            if not currentCp.marker then createCheckpointMarker(expectedIndex, false) end
            currentCp.marker.instanceColor = ColorF(0, 1, 0, 0.7):asLinear4F() -- Green
        end

        -- The preview checkpoint (red) must also be from the main route.
        local previewIndex = expectedIndex + 1
        local previewCp = checkpoints and checkpoints[previewIndex]
        if previewCp then
            if not previewCp.marker then createCheckpointMarker(previewIndex, false) end
            previewCp.marker.instanceColor = ColorF(1, 0, 0, 0.5):asLinear4F() -- Red
        end

        -- BACKWARDS COMPATIBILITY: If this is a classic race, ALSO show the first blue checkpoint.
        if race and race.altRoute and not race.forks and #altCheckpoints > 0 then
            local altStartCp = altCheckpoints[1]
            if altStartCp then
                if not altStartCp.marker then createCheckpointMarker(1, true) end
                altStartCp.marker.instanceColor = ColorF(0, 0, 1, 0.7):asLinear4F() -- Blue
            end
        end
    end

    return expectedIndex
end

local function enableForkCheckpoints(mainIndex, altIndex, raceData)
    resetActiveCheckpoints()
    
    local mainCp = checkpoints[mainIndex]
    local altCp = altCheckpoints[altIndex]

    if mainCp then
        if not mainCp.marker then
            mainCp = createCheckpointMarker(mainIndex, false)
        end
        -- Color for a choice, e.g., blue
        mainCp.marker.instanceColor = ColorF(0, 0, 1, 0.7):asLinear4F() 
    end

    if altCp then
        if not altCp.marker then
            altCp = createCheckpointMarker(altIndex, true)
        end
        -- Color for a choice, e.g., blue
        altCp.marker.instanceColor = ColorF(0, 0, 1, 0.7):asLinear4F()
    end

    -- Return the valid next checkpoint indexes
    return { main = mainIndex, alt = altIndex }
end

local function removeCheckpoints()
    local function removeCheckpointList(checkpointList)
        if not checkpointList or #checkpointList == 0 then
            return
        end

        for i = 1, #checkpointList do
            local checkpoint = checkpointList[i]
            if checkpoint then
                -- Remove the checkpoint object
                if checkpoint.object then
                    checkpoint.object:delete()
                    checkpoint.object = nil
                end

                -- Remove the checkpoint marker
                if checkpoint.marker then
                    checkpoint.marker:delete()
                    checkpoint.marker = nil
                end
            end
        end

        -- Clear the checkpoint list
        for i = 1, #checkpointList do
            checkpointList[i] = nil
        end
    end

    resetActiveCheckpoints()

    -- Remove main checkpoints
    removeCheckpointList(checkpoints)

    -- Remove alternative checkpoints
    removeCheckpointList(altCheckpoints)

    -- Reset the checkpoint tables
    checkpoints = {}
    altCheckpoints = {}
    race = nil
    mAltRoute = nil
end

local function calculateTotalCheckpoints(raceData)
    local mainCount = #checkpoints
    local altCount = altCheckpoints and #altCheckpoints or 0

    if mAltRoute and raceData then
        -- Check which kind of alt route we're on
        if raceData.forks then
            -- SCENARIO 1: It's our new "fork" system
            local forkData = raceData.forks[1] -- Assumes one fork for now
            return forkData.atMainIndex + altCount
        elseif raceData.altRoute and raceData.altRoute.mergeCheckpoints then
            -- SCENARIO 2: It's a classic "altRoute" with a merge point
            local mergePoints = raceData.altRoute.mergeCheckpoints
            -- It calculates: (total alt CPs) + (main CPs after the merge) - (main CPs that were skipped)
            return altCount + (mainCount - mergePoints[2]) + 1
        else
            -- Fallback for a weirdly defined alt route
            return altCount
        end
    else
        -- SCENARIO 3: We're on the main route
        return mainCount
    end
end

local function setAltRoute(altRoute)
end

local function setRace(inputRace, inputRaceName)
    race = inputRace
    raceName = inputRaceName
end

local function onExtensionLoaded()
    print("Initializing Checkpoint Manager")
end

M.onExtensionLoaded = onExtensionLoaded
M.createCheckpoints = createCheckpoints
M.enableCheckpoint = enableCheckpoint
M.enableForkCheckpoints = enableForkCheckpoints
M.removeCheckpoints = removeCheckpoints
M.setAltRoute = setAltRoute
M.setRace = setRace
M.calculateTotalCheckpoints = calculateTotalCheckpoints

return M