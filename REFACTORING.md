# Window Modifier Refactoring

## Overview

The Window Modifier project has been refactored to address several key issues, making it more robust for general macOS applications rather than only supporting specific multi-process applications like Discord and Electron apps. This document outlines the changes made and provides guidelines for future development.

## Key Improvements

### 1. Generic Window Handling

The code now properly handles windows with different ownership patterns:
- Standard application windows
- Windows with special ownership (Owner ID 0)
- Windows from various process types

### 2. Event-Driven Initialization (No More Time-Based Fallbacks)

- Removed the arbitrary time threshold for initializing windows
- Implemented a robust event-based state machine tracking window initialization events
- Properly tracks standard vs. utility windows for informed decisions

### 3. Multiple Modification Methods

Windows are now modified using multiple approaches for maximum compatibility:

- **CGS API**: Primary approach for standard windows
- **NSWindow Approach**: For special windows with Owner ID 0
- **Method Swizzling**: Direct intervention during window creation

### 4. Window Classification System

Improved window classification based on:
- Window properties (size, style, level)
- Process role detection (main, UI, utility)
- Ownership patterns

## Technical Details

### Method Swizzling

Added a new component that swizzles NSWindow's initialization methods to directly modify windows as they're being created, bypassing ownership issues completely. This approach handles special cases where CGS APIs are insufficient.

### NSWindow Modification

Direct AppKit-based window modification is now used when the CGS approach fails, particularly for Owner ID 0 windows:

```objc
window.level = NSFloatingWindowLevel;
window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
[window _setPreventsActivation:YES];
```

### Improved Window Classification

Windows are now properly classified by:
- Size (small windows are treated as utility windows)
- Style masks (panels, sheets, utility windows recognized)
- Event sequence (creation, ordering, resizing, updates)

### Safe Modification Timing

Added safe delayed modification to allow windows to complete construction before attempting modification:

```objc
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    // Window modification code
});
```

## Directory Structure

```
src/
├── core/            # Core data types and entry points
├── cgs/             # Core Graphics Services (CGS) API interfaces
├── operations/      # Main window operations (including new swizzling)
└── tracker/         # Window tracking and registry functionality
```

## Future Development Guidelines

1. **General Application Support**:
   - Avoid Discord or Electron-specific assumptions
   - Use robust detection methods for all window types
   - Maintain compatibility with standard macOS applications

2. **Event-Driven Architecture**:
   - Continue using the event-driven approach for window state tracking
   - Avoid time-based fallbacks whenever possible
   - Use the state machine pattern for tracking initialization

3. **Layered Modification Approach**:
   - Try multiple strategies in sequence (NSWindow → CGS → direct manipulation)
   - Make decisions based on window classification
   - Use retry mechanisms for unstable windows

4. **Testing Methodology**:
   - Test with various application types:
     - Standard single-process macOS apps
     - Multi-process Electron apps
     - System utilities with special window permissions
     - Applications with customized window handling

## Known Limitations

1. Some system windows with special permissions may still resist modification
2. Applications with custom window management might require additional strategies
3. Method swizzling may not work for all application architectures

## Conclusion

This refactoring transforms the window modifier from a Discord/Electron-specific solution into a general-purpose tool for macOS applications. The multi-layered approach using both CGS APIs and AppKit provides maximum compatibility and reliability.
