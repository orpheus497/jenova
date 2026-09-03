## Script function and purpose: FlateDecode, which is the one thing this project
## needs zlib for — a PDF's content streams are compressed with it and cannot be
## read without it (G-30). Approved as a dependency by the USER on 2026-09-02;
## `/usr/lib/libz.so.1` is FreeBSD base, and the zlib licence is permissive.
##
## Bound as `uncompress` and nothing else. That entry point takes no struct, so
## no versioned C layout is mirrored into Nim — which is **D-V**: hand-declaring
## `z_stream` would rebuild the `ffi_defs.lua` defect class the migration exists
## to have deleted. The header supplies the prototype and the C compiler owns it.

{.passL: "-lz".}

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

  ## A decompressed stream larger than this is refused rather than grown into.
  ## Same reasoning as `pipeline.MaxAttachmentBytes` (D-BQ): a zip bomb inside an
  ## attached PDF must fail as a refusal, not as the window exhausting memory.
  MaxInflatedBytes* = 64 * 1024 * 1024

## Function purpose: inflate a zlib stream whose decompressed length is unknown,
## which is every PDF stream — the dictionary's `/Length` is the *compressed*
## length and nothing records the other one.
##
## Action purpose: `uncompress` has to be told how much room it has, so the
## buffer starts at four times the input and quadruples on `Z_BUF_ERROR` until
## the cap. Retrying is cheap and bounded; guessing once and truncating would
## hand the model half a document, which is the failure D-BQ refuses.
proc inflate*(src: string): tuple[ok: bool, data: string] =
  if src.len == 0: return (false, "")
  var cap = max(src.len * 4, 4096)
  while cap <= MaxInflatedBytes:
    var buf = newString(cap)
    var outLen = culong(cap)
    let rc = uncompress(cast[ptr uint8](buf[0].addr), outLen.addr,
                        cast[ptr uint8](src[0].unsafeAddr), culong(src.len))
    if rc == ZOk:
      buf.setLen(int(outLen))
      return (true, buf)
    if rc != ZBufError:
      return (false, "")
    cap = cap * 4
  (false, "")

## Function purpose: the other half of the round trip, and it exists for the
## assertions rather than for the product — nothing in Jenova compresses
## anything. `rag.vectorRoundTrip` is the precedent: a codec is proven by
## putting a known value through both directions, and embedding pre-compressed
## bytes as a literal would assert against something nobody can read.
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
