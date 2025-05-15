# NonActivating Window Demo

A macOS application demonstrating how to create a window that doesn't steal focus from other applications while still being interactive.

## Features

- **Non-activating window**: Receives key input without stealing focus from other applications
- **Always on top**: Stays above other windows
- **Mission Control visibility**: Shows up in Mission Control
- **Screen capture bypass**: Cannot be captured in screenshots or recordings

## How It Works

This application uses a combination of special window properties:

- `NSWindowStyleMaskNonactivatingPanel` to create a window that doesn't activate the application
- `NSFloatingWindowLevel` to keep the window above others
- Special collection behaviors to ensure Mission Control visibility
- `NSWindowSharingNone` to prevent screen capture

## Building the Project

1. Make sure you have Xcode command-line tools installed
2. Clone this repository
3. Run the following commands:

```bash
cd project-directory
make
```

## Running the Application

After building, run:

```bash
make run
```

Or manually open:

```bash
open build/Window
```

## Implementation Notes

- The key functionality is implemented in `AppDelegate.m` using a custom `NonActivatingWindow` class
- The window can receive key input (demonstrated with a text field) while maintaining focus on previous applications
- The window appears in Mission Control but doesn't steal focus when clicked
