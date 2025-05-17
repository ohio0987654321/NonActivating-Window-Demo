// discord_final.m - Final robust Discord window modifier
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <pthread.h>  // Added for pthread functions

// Ensure logs are visible
static void safe_log(const char *format, ...) {
    va_list args;
    va_start(args, format);
    
    // Print with distinctive prefix
    printf("[DISCORD-MOD] ");
    vprintf(format, args);
    printf("\n");
    
    // Ensure output is flushed immediately
    fflush(stdout);
    
    va_end(args);
}

// Try to identify the process we're running in
static void identify_process(void) {
    NSString *procName = [[NSProcessInfo processInfo] processName];
    pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
    
    safe_log("Process: %s (PID: %d)", [procName UTF8String], pid);
    
    // Check if we're in a renderer process
    if ([procName containsString:@"Renderer"]) {
        safe_log("Detected renderer process - will attempt window modification");
    } else {
        safe_log("Not a renderer process - window modification may not work");
    }
}

// The window modifier function that will be swizzled into NSWindow
static void window_appeared(NSWindow *window) {
    if (!window) return;
    
    @try {
        NSString *title = [window title];
        NSRect frame = [window frame];
        
        safe_log("Window appeared: %p, Title: %s, Size: %.0fx%.0f", 
              (__bridge void*)window, 
              [title UTF8String] ?: "(no title)",
              frame.size.width, 
              frame.size.height);
        
        // Check if this looks like a main window
        if (frame.size.width >= 500 && frame.size.height >= 400) {
            safe_log("Modifying Discord window...");
            
            // 1. Set always-on-top
            window.level = NSFloatingWindowLevel;
            safe_log("Set floating window level");
            
            // 2. Set non-activating
            if ([window respondsToSelector:@selector(_setPreventsActivation:)]) {
                [window performSelector:@selector(_setPreventsActivation:) 
                             withObject:@YES];
                safe_log("Set non-activating window");
            }
            
            // 3. Set all-spaces
            window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | 
                                       NSWindowCollectionBehaviorParticipatesInCycle | 
                                       NSWindowCollectionBehaviorManaged;
            safe_log("Set all-spaces behavior");
            
            // 4. Set screen capture bypass
            window.sharingType = NSWindowSharingNone;
            safe_log("Set screen capture bypass");
            
            safe_log("Successfully modified Discord window");
        }
    } @catch (NSException *e) {
        safe_log("Exception while modifying window: %s", [[e description] UTF8String]);
    }
}

// Setup Swizzling for NSWindow
static void setup_window_swizzling(void) {
    safe_log("Setting up window swizzling");
    
    @try {
        // Get NSWindow class
        Class windowClass = NSClassFromString(@"NSWindow");
        if (!windowClass) {
            safe_log("Failed to get NSWindow class");
            return;
        }
        
        // Try several methods that might be called when a window appears
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
                safe_log("Method %s not found", selectorNames[i]);
                continue;
            }
            
            // Get original implementation
            IMP originalImp = method_getImplementation(method);
            
            // FIXED: Capture the selector outside the block
            SEL currentSelector = selectors[i];
            
            // Create new implementation
            IMP newImp = imp_implementationWithBlock(^(id self, id sender) {
                // Call original method with the captured selector
                ((void (*)(id, SEL, id))originalImp)(self, currentSelector, sender);
                
                // Now that the window has appeared, modify it
                window_appeared((NSWindow *)self);
            });
            
            // Replace method implementation
            method_setImplementation(method, newImp);
            safe_log("Successfully swizzled %s", selectorNames[i]);
        }
        
        safe_log("Swizzling complete");
    } @catch (NSException *e) {
        safe_log("Exception during swizzling: %s", [[e description] UTF8String]);
    }
}

// Check for and modify all existing windows
static void check_existing_windows(void) {
    safe_log("Checking for existing windows");
    
    @try {
        if (!NSApp) {
            safe_log("NSApp is nil, cannot access windows");
            return;
        }
        
        NSArray *windows = [NSApp windows];
        safe_log("Found %lu existing windows", (unsigned long)[windows count]);
        
        for (NSWindow *window in windows) {
            window_appeared(window);
        }
    } @catch (NSException *e) {
        safe_log("Exception checking existing windows: %s", [[e description] UTF8String]);
    }
}

// Set up notification observer for windows
static void setup_window_observer(void) {
    safe_log("Setting up window observer");
    
    @try {
        [[NSNotificationCenter defaultCenter] 
            addObserverForName:NSWindowDidBecomeKeyNotification 
                        object:nil 
                         queue:[NSOperationQueue mainQueue] 
                    usingBlock:^(NSNotification *note) {
            NSWindow *window = note.object;
            if (window) {
                safe_log("Window notification received");
                window_appeared(window);
            }
        }];
        
        safe_log("Window observer set up successfully");
    } @catch (NSException *e) {
        safe_log("Exception setting up window observer: %s", [[e description] UTF8String]);
    }
}

// Periodic window check thread
static void* window_check_thread(void* arg) {
    safe_log("Window check thread started");
    
    // Wait for app to initialize
    sleep(5);
    safe_log("Initial delay complete");
    
    // Check for existing windows
    check_existing_windows();
    
    // Periodic check
    for (int i = 0; i < 30; i++) {
        sleep(3);
        safe_log("Periodic window check #%d", i + 1);
        check_existing_windows();
    }
    
    safe_log("Window check thread complete");
    return NULL;
}

// Main entry point
__attribute__((constructor))
void dylib_entry(void) {
    @autoreleasepool {
        // Make sure logs are visible immediately
        setbuf(stdout, NULL);
        
        safe_log("Discord Final Modifier v1.0 loaded!");
        
        // Identify the current process
        identify_process();
        
        // Use dispatch_after to ensure UI is ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            safe_log("Delayed initialization starting");
            
            // Set up swizzling
            setup_window_swizzling();
            
            // Set up window observer
            setup_window_observer();
            
            // Start window check thread
            pthread_t check_thread;
            if (pthread_create(&check_thread, NULL, window_check_thread, NULL) == 0) {
                pthread_detach(check_thread);
                safe_log("Window check thread created");
            } else {
                safe_log("Failed to create window check thread");
            }
            
            safe_log("Initialization complete");
        });
    }
}