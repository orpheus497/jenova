## Script function and purpose: which of the window's viewers can show a stored
## file asset, and what to call its type when none of them can. `gui.nim` links
## into no test binary, so the decision lives here where `asset-selftest`
## asserts it, and the window only draws the answer.

import std/[base64, strutils]
import ./pipeline

type
  AssetViewer* = enum
    ## No content at all is its own answer and not a kind of "unsupported". A
    ## file asset filed from a chat image stores its bytes with the message and
    ## leaves this column empty on purpose, so the two states have to be
    ## distinguishable or the window reports a deliberate design as a failure.
    avEmpty
    avImage
    avText
    avBinary

  AssetView* = object
    viewer*: AssetViewer
    ## The media type as honestly as it can be established: what the stored
    ## `data:` URI declared, else the row's own `type` column, else what the
    ## file name's extension implies. Empty when nothing declares one, which is
    ## a different claim from declaring `application/octet-stream`.
    mime*: string
    ## The bytes to show or write out, already un-base64ed. Never the `data:`
    ## envelope: every caller wants the file, not its transport encoding.
    data*: string

const
  ## Extensions that name a text format a reader would expect to open as text
  ## even though a byte scan alone cannot distinguish them from anything else
  ## printable. The scan is still what decides — this only supplies a media type
  ## to show, so a name that lies costs a label and never a wrong viewer.
  TextMimes = {
    ".md": "text/markdown", ".markdown": "text/markdown",
    ".txt": "text/plain", ".log": "text/plain",
    ".json": "application/json", ".csv": "text/csv",
    ".html": "text/html", ".htm": "text/html", ".xml": "text/xml",
    ".css": "text/css", ".js": "text/javascript",
    ".nim": "text/x-nim", ".c": "text/x-c", ".h": "text/x-c",
    ".py": "text/x-python", ".sh": "text/x-shellscript",
    ".yaml": "text/yaml", ".yml": "text/yaml", ".toml": "text/toml",
  }

## Function purpose: splits a stored `data:` URI into what it claims to be and
## what it carries, so the media type is read from the payload rather than
## guessed from the name beside it.
proc splitDataUrl*(content: string): tuple[isData: bool, mime, encoded: string] =
  if not content.startsWith("data:"): return (false, "", "")
  let comma = content.find(',')
  if comma < 0: return (false, "", "")
  # Everything between `data:` and the comma is the media type plus its
  # parameters; `;base64` is one of those and is not part of the type.
  var head = content[5 ..< comma]
  let semi = head.find(';')
  if semi >= 0: head = head[0 ..< semi]
  (true, head, content[comma + 1 .. ^1])

## Function purpose: the base64 alphabet is filtered before decoding for the
## reason `fssync.syncFileAsset` filters it — a stored URI can carry newlines
## from whatever wrote it, and Nim's decoder does not skip them.
proc decodeBase64*(encoded: string): tuple[ok: bool, data: string] =
  var clean = newStringOfCap(encoded.len)
  for ch in encoded:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}: clean.add ch
  # A payload that had characters and has none after filtering held nothing the
  # alphabet allows, which is a refusal and not an empty file. Without this the
  # two are the same answer, and a corrupt URI would report as a stored asset
  # with no content.
  if clean.len == 0: return (encoded.len == 0, "")
  if clean.len mod 4 != 0: return (false, "")
  try:
    (true, base64.decode(clean))
  except CatchableError:
    (false, "")

## Function purpose: the media type a name implies, which is the last resort
## and the weakest of the three sources — a renamed file is still whatever it
## was.
proc mimeFromName*(name: string): string =
  let dot = name.rfind('.')
  if dot < 0: return ""
  let ext = name[dot .. ^1].toLowerAscii
  for (suffix, mime) in TextMimes:
    if ext == suffix: return mime
  if ext in pipeline.ImageExts: return pipeline.mimeForImage(ext)
  ""

## Function purpose: the one place that turns a stored row into a viewer
## choice, so the sidebar row, the files list and the viewer panel cannot
## disagree about what a given asset is.
##
## Action purpose: the byte scan outranks every declaration. `type` is written
## by whichever client uploaded the row — the window writes the literal
## `image/*` for an image and `text/plain` for everything else — so trusting it
## would send a text file to an image loader on the strength of a name.
proc classify*(name, declaredType, content: string): AssetView =
  let (isData, dataMime, encoded) = splitDataUrl(content)
  var bytes = content
  if isData:
    let (ok, decoded) = decodeBase64(encoded)
    # A `data:` URI that will not decode carries no recoverable file. Reporting
    # it as text would show the user its base64 instead of saying so.
    if not ok: return AssetView(viewer: avBinary, mime: dataMime, data: "")
    bytes = decoded

  # `image/*` is not a media type; it is the wildcard the window stores when it
  # files a chat image, and passing it on as though it were one would put a
  # value no viewer can act on in front of the user.
  let declared = (if declaredType == "image/*": "" else: declaredType)
  result.mime =
    if dataMime.len > 0: dataMime
    elif declared.len > 0: declared
    else: mimeFromName(name)
  result.data = bytes

  if bytes.len == 0:
    result.viewer = avEmpty
  elif result.mime.startsWith("image/") or
       (result.mime.len == 0 and mimeFromName(name).startsWith("image/")):
    result.viewer = avImage
  elif pipeline.looksTextual(bytes):
    # The same test the attach path uses, not a second one: a file the composer
    # would take as text must read as text here, or the two surfaces disagree
    # about the same bytes.
    result.viewer = avText
  else:
    result.viewer = avBinary

## Function purpose: what to call the type in a sentence the user reads, so the
## no-viewer state names something rather than saying "unknown" over a file
## whose extension is right there.
proc typeLabel*(view: AssetView, name: string): string =
  if view.mime.len > 0: return view.mime
  let dot = name.rfind('.')
  if dot > 0 and dot < name.len - 1: return name[dot + 1 .. ^1].toLowerAscii & " file"
  "unrecognised"

## Function purpose: a size the user can compare, in the units the rest of the
## window already uses. Rounded up, for the reason the models list rounds up: a
## file under a kilobyte reporting as 0 reads as an empty file.
proc sizeLabel*(bytes: int): string =
  if bytes < 1024: return $bytes & " B"
  if bytes < 1024 * 1024: return $((bytes + 1023) div 1024) & " KB"
  $((bytes + 1024 * 1024 - 1) div (1024 * 1024)) & " MB"

## Function purpose: the ceiling on what the viewer will read into memory at
## all. It exists because the read happens on the GTK thread, where the cost is
## paid by the frame the user is waiting for, and it is tied to the attachment
## cap rather than chosen separately: a file the composer would accept must be
## one the window can then open, or the two halves of the same window disagree
## about the same file. `asset-selftest` asserts that relation.
const MaxOpenBytes* = pipeline.MaxAttachmentBytes

## Function purpose: how much of a text asset the read-only view is given.
## A preview is a look at a file, not a text editor: a `TextBuffer` holding
## tens of megabytes is laid out by Pango on the GTK thread, which is the frame
## the user is waiting for.
const PreviewTextCap* = 256 * 1024

## Function purpose: the shown text plus whether anything was left out, because
## a view that silently stops at a cap is indistinguishable from a file that
## ends there.
proc previewText*(data: string): tuple[text: string, truncated: bool] =
  if data.len <= PreviewTextCap: return (data, false)
  (data[0 ..< PreviewTextCap], true)

## Function purpose: the name to offer in the export dialog. The stored name is
## what the user uploaded and is the right suggestion; it is stripped of any
## path because a name carrying separators would land the write somewhere the
## user did not choose in the picker.
proc exportName*(name: string): string =
  result = name
  for sep in ['/', '\\']:
    let at = result.rfind(sep)
    if at >= 0: result = result[at + 1 .. ^1]
  if result.len == 0 or result == "." or result == "..": result = "asset"
