# Kaddo flame mascot

Created with the built-in OpenAI ImageGen tool, with actual alpha transparency.
Final project assets are in `Sources/KaddoCanvas/Resources/FlamePet/`.
Each 2172 × 724 PNG contains six horizontal animation cells. The runtime uses a
shared alpha crop across all cells/states to preserve alignment and the jump.
The original cat artwork and its license remain bundled for attribution/history.

## Base generation — idle.png

Use case: stylized-concept. Create an original pixel-art desktop pet animation
sprite strip, transparent background. One horizontal strip of exactly SIX equally
sized square cells in a single row, no gutters; output wide 6:1 proportions.
Each cell contains the SAME adorable original small flame-headed humanoid mascot
with a cream rounded face, two black square eyes, compact cream body, orange-red
outline/hood and a bright yellow/orange flame on top. Simple dark burgundy pixel
outlines, chunky clean 16-bit pixel art, no soft edges, no text, no numbers, no
borders, no shadows outside character. Front-facing slight three-quarter pose.
Full character centered in every cell with identical feet baseline, scale,
margins and camera. All six cells must have wide empty transparent margins so
frames never touch or cross cell edges. Animation state IDLE: six distinct
sequential frames with subtle breathing and gently flickering flame, feet fixed.
Keep identity and proportions exactly consistent. Actual alpha transparency,
no checkerboard image.

The generator returned 3:1 strips with tall cells; runtime alpha cropping handles
this without stretching the character or modifying the generated PNGs.

## State edits

Each edit used the generated idle strip as its reference. Shared prompt:

> Edit this original character animation strip into the STATE state: ACTION.
> Keep exactly SIX separate equally spaced frames in ONE horizontal row with the
> same six column centers, same character identity, palette, clean chunky pixel
> style, feet baseline and scale as the reference. Each frame is a distinct
> sequential animation pose. Cream rounded face, orange-red outline, yellow flame,
> compact cream body. Full character with transparent margins in every cell; no
> clipping, no text, labels, borders or scenery. Real alpha transparency. Preserve
> the reference strip canvas proportions and fixed cell grid.

| File / STATE | ACTION |
| --- | --- |
| thinking.png / THINKING | hand at chin, eyes looking upward, subtle pondering head tilt, gently flickering flame |
| happy.png / HAPPY | delighted smiling eyes, friendly gentle waving motion and small buoyant bounce |
| sleeping.png / SLEEPING | standing drowsily with closed eyes, hands resting, slow sleepy breathing, smaller gently flickering flame |
| celebrating.png / CELEBRATING | six sequential frames of joyful arms-up cheering with a small hop; frame six is a delighted stable finishing pose |
