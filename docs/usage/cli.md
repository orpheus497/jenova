# Headless & CLI Usage

While the canonical interactive experience is `jvim`, Jenova also supports
headless and scripted workflows for servers, CI, and LAN setups.

## Backend Supervisor — `bin/jenova-ca`

Manages the three backend daemons (llama-server, intelligence proxy,
embedding server) as a single unit.

```sh
bin/jenova-ca --daemon          # start all three daemons in the background
bin/jenova-ca --daemon --lan    # bind to 0.0.0.0 instead of 127.0.0.1
bin/jenova-ca --daemon --watch  # daemon + health watchdog with auto-restart
bin/jenova-ca status            # show PID + alive/dead per service
bin/jenova-ca stop              # stop everything and clean up PID files
bin/jenova-ca restart           # stop + start
```

PIDs and lock files live under `$JENOVA_HOME/.system/`, logs under
`$JENOVA_HOME/var/log/`.

## Top-level launcher — `bin/jenova`

```sh
jenova [files...]      # start backend (if not running) and open jvim
jenova --no-backend    # just open jvim, assume backend is already up
jenova --daemon-only   # start jenova-ca and exit
jenova --check         # print resolved JENOVA_* environment and exit
```

## Jenova Manager (Operational TUI) — `bin/jenova-tui`

The Jenova Manager is the primary operational interface for controlling the
backend and launching applications. It is what the `jenova.desktop` entry
connects to.

```sh
bin/jenova-tui
```

Features:
- **Status Monitoring**: Real-time display of backend (active/inactive) and
  network mode (LAN/LOCAL).
- **Backend Lifecycle**: Start, Stop, and Restart the `jenova-ca` suite.
- **Network Toggle**: Switch between LOCAL (127.0.0.1) and LAN (0.0.0.0)
  access with one command (updates `etc/jenova.local.conf`).
- **Quick Launch**: One-key shortcuts to launch the `jvim` editor and the
  Web UI.

## Maintenance Manager — `scripts/jenova-manager.sh`

A `dialog` / `whiptail`-based menu for installation and maintenance tasks.
Use this for building, updating, or uninstalling components.

```sh
scripts/jenova-manager.sh
```

## Hardware Tooling

```sh
./hardware-profiles/detect-hardware.sh --info     # report only
./hardware-profiles/detect-hardware.sh --apply    # write etc/jenova.conf
sudo scripts/jenova-setup                         # sysctls + swap + ZFS ARC
sudo bin/jenova-swap-mount <size>                 # swap-backed model store
```

## OpenAI-Compatible API

The intelligence proxy (port `8080`) exposes:

- `POST /v1/chat/completions`
- `POST /v1/completions`
- `GET  /v1/models`
- `GET  /v1/health`

Example:

```sh
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "jenova",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

Any OpenAI-compatible client library works — point its `base_url` at
`http://<host>:8080/v1` and use any non-empty `api_key`.

## Modern C Shell — `bin/mcsh`

The bundled shell is built from the in-tree `mcsh/` source by `make mcsh`
(or `cd mcsh && ./configure && make` for a standalone build). It is a
drop-in replacement for `tcsh`/`csh`:

- reads `~/.mcshrc` first, then falls back to `~/.tcshrc` / `~/.cshrc`
- `man mcsh` is canonical; `man tcsh` is a symlink to the same page
- both `$mcsh` and `$tcsh` are populated, so legacy `if ($?tcsh)` guards
  keep firing

See `mcsh/README.md` for the full feature matrix.
