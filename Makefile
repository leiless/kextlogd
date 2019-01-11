#
# Makefile for kextlogd
#

CC=clang
FRAMEWORKS+=-framework Foundation -framework CoreServices
CPPFLAGS+=-D__TARGET_OS__=\"$(shell uname -m)-apple-darwin_$(shell uname -r)\" \
	-D__TZ__=\"$(shell date +%z)\"
CFLAGS+=-std=c99 -Wall -Wextra -Werror \
	-arch x86_64 -arch i386 \
	$(FRAMEWORKS)
SOURCES=$(wildcard *.m)
EXECUTABLE=kextlogd
RM=rm -rf

all: debug

release: $(SOURCES)
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $(EXECUTABLE)

debug: CPPFLAGS += -g -DDEBUG
debug: release

clean:
	$(RM) *.o *.dSYM $(EXECUTABLE)

.PHONY: all debug release clean

