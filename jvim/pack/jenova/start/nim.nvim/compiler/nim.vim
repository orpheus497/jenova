" Vim compiler file
" Compiler: Nim
" Author:   Leorize

if exists("current_compiler")
  finish
endif

let current_compiler = "nim"

if exists(":CompilerSet") != 2
  command -nargs=* CompilerSet setlocal <args>
endif

CompilerSet errorformat=
      \%f(%l\\,\ %c)\ %trror:\ %m,
      \%f(%l\\,\ %c)\ %tarning:\ %m,
      \%A%f(%l\\,\ %c)\ Hint:\ %m,
      \%I%f(%l\\,\ %c)\ %m,
      \%-IHint:\ %m,
      \%-ICC:\ %m
CompilerSet makeprg=nim\ c\ --listFullPaths:on\ $*\ %
