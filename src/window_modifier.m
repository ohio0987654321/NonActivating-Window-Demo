// window_modifier.m - Enhanced for all macOS applications
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>
#include "window_registry.h"
#import <sys/time.h>
#import <pthread.h>

// Declare NSWindow private methods
@interface NSWindow (PrivateMethods)
- (void)_setPreventsActivation:(BOOL)preventsActivation;
@end

// CGS Function and Type Declarations
typedef int CGSConnectionID;
typedef int CGSWindowID;
typedef uint64_t CGSNotificationID;
typedef void* CGSNotificationArg;
typedef void (*CGSNotifyConnectionProcPtr)(int type, void *data, uint32_t data_length, void *arg);

#define kCGSPreventsActivationTagBit (1 << 16)
#define kCGSWindowSharingNoneValue 0
#define kCGSWindowLevelForKey 2 // NSFloatingWindowLevel

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

// CGS Function typedefs
typedef CGSConnectionID (*CGSDefaultConnection_t)(void);
typedef CGError (*CGSSetWindowLevel_t)(CGSConnectionID, CGSWindowID, int);
typedef CGError (*CGSSetWindowSharingState_t)(CGSConnectionID, CGSWindowID, int);
typedef CGError (*CGSSetWindowTags_t)(CGSConnectionID, CGSWindowID, int*, int);
typedef CGError (*CGSClearWindowTags_t)(CGSConnectionID, CGSWindowID, int*, int);
typedef CGError (*CGSGetWindowTags_t)(CGSConnectionID, CGSWindowID, int*, int*);
typedef CGError (*CGSRegisterNotifyProc_t)(CGSNotifyConnectionProcPtr proc, int type, void *arg);
typedef CGError (*CGSGetOnScreenWindowList_t)(CGSConnectionID cid, CGSConnectionID targetCID, int maxCount, CGSWindowID *list, int *listCount);
typedef CGError (*CGSGetWindowLevel_t)(CGSConnectionID, CGSWindowID, int*);
typedef CGError (*CGSGetWindowOwner_t)(CGSConnectionID, CGSWindowID, CGSConnectionID*);
typedef CGError (*CGSGetConnectionPSN_t)(CGSConnectionID, ProcessSerialNumber*);
typedef CFArrayRef (*CGSCopyWindowDescriptionList_t)(CGSConnectionID cid, int windowID);
typedef CGError (*CGSGetConnectionID_t)(CGSConnectionID* cid);

// CGS Function pointers
static CGSDefaultConnection_t CGSDefaultConnection_ptr = NULL;
static CGSSetWindowLevel_t CGSSetWindowLevel_ptr = NULL;
static CGSSetWindowSharingState_t CGSSetWindowSharingState_ptr = NULL;
static CGSSetWindowTags_t CGSSetWindowTags_ptr = NULL;
static CGSClearWindowTags_t CGSClearWindowTags_ptr = NULL;
static CGSGetWindowTags_t CGSGetWindowTags_ptr = NULL;
static CGSRegisterNotifyProc_t CGSRegisterNotifyProc_ptr = NULL;
static CGSGetOnScreenWindowList_t CGSGetOnScreenWindowList_ptr = NULL;
static CGSGetWindowLevel_t CGSGetWindowLevel_ptr = NULL;
static CGSGetWindowOwner_t CGSGetWindowOwner_ptr = NULL;
static CGSGetConnectionPSN_t CGSGetConnectionPSN_ptr = NULL;
static CGSCopyWindowDescriptionList_t CGSCopyWindowDescriptionList_ptr = NULL;
static CGSGetConnectionID_t CGSGetConnectionID_ptr = NULL;

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

// Window state tracking structure
typedef struct {
    uint32_t window_id;
    uint32_t window_state;      // Bitfield of events received
    bool is_initialized;        // Window fully initialized flag
    time_t first_seen;          // Timestamp when window was first seen
    window_class_t window_class; // Classification of window
} window_init_state_t;

// Window state flags
#define WINDOW_STATE_CREATED         (1 << 0)
#define WINDOW_STATE_VISIBLE         (1 << 1)
#define WINDOW_STATE_SIZED           (1 << 2)
#define WINDOW_STATE_CONTENT_READY   (1 << 3)
#define WINDOW_STATE_FULLY_INITIALIZED (WINDOW_STATE_CREATED | \
                                       WINDOW_STATE_VISIBLE | \
                                       WINDOW_STATE_SIZED | \
                                       WINDOW_STATE_CONTENT_READY)

// Window stability tracking
typedef struct {
    CGSWindowID windowID;
    int attempts;
    double next_attempt_time;
} retry_window_t;

// Global state
static NSRunningApplication *previousFrontmostApp = nil;
static window_registry_t *window_registry = NULL;
static bool is_cgs_monitor_active = false;
static process_role_t current_process_role = PROCESS_ROLE_MAIN;
static time_t process_start_time = 0;
static int modified_window_count = 0;
static const int STARTUP_PROTECTION_SECONDS = 3; // Simplified protection period
static const int UI_STARTUP_PROTECTION_SECONDS = 5; // Extra time for UI processes
static const int MAX_PROTECTED_WINDOWS = 2; // Limit for protected windows
static retry_window_t retry_windows[32];
static int retry_window_count = 0;
static double retry_delays[] = {0.1, 0.3, 0.6, 1.0, 2.0}; // Progressive delays in seconds
static const int max_retry_attempts = 5;

// Thread-local storage for current window context
static pthread_key_t current_window_key;
static bool thread_keys_initialized = false;

// Window state tracking dictionary (window ID -> state)
static CFMutableDictionaryRef window_states = NULL;

// Application initialization state tracking
typedef enum {
    APP_INIT_NOT_STARTED,
    APP_INIT_FIRST_WINDOW_CREATING,
    APP_INIT_FIRST_WINDOW_COMPLETE,
    APP_INIT_MAIN_WINDOW_CREATING,
    APP_INIT_COMPLETE
} app_init_state_t;

static app_init_state_t current_init_state = APP_INIT_NOT_STARTED;
static int main_window_count = 0;

// Forward declarations
static NSDictionary *getWindowInfoWithCGS(CGSWindowID windowID);
static bool modifyWindowWithCGS(CGSWindowID windowID);
static bool modifyNSWindow(NSWindow *window);
static bool applyAllWindowModifications(void);
static void saveFrontmostApp(void);
static void restoreFrontmostApp(void);
static bool isUtilityWindow(CGSWindowID windowID);
static bool isWindowReadyForModification(CGSWindowID windowID);
static bool isInStartupProtection(void);
static bool isApplicationInitialized(void);
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry);
static void addWindowToRetryQueue(CGSWindowID windowID);
static void processRetryQueue(void);
static window_class_t determineWindowClass(CGSWindowID windowID, NSDictionary *windowInfo);
static bool isWindowInitialized(CGSWindowID windowID);
static void updateInitializationState(int eventType, CGSWindowID windowID);

// Function to count initialized standard windows for the dictionary applier
static void countInitializedStandardWindows(const void *key, const void *value, void *context) {
    window_init_state_t *state = (window_init_state_t *)value;
    if (state->window_class == WINDOW_CLASS_STANDARD && state->is_initialized) {
        int *counter = (int *)context;
        (*counter)++;
    }
}

// Function to count all standard windows (initialized or not)
static void countStandardWindows(const void *key, const void *value, void *context) {
    window_init_state_t *state = (window_init_state_t *)value;
    if (state->window_class == WINDOW_CLASS_STANDARD) {
        int *counter = (int *)context;
        (*counter)++;
    }
}

// Save previous app
static void saveFrontmostApp(void) {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (frontApp && ![frontApp.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        previousFrontmostApp = frontApp;
        printf("[Modifier] Saved frontmost app: %s\n", [frontApp.localizedName UTF8String]);
    }
}

// Return focus to previous app
static void restoreFrontmostApp(void) {
    if (previousFrontmostApp) {
        [previousFrontmostApp activateWithOptions:0];
        printf("[Modifier] Restored focus to: %s\n", [previousFrontmostApp.localizedName UTF8String]);
    }
}

// Load CGS functions
static bool loadCGSFunctions(void) {
    void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    if (!handle) {
        printf("[Modifier] Error: Failed to open CoreGraphics framework\n");
        return false;
    }
    
    // Load core CGS functions
    CGSDefaultConnection_ptr = (CGSDefaultConnection_t)dlsym(handle, "_CGSDefaultConnection");
    if (!CGSDefaultConnection_ptr) {
        CGSDefaultConnection_ptr = (CGSDefaultConnection_t)dlsym(handle, "CGSMainConnectionID");
    }
    
    CGSSetWindowLevel_ptr = (CGSSetWindowLevel_t)dlsym(handle, "CGSSetWindowLevel");
    CGSSetWindowSharingState_ptr = (CGSSetWindowSharingState_t)dlsym(handle, "CGSSetWindowSharingState");
    CGSSetWindowTags_ptr = (CGSSetWindowTags_t)dlsym(handle, "CGSSetWindowTags");
    CGSClearWindowTags_ptr = (CGSClearWindowTags_t)dlsym(handle, "CGSClearWindowTags");
    CGSGetWindowTags_ptr = (CGSGetWindowTags_t)dlsym(handle, "CGSGetWindowTags");
    
    // Load CGS functions for window detection
    CGSRegisterNotifyProc_ptr = (CGSRegisterNotifyProc_t)dlsym(handle, "CGSRegisterNotifyProc");
    CGSGetOnScreenWindowList_ptr = (CGSGetOnScreenWindowList_t)dlsym(handle, "CGSGetOnScreenWindowList");
    CGSGetWindowLevel_ptr = (CGSGetWindowLevel_t)dlsym(handle, "CGSGetWindowLevel");
    CGSGetWindowOwner_ptr = (CGSGetWindowOwner_t)dlsym(handle, "CGSGetWindowOwner");
    CGSGetConnectionPSN_ptr = (CGSGetConnectionPSN_t)dlsym(handle, "CGSGetConnectionPSN");
    CGSCopyWindowDescriptionList_ptr = (CGSCopyWindowDescriptionList_t)dlsym(handle, "CGSCopyWindowDescriptionList");
    CGSGetConnectionID_ptr = (CGSGetConnectionID_t)dlsym(handle, "CGSGetConnectionID");
    
    bool success = (CGSDefaultConnection_ptr != NULL && 
                    CGSSetWindowLevel_ptr != NULL && 
                    CGSSetWindowSharingState_ptr != NULL && 
                    CGSSetWindowTags_ptr != NULL);
    
    printf("[Modifier] CGS core functions loaded: %s\n", success ? "Success" : "Failed");
    
    bool detection_success = (CGSRegisterNotifyProc_ptr != NULL && 
                             CGSGetOnScreenWindowList_ptr != NULL);
    
    printf("[Modifier] CGS detection functions loaded: %s\n", detection_success ? "Success" : "Failed");
    
    return success;
}

// Get window information using CGS
static NSDictionary *getWindowInfoWithCGS(CGSWindowID windowID) {
    if (!CGSCopyWindowDescriptionList_ptr || !CGSDefaultConnection_ptr) {
        return nil;
    }
    
    CGSConnectionID cid = CGSDefaultConnection_ptr();
    CFArrayRef windowDescriptions = CGSCopyWindowDescriptionList_ptr(cid, windowID);
    
    if (!windowDescriptions || CFArrayGetCount(windowDescriptions) < 1) {
        if (windowDescriptions) {
            CFRelease(windowDescriptions);
        }
        return nil;
    }
    
    NSDictionary *windowInfo = (NSDictionary *)CFArrayGetValueAtIndex(windowDescriptions, 0);
    CFRetain((__bridge CFTypeRef)windowInfo);
    CFRelease(windowDescriptions);
    
    return CFBridgingRelease((__bridge_retained CFTypeRef)windowInfo);
}

// Determine window class from CGS properties
static window_class_t determineWindowClass(CGSWindowID windowID, NSDictionary *windowInfo) {
    if (!windowInfo) {
        return WINDOW_CLASS_UNKNOWN;
    }
    
    // Extract window metadata
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    NSNumber *width = windowInfo[@"kCGSWindowWidth"];
    NSNumber *height = windowInfo[@"kCGSWindowHeight"];
    NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
    NSNumber *windowLevel = windowInfo[@"kCGSWindowLevel"];
    NSNumber *styleMask = windowInfo[@"kCGSWindowStyleMask"];
    
    // Non-standard window levels indicate system or panel windows
    if (windowLevel) {
        int level = [windowLevel intValue];
        if (level > 0) {
            return (level > 3) ? WINDOW_CLASS_SYSTEM : WINDOW_CLASS_PANEL;
        }
    }
    
    // Layer detection (non-zero layers are usually utility windows)
    if (windowLayer && [windowLayer intValue] != 0) {
        return WINDOW_CLASS_HELPER;
    }
    
    // Size detection (very small windows are helper/utility windows)
    if (width && height) {
        if ([width intValue] < 100 || [height intValue] < 100) {
            return WINDOW_CLASS_HELPER;
        }
    }
    
    // Visibility detection (invisible or nearly invisible windows)
    if (alpha && [alpha doubleValue] < 0.3) {
        return WINDOW_CLASS_HELPER;
    }
    
    // Use style mask bits for classification if available
    if (styleMask) {
        uint32_t style = [styleMask unsignedIntValue];
        
        // Check for utility window style
        if (style & 0x8) {  // NSWindowStyleMaskUtilityWindow equivalent
            return WINDOW_CLASS_PANEL;
        }
        
        // Check for sheet style
        if (style & 0x200) { // NSWindowStyleMaskSheet equivalent
            return WINDOW_CLASS_SHEET;
        }
        
        // Standard window with title bar
        if (style & 0x1) {  // NSWindowStyleMaskTitled equivalent
            return WINDOW_CLASS_STANDARD;
        }
    }
    
    // Default to standard if it passes basic size/visibility tests
    if ((width && [width intValue] >= 100) && 
        (height && [height intValue] >= 100) && 
        (alpha && [alpha doubleValue] >= 0.3)) {
        return WINDOW_CLASS_STANDARD;
    }
    
    // When in doubt, treat as helper window
    return WINDOW_CLASS_HELPER;
}

// Check if a window is fully initialized
static bool isWindowInitialized(CGSWindowID windowID) {
    if (!window_states) {
        return false;
    }
    
    NSNumber *key = @(windowID);
    if (!CFDictionaryContainsKey(window_states, (__bridge CFNumberRef)key)) {
        return false;
    }
    
    window_init_state_t *state = (window_init_state_t *)CFDictionaryGetValue(
        window_states, (__bridge CFNumberRef)key);
    
    return state->is_initialized;
}

// Update application initialization state based on window events - Phase 4 implementation with complete state machine
static void updateInitializationState(int eventType, CGSWindowID windowID) {
    // Get window info and class
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    window_class_t windowClass = determineWindowClass(windowID, windowInfo);
    
    // For phase 4, we're adding tracking of important windows - store the window ID for later reference
    static CGSWindowID mainWindowID = 0;
    static NSMutableArray *standardWindowIDs = nil;
    
    // Initialize the array if needed
    if (!standardWindowIDs) {
        standardWindowIDs = [[NSMutableArray alloc] init];
    }
    
    // Check if this is a standard window and add it to our tracking if not already there
    if (windowClass == WINDOW_CLASS_STANDARD && 
        ![standardWindowIDs containsObject:@(windowID)]) {
        [standardWindowIDs addObject:@(windowID)];
        printf("[Modifier] Added standard window %d to tracking (total: %lu)\n", 
              windowID, (unsigned long)[standardWindowIDs count]);
    }
    
    // Update state machine based on current state, event, and window properties
    switch (current_init_state) {
        case APP_INIT_NOT_STARTED:
            // Any window event moves us to the first state
            current_init_state = APP_INIT_FIRST_WINDOW_CREATING;
            printf("[Modifier] App initialization started (first window event detected)\n");
            break;
            
        case APP_INIT_FIRST_WINDOW_CREATING:
            // When we see a standard window that's fully initialized, consider first window complete
            if (windowClass == WINDOW_CLASS_STANDARD) {
                bool initialized = isWindowInitialized(windowID);
                
                // Enhanced logging
                printf("[Modifier] Standard window %d detected during initial phase (initialized: %s)\n", 
                       windowID, initialized ? "yes" : "no");
                
                if (initialized) {
                    // Count all initialized standard windows
                    main_window_count = 0;
                    for (NSNumber *winIDObj in standardWindowIDs) {
                        CGSWindowID trackedWinID = [winIDObj unsignedIntValue];
                        if (isWindowInitialized(trackedWinID)) {
                            main_window_count++;
                        }
                    }
                    
                    // Now we have at least one initialized window
                    current_init_state = APP_INIT_FIRST_WINDOW_COMPLETE;
                    printf("[Modifier] First window phase complete (initialized standard windows: %d)\n", 
                           main_window_count);
                }
            }
            break;
            
        case APP_INIT_FIRST_WINDOW_COMPLETE:
            // For a more robust approach, we'll detect the main application window based
            // on events and properties, rather than just looking for the next window
            
            // If we see a large standard window being created/becoming visible, it's likely the main window
            if ((eventType == kCGSWindowDidCreateNotification || 
                 eventType == kCGSWindowDidOrderInNotification) && 
                windowClass == WINDOW_CLASS_STANDARD) {
                
                // Get size information - main window is typically larger
                NSNumber *width = windowInfo[@"kCGSWindowWidth"];
                NSNumber *height = windowInfo[@"kCGSWindowHeight"];
                
                // Check if this looks like a main window (substantial size)
                if (width && height && 
                    [width intValue] >= 400 && [height intValue] >= 300) {
                    
                    mainWindowID = windowID;
                    current_init_state = APP_INIT_MAIN_WINDOW_CREATING;
                    printf("[Modifier] Potential main window (%d) detected (%d x %d)\n", 
                          windowID, [width intValue], [height intValue]);
                }
            }
            break;
            
        case APP_INIT_MAIN_WINDOW_CREATING:
            // The main window is considered ready when it's updated, has content, and is initialized
            
            // Track updates to the main window we identified
            if (windowID == mainWindowID) {
                // General update events are a good sign the window is getting ready
                if (eventType == kCGSWindowDidUpdateNotification || 
                    eventType == kCGSWindowDidResizeNotification) {
                    
                    // Check if it's fully initialized
                    if (isWindowInitialized(windowID)) {
                        current_init_state = APP_INIT_COMPLETE;
                        printf("[Modifier] Application fully initialized (main window ready)\n");
                    } else {
                        printf("[Modifier] Main window progressing but not yet fully initialized\n");
                    }
                }
            }
            
            // If we have multiple initialized standard windows, that's also a good
            // indication the app is ready even if we haven't positively ID'd the main window
            if (main_window_count >= 2) {
                current_init_state = APP_INIT_COMPLETE;
                printf("[Modifier] Application considered initialized (multiple standard windows ready)\n");
            }
            break;
            
        case APP_INIT_COMPLETE:
            // No state changes needed, but we'll continue tracking windows
            
            // For diagnostics, count initialized windows periodically
            static time_t last_count_time = 0;
            time_t now = time(NULL);
            
            if (now - last_count_time >= 5) { // Every 5 seconds
                main_window_count = 0;
                for (NSNumber *winIDObj in standardWindowIDs) {
                    CGSWindowID trackedWinID = [winIDObj unsignedIntValue];
                    if (isWindowInitialized(trackedWinID)) {
                        main_window_count++;
                    }
                }
                
                printf("[Modifier] Application status: %d initialized standard windows\n", main_window_count);
                last_count_time = now;
            }
            break;
    }
    
    // Clean up closed or invalid windows from our tracking array
    NSMutableIndexSet *indicesToRemove = [NSMutableIndexSet indexSet];
    [standardWindowIDs enumerateObjectsUsingBlock:^(NSNumber *winIDObj, NSUInteger idx, BOOL *stop) {
        CGSWindowID trackedWinID = [winIDObj unsignedIntValue];
        
        // If we can't get window info, it's likely gone
        if (!getWindowInfoWithCGS(trackedWinID)) {
            [indicesToRemove addIndex:idx];
            printf("[Modifier] Removing window %d from tracking (no longer exists)\n", trackedWinID);
        }
    }];
    
    // Remove all marked indices
    if ([indicesToRemove count] > 0) {
        [standardWindowIDs removeObjectsAtIndexes:indicesToRemove];
    }
}

// Check if a window is ready for modification
static bool isWindowReadyForModification(CGSWindowID windowID) {
    if (!CGSDefaultConnection_ptr || !CGSCopyWindowDescriptionList_ptr) {
        return true; // If we can't check, assume it's ready
    }
    
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    if (!windowInfo) {
        return false; // Can't get window info, not ready
    }
    
    // Check window properties
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
    NSNumber *width = windowInfo[@"kCGSWindowWidth"];
    NSNumber *height = windowInfo[@"kCGSWindowHeight"];
    
    // Basic requirements
    BOOL isVisible = [alpha doubleValue] > 0.0;
    BOOL isMainLayer = [windowLayer intValue] == 0;
    BOOL hasReasonableSize = [width intValue] > 100 && [height intValue] > 100;
    
    return isVisible && isMainLayer && hasReasonableSize;
}

// Detect process role based on executable path
static process_role_t detectProcessRole(void) {
    const char* processPath = getprogname();
    if (!processPath) {
        return PROCESS_ROLE_MAIN;
    }
    
    // Extract process name from path
    const char* processName = strrchr(processPath, '/');
    if (processName) {
        processName++; // Skip '/'
    } else {
        processName = processPath;
    }
    
    // Check for utility/helper processes by name patterns
    if ((strstr(processName, "Helper") || strstr(processName, "helper")) && (
        strstr(processName, "GPU") || 
        strstr(processName, "Gpu") ||
        strstr(processName, "gpu") ||
        strstr(processName, "Utility") || 
        strstr(processName, "utility") ||
        strstr(processName, "Plugin") || 
        strstr(processName, "plugin"))) {
        return PROCESS_ROLE_UTILITY;
    }
    
    // Check for renderer processes
    if (strstr(processName, "Renderer") || 
        strstr(processName, "renderer") ||
        strstr(processName, "WebProcess") ||
        strstr(processName, "WebContent")) {
        return PROCESS_ROLE_UI;
    }
    
    // If it's the main executable, it's likely the main process
    if (strstr(processPath, ".app/Contents/MacOS/")) {
        return PROCESS_ROLE_MAIN;
    }
    
    return PROCESS_ROLE_MAIN; // Default
}

// Check if a window should be treated as a utility window (not a main application window)
static bool isUtilityWindow(CGSWindowID windowID) {
    // First, check if we have this window in our tracking system
    if (window_states) {
        NSNumber *key = @(windowID);
        if (CFDictionaryContainsKey(window_states, (__bridge CFNumberRef)key)) {
            window_init_state_t *state = (window_init_state_t *)CFDictionaryGetValue(
                window_states, (__bridge CFNumberRef)key);
            
            // Use the window classification to determine if it's a utility window
            switch (state->window_class) {
                case WINDOW_CLASS_PANEL:
                case WINDOW_CLASS_SHEET:
                case WINDOW_CLASS_SYSTEM:
                case WINDOW_CLASS_HELPER:
                    return true;
                    
                case WINDOW_CLASS_STANDARD:
                    return false;
                    
                case WINDOW_CLASS_UNKNOWN:
                    // Fall through to legacy checks for unknown classification
                    break;
            }
        }
    }
    
    // Fall back to legacy property-based detection if not tracked or unknown class
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    if (!windowInfo) {
        return false;
    }
    
    // Extract window metadata
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    NSNumber *width = windowInfo[@"kCGSWindowWidth"];
    NSNumber *height = windowInfo[@"kCGSWindowHeight"];
    NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
    
    // Visibility, size, and layer checks (same logic as window classification)
    if ((windowLayer && [windowLayer intValue] != 0) ||
        ([width intValue] < 100 || [height intValue] < 100) ||
        ([alpha doubleValue] < 0.3)) {
        return true;
    }
    
    return false;
}

// Check if the application is fully initialized - Phase 4 implementation prioritizing window state
static bool isApplicationInitialized(void) {
    // Get current time for timeout calculations
    time_t now = time(NULL);
    
    // Phase 4: Multi-layered approach to initialization detection
    
    // Layer 1: State machine - most accurate when working correctly
    if (current_init_state >= APP_INIT_FIRST_WINDOW_COMPLETE) {
        return true;
    }
    
    // Layer 2: Window count heuristic - apps with multiple standard windows are likely initialized
    int standard_window_count = 0;
    int initialized_window_count = 0;
    
    if (window_states) {
        // Count standard and initialized windows
        CFDictionaryApplyFunction(window_states, countInitializedStandardWindows, &initialized_window_count);
        
        // Count all standard windows (initialized or not)
        CFDictionaryApplyFunction(window_states, countStandardWindows, &standard_window_count);
        
        // Update global counter for other functions to use
        main_window_count = initialized_window_count;
        
        // Heuristic based on window counts
        if (initialized_window_count >= 1) {
            // We have at least one fully initialized standard window
            printf("[Modifier] App considered initialized: %d initialized standard window(s)\n", 
                  initialized_window_count);
                  
            // Update state machine to match reality
            if (current_init_state < APP_INIT_FIRST_WINDOW_COMPLETE) {
                current_init_state = APP_INIT_FIRST_WINDOW_COMPLETE;
            }
            
            return true;
        }
        
        if (standard_window_count >= 3) {
            // Multiple standard windows usually indicate the app is up and running
            printf("[Modifier] App considered initialized: multiple standard windows detected (%d)\n", 
                  standard_window_count);
                  
            // Update state machine to match reality
            if (current_init_state < APP_INIT_FIRST_WINDOW_COMPLETE) {
                current_init_state = APP_INIT_FIRST_WINDOW_COMPLETE;
