# Jenova Desktop Manager (jenova-ui) — Makefile
# Supports FreeBSD (cc/clang), Linux (gcc/cc), and macOS (cc/clang).

CC ?= cc
CFLAGS=-Wall -Wextra -std=c99 `pkg-config --cflags gtk+-3.0 appindicator3-0.1 ncurses luajit`
LDFLAGS=`pkg-config --libs gtk+-3.0 appindicator3-0.1 ncurses luajit` -Wl,-E
TARGET=jenova-ui
SRC=src/main.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)
