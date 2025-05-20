# Makefile for the universal window modifier
CC=clang
# Architecture flags for universal binary (x86_64, arm64, arm64e)
ARCH_FLAGS=-arch x86_64 -arch arm64 -arch arm64e
# Added optimization flag -O2 while keeping debug info
CFLAGS=-Wall -Wextra -g -O2 -fPIC -ObjC -fobjc-arc $(ARCH_FLAGS)
LDFLAGS=-dynamiclib -framework Cocoa -framework AppKit -framework CoreFoundation $(ARCH_FLAGS)

# Enable parallel builds
MAKEFLAGS += -j$(shell sysctl -n hw.ncpu)

# Directories
SRC_DIR=src
BUILD_DIR=build

# Create build directories
BUILD_DIRS=$(BUILD_DIR) \
          $(BUILD_DIR)/core \
          $(BUILD_DIR)/cgs \
          $(BUILD_DIR)/tracker \
          $(BUILD_DIR)/operations

# Individual source files
INJECTION_ENTRY_SRC=$(SRC_DIR)/core/injection_entry.c
WINDOW_MODIFIER_CGS_SRC=$(SRC_DIR)/cgs/window_modifier_cgs.m
WINDOW_REGISTRY_SRC=$(SRC_DIR)/tracker/window_registry.c
WINDOW_CLASSIFIER_SRC=$(SRC_DIR)/tracker/window_classifier.m
WINDOW_MODIFIER_SWIZZLE_SRC=$(SRC_DIR)/operations/window_modifier_swizzle.m
WINDOW_MODIFIER_SRC=$(SRC_DIR)/operations/window_modifier.m
INJECTOR_SRC=$(SRC_DIR)/injector.c

# Individual object files
INJECTION_ENTRY_OBJ=$(BUILD_DIR)/core/injection_entry.o
WINDOW_MODIFIER_CGS_OBJ=$(BUILD_DIR)/cgs/window_modifier_cgs.o
WINDOW_REGISTRY_OBJ=$(BUILD_DIR)/tracker/window_registry.o
WINDOW_CLASSIFIER_OBJ=$(BUILD_DIR)/tracker/window_classifier.o
WINDOW_MODIFIER_SWIZZLE_OBJ=$(BUILD_DIR)/operations/window_modifier_swizzle.o
WINDOW_MODIFIER_OBJ=$(BUILD_DIR)/operations/window_modifier.o

# All object files
OBJS= \
    $(INJECTION_ENTRY_OBJ) \
    $(WINDOW_MODIFIER_CGS_OBJ) \
    $(WINDOW_REGISTRY_OBJ) \
    $(WINDOW_CLASSIFIER_OBJ) \
    $(WINDOW_MODIFIER_SWIZZLE_OBJ) \
    $(WINDOW_MODIFIER_OBJ)

# Target libraries and executables
DYLIB=$(BUILD_DIR)/libwindowmodifier.dylib
INJECTOR=$(BUILD_DIR)/injector

# Default target
all: $(BUILD_DIRS) $(DYLIB) $(INJECTOR)

# Create build directories
$(BUILD_DIRS):
	@mkdir -p $@

# Individual compilation rules
$(INJECTION_ENTRY_OBJ): $(INJECTION_ENTRY_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c $< -o $@

$(WINDOW_MODIFIER_CGS_OBJ): $(WINDOW_MODIFIER_CGS_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c $< -o $@

$(WINDOW_REGISTRY_OBJ): $(WINDOW_REGISTRY_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c $< -o $@

$(WINDOW_CLASSIFIER_OBJ): $(WINDOW_CLASSIFIER_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c $< -o $@

$(WINDOW_MODIFIER_SWIZZLE_OBJ): $(WINDOW_MODIFIER_SWIZZLE_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c $< -o $@

$(WINDOW_MODIFIER_OBJ): $(WINDOW_MODIFIER_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -c $< -o $@

# Build the DYLIB
$(DYLIB): $(OBJS)
	@echo "Linking $(DYLIB) with object files only"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS)

# Build the injector
$(INJECTOR): $(INJECTOR_SRC) | $(BUILD_DIRS)
	$(CC) $(CFLAGS) -o $@ $< -framework CoreFoundation

# Clean build files
clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean