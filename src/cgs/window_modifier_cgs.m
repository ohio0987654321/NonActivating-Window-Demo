// window_modifier_cgs.m - Core Graphics Services functions
#import "window_modifier_cgs.h"
#import <dlfcn.h>

// CGS Function pointers
CGSConnectionID (*CGSDefaultConnection_ptr)(void) = NULL;
OSStatus (*CGSGetOnScreenWindowList_ptr)(CGSConnectionID cid, CGSConnectionID targetCID, int maxCount, CGSWindowID *list, int *outCount) = NULL;
OSStatus (*CGSSetWindowLevel_ptr)(CGSConnectionID cid, CGSWindowID wid, int level) = NULL;
OSStatus (*CGSSetWindowSharingState_ptr)(CGSConnectionID cid, CGSWindowID wid, int sharingState) = NULL;
OSStatus (*CGSSetWindowTags_ptr)(CGSConnectionID cid, CGSWindowID wid, int *tags, int count) = NULL;
OSStatus (*CGSRegisterNotifyProc_ptr)(CGSNotifyConnectionProcPtr proc, int event, void *userdata) = NULL;

// Additional CGS function pointers not exposed in header
static OSStatus (*CGSClearWindowTags_ptr)(CGSConnectionID cid, CGSWindowID wid, int *tags, int count) = NULL;
static OSStatus (*CGSGetWindowTags_ptr)(CGSConnectionID cid, CGSWindowID wid, int *tags, int *count) = NULL;
static OSStatus (*CGSGetWindowLevel_ptr)(CGSConnectionID cid, CGSWindowID wid, int *level) = NULL;
CGSConnectionID (*CGSGetWindowOwner_ptr)(CGSConnectionID cid, CGSWindowID wid) = NULL;
static OSStatus (*CGSGetConnectionPSN_ptr)(CGSConnectionID cid, ProcessSerialNumber *psn) = NULL;
static CFArrayRef (*CGSCopyWindowDescriptionList_ptr)(CGSConnectionID cid, CGSWindowID wid) = NULL;
static CGSConnectionID (*CGSGetConnectionID_ptr)(void) = NULL;

// Global window state dictionary (windowID -> window_init_state_t)
CFMutableDictionaryRef window_states = NULL;

// Load CGS functions
bool loadCGSFunctions(void) {
    void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    if (!handle) {
        printf("[CGS] Error: Failed to open CoreGraphics framework\n");
        return false;
    }
    
    // Load core CGS functions
    CGSDefaultConnection_ptr = dlsym(handle, "_CGSDefaultConnection");
    if (!CGSDefaultConnection_ptr) {
        CGSDefaultConnection_ptr = dlsym(handle, "CGSMainConnectionID");
    }
    
    CGSSetWindowLevel_ptr = dlsym(handle, "CGSSetWindowLevel");
    CGSSetWindowSharingState_ptr = dlsym(handle, "CGSSetWindowSharingState");
    CGSSetWindowTags_ptr = dlsym(handle, "CGSSetWindowTags");
    CGSClearWindowTags_ptr = dlsym(handle, "CGSClearWindowTags");
    CGSGetWindowTags_ptr = dlsym(handle, "CGSGetWindowTags");
    
    // Load CGS functions for window detection
    CGSRegisterNotifyProc_ptr = dlsym(handle, "CGSRegisterNotifyProc");
    CGSGetOnScreenWindowList_ptr = dlsym(handle, "CGSGetOnScreenWindowList");
    CGSGetWindowLevel_ptr = dlsym(handle, "CGSGetWindowLevel");
    CGSGetWindowOwner_ptr = dlsym(handle, "CGSGetWindowOwner");
    CGSGetConnectionPSN_ptr = dlsym(handle, "CGSGetConnectionPSN");
    CGSCopyWindowDescriptionList_ptr = dlsym(handle, "CGSCopyWindowDescriptionList");
    CGSGetConnectionID_ptr = dlsym(handle, "CGSGetConnectionID");
    
    bool success = (CGSDefaultConnection_ptr != NULL && 
                    CGSSetWindowLevel_ptr != NULL && 
                    CGSSetWindowSharingState_ptr != NULL && 
                    CGSSetWindowTags_ptr != NULL);
    
    printf("[CGS] Core functions loaded: %s\n", success ? "Success" : "Failed");
    
    bool detection_success = (CGSRegisterNotifyProc_ptr != NULL && 
                             CGSGetOnScreenWindowList_ptr != NULL);
    
    printf("[CGS] Detection functions loaded: %s\n", detection_success ? "Success" : "Failed");
    
    return success;
}

// Get window information using CGS
NSDictionary *getWindowInfoWithCGS(CGSWindowID windowID) {
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
window_class_t determineWindowClass(CGSWindowID windowID, NSDictionary *windowInfo) {
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
    // Use a more lenient size requirement for standard macOS apps
    if (width && height) {
        if ([width intValue] < 50 || [height intValue] < 50) {
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

// Check if a window is ready for modification
bool isWindowReadyForModification(CGSWindowID windowID) {
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
    
    // Basic requirements - more lenient size check for standard macOS apps
    BOOL isVisible = [alpha doubleValue] > 0.0;
    BOOL isMainLayer = [windowLayer intValue] == 0;
    BOOL hasReasonableSize = [width intValue] > 50 && [height intValue] > 50;
    
    return isVisible && isMainLayer && hasReasonableSize;
}

// Check if a window should be treated as a utility window (not a main application window)
bool isUtilityWindow(CGSWindowID windowID) {
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
    
    // Visibility, size, and layer checks - more lenient for standard macOS apps
    if ((windowLayer && [windowLayer intValue] != 0) ||
        ([width intValue] < 50 || [height intValue] < 50) ||
        ([alpha doubleValue] < 0.3)) {
        return true;
    }
    
    return false;
}

// Check if a window is fully initialized
bool isWindowInitialized(CGSWindowID windowID) {
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
