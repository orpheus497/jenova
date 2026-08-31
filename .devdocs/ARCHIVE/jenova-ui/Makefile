# Jenova Desktop Manager (jenova-ui) — Makefile
# FreeBSD only. Builds with the base system make(1). No GNU make required.

CC?= cc

# NOT `CFLAGS?=`. The base system make predefines CFLAGS (to -O2 -pipe), so a
# ?= assignment is silently discarded and -std=gnu99 would be lost — which
# matters, because src/main.c relies on gnu99 exposing POSIX declarations.
# Keep the user's CFLAGS and append ours.
JENOVA_CFLAGS= -Wall -Wextra -std=gnu99

TARGET= jenova-ui
SRC= src/main.c

.PHONY: all clean

all: ${TARGET}

# All library discovery happens in the shell, at recipe time. Nothing is
# evaluated while make parses this file, so `make clean` works on a machine
# with no libraries installed, and there are no make-level conditionals or
# shell-assignments to keep portable.
#
# FreeBSD ships two application-indicator libraries under different pkg-config
# names and header paths; build against whichever is present.
${TARGET}: ${SRC}
	@set -e; \
	if pkg-config --exists appindicator3-0.1 2>/dev/null; then \
		ind=appindicator3-0.1; def=; \
	elif pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null; then \
		ind=ayatana-appindicator3-0.1; def=-DJENOVA_AYATANA_APPINDICATOR; \
	else \
		echo "Error: no application-indicator library found." >&2; \
		echo "  pkg install libappindicator" >&2; \
		echo "  or: pkg install ayatana-appindicator" >&2; \
		exit 1; \
	fi; \
	pkgs="gtk+-3.0 $$ind ncurses luajit"; \
	set -x; \
	${CC} ${CFLAGS} ${JENOVA_CFLAGS} $$def `pkg-config --cflags $$pkgs` \
		-o ${TARGET} ${SRC} \
		`pkg-config --libs $$pkgs` -Wl,-E

clean:
	rm -f ${TARGET}
