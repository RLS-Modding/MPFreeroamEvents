# MPFreeroamEvents — Design Proposals

## 1. Route Graph System (Replaces Alt Routes)

### Problem
- Current system only supports 1 main route + 1 alt route
- No support for figure-8s, track crossings, or complex layouts
- Checkpoint validation assumes linear sequential order
- Crossing zones trigger wrong checkpoints based on physical overlap

### Proposed Architecture

#### Core Concepts

**Segments** — Named road sections that can be composed into layouts
```json
{
  "segments": {
    "start_straight": { "road": "race1_road_start", "checkpointIndexes": [5, 12] },
    "loop_north": { "road": "race1_road_north", "checkpointIndexes": [3, 8, 15] },
    "loop_south": { "road": "race1_road_south", "checkpointIndexes": [4, 10] },
    "crossing": { "road": "race1_crossing" },
    "shortcut": { "road": "race1_shortcut" }
  }
}
```

**Layouts** — Ordered compositions of segments with their own times/rewards
```json
{
  "layouts": {
    "full_circuit": {
      "label": "Full Circuit",
      "segments": ["start_straight", "loop_north", "crossing", "loop_south"],
      "bestTime": 120,
      "reward": 2000,
      "hotlap": 110
    },
    "north_only": {
      "label": "North Loop Only",
      "segments": ["start_straight", "loop_north", "shortcut"],
      "bestTime": 55,
      "reward": 800
    },
    "reverse": {
      "label": "Reverse Circuit",
      "segments": ["start_straight", "loop_south", "crossing", "loop_north"],
      "bestTime": 125,
      "reward": 2000
    }
  }
}
```

#### Generic Overlap Handling (Direction-Aware Checkpoints)

All track overlaps (figure-8s, crossings, shared road segments, loops that touch) are handled by a single generic mechanism — **no special-casing per track shape**.

When a player enters a checkpoint trigger zone:
1. Check vehicle's **travel direction** (velocity vector)
2. Compare against the **expected approach direction** for the next checkpoint in sequence
3. `dot(vehicleVelocity, expectedDirection) > 0` → valid hit (traveling toward checkpoint)
4. `dot(vehicleVelocity, expectedDirection) <= 0` → ignore (wrong pass, different direction)

The expected direction is simply: `normalize(checkpointPosition - previousCheckpointPosition)`

This naturally handles:
- **Figure-8s**: First pass heading north through crossing → valid. Second pass heading east → different checkpoint expected.
- **Overlapping loops**: Player on lap 2 passes through lap 1's checkpoint zone → direction check filters it.
- **Shared road segments**: Multiple routes using the same physical road → direction determines which route's checkpoint to trigger.
- **Any geometry**: No track shape is special. Direction is universal.

#### Checkpoint Validation (Updated Algorithm)

```
1. Player enters a checkpoint trigger zone
2. Get the next expected checkpoint for the active layout
3. If this trigger matches the expected checkpoint:
   a. Calculate expected approach direction from previous checkpoint
   b. Check dot(playerVelocity, expectedDirection) > DIRECTION_THRESHOLD
   c. If direction matches → valid hit, advance progress
   d. If direction wrong → ignore (player on different pass/route)
4. If this trigger does NOT match expected:
   a. Check if it's a future checkpoint (player skipped some) → invalidate lap
   b. Check if it's a past checkpoint (player looping back) → ignore
```

#### Layout Selection
- At staging, player sees all available layouts for the event
- Could auto-detect based on which start trigger they enter
- Or present a selection UI before race starts

#### Backward Compatibility
- Events without `layouts` key work exactly as before (single route)
- Events with `altRoute` can be auto-migrated: main route → layout "standard", alt → layout "alternative"
- `segments` is optional — you can still use `checkpointRoad` directly for simple events
- Direction-aware validation can be added to the existing system too (benefits all events)

### Implementation Phases

1. **Direction-aware checkpoints** — Add direction check to existing `handleCheckpoint()` (benefits all events immediately)
2. **Data model** — Add segments/layouts to race_data.json schema
3. **Checkpoint validation** — Integrate layouts with direction-aware matching
4. **Editor UI** — Segment editor, layout composer, visual preview
5. **Migration** — Auto-convert altRoute configs
6. **Staging UI** — Layout selection at race start

---

## 2. Track Distance System

### Problem
- No way to know track length during editing or racing
- Can't show "distance remaining" to player
- Hard to balance checkpoint spacing without distance info

### Static Distances (Calculated on Load)

Pre-computed when checkpoints are initialized from road nodes:

```lua
trackDistances = {
  totalLength = 3450.5,           -- meters, full track
  checkpointDistances = {         -- cumulative from start
    [1] = 245.3,
    [2] = 512.8,
    [3] = 890.1,
    -- ...
  },
  segmentLengths = {              -- between consecutive checkpoints
    [1] = 245.3,                  -- start → cp1
    [2] = 267.5,                  -- cp1 → cp2
    [3] = 377.3,                  -- cp2 → cp3
    -- ...
  },
  perLayoutLength = {             -- when using route graph system
    ["full_circuit"] = 3450.5,
    ["north_only"] = 1580.2
  }
}
```

**Calculation**: Sum `calculateDistance(roadNodes[i], roadNodes[i+1])` for all consecutive node pairs along the route.

### Live Distances (Updated Per Frame)

During an active race:

```lua
liveDistance = {
  completed = 1250.0,             -- meters traveled along route
  remaining = 2200.5,             -- meters to finish
  progress = 0.362,               -- 0-1 completion ratio
  toNextCheckpoint = 180.3,       -- meters to next checkpoint
  fromLastCheckpoint = 87.2       -- meters since last checkpoint
}
```

**Calculation**: Find nearest road node to player position → look up that node's cumulative distance.

### Editor Display

In Checkpoint Settings section:
```
Track Length: 3,450m (3.45 km)
Checkpoints: 8

Checkpoint 1: 245m from start
Checkpoint 2: 513m from start (268m gap)
Checkpoint 3: 890m from start (377m gap)  ⚠️ Large gap
...

Average gap: 431m
Shortest gap: 180m (CP 5→6)
Longest gap: 620m (CP 7→8)  ⚠️
```

### Race HUD Display

Options for displaying to player:
- Progress bar at top of screen
- "1.2 km remaining" text
- Split distances at checkpoint messages: "Checkpoint 3/8 — 890m / 3.45km"
- Mini-map dot showing position along track

### Implementation

1. **processRoad.lua** — Add `calculateTrackDistances(roadNodes, checkpoints)` function
2. **freeroamEvents.lua** — Call on race start, update live distances in `onUpdate`
3. **Editor** — Show static distances in Checkpoint Settings
4. **HUD** — Optional display during races (can be toggled)

---

## 3. Implementation Priority

| Feature | Complexity | Value | Priority |
|---------|-----------|-------|----------|
| Track distances (static/editor) | Low | Medium | Phase 1 |
| Track distances (live/HUD) | Medium | High | Phase 1 |
| Route segments data model | Medium | High | Phase 2 |
| Direction-aware checkpoints | High | High | Phase 2 |
| Multiple layouts | Medium | High | Phase 2 |
| Layout editor UI | High | Medium | Phase 3 |
| Figure-8 support | High | Medium | Phase 3 |
| Auto-migration from altRoute | Low | Medium | Phase 3 |
