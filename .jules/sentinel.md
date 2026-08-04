# Sentinel Security Journal

## 2025-05-18 - Fix Command Injection in fs_sync.get_fs_tree
**Vulnerability:** Command Injection. The function `fs_sync.get_fs_tree` concatenated user-supplied variables (`scope_workspace`, `scope_project`, etc.) directly into a string executed by `/bin/sh` via `io.popen` and `os.execute` (e.g. `io.popen('find "' .. search_root .. '" ...')`). Since user input was used inside double quotes, command substitution (`$()`, `` ` ``) or early quote termination (`; #`) could be used for arbitrary code execution.
**Learning:** In Lua scripts serving as backend APIs (like the Jenova CA proxy), `io.popen` and `os.execute` are frequently used but lack automatic argument parameterization. Double quotes are unsafe for passing user data to the shell.
**Prevention:** Always use POSIX single-quote escaping for any dynamically constructed shell argument: replace all occurrences of `'` with `'\''` and enclose the entire string in single quotes (`'`). Additionally, explicitly reject or strip newline characters `[\r\n]` from inputs, because newline-delimited find output can split ambiguous arguments.

## 2024-05-27 - [Command Injection]
**Vulnerability:** Found `os.execute` and `io.popen` calls in `.lua` files that lack proper sanitization for potential shell injection (in commands like `find ...`). Especially `async_popen_read` and `io.popen` where input strings derived from environmental variables, though some `sq()` escaping is present, not all variables are validated properly. However, one specific instance in `lib/ui.lua` appears to use user input or environmental variables un-safely (like `os.getenv("JENOVA_STATE")` or IP lookup commands) without escaping.

Another notable finding: `lib/proxy.lua` uses `async_popen_read` with `find` over user directories. While escaping is present (`gsub("'", "'\\''")`), it doesn't prevent newline injection natively (a problem noted in `lib/fs_sync.lua` where manual newline stripping is performed, but not consistently in `lib/proxy.lua`).
**Prevention:** Implement and use a robust `shell_quote` function that rejects newlines and safely handles POSIX single quotes around arguments passed to shell commands.
