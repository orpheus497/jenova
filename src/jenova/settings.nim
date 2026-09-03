## Script function and purpose: the desktop application's settings — the values
## behind `PLANS.md` Step 5 (G-31), and the merge that puts the sampling and
## penalty parameters into the request body.
##
## **This module is deliberately below the window.** The values are defined,
## stored, validated and merged here; `gui.nim` draws them and nothing more. That
## is the whole lesson of **D-BH**: Continue shipped broken twice while the
## request body was assembled inside `gui.nim`, where nothing under the widget
## layer could assert it. A settings dialog that built its own body would undo
## that, so the merge is `applyTo` and it is reachable from `pipeline-selftest`.
##
## **A value is a string, and empty means "not set".** That is the Web UI's own
## semantic (`settings-config.ts`: "empty means use server default ... and are NOT
## sent in API requests, letting the server decide") and it is the reason the
## storage is not typed: a `float` field cannot distinguish "the user asked for
## 0.0" from "the user never touched it", and sending a defaulted 0 for every
## parameter would silently override the server's own preset on every request.
## Conversion happens once, in `applyTo`, on the values that survive that test.
##
## **The field list is 1:1 with `jca_web`'s `ChatSettings.svelte` `settingSections`**
## — that array, not `SETTING_CONFIG_DEFAULT`, is the authority, because the
## config object also holds keys the Web UI never draws (`showSystemMessage`,
## `mcpServerUsageStats`). Two groups are excluded on the USER's instruction: the
## **API Key** field and the whole **MCP** section. One more is excluded on
## architectural grounds and is recorded rather than dropped silently —
## **`serverUrl`**, see `OmittedFields`.
##
## **Every remaining field is drawn** (**D-BL**, superseding D-BK's narrower
## rule). Where the behaviour a field governs does not exist in this window yet,
## the field still stores its value and is marked `awaiting`, so the panel says
## which step turns it on rather than presenting a control that silently does
## nothing. That is the difference between a documented schedule and G-8's
## defect.

import std/[json, os, strutils, tables]
import ./paths

type
  SettingKind* = enum
    ## How a stored string is converted on its way into the request body, and
    ## which widget draws it.
    skFloat, skInt, skBool, skString, skText, skSelect

  SettingSection* = enum
    ssGeneral = "General"
    ssDisplay = "Display"
    ssSampling = "Sampling"
    ssPenalties = "Penalties"
    ssImportExport = "Import/Export"
    ssDeveloper = "Developer"

  SettingDef* = object
    key*: string
    label*: string
    section*: SettingSection
    kind*: SettingKind
    ## The default for a `skBool`. Every other kind defaults to empty, because
    ## empty is what makes the server's own value authoritative.
    boolDefault*: bool
    ## Sent to `llama-server` in the request body when set. False for the
    ## settings that only change what the window does.
    inRequest*: bool
    ## `llama-server` reports this parameter under a different name in
    ## `/props`. Empty means the key is the same. **Only `typ_p` differs**, and
    ## that single mismatch is why its placeholder was blank on the first build.
    propsKey*: string
    ## `llama-server`'s own compiled-in default, shown as ghost text before the
    ## backend has answered. Accurate because **Jenova passes no sampling flags
    ## on the command line at all** — checked in `lifecycle.nim` and both conf
    ## files — so the server always starts from these. Sourced from
    ## `common/common.h`'s `common_params_sampling`, not from memory.
    appDefault*: string
    ## Options for a `skSelect`, as `value|label` pairs.
    options*: seq[string]
    ## Empty when the field takes effect now. Otherwise the plain-English reason
    ## it does not yet, shown beside the control.
    awaiting*: string
    help*: string

  Settings* = object
    values*: Table[string, string]

const
  ## Every field, in the order `ChatSettings.svelte` draws it, section by
  ## section. Labels follow the Web UI's so the two surfaces name a parameter
  ## the same way. **The help text deliberately does not** — the Web UI's is
  ## reference text ("Keeps only k top tokens"), which says nothing about what to
  ## type. Each one below gives the usable range, which direction does what, and
  ## the value that switches the sampler off.
  Defs*: seq[SettingDef] = @[
    # ---- General ---------------------------------------------------------
    SettingDef(key: "theme", label: "Theme",
               section: ssGeneral, kind: skSelect,
               options: @["system|System", "light|Light", "dark|Dark"],
               help: "System follows your desktop's own light/dark preference. " &
                     "The dark palette is the brand one; the light palette is " &
                     "neutral, matching the Web UI's."),
    SettingDef(key: "systemMessage", label: "System message",
               section: ssGeneral, kind: skText,
               help: "Standing instructions sent at the top of every " &
                     "conversation — tone, role, things to always or never do. " &
                     "It is placed beneath Jenova's own persona rather than " &
                     "replacing it, so it adds to the behaviour instead of " &
                     "fighting it. Leave empty for no standing instruction."),
    SettingDef(key: "pasteLongTextToFileLen",
               label: "Paste long text to file length",
               section: ssGeneral, kind: skInt, appDefault: "2500",
               # W-01. **The reason this named was already false.** It read
               # "attachments — PLANS.md Step 7b (G-30)" long after attachments
               # shipped in full — file picker, drop zone, clipboard paste, PDF
               # extraction, thumbnails — so the field read as deferred when it
               # had simply been forgotten. What it actually waits on is
               # narrower and is named here instead.
               awaiting: "a paste handler on the composer. `DraftView` owns a " &
                         "GtkTextView and GTK pastes text into it directly, so " &
                         "there is no point at which this window sees the " &
                         "pasted string and could divert a long one",
               help: "Pasting more than this many characters turns the paste " &
                     "into a text attachment instead of filling the message " &
                     "box. 0 disables it."),
    SettingDef(key: "copyTextAttachmentsAsPlainText",
               label: "Copy text attachments as plain text",
               section: ssGeneral, kind: skBool, boolDefault: false,
               # W-01: wired. `pipeline.copyTextFor` decides it and
               # `gui.messageActions` calls it. It carried a stale `awaiting`
               # naming a blocker that had already shipped.
               help: "On, copying a message appends the text of anything " &
                     "attached to it, under the same heading the model was " &
                     "shown — so what you paste is what the model read. Off, " &
                     "you get the message text alone. Images are never " &
                     "copied either way: a base64 image is useless on a " &
                     "clipboard and is the largest part of the turn."),
    SettingDef(key: "enableContinueGeneration",
               label: "Enable \"Continue\" button",
               section: ssGeneral, kind: skBool, boolDefault: false,
               help: "Adds a Continue action to the last reply, which asks the " &
                     "model to carry on from where it stopped rather than " &
                     "start again. Off by default, matching the Web UI. Not " &
                     "offered on a reply that carries reasoning — see D-BH."),
    SettingDef(key: "pdfAsImage", label: "Parse PDF as image",
               section: ssGeneral, kind: skBool, boolDefault: false,
               # W-01: the reason was stale in the same way. This one is
               # genuinely blocked, but on rasterisation rather than on
               # attachments.
               awaiting: "a PDF rasteriser. `pdf.nim` extracts a page's text " &
                         "and nothing in this program can render a page to " &
                         "pixels, which is what sending pages as images means",
               help: "Send an attached PDF's pages as images rather than " &
                     "extracted text. Needs a vision model; falls back to text " &
                     "on one without."),
    SettingDef(key: "askForTitleConfirmation",
               label: "Ask before changing a conversation title",
               section: ssGeneral, kind: skBool, boolDefault: false,
               help: "A new conversation takes its name from your first " &
                     "message. With this on, editing that message asks before " &
                     "renaming the conversation to match."),

    # ---- Display ---------------------------------------------------------
    SettingDef(key: "showMessageStats",
               label: "Show message generation statistics",
               section: ssDisplay, kind: skBool, boolDefault: true,
               help: "The line under each reply: tokens in and out, tokens per " &
                     "second, how much of the context window the turn used, " &
                     "and which model answered."),
    SettingDef(key: "showThoughtInProgress",
               label: "Show thought in progress",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Keep a reasoning model's Reasoning box open by default. " &
                     "It already opens while a turn is streaming and whenever " &
                     "the answer itself is empty; this makes it open always."),
    SettingDef(key: "keepStatsVisible",
               label: "Keep stats visible after generation",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Only matters when the statistics line above is off: the " &
                     "live numbers still appear while a reply is generating, " &
                     "and this decides whether they stay once it finishes."),
    SettingDef(key: "autoMicOnEmpty",
               label: "Show microphone on empty input",
               section: ssDisplay, kind: skBool, boolDefault: false,
               # Still genuinely blocked, and unlike the three above it always
               # was: this window has no audio capture at all. The send path is
               # ready — `pipeline.contentFor` already emits `input_audio` parts
               # for a conversation imported from the Web UI — so what is
               # missing is the recorder, not the wire format.
               awaiting: "audio capture. Nothing in this window records, and " &
                         "GTK4 has no recorder of its own",
               help: "Show a record button instead of Send while the message " &
                     "box is empty, on models that accept audio."),
    SettingDef(key: "renderUserContentAsMarkdown",
               label: "Render user content as Markdown",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Format your own messages as markdown too, rather than " &
                     "showing them as the plain text you typed."),
    SettingDef(key: "fullHeightCodeBlocks",
               label: "Use full height code blocks",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Off, a long code block is capped in height and scrolls " &
                     "inside itself, so one answer cannot fill the whole " &
                     "transcript. On, every block is shown at its natural " &
                     "height."),
    SettingDef(key: "disableAutoScroll",
               label: "Disable automatic scroll",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "The transcript follows the reply as it streams. Turn " &
                     "this on to keep the view where you put it — useful when " &
                     "reading back while the model is still answering."),
    SettingDef(key: "alwaysShowSidebarOnDesktop",
               label: "Always show the sidebar",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Stop the sidebar folding itself away when the window is " &
                     "narrow. It keeps its width instead, and the chat column " &
                     "gets what is left."),
    SettingDef(key: "autoShowSidebarOnNewChat",
               label: "Show the sidebar on a new chat",
               section: ssDisplay, kind: skBool, boolDefault: true,
               help: "Open the sidebar automatically when you start a new " &
                     "conversation. Off, it stays as you left it."),
    SettingDef(key: "showRawModelNames", label: "Show raw model names",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "The statistics line shortens a model path to its bare " &
                     "name. On, it shows the identifier in full, which is what " &
                     "you need when two quantisations of one model are " &
                     "installed."),

    # ---- Sampling --------------------------------------------------------
    SettingDef(key: "temperature", label: "Temperature",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "0.8",
               help: "How much randomness the model is allowed. Range 0.0-2.0. " &
                     "Low (0.1-0.4) for code, extraction and factual answers; " &
                     "around 0.8 for conversation; above 1.2 gets inventive " &
                     "and starts to wander. 0 is effectively deterministic."),
    SettingDef(key: "dynatemp_range", label: "Dynamic temperature range",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "0.0",
               help: "Lets the temperature move by plus or minus this amount " &
                     "depending on how certain the model is — confident tokens " &
                     "get a lower temperature, uncertain ones higher. " &
                     "0 disables it. Try 0.2-0.4 with a temperature near 1.0."),
    SettingDef(key: "dynatemp_exponent", label: "Dynamic temperature exponent",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "1.0",
               help: "Shapes how sharply dynamic temperature reacts. Only has " &
                     "an effect when the range above is non-zero. Higher is " &
                     "more abrupt; 1.0 is linear."),
    SettingDef(key: "top_k", label: "Top K",
               section: ssSampling, kind: skInt, inRequest: true,
               appDefault: "40",
               help: "Consider only the k most likely next tokens. 1 is greedy " &
                     "— always the single best. 20-40 is the usual range; a " &
                     "very high value effectively disables it. Lower tightens, " &
                     "higher loosens."),
    SettingDef(key: "top_p", label: "Top P",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "0.95",
               help: "Keep the most likely tokens until their probabilities " &
                     "add up to p, and ignore the rest. Range 0.0-1.0, and " &
                     "1.0 disables it. 0.9-0.95 is typical; lower is more " &
                     "focused."),
    SettingDef(key: "min_p", label: "Min P",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "0.05",
               help: "Drop any token less than this fraction as likely as the " &
                     "best one. 0 disables it. 0.05-0.1 works well, and is " &
                     "often used instead of Top P rather than alongside it."),
    SettingDef(key: "xtc_probability", label: "XTC probability",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "0.0",
               help: "XTC removes the most obvious tokens to make writing less " &
                     "predictable. This is the chance of doing it at all, and " &
                     "0 disables XTC. 0.5 is a common starting point for " &
                     "creative work; leave it off for code."),
    SettingDef(key: "xtc_threshold", label: "XTC threshold",
               section: ssSampling, kind: skFloat, inRequest: true,
               appDefault: "0.1",
               help: "How likely a token must be before XTC will consider " &
                     "cutting it. Only matters when the probability above is " &
                     "non-zero. Above 0.5 disables XTC."),
    SettingDef(key: "typ_p", label: "Typical P",
               section: ssSampling, kind: skFloat, inRequest: true,
               propsKey: "typical_p", appDefault: "1.0",
               help: "Prefers tokens of typical surprise rather than simply " &
                     "the most likely, which reduces bland phrasing. " &
                     "1.0 disables it. Try 0.9-0.95."),
    SettingDef(key: "max_tokens", label: "Max tokens",
               section: ssSampling, kind: skInt, inRequest: true,
               appDefault: "-1",
               help: "Hard ceiling on the length of one reply. -1 means no " &
                     "limit and lets the model stop where it wants, which is " &
                     "usually what you want; set a number to cut long answers " &
                     "short."),
    SettingDef(key: "samplers", label: "Samplers",
               section: ssSampling, kind: skString, inRequest: true,
               help: "The order the samplers are applied in, separated by " &
                     "semicolons — for example " &
                     "top_k;typ_p;top_p;min_p;temperature. Only change this if " &
                     "you know why; the placeholder shows the order your " &
                     "server is actually using."),
    SettingDef(key: "backend_sampling", label: "Backend sampling",
               section: ssSampling, kind: skBool, boolDefault: false,
               inRequest: true,
               help: "Run the supported samplers on the GPU instead of the " &
                     "CPU. Faster where the backend supports it, and it does " &
                     "not change what is generated."),

    # ---- Penalties -------------------------------------------------------
    SettingDef(key: "repeat_last_n", label: "Repeat last N",
               section: ssPenalties, kind: skInt, inRequest: true,
               appDefault: "64",
               help: "How many recent tokens the repetition penalties look " &
                     "back over. 0 disables all of them; -1 means the whole " &
                     "context. 64-256 is the usual range."),
    SettingDef(key: "repeat_penalty", label: "Repeat penalty",
               section: ssPenalties, kind: skFloat, inRequest: true,
               appDefault: "1.0",
               help: "Divides the score of tokens that already appeared. " &
                     "1.0 disables it. 1.05-1.15 discourages loops; above 1.2 " &
                     "starts distorting normal language, because ordinary " &
                     "words repeat legitimately."),
    SettingDef(key: "presence_penalty", label: "Presence penalty",
               section: ssPenalties, kind: skFloat, inRequest: true,
               appDefault: "0.0",
               help: "A flat penalty for any token that has appeared at all, " &
                     "however often. 0 disables it. 0.1-0.5 pushes the model " &
                     "towards new subject matter."),
    SettingDef(key: "frequency_penalty", label: "Frequency penalty",
               section: ssPenalties, kind: skFloat, inRequest: true,
               appDefault: "0.0",
               help: "Penalty that grows with how often a token has already " &
                     "appeared. 0 disables it. 0.1-0.5 reduces verbal tics " &
                     "without banning a word outright."),
    SettingDef(key: "dry_multiplier", label: "DRY multiplier",
               section: ssPenalties, kind: skFloat, inRequest: true,
               appDefault: "0.0",
               help: "DRY penalises repeated sequences rather than single " &
                     "tokens, which is what stops a model looping a whole " &
                     "phrase. This is its strength, and 0 disables DRY. " &
                     "0.8 is the usual starting value."),
    SettingDef(key: "dry_base", label: "DRY base",
               section: ssPenalties, kind: skFloat, inRequest: true,
               appDefault: "1.75",
               help: "How steeply DRY's penalty grows as a repeated sequence " &
                     "gets longer. Only matters when the multiplier is " &
                     "non-zero. 1.75 suits most cases."),
    SettingDef(key: "dry_allowed_length", label: "DRY allowed length",
               section: ssPenalties, kind: skInt, inRequest: true,
               appDefault: "2",
               help: "How long a repeated run may be before DRY penalises it. " &
                     "2 catches loops early; raise it if the model writes code " &
                     "or lists where short repeats are legitimate."),
    SettingDef(key: "dry_penalty_last_n", label: "DRY penalty last N",
               section: ssPenalties, kind: skInt, inRequest: true,
               appDefault: "-1",
               help: "How far back DRY scans for repetition. -1 is the whole " &
                     "context; 0 disables it."),

    # ---- Developer -------------------------------------------------------
    SettingDef(key: "disableReasoningParsing",
               label: "Disable reasoning content parsing",
               section: ssDeveloper, kind: skBool, boolDefault: false,
               inRequest: true,
               help: "Stops the server splitting a reasoning model's thinking " &
                     "into its own field, so it arrives inline in the answer. " &
                     "This empties the Reasoning box — it is for seeing " &
                     "exactly what the model emitted."),
    SettingDef(key: "excludeReasoningFromContext",
               label: "Exclude reasoning from context",
               section: ssDeveloper, kind: skBool, boolDefault: false,
               help: "Strip earlier thinking out of the conversation before " &
                     "sending it. Off, the model sees its own reasoning from " &
                     "previous turns, which helps continuity and costs context."),
    SettingDef(key: "showRawOutputSwitch",
               label: "Enable raw output toggle",
               section: ssDeveloper, kind: skBool, boolDefault: false,
               help: "Adds a per-message button that switches between the " &
                     "rendered markdown and the exact text the model produced " &
                     "— which is how you tell a formatting bug from a model " &
                     "that really did write that."),
    SettingDef(key: "custom", label: "Custom JSON",
               section: ssDeveloper, kind: skText, inRequest: true,
               help: "A JSON object merged into every request, last, so it " &
                     "overrides anything above — including the fields the " &
                     "window sets itself. This is how to reach a parameter " &
                     "with no field here, such as " &
                     "{\"mirostat\": 2, \"top_n_sigma\": 1.0}."),
  ]

  ## The three fields `ChatSettings.svelte` draws that this panel does not, and
  ## why. Recorded so the difference is never read as an oversight (**D-BL**).
  OmittedFields*: seq[tuple[key, reason: string]] = @[
    ("apiKey", "excluded by the USER — this server does not authenticate"),
    ("mcpServers", "the whole MCP section is excluded by the USER; MCP is " &
                   "deferred (SETTLED FACT)"),
    ("serverUrl", "architectural, not scope. `bin/jenova` starts its own " &
                  "server and backends and is the host — settled at N-S6 and " &
                  "again at Session 006. A field pointing the window at a " &
                  "different backend would bypass the local pipeline, personas " &
                  "and retrieval, which is a product change and not a setting. " &
                  "LAN mode already covers serving this machine to others."),
  ]

  SettingsFile = "settings.json"

## Function purpose: the stored settings for a fresh install — every field empty
## except the booleans and the one select, which carry their own default. Empty
## is meaningful (see the header), so this is not the same as an empty table.
proc initSettings*(): Settings =
  result.values = initTable[string, string]()
  for d in Defs:
    result.values[d.key] =
      case d.kind
      of skBool: (if d.boolDefault: "1" else: "0")
      of skSelect: (if d.options.len > 0: d.options[0].split('|')[0] else: "")
      else: ""

proc settingsFile(p: Paths): string = p.state / SettingsFile

## Function purpose: read a value as stored. An unknown key answers empty rather
## than raising, so a field added to `Defs` after a file was written reads as
## unset instead of breaking the load.
proc get*(s: Settings, key: string): string =
  s.values.getOrDefault(key, "")

proc getBool*(s: Settings, key: string): bool =
  s.get(key) == "1"

proc `[]=`*(s: var Settings, key, value: string) =
  s.values[key] = value

## Function purpose: the definition for a key, so the window can ask about one
## field without walking `Defs` itself.
proc defFor*(key: string): SettingDef =
  for d in Defs:
    if d.key == key: return d

## Function purpose: the name `llama-server` reports this parameter under in
## `/props`. **`typ_p` is the only one that differs** — the server calls it
## `typical_p` — and that single mismatch is why its placeholder was blank until
## this existed.
proc propsNameFor*(d: SettingDef): string =
  if d.propsKey.len > 0: d.propsKey else: d.key

proc loadFrom*(file: string): Settings =
  result = initSettings()
  if not fileExists(file): return
  try:
    let node = parseJson(readFile(file))
    if node.kind != JObject: return
    for d in Defs:
      if node.hasKey(d.key) and node[d.key].kind == JString:
        result.values[d.key] = node[d.key].getStr
  except CatchableError:
    discard

## Function purpose: load the settings, falling back to the defaults for anything
## the file does not carry. **A malformed or absent file is the defaults, never an
## error** — this is read on the window's startup path, and a settings file that
## refuses to parse must not stop the application opening.
proc load*(p: Paths): Settings = loadFrom(settingsFile(p))

## The path is a parameter on this pair so a self-test can round-trip the store
## without writing over the USER's own `settings.json` — the same reason every
## other self-test opens a scratch database rather than the real one.
proc saveTo*(file: string, s: Settings): bool =
  try:
    createDir(file.parentDir)
    var node = newJObject()
    for d in Defs:
      node[d.key] = %s.get(d.key)
    writeFile(file, pretty(node))
    true
  except CatchableError:
    false

proc save*(p: Paths, s: Settings): bool = saveTo(settingsFile(p), s)

## Function purpose: report the first field whose stored text cannot be converted
## to the type it will be sent as, so the dialog can refuse the save and say which
## one. **The check has to happen before storing, not at merge time:** `applyTo`
## runs on the way to the model and silently dropping a malformed value there
## would look exactly like a parameter the server ignored.
proc validate*(s: Settings): tuple[ok: bool, key, msg: string] =
  for d in Defs:
    let raw = s.get(d.key).strip
    if raw.len == 0: continue
    case d.kind
    of skFloat:
      try: discard parseFloat(raw)
      except ValueError: return (false, d.key, "expects a number")
    of skInt:
      try: discard parseInt(raw)
      except ValueError: return (false, d.key, "expects a whole number")
    of skText:
      if d.key == "custom":
        try:
          if parseJson(raw).kind != JObject:
            return (false, d.key, "must be a JSON object")
        except CatchableError:
          return (false, d.key, "is not valid JSON")
    else: discard
  (true, "", "")

## Function purpose: merge the request-affecting settings into a chat request
## body. Called by `pipeline.chatBody` so the values land in the JSON that
## actually goes to `llama-server`, and so a self-test can read the result
## without a window or a generation.
##
## Action purpose: **an empty value is omitted, not sent as a zero.** The server's
## own preset is the source of truth for anything the user has not set, so a
## parameter appears in the body only when it carries text. `custom` is merged
## last and overwrites, which is what makes it the escape hatch for a parameter
## this build does not name.
proc applyTo*(body: JsonNode, s: Settings) =
  if body.kind != JObject: return
  for d in Defs:
    if not d.inRequest: continue
    let raw = s.get(d.key).strip
    case d.kind
    of skBool:
      # A boolean is always set or not-set, never empty, so "off" would be a real
      # `false` in the body. Only the enabled state is sent: an unasked-for
      # `false` is still an override of the server's preset.
      if raw == "1" and d.key != "disableReasoningParsing":
        body[d.key] = %true
    of skFloat:
      if raw.len > 0:
        try: body[d.key] = %parseFloat(raw)
        except ValueError: discard
    of skInt:
      if raw.len > 0:
        try: body[d.key] = %parseInt(raw)
        except ValueError: discard
    of skString:
      if raw.len > 0: body[d.key] = %raw
    of skSelect:
      # No select is a request parameter — `theme` is the only one and it is
      # entirely a window concern.
      discard
    of skText:
      if d.key == "custom" and raw.len > 0:
        try:
          let extra = parseJson(raw)
          if extra.kind == JObject:
            for k, v in extra: body[k] = v
        except CatchableError:
          discard

## Function purpose: the `reasoning_format` the request should carry. `"auto"`
## makes `llama-server` split a reasoning model's thinking out of the answer,
## which is what the reasoning view (G-39) reads; `"none"` leaves it inline and is
## what the Developer switch is for.
proc reasoningFormat*(s: Settings): string =
  if s.getBool("disableReasoningParsing"): "none" else: "auto"

## Function purpose: group the fields for the dialog, in section order, without
## the window having to know which key belongs where.
proc fieldsIn*(section: SettingSection): seq[SettingDef] =
  for d in Defs:
    if d.section == section: result.add d
