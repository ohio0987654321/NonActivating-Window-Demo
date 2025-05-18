// window_modifier.m - Enhanced for multi-process applications
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>
#include "window_registry.h"

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

// Forward declarations to fix compilation issues
static NSDictionary *getWindowInfoWithCGS(CGSWindowID windowID);
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry);

// Process role detection
typedef enum {
    PROCESS_ROLE_MAIN,       // Main application process
    PROCESS_ROLE_RENDERER,   // UI rendering process
    PROCESS_ROLE_UTILITY,    // Background service process
    PROCESS_ROLE_PLUGIN,     // Plugin process
    PROCESS_ROLE_UNKNOWN     // Unknown role
} process_role_t;

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
static retry_window_t retry_windows[32];
static int retry_window_count = 0;
static double retry_delays[] = {0.1, 0.3, 0.6, 1.0, 2.0}; // Progressive delays in seconds
static const int max_retry_attempts = 5;
static process_role_t current_process_role = PROCESS_ROLE_UNKNOWN;
static time_t process_start_time = 0;
static int modified_window_count = 0;
static const int STARTUP_PROTECTION_SECONDS = 5; // Base protection period for processes
static const int RENDERER_STARTUP_PROTECTION_SECONDS = 15; // Longer protection for renderers
static const int FIRST_WINDOWS_PROTECTION_COUNT = 3; // Skip first N windows in renderer processes

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

// Check if a window is ready for modification
static bool isWindowReadyForModification(CGSWindowID windowID) {
    if (!CGSDefaultConnection_ptr || !CGSCopyWindowDescriptionList_ptr) {
        return true; // If we can't check, assume it's ready
    }
    
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    if (!windowInfo) {
        return false; // Can't get window info, not ready
    }
    
    // Check window properties more comprehensively
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
    NSNumber *width = windowInfo[@"kCGSWindowWidth"];
    NSNumber *height = windowInfo[@"kCGSWindowHeight"];
    NSString *windowType = windowInfo[@"kCGSWindowType"];
    NSNumber *isOnAllSpaces = windowInfo[@"kCGSWindowIsOnAllWorkspaces"];
    NSString *sharingState = windowInfo[@"kCGSWindowSharingState"];
    NSString *windowTitle = windowInfo[@"kCGSWindowTitle"];
    
    // Log extended window information for debugging
    printf("[Modifier] Window %d readiness check: alpha=%.2f, layer=%s, size=%dx%d, type=%s\n",
           windowID, 
           [alpha doubleValue],
           [windowLayer UTF8String],
           [width intValue], [height intValue],
           [windowType UTF8String]);
    
    if (windowTitle) {
        printf("[Modifier] Window %d title: %s\n", windowID, [windowTitle UTF8String]);
    }
    
    // More strict requirements for window readiness:
    // 1. Window must be visible (alpha > 0)
    BOOL isVisible = [alpha doubleValue] > 0.0;
    
    // 2. Window must be on the main layer (0) - higher layers are for special windows
    // Layer 0 = normal window, Layer 1000 = system UI, Layer 1001 = dock, etc.
    BOOL isMainLayer = [windowLayer intValue] == 0;
    
    // 3. Window must have reasonable dimensions (not tiny utility or offscreen)
    BOOL hasReasonableSize = [width intValue] > 100 && [height intValue] > 100;
    
    // 4. Check window type (if available)
    BOOL isNormalWindowType = YES;
    if (windowType) {
        // Avoid special window types
        isNormalWindowType = !([windowType containsString:@"MenuWindow"] || 
                              [windowType containsString:@"AlertWindow"] ||
                              [windowType containsString:@"DragWindow"] ||
                              [windowType containsString:@"OverlayWindow"] ||
                              [windowType containsString:@"HelpWindow"]);
    }
    
    // 5. Avoid windows that are set to appear on all spaces (often utilities)
    BOOL isNotOnAllSpaces = (isOnAllSpaces == nil) || [isOnAllSpaces boolValue] == NO;
    
    // 6. Check sharing state for special windows
    BOOL hasNormalSharing = YES;
    if (sharingState) {
        // Some special utility windows have unusual sharing states
        int sharingStateVal = [sharingState intValue];
        hasNormalSharing = (sharingStateVal != 1 && sharingStateVal != 2);
    }
    
    // Combine all checks for a comprehensive window readiness assessment
    return isVisible && isMainLayer && hasReasonableSize && 
           isNormalWindowType && isNotOnAllSpaces && hasNormalSharing;
}

// Add a window to the retry queue
static void addWindowToRetryQueue(CGSWindowID windowID) {
    // Check if window is already in the queue
    for (int i = 0; i < retry_window_count; i++) {
        if (retry_windows[i].windowID == windowID) {
            // Already in queue, update next attempt time
            retry_windows[i].attempts++;
            
            if (retry_windows[i].attempts < max_retry_attempts) {
                int delayIndex = retry_windows[i].attempts < 5 ? retry_windows[i].attempts : 4;
                double delayTime = retry_delays[delayIndex];
                
                struct timeval tv;
                gettimeofday(&tv, NULL);
                double currentTime = tv.tv_sec + (tv.tv_usec / 1000000.0);
                
                retry_windows[i].next_attempt_time = currentTime + delayTime;
                
                printf("[Modifier] Window %d scheduled for retry %d in %.1f seconds\n", 
                       windowID, retry_windows[i].attempts, delayTime);
            } else {
                printf("[Modifier] Window %d max retries reached, abandoning\n", windowID);
                
                // Remove from queue by swapping with last entry
                retry_windows[i] = retry_windows[retry_window_count - 1];
                retry_window_count--;
            }
            return;
        }
    }
    
    // Add new entry if we have space
    if (retry_window_count < 32) {
        retry_windows[retry_window_count].windowID = windowID;
        retry_windows[retry_window_count].attempts = 0;
        
        struct timeval tv;
        gettimeofday(&tv, NULL);
        double currentTime = tv.tv_sec + (tv.tv_usec / 1000000.0);
        
        retry_windows[retry_window_count].next_attempt_time = currentTime + retry_delays[0];
        
        printf("[Modifier] Window %d added to retry queue (will retry in %.1f seconds)\n", 
               windowID, retry_delays[0]);
        
        retry_window_count++;
    }
}

// Process the retry queue
static void processRetryQueue(void) {
    if (retry_window_count == 0) {
        return;
    }
    
    struct timeval tv;
    gettimeofday(&tv, NULL);
    double currentTime = tv.tv_sec + (tv.tv_usec / 1000000.0);
    
    printf("[Modifier] Processing retry queue (%d windows)\n", retry_window_count);
    
    // Process the queue from the end to make removals easier
    for (int i = retry_window_count - 1; i >= 0; i--) {
        if (currentTime >= retry_windows[i].next_attempt_time) {
            CGSWindowID windowID = retry_windows[i].windowID;
            
            printf("[Modifier] Retrying window %d (attempt %d)\n", 
                   windowID, retry_windows[i].attempts + 1);
            
            // Check if the window is ready and if so, try to modify it
            if (isWindowReadyForModification(windowID)) {
                if (modifyWindowWithCGSInternal(windowID, true)) {
                    // Success! Remove from queue
                    retry_windows[i] = retry_windows[retry_window_count - 1];
                    retry_window_count--;
                } else {
                    // Failed again, update for next retry
                    retry_windows[i].attempts++;
                    
                    if (retry_windows[i].attempts < max_retry_attempts) {
                        int delayIndex = retry_windows[i].attempts < 5 ? retry_windows[i].attempts : 4;
                        retry_windows[i].next_attempt_time = currentTime + retry_delays[delayIndex];
                    } else {
                        // Max retries reached, remove from queue
                        retry_windows[i] = retry_windows[retry_window_count - 1];
                        retry_window_count--;
                    }
                }
            } else {
                // Window not ready yet, schedule next attempt
                retry_windows[i].next_attempt_time = currentTime + retry_delays[0];
            }
        }
    }
}

// Internal implementation of window modification (without retry handling)
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry) {
    if (!CGSDefaultConnection_ptr || windowID == 0) return false;
    
    // Check if we already modified this window in any process
    if (window_registry && registry_is_window_modified(window_registry, windowID)) {
        if (!isRetry) {
            printf("[Modifier] Window %d already modified, skipping\n", windowID);
        }
        return true;
    }
    
    CGSConnectionID cid = CGSDefaultConnection_ptr();
    bool success = true;
    
    // 1. Apply non-activating (prevent stealing focus)
    if (CGSSetWindowTags_ptr) {
        int tags[1] = { kCGSPreventsActivationTagBit };
        CGError err = CGSSetWindowTags_ptr(cid, windowID, tags, 1);
        
        if (err != 0) {
            printf("[Modifier] Warning: Failed to set non-activating for window %d (error: %d)\n", 
                   windowID, err);
            success = false;
        } else {
            printf("[Modifier] Set window %d as non-activating\n", windowID);
        }
    }
    
    // 2. Always-on-top (floating window level)
    if (CGSSetWindowLevel_ptr) {
        CGError err = CGSSetWindowLevel_ptr(cid, windowID, kCGSWindowLevelForKey);
        
        if (err != 0) {
            printf("[Modifier] Warning: Failed to set window level for window %d (error: %d)\n", 
                   windowID, err);
            success = false;
        } else {
            printf("[Modifier] Set window %d as always-on-top\n", windowID);
        }
    }
    
    // 3. Screen capture bypass
    if (CGSSetWindowSharingState_ptr) {
        CGError err = CGSSetWindowSharingState_ptr(cid, windowID, kCGSWindowSharingNoneValue);
        
        if (err != 0) {
            printf("[Modifier] Warning: Failed to set screen capture bypass for window %d (error: %d)\n", 
                   windowID, err);
            success = false;
        } else {
            printf("[Modifier] Set window %d with screen capture bypass\n", windowID);
        }
    }
    
    if (success && window_registry) {
        // Mark the window as modified in our registry
        registry_mark_window_modified(window_registry, windowID);
        
        // Track that we've modified another window
        modified_window_count++;
    }
    
    return success;
}

// Detect process role based on executable path and other heuristics
static process_role_t detectProcessRole(void) {
    const char* processPath = getprogname();
    if (!processPath) {
        return PROCESS_ROLE_UNKNOWN;
    }
    
    // Extract process name from path
    const char* processName = strrchr(processPath, '/');
    if (processName) {
        processName++; // Skip '/'
    } else {
        processName = processPath;
    }
    
    // Enhanced detection for Discord and Electron apps
    // Discord has multiple renderers, GPU helpers, network services, etc.
    
    // Check for utility/helper processes by name patterns (expanded for Discord)
    if ((strstr(processName, "Helper") || strstr(processName, "helper")) && (
        strstr(processName, "GPU") || 
        strstr(processName, "Gpu") ||
        strstr(processName, "gpu") ||
        strstr(processName, "Utility") || 
        strstr(processName, "utility") ||
        strstr(processName, "Plugin") || 
        strstr(processName, "plugin") ||
        strstr(processName, "crashpad") ||
        strstr(processName, "Crashpad") ||
        strstr(processName, "Network") ||
        strstr(processName, "network") ||
        strstr(processName, "Service") ||
        strstr(processName, "service")
    )) {
        printf("[Modifier] Detected utility process: %s\n", processName);
        return PROCESS_ROLE_UTILITY;
    }
    
    // Check for renderer processes - expanded for all Electron apps
    if (strstr(processName, "Renderer") || 
        strstr(processName, "renderer") ||
        strstr(processName, "WebProcess") ||
        strstr(processName, "WebContent")) {
        printf("[Modifier] Detected renderer process: %s\n", processName);
        return PROCESS_ROLE_RENDERER;
    }
    
    // Special handling for Discord/Electron plugin processes
    if (strstr(processName, "Discord") && strstr(processPath, "Plugin")) {
        printf("[Modifier] Detected plugin process: %s\n", processName);
        return PROCESS_ROLE_PLUGIN;
    }
    
    // If it's the main executable of an app bundle, it's likely the main process
    if (strstr(processPath, ".app/Contents/MacOS/")) {
        printf("[Modifier] Detected main process: %s\n", processName);
        return PROCESS_ROLE_MAIN;
    }
    
    // If we can't determine definitely, log more info
    printf("[Modifier] Unknown process role - path: %s, name: %s\n", 
           processPath, processName);
    
    return PROCESS_ROLE_UNKNOWN;
}

// Check if a window belongs to a network service or critical system process
static bool isUtilityWindow(CGSWindowID windowID) {
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    if (!windowInfo) {
        return false;
    }
    
    // Extract comprehensive window metadata
    NSString *windowName = windowInfo[@"kCGSWindowTitle"];
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    NSNumber *width = windowInfo[@"kCGSWindowWidth"];
    NSNumber *height = windowInfo[@"kCGSWindowHeight"];
    NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
    NSString *sharingState = windowInfo[@"kCGSWindowSharingState"];
    NSString *windowType = windowInfo[@"kCGSWindowType"];
    NSNumber *isOnAllSpaces = windowInfo[@"kCGSWindowIsOnAllWorkspaces"];
    NSString *ownerName = windowInfo[@"kCGSOwnerName"];
    NSString *memoryUsage = windowInfo[@"kCGSWindowMemoryUsage"];
    NSString *windowTags = windowInfo[@"kCGSWindowTags"];
    NSString *windowWorkspace = windowInfo[@"kCGSWindowWorkspace"];
    
    // Log comprehensive window info for analysis
    printf("[Modifier] Analyzing window %d for utility classification:\n", windowID);
    printf("  - Title: %s\n", windowName ? [windowName UTF8String] : "(none)");
    printf("  - Type: %s\n", windowType ? [windowType UTF8String] : "(none)");
    printf("  - Owner: %s\n", ownerName ? [ownerName UTF8String] : "(none)");
    printf("  - Size: %dx%d\n", [width intValue], [height intValue]);
    printf("  - Alpha: %.2f\n", [alpha doubleValue]);
    printf("  - Layer: %s\n", windowLayer ? [windowLayer UTF8String] : "(none)");
    
    // CRITERION 1: Layer-based detection (non-zero layers are special system windows)
    // Window Server layers:
    // 0 = Normal application windows
    // 1-999 = Special window layers
    // 1000+ = System UI layers (menu bar, dock, etc.)
    if (windowLayer && [windowLayer intValue] != 0) {
        printf("[Modifier] Window %d identified as utility window: non-standard layer %s\n", 
               windowID, [windowLayer UTF8String]);
        return true;
    }
    
    // CRITERION 2: Size-based detection (tiny windows are often internal utility windows)
    if ([width intValue] < 100 || [height intValue] < 100) {
        printf("[Modifier] Window %d identified as utility window: small size %dx%d\n", 
              windowID, [width intValue], [height intValue]);
        return true;
    }
    
    // CRITERION 3: Visibility-based detection (nearly invisible windows are often utilities)
    if ([alpha doubleValue] < 0.3) {
        printf("[Modifier] Window %d identified as utility window: low alpha %.2f\n", 
              windowID, [alpha doubleValue]);
        return true;
    }
    
    // CRITERION 4: Window type detection (special window types)
    if (windowType) {
        if ([windowType containsString:@"Menu"] ||
            [windowType containsString:@"Alert"] ||
            [windowType containsString:@"Drag"] ||
            [windowType containsString:@"Overlay"] ||
            [windowType containsString:@"Help"] ||
            [windowType containsString:@"Panel"] ||
            [windowType containsString:@"Popup"] ||
            [windowType containsString:@"Tooltip"]) {
            
            printf("[Modifier] Window %d identified as utility window: special type %s\n", 
                   windowID, [windowType UTF8String]);
            return true;
        }
    }
    
    // CRITERION 5: Title-based detection for special windows
    if (windowName) {
        // Detect windows with service-related names
        if ([windowName containsString:@"service"] ||
            [windowName containsString:@"Service"] ||
            [windowName containsString:@"helper"] ||
            [windowName containsString:@"Helper"] ||
            [windowName containsString:@"network"] ||
            [windowName containsString:@"Network"] ||
            [windowName containsString:@"crash"] ||
            [windowName containsString:@"Crash"] ||
            [windowName containsString:@"plugin"] ||
            [windowName containsString:@"Plugin"] ||
            [windowName containsString:@"utility"] ||
            [windowName containsString:@"Utility"]
            ) {
            
            printf("[Modifier] Window %d identified as utility window: special title %s\n", 
                   windowID, [windowName UTF8String]);
            return true;
        }
    }
    
    // CRITERION 6: Special workspace/visibility attributes  
    if (isOnAllSpaces && [isOnAllSpaces boolValue]) {
        // Windows that appear on all spaces are often utilities
        printf("[Modifier] Window %d identified as utility window: present on all spaces\n", windowID);
        return true;
    }
    
    // This appears to be a normal application window that we can safely modify
    printf("[Modifier] Window %d classified as normal application window\n", windowID);
    return false;
}

// Check if we're in startup protection period
static bool isInStartupProtection(void) {
    // If process role is utility, always in protection (never modify their windows)
    if (current_process_role == PROCESS_ROLE_UTILITY) {
        return true;
    }
    
    // Extra protection for renderer processes
    if (current_process_role == PROCESS_ROLE_RENDERER) {
        // Protect the first few windows created by a renderer process
        // This prevents interference with critical network service initialization
        if (modified_window_count < FIRST_WINDOWS_PROTECTION_COUNT) {
            printf("[Modifier] Early renderer window protection (%d/%d windows protected)\n", 
                   modified_window_count + 1, FIRST_WINDOWS_PROTECTION_COUNT);
            return true;
        }
        
        // Longer startup protection period for renderer processes
        time_t now = time(NULL);
        if (now - process_start_time < RENDERER_STARTUP_PROTECTION_SECONDS) {
            return true;
        }
    } else {
        // Standard startup protection for other processes
        time_t now = time(NULL);
        if (now - process_start_time < STARTUP_PROTECTION_SECONDS) {
            return true;
        }
    }
    
    return false;
}

// Apply window modifications directly using CGS APIs (with retry handling)
static bool modifyWindowWithCGS(CGSWindowID windowID) {
    // Check for startup protection period
    if (isInStartupProtection()) {
        printf("[Modifier] Window %d skipped - in startup protection period\n", windowID);
        // For main process windows during startup, add to retry queue to try later
        if (current_process_role != PROCESS_ROLE_UTILITY) {
            addWindowToRetryQueue(windowID);
        }
        return false;
    }
    
    // Check if this is a utility/service window
    if (isUtilityWindow(windowID)) {
        printf("[Modifier] Window %d skipped - detected as utility window\n", windowID);
        return false;
    }
    
    // First check if window is ready for modification
    if (!isWindowReadyForModification(windowID)) {
        printf("[Modifier] Window %d not ready for modification, adding to retry queue\n", windowID);
        addWindowToRetryQueue(windowID);
        return false;
    }
    
    // Try to modify the window
    bool success = modifyWindowWithCGSInternal(windowID, false);
    
    // If modification failed, add to retry queue
    if (!success) {
        printf("[Modifier] Window %d modification failed, adding to retry queue\n", windowID);
        addWindowToRetryQueue(windowID);
    }
    
    return success;
}

// Apply modifications to an NSWindow using both AppKit and CGS
static bool modifyNSWindow(NSWindow *window) {
    if (!window) return false;
    
    CGSWindowID windowID = (CGSWindowID)[window windowNumber];
    
    // Check if we already modified this window in any process
    if (window_registry && registry_is_window_modified(window_registry, windowID)) {
        return true;
    }
    
    // 1. Non-activating behavior
    if ([window respondsToSelector:@selector(_setPreventsActivation:)]) {
        [window _setPreventsActivation:YES];
        printf("[Modifier] Applied _setPreventsActivation:YES to window %p\n", (__bridge void*)window);
    } else {
        // Fall back to CGS for non-activating behavior
        if (CGSDefaultConnection_ptr && CGSSetWindowTags_ptr) {
            CGSConnectionID cid = CGSDefaultConnection_ptr();
            int tags[1] = { kCGSPreventsActivationTagBit };
            CGSSetWindowTags_ptr(cid, windowID, tags, 1);
        }
    }
    
    // 2. Always-on-top behavior
    window.level = NSFloatingWindowLevel;
    
    // 3. Screen capture bypass
    window.sharingType = NSWindowSharingNone;
    
    // 4. Mission control compatibility
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | 
                               NSWindowCollectionBehaviorParticipatesInCycle | 
                               NSWindowCollectionBehaviorManaged;
    
    // 5. Panel-specific settings (for NSPanel)
    if ([window isKindOfClass:[NSPanel class]]) {
        NSPanel *panel = (NSPanel *)window;
        [panel setBecomesKeyOnlyIfNeeded:YES];
        [panel setWorksWhenModal:YES];
        [panel setHidesOnDeactivate:NO];
        printf("[Modifier] Applied panel settings to panel %p\n", (__bridge void*)panel);
    } else {
        printf("[Modifier] Applied window settings to window %p\n", (__bridge void*)window);
    }
    
    // Mark the window as modified in our registry
    if (window_registry) {
        registry_mark_window_modified(window_registry, windowID);
        modified_window_count++;
    }
    
    return true;
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

// CGS Window Notification callback
static void cgsWindowNotificationCallback(int type, void *data, uint32_t data_length, void *arg) {
    if (!data || data_length < sizeof(CGSWindowID)) {
        return;
    }
    
    CGSWindowID windowID = *(CGSWindowID *)data;
    
    if (type == kCGSWindowDidCreateNotification || type == kCGSWindowDidOrderInNotification) {
        // Get information about the window
        NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
        
        if (windowInfo) {
            // Check if this is a suitable window to modify
            NSString *ownerName = windowInfo[@"kCGSOwnerName"];
            NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
            NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
            
            BOOL isVisible = [alpha doubleValue] > 0.0;
            BOOL isMainLayer = [windowLayer intValue] == 0;
            
            printf("[Modifier] CGS detected window %d (owner: %s, visible: %d, layer: %s)\n", 
                   windowID, [ownerName UTF8String], isVisible, [windowLayer UTF8String]);
            
            // Only modify visible, main-layer windows
            if (isVisible && isMainLayer) {
                modifyWindowWithCGS(windowID);
            }
        } else {
            // If we can't get info, try to modify anyway
            modifyWindowWithCGS(windowID);
        }
    }
}

// Set up CGS window notification monitoring with enhanced error handling
static bool setupCGSWindowMonitoring(void) {
    if (!CGSRegisterNotifyProc_ptr || !CGSDefaultConnection_ptr) {
        printf("[Modifier] Cannot setup CGS monitoring: functions not available\n");
        return false;
    }
    
    if (is_cgs_monitor_active) {
        printf("[Modifier] CGS monitoring already active\n");
        return true;
    }
    
    // For multi-process applications like Discord or Electron apps, 
    // CGS notification registration often fails with error 1000 (permission issue)
    // This is expected and we handle it gracefully with our fallback mechanisms
    
    // Attempt to register for various window notifications with enhanced error handling
    const int notification_types[] = {
        kCGSWindowDidCreateNotification,
        kCGSWindowDidOrderInNotification,
        kCGSWindowDidUpdateNotification, // Try this additional notification type
        kCGSWindowDidResizeNotification  // And this one
    };
    const char* notification_names[] = {
        "create", "order-in", "update", "resize"
    };
    
    bool any_registration_successful = false;
    int registered_count = 0;
    
    // Try each notification type
    for (int i = 0; i < 4; i++) {
        CGError err = CGSRegisterNotifyProc_ptr(cgsWindowNotificationCallback, 
                                               notification_types[i], 
                                               NULL);
        
        if (err == 0) {
            // Success
            registered_count++;
            any_registration_successful = true;
            printf("[Modifier] Successfully registered for window %s notifications\n", 
                   notification_names[i]);
        } else if (err == 1000) {
            // Permission error - very common in sandboxed/restricted processes
            printf("[Modifier] Expected permission error (%d) registering for %s notifications\n", 
                   err, notification_names[i]);
        } else {
            // Other error
            printf("[Modifier] Failed to register for window %s notifications: %d\n", 
                   notification_names[i], err);
        }
    }
    
    // Always activate monitoring regardless of registration success
    // We'll rely on our fallback mechanisms
    is_cgs_monitor_active = true;
    
    if (any_registration_successful) {
        printf("[Modifier] CGS window monitoring activated with %d notification types\n", 
               registered_count);
    } else {
        // If no registrations succeeded, we'll rely completely on periodic scanning
        printf("[Modifier] CGS notifications unavailable - using periodic scanning as fallback\n");
        printf("[Modifier] This is normal for restricted processes like Discord's renderer\n");
        
        // Increase scanning frequency for better responsiveness when notifications fail
        // This will be handled in the main loop
    }
    
    return true;
}

// Scan for existing windows using CGS
static void scanExistingWindowsWithCGS(void) {
    if (!CGSGetOnScreenWindowList_ptr || !CGSDefaultConnection_ptr) {
        printf("[Modifier] Cannot scan windows: CGS functions not available\n");
        return;
    }
    
    CGSConnectionID cid = CGSDefaultConnection_ptr();
    const int maxWindows = 256;
    CGSWindowID windowList[maxWindows];
    int windowCount = 0;
    
    CGError err = CGSGetOnScreenWindowList_ptr(cid, cid, maxWindows, windowList, &windowCount);
    
    if (err != 0) {
        printf("[Modifier] Failed to get window list: %d\n", err);
        return;
    }
    
    printf("[Modifier] Found %d windows via CGS\n", windowCount);
    
    for (int i = 0; i < windowCount; i++) {
        CGSWindowID windowID = windowList[i];
        
        // Get window info to see if we should modify it
        NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
        
        if (windowInfo) {
            NSString *ownerName = windowInfo[@"kCGSOwnerName"];
            NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
            NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
            
            BOOL isVisible = [alpha doubleValue] > 0.0;
            BOOL isMainLayer = [windowLayer intValue] == 0;
            
            // Only modify visible, main-layer windows
            if (isVisible && isMainLayer) {
                printf("[Modifier] CGS scan found window %d (owner: %s)\n", 
                       windowID, [ownerName UTF8String]);
                modifyWindowWithCGS(windowID);
            }
        }
    }
}

// Apply modifications to all NSWindows
bool applyAllWindowModifications(void) {
    saveFrontmostApp();
    
    // First, try to modify via AppKit if available
    if (NSApp) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Apply to each window
            for (NSWindow *window in [NSApp windows]) {
                modifyNSWindow(window);
            }
            
            // Return to focus on previous application
            restoreFrontmostApp();
        });
    }
    
    // Also scan for windows using CGS for frameworks that don't use AppKit
    // or windows from other processes
    scanExistingWindowsWithCGS();
    
    return true;
}

// Method swizzling for window creation detection
static void setupWindowMethodSwizzling(void) {
    Class windowClass = [NSWindow class];
    
    // Methods to swizzle for detecting window creation/display
    SEL selectors[] = {
        @selector(orderFront:),
        @selector(makeKeyAndOrderFront:),
        @selector(makeKeyWindow)
    };
    
    const char *selectorNames[] = {
        "orderFront:",
        "makeKeyAndOrderFront:",
        "makeKeyWindow"
    };
    
    for (int i = 0; i < 3; i++) {
        Method method = class_getInstanceMethod(windowClass, selectors[i]);
        
        if (!method) {
            printf("[Modifier] Method %s not found\n", selectorNames[i]);
            continue;
        }
        
        // Get original implementation
        IMP originalImp = method_getImplementation(method);
        
        // Capture the selector outside the block
        SEL currentSelector = selectors[i];
        
        // Create new implementation
        IMP newImp = imp_implementationWithBlock(^(id self, id sender) {
            // Call original method
            ((void (*)(id, SEL, id))originalImp)(self, currentSelector, sender);
            
            // Now that the window has appeared, modify it
            modifyNSWindow((NSWindow *)self);
        });
        
        // Replace method implementation
        method_setImplementation(method, newImp);
        printf("[Modifier] Successfully swizzled %s\n", selectorNames[i]);
    }
}

// Setup window notification observer
static void setupWindowObserver(void) {
    [[NSNotificationCenter defaultCenter] 
        addObserverForName:NSWindowDidBecomeKeyNotification 
                    object:nil 
                     queue:[NSOperationQueue mainQueue] 
                usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        if (window) {
            modifyNSWindow(window);
        }
    }];
    
    [[NSNotificationCenter defaultCenter] 
        addObserverForName:NSWindowDidMoveNotification 
                    object:nil 
                     queue:[NSOperationQueue mainQueue] 
                usingBlock:^(NSNotification *note) {
        NSWindow *windowObj = note.object;
        if (windowObj) {
            modifyNSWindow(windowObj);
        }
    }];
    
    printf("[Modifier] Window observer set up successfully\n");
}

// Initialize the window modifier system
bool initWindowModifier(void) {
    printf("[Modifier] Initializing window modifier system...\n");
    
    // Record process start time for startup protection
    process_start_time = time(NULL);
    
    // Detect process role
    current_process_role = detectProcessRole();
    
    // Log process type
    const char* role_names[] = {
        "Main", "Renderer", "Utility", "Plugin", "Unknown"
    };
    printf("[Modifier] Process type: %s\n", role_names[current_process_role]);
    
    // Initialize shared registry for cross-process communication
    window_registry = registry_init();
    if (!window_registry) {
        printf("[Modifier] Warning: Failed to initialize window registry\n");
    } else {
        printf("[Modifier] Window registry initialized successfully\n");
    }
    
    // Load CGS functions
    if (!loadCGSFunctions()) {
        printf("[Modifier] Warning: Failed to load some CGS functions\n");
    }
    
    // Set up CGS window monitoring
    setupCGSWindowMonitoring();
    
    // Save frontmost app for focus restoration
    saveFrontmostApp();
    
    // Set up AppKit-based window detection (if this is an AppKit process)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSApp) {
            // Set up swizzling for window creation methods
            setupWindowMethodSwizzling();
            
            // Set up notification observers
            setupWindowObserver();
            
            // Temporarily set app to regular mode for Mission Control display
            if ([NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
                [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            }
            
            // Apply window modification with a small delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                           dispatch_get_main_queue(), ^{
                applyAllWindowModifications();
                
                // Return to accessories app
                if ([NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
                    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
                    printf("[Modifier] Application set to accessory mode\n");
                }
            });
        } else {
            printf("[Modifier] NSApp not available, using CGS-only approach\n");
            // If NSApp is not available, this is likely a non-AppKit process
            // Apply initial CGS scan
            scanExistingWindowsWithCGS();
        }
    });
    
    return true;
}

// Main Entry Point
void* window_modifier_main(void* arg) {
    printf("[Modifier] Window modifier starting up...\n");
    printf("[Modifier] Process ID: %d\n", getpid());
    
    initWindowModifier();
    
    // Wait a bit for initial setup
    sleep(1);
    
    // Main monitoring loop with retry queue processing
    while (1) {
        // Wait less time when we have pending windows
        if (retry_window_count > 0) {
            // Check more frequently when we have windows in retry queue
            usleep(500000); // 0.5 seconds
        } else {
            sleep(3); // Standard interval
        }
        
        // Process any windows in the retry queue that are ready
        if (retry_window_count > 0) {
            processRetryQueue();
        }
        
        // Periodically scan for new windows
        applyAllWindowModifications();
    }
    
    return NULL;
}
