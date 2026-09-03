## Script function and purpose: the program's version, in one place.
##
## It was in three: `jenova_core.nim:24`, `jenova_gui.nim:21` and
## `jenova_core.nimble:3`. Two of those are Nim and can share a constant; the
## third cannot, because a `.nimble` file is read by nimble before anything in
## `src/` is compiled and its `version` field must be a literal. So the rule is:
## **this constant is what the programs report, and the nimble field is bumped
## with it.** Nothing else declares a version.

const
  Version* = "0.1.0"

  ## The copyright line the About window shows. The licence itself is not
  ## declared here: libadwaita's About window takes it as a `License` enum
  ## value, set where that window is configured. `LICENSE` is the AGPL v3 text
  ## and `jenova_core.nimble:6` says `AGPL-3.0-or-later`, so the value there is
  ## `LicenseAGPL3_0`, the "or later" variant — `LicenseAGPL3_0_Only` is the one
  ## that is not.
  Copyright* = "© 2026 orpheus497"

  ## Where the project lives. Used by the About window's Website and Report an
  ## Issue links, which is the only place either is shown.
  HomeUrl* = "https://github.com/orpheus497/jenova"
  IssueUrl* = "https://github.com/orpheus497/jenova/issues"
