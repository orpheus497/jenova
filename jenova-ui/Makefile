# Jenova Desktop Manager (jenova-ui) — Makefile
# Supports FreeBSD (cc/clang), Linux (gcc/cc), and macOS (cc/clang).

CC ?= cc
CFLAGS=-Wall -Wextra -std=c99 `pkg-config --cflags gtk+-3.0 appindicator3-0.1 ncurses luajit webkit2gtk-4.1 json-glib-1.0`
LDFLAGS=`pkg-config --libs gtk+-3.0 appindicator3-0.1 ncurses luajit webkit2gtk-4.1 json-glib-1.0` -Wl,-E -lm
TARGET=jenova-ui
TEST_TARGET=test_gtk
SRC=src/main.c src/canvas.c src/chat_bedrock.c src/workspace_explorer.c
TEST_SRC=test_gtk.c

.PHONY: all clean test

all: $(TARGET) $(TEST_TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

$(TEST_TARGET): $(TEST_SRC)
	$(CC) -Wall -Wextra -std=c99 `pkg-config --cflags gtk+-3.0` -o $(TEST_TARGET) $(TEST_SRC) `pkg-config --libs gtk+-3.0` -lm

test: $(TEST_TARGET)
	xvfb-run -a ./$(TEST_TARGET)

clean:
	rm -f $(TARGET) $(TEST_TARGET)
