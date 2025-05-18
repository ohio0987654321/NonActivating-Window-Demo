# Window Modifier for macOS Applications

## Overview

This proof-of-concept (PoC) project creates a window modifier library that can be injected into macOS applications. It enables windows to:

1. Stay on top of other applications (always-on-top)
2. Not steal focus when clicked on (accessory window mode)
3. Be hidden from screen captures (screen capture bypass)
4. Properly integrate with Mission Control and virtual desktops

The project has been redesigned for better stability with multi-process applications like Discord, Slack, Chrome, and other Electron/Chromium-based apps.

## Key Features

- **Process role detection**: Automatically detects main, renderer, utility, and service processes
- **Registry system**: Maintains a shared registry across all processes to avoid duplicate window modifications
- **Startup protection**: Prevents interference with critical initialization processes
- **Window classification**: Intelligently detects utility windows vs. user interface windows
- **Error resilience**: Enhanced error handling and recovery mechanisms
- **Focus preservation**: Better focus management to maintain the current app's activation state
- **Mission Control integration**: Windows properly appear in Mission Control
- **Virtual desktop support**: Windows respect virtual desktop boundaries rather than appearing in fixed positions
- **Retry mechanism**: Automatically retries failed window modifications with exponential backoff

## Building

```
make clean && make
```

This will create:
- `build/libwindowmodifier.dylib` - The injectable library
- `build/injector` - A standalone injector executable

## Usage

### Basic Usage

```
./build/injector /Applications/TargetApp.app/Contents/MacOS/TargetApp
```

**Important:** Always specify the direct path to the executable within the .app bundle, not just the app bundle itself. For example:

```
# Correct usage:
./build/injector /Applications/Discord.app/Contents/MacOS/Discord

# Not recommended (may work but less reliable):
./build/injector /Applications/Discord.app
```

This direct approach ensures more reliable injection and is the preferred method.

### Manual Injection (Alternative)

You can also manually inject using the DYLD_INSERT_LIBRARIES environment variable:

```
DYLD_INSERT_LIBRARIES=./build/libwindowmodifier.dylib DYLD_FORCE_FLAT_NAMESPACE=1 /Applications/TargetApp.app/Contents/MacOS/TargetApp
```

## Supported Applications

Tested with:
- Discord
- Slack
- Google Chrome
- Firefox
- Safari

## How it Works

The library uses a combination of:

1. **DYLIB injection** - Loads into the target application processes
2. **AppKit swizzling** - Intercepts window creation and updating methods
3. **Core Graphics Services (CGS)** - Uses private Apple APIs for window modification
4. **Inter-process registry** - Coordinated window management using a shared memory-mapped file

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

## Troubleshooting

If the application crashes on launch:
- Ensure the application isn't already running
- Some applications may have security measures that prevent injection
- Check that System Integrity Protection (SIP) isn't blocking the injection

If windows aren't being modified:
- It may be a service/utility process - these are intentionally skipped
- Some windows are protected during initial launch to prevent crashes
- Check that the window is a standard user interface window, not a utility

## Project Structure

- `src/window_modifier.m`: Core window modification logic
- `src/injection_entry.c`: Entry point for dylib injection
- `src/injector.c`: Command-line injection utility
- `src/window_registry.c`: Shared registry for cross-process coordination

## Security Note

This project uses private Apple APIs (CGS) and method swizzling, which are not approved for App Store distribution. This is intended as a proof-of-concept and for educational purposes only.
