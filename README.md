# Universal Window Modifier for macOS Applications

## Overview

This project creates a window modifier library that can be injected into any macOS application. It enables windows to:

1. Stay on top of other applications (always-on-top)
2. Not steal focus when clicked on (accessory window mode)
3. Bypass screen recording detection (privacy enhancement)
4. Properly integrate with Mission Control and virtual desktops
5. Work universally across all application architectures (standard macOS apps, single-process, multi-process, and Electron-based applications)

The project has been refactored to work with all macOS applications, regardless of their architecture or design pattern, eliminating any dependencies on specific frameworks or application structures.

## Key Features

- **Universal binary support**: Fully compatible with Apple Silicon (arm64, arm64e) and Intel (x86_64) processors
- **Universal application support**: Works with standard macOS applications, Electron apps, and complex multi-process applications
- **Process role detection**: Automatically detects main, renderer, utility, and service processes
- **Cross-process registry system**: Maintains a shared registry across all processes to avoid duplicate window modifications
- **Startup protection**: Prevents interference with critical initialization processes
- **Window classification**: Intelligently detects utility windows vs. user interface windows
- **Screen recording bypass**: Prevents windows from being captured in screen recordings
- **Error resilience**: Enhanced error handling and recovery mechanisms
- **Focus preservation**: Better focus management to maintain the current app's activation state
- **Mission Control integration**: Windows properly appear in Mission Control and Exposé
- **Virtual desktop support**: Windows can appear on all spaces or respect virtual desktop boundaries
- **Retry mechanism**: Automatically retries failed window modifications with exponential backoff

## Recent Refactoring Improvements

The codebase has been refactored with the following enhancements:

1. **Centralized Type System**: All shared types are now defined in `common_types.h` to eliminate duplication and improve consistency
2. **Enhanced Architecture Support**: Better CPU architecture detection for native performance on all Mac systems
3. **Improved Error Handling**: Added comprehensive error reporting and recovery mechanisms
4. **Better Code Organization**: Restructured code with logical sections and proper forward declarations
5. **Centralized Constants**: Common constants and flags moved to shared header files

For a detailed list of changes, see [REFACTORING.md](REFACTORING.md)

## Building

```
make clean && make
```

This will create:
- `build/libwindowmodifier.dylib` - The injectable library (Universal binary for x86_64/arm64/arm64e)
- `build/injector` - A standalone injector executable (Universal binary for x86_64/arm64/arm64e)

## Usage

### Basic Usage

```
./build/injector /Applications/TargetApp.app
```

Or for more direct control:

```
./build/injector /Applications/TargetApp.app/Contents/MacOS/TargetApp
```

### Debug Mode

```
./build/injector /Applications/TargetApp.app --debug
```

### Manual Injection (Alternative)

You can also manually inject using the DYLD_INSERT_LIBRARIES environment variable:

```
DYLD_INSERT_LIBRARIES=./build/libwindowmodifier.dylib DYLD_FORCE_FLAT_NAMESPACE=1 /Applications/TargetApp.app/Contents/MacOS/TargetApp
```

## Supported Architectures

The window modifier now builds as a true universal binary with support for:

- **Intel x86_64**: All Intel Macs
- **Apple Silicon arm64**: Base M1/M2 systems
- **Apple Silicon arm64e**: M1 Pro, M1 Max, M1 Ultra, M2 Pro, M2 Max, etc.

The architecture detection is automatic and ensures optimal compatibility across all Mac systems.

## Supported Applications

The refactored design works with virtually all macOS applications:

### Standard macOS Applications
- Safari, Mail, Notes, and other native apps
- Professional applications like XCode, Final Cut Pro, Logic Pro

### Electron-based Applications
- Discord
- Slack
- Visual Studio Code
- Microsoft Teams

### Chromium-based Browsers
- Google Chrome
- Microsoft Edge
- Brave Browser

### Mozilla Applications
- Firefox

### Qt and Cross-platform Applications
- VLC
- Audacity
- GIMP

## How it Works

The library uses a layered approach to maximize compatibility:

1. **DYLIB injection** - Loads into all target application processes
2. **AppKit integration** - Works with standard macOS window system
3. **Method swizzling** - Intercepts window creation and updating methods
4. **Core Graphics Services (CGS)** - Uses private Apple APIs for window modification
5. **Inter-process registry** - Coordinates window management using a shared memory-mapped file
6. **Automatic Process Detection** - Adapts behavior based on process type

## Technical Implementation

1. **Process Classification**:
   - Main processes: Host the application's primary logic
   - UI processes: Render interface elements (Electron renderers, etc.)
   - Utility processes: Background services and helpers
   - Network processes: Handle communication tasks

2. **Window Modification Strategy**:
   - Each window undergoes safety checks before modification
   - Modifications include setting non-activating flags, window levels, and screen sharing state
   - Changes are tracked in a shared registry to prevent duplication

3. **Window Detection Techniques**:
   - Method swizzling for AppKit window events
   - CGS window notifications for system-level events
   - Periodic scanning for windows created through other means
   - Combined approach ensures maximum window coverage

4. **Retry System**:
   - Failed modifications are added to a retry queue
   - Exponential backoff for retry attempts
   - Window readiness verification before retry attempts

5. **Screen Recording Bypass**:
   - Uses window sharing state APIs to prevent windows from appearing in screen recordings
   - Applies different techniques based on window type and ownership

## Troubleshooting

If the application crashes on launch:
- Ensure the application isn't already running
- Some applications may have security measures that prevent injection
- Check that System Integrity Protection (SIP) isn't blocking the injection

If windows aren't being modified:
- It may be a service/utility process - these are intentionally skipped
- Some windows are protected during initial launch to prevent crashes
- Check that the window is a standard user interface window, not a utility

If a specific feature isn't working:
- **Screen recording bypass**: May be blocked by high security applications or system security policies
- **Mission Control display**: Make sure the window has the correct collection behavior flags
- **Always-on-top**: Might be overridden by system windows or full-screen applications

## Project Structure

The project has been refactored for better organization and broader compatibility:

- `src/core/`: Core functionality and entry points
  - `src/core/injection_entry.c`: Entry point for dylib injection
  - `src/core/common_types.h`: Centralized type definitions
  - `src/core/window_modifier_types.h`: Additional window-specific types
- `src/operations/`: Window operations implementation
  - `src/operations/window_modifier.m`: Core window modification logic
  - `src/operations/window_modifier.h`: Public API for window modification
  - `src/operations/window_modifier_swizzle.m`: Method swizzling implementation
  - `src/operations/window_modifier_swizzle.h`: Method swizzling interface
- `src/tracker/`: Window and process tracking
  - `src/tracker/window_registry.c`: Shared registry for cross-process coordination
  - `src/tracker/window_registry.h`: Registry interface
  - `src/tracker/window_classifier.m`: Window type detection and classification
  - `src/tracker/window_classifier.h`: Window classification interface
- `src/cgs/`: Core Graphics Services wrapper
  - `src/cgs/window_modifier_cgs.m`: CGS API implementations
  - `src/cgs/window_modifier_cgs.h`: CGS function declarations
- `src/injector.c`: Command-line injection utility with enhanced architecture detection

## Security Note

This project uses private Apple APIs (CGS) and method swizzling, which are not approved for App Store distribution. This is intended as a proof-of-concept and for educational purposes only.
