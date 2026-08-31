## Script function and purpose: the animated particle field the Web UI draws
## behind everything (`jca_web/src/lib/components/app/NeuralCanvas.svelte`),
## ported to a GTK4 `DrawingArea` and cairo (G-2, ruling D-AP).
##
## ## Faithful to the original, including its numbers
##
## 80 particles, velocity `(random - 0.5) * 0.5`, walls reflect, radius 1.5, and
## a link drawn between any two closer than 150 px whose alpha fades linearly to
## zero at that distance. Those constants are the look; changing them is a design
## decision, not a tuning detail, so they are named rather than inlined.
##
## ## Two deliberate differences from the browser
##
## * **`mix-blend-mode: screen` is not reproduced.** owlkettle's cairo bindings
##   expose no `cairo_set_operator`, and the effect of `screen` against a
##   near-black ground is very close to plain alpha compositing anyway. The
##   canvas is drawn at `Opacity` over `#131313` instead. If the difference ever
##   matters, `cairo_set_operator` is a one-line `importc` — it is absent, not
##   unavailable.
## * **The simulation is advanced by a timer, not by the draw callback.**
##   owlkettle redraws the whole application when a `DrawingArea` draw callback
##   returns `true`, which would run the widget diff at the display's refresh
##   rate for as long as the window is open. Stepping from a timer bounds it to
##   `FrameMs` and keeps rendering free of side effects — `draw` reads state and
##   paints, `step` mutates it.

import std/[math, random]
import owlkettle/cairo
import ./theme

const
  ParticleCount* = 80
  LinkDistance* = 150.0
  ParticleRadius* = 1.5
  MaxSpeed = 0.5
  Opacity* = 0.30          ## `NeuralCanvas.svelte:75` — `opacity-30`
  ParticleAlpha = 0.4      ## `:44`
  FrameMs* = 33            ## ~30 fps. See the note above on why this is a timer.

type
  Particle = object
    x, y, vx, vy: float

var
  particles: seq[Particle]
  fieldW, fieldH: float
  rng = initRand(0x5eed)

## Function purpose: (re)seed the field for a given widget size. Called on the
## first draw and whenever the widget is resized, because particles seeded for an
## 900x680 window would all sit in one corner of a maximised one.
proc reseed(w, h: float) =
  fieldW = w
  fieldH = h
  particles.setLen(0)
  for _ in 0 ..< ParticleCount:
    particles.add Particle(
      x: rng.rand(w),
      y: rng.rand(h),
      vx: (rng.rand(1.0) - 0.5) * MaxSpeed,
      vy: (rng.rand(1.0) - 0.5) * MaxSpeed)

## Function purpose: advance one frame. Walls reflect rather than wrap, which is
## what keeps the field visually even — a wrapping field drifts into stripes.
proc step*() =
  for p in particles.mitems:
    p.x += p.vx
    p.y += p.vy
    if p.x < 0 or p.x > fieldW: p.vx = -p.vx
    if p.y < 0 or p.y > fieldH: p.vy = -p.vy

## Function purpose: paint the field. Returns false: this callback never asks
## owlkettle to redraw, because the timer in `gui.nim` owns the frame rate.
proc draw*(ctx: CairoContext, size: (int, int)): bool =
  let
    w = float(size[0])
    h = float(size[1])
  if w <= 0 or h <= 0: return false
  if particles.len == 0 or w != fieldW or h != fieldH:
    reseed(w, h)

  ctx.lineWidth = 1.0
  let (pr, pg, pb) = theme.CanvasParticle
  let (lr, lg, lb) = theme.CanvasLink

  for i in 0 ..< particles.len:
    let p = particles[i]

    ctx.source = (pr, pg, pb, ParticleAlpha * Opacity)
    ctx.circle(p.x, p.y, ParticleRadius)
    ctx.fill()

    # Action purpose: links are drawn from each particle only to those after it
    # in the sequence. Drawing both directions would paint every link twice, and
    # with alpha compositing a doubled line is visibly brighter than a single one
    # — the bug would look like a tuning problem rather than a loop problem.
    for j in i + 1 ..< particles.len:
      let
        q = particles[j]
        dx = p.x - q.x
        dy = p.y - q.y
        dist = sqrt(dx * dx + dy * dy)
      if dist < LinkDistance:
        ctx.source = (lr, lg, lb, (1.0 - dist / LinkDistance) * Opacity)
        ctx.moveTo(p.x, p.y)
        ctx.lineTo(q.x, q.y)
        ctx.stroke()
  false
