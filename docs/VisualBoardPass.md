# Visual Board Pass 1

Date: 2026-04-22

## Scope
Rendering-only pass focused on board readability and combatant visibility.
No gameplay rules were changed.

## What changed
- `BattleScene` now delegates player/enemy visual creation to `SpriteManager.createCharacter(...)`, which uses frame assets when available and deterministic procedural fallbacks otherwise.
- Added a deterministic map `boardBackplate` layer behind the tile map for stronger scene contrast.
- Added a subtle deterministic scanline layer over the backplate for depth/atmosphere.

## Sprite behavior
- Player and enemy nodes are still placed from existing tile coordinates (`positionX`, `positionY`) and tracked in `characterNodes`.
- Movement/selection/HP hooks continue to use the same scene pathways.

## Tile/board behavior
- Existing tile rendering in `TileMap` remains active (sprite-backed tile styles with procedural fallback).
- Backplate improves tile/sprite contrast but does not alter tile semantics.

## Verify in Xcode
1. Open `ShadowrunGame.xcodeproj`.
2. Launch combat mission.
3. Confirm:
   - players are visible at spawn,
   - enemies are visible at spawn,
   - tile textures are visible,
   - board has a dark framed backplate with subtle scanline depth.

If running outside macOS/Xcode, runtime visual validation is NOT_COMPUTABLE.

## Visual Pass 2 (Readability + Game Feel)

- Added an explicit active-turn ring (`activeTurnRing`) on the active player unit in `BattleScene`.
- Tuned movement overlay styling to cyan/blue with reduced clutter.
- Kept enemy target overlays but raised them to a distinct overlay layer.
- Added a subtle pulsing enemy threat ring on enemy sprites for at-a-glance danger readability.
- Added quick selection pop feedback (`1.05x -> 1.0x`) when selecting a unit.
