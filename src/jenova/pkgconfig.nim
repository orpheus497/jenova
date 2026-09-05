## Script function and purpose: pkg-config for the three hand-written bindings,
## with a failure that names the package and the port that provides it.

import std/[strutils, macros]

## Function purpose: `gorgeEx` rather than `gorge`, because only the former
## returns the exit status. Without it pkg-config's diagnostic becomes the
## argument list: "Package dbus-1 was not found" is spliced into `passL` and the
## build ends in sixty lines of `gcc: error: the: linker input file not found`,
## naming no missing dependency anywhere.
proc pkgQuery*(module, flag, port: string): string {.compileTime.} =
  let (output, code) = gorgeEx("pkg-config " & flag & " " & module)
  if code != 0:
    error("pkg-config cannot find '" & module & "'. On FreeBSD it is the " &
          port & " package — see docs/install.md. Reported: " & output.strip)
  output.strip

## Function purpose: one line per binding, because the two pragmas always go
## together and the port has to be stated once rather than twice. `port` is the
## FreeBSD origin `docs/install.md` lists for that package; keep the two in step.
template pkgConfig*(module, port: static string) =
  {.passC: pkgQuery(module, "--cflags", port).}
  {.passL: pkgQuery(module, "--libs", port).}
