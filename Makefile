# Target and directory definitions
BUILD_DIR = build
DYLIB = $(BUILD_DIR)/libwindowmodifier.dylib
INJECTOR = $(BUILD_DIR)/injector

# Compiler and Configuration
CC = clang
CFLAGS_DYLIB = -g -Wall -dynamiclib -fPIC -fobjc-arc
CFLAGS_EXE = -g -Wall
FRAMEWORKS_DYLIB = -framework CoreGraphics -framework CoreFoundation \
                   -framework ApplicationServices -framework Carbon -framework Cocoa
FRAMEWORKS_EXE = -framework CoreFoundation
LIBS = -lpthread

# Source files
DYLIB_SOURCES = src/window_modifier.m src/injection_entry.c src/window_registry.c
INJECTOR_SOURCES = src/injector.c

all: $(BUILD_DIR) $(DYLIB) $(INJECTOR)

$(BUILD_DIR):
	mkdir -p $@

$(DYLIB): $(DYLIB_SOURCES) | $(BUILD_DIR)
	$(CC) $(CFLAGS_DYLIB) $(FRAMEWORKS_DYLIB) $(LIBS) $(DYLIB_SOURCES) -o $@

$(INJECTOR): $(INJECTOR_SOURCES) | $(BUILD_DIR)
	$(CC) $(CFLAGS_EXE) $(FRAMEWORKS_EXE) $(LIBS) $(INJECTOR_SOURCES) -o $@

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean


