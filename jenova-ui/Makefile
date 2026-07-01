# Jenova Desktop Manager (jenova-ui) — Makefile
# Supports FreeBSD (cc/clang), Linux (gcc/cc), and macOS (cc/clang).

CC ?= cc
CFLAGS=-Wall -Wextra -std=c99 `pkg-config --cflags gtk+-3.0 appindicator3-0.1 ncurses luajit webkit2gtk-4.1`
LDFLAGS=`pkg-config --libs gtk+-3.0 appindicator3-0.1 ncurses luajit webkit2gtk-4.1` -Wl,-E -lm
TARGET=jenova-ui
SRC=src/main.c src/canvas.c src/chat_bedrock.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)
