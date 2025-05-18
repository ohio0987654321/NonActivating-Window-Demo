#!/bin/bash
# launch_app.sh - Universal launcher for applications with enhanced window modifier

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/Application.app [--debug]"
    echo "Examples:"
    echo "  $0 /Applications/Discord.app"
    echo "  $0 /Applications/Slack.app"
    echo "  $0 /Applications/Google\\ Chrome.app --debug"
    exit 1
fi

APP_PATH="$1"
DEBUG_MODE=0

if [ "$2" == "--debug" ]; then
    DEBUG_MODE=1
    echo "Debug mode enabled: extra logging will be displayed"
fi

# Validate app
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Application not found at: $APP_PATH"
    exit 1
fi

# Get app name
APP_NAME=$(basename "$APP_PATH" | sed 's/\.app$//')
echo "Target application: $APP_NAME"

# Find the executable
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
if [ ! -f "$EXECUTABLE" ]; then
    # Some apps have differently named executables, try to find it
    EXECUTABLE=$(find "$APP_PATH/Contents/MacOS" -type f -perm +111 | head -1)
    if [ ! -f "$EXECUTABLE" ]; then
        echo "Error: Executable not found in $APP_PATH/Contents/MacOS/"
        exit 1
    fi
fi

echo "Found executable: $EXECUTABLE"

# Build the window modifier
echo "Building window modifier..."
make clean && make
if [ $? -ne 0 ]; then
    echo "Error: Build failed"
    exit 1
fi

# Get DYLIB path
DYLIB_PATH="$(pwd)/build/libwindowmodifier.dylib"
if [ ! -f "$DYLIB_PATH" ]; then
    echo "Error: Failed to build DYLIB"
    exit 1
fi

# Kill any existing app processes
echo "Stopping any running $APP_NAME instances..."
pkill -f "$APP_NAME" || true
sleep 2

# Setup log file
LOG_FILE="$(pwd)/$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')_launch.log"
echo "Log file: $LOG_FILE"
echo "--- $(date) - Window Modifier Launch ---" > "$LOG_FILE"

# Set environment variables for advanced debugging
if [ $DEBUG_MODE -eq 1 ]; then
    export OBJC_DEBUG_MISSING_POOLS=YES
    export OBJC_PRINT_EXCEPTIONS=YES
    export DYLD_PRINT_LIBRARIES=1
    export DYLD_PRINT_BINDINGS=1
    echo "Enhanced debugging enabled - check system logs for additional information"
fi

# Launch application with DYLIB injection
echo "Launching $APP_NAME with window modifier..."
echo "DYLIB path: $DYLIB_PATH"

DYLD_INSERT_LIBRARIES="$DYLIB_PATH" "$EXECUTABLE" 2>&1 | tee -a "$LOG_FILE" &

APP_PID=$!
echo "$APP_NAME started with PID: $APP_PID"

# Wait a moment for processes to initialize
echo "Waiting for processes to initialize..."
sleep 5

# Check if app is still running
if ! ps -p $APP_PID > /dev/null; then
    echo "Warning: $APP_NAME appears to have terminated immediately."
    echo "Check $LOG_FILE for errors."
    echo "Last 20 lines of log:"
    tail -n 20 "$LOG_FILE"
else
    # Check for child processes (important for multi-process apps)
    echo "Checking for multi-process structure..."
    CHILD_PROCESSES=$(pgrep -P $APP_PID)
    PROCESS_COUNT=$(echo "$CHILD_PROCESSES" | wc -l | tr -d ' ')
    
    if [ -n "$CHILD_PROCESSES" ]; then
        echo "Detected $PROCESS_COUNT child processes - good sign for multi-process apps"
    else
        echo "No child processes detected - app may be single-process or still initializing"
    fi
    
    echo
    echo "The window modifier is now active. You should see:"
    echo "- Windows that stay on top of other applications"
    echo "- Windows that don't steal focus when clicked"
    echo "- Windows that are hidden in screenshots (test with ⌘+Shift+4)"
    echo
    echo "Check $LOG_FILE for detailed logs"
    echo "Press Ctrl+C to exit this script ($APP_NAME will continue running)"
    
    # Wait for app (will be interrupted by Ctrl+C)
    wait $APP_PID
fi
