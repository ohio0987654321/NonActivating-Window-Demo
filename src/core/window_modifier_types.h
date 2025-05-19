// window_modifier_types.h - Common types for window modification
#ifndef WINDOW_MODIFIER_TYPES_H
#define WINDOW_MODIFIER_TYPES_H

#import <CoreGraphics/CoreGraphics.h>

// Window registry opaque type
typedef struct window_registry window_registry_t;

// Process role detection - simplified to three essential roles
typedef enum {
    PROCESS_ROLE_MAIN,       // Main application process
    PROCESS_ROLE_UI,         // Any UI rendering process (renderer, plugin, etc.)
    PROCESS_ROLE_UTILITY     // Background service process
} process_role_t;

// Window classification by CGS properties
typedef enum {
    WINDOW_CLASS_UNKNOWN = 0,
    WINDOW_CLASS_STANDARD,      // Standard application window
    WINDOW_CLASS_PANEL,         // Panel/utility window
    WINDOW_CLASS_SHEET,         // Sheet dialog
    WINDOW_CLASS_SYSTEM,        // System window
    WINDOW_CLASS_HELPER         // Helper/auxiliary window
} window_class_t;

// Application initialization state tracking
typedef enum {
    APP_INIT_NOT_STARTED,
    APP_INIT_FIRST_WINDOW_CREATING,
    APP_INIT_FIRST_WINDOW_COMPLETE,
    APP_INIT_MAIN_WINDOW_CREATING,
    APP_INIT_COMPLETE
} app_init_state_t;

// Window state tracking structure
typedef struct {
    uint32_t window_id;
    uint32_t window_state;      // Bitfield of events received
    bool is_initialized;        // Window fully initialized flag
    time_t first_seen;          // Timestamp when window was first seen
    window_class_t window_class; // Classification of window
} window_init_state_t;

// Window stability tracking
typedef struct {
    uint32_t windowID;         // Changed from CGSWindowID to uint32_t
    int attempts;
    double next_attempt_time;
} retry_window_t;

// Window state flags
#define WINDOW_STATE_CREATED         (1 << 0)
#define WINDOW_STATE_VISIBLE         (1 << 1)
#define WINDOW_STATE_SIZED           (1 << 2)
#define WINDOW_STATE_CONTENT_READY   (1 << 3)
#define WINDOW_STATE_FULLY_INITIALIZED (WINDOW_STATE_CREATED | \
                                       WINDOW_STATE_VISIBLE | \
                                       WINDOW_STATE_SIZED | \
                                       WINDOW_STATE_CONTENT_READY)

// CGS Function and Type Declarations
typedef int CGSConnectionID;
typedef uint32_t CGSWindowID;   // Changed from int to uint32_t
typedef uint64_t CGSNotificationID;
typedef void* CGSNotificationArg;
typedef void (*CGSNotifyConnectionProcPtr)(int type, void *data, uint32_t data_length, void *arg);

// CGS Window Notification Types
enum {
    kCGSWindowDidCreateNotification = 1001,
    kCGSWindowDidDeminiaturizeNotification = 1002,
    kCGSWindowDidMiniaturizeNotification = 1003,
    kCGSWindowDidOrderInNotification = 1004,
    kCGSWindowDidOrderOutNotification = 1005,
    kCGSWindowDidReorderNotification = 1006,
    kCGSWindowDidResizeNotification = 1007,
    kCGSWindowDidUpdateNotification = 1008
};

// CGS Constants
#define kCGSPreventsActivationTagBit (1 << 16)
#define kCGSWindowSharingNoneValue 0
#define kCGSWindowLevelForKey 2 // NSFloatingWindowLevel

#endif // WINDOW_MODIFIER_TYPES_H
