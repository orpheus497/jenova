## Script function and purpose: FlateDecode, the one thing this project needs
## zlib for — a PDF's content streams are compressed with it and cannot be read
## otherwise. `libz` is FreeBSD base, so this adds no install step.

{.passL: "-lz".}

# Action purpose: only the buffer-at-a-time entry points are bound. They take no
# struct, so no versioned C layout is mirrored into Nim and `zlib.h` keeps
# ownership of the prototypes; hand-declaring `z_stream` would not.
{.push importc, cdecl, header: "zlib.h".}
proc uncompress(dest: ptr uint8, destLen: ptr culong,
                source: ptr uint8, sourceLen: culong): cint
proc compress(dest: ptr uint8, destLen: ptr culong,
              source: ptr uint8, sourceLen: culong): cint
proc compressBound(sourceLen: culong): culong
{.pop.}

const
  ZOk = cint(0)
  ZBufError = cint(-5)   ## the output buffer was too small; nothing else failed

  ## A stream that inflates past this is refused rather than grown into: a zip
  ## bomb inside an attached PDF must fail as a refusal, not as the window
  ## exhausting memory.
  MaxInflatedBytes* = 64 * 1024 * 1024

## Function purpose: a PDF stream's `/Length` is its *compressed* size and
## nothing records the other one, so no caller can size the output buffer.
##
## Action purpose: `uncompress` must be told how much room it has, so the buffer
## starts at four times the input and quadruples on `Z_BUF_ERROR` up to the cap.
## Retrying is cheap and bounded; guessing once would truncate the document.
##
## **Every size is clamped to the cap rather than compared against it.** The
## opening guess is four times the input, so a stream over 16 MiB compressed
## produced a first `cap` past `MaxInflatedBytes` and the loop was never entered
## — `uncompress` was not called even once, and a large but perfectly legal PDF
## stream was refused as though it were a bomb. Quadrupling had the same edge at
## the other end: from 20 MiB the next step is 80 MiB, so the attempt at the cap
## itself never happened. Clamping both makes the last attempt exactly
## `MaxInflatedBytes`, which is what the cap is supposed to mean, and the
## `cap >= MaxInflatedBytes` exit is what stops that becoming a loop.
proc inflate*(src: string): tuple[ok: bool, data: string] =
  if src.len == 0: return (false, "")
  var cap = min(max(src.len * 4, 4096), MaxInflatedBytes)
  while true:
    var buf = newString(cap)
    var outLen = culong(cap)
    let rc = uncompress(cast[ptr uint8](buf[0].addr), outLen.addr,
                        cast[ptr uint8](src[0].unsafeAddr), culong(src.len))
    if rc == ZOk:
      buf.setLen(int(outLen))
      return (true, buf)
    if rc != ZBufError:
      return (false, "")
    if cap >= MaxInflatedBytes:
      return (false, "")
    cap = min(cap * 4, MaxInflatedBytes)

## Function purpose: nothing in Jenova compresses anything — this exists so the
## self-test can prove the codec by round trip, rather than by asserting against
## literal compressed bytes no reader can check.
proc deflate*(src: string): tuple[ok: bool, data: string] =
  if src.len == 0: return (false, "")
  var cap = int(compressBound(culong(src.len)))
  var buf = newString(cap)
  var outLen = culong(cap)
  let rc = compress(cast[ptr uint8](buf[0].addr), outLen.addr,
                    cast[ptr uint8](src[0].unsafeAddr), culong(src.len))
  if rc != ZOk: return (false, "")
  buf.setLen(int(outLen))
  (true, buf)
