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
## **Scope of parity, decided here and recorded as D-BK.** The sections and field
## names reproduce `jca_web`'s `ChatSettings` one for one, minus the two the USER
## excluded (API Key, MCP) and minus the fields whose *feature* does not exist in
## this window yet. A control wired to nothing is not parity — it is **G-8's and
## G-37's exact defect**, a thing defined and applied to nothing, and this project
## has now shipped it twice. Each omission is listed in `OmittedFields` below with
## the step that brings it back, so it is not rediscovered as a gap.

import std/[json, os, strutils, tables]
import ./paths

type
  SettingKind* = enum
    ## How a stored string is converted on its way into the request body, and
    ## which widget draws it.
    skFloat, skInt, skBool, skString, skText

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
    help*: string

  Settings* = object
    values*: Table[string, string]

const
  ## Every field, in the order it is drawn, grouped by the section it belongs to.
  ## Labels and help text are taken from `jca_web`'s `settings-config.ts` and
  ## `ChatSettings.svelte` rather than reworded, so the two surfaces describe a
  ## parameter the same way.
  Defs*: seq[SettingDef] = @[
    # ---- General ---------------------------------------------------------
    SettingDef(key: "systemMessage", label: "System message",
               section: ssGeneral, kind: skText,
               help: "The starting message that defines how the model should " &
                     "behave. It is placed beneath Jenova's own persona, not " &
                     "instead of it."),
    SettingDef(key: "enableContinueGeneration",
               label: "Enable \"Continue\" button",
               section: ssGeneral, kind: skBool, boolDefault: false,
               help: "Offer Continue on the last reply. Works only with " &
                     "non-reasoning models."),

    # ---- Display ---------------------------------------------------------
    SettingDef(key: "showMessageStats",
               label: "Show message generation statistics",
               section: ssDisplay, kind: skBool, boolDefault: true,
               help: "Display tokens, tokens/second and context use beneath " &
                     "each reply."),
    SettingDef(key: "keepStatsVisible",
               label: "Keep stats visible after generation",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Keep processing statistics visible after generation " &
                     "finishes."),
    SettingDef(key: "showThoughtInProgress",
               label: "Show thought in progress",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Expand the reasoning box by default while a reasoning " &
                     "model is generating."),
    SettingDef(key: "renderUserContentAsMarkdown",
               label: "Render user content as Markdown",
               section: ssDisplay, kind: skBool, boolDefault: false,
               help: "Render your own messages with markdown formatting."),

    # ---- Sampling --------------------------------------------------------
    SettingDef(key: "temperature", label: "Temperature",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "Controls the randomness of the generated text by " &
                     "affecting the probability distribution of the output " &
                     "tokens. Higher = more random, lower = more focused."),
    SettingDef(key: "dynatemp_range", label: "Dynamic temperature range",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "Addon for the temperature sampler. The added value to " &
                     "the range of dynamic temperature, which adjusts " &
                     "probabilities by entropy of tokens."),
    SettingDef(key: "dynatemp_exponent", label: "Dynamic temperature exponent",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "Addon for the temperature sampler. Smoothes out the " &
                     "probability redistribution based on the most probable " &
                     "token."),
    SettingDef(key: "top_k", label: "Top K",
               section: ssSampling, kind: skInt, inRequest: true,
               help: "Keeps only k top tokens."),
    SettingDef(key: "top_p", label: "Top P",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "Limits tokens to those that together have a cumulative " &
                     "probability of at least p."),
    SettingDef(key: "min_p", label: "Min P",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "Limits tokens based on the minimum probability for a " &
                     "token to be considered, relative to the probability of " &
                     "the most likely token."),
    SettingDef(key: "xtc_probability", label: "XTC probability",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "XTC sampler cuts out top tokens; this parameter " &
                     "controls the chance of cutting tokens at all. 0 " &
                     "disables XTC."),
    SettingDef(key: "xtc_threshold", label: "XTC threshold",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "XTC sampler cuts out top tokens; this parameter " &
                     "controls the token probability that is required to cut " &
                     "that token."),
    SettingDef(key: "typ_p", label: "Typical P",
               section: ssSampling, kind: skFloat, inRequest: true,
               help: "Sorts and limits tokens based on the difference " &
                     "between log-probability and entropy."),
    SettingDef(key: "max_tokens", label: "Max tokens",
               section: ssSampling, kind: skInt, inRequest: true,
               help: "The maximum number of tokens per output. Use -1 for " &
                     "infinite (no limit)."),
    SettingDef(key: "samplers", label: "Samplers",
               section: ssSampling, kind: skString, inRequest: true,
               help: "The order at which samplers are applied, in simplified " &
                     "way. Default is \"top_k;typ_p;top_p;min_p;temperature\"."),
    SettingDef(key: "backend_sampling", label: "Backend sampling",
               section: ssSampling, kind: skBool, boolDefault: false,
               inRequest: true,
               help: "Enable backend-based samplers. When enabled, supported " &
                     "samplers run on the accelerator backend for faster " &
                     "sampling."),

    # ---- Penalties -------------------------------------------------------
    SettingDef(key: "repeat_last_n", label: "Repeat last N",
               section: ssPenalties, kind: skInt, inRequest: true,
               help: "Last n tokens to consider for penalizing repetition."),
    SettingDef(key: "repeat_penalty", label: "Repeat penalty",
               section: ssPenalties, kind: skFloat, inRequest: true,
               help: "Controls the repetition of token sequences in the " &
                     "generated text."),
    SettingDef(key: "presence_penalty", label: "Presence penalty",
               section: ssPenalties, kind: skFloat, inRequest: true,
               help: "Limits tokens based on whether they appear in the " &
                     "output or not."),
    SettingDef(key: "frequency_penalty", label: "Frequency penalty",
               section: ssPenalties, kind: skFloat, inRequest: true,
               help: "Limits tokens based on how often they appear in the " &
                     "output."),
    SettingDef(key: "dry_multiplier", label: "DRY multiplier",
               section: ssPenalties, kind: skFloat, inRequest: true,
               help: "DRY sampling reduces repetition in generated text even " &
                     "across long contexts. This parameter sets the DRY " &
                     "sampling multiplier."),
    SettingDef(key: "dry_base", label: "DRY base",
               section: ssPenalties, kind: skFloat, inRequest: true,
               help: "DRY sampling reduces repetition in generated text even " &
                     "across long contexts. This parameter sets the DRY " &
                     "sampling base value."),
    SettingDef(key: "dry_allowed_length", label: "DRY allowed length",
               section: ssPenalties, kind: skInt, inRequest: true,
               help: "DRY sampling reduces repetition in generated text even " &
                     "across long contexts. This parameter sets the allowed " &
                     "length for DRY sampling."),
    SettingDef(key: "dry_penalty_last_n", label: "DRY penalty last N",
               section: ssPenalties, kind: skInt, inRequest: true,
               help: "DRY sampling reduces repetition in generated text even " &
                     "across long contexts. This parameter sets DRY penalty " &
                     "for the last n tokens."),

    # ---- Developer -------------------------------------------------------
    SettingDef(key: "disableReasoningParsing",
               label: "Disable reasoning content parsing",
               section: ssDeveloper, kind: skBool, boolDefault: false,
               inRequest: true,
               help: "Send reasoning_format=none to prevent server-side " &
                     "extraction of reasoning tokens into a separate field."),
    SettingDef(key: "excludeReasoningFromContext",
               label: "Exclude reasoning from context",
               section: ssDeveloper, kind: skBool, boolDefault: false,
               help: "Strip reasoning content from previous messages before " &
                     "sending to the model. When unchecked, reasoning is " &
                     "sent back so the model can see its own chain-of-" &
                     "thought across turns."),
    SettingDef(key: "custom", label: "Custom JSON",
               section: ssDeveloper, kind: skText, inRequest: true,
               help: "Custom JSON parameters to send to the API. Must be " &
                     "valid JSON format. Merged last, so it overrides any " &
                     "field above."),
  ]

  ## The Web UI fields deliberately not drawn, and what brings each one back.
  ## Recorded so a later session does not read the difference as an oversight and
  ## re-derive it — and so none of them is added as a control with no feature
  ## under it (**D-BK**).
  OmittedFields*: seq[tuple[key, reason: string]] = @[
    ("apiKey", "excluded by the USER — this server does not authenticate"),
    ("serverUrl", "excluded by the USER; the desktop application is the host"),
    ("mcpServers", "MCP is deferred (SETTLED FACT); the whole section is skipped"),
    ("mcpServerUsageStats", "MCP is deferred"),
    ("agenticMaxTurns", "MCP is deferred"),
    ("agenticMaxToolPreviewLines", "MCP is deferred"),
    ("showToolCallInProgress", "MCP is deferred"),
    ("alwaysShowAgenticTurns", "MCP is deferred"),
    ("theme", "the window's palette is dark-only; a light theme is theming " &
              "work, not a setting"),
    ("askForTitleConfirmation", "the window has no automatic conversation " &
                                "titling to confirm"),
    ("disableAutoScroll", "the transcript has no automatic scroll to disable"),
    ("fullHeightCodeBlocks", "code blocks already render at full height — " &
                             "`.code-body` carries no height cap to override, " &
                             "and the transcript word-wraps instead (G-11)"),
    ("pasteLongTextToFileLen", "attachments — G-30, PLANS.md Step 7b"),
    ("copyTextAttachmentsAsPlainText", "attachments — G-30, Step 7b"),
    ("pdfAsImage", "attachments — G-30, Step 7b"),
    ("autoMicOnEmpty", "audio capture — G-30, Step 7b"),
    ("showRawModelNames", "the model selector — G-20, Step 8a"),
    ("showRawOutputSwitch", "there is no per-message raw-output toggle to " &
                            "enable — it lands with G-35's message surface"),
    ("alwaysShowSidebarOnDesktop", "the window has one sidebar and one " &
                                   "toggle; there is no desktop/mobile split"),
    ("autoShowSidebarOnNewChat", "same — the sidebar toggle is manual and " &
                                 "persistent"),
  ]

  SettingsFile = "settings.json"

## Function purpose: the stored settings for a fresh install — every field empty
## except the booleans, which carry their own default. Empty is meaningful (see
## the header), so this is not the same as an empty table.
proc initSettings*(): Settings =
  result.values = initTable[string, string]()
  for d in Defs:
    result.values[d.key] =
      if d.kind == skBool: (if d.boolDefault: "1" else: "0") else: ""

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

## Function purpose: load the settings, falling back to the defaults for anything
## the file does not carry. **A malformed or absent file is the defaults, never an
## error** — this is read on the window's startup path, and a settings file that
## refuses to parse must not stop the application opening.
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

proc load*(p: Paths): Settings = loadFrom(settingsFile(p))

## Function purpose: persist the settings beside `lan_mode`, which is the pattern
## this window already uses for state that must survive a restart but does not
## belong in the database.
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
