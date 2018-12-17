#
# Makefile for kextlogd
#

CC=clang
CFLAGS=-framework Foundation -Wall -Wextra -DDEBUG
SOURCES=$(wildcard *.m)
EXECUTABLE=kextlogd
RM=rm -f

all: $(EXECUTABLE)

$(EXECUTABLE): $(SOURCES)
	$(CC) $(CFLAGS) $< -o $@

clean:
	$(RM) *.o $(EXECUTABLE)

.PHONY: all clean

