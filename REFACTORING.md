# Window Modifier Refactoring Documentation

## Overview

This document details the refactoring work performed to transform the Window Modifier project from a Discord-specific tool to a universal macOS application window modifier. The refactoring focused on removing application-specific code, generalizing detection algorithms, and streamlining the codebase.

## Completed Refactoring Tasks

### 1. Directory Structure Reorganization

- Created a logical modular structure:
  - `src/core/`: Core functionality and types
  - `src/operations/`: Window modification operations
  - `src/tracker/`: Window tracking and classification
  - `src/cgs/`: Core Graphics Services wrappers

- Removed duplicated files in the root directory:
  - Moved `src/injection_entry.c` → `src/core/injection_entry.c`
  - Moved `src/window_modifier.m` → `src/operations/window_modifier.m`
  - Moved `src/window_registry.c|h` → `src/tracker/window_registry.c|h`

### 2. Removal of Discord-specific Code

- Generalized process detection logic in `src/injector.c` to work with any macOS application
- Replaced hard-coded Discord window checks with generalized window classification
- Removed Discord-specific handling in the window modification logic
- Implemented generic process role detection based on common macOS application patterns

### 3. Code Cleanup and Simplification

- Removed unused callback functionality from window_classifier
- Consolidated type definitions in `window_modifier_types.h`
- Improved error handling for better compatibility with various application types
- Added the window_registry_t opaque type definition to window_modifier_types.h

### 4. Enhanced Compatibility

- Added support for screen recording bypass with improved detection
- Improved NSWindow modification approach for better compatibility
- Added more robust retry mechanisms for window modification
- Enhanced initialization state detection for all macOS application types

## Future Enhancements

1. **Further Code Cleanup**
   - Continue simplifying the window classification system
   - Remove any remaining unused functions or parameters
   - Consolidate duplicate functionality

2. **Performance Improvements**
   - Optimize window detection algorithms
   - Reduce memory usage in the window registry system
   - Implement more efficient CGS function caching

3. **Additional Features**
   - Window transparency control
   - Enhanced virtual desktop integration
   - Per-application configuration profiles
   - User interface for controlling window behavior

4. **Testing Expansion**
   - Test with wider range of macOS applications
   - Create test suite for different window scenarios
   - Add single-window injection option

## Project Status

The project is now a universal window modifier capable of working with any macOS application rather than being limited to Discord or other Electron apps. The core functionality includes:

1. **Universal compatibility**: Works with standard macOS apps, Electron apps, and multi-process applications
2. **Always-on-top windows**: Sets windows to float above other applications
3. **Focus preservation**: Prevents windows from stealing focus when clicked
4. **Screen recording bypass**: Enhances privacy by preventing windows from appearing in screen recordings
5. **Mission Control integration**: Works properly with macOS window management features

All the application-specific code has been removed, and the project now detects and adapts to different application architectures automatically.
