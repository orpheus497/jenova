Installing jvim
===============

jvim is currently distributed as a source-only build. Pre-built packages are
not yet available through system package managers. The recommended way to
install jvim is to build from source.

---

- After installing, run `jvim`.
- Before upgrading to a new version, check `runtime/doc/news.txt` for
  breaking changes.

---

Install from source
===================

See [BUILD.md](./BUILD.md) for the full build matrix and platform-specific
instructions. If you have the [prerequisites](./BUILD.md#build-prerequisites)
then building is straightforward:

```bash
git clone https://github.com/orpheus497/jvim
cd jvim
make CMAKE_BUILD_TYPE=RelWithDebInfo
sudo make install
```

This installs jvim to `/usr/local` on Unix-like systems.

### Install to a custom prefix

```bash
rm -rf build/  # clear the CMake cache
make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=$HOME/jvim
make install
export PATH="$HOME/jvim/bin:$PATH"
```

### FreeBSD 15 (primary Jenova target)

```bash
sudo pkg install cmake gmake luajit-openresty git curl wget gettext sha \
  vulkan-loader
git clone https://github.com/orpheus497/jvim
cd jvim
gmake CMAKE_BUILD_TYPE=RelWithDebInfo
sudo gmake install
```

### Debian/Ubuntu DEB package

```bash
git clone https://github.com/orpheus497/jvim
cd jvim
make CMAKE_BUILD_TYPE=RelWithDebInfo
cd build && cpack -G DEB && sudo dpkg -i jvim-linux-*.deb
```

### macOS

```bash
# Install build prerequisites via Homebrew
brew install cmake ninja gettext curl

git clone https://github.com/orpheus497/jvim
cd jvim
make CMAKE_BUILD_TYPE=RelWithDebInfo
sudo make install
```

Uninstall
=========

There is a CMake target to _uninstall_ after `make install`:

```bash
sudo cmake --build build/ --target uninstall
```

Alternatively, just delete the `CMAKE_INSTALL_PREFIX` artifacts:

```bash
sudo rm /usr/local/bin/jvim
sudo rm -r /usr/local/share/jvim/
sudo rm -r /usr/local/lib/jvim/
```

Using with the Jenova Cognitive Architecture
============================================

After installing jvim, set up the full Jenova environment:

```bash
git clone https://github.com/orpheus497/jenova
cd jenova
# Follow the Jenova README for backend setup, then:
jvim [files...]
```

When the Jenova environment variables are set (`JENOVA_ROOT`,
`JENOVA_CONNECT_HOST`, `JENOVA_PORT`, etc.), jvim automatically loads the
Jenova configuration and connects to the cognitive backend.
See [`:help jvim`](./runtime/doc/jvim.txt) for details.
