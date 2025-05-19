// window_classifier.m - Window classification and tracking
#import "window_classifier.h"
#import "../cgs/window_modifier_cgs.h"
#import <objc/runtime.h>

// Global state for classifier
static NSMutableDictionary *windowClassCache = nil;
static NSMutableDictionary *windowInitStateCache = nil;
static window_class_callback_t classificationCallback = NULL;

// Forward declarations
static window_class_t classifyWindowWithInfo(CGSWindowID windowID, NSDictionary *windowInfo);
static void updateWindowInitState(CGSWindowID windowID, int eventType);
static bool is_window_classified(CGSWindowID windowID);

// Initialize the window classifier
bool init_window_classifier(void) {
    // Create caches
    windowClassCache = [[NSMutableDictionary alloc] init];
    windowInitStateCache = [[NSMutableDictionary alloc] init];
    
    return (windowClassCache != nil && windowInitStateCache != nil);
}

// Clean up the window classifier
void cleanup_window_classifier(void) {
    // Release caches
    windowClassCache = nil;
    windowInitStateCache = nil;
    
    classificationCallback = NULL;
}

// Register for window classification
void register_classification_callback(window_class_callback_t callback) {
    classificationCallback = callback;
}

// Track window event
void track_window_event(CGSWindowID windowID, int eventType) {
    if (windowID <= 0) {
        return;
    }
    
    // Update window initialization state
    updateWindowInitState(windowID, eventType);
    
    // Trigger classification if needed
    if (!is_window_classified(windowID)) {
        // Get window info
        NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
        if (windowInfo) {
            // Classify window
            window_class_t classification = classifyWindowWithInfo(windowID, windowInfo);
            
            // Cache classification
            NSNumber *key = @(windowID);
            NSNumber *value = @(classification);
            [windowClassCache setObject:value forKey:key];
            
            // Notify callback if registered
            if (classificationCallback) {
                classificationCallback(windowID, classification);
            }
        }
    }
}

// Check if window is classified
static bool is_window_classified(CGSWindowID windowID) {
    NSNumber *key = @(windowID);
    return [windowClassCache objectForKey:key] != nil;
}

// Check if window is standard
bool is_window_standard(CGSWindowID windowID) {
    NSNumber *key = @(windowID);
    NSNumber *currentClass = [windowClassCache objectForKey:key];
    
    if (currentClass) {
        return [currentClass intValue] == WINDOW_CLASS_STANDARD;
    }
    
    // If not classified yet, classify it now
    NSDictionary *windowInfo = getWindowInfoWithCGS(windowID);
    if (!windowInfo) {
        return false;
    }
    
    window_class_t classification = classifyWindowWithInfo(windowID, windowInfo);
    
    // Cache the result
    [windowClassCache setObject:@(classification) forKey:key];
    
    return classification == WINDOW_CLASS_STANDARD;
}

// Check if window is fully initialized
bool is_window_initialized(CGSWindowID windowID) {
    NSNumber *key = @(windowID);
    NSDictionary *stateDict = [windowInitStateCache objectForKey:key];
    
    if (stateDict) {
        NSNumber *stateNum = stateDict[@"state"];
        return (([stateNum unsignedIntValue] & WINDOW_STATE_FULLY_INITIALIZED) == 
                WINDOW_STATE_FULLY_INITIALIZED);
    }
    
    return false;
}

// Update window initialization state
static void updateWindowInitState(CGSWindowID windowID, int eventType) {
    NSNumber *key = @(windowID);
    NSMutableDictionary *stateDict = [windowInitStateCache objectForKey:key];
    
    if (!stateDict) {
        // Create new state
        stateDict = [NSMutableDictionary dictionary];
        [stateDict setObject:@(0) forKey:@"state"];
        [stateDict setObject:@(time(NULL)) forKey:@"firstSeen"];
        
        [windowInitStateCache setObject:stateDict forKey:key];
    }
    
    // Get current state
    NSNumber *stateNum = stateDict[@"state"];
    uint32_t state = [stateNum unsignedIntValue];
    
    // Update state based on event type
    switch (eventType) {
        case kCGSWindowDidCreateNotification:
            state |= WINDOW_STATE_CREATED;
            break;
            
        case kCGSWindowDidOrderInNotification:
            state |= WINDOW_STATE_VISIBLE;
            break;
            
        case kCGSWindowDidResizeNotification:
            state |= WINDOW_STATE_SIZED;
            break;
            
        case kCGSWindowDidUpdateNotification:
            state |= WINDOW_STATE_CONTENT_READY;
            break;
    }
    
    // Update state in dictionary
    [stateDict setObject:@(state) forKey:@"state"];
}

// Classify window based on CGS properties
static window_class_t classifyWindowWithInfo(CGSWindowID windowID, NSDictionary *windowInfo) {
    if (!windowInfo) {
        return WINDOW_CLASS_UNKNOWN;
    }
    
    // Get window level - important for classification
    NSNumber *level = windowInfo[@"kCGSWindowLevel"];
    int windowLevel = level ? [level intValue] : 0;
    
    // Get window tags
    NSNumber *tagsNum = windowInfo[@"kCGSWindowTags"];
    uint32_t tags = tagsNum ? [tagsNum unsignedIntValue] : 0;
    
    // Get window alpha
    NSNumber *alpha = windowInfo[@"kCGSWindowAlpha"];
    float windowAlpha = alpha ? [alpha floatValue] : 1.0;
    
    // Get sharing state
    NSNumber *sharingState = windowInfo[@"kCGSWindowSharingState"];
    int sharing = sharingState ? [sharingState intValue] : 0;
    
    // Get window type
    NSString *windowType = windowInfo[@"kCGSWindowTitle"];
    
    // Check for utility window (helper, panel, etc.)
    if (windowLevel >= 19 && windowLevel <= 23) {
        return WINDOW_CLASS_PANEL;
    }
    
    // Check for sheet (attached to parent window)
    if (windowInfo[@"kCGSWindowParentID"] != nil) {
        return WINDOW_CLASS_SHEET;
    }
    
    // Check for system windows
    if (windowLevel < 0 || windowLevel > 25) {
        return WINDOW_CLASS_SYSTEM;
    }
    
    // Check for transparent or invisible windows
    if (windowAlpha < 0.1) {
        return WINDOW_CLASS_HELPER;
    }
    
    // Check for standard application window
    if (windowLevel == 0 || windowLevel == 1 || windowLevel == 4) {
        // Standard window
        return WINDOW_CLASS_STANDARD;
    }
    
    // Default to standard if nothing else matched
    return WINDOW_CLASS_STANDARD;
}
