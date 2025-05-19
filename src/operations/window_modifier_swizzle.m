//  window_modifier_swizzle.m - Method swizzling implementation for NSWindow
#import "window_modifier_swizzle.h"
#import "window_modifier.h"
#import "../tracker/window_registry.h"
#import <objc/runtime.h>

// External function to register a window as modified
extern window_registry_t *window_registry;

// Forward declaration of the swizzled method
@interface NSWindow (WindowModifierSwizzling)
- (instancetype)wm_initWithContentRect:(NSRect)contentRect 
                            styleMask:(NSWindowStyleMask)style 
                              backing:(NSBackingStoreType)backingStoreType 
                                defer:(BOOL)flag;
- (void)wm_makeKeyAndOrderFront:(id)sender;
@end

// Implementation of the swizzled methods
@implementation NSWindow (WindowModifierSwizzling)

- (instancetype)wm_initWithContentRect:(NSRect)contentRect 
                            styleMask:(NSWindowStyleMask)style 
                              backing:(NSBackingStoreType)backingStoreType 
                                defer:(BOOL)flag {
    // Call original implementation first
    NSWindow *window = [self wm_initWithContentRect:contentRect 
                                         styleMask:style 
                                           backing:backingStoreType 
                                             defer:flag];
    
    // Don't apply modifications to utility, sheet, or panel windows
    if (style & NSWindowStyleMaskUtilityWindow || 
        style & NSWindowStyleMaskDocModalWindow || 
        window.level > NSNormalWindowLevel) {
        return window;
    }
    
    // Don't modify windows that are too small (likely helper/utility windows)
    if (contentRect.size.width < 100 || contentRect.size.height < 50) {
        return window;
    }

    // Schedule the modification for after window creation is complete
    dispatch_async(dispatch_get_main_queue(), ^{
        // Modify the window
        modifyNSWindow(window);
    });
    
    return window;
}

- (void)wm_makeKeyAndOrderFront:(id)sender {
    // Call the original implementation first
    [self wm_makeKeyAndOrderFront:sender];
    
    // Get the window number to check in registry
    CGSWindowID windowID = (CGSWindowID)[self windowNumber];
    
    // Don't modify windows that are too small (likely helper/utility windows)
    if (self.frame.size.width < 100 || self.frame.size.height < 50) {
        return;
    }
    
    // Check if this window needs modification
    if (windowID > 0 && window_registry && !registry_is_window_modified(window_registry, windowID)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Modify the window
            modifyNSWindow(self);
            
            // Mark as modified in registry
            registry_mark_window_modified(window_registry, windowID);
            
            // Temporarily set app to regular mode for Mission Control display
            // This helps with maintaining visibility in Mission Control
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                if (NSApp && [NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
                    // Store original activation policy
                    NSApplicationActivationPolicy originalPolicy = [NSApp activationPolicy];
                    
                    // Briefly switch to regular mode
                    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
                    
                    // Return to original policy after a short delay
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), 
                                   dispatch_get_main_queue(), ^{
                        [NSApp setActivationPolicy:originalPolicy];
                    });
                }
            });
        });
    }
}

@end

// Initialize method swizzling
void initializeWindowSwizzling(void) {
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        Class class = [NSWindow class];
        
        // Swizzle initialization method
        SEL originalInitSelector = @selector(initWithContentRect:styleMask:backing:defer:);
        SEL swizzledInitSelector = @selector(wm_initWithContentRect:styleMask:backing:defer:);
        
        Method originalInitMethod = class_getInstanceMethod(class, originalInitSelector);
        Method swizzledInitMethod = class_getInstanceMethod(class, swizzledInitSelector);
        
        if (class_addMethod(class, originalInitSelector, 
                          method_getImplementation(swizzledInitMethod), 
                          method_getTypeEncoding(swizzledInitMethod))) {
            class_replaceMethod(class, swizzledInitSelector, 
                              method_getImplementation(originalInitMethod), 
                              method_getTypeEncoding(originalInitMethod));
        } else {
            method_exchangeImplementations(originalInitMethod, swizzledInitMethod);
        }
        
        // Swizzle makeKeyAndOrderFront: method for catching windows as they're shown
        SEL originalShowSelector = @selector(makeKeyAndOrderFront:);
        SEL swizzledShowSelector = @selector(wm_makeKeyAndOrderFront:);
        
        Method originalShowMethod = class_getInstanceMethod(class, originalShowSelector);
        Method swizzledShowMethod = class_getInstanceMethod(class, swizzledShowSelector);
        
        if (class_addMethod(class, originalShowSelector, 
                          method_getImplementation(swizzledShowMethod), 
                          method_getTypeEncoding(swizzledShowMethod))) {
            class_replaceMethod(class, swizzledShowSelector, 
                              method_getImplementation(originalShowMethod), 
                              method_getTypeEncoding(originalShowMethod));
        } else {
            method_exchangeImplementations(originalShowMethod, swizzledShowMethod);
        }
        
        NSLog(@"[WindowModifier] Successfully initialized method swizzling for NSWindow");
    });
}
