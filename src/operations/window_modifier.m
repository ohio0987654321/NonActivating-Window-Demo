// window_modifier.m - Core window modification operations
#import "window_modifier.h"
#import "../cgs/window_modifier_cgs.h"
#import "../tracker/window_classifier.h"
#import <objc/runtime.h>
#import <sys/time.h>
#import <pthread.h>
#import <unistd.h>

// Access to CGS window states dictionary
extern CFMutableDictionaryRef window_states;

// Declare NSWindow private methods
@interface NSWindow (PrivateMethods)
- (void)_setPreventsActivation:(BOOL)preventsActivation;
@end

// Global state
static NSRunningApplication *previousFrontmostApp = nil;
window_registry_t *window_registry = NULL;  // Updated to make it externally visible
static bool is_cgs_monitor_active = false;
static process_role_t current_process_role = PROCESS_ROLE_MAIN;
static time_t process_start_time = 0;
static int modified_window_count = 0;
// Application startup detection and protection times (for all macOS applications)
static const int STARTUP_PROTECTION_SECONDS = 0; // Reduced protection period
static const int MAX_PROTECTED_WINDOWS = 2; // Limit for protected windows
static retry_window_t retry_windows[32];
static int retry_window_count = 0;
static double retry_delays[] = {0.1, 0.3, 0.6, 1.0, 2.0}; // Progressive delays in seconds
static const int max_retry_attempts = 5;

// Thread-local storage for current window context
static pthread_key_t current_window_key;
static bool thread_keys_initialized = false;

// Application initialization state tracking
static app_init_state_t current_init_state = APP_INIT_NOT_STARTED;
static int main_window_count = 0;

// Import swizzling header
#import "window_modifier_swizzle.h"

// Forward declarations for internal functions
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry);
static void addWindowToRetryQueue(CGSWindowID windowID);
static void processRetryQueue(void);
static void startWindowMonitoring(void);
static void saveFrontmostApp(void);
static void restoreFrontmostApp(void);
static void updateWindowState(int eventType, CGSWindowID windowID);
static void windowNotificationCallback(int type, void *data, uint32_t data_length, void *arg);
static void countInitializedStandardWindows(const void *key, const void *value, void *context);
static void countStandardWindows(const void *key, const void *value, void *context);
static void updateInitializationState(int eventType, CGSWindowID windowID);
static process_role_t detectProcessRole(void);
static NSWindow* findNSWindowByID(CGSWindowID windowID);
static bool modifyWindowWithNSWindow(CGSWindowID windowID);
static void modifyWindowWhenSafe(CGSWindowID windowID);

// Function to count initialized standard windows for the dictionary applier
static void countInitializedStandardWindows(const void * __attribute__((unused)) key, const void *value, void *context) {
    window_init_state_t *state = (window_init_state_t *)value;
    if (state->window_class == WINDOW_CLASS_STANDARD && state->is_initialized) {
        int *counter = (int *)context;
        (*counter)++;
    }
}

// Function to count all standard windows (initialized or not)
static void countStandardWindows(const void * __attribute__((unused)) key, const void *value, void *context) {
    window_init_state_t *state = (window_init_state_t *)value;
    if (state->window_class == WINDOW_CLASS_STANDARD) {
        int *counter = (int *)context;
        (*counter)++;
    }
}

// Save previous app
static void __attribute__((unused)) saveFrontmostApp(void) {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (frontApp && ![frontApp.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        previousFrontmostApp = frontApp;
        printf("[Modifier] Saved frontmost app: %s\n", [frontApp.localizedName UTF8String]);
    }
}

// Return focus to previous app
static void __attribute__((unused)) restoreFrontmostApp(void) {
    if (previousFrontmostApp) {
        [previousFrontmostApp activateWithOptions:0];
        printf("[Modifier] Restored focus to: %s\n", [previousFrontmostApp.localizedName UTF8String]);
    }
}

// Check if we're in the startup protection period
bool isInStartupProtection(void) {
    time_t now = time(NULL);
    
    if (process_start_time == 0) {
        process_start_time = now; // Initialize if not set
    }
    
    // Are we within the protection time and under the protected window limit?
    return ((now - process_start_time < STARTUP_PROTECTION_SECONDS) && 
            (modified_window_count < MAX_PROTECTED_WINDOWS));
}

// Modify a window using CGS (thread-safe public interface)
bool modifyWindowWithCGS(CGSWindowID windowID) {
    // Just a wrapper that calls the internal function with retry=false
    return modifyWindowWithCGSInternal(windowID, false);
}

// Modify a window using CGS (internal implementation)
static bool modifyWindowWithCGSInternal(CGSWindowID windowID, bool isRetry) {
    if (!CGSDefaultConnection_ptr || !CGSSetWindowLevel_ptr || 
        !CGSSetWindowSharingState_ptr || !CGSSetWindowTags_ptr) {
        printf("[Modifier] Error: Required CGS functions not loaded\n");
        return false;
    }
    
    // Skip if window ID is invalid
    if (windowID <= 0) {
        return false;
    }
    
    // Check if we've already modified this window via cross-process registry
    if (window_registry && registry_is_window_modified(window_registry, windowID)) {
        printf("[Modifier] Info: Window %d already modified (registry)\n", windowID);
        return true;
    }
    
    // Check if it's an utility window that we should skip
    if (isUtilityWindow(windowID)) {
        printf("[Modifier] Skipping utility window: %d\n", windowID);
        return false;
    }
    
    // Check if the window is ready for modification
    if (!isRetry && !isWindowReadyForModification(windowID)) {
        printf("[Modifier] Window %d not ready, adding to retry queue\n", windowID);
        addWindowToRetryQueue(windowID);
        return false;
    }
    
    // Apply modifications
    CGSConnectionID cid = CGSDefaultConnection_ptr();
    CGSConnectionID ownerCID = 0;
    bool success = true;
    bool tagSuccess = false;
    
    // Get window owner information first
    if (CGSGetWindowOwner_ptr) {
        ownerCID = CGSGetWindowOwner_ptr(cid, windowID);
        if (ownerCID != cid) {
            printf("[Modifier] Window %d is owned by a different connection (Owner: %d, Current: %d)\n", 
                   windowID, ownerCID, cid);
            
            // Special case: Owner ID 0 indicates a system window or special permission window
            // These windows should be completely avoided to prevent crashes
            if (ownerCID == 0) {
                printf("[Modifier] Window %d has special ownership (ID 0), avoiding modification\n", windowID);
                // Mark as modified in registry to avoid future attempts
                if (window_registry) {
                    registry_mark_window_modified(window_registry, windowID);
                }
                return false; // Skip this window completely
            }
        }
    }
    
    // Set window level to floating - try owner connection first if different
    OSStatus levelStatus = kCGErrorFailure;
    if (ownerCID != 0 && ownerCID != cid) {
        levelStatus = CGSSetWindowLevel_ptr(ownerCID, windowID, kCGSWindowLevelForKey);
    }
    
    // If owner connection failed or is the same, try our connection
    if (levelStatus != kCGErrorSuccess) {
        levelStatus = CGSSetWindowLevel_ptr(cid, windowID, kCGSWindowLevelForKey);
    }
    
    if (levelStatus != kCGErrorSuccess) {
        printf("[Modifier] Failed to set window level for %d (Error: %d)\n", windowID, (int)levelStatus);
        // Don't fail completely, continue with other modifications
    }
    
    // Enable screen recording bypass by setting window sharing to none
    OSStatus sharingStatus = kCGErrorFailure;
    
    // Try with owner connection if different
    if (ownerCID != 0 && ownerCID != cid) {
        sharingStatus = CGSSetWindowSharingState_ptr(ownerCID, windowID, kCGSWindowSharingNoneValue);
        if (sharingStatus == kCGErrorSuccess) {
            printf("[Modifier] Successfully set screen recording bypass using owner connection\n");
        }
    }
    
    // If owner connection failed or is the same, try our connection
    if (sharingStatus != kCGErrorSuccess) {
        sharingStatus = CGSSetWindowSharingState_ptr(cid, windowID, kCGSWindowSharingNoneValue);
        if (sharingStatus == kCGErrorSuccess) {
            printf("[Modifier] Successfully set screen recording bypass using our connection\n");
        }
    }
    
    // If both failed, try with default connection as last resort
    if (sharingStatus != kCGErrorSuccess) {
        CGSConnectionID defaultCID = CGSDefaultConnection_ptr();
        if (defaultCID != cid && defaultCID != ownerCID) {
            sharingStatus = CGSSetWindowSharingState_ptr(defaultCID, windowID, kCGSWindowSharingNoneValue);
            if (sharingStatus == kCGErrorSuccess) {
                printf("[Modifier] Successfully set screen recording bypass using default connection\n");
            } else {
                printf("[Modifier] Failed to set screen recording bypass for %d (Error: %d)\n", 
                       windowID, (int)sharingStatus);
            }
        }
    }
    
    // Get window info for context
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    NSString *windowName = nil;
    NSString *windowOwner = nil;
    
    if (windowInfo) {
        windowName = windowInfo[@"kCGSWindowTitle"];
        windowOwner = windowInfo[@"kCGSWindowOwnerName"];
        printf("[Modifier] Window info: ID=%d, Title='%s', Owner='%s'\n", 
               windowID,
               windowName ? [windowName UTF8String] : "unknown",
               windowOwner ? [windowOwner UTF8String] : "unknown");
    }
    
    // Add prevents-activation tag - only for windows that don't have owner ID 0
    int tag = kCGSPreventsActivationTagBit;
    
    // For normal (non-owner ID 0) windows only
    {
        // For normal windows, try all connection methods
        
        // First attempt: Try with owner connection if different
        if (ownerCID != cid) {
            OSStatus status = CGSSetWindowTags_ptr(ownerCID, windowID, &tag, 1);
            if (status == kCGErrorSuccess) {
                printf("[Modifier] Successfully set tags using owner connection\n");
                tagSuccess = true;
            } else {
                printf("[Modifier] Failed to set tags with owner connection (Error: %d)\n", (int)status);
            }
        }
        
        // Second attempt: Try with our connection if first failed
        if (!tagSuccess) {
            OSStatus status = CGSSetWindowTags_ptr(cid, windowID, &tag, 1);
            if (status == kCGErrorSuccess) {
                printf("[Modifier] Successfully set tags using our connection\n");
                tagSuccess = true;
            } else {
                printf("[Modifier] Failed to set tags with our connection (Error: %d)\n", (int)status);
            }
        }
        
        // Third attempt: Try with default connection as last resort
        if (!tagSuccess) {
            CGSConnectionID defaultCID = CGSDefaultConnection_ptr();
            if (defaultCID != cid && defaultCID != ownerCID) {
                OSStatus status = CGSSetWindowTags_ptr(defaultCID, windowID, &tag, 1);
                if (status == kCGErrorSuccess) {
                    printf("[Modifier] Successfully set tags using default connection\n");
                    tagSuccess = true;
                } else {
                    printf("[Modifier] Failed with all connection attempts for tag setting\n");
                }
            }
        }
    }
    
    // Even if tag setting fails, consider successful if we at least set the window level
    success = (levelStatus == kCGErrorSuccess || tagSuccess);
    
    // Log comprehensive window details if tag setting failed
    if (!tagSuccess) {
        printf("[Modifier] WARNING: Unable to set non-activating tag for window %d\n", windowID);
        if (windowInfo) {
            // Log key window properties for debugging
            printf("[Modifier] Window Properties for ID %d:\n", windowID);
            NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
            NSNumber *width = windowInfo[@"kCGSWindowWidth"];
            NSNumber *height = windowInfo[@"kCGSWindowHeight"];
            NSString *windowLayer = windowInfo[@"kCGSWindowLayer"];
            NSNumber *windowLevel = windowInfo[@"kCGSWindowLevel"];
            
            printf("  - Alpha: %f\n", alpha ? [alpha doubleValue] : -1);
            printf("  - Size: %dx%d\n", width ? [width intValue] : -1, height ? [height intValue] : -1);
            printf("  - Layer: %s\n", windowLayer ? [windowLayer UTF8String] : "unknown");
            printf("  - Level: %d\n", windowLevel ? [windowLevel intValue] : -1);
        }
    }
    
    if (success) {
        printf("[Modifier] Successfully modified window: %d\n", windowID);
        
        // Mark as modified in registry
        if (window_registry) {
            registry_mark_window_modified(window_registry, windowID);
        }
        
        modified_window_count++;
    }
    
    return success;
}

// Modify an NSWindow instance (for AppKit windows)
bool modifyNSWindow(NSWindow *window) {
    if (!window) {
        return false;
    }
    
    @try {
        // 1. Set window level to floating
        window.level = NSFloatingWindowLevel;
        
        // 2. Set collectionBehavior for Mission Control compatibility
        // Using NSWindowCollectionBehaviorParticipatesInCycle|NSWindowCollectionBehaviorManaged 
        // for proper Mission Control support
        window.collectionBehavior = NSWindowCollectionBehaviorParticipatesInCycle |
                                   NSWindowCollectionBehaviorManaged;
        
        // 3. Screen capture bypass (prevent recording)
        if ([window respondsToSelector:@selector(setSharingType:)]) {
            [window setSharingType:NSWindowSharingNone];
        }
        
        // 4. Use private API to prevent activation
        if ([window respondsToSelector:@selector(_setPreventsActivation:)]) {
            [window _setPreventsActivation:YES];
        }
        
        // 5. Temporarily set the app to regular mode for Mission Control display
        // This helps with proper display in Mission Control
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            if (NSApp && [NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
                // Store the original activation policy
                NSApplicationActivationPolicy originalPolicy = [NSApp activationPolicy];
                
                // Briefly switch to regular mode
                [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
                
                // Schedule return to original policy after 1 second
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), 
                               dispatch_get_main_queue(), ^{
                    [NSApp setActivationPolicy:originalPolicy];
                    printf("[Modifier] Restored original activation policy\n");
                });
            }
        });
        
        // Get the window ID
        CGSWindowID windowID = (CGSWindowID)[window windowNumber];
        
        // Mark as modified in registry if we have a valid window ID
        if (windowID > 0 && window_registry) {
            registry_mark_window_modified(window_registry, windowID);
        }
        
        printf("[Modifier] Modified NSWindow: %lu\n", (unsigned long)[window windowNumber]);
        return true;
    }
    @catch (NSException *exception) {
        printf("[Modifier] Exception modifying NSWindow: %s\n", 
              [[exception description] UTF8String]);
        return false;
    }
}

// Add a window to the retry queue
static void addWindowToRetryQueue(CGSWindowID windowID) {
    // Check if already in queue
    for (int i = 0; i < retry_window_count; i++) {
        if (retry_windows[i].windowID == windowID) {
            return;
        }
    }
    
    // Add to queue if space available
    if (retry_window_count < (int)(sizeof(retry_windows) / sizeof(retry_windows[0]))) {
        retry_windows[retry_window_count].windowID = windowID;
        retry_windows[retry_window_count].attempts = 0;
        retry_windows[retry_window_count].next_attempt_time = 
            CFAbsoluteTimeGetCurrent() + retry_delays[0];
        
        retry_window_count++;
        printf("[Modifier] Added window %d to retry queue (count: %d)\n", 
               windowID, retry_window_count);
    }
}

// Process the window retry queue
static void processRetryQueue(void) {
    if (retry_window_count == 0) {
        return;
    }
    
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    
    // Track indices to remove
    int indices_to_remove[32] = {0};
    int remove_count = 0;
    
    // Process each window in the retry queue
    for (int i = 0; i < retry_window_count; i++) {
        if (now >= retry_windows[i].next_attempt_time) {
            CGSWindowID windowID = retry_windows[i].windowID;
            
            printf("[Modifier] Retry attempt %d for window %d\n", 
                   retry_windows[i].attempts + 1, windowID);
            
            // Try to modify the window
            bool success = modifyWindowWithCGSInternal(windowID, true);
            
            if (success) {
                // If successful, mark for removal
                indices_to_remove[remove_count++] = i;
                printf("[Modifier] Retry successful for window %d\n", windowID);
            } else {
                // Increment attempt count
                retry_windows[i].attempts++;
                
                // If max retries reached, mark for removal
                if (retry_windows[i].attempts >= max_retry_attempts) {
                    indices_to_remove[remove_count++] = i;
                    printf("[Modifier] Max retries reached for window %d\n", windowID);
                } else {
                    // Schedule next retry
                    int delay_index = retry_windows[i].attempts;
                    if (delay_index >= (int)(sizeof(retry_delays) / sizeof(retry_delays[0]))) {
                        delay_index = sizeof(retry_delays) / sizeof(retry_delays[0]) - 1;
                    }
                    
                    retry_windows[i].next_attempt_time = now + retry_delays[delay_index];
                }
            }
        }
    }
    
    // Remove processed entries from highest index to lowest
    for (int i = remove_count - 1; i >= 0; i--) {
        int index = indices_to_remove[i];
        
        // Shift all elements after this one down
        for (int j = index; j < retry_window_count - 1; j++) {
            retry_windows[j] = retry_windows[j + 1];
        }
        
        retry_window_count--;
    }
    
    if (remove_count > 0) {
        printf("[Modifier] Removed %d windows from retry queue (remaining: %d)\n", 
               remove_count, retry_window_count);
    }
}

// Apply modifications to all windows
bool applyAllWindowModifications(void) {
    if (!CGSDefaultConnection_ptr || !CGSGetOnScreenWindowList_ptr) {
        printf("[Modifier] Error: Required CGS functions not loaded\n");
        return false;
    }
    
    // Create local array for safe windows only
    CGSWindowID safeWindows[128];
    int safeWindowCount = 0;
    int success_count = 0;
    
    @try {
        // First phase: Get all windows, but only store the IDs
        // This avoids passing the full window array to functions that might
        // crash when accessing certain windows
        CGSConnectionID cid = CGSDefaultConnection_ptr();
        CGSWindowID allWindows[128];
        int windowCount = 0;
        
        @try {
            CGSGetOnScreenWindowList_ptr(cid, cid, 128, allWindows, &windowCount);
            printf("[Modifier] Found %d on-screen windows\n", windowCount);
            
            // Pre-scan phase: Check each window for safety before doing anything else
            for (int i = 0; i < windowCount; i++) {
                CGSWindowID windowID = allWindows[i];
                
                // Skip windows already marked in registry
                if (window_registry && registry_is_window_modified(window_registry, windowID)) {
                    continue;
                }
                
                // Check if this is an unsafe window (owner ID 0)
                bool unsafe = isOwnerIDZeroWindow(windowID);
                
                if (unsafe) {
                    // Mark as modified in registry to prevent future attempts
                    if (window_registry) {
                        registry_mark_window_modified(window_registry, windowID);
                        printf("[Modifier] Pre-filtered unsafe window %d\n", windowID);
                    }
                } else {
                    // This window seems safe, add to our safe list
                    if (safeWindowCount < 128) {
                        safeWindows[safeWindowCount++] = windowID;
                    }
                }
            }
        }
        @catch (NSException *exception) {
            printf("[Modifier] Exception during window list retrieval: %s\n", 
                  [[exception description] UTF8String]);
            return false;
        }
        
        // Second phase: Only operate on windows we've verified are safe
        for (int i = 0; i < safeWindowCount; i++) {
            if (modifyWindowWithCGS(safeWindows[i])) {
                success_count++;
            }
        }
    }
    @catch (NSException *exception) {
        printf("[Modifier] Top-level exception during window modifications: %s\n", 
              [[exception description] UTF8String]);
    }
    
    printf("[Modifier] Successfully modified %d windows\n", success_count);
    return (success_count > 0);
}

// Check if the application is fully initialized
bool isApplicationInitialized(void) {
    // Get current time for timeout calculations
    time_t now = time(NULL);
    
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
            }
            
            return true;
        }
    }
    
    // Layer 3: Time-based fallback - if enough time has passed, assume the app is initialized
    int time_threshold = (current_process_role == PROCESS_ROLE_UI) ? 3 : 2;
    
    if ((now - process_start_time) > time_threshold) {
        printf("[Modifier] App considered initialized by time threshold (%d seconds elapsed)\n", 
              (int)(now - process_start_time));
              
        // Update state machine to match reality
        if (current_init_state < APP_INIT_FIRST_WINDOW_COMPLETE) {
            current_init_state = APP_INIT_FIRST_WINDOW_COMPLETE;
        }
        
        return true;
    }
    
    return false;
}

// Update the state of a window based on events
static void updateWindowState(int eventType, CGSWindowID windowID) {
    if (!window_states) {
        // Create window states dictionary if it doesn't exist yet
        window_states = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 
            128, 
            &kCFTypeDictionaryKeyCallBacks, 
            NULL); // Custom value callbacks not needed
    }
    
    NSNumber *key = @(windowID);
    window_init_state_t *state = NULL;
    
    // Get existing state or create new one
    if (CFDictionaryContainsKey(window_states, (__bridge CFNumberRef)key)) {
        state = (window_init_state_t *)CFDictionaryGetValue(window_states, (__bridge CFNumberRef)key);
    } else {
        // Create new state
        state = malloc(sizeof(window_init_state_t));
        if (!state) {
            return; // Out of memory
        }
        
        // Initialize state
        state->window_id = windowID;
        state->window_state = 0;
        state->is_initialized = false;
        state->first_seen = time(NULL);
        
        // Get window info to determine class
        NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
        state->window_class = determineWindowClass(windowID, windowInfo);
        
        // Add to dictionary
        CFDictionarySetValue(window_states, (__bridge CFNumberRef)key, state);
        
        printf("[Modifier] Created tracking for window %d (class: %d)\n", 
               windowID, state->window_class);
    }
    
    // Update state based on event type
    switch (eventType) {
        case kCGSWindowDidCreateNotification:
            state->window_state |= WINDOW_STATE_CREATED;
            break;
            
        case kCGSWindowDidOrderInNotification:
            state->window_state |= WINDOW_STATE_VISIBLE;
            break;
            
        case kCGSWindowDidResizeNotification:
            state->window_state |= WINDOW_STATE_SIZED;
            break;
            
        case kCGSWindowDidUpdateNotification:
            state->window_state |= WINDOW_STATE_CONTENT_READY;
            break;
    }
    
    // Check if window is fully initialized
    bool was_initialized = state->is_initialized;
    state->is_initialized = ((state->window_state & WINDOW_STATE_FULLY_INITIALIZED) == 
                            WINDOW_STATE_FULLY_INITIALIZED);
    
    // If initialization status changed, log it
    if (!was_initialized && state->is_initialized) {
        printf("[Modifier] Window %d now fully initialized (state: 0x%x, class: %d)\n", 
               windowID, state->window_state, state->window_class);
               
                // If this is a standard window, try to modify it
                if (state->window_class == WINDOW_CLASS_STANDARD && 
                    isApplicationInitialized() && 
                    !isInStartupProtection()) {
            
                    modifyWindowWithCGS(windowID);
                }
    }
    
    // Update application initialization state
    updateInitializationState(eventType, windowID);
}

// CGS window notification callback
static void windowNotificationCallback(int type, void *data, uint32_t data_length, void * __attribute__((unused)) arg) {
    if (!data || data_length < sizeof(uint32_t)) {
        return;
    }
    
    CGSWindowID windowID = *(uint32_t *)data;
    
    // Update window state tracking
    if (windowID > 0) {
        updateWindowState(type, windowID);
    }
    
    // Perform window modification if conditions are met
    if ((type == kCGSWindowDidCreateNotification || type == kCGSWindowDidOrderInNotification) && 
        isApplicationInitialized() && 
        !isInStartupProtection()) {
        
        modifyWindowWithCGS(windowID);
    }
}

// Handle a window event (public interface)
void handleWindowEvent(int eventType, CGSWindowID windowID) {
    if (windowID <= 0) {
        return;
    }
    
    // Just pass through to the internal function
    updateWindowState(eventType, windowID);
    
    // Conditionally try to modify the window
    if ((eventType == kCGSWindowDidCreateNotification || eventType == kCGSWindowDidOrderInNotification) && 
        isApplicationInitialized() && 
        !isInStartupProtection()) {
        
        modifyWindowWithCGS(windowID);
    }
}

// Start CGS window monitoring
static void startWindowMonitoring(void) {
    if (is_cgs_monitor_active || !CGSRegisterNotifyProc_ptr) {
        return;
    }
    
    // Register for window notifications
    CGSRegisterNotifyProc_ptr(windowNotificationCallback, kCGSWindowDidCreateNotification, NULL);
    CGSRegisterNotifyProc_ptr(windowNotificationCallback, kCGSWindowDidOrderInNotification, NULL);
    CGSRegisterNotifyProc_ptr(windowNotificationCallback, kCGSWindowDidResizeNotification, NULL);
    CGSRegisterNotifyProc_ptr(windowNotificationCallback, kCGSWindowDidUpdateNotification, NULL);
    
    is_cgs_monitor_active = true;
    printf("[Modifier] Window monitoring started\n");
}

// Initialize thread resources
static void initThreadResources(void) {
    if (!thread_keys_initialized) {
        pthread_key_create(&current_window_key, NULL);
        thread_keys_initialized = true;
    }
}

// Main loop for window modifier
static void runWindowModifier(void) {
    int iteration_count = 0;
    
    while (true) {
        // Process retry queue
        processRetryQueue();
        
        // Apply modifications to new windows if app is initialized and not in startup protection
        if (isApplicationInitialized() && !isInStartupProtection() && (iteration_count % 50 == 0)) {
            applyAllWindowModifications();
        }
        
        // Increment iteration counter
        iteration_count++;
        
        // Sleep
        usleep(100000); // 100ms
    }
}

// Update application initialization state based on window events
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
                
                // Check if this looks like a main window - use more lenient size requirements
                // Many macOS apps have smaller main windows
                if (width && height && 
                    [width intValue] >= 200 && [height intValue] >= 100) {
                    
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
            
        case APP_INIT_COMPLETE: {
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
    }
    
    // Clean up closed or invalid windows from our tracking array
    NSMutableIndexSet *indicesToRemove = [NSMutableIndexSet indexSet];
    [standardWindowIDs enumerateObjectsUsingBlock:^(NSNumber *winIDObj, NSUInteger idx, BOOL * __attribute__((unused)) stop) {
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

// Process name patterns for classification
typedef struct {
    const char* pattern;
    process_role_t role;
} process_pattern_t;

// Common patterns in macOS process architecture
static const process_pattern_t process_patterns[] = {
    // UI/Rendering processes - common patterns across frameworks
    {"Renderer", PROCESS_ROLE_UI},
    {"WebProcess", PROCESS_ROLE_UI},
    {"WebContent", PROCESS_ROLE_UI},
    {"UIProcess", PROCESS_ROLE_UI},
    {"ViewService", PROCESS_ROLE_UI},
    {"RenderProcess", PROCESS_ROLE_UI},
    
    // Utility/Helper processes - common across macOS applications
    {"GPU", PROCESS_ROLE_UTILITY},
    {"Helper", PROCESS_ROLE_UTILITY},
    {"Plugin", PROCESS_ROLE_UTILITY},
    {"Utility", PROCESS_ROLE_UTILITY},
    {"Service", PROCESS_ROLE_UTILITY},
    {"Agent", PROCESS_ROLE_UTILITY},
    {"XPC", PROCESS_ROLE_UTILITY},
    {"Network", PROCESS_ROLE_UTILITY},
    {"Storage", PROCESS_ROLE_UTILITY},
    
    // End marker
    {NULL, PROCESS_ROLE_MAIN}
};

// Detect process role based on executable path - generalized for all macOS applications
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
    
    // Check for position in application bundle
    bool isMainBundle = false;
    if (strstr(processPath, ".app/Contents/MacOS/")) {
        // This is likely the main application executable
        isMainBundle = true;
    }
    
    // Helper processes often contain these patterns
    for (int i = 0; process_patterns[i].pattern != NULL; i++) {
        if (strcasestr(processName, process_patterns[i].pattern) != NULL) {
            // If this is in the main bundle path but has a pattern match,
            // it could be a specially named main executable, so do extra checks
            if (isMainBundle) {
                // Is the pattern the entire name? If so, it's probably a helper
                size_t patternLen = strlen(process_patterns[i].pattern);
                size_t nameLen = strlen(processName);
                
                // If the pattern is a significant portion of the name, it's likely matching correctly
                if (patternLen > 3 && patternLen >= nameLen / 2) {
                    return process_patterns[i].role;
                }
                
                // Otherwise, continue checking other patterns
            } else {
                // Not in main bundle, so pattern match is reliable
                return process_patterns[i].role;
            }
        }
    }
    
    // If we reach here and it's the main bundle, it's the main process
    if (isMainBundle) {
        return PROCESS_ROLE_MAIN;
    }
    
    // If we couldn't determine, default to standard
    return PROCESS_ROLE_MAIN;
}

// Find a NSWindow instance that corresponds to a CGSWindowID
static NSWindow* findNSWindowByID(CGSWindowID windowID) {
    if (windowID <= 0) {
        return nil;
    }
    
    // Get all the windows in the application
    NSArray *windows = [NSApp windows];
    
    // Iterate through the windows and find the one with matching window number
    for (NSWindow *window in windows) {
        if ((CGSWindowID)[window windowNumber] == windowID) {
            return window;
        }
    }
    
    // Try to find the window even if it belongs to a different application
    // This is useful for windows with owner ID 0
    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (windowList) {
        NSArray *windows = CFBridgingRelease(windowList);
        for (NSDictionary *windowInfo in windows) {
            NSNumber *winIDNum = windowInfo[(id)kCGWindowNumber];
            if (winIDNum && [winIDNum unsignedIntValue] == windowID) {
                // Found the window info, but we can't get an NSWindow directly for other apps
                // Just return nil as we can't modify it via NSWindow methods
                return nil;
            }
        }
    }
    
    return nil;
}

// Modify a window using the AppKit NSWindow approach
static bool modifyWindowWithNSWindow(CGSWindowID windowID) {
    NSWindow *window = findNSWindowByID(windowID);
    if (window) {
        return modifyNSWindow(window);
    }
    
    // If we can't find the window, return false
    printf("[Modifier] Could not find NSWindow for window ID %d\n", windowID);
    return false;
}

// Schedule window modification with a small delay to let window finish construction
static void __attribute__((unused)) modifyWindowWhenSafe(CGSWindowID windowID) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        // Check if the window has already been modified
        if (window_registry && registry_is_window_modified(window_registry, windowID)) {
            return;
        }
        
        // Try the NSWindow approach first
        if (modifyWindowWithNSWindow(windowID)) {
            registry_mark_window_modified(window_registry, windowID);
            return;
        }
        
        // If that fails, try the CGS approach
        modifyWindowWithCGSInternal(windowID, false);
    });
}

// Main entry point for window modifier thread
void* window_modifier_main(void* __attribute__((unused)) arg) {
    // Set up thread resources
    initThreadResources();
    
    // Record start time
    process_start_time = time(NULL);
    
    // Detect process role
    current_process_role = detectProcessRole();
    
    // Initialize registry
    if (!window_registry) {
        window_registry = registry_init();
        if (!window_registry) {
            printf("[Modifier] Warning: Failed to initialize window registry\n");
        }
    }
    
    // Load CGS functions
    if (!loadCGSFunctions()) {
        printf("[Modifier] Error: Failed to load CGS functions\n");
        return NULL;
    }
    
    // Initialize method swizzling for direct NSWindow modifications
    // This helps catch windows as they're being created, especially 
    // important for windows with owner ID 0
    initializeWindowSwizzling();
    printf("[Modifier] Window method swizzling initialized\n");
    
    // Start monitoring windows
    startWindowMonitoring();
    
    // Apply initial modifications
    applyAllWindowModifications();
    
    // Run the window modifier loop
    runWindowModifier();
    
    return NULL;
}
