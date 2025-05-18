# Enhanced Window Modifier for Multi-Process Applications

This improved version of the window modifier provides better stability and compatibility with a wide range of multi-process applications.

## Key Improvements

1. **Reliable Cross-Process Communication**
   - Replaced error-prone shared memory approach with robust file-based registry
   - Added file locking for reliable concurrent access
   - Registry now persists across process restarts for better stability

2. **Enhanced Process Role Detection**
   - Automatically identifies utility vs. UI processes based on behavior patterns
   - Intelligently handles network service processes in Electron apps
   - Prevents crashes in Discord's Network Service
   - No framework-specific code - detection is based on universal process characteristics

3. **Renderer Process Protection**
   - Added special protection for the first critical windows in renderer processes
   - Prevents interference with Electron's network service initialization
   - Tracks window modification count to adapt behavior based on process state
   - Solves Discord's intermittent startup failures by protecting early windows

4. **Adaptive Startup Protection Periods**
   - Standard 3-second protection for most processes
   - Extended 10-second protection for renderer processes
   - Prevents modification during critical initialization phases
   - Tailored delays based on process role (main, renderer, utility)

5. **Window Stability Detection**
   - Added intelligent window readiness detection that works across all application frameworks
   - Checks for stable window dimensions, visibility, and drawing context before modification
   - Distinguishes between utility windows and user interface windows
   - No framework-specific code, ensuring universal compatibility

6. **Progressive Retry Strategy**
   - Implements an adaptive retry system with progressive delays for window modification
   - First attempts immediate modification for simple applications
   - Gradually increases retry intervals (0.1s, 0.3s, 0.6s, etc.) for complex window systems
   - Automatically manages a retry queue for unstable windows

7. **Enhanced Error Handling & Resilience**
   - Graceful fallbacks when CGS notification registration fails
   - Improved detection and handling of multi-process applications 
   - Added more signal handlers to handle crashes more gracefully
   - More robust thread management with fallbacks

8. **Better Process Management**
   - Proper cleanup of resources and stale registry data
   - Improved process type detection for various application frameworks
   - More informative logging for easier troubleshooting

## How It Works

The window modifier now uses three main techniques to detect and modify windows:

1. **AppKit Method Swizzling**: Intercepts window creation in AppKit-based processes
2. **CGS Notification System**: Receives window creation events from the window server
3. **Periodic Window Scanning**: Fallback method that scans for windows periodically

These techniques work together to ensure all windows are properly modified across multiple application processes.

## Usage

Use the launcher script to inject the window modifier into any application:

```
./launch_app.sh /path/to/application.app
```

Examples:
```
./launch_app.sh /Applications/Discord.app
./launch_app.sh /Applications/Slack.app
./launch_app.sh /Applications/Google\ Chrome.app
```

## Window Modifications Applied

When applied, the window modifier makes the following changes to windows:

1. **Always-on-top**: Windows stay above regular application windows
2. **Non-activating**: Windows don't steal focus when clicked
3. **Screen capture bypass**: Windows aren't visible in screenshots/recordings
4. **Global visibility**: Windows are visible in all Mission Control spaces

## Technical Notes

The system is designed to work with various multi-process application frameworks:

- Electron (Discord, Slack, VS Code, etc.)
- Chromium (Chrome, Edge, Brave, etc.)
- WebKit (Safari, Mail, etc.)
- Firefox
- And more...

The file-based registry ensures that even if processes crash or restart, the system maintains consistent window state tracking.
