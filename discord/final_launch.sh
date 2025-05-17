#!/bin/bash
# final_launch.sh - Simple launcher for Discord with the final modifier

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/Discord.app"
    exit 1
fi

APP_PATH="$1"

# Validate app
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Discord not found at: $APP_PATH"
    exit 1
fi

# Find the executable
EXECUTABLE="$APP_PATH/Contents/MacOS/Discord"
if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Discord executable not found"
    exit 1
fi

# Build the DYLIB
echo "Building final Discord modifier..."
make

# Get DYLIB path
DYLIB_PATH="$(pwd)/build/libdiscord_final.dylib"
if [ ! -f "$DYLIB_PATH" ]; then
    echo "Error: Failed to build DYLIB"
    exit 1
fi

# Kill any existing Discord processes
echo "Stopping any running Discord instances..."
pkill -f "Discord" || true
sleep 1

# Launch Discord with the DYLIB
echo "Launching Discord with final modifier..."
echo "DYLIB: $DYLIB_PATH"
echo "Executable: $EXECUTABLE"

# Set environment variables for better debugging
export OBJC_DEBUG_MISSING_POOLS=YES
export OBJC_PRINT_EXCEPTIONS=YES

DYLD_INSERT_LIBRARIES="$DYLIB_PATH" "$EXECUTABLE" &

DISCORD_PID=$!
echo "Discord started with PID: $DISCORD_PID"
echo

# Wait a moment
sleep 3

echo "If you don't see any [DISCORD-MOD] messages above, check the Console app for output"
echo "The modifier will attempt to make Discord windows always-on-top and non-activating"
echo "Press Ctrl+C to exit this script (Discord will continue running)"

# Wait for Discord (optional)
wait $DISCORD_PID