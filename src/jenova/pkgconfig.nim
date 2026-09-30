## Script function and purpose: pkg-config for the hand-written bindings, with a
## failure that says how to find the missing package on the OS being built on.

import std/[strutils, macros]

## Function purpose: the FreeBSD port, or the Linux distribution's own search for
## the package that ships `<module>.pc`, chosen by which package manager exists.
proc installHint(module, port: string): string {.compileTime.} =
  when defined(freebsd):
    "On FreeBSD it is the " & port & " package"
  else:
    let pc = module & ".pc"
    if gorgeEx("command -v pacman").exitCode == 0:
      "On Arch, `pacman -F " & pc & "` names the package that provides it" &
        " (once `pacman -Fy` has fetched the file lists)"
    elif gorgeEx("command -v dnf").exitCode == 0:
      "On Fedora, `dnf provides 'pkgconfig(" & module & ")'` names the package"
    elif gorgeEx("command -v apt-file").exitCode == 0 or
         gorgeEx("command -v apt-get").exitCode == 0:
      "On Debian, `apt-file search " & pc & "` (from the apt-file package)" &
        " names the package that provides it"
    else:
      "Install the package that provides " & pc

## Function purpose: `gorgeEx` rather than `gorge`, because only it returns the
## exit status; without it pkg-config's diagnostic is spliced into `passL`.
proc pkgQuery*(module, flag, port: string): string {.compileTime.} =
  let (output, code) = gorgeEx("pkg-config " & flag & " " & module)
  if code != 0:
    error("pkg-config cannot find '" & module & "'. " & installHint(module, port) &
          " — see docs/install.md. Reported: " & output.strip)
  output.strip

## Function purpose: both pragmas from one line per binding. `port` is the FreeBSD
## origin `docs/install.md` lists for that package; keep the two in step.
template pkgConfig*(module, port: static string) =
  {.passC: pkgQuery(module, "--cflags", port).}
  {.passL: pkgQuery(module, "--libs", port).}
