# Window Modifier Injection PoC

A proof of concept (PoC) for injecting window modification capabilities into macOS applications through dynamic library injection.

## Overview

This project demonstrates how to modify the behavior of existing macOS application windows by injecting a dynamic library at runtime. The injected code enables several powerful window features without modifying the original application code.

## Features

The injected code modifies windows to have the following properties:

1. **Screen Recording Bypass**: Windows won't appear in screen recordings or screenshots
2. **Always-on-top Display**: Windows stay above other applications
3. **Focus-preserving Interaction**: Windows can be interacted with without stealing focus from other applications
4. **Title Bar State Control**: Preserves active title bar appearance in other applications
5. **Mission Control Visibility**: Modified windows still appear in Mission Control

## Building the Project

To build the project:

```bash
make
```

This will create:
- `build/libwindowmodifier.dylib`: The injection library
- `build/injector`: A command-line utility for easy injection

## Usage

Inject window modifications into an application:

```bash
./build/injector /Applications/TargetApp.app
```

The injector will:
1. Locate the executable inside the application bundle
2. Launch it with the injection library attached

### Manual Injection

You can also manually inject using the DYLD_INSERT_LIBRARIES environment variable:

```bash
DYLD_INSERT_LIBRARIES=./build/libwindowmodifier.dylib /Applications/TargetApp.app/Contents/MacOS/TargetApp

or

./build/injector /Application/TargetApp.app
```

## Technical Implementation

The project utilizes several macOS internals:

1. **Private AppKit Methods**: Uses NSWindow's private `_setPreventsActivation:` method to implement focus-preserving behavior

2. **CoreGraphics Window Server API**: Sets window tags and properties using CGS* functions to modify window behavior at a low level

3. **Window Level Management**: Manipulates window levels to ensure always-on-top behavior

4. **Focus Management**: Implements focus tracking and restoration to maintain proper window state

## Project Structure

- `src/window_modifier.m`: Core window modification logic
- `src/injection_entry.c`: Entry point for dylib injection
- `src/injector.c`: Command-line injection utility

## Security and Compatibility Notes

- This technique uses private APIs that may change in future macOS versions
- Some applications may have security measures that prevent injection
- Applications using this method cannot be distributed through the Mac App Store
- System Integrity Protection (SIP) may prevent injection into certain applications

## Use Cases

This technique may be useful for:
- Creating utility applications that need to remain visible
- HUD-style overlays that don't interrupt workflow
- Accessibility tools that need to remain non-intrusive
- Development and testing tools

## License

This code is provided for educational purposes only. Use at your own risk.