# Hardware Profiles

> **This document has moved.** The canonical reference for Jenova hardware
> profiles is maintained alongside the profiles themselves.
>
> **See: [hardware-profiles/README.md](../../hardware-profiles/README.md)**

That document covers:

- All available profiles with settings and model details
- Profile directory structure and detection scoring
- Manual profile selection and environment overrides
- How to create new profiles

## Quick Reference

```sh
# Show hardware detection report
./hardware-profiles/detect-hardware.sh --info

# Apply recommended profile
./hardware-profiles/detect-hardware.sh --apply

# Apply a specific profile
./hardware-profiles/detect-hardware.sh --apply-profile Linux/Vulkan/dgpu/gtx-1650ti

# List all profiles
./hardware-profiles/detect-hardware.sh --list
```

## Manual Overrides

Key variables in `etc/jenova.conf` (all overridable via environment):

| Variable | Description | Example |
|----------|-------------|---------|
| `JENOVA_DEVICES` | Compute devices | `Vulkan0,Vulkan1` |
| `JENOVA_NGL` | GPU layers (`all` or count) | `all` |
| `JENOVA_CTX` | Context window size | `16384` |
| `JENOVA_DRAFT` | Speculative decoding | `1` (enabled) |
| `JENOVA_MODEL` | Override agent model path | `/path/to/model.gguf` |
