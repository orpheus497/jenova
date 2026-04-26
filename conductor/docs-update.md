# Documentation Update Plan

## Objective
Update the documentation to correct inaccuracies and properly acknowledge foundational open-source projects.

## Key Files & Context
- `docs/architecture/agent.md`: Contains the false claim about a C-based sandbox.
- `README.md`: Needs an Acknowledgments section to pay homage to `llama.cpp`, `Neovim`, and other related packages.

## Implementation Steps
1. **Fix Sandbox Documentation**:
   - In `docs/architecture/agent.md`, locate the "Security & Permissions" section.
   - Replace `- **Sandbox**: A C-based layer that validates paths and blocks dangerous shell patterns.` with `- **Sandbox**: A Lua-based layer that validates paths and blocks dangerous shell patterns.`
2. **Add Acknowledgments**:
   - In `README.md`, insert an "Acknowledgments" section right before the "License" section.
   - The section will explicitly credit `llama.cpp` (for the C++ inference engine) and `Neovim` (for the `jvim` editor foundation).

## Verification & Testing
- Use `grep` or `read_file` to confirm that `docs/architecture/agent.md` no longer mentions a "C-based" sandbox.
- Verify that `README.md` contains the new "Acknowledgments" section formatted correctly.