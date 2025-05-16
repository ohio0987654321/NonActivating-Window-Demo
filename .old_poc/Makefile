# Makefile
# Build window_modifier as Objective-C (".m") to support Cocoa APIs
CC = clang
CFLAGS = -g -Wall -dynamiclib -fPIC -fobjc-arc
FRAMEWORKS = \
	-framework CoreGraphics \
	-framework CoreFoundation \
	-framework ApplicationServices \
	-framework Carbon \
	-framework Cocoa

# Rename window_modifier.c to window_modifier.m to allow Objective-C
SOURCES = window_modifier.m injection_entry.c
HEADERS = window_modifier.h
OUTPUT = libwindowmodifier.dylib

all: $(OUTPUT)

$(OUTPUT): $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(SOURCES) -o $@

clean:
	rm -f $(OUTPUT)

inject: $(OUTPUT)
	# Example injection command
	DYLD_INSERT_LIBRARIES=./$(OUTPUT) /Applications/SomeApp.app/Contents/MacOS/SomeApp

.PHONY: all clean inject