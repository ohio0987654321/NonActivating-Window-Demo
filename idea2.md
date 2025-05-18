# Revised Window Modifier Injection for Multi-Process Applications

## 1. Executive Summary

This document outlines our revised approach to extending the Window Modifier Injection PoC for multi-process applications like Discord. Based on technical research and feedback, we've refined our strategy to address security limitations, focus on core processes, and implement a more reliable architecture. The solution maintains all our original modification goals while adopting a more targeted and efficient implementation approach.

## 2. Core Objectives

The window modifier will continue to provide the following enhancements to application windows:

- **Always-on-top behavior**: Windows remain above other applications
- **Non-activating interaction**: Windows don't steal focus when interacted with
- **Screen recording bypass**: Windows can be excluded from screen captures
- **Mission Control visibility**: Windows appear correctly in Mission Control
- **Active appearance**: Windows maintain active title bar appearance

## 3. Revised Architecture

### 3.1 Key Architecture Changes

Based on technical research, we've made these fundamental changes to our approach:

1. **Targeted Process Injection**: Focus primarily on the Electron main process where window management occurs, rather than injecting into all child processes
   
2. **Security-Aware Injection**: Address hardened runtime and library validation constraints with appropriate injection techniques
   
3. **Simplified Modification Logic**: Replace complex strategy patterns with direct, efficient window modifications
   
4. **Reliable Process Monitoring**: Use robust system APIs and hooks for process detection and tracking

### 3.2 High-Level Architecture

```
┌────────────────────────────────────┐
│         Launcher/Injector          │
│  - Handles initial process launch  │
│  - Manages injection into main proc│
└─────────────────┬──────────────────┘
                  │
                  ▼
┌────────────────────────────────────┐
│      Process Monitor/Router        │
│  - Uses NSWorkspace notifications  │
│  - Monitors for relevant processes │
│  - Intercepts new process creation │
└─────────────────┬──────────────────┘
                  │
                  ▼
┌────────────────────────────────────┐
│         Window Hook System         │
│  - Swizzles NSWindow methods       │
│  - Observes window notifications   │
│  - Applies window modifications    │
└────────────────────────────────────┘
```

## 4. Injection Strategy

### 4.1 Target Process Identification

Research confirms that in Electron applications like Discord:

- The **main process** is responsible for creating and managing NSWindow instances via the BrowserWindow module
- Renderer processes primarily draw web content but do not typically own native windows
- Other processes (GPU, utilities) have no direct window management role

Our revised strategy targets the main process as the primary injection point, with conditional injection into renderer processes only if they are confirmed to manage windows.

### 4.2 Addressing Security Constraints

Modern Electron applications typically enable Hardened Runtime and library validation, which blocks traditional DYLD_INSERT_LIBRARIES injection. To address this:

1. **Initial Approach**: Use an application wrapper or launcher that injects using approved mechanisms
   
2. **Code Signing Considerations**: Either:
   - Use ad-hoc signing to bypass library validation when needed
   - Implement as a loadable plugin if the target application supports it
   
3. **Fallback Mechanisms**:
   - If direct injection fails, implement an Accessibility-based solution for basic window operations
   - Consider XPC services for inter-process communication if needed

### 4.3 Process Monitoring Method

For reliable process detection and tracking:

```objective-c
// Setup workspace notification observer
[[NSWorkspace sharedWorkspace].notificationCenter 
    addObserver:self 
    selector:@selector(applicationLaunched:) 
    name:NSWorkspaceDidLaunchApplicationNotification 
    object:nil];

// Process launch handler
- (void)applicationLaunched:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    
    // Check if this is a relevant process
    if ([self isElectronProcess:app]) {
        // Inject into the process if needed
        [self injectIntoProcess:app.processIdentifier];
    }
}

// For more reliable detection in child processes
- (BOOL)isElectronProcess:(NSRunningApplication *)app {
    // Check command line arguments - more reliable than process name
    NSArray *args = [self getProcessArguments:app.processIdentifier];
    return [args containsObject:@"--type=renderer"] || 
           [app.bundleIdentifier isEqualToString:@"com.discord.discord"];
}
```

For processes that don't trigger NSWorkspace notifications, we'll also implement function interposition to intercept process creation:

```objective-c
// Using mach_override or fishhook to intercept posix_spawn
int (*original_posix_spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                            const posix_spawnattr_t *, char *const [], char *const []);

int my_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions,
                   const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    
    // Call original spawn function
    int result = original_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    
    // If successful spawn and path contains relevant binary name
    if (result == 0 && strstr(path, "Electron") != NULL) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Allow process to initialize
            usleep(100000);
            // Inject into the new process
            inject_into_pid(*pid);
        });
    }
    
    return result;
}
```

## 5. Window Hook Implementation

### 5.1 Method Swizzling Approach

The revised approach uses targeted method swizzling to intercept window creation and modification:

```objective-c
+ (void)setupWindowModification {
    // Get NSWindow class
    Class windowClass = NSClassFromString(@"NSWindow");
    
    // Window creation
    SEL initSelector = @selector(initWithContentRect:styleMask:backing:defer:);
    Method initMethod = class_getInstanceMethod(windowClass, initSelector);
    
    IMP originalInit = method_getImplementation(initMethod);
    method_setImplementation(initMethod, imp_implementationWithBlock(^(id self, CGRect rect, 
                            NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer) {
        
        // Call original implementation
        NSWindow *window = ((NSWindow* (*)(id, SEL, CGRect, NSWindowStyleMask, 
                          NSBackingStoreType, BOOL))originalInit)
                          (self, initSelector, rect, style, backing, defer);
        
        // Apply modifications to the new window
        [WindowModifier applyModificationsToWindow:window];
        
        return window;
    }));
    
    // Window display methods
    [self swizzleSelector:@selector(orderFront:) inClass:windowClass];
    [self swizzleSelector:@selector(makeKeyAndOrderFront:) inClass:windowClass];
    [self swizzleSelector:@selector(makeKeyWindow) inClass:windowClass];
}

+ (void)swizzleSelector:(SEL)selector inClass:(Class)class {
    Method method = class_getInstanceMethod(class, selector);
    IMP originalImp = method_getImplementation(method);
    
    method_setImplementation(method, imp_implementationWithBlock(^(id self, id sender) {
        // Call original method
        ((void (*)(id, SEL, id))originalImp)(self, selector, sender);
        
        // Apply modifications after window operation
        [WindowModifier applyModificationsToWindow:self];
    }));
}
```

### 5.2 Window Modifier Logic

Rather than using multiple strategy classes, we'll use a simpler, more direct modification approach:

```objective-c
@implementation WindowModifier

+ (void)applyModificationsToWindow:(NSWindow *)window {
    // Skip unnecessary windows
    if (![self shouldModifyWindow:window]) return;
    
    @try {
        // 1. Make non-activating
        if ([window respondsToSelector:@selector(_setPreventsActivation:)]) {
            [window _setPreventsActivation:YES];
        }
        
        // 2. Set always-on-top level
        window.level = NSFloatingWindowLevel;
        
        // 3. Control screen capture behavior
        window.sharingType = NSWindowSharingNone;
        
        // 4. Configure Mission Control behavior
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | 
                                    NSWindowCollectionBehaviorParticipatesInCycle | 
                                    NSWindowCollectionBehaviorManaged;
        
        // 5. Special panel settings if needed
        if ([window isKindOfClass:[NSPanel class]]) {
            NSPanel *panel = (NSPanel *)window;
            [panel setBecomesKeyOnlyIfNeeded:YES];
            [panel setWorksWhenModal:YES];
            [panel setHidesOnDeactivate:NO];
        }
        
        // Log successful modification
        NSString *title = window.title.length > 0 ? window.title : @"Untitled Window";
        logInfo(@"Modified window: %@ (%p)", title, window);
        
    } @catch (NSException *e) {
        logError(@"Error modifying window: %@", e.reason);
    }
}

+ (BOOL)shouldModifyWindow:(NSWindow *)window {
    // Skip utility windows, sheets, etc.
    if (window.isFloatingPanel) return NO;
    
    // Skip windows that shouldn't be modified based on window class
    NSString *className = NSStringFromClass([window class]);
    if ([className containsString:@"HelperWindow"] || 
        [className containsString:@"OverlayWindow"]) return NO;
    
    return YES;
}

@end
```

### 5.3 Notification Observers

As a complementary approach to method swizzling, we'll also register for window notifications:

```objective-c
+ (void)setupNotificationObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    
    [center addObserverForName:NSWindowDidBecomeMainNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        NSWindow *window = note.object;
                        [WindowModifier applyModificationsToWindow:window];
                    }];
    
    [center addObserverForName:NSWindowDidBecomeKeyNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        NSWindow *window = note.object;
                        [WindowModifier applyModificationsToWindow:window];
                    }];
    
    // Similar observers for other window notifications
}
```

## 6. Testing Methodology

We'll implement a staged testing approach to validate each component:

### 6.1 Injection Testing

1. **Basic Injection Test**
   - Create a simple test app
   - Inject a minimal dylib that logs its presence
   - Verify the dylib loads and executes

2. **Hardened Runtime Test**
   - Enable Hardened Runtime on test app
   - Verify injection still works with our modified approach
   - Test library validation bypass techniques

### 6.2 Window Modification Testing

3. **Swizzling Test**
   - In an injected process, swizzle a simple NSWindow method (e.g., setTitle:)
   - Verify the swizzle takes effect

4. **Full Modification Test**
   - Apply all window modifications to a test window
   - Verify each modification works as expected (level, activation behavior, etc.)

### 6.3 Multi-Process Testing

5. **Process Monitoring Test**
   - Launch an app that creates child processes
   - Verify our monitoring catches all relevant processes

6. **Electron-Specific Test**
   - Test with a simple Electron app
   - Verify window modifications work in the correct processes

7. **Discord Integration Test**
   - Apply the complete solution to Discord
   - Verify all windows are properly modified
   - Test edge cases (new windows, pop-outs, etc.)

## 7. Implementation Plan

### 7.1 Phase 1: Core Injection Framework

1. Implement security-aware launcher/injector
2. Create process monitoring system using NSWorkspace and function interposition
3. Test injection on simple applications

### 7.2 Phase 2: Window Modification

4. Implement window hook system with swizzling and notification observers
5. Create window modifier with all required modifications
6. Test window modification on standard applications

### 7.3 Phase 3: Electron Integration

7. Add Electron-specific detection and handling
8. Implement application profiles for Discord and other targets
9. Test on Discord and refine approach

### 7.4 Phase 4: Refinement and Edge Cases

10. Address any reliability issues
11. Optimize performance and resource usage
12. Document the solution and its limitations

## 8. Potential Challenges and Mitigations

### 8.1 Hardened Runtime Limitations

**Challenge**: Modern applications may block library injection via Hardened Runtime and library validation.

**Mitigation**: 
- Use mach_inject or other low-level injection techniques
- Investigate if Discord has disabled library validation
- Provide an alternative launcher that temporarily disables validation

### 8.2 Process Monitoring Reliability

**Challenge**: Not all processes trigger workspace notifications, potentially missing some child processes.

**Mitigation**:
- Combine multiple detection mechanisms (NSWorkspace + function interposition)
- Periodically scan for new processes with matching criteria
- Hook process creation functions within the main process

### 8.3 Window Discovery Edge Cases

**Challenge**: Some windows may be created through non-standard means or have unusual class hierarchies.

**Mitigation**:
- Implement multiple parallel detection strategies
- Use a periodic window check as a fallback
- Add logging to identify missed windows

### 8.4 macOS Version Compatibility

**Challenge**: Different macOS versions may have different security models or APIs.

**Mitigation**:
- Test on multiple macOS versions
- Add version-specific code paths where needed
- Document version limitations

## 9. Conclusion

This revised approach addresses the technical concerns raised by the research team while maintaining our core window modification objectives. By focusing on the main process, using robust process monitoring, and implementing efficient window hooks, we can create a solution that works reliably with Discord and other multi-process applications.

The design is now more:
- **Targeted**: Focusing on processes that actually manage windows
- **Efficient**: Minimizing overhead with simpler, more direct modifications
- **Reliable**: Using multiple detection methods to ensure no windows are missed
- **Security-aware**: Addressing modern macOS security constraints

This approach gives us the highest likelihood of success while maintaining code quality and performance.
