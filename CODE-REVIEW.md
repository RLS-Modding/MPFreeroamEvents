# MPFreeroamEvents Code Review

**Reviewer:** Claude (Code Review Agent)  
**Date:** 2026-02-06  
**Repository:** MPFreeroamEvents  
**Purpose:** BeamNG.drive mod for multiplayer freeroam events (races, drag races, leaderboards)

---

## Executive Summary

This is a well-structured BeamNG mod with clean module separation. The core racing logic is solid, and the event system leverages BeamNG's trigger system effectively. However, there are several **critical issues** around nil-safety and career mode guards that could cause crashes, plus some **moderate concerns** around synchronization in multiplayer contexts and potential performance bottlenecks.

**Overall Assessment:** Good foundation, needs hardening for production use.

---

## 🔴 Critical Issues

### 1. Missing Career Mode Guards (Multiple Files)

**File:** `freeroamEvents.lua`  
**Lines:** ~91-100, ~183, ~258, and throughout

The code frequently accesses `career_career` and related modules without proper nil checks. According to BeamNG anti-patterns, this is a common source of crashes.

**Problem:**
```lua
-- Line 91-93 in freeroamEvents.lua
if career_modules_hardcore.isHardcoreMode() then
    -- CRASH if career_career is not active or module not loaded
```

```lua
-- Line 183
career_saveSystem.saveCurrent()
-- No check if career is active
```

**Fix:** Always guard career module access:
```lua
if career_career and career_career.isActive() then
    if career_modules_hardcore and career_modules_hardcore.isHardcoreMode() then
        -- safe to use
    end
end
```

**Affected locations:**
- `freeroamEvents.lua`: Lines 91, 95, 183, 191, 215, 224, 231, 258, 280, 344, 446, 518
- `leaderboardManager.lua`: Lines 7, 88, 101
- `utils.lua`: Lines 279, 357-360

---

### 2. Race Condition in Vehicle Spawn Flow

**File:** `freeroamEvents.lua`  
**Lines:** 282-290

When staging for a drag race, the code immediately accesses vehicle properties without waiting for the vehicle engine (VE) to be ready.

**Problem:**
```lua
-- Lines 282-290
if raceName == "drag" then
    utils.initDisplays()
    utils.resetDisplays()
end
staged = raceName
-- Vehicle data accessed here may not be ready
```

**Risk:** If a player spawns a new vehicle and immediately stages, the VE Lua context may not be fully initialized, leading to dropped commands or stale data.

**Fix:** Use `onVehicleSpawned` hook or implement a callback chain to ensure VE is ready before staging.

---

### 3. Nil Check Missing on `be:getPlayerVehicle(0)`

**File:** `pits.lua`  
**Lines:** 25, 36, 72, 145, 155

Multiple locations call `be:getPlayerVehicle(0)` without checking for nil.

**Problem:**
```lua
-- Line 145 in pits.lua
local function toggleSpeedLimit()
    -- ...
    be:getPlayerVehicle(0):queueLuaCommand([[
        -- CRASH if player has no vehicle (walking mode, loading state)
    ]])
end
```

**Fix:**
```lua
local veh = be:getPlayerVehicle(0)
if not veh then return end
veh:queueLuaCommand([[...]])
```

---

### 4. Unprotected `map.objects` Access

**File:** `utils.lua`  
**Line:** 406

**Problem:**
```lua
local function getVehicleDamage()
    local playerVehicleId = be:getPlayerVehicleID(0)
    return map.objects[playerVehicleId] and map.objects[playerVehicleId].damage or 0
end
```

This is good defensive code, but `be:getPlayerVehicleID(0)` can return `-1` or `nil` when there's no player vehicle, and `map.objects[-1]` is undefined behavior.

**Fix:**
```lua
local function getVehicleDamage()
    local playerVehicleId = be:getPlayerVehicleID(0)
    if not playerVehicleId or playerVehicleId < 0 then return 0 end
    return map.objects[playerVehicleId] and map.objects[playerVehicleId].damage or 0
end
```

---

### 5. Missing `scenetree` Object Validation

**File:** `checkpointManager.lua`  
**Lines:** 17-47

When creating checkpoint triggers, the code doesn't validate that the scenetree operations succeeded.

**Problem:**
```lua
-- Line 37
checkpoint.object = createObject('BeamNGTrigger')
checkpoint.object:setPosition(position)  -- CRASH if createObject returned nil
```

**Fix:**
```lua
checkpoint.object = createObject('BeamNGTrigger')
if not checkpoint.object then
    log('E', 'checkpointManager', 'Failed to create checkpoint trigger')
    return nil
end
checkpoint.object:setPosition(position)
```

---

## 🟠 Moderate Issues

### 6. Global State Pollution in MPevents.lua

**File:** `MPevents.lua`  
**Lines:** 11-21

Module-level state is managed correctly with local variables, but the FFI usage introduces potential memory issues.

**Problem:**
```lua
local ffi = require("ffi")
-- ...
local reasonBuffer = im.ArrayChar(256)
for i = 1, #actionDialogState.reason do
    reasonBuffer[i-1] = string.byte(actionDialogState.reason, i)
end
```

The `reasonBuffer` is created fresh each frame in `showActionDialog`, but there's no null-terminator handling if the reason is shorter than previous input.

**Fix:** Clear the buffer before populating:
```lua
ffi.fill(reasonBuffer, 256, 0)  -- Clear buffer
for i = 1, #actionDialogState.reason do
    reasonBuffer[i-1] = string.byte(actionDialogState.reason, i)
end
```

---

### 7. Inconsistent Error Handling in Leaderboard Operations

**File:** `leaderboardManager.lua`  
**Lines:** 63-97

The `isBestTime` function has deeply nested conditionals that return `true` at multiple points, making the logic hard to follow and prone to bugs.

**Problem:**
```lua
local function isBestTime(entry)
    -- Multiple early returns, inconsistent path handling
    if entry.driftScore and entry.driftScore > 0 then
        if not leaderboardEntry.driftScore then
            return true
        end
        return entry.driftScore > leaderboardEntry.driftScore
    end
    -- More branches...
end
```

**Recommendation:** Refactor to use early-exit pattern consistently and add logging for debugging:
```lua
local function isBestTime(entry)
    if not leaderboard then return true end
    
    local existingEntry = getLeaderboardEntry(entry.inventoryId, entry.raceLabel)
    if not existingEntry or not existingEntry.time then return true end
    
    -- Single comparison logic based on race type
    if entry.driftScore and entry.driftScore > 0 then
        return entry.driftScore > (existingEntry.driftScore or 0)
    end
    -- etc.
end
```

---

### 8. MP Sync Issues - Vehicle Hiding Without Verification

**File:** `MPevents.lua`  
**Lines:** 267-297

The `MP_hideVehicles` function assumes `MPVehicleGE` exists and has the expected API.

**Problem:**
```lua
local function MP_hideVehicles(vehicleList)
    -- ...
    local gameVehicleID = MPVehicleGE.getGameVehicleID(vehicleId)  -- CRASH if not in MP
    if gameVehicleID and not MPVehicleGE.isOwn(gameVehicleID) then
```

**Fix:**
```lua
local function MP_hideVehicles(vehicleList)
    if not MPVehicleGE then
        log('W', 'MPevents', 'MPVehicleGE not available - not in multiplayer?')
        return
    end
    -- ...
end
```

---

### 9. Potential Performance Issue in `checkPlayerOnRoad`

**File:** `processRoad.lua`  
**Lines:** 320-410

This function is called every frame via `onUpdate` and performs:
1. `findNearestNode` - O(n) scan through all road nodes
2. Multiple `distanceToLineSegment` calculations
3. UI message updates with `ui_message`

**Problem:** For tracks with many nodes, this could cause frame drops.

**Recommendation:**
1. Use spatial indexing (quadtree) for nearest-node lookup
2. Cache the last known segment and search nearby first
3. Throttle UI updates (not every frame)

```lua
local lastKnownSegment = nil
local uiUpdateTimer = 0

local function checkPlayerOnRoad()
    -- Start search from lastKnownSegment if available
    local searchStart = lastKnownSegment and math.max(1, lastKnownSegment - 5) or 1
    -- ...
    
    uiUpdateTimer = uiUpdateTimer + dt
    if uiUpdateTimer > 0.5 then
        uiUpdateTimer = 0
        ui_message(...)
    end
end
```

---

### 10. Hardcoded Speed Unit Conversion

**File:** `freeroamEvents.lua`  
**Line:** 18

**Problem:**
```lua
local speedUnit = 2.2369362921
```

Magic number without documentation. This is m/s to mph conversion, but it's easy to forget.

**Fix:**
```lua
-- Convert m/s to mph (meters per second * 2.237 ≈ miles per hour)
local MPS_TO_MPH = 2.2369362921
```

---

### 11. Server-Side Leaderboard Missing Input Validation

**File:** `server/Leaderboard.lua`  
**Lines:** 42-54

The `saveLeaderboard` function accepts data from clients without sanitization.

**Problem:**
```lua
function saveLeaderboard(playerID, data)
    if data and type(data) == "table" then
        if savePlayerLeaderboard(playerID, data.data) then
            -- Blindly trusts client data structure
```

**Security Risk:** Malicious clients could send oversized data or invalid structures.

**Fix:**
```lua
function saveLeaderboard(playerID, data)
    if not data or type(data) ~= "table" then
        print("[LeaderboardManager-Event] Invalid data type from player: " .. tostring(playerID))
        return
    end
    
    -- Validate structure
    if not data.data or type(data.data) ~= "table" then
        print("[LeaderboardManager-Event] Invalid data.data from player: " .. tostring(playerID))
        return
    end
    
    -- Size check (prevent DoS via huge payloads)
    local encoded = json.encode(data.data)
    if #encoded > 1024 * 100 then  -- 100KB limit
        print("[LeaderboardManager-Event] Data too large from player: " .. tostring(playerID))
        return
    end
    
    savePlayerLeaderboard(playerID, data.data)
end
```

---

## 🟡 Minor Issues

### 12. Commented-Out Debug Prints

**Files:** Multiple  
**Examples:** `processRoad.lua` lines 81, 87, 129, 173, etc.

Many commented-out `print()` statements throughout. This is fine for development but clutters production code.

**Recommendation:** Use the proper `log()` function with severity levels:
```lua
log('D', 'processRoad', 'Checkpoint added at index ' .. index)
```

Then control verbosity via settings rather than commenting/uncommenting.

---

### 13. Inconsistent Function Export Style

**File:** `freeroamEvents.lua`  
**Lines:** 518-537

Mixed styles of exporting module functions.

**Problem:**
```lua
-- Some defined inline
local function onBeamNGTrigger(data)
-- ...

-- Then exported at bottom
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate
M.payoutRace = payoutRace
```

vs

```lua
-- Others defined directly
function M.onGetRawPoiListForLevel(levelIdentifier, elements)
```

**Recommendation:** Pick one style and stick with it. The inline + export pattern is more flexible (allows local calls without `M.` prefix), so prefer that consistently.

---

### 14. Missing `onExtensionUnloaded` Cleanup

**File:** `freeroamEvents.lua`  
**Lines:** 489-491

The `onExtensionUnloaded` only unloads child extensions but doesn't clean up module state.

**Problem:**
```lua
local function onExtensionUnloaded()
    unloadExtensions()
    -- State variables like `races`, `mActiveRace`, `timerActive` not reset
end
```

**Fix:**
```lua
local function onExtensionUnloaded()
    unloadExtensions()
    races = nil
    mActiveRace = nil
    timerActive = false
    staged = nil
    -- etc.
end
```

---

### 15. Typo in ReadMe

**File:** `ReadMe.md`  
**Line:** ~60

```markdown
"Reverse Logic":
  If the race is reversed, the checkpoints will be flipped. Use this if the checkpoints are in the wrong order.
```

The last sentence is confusing. It suggests using reverse to fix checkpoint order issues, but reverse is actually for running the course backwards.

**Suggested fix:**
```markdown
"Reverse Logic":
  If enabled, checkpoints are traversed in reverse order (end to start). Useful for creating bidirectional courses from a single road definition.
```

---

### 16. Redundant `deepcopy` in Race Data Loading

**File:** `utils.lua`  
**Line:** 431

```lua
return deepcopy(races)
```

This is called every time `loadRaceData()` is invoked, including on `onWorldReadyState`. Since `races` is already a local and `jsonReadFile` returns a fresh table, the deepcopy is redundant here.

---

### 17. Magic Numbers in Reward Calculations

**File:** `utils.lua`  
**Lines:** 149, 170, 201

Several magic numbers in reward formulas:
- `500` - divisor for exponential scaling
- `30` - reward cap multiplier
- `1.2` - drift/time factor exponent

**Recommendation:** Extract to named constants with documentation:
```lua
local REWARD_SCALING_DIVISOR = 500  -- Higher = gentler exponential curve
local REWARD_CAP_MULTIPLIER = 30    -- Maximum reward = base * this
local PERFORMANCE_EXPONENT = 1.2    -- Power curve for over-performance bonus
```

---

## 🟢 Positive Observations

### Clean Module Separation
The codebase follows a clear separation of concerns:
- `freeroamEvents.lua` - Main orchestration
- `checkpointManager.lua` - Checkpoint creation/tracking
- `leaderboardManager.lua` - Persistence layer
- `processRoad.lua` - Road geometry analysis
- `utils.lua` - Shared utilities
- `pits.lua` - Pit lane speed limiting
- `activeAssets.lua` - Visual asset management

This makes the code maintainable and testable.

### Proper BeamNG Extension Pattern
The mod correctly uses:
- `M.dependencies` (though currently empty, the pattern is there)
- Lifecycle hooks (`onExtensionLoaded`, `onWorldReadyState`, etc.)
- Proper trigger naming convention (`fre_*`)
- `setExtensionUnloadMode("manual")` for persistent loading

### Comprehensive Race Type Support
The system elegantly handles:
- Time trials
- Drift events (with scoring)
- Top speed challenges
- Hybrid damage/time events
- Hotlaps with multipliers
- Alternative routes

### Good UX Touches
- Split time comparisons with visual feedback
- Motivational messages at race start
- Progressive checkpoint markers (green for next, red for upcoming)
- Hotlap multiplier system for repeated play

### Robust Road Processing
The `processRoad.lua` contains sophisticated algorithms for:
- Automatic checkpoint placement at corners
- Turn apex detection
- Road merging for complex tracks
- Loop detection

---

## Summary of Required Actions

| Priority | Count | Category |
|----------|-------|----------|
| 🔴 Critical | 5 | Must fix before production |
| 🟠 Moderate | 6 | Should fix soon |
| 🟡 Minor | 6 | Nice to have |

### Quick Wins (High Impact, Low Effort)
1. Add career mode guards (copy-paste pattern)
2. Add nil checks for `be:getPlayerVehicle(0)`
3. Add `MPVehicleGE` existence check
4. Add server-side input validation

### Refactoring Tasks (Medium Effort)
1. Extract magic numbers to named constants
2. Standardize function export style
3. Replace `print()` with `log()`
4. Implement spatial indexing for road node lookup

---

## Appendix: Testing Recommendations

1. **Career Mode Edge Cases**
   - Test when career is not active
   - Test when switching between freeroam and career
   - Test when career modules are loading

2. **Multiplayer Edge Cases**
   - Test with MPVehicleGE not available
   - Test with high latency
   - Test vehicle hiding/showing with vehicle spawns/despawns

3. **Race State Machine**
   - Test interrupting races (leave trigger, vehicle destroyed)
   - Test stationary timeout
   - Test checkpoint skipping

4. **Performance Testing**
   - Profile `checkPlayerOnRoad` with 1000+ node roads
   - Measure frame time impact during active race

---

*End of Code Review*
