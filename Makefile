#
# Makefile for kextlogd
#

CC=clang
FRAMEWORKS+=-framework Foundation -framework CoreServices -framework IOKit
CPPFLAGS+=-D__TARGET_OS__=\"$(shell uname -m)-apple-darwin_$(shell uname -r)\" \
	-D__TS__=\"$(shell date +'%Y/%m/%d\ %H:%M:%S%z')\"
CFLAGS+=-std=c99 -Wall -Wextra -Werror \
	-arch x86_64 -arch i386 \
	-mmacosx-version-min=10.4 \
	$(FRAMEWORKS)
SOURCES=$(wildcard *.m)
EXECUTABLE=kextlogd
RM=rm

all: debug

release: CFLAGS += -Os
release: $(SOURCES)
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $(EXECUTABLE)

debug: CPPFLAGS += -g -DDEBUG
debug: CFLAGS += -O0
debug: $(SOURCES)
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $(EXECUTABLE)

clean:
	$(RM) -rf *.o *.dSYM $(EXECUTABLE)

.PHONY: all debug release clean

