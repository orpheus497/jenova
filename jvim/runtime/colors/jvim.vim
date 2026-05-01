" jvim native colorscheme — powdery dark palette with optional pywal blend.
"
" Backgrounds are always a blackish-grey (never pure black) and the UI
" chrome stays in the dark/muted family. Syntax foregrounds blend a
" hand-picked maroon / royal-purple / violet / dark-yellow / orange palette
" with whatever pywal has cached, when the user opts in.
"
" To enable pywal blending:
"   :let g:jvim_use_pywal = 1   " before colorscheme jvim
"   …or set vim.g.jvim_use_pywal = true in your init.lua
" When enabled and ~/.cache/wal/colors is readable, the wal colours override
" the syntax accent slots; backgrounds stay derived from our blackish base
" so the UI never inherits pywal's pure-black bg or washed-out fg.

hi clear
if exists("syntax_on")
  syntax reset
endif
let g:colors_name = "jvim"
set background=dark

if !exists('g:jvim_use_pywal')
  let g:jvim_use_pywal = 1
endif

" ── Hardcoded base palette ──────────────────────────────────────────────────
" Blackish-grey backgrounds (NEVER pure black even when pywal gives #000000).
" Powdery muted accents in the maroon/royal-purple/violet/yellow/orange
" family. These are the fallback when pywal is disabled or unavailable.
let s:base = {
\ 'bg':       '#14131A',
\ 'bg_dim':   '#0E0D14',
\ 'bg_hi':    '#1F1D26',
\ 'sep':      '#2B2933',
\ 'sel':      '#3A2E4A',
\ 'fg':       '#D8C9C0',
\ 'fg_dim':   '#7A6E78',
\ 'maroon':   '#9B4F6D',
\ 'coral':    '#C4685E',
\ 'peach':    '#D88A6E',
\ 'tan':      '#C4A075',
\ 'royal':    '#7A6AA0',
\ 'plum':     '#926A96',
\ 'violet':   '#B8A0C0',
\ }

" ── Pywal loader ────────────────────────────────────────────────────────────
" Reads ~/.cache/wal/colors (16 hex lines) and returns a list of hex strings.
" Returns [] on any failure so we silently fall back to the base palette.
function! s:load_wal() abort
  let l:path = expand('~/.cache/wal/colors')
  if !filereadable(l:path) | return [] | endif
  let l:lines = readfile(l:path)
  let l:out = []
  for l:line in l:lines
    let l:hex = matchstr(l:line, '#\x\{6}')
    if !empty(l:hex) | call add(l:out, l:hex) | endif
  endfor
  return len(l:out) >= 8 ? l:out : []
endfunction

" Lift / clamp a hex colour by a signed amount on every channel. Used to
" derive bg_hi / sep / sel from the base bg without exposing pure black.
function! s:shift(hex, amount) abort
  let l:r = str2nr(strpart(a:hex, 1, 2), 16) + a:amount
  let l:g = str2nr(strpart(a:hex, 3, 2), 16) + a:amount
  let l:b = str2nr(strpart(a:hex, 5, 2), 16) + a:amount
  let l:r = max([0, min([255, l:r])])
  let l:g = max([0, min([255, l:g])])
  let l:b = max([0, min([255, l:b])])
  return printf('#%02x%02x%02x', l:r, l:g, l:b)
endfunction

" Build the live palette: backgrounds always come from the base (blackish
" grey, never pure pywal #000000), accents come from pywal if available
" and enabled, otherwise from the base palette.
function! s:build_palette() abort
  let l:p = copy(s:base)
  if !g:jvim_use_pywal | return l:p | endif
  let l:wal = s:load_wal()
  if empty(l:wal) | return l:p | endif

  " Pywal slot mapping (matches Linux 16-colour terminal convention):
  "   1 maroon   2 coral    3 peach    4 tan
  "   5 royal    6 plum     7 fg       8 fg_dim
  let l:p.maroon = l:wal[1]
  let l:p.coral  = l:wal[2]
  let l:p.peach  = l:wal[3]
  let l:p.tan    = l:wal[4]
  let l:p.royal  = l:wal[5]
  let l:p.plum   = l:wal[6]
  " Only adopt pywal's fg if it is not too washed out (>= R+G+B 360 ≈ medium)
  let l:fg = l:wal[7]
  let l:r = str2nr(strpart(l:fg, 1, 2), 16)
  let l:g = str2nr(strpart(l:fg, 3, 2), 16)
  let l:b = str2nr(strpart(l:fg, 5, 2), 16)
  if l:r + l:g + l:b > 360
    let l:p.fg = l:fg
  endif
  if len(l:wal) > 8 | let l:p.fg_dim = l:wal[8] | endif
  " Derive a softer violet from royal so identifiers and tag attrs read
  " distinctly from function names.
  let l:p.violet = s:shift(l:p.royal, 36)
  return l:p
endfunction

let s:p = s:build_palette()

" Aliases for legacy callers (statusline / icons / dashboard consumers that
" reference s:p.red / s:p.green / s:p.blue etc.). They map to the closest
" semantic accent in the new palette so nothing renders untyped.
let s:p.red     = s:p.maroon
let s:p.orange  = s:p.peach
let s:p.yellow  = s:p.tan
let s:p.green   = s:p.plum
let s:p.cyan    = s:p.plum
let s:p.blue    = s:p.royal
let s:p.magenta = s:p.royal
let s:p.purple  = s:p.royal
let s:p.error   = s:p.coral
let s:p.warn    = s:p.peach
let s:p.info    = s:p.royal
let s:p.hint    = s:p.plum
let s:p.punct   = s:p.violet
let s:p.ident   = s:p.violet

function! s:hi(group, fg, bg, attr) abort
  let l:cmd = 'hi ' . a:group
  if !empty(a:fg)   | let l:cmd .= ' guifg=' . a:fg     | endif
  if !empty(a:bg)   | let l:cmd .= ' guibg=' . a:bg     | endif
  if !empty(a:attr) | let l:cmd .= ' gui=' . a:attr . ' cterm=' . a:attr | endif
  execute l:cmd
endfunction

" ── Editor / UI chrome ──────────────────────────────────────────────────────
call s:hi('Normal',       s:p.fg,     s:p.bg,    '')
call s:hi('NormalNC',     s:p.fg_dim, s:p.bg,    '')
call s:hi('NormalFloat',  s:p.fg,     s:p.bg_hi, '')
call s:hi('FloatBorder',  s:p.sep,    s:p.bg_hi, '')
call s:hi('FloatTitle',   s:p.tan,    s:p.bg_hi, 'bold')
call s:hi('SignColumn',   '',         s:p.bg,    '')
call s:hi('LineNr',       s:p.fg_dim, s:p.bg,    '')
call s:hi('CursorLineNr', s:p.tan,    s:p.bg,    'bold')
call s:hi('CursorLine',   '',         s:p.bg_hi, '')
call s:hi('CursorColumn', '',         s:p.bg_hi, '')
call s:hi('ColorColumn',  '',         s:p.bg_hi, '')
call s:hi('VertSplit',    s:p.sep,    '',        '')
call s:hi('WinSeparator', s:p.sep,    '',        '')
call s:hi('StatusLine',   s:p.fg,     s:p.bg_hi, '')
call s:hi('StatusLineNC', s:p.fg_dim, s:p.bg_hi, '')
call s:hi('TabLine',      s:p.fg_dim, s:p.bg_hi, '')
call s:hi('TabLineFill',  '',         s:p.bg_hi, '')
call s:hi('TabLineSel',   s:p.fg,     s:p.bg,    'bold')
call s:hi('Pmenu',        s:p.fg,     s:p.bg_hi, '')
call s:hi('PmenuSel',     s:p.bg,     s:p.tan,   'bold')
call s:hi('PmenuSbar',    '',         s:p.sep,   '')
call s:hi('PmenuThumb',   '',         s:p.fg_dim,'')
call s:hi('Visual',       '',         s:p.sel,   '')
call s:hi('Search',       s:p.bg,     s:p.tan,   '')
call s:hi('IncSearch',    s:p.bg,     s:p.peach, 'bold')
call s:hi('MatchParen',   s:p.peach,  s:p.bg_hi, 'bold')
call s:hi('NonText',      s:p.sep,    '',        '')
call s:hi('Whitespace',   s:p.sep,    '',        '')
call s:hi('SpecialKey',   s:p.sep,    '',        '')
call s:hi('Folded',       s:p.fg_dim, s:p.bg_hi, 'italic')
call s:hi('FoldColumn',   s:p.fg_dim, s:p.bg,    '')
call s:hi('Conceal',      s:p.fg_dim, s:p.bg,    '')
call s:hi('Directory',    s:p.royal,  '',        'bold')
call s:hi('Title',        s:p.tan,    '',        'bold')
call s:hi('Question',     s:p.plum,   '',        '')
call s:hi('ErrorMsg',     s:p.coral,  '',        'bold')
call s:hi('WarningMsg',   s:p.peach,  '',        '')
call s:hi('ModeMsg',      s:p.fg,     '',        'bold')
call s:hi('MoreMsg',      s:p.plum,   '',        '')

" ── Syntax (linked groups carry through to most language plugins) ───────────
" Distinct hue per role so structure reads at a glance — no two adjacent
" categories share a colour. Maroon + royal-purple are the dominant anchors.
call s:hi('Comment',      s:p.fg_dim, '',        'italic')
call s:hi('Constant',     s:p.peach,  '',        '')
call s:hi('String',       s:p.tan,    '',        '')
call s:hi('Character',    s:p.tan,    '',        '')
call s:hi('Number',       s:p.peach,  '',        '')
call s:hi('Boolean',      s:p.peach,  '',        'bold')
call s:hi('Float',        s:p.peach,  '',        '')
call s:hi('Identifier',   s:p.violet, '',        '')
call s:hi('Function',     s:p.royal,  '',        'bold')
call s:hi('Statement',    s:p.maroon, '',        'italic')
call s:hi('Conditional',  s:p.maroon, '',        'italic')
call s:hi('Repeat',       s:p.maroon, '',        'italic')
call s:hi('Label',        s:p.maroon, '',        '')
call s:hi('Operator',     s:p.peach,  '',        '')
call s:hi('Keyword',      s:p.maroon, '',        'italic')
call s:hi('Exception',    s:p.coral,  '',        'italic')
call s:hi('PreProc',      s:p.plum,   '',        '')
call s:hi('Include',      s:p.plum,   '',        'italic')
call s:hi('Define',       s:p.plum,   '',        '')
call s:hi('Macro',        s:p.plum,   '',        '')
call s:hi('Type',         s:p.tan,    '',        'bold')
call s:hi('StorageClass', s:p.maroon, '',        '')
call s:hi('Structure',    s:p.tan,    '',        'bold')
call s:hi('Typedef',      s:p.tan,    '',        '')
call s:hi('Special',      s:p.peach,  '',        '')
call s:hi('SpecialChar',  s:p.peach,  '',        '')
call s:hi('Tag',          s:p.royal,  '',        '')
call s:hi('Delimiter',    s:p.punct,  '',        '')
call s:hi('SpecialComment', s:p.plum, '',        'italic')
call s:hi('Underlined',   s:p.royal,  '',        'underline')
call s:hi('Error',        s:p.coral,  '',        'bold')
call s:hi('Todo',         s:p.tan,    s:p.bg_hi, 'bold')

" ── Diagnostics ─────────────────────────────────────────────────────────────
call s:hi('DiagnosticError', s:p.coral, '', '')
call s:hi('DiagnosticWarn',  s:p.peach, '', '')
call s:hi('DiagnosticInfo',  s:p.royal, '', '')
call s:hi('DiagnosticHint',  s:p.plum,  '', '')
call s:hi('DiagnosticOk',    s:p.tan,   '', '')
call s:hi('DiagnosticUnderlineError', '', '', 'undercurl')
call s:hi('DiagnosticUnderlineWarn',  '', '', 'undercurl')
call s:hi('DiagnosticUnderlineInfo',  '', '', 'undercurl')
call s:hi('DiagnosticUnderlineHint',  '', '', 'undercurl')

" ── Diff / Git ──────────────────────────────────────────────────────────────
call s:hi('DiffAdd',    s:p.plum,   s:p.bg_hi, '')
call s:hi('DiffChange', s:p.tan,    s:p.bg_hi, '')
call s:hi('DiffDelete', s:p.coral,  s:p.bg_hi, '')
call s:hi('DiffText',   s:p.peach,  s:p.bg_hi, 'bold')

call s:hi('GitSignsAdd',    s:p.plum,  '', '')
call s:hi('GitSignsChange', s:p.tan,   '', '')
call s:hi('GitSignsDelete', s:p.coral, '', '')

" ── Spell ───────────────────────────────────────────────────────────────────
call s:hi('SpellBad',   s:p.coral, '', 'undercurl')
call s:hi('SpellCap',   s:p.peach, '', 'undercurl')
call s:hi('SpellLocal', s:p.royal, '', 'undercurl')
call s:hi('SpellRare',  s:p.plum,  '', 'undercurl')

" ── LSP / treesitter highlight links ────────────────────────────────────────
hi! link @comment Comment
hi! link @comment.documentation SpecialComment
hi! link @keyword Keyword
hi! link @keyword.return Statement
hi! link @keyword.operator Keyword
hi! link @keyword.import Include
hi! link @function Function
hi! link @function.call Function
hi! link @function.builtin Function
hi! link @function.macro Macro
hi! link @method Function
hi! link @method.call Function
hi! link @constructor Type
hi! link @variable Identifier
hi! link @variable.parameter Identifier
hi! link @variable.member Identifier
hi! link @variable.builtin Constant
hi! link @field Identifier
hi! link @property Identifier
hi! link @parameter Identifier
hi! link @type Type
hi! link @type.builtin Type
hi! link @type.definition Typedef
hi! link @type.qualifier StorageClass
hi! link @attribute PreProc
hi! link @namespace Type
hi! link @module Type
hi! link @constant Constant
hi! link @constant.builtin Constant
hi! link @constant.macro Macro
hi! link @string String
hi! link @string.escape SpecialChar
hi! link @character Character
hi! link @number Number
hi! link @boolean Boolean
hi! link @float Float
hi! link @operator Operator
hi! link @punctuation Delimiter
hi! link @punctuation.bracket Delimiter
hi! link @punctuation.delimiter Delimiter
hi! link @punctuation.special Special
hi! link @tag Tag
hi! link @tag.attribute Identifier
hi! link @tag.delimiter Delimiter

" Markdown — used by the Jenova chat buffer
hi! link @markup.heading.1.markdown Title
hi! link @markup.heading.2.markdown Title
hi! link @markup.heading.3.markdown Title
hi! link @markup.strong Statement
hi! link @markup.italic Comment
hi! link @markup.raw String
hi! link @markup.link Tag
hi! link @markup.link.url Underlined

" ── jvim dashboard / ui / notify ────────────────────────────────────────────
call s:hi('JvimDashboardHeader',   s:p.tan,     '', 'bold')
call s:hi('JvimDashboardJvim',     s:p.royal,   '', 'bold')
call s:hi('JvimDashboardTitle',    s:p.maroon,  '', 'bold')
call s:hi('JvimDashboardSubtitle', s:p.fg_dim,  '', 'italic')
call s:hi('JvimDashboardAttr',     s:p.plum,    '', '')
call s:hi('JvimDashboardSep',      s:p.sep,     '', '')
call s:hi('JvimDashboardSection',  s:p.royal,   '', 'bold')
call s:hi('JvimDashboardAction',   s:p.fg,      '', '')
call s:hi('JvimDashboardHint',     s:p.fg_dim,  '', 'italic')
call s:hi('JvimDashboardStatus',   s:p.plum,    '', '')
call s:hi('JvimDashboardControls', s:p.fg_dim,  '', '')
call s:hi('JvimDashboardFooter',   s:p.fg_dim,  '', 'italic')

call s:hi('JvimStatusMode',        s:p.bg,      s:p.tan,    'bold')
call s:hi('JvimStatusModeI',       s:p.bg,      s:p.plum,   'bold')
call s:hi('JvimStatusModeV',       s:p.bg,      s:p.royal,  'bold')
call s:hi('JvimStatusModeR',       s:p.bg,      s:p.coral,  'bold')
call s:hi('JvimStatusModeC',       s:p.bg,      s:p.peach,  'bold')
call s:hi('JvimStatusModeT',       s:p.bg,      s:p.maroon, 'bold')
call s:hi('JvimStatusBranch',      s:p.fg,      s:p.bg_hi,  '')
call s:hi('JvimStatusFile',        s:p.fg,      '',         '')
call s:hi('JvimStatusFileMod',     s:p.peach,   '',         'bold')
call s:hi('JvimStatusInfo',        s:p.fg_dim,  s:p.bg_hi,  '')
call s:hi('JvimStatusErr',         s:p.coral,   s:p.bg_hi,  '')
call s:hi('JvimStatusWarn',        s:p.peach,   s:p.bg_hi,  '')
call s:hi('JvimStatusHint',        s:p.plum,    s:p.bg_hi,  '')

call s:hi('JvimNotifyError', s:p.coral, s:p.bg_hi, 'bold')
call s:hi('JvimNotifyWarn',  s:p.peach, s:p.bg_hi, 'bold')
call s:hi('JvimNotifyInfo',  s:p.royal, s:p.bg_hi, '')
call s:hi('JvimNotifyHint',  s:p.plum,  s:p.bg_hi, '')
call s:hi('JvimNotifyTitle', s:p.tan,   s:p.bg_hi, 'bold')
call s:hi('JvimNotifyBody',  s:p.fg,    s:p.bg_hi, '')

call s:hi('JvimKeyhelpKey',   s:p.tan,    s:p.bg_hi, 'bold')
call s:hi('JvimKeyhelpDesc',  s:p.fg,     s:p.bg_hi, '')
call s:hi('JvimKeyhelpGroup', s:p.royal,  s:p.bg_hi, 'italic')

call s:hi('JvimIndentGuide',      s:p.sep,     '', '')
call s:hi('JvimIndentGuideActive',s:p.fg_dim,  '', '')

" jvim icon palette
call s:hi('JvimIconRed',     s:p.coral,   '', '')
call s:hi('JvimIconOrange',  s:p.peach,   '', '')
call s:hi('JvimIconYellow',  s:p.tan,     '', '')
call s:hi('JvimIconGreen',   s:p.plum,    '', '')
call s:hi('JvimIconCyan',    s:p.plum,    '', '')
call s:hi('JvimIconBlue',    s:p.royal,   '', '')
call s:hi('JvimIconPurple',  s:p.royal,   '', '')
call s:hi('JvimIconPink',    s:p.maroon,  '', '')
call s:hi('JvimIconGrey',    s:p.fg_dim,  '', '')
call s:hi('JvimIconWhite',   s:p.fg,      '', '')

" jvim tree
call s:hi('JvimTreeRoot',    s:p.tan,     '', 'bold')
call s:hi('JvimTreeDir',     s:p.royal,   '', 'bold')
call s:hi('JvimTreeFile',    s:p.fg,      '', '')
call s:hi('JvimTreeOpened',  s:p.plum,    '', 'bold,italic')

" jvim tabline
call s:hi('JvimTabActive',   s:p.fg,      s:p.bg,     'bold')
call s:hi('JvimTabInactive', s:p.fg_dim,  s:p.bg_hi,  '')
call s:hi('JvimTabSep',      s:p.sep,     s:p.bg_hi,  '')
call s:hi('JvimTabFill',     '',          s:p.bg_hi,  '')
call s:hi('JvimTabModified', s:p.peach,   s:p.bg_hi,  'bold')

" jvim finder
call s:hi('JvimFinderPrompt',    s:p.tan,     s:p.bg_hi, 'bold')
call s:hi('JvimFinderMatch',     s:p.peach,   '',        'bold')
call s:hi('JvimFinderSelection', s:p.fg,      s:p.sel,   'bold')

" jvim diagnostics list
call s:hi('JvimDiagListFile', s:p.tan,    '', 'bold')
call s:hi('JvimDiagListLine', s:p.fg_dim, '', '')

" ── Jenova chat highlight defaults ──────────────────────────────────────────
" Defaults so chat buffers read correctly even before chat.lua's
" apply_chat_highlights() runs the first time.
call s:hi('JenovaChatUserHdr',     s:p.royal,  '', 'bold')
call s:hi('JenovaChatJenovaHdr',   s:p.maroon, '', 'bold')
call s:hi('JenovaChatToolOk',      s:p.plum,   '', 'bold')
call s:hi('JenovaChatToolFail',    s:p.coral,  '', 'bold')
call s:hi('JenovaChatToolName',    s:p.tan,    '', '')
call s:hi('JenovaChatToolPreview', s:p.fg_dim, '', 'italic')
call s:hi('JenovaChatError',       s:p.coral,  '', 'bold')
call s:hi('JenovaChatCost',        s:p.plum,   '', 'italic')
