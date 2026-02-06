local M = {}

-- ============================================================================
-- STATE
-- ============================================================================

local roadNodes = {}
local altRoadNodes = {}
local checkpoints = {}
local altCheckpoints = {}
local activeRace = nil

-- ============================================================================
-- CONSTANTS (defaults, can be overridden by race data)
-- ============================================================================

local DEFAULT_CONFIG = {
  -- Road processing
  STRAIGHT_THRESHOLD = math.rad(10),    -- Angle threshold for straight segments
  HAIRPIN_THRESHOLD = math.rad(120),    -- Angle threshold for hairpin turns
  MIN_SEGMENT_LENGTH = 20,              -- Minimum length for a segment in meters
  MAX_TURN_MERGE_ANGLE = math.rad(20),  -- Maximum angle difference to merge turns
  MIN_CHECKPOINT_DISTANCE = 90,         -- Minimum distance between checkpoints
  CURVATURE_WINDOW = 3,                 -- Number of nodes for curvature calculation
  
  -- Road merging
  MAX_MERGE_DISTANCE = 50,
  END_SEARCH_RANGE = 0.2,
  
  -- Player tracking
  MAX_DISTANCE_FROM_PATH = 10,          -- meters
  ALERT_COOLDOWN = 3,                   -- seconds
  WRONG_DIRECTION_THRESHOLD = 0.5,      -- cosine of angle
  EXIT_COUNTDOWN_START = 5,             -- seconds
  
  -- Stationary timeout
  STATIONARY_TIMEOUT = 10               -- seconds
}

-- Runtime config (can be modified per-race)
local config = {}
for k, v in pairs(DEFAULT_CONFIG) do
  config[k] = v
end

-- Runtime state for player tracking
local lastAlertTime = 0
local nextNodeIndex = 2
local exitCountdown = 0
local lastCountdownTime = 0

local lastMovementTime = nil
local lastCountdownUpdate = nil
local remainingTime = config.STATIONARY_TIMEOUT

-- ============================================================================
-- MATH HELPERS
-- ============================================================================

--- Calculate distance between two nodes
-- @param node1 table First node {x, y}
-- @param node2 table Second node {x, y}
-- @return number Distance in meters
local function calculateDistance(node1, node2)
  if not node1 or not node2 then
    return 0
  end
  local dx, dy = node2.x - node1.x, node2.y - node1.y
  return math.sqrt(dx * dx + dy * dy)
end

--- Calculate angle and direction between three nodes
-- @param node1 table First node
-- @param node2 table Middle node
-- @param node3 table Third node
-- @return number Angle in radians
-- @return string Direction ("left", "right", or "straight")
-- @return number Angle in degrees
local function calculateAngle(node1, node2, node3)
  if not node1 or not node2 or not node3 then
    return 0, "straight", 0
  end
  
  local vec1 = {
    x = node2.x - node1.x,
    y = node2.y - node1.y
  }
  local vec2 = {
    x = node3.x - node2.x,
    y = node3.y - node2.y
  }
  local angle = math.atan2(vec2.y, vec2.x) - math.atan2(vec1.y, vec1.x)

  -- Normalize angle to be between -pi and pi
  if angle > math.pi then
    angle = angle - 2 * math.pi
  elseif angle < -math.pi then
    angle = angle + 2 * math.pi
  end

  local degrees = math.deg(angle)
  local direction = "straight"
  if degrees > 1 then
    direction = "left"
  elseif degrees < -1 then
    direction = "right"
  end

  return angle, direction, degrees
end

--- Calculate average curvature around an index
-- @param nodes table Array of nodes
-- @param index number Center index
-- @return number Average curvature
local function calculateCurvature(nodes, index)
  local sum = 0
  local count = 0
  for i = math.max(1, index - config.CURVATURE_WINDOW), math.min(#nodes - 2, index + config.CURVATURE_WINDOW) do
    sum = sum + math.abs(calculateAngle(nodes[i], nodes[i + 1], nodes[i + 2]))
    count = count + 1
  end
  return count > 0 and (sum / count) or 0
end

--- Find the apex (point of maximum curvature) in a range
-- @param nodes table Array of nodes
-- @param startIndex number Start index
-- @param endIndex number End index
-- @return number Index of the apex
local function findApex(nodes, startIndex, endIndex)
  local maxCurvature = 0
  local apexIndex = startIndex
  
  for i = startIndex, endIndex do
    local prevNode = nodes[math.max(1, i - 1)]
    local currNode = nodes[i]
    local nextNode = nodes[math.min(#nodes, i + 1)]
    local angle = calculateAngle(prevNode, currNode, nextNode)
    local curvature = math.abs(angle)
    if curvature > maxCurvature then
      maxCurvature = curvature
      apexIndex = i
    end
  end
  
  local apexOffset = activeRace and activeRace.apexOffset or 0
  apexOffset = activeRace and activeRace.reverse and -apexOffset or apexOffset
  apexIndex = nodes[apexIndex + apexOffset] and apexIndex + apexOffset or #nodes
  
  return apexIndex
end

--- Convert table to vec3
-- @param t table Table with x, y, z keys
-- @return vec3 Vector
local function vec3FromTable(t)
  return vec3(t.x, t.y, t.z)
end

--- Calculate distance from a point to a line segment
-- @param point vec3 The point
-- @param lineStart table Start of line segment
-- @param lineEnd table End of line segment
-- @return number Distance
-- @return number Parameter t (0-1) along the segment
local function distanceToLineSegment(point, lineStart, lineEnd)
  local lineVec = vec3FromTable(lineEnd) - vec3FromTable(lineStart)
  local pointVec = point - vec3FromTable(lineStart)
  local lineLength = lineVec:length()

  if lineLength < 0.001 then
    return pointVec:length(), 0
  end

  local t = pointVec:dot(lineVec) / (lineLength * lineLength)
  t = math.max(0, math.min(1, t))

  local projection = vec3FromTable(lineStart) + lineVec * t

  return (point - projection):length(), t
end

--- Find the nearest node to a position
-- @param vehiclePos vec3 Position to search from
-- @param nodes table Array of nodes
-- @return number Index of nearest node
-- @return number Distance to nearest node
local function findNearestNode(vehiclePos, nodes)
  if not nodes or #nodes == 0 then
    return nil, nil
  end
  
  local nearestIndex = 1
  local minDistance = math.huge
  
  for i, node in ipairs(nodes) do
    local distance = (vehiclePos - vec3FromTable(node)):length()
    if distance < minDistance then
      minDistance = distance
      nearestIndex = i
    end
  end
  
  return nearestIndex, minDistance
end

-- ============================================================================
-- ROAD PROCESSING
-- ============================================================================

--- Get a DecalRoad object by name
-- @param roadName string Name of the road
-- @return object|nil The road object or nil if not found
local function getRoad(roadName)
  local road = scenetree.findObject(roadName)
  if road and road:getClassName() == "DecalRoad" then
    return road
  else
    return nil
  end
end

--- Get nodes from a road by name
-- @param roadName string Name of the road
-- @return table|nil Array of nodes or nil if road not found
local function getRoadNodes(roadName)
  local road = scenetree.findObject(roadName)
  
  -- Check if road exists BEFORE trying to access its methods
  if not road then
    return nil
  end
  
  if road:getClassName() ~= "DecalRoad" then
    return nil
  end

  local nodeTable = road:getNodesTable()
  local nodeCount = road:getNodeCount()
  
  local nodes = {}
  for i = 0, nodeCount - 1 do
    local pos = road:getNodePosition(i)
    table.insert(nodes, {
      x = pos.x,
      y = pos.y,
      z = pos.z,
      width = nodeTable[i + 1] and nodeTable[i + 1][2] or 20
    })
  end
  
  return nodes
end

--- Find closest endpoints between two sets of nodes for merging
-- @param nodes1 table First node array
-- @param nodes2 table Second node array
-- @return table Array of connection candidates
local function findClosestEndPoints(nodes1, nodes2)
  local connections = {}
  local searchRange1 = math.floor(#nodes1 * config.END_SEARCH_RANGE)
  local searchRange2 = math.floor(#nodes2 * config.END_SEARCH_RANGE)

  local function checkConnection(start1, end1, start2, end2, isStart1, isStart2)
    local minDist = math.huge
    local bestIndex1, bestIndex2

    for i = start1, end1, start1 < end1 and 1 or -1 do
      for j = start2, end2, start2 < end2 and 1 or -1 do
        local dist = calculateDistance(nodes1[i], nodes2[j])
        if dist < minDist then
          minDist = dist
          bestIndex1, bestIndex2 = i, j
        end
      end
    end

    if minDist <= config.MAX_MERGE_DISTANCE then
      table.insert(connections, {
        index1 = bestIndex1,
        index2 = bestIndex2,
        distance = minDist,
        isStart1 = isStart1,
        isStart2 = isStart2
      })
    end
  end

  -- Check all combinations
  checkConnection(1, searchRange1, 1, searchRange2, true, true)
  checkConnection(1, searchRange1, #nodes2, #nodes2 - searchRange2 + 1, true, false)
  checkConnection(#nodes1, #nodes1 - searchRange1 + 1, 1, searchRange2, false, true)
  checkConnection(#nodes1, #nodes1 - searchRange1 + 1, #nodes2, #nodes2 - searchRange2 + 1, false, false)

  table.sort(connections, function(a, b)
    return a.distance < b.distance
  end)
  
  return connections
end

--- Merge two road node arrays
-- @param nodes1 table First node array (direction preserved)
-- @param nodes2 table Second node array
-- @return table|nil Merged node array or nil if cannot merge
local function mergeTwoRoads(nodes1, nodes2)
  local connections = findClosestEndPoints(nodes1, nodes2)

  if #connections == 0 then
    return nil
  end

  local mergedNodes = {}

  local function createJunction(node1, node2)
    return {
      x = (node1.x + node2.x) / 2,
      y = (node1.y + node2.y) / 2,
      z = (node1.z + node2.z) / 2,
      width = (node1.width + node2.width) / 2,
      isJunction = true
    }
  end

  -- Always preserve the first road's direction
  for i = 1, #nodes1 do
    table.insert(mergedNodes, nodes1[i])
  end
  
  -- Handle single connection point case (for loops)
  if #connections == 1 then
    local conn = connections[1]
    local connectionIndex = conn.index1
    local isStart2 = conn.isStart2
    
    -- Replace the original node with a junction
    mergedNodes[connectionIndex] = createJunction(nodes1[connectionIndex], nodes2[conn.index2])
    
    -- Add nodes from second road
    if isStart2 then
      for i = 2, #nodes2 do
        table.insert(mergedNodes, nodes2[i])
      end
    else
      for i = #nodes2 - 1, 1, -1 do
        table.insert(mergedNodes, nodes2[i])
      end
    end
    
    return mergedNodes
  end

  -- Dual connection point case
  mergedNodes = {}
  
  local conn1 = connections[1]
  
  -- Determine if we need to reverse the second road
  local reverseRoad2 = conn1.isStart1 == conn1.isStart2
  
  -- Add nodes from the first road normally
  for i = 1, #nodes1 do
    table.insert(mergedNodes, nodes1[i])
  end
  
  -- Add junction at the connection point
  local junctionIndex = conn1.isStart1 and 1 or #mergedNodes
  mergedNodes[junctionIndex] = createJunction(nodes1[conn1.index1], nodes2[conn1.index2])
  
  -- Add nodes from road2 based on needed direction
  if reverseRoad2 then
    for i = #nodes2, 1, -1 do
      if i ~= conn1.index2 then
        table.insert(mergedNodes, nodes2[i])
      end
    end
  else
    for i = 1, #nodes2 do
      if i ~= conn1.index2 then
        table.insert(mergedNodes, nodes2[i])
      end
    end
  end
  
  return mergedNodes
end

--- Merge multiple roads into one
-- @param roads table Array of road names
-- @return table|nil Merged node array or nil if failed
local function mergeRoads(roads)
  if type(roads) ~= "table" or #roads < 1 then
    return nil
  end
  
  if #roads == 1 then
    return getRoadNodes(roads[1])
  end

  local result = getRoadNodes(roads[1])
  if not result then
    print("First road not found or invalid: " .. roads[1])
    return nil
  end
  
  for i = 2, #roads do
    local nextRoadNodes = getRoadNodes(roads[i])
    if not nextRoadNodes then
      print("Road not found or invalid: " .. roads[i])
      goto continue
    end
    
    local mergedResult = mergeTwoRoads(result, nextRoadNodes)
    if mergedResult then
      result = mergedResult
    else
      print("Failed to merge road " .. roads[i])
    end
    
    ::continue::
  end
  
  return result
end

-- ============================================================================
-- CHECKPOINT PROCESSING
-- ============================================================================

--- Process road nodes into checkpoints
-- @param mainNodes table Main route nodes
-- @param altNodes table|nil Alternative route nodes
-- @return table Main checkpoints
-- @return table|nil Alt checkpoints
local function processRoadNodes(mainNodes, altNodes)
  altNodes = altNodes or {}

  local function processRoute(nodes, isAlt)
    print("Processing route with " .. #nodes .. " nodes")
    local segments = {}
    local routeCheckpoints = {}
    local currentSegment = {
      startIndex = 1,
      type = "straight",
      totalAngle = 0,
      length = 0,
      direction = nil
    }
    local startIndex = isAlt and 3 or 1

    local function addCheckpoint(segStartIndex, endIndex, segType, direction)
      local apexIndex = findApex(nodes, segStartIndex, endIndex)
      
      local function isDuplicatePosition(newPos)
        for _, checkpoint in ipairs(routeCheckpoints) do
          if checkpoint.node.x == newPos.x and checkpoint.node.y == newPos.y and checkpoint.node.z == newPos.z then
            return true
          end
        end
        return false
      end
      
      -- Check for existing checkpoints with same direction
      if #routeCheckpoints > 0 then
        local lastCheckpoint = routeCheckpoints[#routeCheckpoints]
        if lastCheckpoint.direction == direction then
          local distance = calculateDistance(nodes[lastCheckpoint.index], nodes[apexIndex])
          if distance < config.MIN_CHECKPOINT_DISTANCE then
            if calculateCurvature(nodes, apexIndex) > calculateCurvature(nodes, lastCheckpoint.index) then
              if not isDuplicatePosition(nodes[apexIndex]) then
                routeCheckpoints[#routeCheckpoints] = {
                  node = nodes[apexIndex],
                  type = segType,
                  index = apexIndex,
                  direction = direction
                }
              end
            end
            return
          end
        end
      end
      
      if not isDuplicatePosition(nodes[apexIndex]) then
        table.insert(routeCheckpoints, {
          node = nodes[apexIndex],
          type = segType,
          index = apexIndex,
          direction = direction
        })
      end
    end

    local function finishSegment(endIndex)
      if currentSegment.length >= config.MIN_SEGMENT_LENGTH then
        table.insert(segments, currentSegment)
        if currentSegment.type == "turn" or currentSegment.type == "hairpin" then
          addCheckpoint(currentSegment.startIndex, endIndex, currentSegment.type, currentSegment.direction)
        end
      end
    end

    for i = startIndex + 1, #nodes - 1 do
      local angle = calculateAngle(nodes[i - 1], nodes[i], nodes[i + 1])
      currentSegment.totalAngle = currentSegment.totalAngle + angle
      currentSegment.length = currentSegment.length + calculateDistance(nodes[i - 1], nodes[i])

      if math.abs(angle) > config.STRAIGHT_THRESHOLD then
        local newDirection = angle > 0 and "left" or "right"
        if currentSegment.type == "straight" then
          finishSegment(i - 1)
          currentSegment = {
            startIndex = i - 1,
            type = "turn",
            direction = newDirection,
            totalAngle = angle,
            length = 0
          }
        elseif currentSegment.type == "turn" then
          if currentSegment.direction ~= newDirection then
            finishSegment(i - 1)
            currentSegment = {
              startIndex = i - 1,
              type = "turn",
              direction = newDirection,
              totalAngle = angle,
              length = 0
            }
          elseif math.abs(currentSegment.totalAngle - angle) > config.MAX_TURN_MERGE_ANGLE then
            addCheckpoint(currentSegment.startIndex, i, "turn", newDirection)
            currentSegment.totalAngle = angle
            currentSegment.startIndex = i
          end
        end
      elseif currentSegment.type == "turn" and currentSegment.length >= config.MIN_SEGMENT_LENGTH then
        finishSegment(i - 1)
        currentSegment = {
          startIndex = i - 1,
          type = "straight",
          totalAngle = 0,
          length = 0,
          direction = nil
        }
      end

      if math.abs(currentSegment.totalAngle) > config.HAIRPIN_THRESHOLD then
        currentSegment.type = "hairpin"
        finishSegment(i)
        currentSegment = {
          startIndex = i,
          type = "straight",
          totalAngle = 0,
          length = 0,
          direction = nil
        }
      end
    end

    finishSegment(#nodes)

    return routeCheckpoints
  end

  local mainCheckpoints = processRoute(mainNodes, false)
  local processedAltCheckpoints = #altNodes > 0 and processRoute(altNodes, true) or nil

  -- Adjust the last checkpoint if it's too close to the first one
  local function adjustLastCheckpoint(cpList, nodes)
    if #cpList >= 2 then
      local firstCheckpoint = cpList[1]
      local lastCheckpoint = cpList[#cpList]
      local distance = calculateDistance(firstCheckpoint.node, lastCheckpoint.node)

      if distance < config.MIN_CHECKPOINT_DISTANCE then
        local newLastIndex = lastCheckpoint.index
        while newLastIndex > 1 and calculateDistance(nodes[newLastIndex], firstCheckpoint.node) < config.MIN_CHECKPOINT_DISTANCE do
          newLastIndex = newLastIndex - 1
        end

        if newLastIndex > 1 and newLastIndex ~= lastCheckpoint.index then
          lastCheckpoint.node = nodes[newLastIndex]
          lastCheckpoint.index = newLastIndex
        end
      end
    end
  end

  adjustLastCheckpoint(mainCheckpoints, mainNodes)
  if processedAltCheckpoints then
    adjustLastCheckpoint(processedAltCheckpoints, altNodes)
  end

  return mainCheckpoints, processedAltCheckpoints
end

--- Flip checkpoint directions for reverse races
-- @param originalCheckpoints table Array of checkpoints
-- @return table|nil Flipped checkpoints
local function flipCheckpoints(originalCheckpoints)
  if not originalCheckpoints or #originalCheckpoints == 0 then
    return nil
  end
  
  local flipped = {}
  for i = #originalCheckpoints, 1, -1 do
    local cp = originalCheckpoints[i]
    local newDirection = "straight"
    
    if cp.direction == "left" then
      newDirection = "right"
    elseif cp.direction == "right" then
      newDirection = "left"
    end
    
    table.insert(flipped, {
      node = cp.node,
      type = cp.type,
      index = cp.index,
      direction = newDirection,
    })
  end
  
  return flipped
end

--- Create checkpoints from node indices
-- @param indices table Array of node indices
-- @param nodes table Road nodes
-- @return table Array of checkpoints
local function getNodeIndexCheckpoints(indices, nodes)
  local result = {}
  for i = 1, #indices do
    local idx = indices[i]
    if nodes[idx - 1] and nodes[idx] and nodes[idx + 1] then
      local angle = calculateAngle(nodes[idx - 1], nodes[idx], nodes[idx + 1])
      table.insert(result, {
        node = nodes[idx],
        type = "manual",
        index = idx,
        direction = angle > 0 and "left" or "right"
      })
    end
  end
  return result
end

--- Get road nodes from a race definition
-- @param race table Race data
-- @return table|nil Road nodes
local function getRoadNodesFromRace(race)
  if not race or not race.checkpointRoad then
    return nil
  end
  
  if type(race.checkpointRoad) == "table" then
    if not race.checkpointRoad[2] then
      return getRoadNodes(race.checkpointRoad[1])
    else
      return mergeRoads(race.checkpointRoad)
    end
  else
    return getRoadNodes(race.checkpointRoad)
  end
end

--- Get checkpoints for a race
-- @param race table Race data
-- @return table Main checkpoints
-- @return table|nil Alt checkpoints
local function getCheckpoints(race)
  -- Apply race-specific config
  config.MIN_CHECKPOINT_DISTANCE = race.minCheckpointDistance or DEFAULT_CONFIG.MIN_CHECKPOINT_DISTANCE
  
  if not race.checkpointRoad then
    return nil, nil
  end
  
  -- Clear existing data
  roadNodes = nil
  altRoadNodes = nil
  checkpoints = nil
  altCheckpoints = nil
  activeRace = race
  
  -- Load main route nodes
  roadNodes = getRoadNodesFromRace(race)
  if not roadNodes then
    return nil, nil
  end

  -- Check for alternative route
  if race.altRoute and race.altRoute.checkpointRoad then
    altRoadNodes = getRoadNodesFromRace(race.altRoute)
    if race.altRoute.checkpointIndexs then
      checkpoints = getNodeIndexCheckpoints(race.checkpointIndexs, roadNodes)
      altCheckpoints = getNodeIndexCheckpoints(race.altRoute.checkpointIndexs, altRoadNodes)
    else
      checkpoints, altCheckpoints = processRoadNodes(roadNodes, altRoadNodes)
    end
  else
    if race.checkpointIndexs then
      checkpoints = getNodeIndexCheckpoints(race.checkpointIndexs, roadNodes)
    else
      checkpoints = processRoadNodes(roadNodes)
    end
    altCheckpoints = nil
  end

  -- Handle reverse races
  if race.reverse then
    print("Flipping checkpoints")
    checkpoints = flipCheckpoints(checkpoints)
    if altCheckpoints then
      altCheckpoints = flipCheckpoints(altCheckpoints)
    end
  end
  
  return checkpoints, altCheckpoints
end

-- ============================================================================
-- PLAYER TRACKING
-- ============================================================================

--- Check if the player vehicle is on the road
-- @return boolean True if on road, false if exited
local function checkPlayerOnRoad()
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then
    return false
  end

  local vehiclePos = playerVehicle:getPosition()
  local vehicleVel = playerVehicle:getVelocity()
  local currentTime = os.time()

  -- Check for stationary timeout
  if vehicleVel:length() < 0.5 then
    if not lastMovementTime then
      lastMovementTime = currentTime
      lastCountdownUpdate = currentTime
      remainingTime = config.STATIONARY_TIMEOUT
    else
      local timeStopped = currentTime - lastMovementTime
      
      if currentTime - lastCountdownUpdate >= 1 then
        remainingTime = config.STATIONARY_TIMEOUT - timeStopped
        lastCountdownUpdate = currentTime
        
        if remainingTime > 0 then
          ui_message("Warning: Move your vehicle! Race ends in " .. remainingTime .. " seconds!", 2, "info")
        end
      end
      
      if timeStopped >= config.STATIONARY_TIMEOUT then
        return false
      end
    end
  else
    lastMovementTime = nil
    lastCountdownUpdate = nil
    remainingTime = config.STATIONARY_TIMEOUT
  end

  -- Check distance to both routes
  local mainNearestIndex, mainDistance = findNearestNode(vehiclePos, roadNodes)
  local altNearestIndex, altDistance = findNearestNode(vehiclePos, altRoadNodes)

  if not mainNearestIndex then
    return true
  end
  
  altDistance = altDistance or 1000000

  local useAltRoute = altDistance < mainDistance
  local currentNodes = useAltRoute and altRoadNodes or roadNodes
  local nearestNodeIndex = useAltRoute and altNearestIndex or mainNearestIndex

  local currentNode = currentNodes[nearestNodeIndex]
  local nextIdx = (nearestNodeIndex % #currentNodes) + 1
  local prevIdx = ((nearestNodeIndex - 2) % #currentNodes) + 1
  local nextNode = currentNodes[nextIdx]
  local prevNode = currentNodes[prevIdx]

  local distanceFromPath, t = distanceToLineSegment(vehiclePos, currentNode, nextNode)
  
  -- Consider adjacent segments
  if t < 0.1 then
    local prevDistance, prevT = distanceToLineSegment(vehiclePos, prevNode, currentNode)
    if prevDistance < distanceFromPath then
      distanceFromPath = prevDistance
      t = prevT
    end
  elseif t > 0.9 then
    local nextNextNode = currentNodes[(nextIdx % #currentNodes) + 1]
    local nextDistance, nextT = distanceToLineSegment(vehiclePos, nextNode, nextNextNode)
    if nextDistance < distanceFromPath then
      distanceFromPath = nextDistance
      t = nextT
    end
  end

  -- Check for wrong direction
  local isWrongDirection = false
  if vehicleVel:length() > 1 then
    local playerDirection = vehicleVel:normalized()
    local forwardDirection = (vec3FromTable(nextNode) - vec3FromTable(currentNode)):normalized()
    local backwardDirection = (vec3FromTable(prevNode) - vec3FromTable(currentNode)):normalized()
    local forwardDot = playerDirection:dot(forwardDirection)
    local backwardDot = playerDirection:dot(backwardDirection)
    isWrongDirection = forwardDot < config.WRONG_DIRECTION_THRESHOLD and backwardDot < config.WRONG_DIRECTION_THRESHOLD
  end

  -- Handle exit countdown
  if distanceFromPath > (config.MAX_DISTANCE_FROM_PATH + 25) then
    if exitCountdown == 0 then
      exitCountdown = config.EXIT_COUNTDOWN_START
      ui_message("Warning: You are exiting the event! " .. exitCountdown .. " seconds to return!", 3, "info")
      lastCountdownTime = currentTime
    elseif currentTime - lastCountdownTime >= 1 then
      exitCountdown = exitCountdown - 1
      lastCountdownTime = currentTime
      if exitCountdown > 0 then
        ui_message("Exiting event in " .. exitCountdown .. " seconds!", 2, "info")
      else
        ui_message("Event exited!", 3, "info")
        return false
      end
    end
  elseif isWrongDirection then
    if currentTime - lastAlertTime > config.ALERT_COOLDOWN then
      lastAlertTime = currentTime
    end
  else
    if exitCountdown > 0 then
      exitCountdown = 0
      ui_message("Back on track!", 2, "info")
    end
  end

  return true
end

--- Check if the road forms a loop
-- @return boolean True if the road is a loop
local function isLoop()
  if not roadNodes or #roadNodes < 3 then
    return false
  end

  local firstNode = roadNodes[1]
  local lastNode = roadNodes[#roadNodes]

  return math.abs(firstNode.x - lastNode.x) < config.MAX_MERGE_DISTANCE and 
         math.abs(firstNode.y - lastNode.y) < config.MAX_MERGE_DISTANCE and
         math.abs(firstNode.z - lastNode.z) < config.MAX_MERGE_DISTANCE
end

--- Set the stationary timeout value
-- @param timeout number|nil Timeout in seconds (uses default if nil)
local function setStationaryTimeout(timeout)
  config.STATIONARY_TIMEOUT = timeout or DEFAULT_CONFIG.STATIONARY_TIMEOUT
  remainingTime = config.STATIONARY_TIMEOUT
end

-- ============================================================================
-- TRACK DISTANCE CALCULATIONS
-- ============================================================================

--- Calculate track distances including total length and checkpoint distances
-- @param nodes table Road nodes array
-- @param cpList table Checkpoints array (from processRoadNodes)
-- @return table Distance data with totalLength, checkpointDistances, segmentLengths
local function calculateTrackDistances(nodes, cpList)
  if not nodes or #nodes < 2 then
    return {
      totalLength = 0,
      checkpointDistances = {},
      segmentLengths = {},
      nodeDistances = {}
    }
  end

  -- Build cumulative distance for each node
  local nodeDistances = {0}  -- First node is at distance 0
  local totalLength = 0
  
  for i = 2, #nodes do
    local segmentDist = calculateDistance(nodes[i-1], nodes[i])
    totalLength = totalLength + segmentDist
    nodeDistances[i] = totalLength
  end

  -- Calculate checkpoint distances
  local checkpointDistances = {}
  local segmentLengths = {}
  local prevCheckpointDist = 0

  if cpList and #cpList > 0 then
    for i, cp in ipairs(cpList) do
      local cpIndex = cp.index or 1
      -- Clamp to valid range
      cpIndex = math.max(1, math.min(cpIndex, #nodes))
      local cpDist = nodeDistances[cpIndex] or 0
      
      checkpointDistances[i] = cpDist
      segmentLengths[i] = cpDist - prevCheckpointDist
      prevCheckpointDist = cpDist
    end
  end

  return {
    totalLength = totalLength,
    checkpointDistances = checkpointDistances,
    segmentLengths = segmentLengths,
    nodeDistances = nodeDistances
  }
end

--- Calculate live distance for a player position on the track
-- @param nodes table Road nodes array
-- @param playerPos vec3 Player position
-- @param trackDistances table Result from calculateTrackDistances
-- @param currentCheckpoint number|nil Current checkpoint index (1-based)
-- @return table Distance info with completed, remaining, progress, toNextCheckpoint
local function calculateLiveDistance(nodes, playerPos, trackDistances, currentCheckpoint)
  if not nodes or #nodes < 2 or not trackDistances or not playerPos then
    return {
      completed = 0,
      remaining = trackDistances and trackDistances.totalLength or 0,
      progress = 0,
      toNextCheckpoint = 0
    }
  end

  local nodeDistances = trackDistances.nodeDistances
  local totalLength = trackDistances.totalLength
  
  if not nodeDistances or #nodeDistances == 0 then
    return {
      completed = 0,
      remaining = totalLength,
      progress = 0,
      toNextCheckpoint = 0
    }
  end

  -- Find the nearest road segment
  local nearestIndex = 1
  local minDistance = math.huge
  local nearestT = 0  -- Interpolation parameter along segment

  for i = 1, #nodes - 1 do
    local dist, t = distanceToLineSegment(playerPos, nodes[i], nodes[i + 1])
    if dist < minDistance then
      minDistance = dist
      nearestIndex = i
      nearestT = t
    end
  end

  -- Calculate completed distance with interpolation
  local baseDist = nodeDistances[nearestIndex] or 0
  local nextDist = nodeDistances[nearestIndex + 1] or baseDist
  local segmentLength = nextDist - baseDist
  local completed = baseDist + (segmentLength * nearestT)
  
  -- Clamp to valid range
  completed = math.max(0, math.min(completed, totalLength))
  local remaining = totalLength - completed
  local progress = totalLength > 0 and (completed / totalLength) or 0

  -- Calculate distance to next checkpoint
  local toNextCheckpoint = 0
  if currentCheckpoint and trackDistances.checkpointDistances then
    local nextCpIndex = currentCheckpoint + 1
    if trackDistances.checkpointDistances[nextCpIndex] then
      toNextCheckpoint = math.max(0, trackDistances.checkpointDistances[nextCpIndex] - completed)
    elseif nextCpIndex > #trackDistances.checkpointDistances then
      -- Past all checkpoints, distance to finish
      toNextCheckpoint = remaining
    end
  end

  return {
    completed = completed,
    remaining = remaining,
    progress = progress,
    toNextCheckpoint = toNextCheckpoint
  }
end

--- Reset all state
local function reset()
  roadNodes = nil
  altRoadNodes = nil
  checkpoints = nil
  altCheckpoints = nil
  activeRace = nil
  exitCountdown = 0
  lastMovementTime = nil
  lastCountdownUpdate = nil
  remainingTime = config.STATIONARY_TIMEOUT
  
  -- Reset config to defaults
  for k, v in pairs(DEFAULT_CONFIG) do
    config[k] = v
  end
end

local function onExtensionLoaded()
  print("Initializing Road Processing")
end

-- ============================================================================
-- MODULE EXPORTS
-- ============================================================================

M.getCheckpoints = getCheckpoints
M.getRoadNodesFromRace = getRoadNodesFromRace
M.isLoop = isLoop
M.reset = reset
M.checkPlayerOnRoad = checkPlayerOnRoad
M.setStationaryTimeout = setStationaryTimeout
M.onExtensionLoaded = onExtensionLoaded

-- Track distance functions
M.calculateTrackDistances = calculateTrackDistances
M.calculateLiveDistance = calculateLiveDistance

-- Accessor for current road nodes
M.getRoadNodes = function() return roadNodes end
M.getAltRoadNodes = function() return altRoadNodes end
M.getCurrentCheckpoints = function() return checkpoints end

return M
