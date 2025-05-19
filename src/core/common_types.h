// common_types.h - Centralized type definitions for the window modifier
#ifndef COMMON_TYPES_H
#define COMMON_TYPES_H

#include <stdbool.h>
#include <stdint.h>  // for uint32_t
#include <time.h>    // for time_t

//==============================================================================
// CoreGraphics Services (CGS) private API types and constants
//==============================================================================

// These are not publicly documented but are used for window management
typedef uint32_t CGSWindowID;
typedef uint32_t CGSConnectionID;
typedef void (*CGSNotifyConnectionProcPtr)(int type, void *data, uint32_t data_length, void *userdata);

// CGS window notifications
#define kCGSWindowDidCreateNotification        1
#define kCGSWindowDidDestroyNotification       2
#define kCGSWindowDidOrderInNotification       3
#define kCGSWindowDidOrderOutNotification      4
#define kCGSWindowDidExposeNotification        5
#define kCGSWindowDidResizeNotification        6
#define kCGSWindowDidUpdateNotification        18
#define kCGSWindowDidFocusNotification         19
#define kCGSWindowDidUnfocusNotification       20

// CGS window sharing state
#define kCGSWindowSharingNoneValue             0
#define kCGSWindowSharingReadOnlyValue         1
#define kCGSWindowSharingReadWriteValue        2

// CGS window tags
#define kCGSPreventsActivationTagBit           (1 << 7)

// CGS window level constants
#define kCGSWindowLevelForKey                  3

//==============================================================================
// Window state and tracking
//==============================================================================

// Window state tracking flags
#define WINDOW_STATE_CREATED                   (1 << 0)
#define WINDOW_STATE_VISIBLE                   (1 << 1)
#define WINDOW_STATE_SIZED                     (1 << 2)
#define WINDOW_STATE_CONTENT_READY             (1 << 3)
#define WINDOW_STATE_FULLY_INITIALIZED         (WINDOW_STATE_CREATED | WINDOW_STATE_VISIBLE | WINDOW_STATE_SIZED | WINDOW_STATE_CONTENT_READY)

// Window class identification
typedef enum {
    WINDOW_CLASS_UNKNOWN = 0,
    WINDOW_CLASS_NORMAL,
    WINDOW_CLASS_UTILITY,
    WINDOW_CLASS_DIALOG,
    WINDOW_CLASS_POPUP,
    WINDOW_CLASS_SHEET,
    WINDOW_CLASS_TOOLBAR,
    WINDOW_CLASS_MENU,
    WINDOW_CLASS_SPLASH,
    WINDOW_CLASS_HELPER,
    WINDOW_CLASS_STANDARD,  // Standard application window
    WINDOW_CLASS_PANEL,     // Utility panel window
    WINDOW_CLASS_SYSTEM     // System window
} window_class_t;

// Window Event Types
typedef enum {
    WINDOW_EVENT_CREATED,
    WINDOW_EVENT_DESTROYED,
    WINDOW_EVENT_FOCUSED,
    WINDOW_EVENT_UNFOCUSED,
    WINDOW_EVENT_MOVED,
    WINDOW_EVENT_RESIZED,
    WINDOW_EVENT_MINIMIZED,
    WINDOW_EVENT_UNMINIMIZED,
    WINDOW_EVENT_HIDDEN,
    WINDOW_EVENT_SHOWN
} WindowEventType;

// Window Modifier state
typedef enum {
    WINDOW_MODIFIER_STATE_INITIALIZING,
    WINDOW_MODIFIER_STATE_READY,
    WINDOW_MODIFIER_STATE_ERROR,
    WINDOW_MODIFIER_STATE_DISABLED
} WindowModifierState;

// Window modification options
typedef struct {
    bool keepAbove;        // Keep window above others
    bool nonActivating;    // Window doesn't activate when clicked
    bool ignoreExpose;     // Window ignores expose events
    bool allowsMoving;     // Window can be moved by user
    int level;             // Window level (z-order)
    float opacity;         // Window opacity (0.0-1.0)
} WindowModificationOptions;

// Window initialization state tracking
typedef struct {
    CGSWindowID window_id;
    window_class_t window_class;
    int window_state;
    bool is_initialized;
    time_t first_seen;
} window_init_state_t;

// Window tracking information
typedef struct {
    CGSWindowID windowID;  // Window ID in CoreGraphics Services
    bool isModified;       // Whether window has been modified
    bool isTracked;        // Whether window is being tracked
    WindowModificationOptions options; // Current modification options
} WindowTrackingInfo;

// Retry window tracking
typedef struct {
    CGSWindowID windowID;
    int attempts;
    double next_attempt_time;
} retry_window_t;

//==============================================================================
// Process and application state
//==============================================================================

// Process role classification
typedef enum {
    PROCESS_ROLE_MAIN,     // Main application process
    PROCESS_ROLE_UI,       // UI/Renderer process
    PROCESS_ROLE_UTILITY   // Helper/Agent process
} process_role_t;

// Application initialization state
typedef enum {
    APP_INIT_NOT_STARTED,
    APP_INIT_FIRST_WINDOW_CREATING,
    APP_INIT_FIRST_WINDOW_COMPLETE,
    APP_INIT_MAIN_WINDOW_CREATING,
    APP_INIT_COMPLETE
} app_init_state_t;

//==============================================================================
// System and architecture
//==============================================================================

// System architecture type
typedef enum {
    ARCH_TYPE_X86_64,
    ARCH_TYPE_ARM64,
    ARCH_TYPE_ARM64E,
    ARCH_TYPE_UNKNOWN
} ArchitectureType;

//==============================================================================
// Error handling
//==============================================================================

// Error codes
typedef enum {
    ERROR_NONE,
    ERROR_INITIALIZATION_FAILED,
    ERROR_WINDOW_NOT_FOUND,
    ERROR_MODIFICATION_FAILED,
    ERROR_INVALID_ARGUMENT,
    ERROR_OPERATION_TIMEOUT,
    ERROR_SYSTEM_INCOMPATIBLE
} ErrorCode;

// Error info struct
typedef struct {
    ErrorCode code;
    char message[256];
} ErrorInfo;

//==============================================================================
// Function types and Objective-C integration
//==============================================================================

// Function pointer type for C interfaces
typedef bool (*ModifyWindowByIDFn)(CGSWindowID windowID, WindowModificationOptions options);

// Include Objective-C headers and types for ObjC code only
#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

// Function pointer types for Objective-C interfaces
typedef bool (*ModifyWindowFn)(NSWindow *window, WindowModificationOptions options);
#endif // __OBJC__

#endif // COMMON_TYPES_H
