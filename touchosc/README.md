# Phase-Space Attractor — TouchOSC Layout

## Overview

This TouchOSC layout controls the Phase-Space Attractor patch. The audio input
creates a wandering point in 2D phase space (amplitude × pitch). Your fingers on
the Multi XY pad are voices — each one sounds when the audio's state passes near it.

## Layout Design

### Page 1: Performance

```
┌──────────────────────────────────────────────────┐
│                                                  │
│           MULTI XY PAD (5 touch points)          │
│                                                  │
│    ·  Each finger = one synth voice              │
│    ·  Tap = gate on/off (envelope trigger)       │
│    ·  X = filter/brightness + stereo pan          │
│         (left=dark, right=bright)                │
│    ·  Y = pitch (bottom=low, top=high)           │
│    ·  Audio proximity → amplitude modulation     │
│                                                  │
│         (takes up ~75% of screen height)         │
│                                                  │
├──────────────────────────────────────────────────┤
│  [Prox]  [Atk]  [Rel]  [Reverb]  [Room]  [Vol]  │
│   |||     |||    |||     |||       |||     |||    │
│   |||     |||    |||     |||       |||     |||    │
│   |||     |||    |||     |||       |||     |||    │
│  Radius  Attack Release  Mix     Room   Master   │
└──────────────────────────────────────────────────┘
```

### Controls Detail

| Control        | Type    | OSC Address             | Range     | Description                                           |
|----------------|---------|-------------------------|-----------|-------------------------------------------------------|
| Multi XY Pad   | XY Pad  | `/attractor/touch`      | 0.0–1.0   | 5-point touch: sends [index, x, y, gate] for all events |
| Prox Radius    | Fader   | `/attractor/proxRadius` | 0.0–1.0   | How close audio state must be to activate a voice     |
| Attack         | Fader   | `/attractor/attack`     | 0.0–1.0   | Envelope attack time (maps to 1ms–2s)                |
| Release        | Fader   | `/attractor/release`    | 0.0–1.0   | Envelope release time (maps to 10ms–5s)              |
| Reverb Mix     | Fader   | `/attractor/reverb`     | 0.0–1.0   | Dry/wet reverb mix                                   |
| Reverb Room    | Fader   | `/attractor/room`       | 0.0–1.0   | Reverb room size                                     |
| Master Vol     | Fader   | CC 11 (MIDI)            | 0–127     | Master output volume (via MIDI Mix or mapped fader)  |

### TouchOSC Editor Setup Instructions

1. **Open TouchOSC Editor** (Mk2 recommended)
2. **Create new layout**, set orientation to Landscape
3. **Add Multi XY control**:
   - Position: x=0, y=0, width=full, height=75%
   - Points: 5
   - Color: pick a vibrant color (e.g., cyan)
   - Configure OSC:
     - For each touch point i (0–4), set up a Lua script or use the built-in
       Multi XY messages. Map touch-down to send `/attractor/touch i x y 1`,
       movement to `/attractor/touch i x y 1`, and touch-up to `/attractor/touch i x y 0`
4. **Add 6 vertical faders** in the bottom 25%:
   - Each fader sends its respective OSC address listed above
   - Range: 0.0 to 1.0
   - Labels below each fader: Radius, Attack, Release, Reverb, Room, Master
5. **Network settings**: Point to the Raspberry Pi's IP address, port 57120 (sclang default)

### TouchOSC Lua Script (for Multi XY touch routing)

Place this in the Multi XY control's script to convert native touch events into
the expected OSC messages:

```lua
function onValueChanged(key)
  -- key format: "touch/x/1", "touch/y/1", "touch/z/1" etc.
  local parts = {}
  for part in key:gmatch("[^/]+") do
    table.insert(parts, part)
  end

  if parts[1] == "touch" then
    local axis = parts[2]     -- "x", "y", or "z"
    local idx = tonumber(parts[3]) - 1  -- 0-indexed

    if axis == "z" then
      -- Touch down/up: send gate message
      local gate = self.values[key] > 0 and 1 or 0
      local x = self.values["touch/x/" .. (idx+1)] or 0.5
      local y = self.values["touch/y/" .. (idx+1)] or 0.5
      sendOSC("/attractor/touch", idx, x, y, gate)
    elseif axis == "x" or axis == "y" then
      -- Movement: re-send touch with gate=1 so SC updates position
      local z = self.values["touch/z/" .. (idx+1)] or 0
      if z > 0 then
        local x = self.values["touch/x/" .. (idx+1)] or 0.5
        local y = self.values["touch/y/" .. (idx+1)] or 0.5
        sendOSC("/attractor/touch", idx, x, y, 1)
      end
    end
  end
end
```
