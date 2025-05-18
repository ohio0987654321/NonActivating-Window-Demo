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

// Process role detection - simplified to three essential roles
typedef enum {
    PROCESS_ROLE_MAIN,       // Main application process
    PROCESS_ROLE_UI,         // Any UI rendering process (renderer, plugin, etc.)
    PROCESS_ROLE_UTILITY     // Background service process
} process_role_t;

// Global state - simplified
static NSRunningApplication *previousFrontmostApp = nil;
static window_registry_t *window_registry = NULL;
static bool is_cgs_monitor_active = false;
static process_role_t current_process_role = PROCESS_ROLE_MAIN;
static time_t process_start_time = 0;
static int modified_window_count = 0;
static const int STARTUP_PROTECTION_SECONDS = 3; // Simplified protection period
static const int UI_STARTUP_PROTECTION_SECONDS = 5; // Extra time for UI processes
static const int MAX_PROTECTED_WINDOWS = 2; // Limit for protected windows

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
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry);

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

// Check if a window belongs to a utility process
static bool isUtilityWindow(CGSWindowID windowID) {
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    if (!windowInfo) {
        return false;
    }
    
    // Extract window metadata
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    NSNumber *width = windowInfo[@"kCGSWindowWidth"];
    NSNumber *height = windowInfo[@"kCGSWindowHeight"];
    NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
    
    // Layer detection
    if (windowLayer && [windowLayer intValue] != 0) {
        return true;
    }
    
    // Size detection
    if ([width intValue] < 100 || [height intValue] < 100) {
        return true;
    }
    
    // Visibility detection
    if ([alpha doubleValue] < 0.3) {
        return true;
    }
    
    return false;
}

// Check if we're in startup protection period
static bool isInStartupProtection(void) {
    // Utility processes are always protected
    if (current_process_role == PROCESS_ROLE_UTILITY) {
        return true;
    }
    
    // UI process protection
    if (current_process_role == PROCESS_ROLE_UI) {
        // Protect first few windows
        if (modified_window_count < MAX_PROTECTED_WINDOWS) {
            return true;
        }
        
        // Time-based protection
        time_t now = time(NULL);
        if (now - process_start_time < UI_STARTUP_PROTECTION_SECONDS) {
            return true;
        }
    } else {
        // Standard protection for main process
        time_t now = time(NULL);
        if (now - process_start_time < STARTUP_PROTECTION_SECONDS) {
            return true;
        }
    }
    
    return false;
}

// Internal implementation of window modification
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry) {
    if (!CGSDefaultConnection_ptr || windowID == 0) return false;
    
    // Check if already modified
    if (window_registry && registry_is_window_modified(window_registry, windowID)) {
        if (!isRetry) {
            printf("[Modifier] Window %d already modified, skipping\n", windowID);
        }
        return true;
    }
    
    CGSConnectionID cid = CGSDefaultConnection_ptr();
    bool success = true;
    
    // Error handling wrapper
    @try {
        // 1. Apply non-activating (prevent stealing focus)
        if (CGSSetWindowTags_ptr) {
            int tags[1] = { kCGSPreventsActivationTagBit };
            CGError err = CGSSetWindowTags_ptr(cid, windowID, tags, 1);
            
            if (err != 0) {
                printf("[Modifier] Warning: Failed to set non-activating for window %d\n", windowID);
                success = false;
            }
        }
        
        // 2. Always-on-top (floating window level)
        if (CGSSetWindowLevel_ptr) {
            CGError err = CGSSetWindowLevel_ptr(cid, windowID, kCGSWindowLevelForKey);
            
            if (err != 0) {
                printf("[Modifier] Warning: Failed to set window level for window %d\n", windowID);
                success = false;
            }
        }
        
        // 3. Screen capture bypass
        if (CGSSetWindowSharingState_ptr) {
            CGError err = CGSSetWindowSharingState_ptr(cid, windowID, kCGSWindowSharingNoneValue);
            
            if (err != 0) {
                printf("[Modifier] Warning: Failed to set screen capture bypass for window %d\n", windowID);
                success = false;
            }
        }
    }
    @catch (NSException *exception) {
        printf("[Modifier] Exception during window modification\n");
        success = false;
    }
    
    if (success && window_registry) {
        // Mark the window as modified
        registry_mark_window_modified(window_registry, windowID);
        modified_window_count++;
    }
    
    return success;
}

// Apply window modifications directly using CGS APIs
static bool modifyWindowWithCGS(CGSWindowID windowID) {
    // Skip if in startup protection
    if (isInStartupProtection()) {
        return false;
    }
    
    // Skip utility windows
    if (isUtilityWindow(windowID)) {
        return false;
    }
    
    // Skip if not ready
    if (!isWindowReadyForModification(windowID)) {
        return false;
    }
    
    // Try to modify the window
    return modifyWindowWithCGSInternal(windowID, false);
}

// Apply modifications to an NSWindow
static bool modifyNSWindow(NSWindow *window) {
    if (!window) return false;
    
    CGSWindowID windowID = (CGSWindowID)[window windowNumber];
    
    // Skip if already modified
    if (window_registry && registry_is_window_modified(window_registry, windowID)) {
        return true;
    }
    
    // Apply modifications with error handling
    @try {
        // 1. Non-activating behavior
        if ([window respondsToSelector:@selector(_setPreventsActivation:)]) {
            [window _setPreventsActivation:YES];
        }
        
        // 2. Always-on-top behavior
        window.level = NSFloatingWindowLevel;
        
        // 3. Screen capture bypass
        window.sharingType = NSWindowSharingNone;
        
        // 4. Mission control compatibility
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | 
                                   NSWindowCollectionBehaviorParticipatesInCycle;
    }
    @catch (NSException *exception) {
        return false;
    }
    
    // Mark as modified
    if (window_registry) {
        registry_mark_window_modified(window_registry, windowID);
        modified_window_count++;
    }
    
    return true;
}

// CGS Window Notification callback
static void cgsWindowNotificationCallback(int type, void *data, uint32_t data_length, void *arg) {
    if (!data || data_length < sizeof(CGSWindowID)) {
        return;
    }
    
    CGSWindowID windowID = *(CGSWindowID *)data;
    
    if (type == kCGSWindowDidCreateNotification || type == kCGSWindowDidOrderInNotification) {
        // Try to modify this window
        modifyWindowWithCGS(windowID);
    }
}

// Set up CGS window notification monitoring
static bool setupCGSWindowMonitoring(void) {
    if (!CGSRegisterNotifyProc_ptr) {
        return false;
    }
    
    if (is_cgs_monitor_active) {
        return true;
    }
    
    // Try to register for notifications
    CGSRegisterNotifyProc_ptr(cgsWindowNotificationCallback, kCGSWindowDidCreateNotification, NULL);
    CGSRegisterNotifyProc_ptr(cgsWindowNotificationCallback, kCGSWindowDidOrderInNotification, NULL);
    
    is_cgs_monitor_active = true;
    
    return true;
}

// Scan for existing windows using CGS
static void scanExistingWindowsWithCGS(void) {
    if (!CGSGetOnScreenWindowList_ptr || !CGSDefaultConnection_ptr) {
        return;
    }
    
    CGSConnectionID cid = CGSDefaultConnection_ptr();
    const int maxWindows = 256;
    CGSWindowID windowList[maxWindows];
    int windowCount = 0;
    
    CGError err = CGSGetOnScreenWindowList_ptr(cid, cid, maxWindows, windowList, &windowCount);
    
    if (err != 0) {
        return;
    }
    
    printf("[Modifier] Found %d windows via CGS\n", windowCount);
    
    for (int i = 0; i < windowCount; i++) {
        modifyWindowWithCGS(windowList[i]);
    }
}

// Apply modifications to all NSWindows
static bool applyAllWindowModifications(void) {
    saveFrontmostApp();
    
    // First, try to modify via AppKit if available
    if (NSApp) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Apply to each window
            for (NSWindow *window in [NSApp windows]) {
                modifyNSWindow(window);
            }
            
            // Return focus
            restoreFrontmostApp();
        });
    }
    
    // Also scan for windows using CGS
    scanExistingWindowsWithCGS();
    
    return true;
}

// Method swizzling for window creation detection
static void setupWindowMethodSwizzling(void) {
    Class windowClass = [NSWindow class];
    
    // Methods to swizzle
    SEL selectors[] = {
        @selector(orderFront:),
        @selector(makeKeyAndOrderFront:)
    };
    
    // Selector names for debugging - this is not used in code but kept for reference
    __attribute__((unused)) const char *selectorNames[] = {
        "orderFront:",
        "makeKeyAndOrderFront:"
    };
    
    for (int i = 0; i < 2; i++) {
        Method method = class_getInstanceMethod(windowClass, selectors[i]);
        
        if (!method) {
            continue;
        }
        
        // Get original implementation
        IMP originalImp = method_getImplementation(method);
        SEL currentSelector = selectors[i];
        
        // Create new implementation
        IMP newImp = imp_implementationWithBlock(^(id self, id sender) {
            // Call original method
            ((void (*)(id, SEL, id))originalImp)(self, currentSelector, sender);
            
            // Now modify the window
            modifyNSWindow((NSWindow *)self);
        });
        
        // Replace method implementation
        method_setImplementation(method, newImp);
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
    
    printf("[Modifier] Window observer set up successfully\n");
}

// Initialize the window modifier system
static bool initWindowModifier(void) {
    printf("[Modifier] Initializing window modifier system...\n");
    
    // Record process start time for startup protection
    process_start_time = time(NULL);
    
    // Detect process role
    current_process_role = detectProcessRole();
    
    // Initialize registry
    window_registry = registry_init();
    
    // Load CGS functions
    loadCGSFunctions();
    
    // Set up CGS window monitoring
    setupCGSWindowMonitoring();
    
    // Save frontmost app for focus restoration
    saveFrontmostApp();
    
    // Set up AppKit-based window detection
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSApp) {
            // Set up swizzling for window creation methods
            setupWindowMethodSwizzling();
            
            // Set up notification observers
            setupWindowObserver();
            
            // Apply initial modifications
            applyAllWindowModifications();
        }
    });
    
    return true;
}

// Main Entry Point
void* window_modifier_main(void* arg) {
    printf("[Modifier] Window modifier starting up...\n");
    printf("[Modifier] Process ID: %d\n", getpid());
    
    initWindowModifier();
    
    // Main monitoring loop - simplified
    while (1) {
        sleep(2);
        
        // Periodically scan for new windows
        applyAllWindowModifications();
    }
    
    return NULL;
}
