Animated pixel art by Frakassets - https://frakassets.itch.io/

10 cute animals, every one animated from 4 sides. Every frame is a square
of the sheet's size (16 x 16, 32 x 32, 48 x 48 or 64 x 64 pixels),
transparent PNG. Play them at 12 frames per second.

What is in it (each animal has its own folder):
  Furry     cat-orange, puppy-shiba, fox-red
  Small     bunny-white, hamster-golden, hedgehog-brown, piglet-pink
  Critters  duckling-yellow, frog-green, turtle-green

The Pets Megapack has 48: these in 3 more colours or breeds each, plus a
raccoon and an owlet: https://frakassets.itch.io/

Animations, one row per animation and side (South = facing you, then
East, North, West):
  Idle     breathing, looking about, ears and tail moving, looping
  Walk     walking in place, looping (the bunny and frog hop)
  Happy    a hop, a wag, a wiggle: petted, fed or greeted, looping
  Sleep    curled up or lying down, eyes shut, breathing, looping
  <animal>_<size>_<angle>.json gives every frame's place, animation, side
  and pivot (Aseprite's JSON hash, with a frame tag per animation and side,
  e.g. Happy_South), for every variant of that size and angle.

File names: <animal>_<size>_<angle>_<outline>_<layer>.png
  size     16px, 32px, 48px or 64px
  angle    scroller (seen from the side, a little from above) or
           top-down (seen from above at 45 degrees)
  outline  outline (dark outer border) or no-outline
  layer    lit     the animal, lit and shaded, without its shine
           shine   the shine alone, to draw over lit: highlights and
                   glints (only where there is one)
           glow    the glowing parts alone, to draw over lit with additive
                   blending or bloom: (only for animals that glow)
           unlit   flat colours, to light yourself
  Draw lit, then shine over it, for the finished look.
  And for each size and angle:
  <animal>_<size>_<angle>_normal.png  the normal map, for 2D lights
                                       (x right, y up, z towards the camera)
  <animal>_<size>_<angle>_lines.png   the outline alone, to recolour or fade
  <animal>_<size>_<angle>_shadow.png  a contact shadow (black ellipse) to
                                       draw under the animal, at any opacity

How to use
----------
1. Unzip. Each animal has its own folder.
2. Pick a sheet (see the file names above).
3. Import:
   Godot 4    Default texture filter Nearest. AnimatedSprite2D > SpriteFrames >
              Add frames from sprite sheet: Horizontal = the columns, Vertical =
              the rows, then pick the cells of one row per animation and side;
              12 FPS.
   Unity      Texture Type Sprite (2D and UI), Sprite Mode Multiple, Filter
              Point, Compression None, Pixels Per Unit = the sheet's size.
              Sprite Editor > Slice > Grid By Cell Size (16, 32, 48 or 64).
   GameMaker  Create Sprite > Import Strip Image, one row at a time, size =
              the sheet's size; 12 frames per second.
   Aseprite   Open the PNG with its .json beside it, or File > Import >
              Import Sprite Sheet, By Rows, width and height = the sheet's size.
   Normal maps line up frame for frame with the sheets (Godot CanvasTexture,
   Unity Secondary Textures > _NormalMap).

Made with Pixor, the tool that turns 3D models into animated pixel-art
sprite sheets: every side, frame by frame, the same pixels every time.
Pay once, every pixel drawn by shaders, offline.
https://pixor.art/

Licence: CC BY 4.0 (LICENSE.txt): credit "Frakassets".

If you use these, a rating or a comment on the itch page helps a lot. Thank you!
