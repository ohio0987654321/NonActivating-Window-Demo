#!/bin/bash
# launch_app.sh - Universal launcher for applications with enhanced window modifier v2.0

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/Application.app [--debug] [--use-injector]"
    echo "Examples:"
    echo "  $0 /Applications/Discord.app"
    echo "  $0 /Applications/Slack.app"
    echo "  $0 /Applications/Google\\ Chrome.app --debug"
    echo "  $0 /Applications/Discord.app --use-injector"
    exit 1
fi

APP_PATH="$1"
DEBUG_MODE=0
USE_INJECTOR=0

# Parse arguments
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug)
            DEBUG_MODE=1
            echo "Debug mode enabled: extra logging will be displayed"
            ;;
        --use-injector)
            USE_INJECTOR=1
            echo "Using standalone injector method"
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Validate app
if [ ! -d "$APP_PATH" ] && [ ! -x "$APP_PATH" ]; then
    echo "Error: Application not found or not valid: $APP_PATH"
    exit 1
fi

# Get app name
APP_NAME=$(basename "$APP_PATH" | sed 's/\.app$//')
echo "Target application: $APP_NAME"

# Find the executable if app is a bundle
if [[ "$APP_PATH" == *.app ]]; then
    EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
    if [ ! -f "$EXECUTABLE" ]; then
        # Some apps have differently named executables, try to find it
        EXECUTABLE=$(find "$APP_PATH/Contents/MacOS" -type f -perm +111 | head -1)
        if [ ! -f "$EXECUTABLE" ]; then
            echo "Error: Executable not found in $APP_PATH/Contents/MacOS/"
            exit 1
        fi
    fi
else
    # Direct executable path
    EXECUTABLE="$APP_PATH"
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

# Clean up registry directory for a fresh start
REGISTRY_DIR="/tmp/window_modifier"
REGISTRY_FILE="$REGISTRY_DIR/window_modifier_registry.dat"

echo "Cleaning up window registry..."
rm -f "$REGISTRY_FILE" 2>/dev/null

if [ ! -d "$REGISTRY_DIR" ]; then
    echo "Creating registry directory..."
    mkdir -p "$REGISTRY_DIR"
    chmod 755 "$REGISTRY_DIR"
fi

# Kill any existing app processes
echo "Stopping any running $APP_NAME instances..."
pkill -9 -f "$APP_NAME" 2>/dev/null || true
sleep 1

# Setup log file
LOG_FILE="$(pwd)/$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')_launch.log"
echo "Log file: $LOG_FILE"
echo "--- #午後 - Window Modifier Launch ---" > "$LOG_FILE"

# Set environment variables for advanced debugging
if [ $DEBUG_MODE -eq 1 ]; then
    export OBJC_DEBUG_MISSING_POOLS=YES
    export OBJC_PRINT_EXCEPTIONS=YES
    # Only show DYLD logs in high-verbosity debug mode
    if [ "$DEBUG_VERBOSE" == "high" ]; then
        export DYLD_PRINT_LIBRARIES=1
        export DYLD_PRINT_BINDINGS=1
    fi
    echo "Enhanced debugging enabled"
fi

# Launch application with DYLIB injection
echo "Launching $APP_NAME with window modifier..."

if [ $USE_INJECTOR -eq 1 ]; then
    # Use the standalone injector
    echo "Using standalone injector executable"
    if [ $DEBUG_MODE -eq 1 ]; then
        ./build/injector "$APP_PATH" --debug | tee -a "$LOG_FILE"
    else
        ./build/injector "$APP_PATH" | tee -a "$LOG_FILE"
    fi
else
    # Use direct environment variable injection
    echo "Using direct DYLIB injection"
    echo "DYLIB: $DYLIB_PATH"
    echo "Executable: $EXECUTABLE"
    
    DYLD_INSERT_LIBRARIES="$DYLIB_PATH" DYLD_FORCE_FLAT_NAMESPACE=1 "$EXECUTABLE" 2>&1 | tee -a "$LOG_FILE" &
    
    APP_PID=$!
    echo "$APP_NAME started with PID: $APP_PID"
    
    # Wait a moment for processes to initialize
    echo "Waiting for processes to initialize..."
    sleep 3
    
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
        
        # Register a trap to kill the app on script exit
        trap 'echo "Received Ctrl+C, cleaning up..."; kill -TERM $APP_PID 2>/dev/null || true; sleep 1; kill -9 $APP_PID 2>/dev/null || true; exit 0' INT TERM
        
        # Wait for app (will be interrupted by Ctrl+C)
        wait $APP_PID
    fi
fi
