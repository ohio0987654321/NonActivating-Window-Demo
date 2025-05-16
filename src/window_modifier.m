// window_modifier.m
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>

// Declare NSWindow private methods
@interface NSWindow (PrivateMethods)
- (void)_setPreventsActivation:(BOOL)preventsActivation;
@end

// CGS Function Declaration
typedef int CGSConnectionID;
typedef int CGSWindowID;
#define kCGSPreventsActivationTagBit (1 << 16)
#define kCGSWindowSharingNoneValue 0

typedef CGSConnectionID (*CGSDefaultConnection_t)(void);
typedef CGError (*CGSSetWindowLevel_t)(CGSConnectionID, CGSWindowID, int);
typedef CGError (*CGSSetWindowSharingState_t)(CGSConnectionID, CGSWindowID, int);
typedef CGError (*CGSSetWindowTags_t)(CGSConnectionID, CGSWindowID, int*, int);

static CGSDefaultConnection_t CGSDefaultConnection_ptr = NULL;
static CGSSetWindowLevel_t CGSSetWindowLevel_ptr = NULL;
static CGSSetWindowSharingState_t CGSSetWindowSharingState_ptr = NULL;
static CGSSetWindowTags_t CGSSetWindowTags_ptr = NULL;

// global state
static NSRunningApplication *previousFrontmostApp = nil;

// Save previous app
static void saveFrontmostApp(void) {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (frontApp && ![frontApp.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        previousFrontmostApp = frontApp;
        printf("Saved frontmost app: %s\n", [frontApp.localizedName UTF8String]);
    }
}

// Return focus to previous app
static void restoreFrontmostApp(void) {
    if (previousFrontmostApp) {
        [previousFrontmostApp activateWithOptions:0];
        printf("Restored focus to: %s\n", [previousFrontmostApp.localizedName UTF8String]);
    }
}

// Load CGS functions
static void loadCGSFunctions(void) {
    void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    if (!handle) return;
    
    CGSDefaultConnection_ptr = (CGSDefaultConnection_t)dlsym(handle, "_CGSDefaultConnection");
    if (!CGSDefaultConnection_ptr) {
        CGSDefaultConnection_ptr = (CGSDefaultConnection_t)dlsym(handle, "CGSMainConnectionID");
    }
    
    CGSSetWindowLevel_ptr = (CGSSetWindowLevel_t)dlsym(handle, "CGSSetWindowLevel");
    CGSSetWindowSharingState_ptr = (CGSSetWindowSharingState_t)dlsym(handle, "CGSSetWindowSharingState");
    CGSSetWindowTags_ptr = (CGSSetWindowTags_t)dlsym(handle, "CGSSetWindowTags");
    
    printf("CGS functions loaded: %s\n", CGSDefaultConnection_ptr ? "Success" : "Failed");
}

// Deactivate Window
static bool makeSingleWindowNonActivating(NSWindow *window) {
    if (!window) return false;
    
    // Use NSWindow's private methods
    if ([window respondsToSelector:@selector(_setPreventsActivation:)]) {
        [window _setPreventsActivation:YES];
        printf("Applied _setPreventsActivation:YES to window %p\n", (__bridge void*)window);
        return true;
    }
    
    // Use CGSSetWindowTags (backup)
    if (CGSDefaultConnection_ptr && CGSSetWindowTags_ptr) {
        CGSConnectionID cid = CGSDefaultConnection_ptr();
        CGSWindowID wid = (CGSWindowID)[window windowNumber];
        
        if (wid == 0) return false;
        
        int tags[1] = { kCGSPreventsActivationTagBit };
        CGError err = CGSSetWindowTags_ptr(cid, wid, tags, 1);
        
        if (err == 0) {
            printf("Set window tag kCGSPreventsActivationTagBit for window %p\n", (__bridge void*)window);
            return true;
        }
    }
    
    printf("Warning: Failed to apply non-activating behavior to window %p\n", (__bridge void*)window);
    return false;
}

// Fixes applied to all windows
bool applyAllWindowModifications(void) {
    saveFrontmostApp();
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Apply to each window
        for (NSWindow *window in [NSApp windows]) {
            // 1. deactivation
            makeSingleWindowNonActivating(window);
            
            // 2. always in the forefront
            window.level = NSFloatingWindowLevel;
            
            // 3. screen capture bypass
            window.sharingType = NSWindowSharingNone;
            
            // Mission control display
            window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | 
                                       NSWindowCollectionBehaviorParticipatesInCycle | 
                                       NSWindowCollectionBehaviorManaged;
            
            // 5. panel specific settings (for NSPanel)
            if ([window isKindOfClass:[NSPanel class]]) {
                NSPanel *panel = (NSPanel *)window;
                [panel setBecomesKeyOnlyIfNeeded:YES];
                [panel setWorksWhenModal:YES];
                [panel setHidesOnDeactivate:NO];
                printf("Applied panel settings to panel %p\n", (__bridge void*)panel);
            } else {
                printf("Applied window settings to window %p\n", (__bridge void*)window);
            }
        }
        
        // Return to focus on previous application
        restoreFrontmostApp();
    });
    
    return true;
}

// initialization process
bool initWindowModifier(void) {
    loadCGSFunctions();
    saveFrontmostApp();
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Temporarily made into a normal app for Mission Control display
        if ([NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        
        // Apply window modification
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            applyAllWindowModifications();
            
            // Return to accessories app
            if ([NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
                [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
                printf("Application set to accessory mode\n");
            }
        });
    });
    
    return true;
}

// Main Entry Point
void* window_modifier_main(void* arg) {
    printf("Window modifier starting up...\n");
    
    initWindowModifier();
    
    // Wait until the application window is created
    sleep(1);
    
    // Regularly apply fixes
    while (1) {
        sleep(3);
        applyAllWindowModifications();
    }
    
    return NULL;
}