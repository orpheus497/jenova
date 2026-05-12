CC=gcc
CFLAGS=-Wall -Wextra -std=c99 `pkg-config --cflags gtk+-3.0 appindicator3-0.1 ncurses`
LDFLAGS=`pkg-config --libs gtk+-3.0 appindicator3-0.1 ncurses`
TARGET=jenova-ui
SRC=src/main.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)
