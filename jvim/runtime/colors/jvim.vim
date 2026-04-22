" jvim native colorscheme — Kanagawa Dragon-inspired dark palette.
" Drop-in replacement for the kanagawa.nvim plugin so jvim ships with
" its own first-party scheme and has no third-party theme dependency.
"
" Palette (hex):
"   bg     #181616   bg_dim    #12120F   bg_hi   #2D2C29
"   fg     #C5C9C5   fg_dim    #8a8980   sel     #2D4F67
"   red    #C4746E   green     #8A9A7B   yellow  #C4B28A
"   blue   #8BA4B0   magenta   #A292A3   cyan    #8EA4A2   orange  #B6927B
"   error  #E46876   warn      #FF9E3B   info    #7FB4CA   hint    #7AA89F

hi clear
if exists("syntax_on")
  syntax reset
endif
let g:colors_name = "jvim"
set background=dark

let s:p = {
\ 'bg':       '#181616', 'bg_dim': '#12120F', 'bg_hi':   '#2D2C29',
\ 'fg':       '#C5C9C5', 'fg_dim': '#8A8980', 'sel':     '#2D4F67',
\ 'red':      '#C4746E', 'green':  '#8A9A7B', 'yellow':  '#C4B28A',
\ 'blue':     '#8BA4B0', 'magenta':'#A292A3', 'cyan':    '#8EA4A2',
\ 'orange':   '#B6927B', 'error':  '#E46876', 'warn':    '#FF9E3B',
\ 'info':     '#7FB4CA', 'hint':   '#7AA89F', 'sep':     '#393836',
\ }

function! s:hi(group, fg, bg, attr) abort
  let l:cmd = 'hi ' . a:group
  if !empty(a:fg) | let l:cmd .= ' guifg=' . a:fg | endif
  if !empty(a:bg) | let l:cmd .= ' guibg=' . a:bg | endif
  if !empty(a:attr) | let l:cmd .= ' gui=' . a:attr . ' cterm=' . a:attr | endif
  execute l:cmd
endfunction

call s:hi('Normal',       s:p.fg,     s:p.bg,    '')
call s:hi('NormalNC',     s:p.fg_dim, s:p.bg,    '')
call s:hi('NormalFloat',  s:p.fg,     s:p.bg_hi, '')
call s:hi('FloatBorder',  s:p.sep,    s:p.bg_hi, '')
call s:hi('FloatTitle',   s:p.yellow, s:p.bg_hi, 'bold')
call s:hi('SignColumn',   '',         s:p.bg,    '')
call s:hi('LineNr',       s:p.fg_dim, s:p.bg,    '')
call s:hi('CursorLineNr', s:p.yellow, s:p.bg,    'bold')
call s:hi('CursorLine',   '',         s:p.bg_hi, '')
call s:hi('CursorColumn', '',         s:p.bg_hi, '')
call s:hi('ColorColumn',  '',         s:p.bg_hi, '')
call s:hi('VertSplit',    s:p.sep,    '',        '')
call s:hi('WinSeparator', s:p.sep,    '',        '')
call s:hi('StatusLine',   s:p.fg,     s:p.bg_dim,'')
call s:hi('StatusLineNC', s:p.fg_dim, s:p.bg_dim,'')
call s:hi('TabLine',      s:p.fg_dim, s:p.bg_dim,'')
call s:hi('TabLineFill',  '',         s:p.bg_dim,'')
call s:hi('TabLineSel',   s:p.fg,     s:p.bg,    'bold')
call s:hi('Pmenu',        s:p.fg,     s:p.bg_hi, '')
call s:hi('PmenuSel',     s:p.bg,     s:p.yellow,'bold')
call s:hi('PmenuSbar',    '',         s:p.sep,   '')
call s:hi('PmenuThumb',   '',         s:p.fg_dim,'')
call s:hi('Visual',       '',         s:p.sel,   '')
call s:hi('Search',       s:p.bg,     s:p.yellow,'')
call s:hi('IncSearch',    s:p.bg,     s:p.orange,'bold')
call s:hi('MatchParen',   s:p.yellow, s:p.bg_hi, 'bold')
call s:hi('NonText',      s:p.sep,    '',        '')
call s:hi('Whitespace',   s:p.sep,    '',        '')
call s:hi('SpecialKey',   s:p.sep,    '',        '')
call s:hi('Folded',       s:p.fg_dim, s:p.bg_hi, 'italic')
call s:hi('FoldColumn',   s:p.fg_dim, s:p.bg,    '')
call s:hi('Conceal',      s:p.fg_dim, s:p.bg,    '')
call s:hi('Directory',    s:p.blue,   '',        'bold')
call s:hi('Title',        s:p.yellow, '',        'bold')
call s:hi('Question',     s:p.green,  '',        '')
call s:hi('ErrorMsg',     s:p.error,  '',        'bold')
call s:hi('WarningMsg',   s:p.warn,   '',        '')
call s:hi('ModeMsg',      s:p.fg,     '',        'bold')
call s:hi('MoreMsg',      s:p.green,  '',        '')

" Syntax (linked groups carry through to most language plugins)
call s:hi('Comment',      s:p.fg_dim, '',        'italic')
call s:hi('Constant',     s:p.orange, '',        '')
call s:hi('String',       s:p.green,  '',        '')
call s:hi('Character',    s:p.green,  '',        '')
call s:hi('Number',       s:p.orange, '',        '')
call s:hi('Boolean',      s:p.orange, '',        '')
call s:hi('Float',        s:p.orange, '',        '')
call s:hi('Identifier',   s:p.fg,     '',        '')
call s:hi('Function',     s:p.blue,   '',        '')
call s:hi('Statement',    s:p.magenta,'',        'italic')
call s:hi('Conditional',  s:p.magenta,'',        'italic')
call s:hi('Repeat',       s:p.magenta,'',        'italic')
call s:hi('Label',        s:p.magenta,'',        '')
call s:hi('Operator',     s:p.cyan,   '',        '')
call s:hi('Keyword',      s:p.magenta,'',        'italic')
call s:hi('Exception',    s:p.red,    '',        'italic')
call s:hi('PreProc',      s:p.cyan,   '',        '')
call s:hi('Include',      s:p.magenta,'',        '')
call s:hi('Define',       s:p.magenta,'',        '')
call s:hi('Macro',        s:p.cyan,   '',        '')
call s:hi('Type',         s:p.yellow, '',        '')
call s:hi('StorageClass', s:p.magenta,'',        '')
call s:hi('Structure',    s:p.yellow, '',        '')
call s:hi('Typedef',      s:p.yellow, '',        '')
call s:hi('Special',      s:p.cyan,   '',        '')
call s:hi('SpecialChar',  s:p.cyan,   '',        '')
call s:hi('Tag',          s:p.blue,   '',        '')
call s:hi('Delimiter',    s:p.fg,     '',        '')
call s:hi('SpecialComment', s:p.cyan, '',        'italic')
call s:hi('Underlined',   s:p.blue,   '',        'underline')
call s:hi('Error',        s:p.error,  '',        'bold')
call s:hi('Todo',         s:p.yellow, s:p.bg_hi, 'bold')

" Diagnostics
call s:hi('DiagnosticError', s:p.error, '', '')
call s:hi('DiagnosticWarn',  s:p.warn,  '', '')
call s:hi('DiagnosticInfo',  s:p.info,  '', '')
call s:hi('DiagnosticHint',  s:p.hint,  '', '')
call s:hi('DiagnosticOk',    s:p.green, '', '')
call s:hi('DiagnosticUnderlineError', '', '', 'undercurl')
call s:hi('DiagnosticUnderlineWarn',  '', '', 'undercurl')
call s:hi('DiagnosticUnderlineInfo',  '', '', 'undercurl')
call s:hi('DiagnosticUnderlineHint',  '', '', 'undercurl')

" Diff
call s:hi('DiffAdd',    s:p.green,  s:p.bg_hi, '')
call s:hi('DiffChange', s:p.yellow, s:p.bg_hi, '')
call s:hi('DiffDelete', s:p.red,    s:p.bg_hi, '')
call s:hi('DiffText',   s:p.orange, s:p.bg_hi, 'bold')

" Git signs (jvim.git_signs / gitsigns shim names)
call s:hi('GitSignsAdd',    s:p.green,  '', '')
call s:hi('GitSignsChange', s:p.yellow, '', '')
call s:hi('GitSignsDelete', s:p.red,    '', '')

" Spell
call s:hi('SpellBad',   s:p.error, '', 'undercurl')
call s:hi('SpellCap',   s:p.warn,  '', 'undercurl')
call s:hi('SpellLocal', s:p.info,  '', 'undercurl')
call s:hi('SpellRare',  s:p.hint,  '', 'undercurl')

" LSP semantic / treesitter common groups (linked, not duplicated)
hi! link @comment Comment
hi! link @keyword Keyword
hi! link @function Function
hi! link @function.call Function
hi! link @function.builtin Function
hi! link @method Function
hi! link @variable Identifier
hi! link @variable.parameter Identifier
hi! link @variable.member Identifier
hi! link @field Identifier
hi! link @property Identifier
hi! link @type Type
hi! link @type.builtin Type
hi! link @constant Constant
hi! link @constant.builtin Constant
hi! link @string String
hi! link @number Number
hi! link @boolean Boolean
hi! link @operator Operator
hi! link @punctuation Delimiter
hi! link @punctuation.bracket Delimiter
hi! link @punctuation.delimiter Delimiter
hi! link @tag Tag

" jvim dashboard / ui / notify highlight groups
call s:hi('JvimDashboardHeader',   s:p.yellow,  '', 'bold')
call s:hi('JvimDashboardJvim',     s:p.green,   '', 'bold')
call s:hi('JvimDashboardTitle',    s:p.green,   '', 'bold')
call s:hi('JvimDashboardSubtitle', s:p.fg_dim,  '', 'italic')
call s:hi('JvimDashboardAttr',     s:p.blue,    '', '')
call s:hi('JvimDashboardSep',      s:p.sep,     '', '')
call s:hi('JvimDashboardSection',  s:p.magenta, '', 'bold')
call s:hi('JvimDashboardAction',   s:p.fg,      '', '')
call s:hi('JvimDashboardHint',     s:p.fg_dim,  '', 'italic')
call s:hi('JvimDashboardStatus',   s:p.cyan,    '', '')
call s:hi('JvimDashboardControls', s:p.fg_dim,  '', '')
call s:hi('JvimDashboardFooter',   s:p.fg_dim,  '', 'italic')

call s:hi('JvimStatusMode',        s:p.bg,      s:p.yellow, 'bold')
call s:hi('JvimStatusModeI',       s:p.bg,      s:p.green,  'bold')
call s:hi('JvimStatusModeV',       s:p.bg,      s:p.magenta,'bold')
call s:hi('JvimStatusModeR',       s:p.bg,      s:p.red,    'bold')
call s:hi('JvimStatusModeC',       s:p.bg,      s:p.orange, 'bold')
call s:hi('JvimStatusModeT',       s:p.bg,      s:p.cyan,   'bold')
call s:hi('JvimStatusBranch',      s:p.fg,      s:p.bg_dim, '')
call s:hi('JvimStatusFile',        s:p.fg,      '',         '')
call s:hi('JvimStatusFileMod',     s:p.warn,    '',         'bold')
call s:hi('JvimStatusInfo',        s:p.fg_dim,  s:p.bg_dim, '')
call s:hi('JvimStatusErr',         s:p.error,   s:p.bg_dim, '')
call s:hi('JvimStatusWarn',        s:p.warn,    s:p.bg_dim, '')
call s:hi('JvimStatusHint',        s:p.hint,    s:p.bg_dim, '')

call s:hi('JvimNotifyError', s:p.error, s:p.bg_hi, 'bold')
call s:hi('JvimNotifyWarn',  s:p.warn,  s:p.bg_hi, 'bold')
call s:hi('JvimNotifyInfo',  s:p.info,  s:p.bg_hi, '')
call s:hi('JvimNotifyHint',  s:p.hint,  s:p.bg_hi, '')
call s:hi('JvimNotifyTitle', s:p.yellow,s:p.bg_hi, 'bold')
call s:hi('JvimNotifyBody',  s:p.fg,    s:p.bg_hi, '')

call s:hi('JvimKeyhelpKey',   s:p.yellow, s:p.bg_hi, 'bold')
call s:hi('JvimKeyhelpDesc',  s:p.fg,     s:p.bg_hi, '')
call s:hi('JvimKeyhelpGroup', s:p.magenta,s:p.bg_hi, 'italic')

call s:hi('JvimIndentGuide',      s:p.sep,     '', '')
call s:hi('JvimIndentGuideActive',s:p.fg_dim,  '', '')

" jvim icon palette (linked from runtime/lua/jvim/icons.lua)
call s:hi('JvimIconRed',     s:p.red,     '', '')
call s:hi('JvimIconOrange',  s:p.orange,  '', '')
call s:hi('JvimIconYellow',  s:p.yellow,  '', '')
call s:hi('JvimIconGreen',   s:p.green,   '', '')
call s:hi('JvimIconCyan',    s:p.cyan,    '', '')
call s:hi('JvimIconBlue',    s:p.blue,    '', '')
call s:hi('JvimIconPurple',  s:p.magenta, '', '')
call s:hi('JvimIconPink',    s:p.magenta, '', '')
call s:hi('JvimIconGrey',    s:p.fg_dim,  '', '')
call s:hi('JvimIconWhite',   s:p.fg,      '', '')

" jvim tree
call s:hi('JvimTreeRoot',    s:p.yellow,  '', 'bold')
call s:hi('JvimTreeDir',     s:p.blue,    '', 'bold')
call s:hi('JvimTreeFile',    s:p.fg,      '', '')
call s:hi('JvimTreeOpened',  s:p.green,   '', 'bold,italic')

" jvim tabline
call s:hi('JvimTabActive',   s:p.fg,      s:p.bg,     'bold')
call s:hi('JvimTabInactive', s:p.fg_dim,  s:p.bg_dim, '')
call s:hi('JvimTabSep',      s:p.sep,     s:p.bg_dim, '')
call s:hi('JvimTabFill',     '',          s:p.bg_dim, '')
call s:hi('JvimTabModified', s:p.warn,    s:p.bg_dim, 'bold')

" jvim finder
call s:hi('JvimFinderPrompt',    s:p.yellow,  s:p.bg_hi, 'bold')
call s:hi('JvimFinderMatch',     s:p.cyan,    '',        'bold')
call s:hi('JvimFinderSelection', s:p.fg,      s:p.sel,   'bold')

" jvim diagnostics list
call s:hi('JvimDiagListFile', s:p.yellow, '', 'bold')
call s:hi('JvimDiagListLine', s:p.fg_dim, '', '')
