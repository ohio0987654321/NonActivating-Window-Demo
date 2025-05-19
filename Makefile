# Makefile for the window modifier
CC=clang
CFLAGS=-Wall -Wextra -g -fPIC -ObjC -fobjc-arc
LDFLAGS=-dynamiclib -framework Cocoa -framework AppKit -framework CoreFoundation

# Directories
SRC_DIR=src
BUILD_DIR=build
CORE_DIR=$(SRC_DIR)/core
CGS_DIR=$(SRC_DIR)/cgs
TRACKER_DIR=$(SRC_DIR)/tracker
OPS_DIR=$(SRC_DIR)/operations

# Source files
CORE_SRCS=$(wildcard $(CORE_DIR)/*.c)
CGS_SRCS=$(wildcard $(CGS_DIR)/*.m)
TRACKER_SRCS=$(wildcard $(TRACKER_DIR)/*.c) $(wildcard $(TRACKER_DIR)/*.m)
OPS_SRCS=$(wildcard $(OPS_DIR)/*.m) $(wildcard $(OPS_DIR)/*.c)

# Split tracker sources into C and M files
TRACKER_C_SRCS=$(wildcard $(TRACKER_DIR)/*.c)
TRACKER_M_SRCS=$(wildcard $(TRACKER_DIR)/*.m)

# Object files
OBJS=$(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(CORE_SRCS)) \
     $(patsubst $(SRC_DIR)/%.m,$(BUILD_DIR)/%.o,$(CGS_SRCS)) \
     $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(TRACKER_C_SRCS)) \
     $(patsubst $(SRC_DIR)/%.m,$(BUILD_DIR)/%.o,$(TRACKER_M_SRCS)) \
     $(patsubst $(SRC_DIR)/%.m,$(BUILD_DIR)/%.o,$(OPS_SRCS))

# Create build directories
BUILD_DIRS=$(BUILD_DIR) \
          $(BUILD_DIR)/core \
          $(BUILD_DIR)/cgs \
          $(BUILD_DIR)/tracker \
          $(BUILD_DIR)/operations

# Target libraries and executables
DYLIB=$(BUILD_DIR)/libwindowmodifier.dylib
INJECTOR=$(BUILD_DIR)/injector

# Default target
all: $(BUILD_DIRS) $(DYLIB) $(INJECTOR)

# Create build directories
$(BUILD_DIRS):
	@mkdir -p $@

# Build the DYLIB (ensure we only use object files)
$(DYLIB): $(OBJS)
	@echo "Linking $(DYLIB) with object files only"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS)

# Build the injector
$(INJECTOR): $(SRC_DIR)/injector.c
	$(CC) $(CFLAGS) -o $@ $< -framework CoreFoundation

# Compile C files
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c -o $@ $<

# Compile Objective-C files
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.m | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c -o $@ $<

# Clean build files
clean:
	rm -rf $(BUILD_DIR)

# Use the injector to run the modifier on applications
run-discord: all
	$(INJECTOR) /Applications/Discord.app

run-slack: all
	$(INJECTOR) /Applications/Slack.app

run-chrome: all
	$(INJECTOR) "/Applications/Google Chrome.app"

run-safari: all
	$(INJECTOR) /Applications/Safari.app

run-firefox: all
	$(INJECTOR) /Applications/Firefox.app

run-terminal: all
	$(INJECTOR) /System/Applications/Utilities/Terminal.app

# General run target
run: all
	@echo "Usage: make run-app APP=/path/to/application.app"
	@exit 1

run-app: all
	@[ -n "$(APP)" ] || (echo "Error: Please specify APP=/path/to/application.app" && exit 1)
	$(INJECTOR) "$(APP)"

.PHONY: all clean run run-app run-discord run-slack run-chrome run-safari run-firefox run-terminal
