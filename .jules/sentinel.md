# Sentinel Security Journal

## 2025-05-18 - Fix Command Injection in fs_sync.get_fs_tree
**Vulnerability:** Command Injection. The function `fs_sync.get_fs_tree` concatenated user-supplied variables (`scope_workspace`, `scope_project`, etc.) directly into a string executed by `/bin/sh` via `io.popen` and `os.execute` (e.g. `io.popen('find "' .. search_root .. '" ...')`). Since user input was used inside double quotes, command substitution (`$()`, `` ` ``) or early quote termination (`; #`) could be used for arbitrary code execution.
**Learning:** In Lua scripts serving as backend APIs (like the Jenova CA proxy), `io.popen` and `os.execute` are frequently used but lack automatic argument parameterization. Double quotes are unsafe for passing user data to the shell.
**Prevention:** Always use POSIX single-quote escaping for any dynamically constructed shell argument: replace all occurrences of `'` with `'\''` and enclose the entire string in single quotes (`'`). Additionally, explicitly reject or strip newline characters `[\r\n]` from inputs, because newline-delimited find output can split ambiguous arguments.
