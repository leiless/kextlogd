#
# Makefile for kextlogd
#

CC=clang
CFLAGS=-framework Foundation -framework CoreServices \
	-Wall -Wextra -g -DDEBUG \
	-arch x86_64 -arch i386
SOURCES=$(wildcard *.m)
EXECUTABLE=kextlogd
RM=rm -rf

all: $(EXECUTABLE)

$(EXECUTABLE): $(SOURCES)
	$(CC) $(CFLAGS) $< -o $@

clean:
	$(RM) *.o $(EXECUTABLE) *.dSYM

.PHONY: all clean

