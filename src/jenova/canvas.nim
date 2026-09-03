## Script function and purpose: the animated particle field drawn behind the
## window, on a GTK4 drawing area and cairo.
##
## The constants below are the look rather than tuning, so they are named: the
## particle count, the velocity range, the link distance and the alpha that fades
## to zero at it. Changing one is a design decision.
##
## The simulation is advanced by a timer and never by the draw callback.
## Returning true from that callback makes owlkettle re-diff the whole
## application at the display's refresh rate; stepping from a timer bounds it and
## keeps rendering free of side effects — the draw reads state, the step mutates
## it.
##
## Screen blending is not reproduced: the cairo bindings in use expose no
## operator call, and against a near-black ground the difference from plain alpha
## compositing is slight.

import std/[math, random]
import owlkettle/cairo
import owlkettle/bindings/gtk
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

## Function purpose: re-seeded on resize as well as at first draw, because
## particles placed for a small window all sit in one corner of a maximised one.
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

## Function purpose: walls reflect rather than wrap, which is what keeps the
## field visually even — a wrapping one drifts into stripes.
proc step*() =
  for p in particles.mitems:
    p.x += p.vx
    p.y += p.vy
    if p.x < 0 or p.x > fieldW: p.vx = -p.vx
    if p.y < 0 or p.y > fieldH: p.vy = -p.vy

## Function purpose: answers false so this callback never asks for a redraw —
## the timer owns the frame rate, and asking here would re-diff the whole
## application at the display's refresh rate.
proc draw*(ctx: CairoContext, size: (int, int)): bool =
  let
    w = float(size[0])
    h = float(size[1])
  if w <= 0 or h <= 0: return false
  if particles.len == 0 or w != fieldW or h != fieldH:
    reseed(w, h)

  ctx.lineWidth = 1.0
  # Read from the palette in force rather than from fixed constants: particles
  # chosen to glow on near-black are invisible on white.
  let (pr, pg, pb) = theme.active().canvasParticle
  let (lr, lg, lb) = theme.active().canvasLink

  for i in 0 ..< particles.len:
    let p = particles[i]

    ctx.source = (pr, pg, pb, ParticleAlpha * Opacity)
    ctx.circle(p.x, p.y, ParticleRadius)
    ctx.fill()

    # Action purpose: each particle links only to those after it. Drawing both
    # directions paints every link twice, and under alpha compositing a doubled
    # line is visibly brighter — which reads as a tuning problem rather than a
    # loop problem.
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

# ---------------------------------------------------------------------------
# The widget, and why this module owns it
# ---------------------------------------------------------------------------

## Action purpose: the canvas is a bare drawing area repainted directly, not an
## owlkettle widget re-diffed each frame. A full tree diff at the frame rate
## re-binds every signal handler in the window thirty times a second, and
## disconnecting a handler from a widget the cycle collector has already taken
## is a crash rather than a slowdown.
##
## Animating needs only a queued draw on the area itself, so the widget-tree diff
## is left to the timers that fire on real state changes.

var area: GtkWidget

## Function purpose: the callback GTK invokes to paint. The context arrives
## untyped and is the cairo handle the wrapper type holds.
proc drawFunc(widget: GtkWidget, ctx: pointer, width, height: cint,
              data: pointer) {.cdecl.} =
  discard draw(CairoContext(ctx), (int(width), int(height)))

## Function purpose: called once from the renderable in the window module, since
## owlkettle's macro emits an unexported type — so the widget is declared there
## and the drawing stays here.
proc newArea*(): GtkWidget =
  area = gtk_drawing_area_new()
  gtk_drawing_area_set_draw_func(area, drawFunc, nil, nil)
  area

## Function purpose: what the frame clock calls instead of a full redraw. A
## no-op before the window is built, so the timer needs no guard of its own.
proc queueFrame*() =
  if not pointer(area).isNil:
    gtk_widget_queue_draw(area)
