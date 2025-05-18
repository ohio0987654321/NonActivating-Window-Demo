# System-Wide Window Proxy via XPC

## Executive Summary

This document proposes a framework-agnostic approach to enhance macOS application windows with special properties (always-on-top, non-activating behavior, screen recording bypass, etc.) without relying on library injection or framework-specific code. The system uses Apple's public CoreGraphics and XPC APIs to detect and modify windows at the window server level, working universally across all application types, including hardened apps like Discord, Tauri, and WebKit-based applications.

## 1. Architecture Overview

### 1.1 Key Components

The System-Wide Window Proxy consists of three main components:

1. **Launch Agent**: A user-level daemon that runs continuously in the background, monitoring window creation system-wide
2. **XPC Service**: A privileged service that handles window property modifications and maintains state
3. **Control Application**: A user interface for configuring rules and monitoring status

```
┌─────────────────────┐     ┌─────────────────────┐
│ Control Application │◄────┤ User Configuration  │
└──────────┬──────────┘     └─────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────┐
│               Launch Agent                       │
│                                                  │
│  ┌─────────────┐    ┌───────────────────────┐    │
│  │Window       │    │Process/Application    │    │
│  │Monitor      │    │Monitor                │    │
│  └──────┬──────┘    └────────┬──────────────┘    │
│         │                    │                    │
│         ▼                    ▼                    │
│  ┌─────────────┐    ┌───────────────────────┐    │
│  │Window       │    │Rule Matching &        │    │
│  │Registry     │◄───┤Application            │    │
│  └──────┬──────┘    │Identification         │    │
│         │           └───────────────────────┘    │
└─────────┼──────────────────────────────────────┬─┘
          │                                      │
          ▼                                      ▼
┌─────────────────────┐            ┌───────────────────────┐
│ XPC Window          │            │ State Persistence     │
│ Modification Service│            │ & Configuration       │
└─────────────────────┘            └───────────────────────┘
```

### 1.2 System Flow

1. The Launch Agent initializes on user login, loading configured rules
2. Window Monitor continuously polls for window creation/modification using CGWindowListCreateDescriptionFromArray
3. When a window matching configured rules is detected, the agent dispatches modification requests to the XPC service
4. The XPC service applies modifications using CoreGraphics APIs
5. The service maintains state to reapply modifications as needed (e.g., after window moves or changes)

## 2. Technical Implementation

### 2.1 Window Detection Strategy

The system uses multiple detection mechanisms to ensure reliability:

#### 2.1.1 Window List Monitoring

```objective-c
- (void)startWindowMonitoring {
    // Create a timer that fires at regular intervals (e.g., 0.5 seconds)
    self.windowMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                               target:self
                                                             selector:@selector(checkForNewWindows)
                                                             userInfo:nil
                                                              repeats:YES];
}

- (void)checkForNewWindows {
    // Get all windows in the system
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    
    // Process each window
    CFIndex count = CFArrayGetCount(windowList);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef windowInfo = CFArrayGetValueAtIndex(windowList, i);
        
        // Extract window ID and owner PID
        CGWindowID windowID = [(__bridge NSDictionary *)windowInfo[kCGWindowNumber] unsignedIntValue];
        pid_t ownerPID = [(__bridge NSDictionary *)windowInfo[kCGWindowOwnerPID] intValue];
        
        // Check if this is a new window we haven't processed yet
        if (![self.knownWindows containsObject:@(windowID)]) {
            [self processNewWindow:windowID withOwnerPID:ownerPID info:(__bridge NSDictionary *)windowInfo];
        } else {
            // Check for changed windows and update if needed
            [self checkWindowForChanges:windowID withInfo:(__bridge NSDictionary *)windowInfo];
        }
    }
    
    CFRelease(windowList);
}
```

#### 2.1.2 Process Launch Monitoring

```objective-c
- (void)setupProcessMonitoring {
    // Register for application launch notifications
    [[NSWorkspace sharedWorkspace].notificationCenter 
        addObserver:self
           selector:@selector(applicationLaunched:)
               name:NSWorkspaceDidLaunchApplicationNotification
             object:nil];
    
    // Register for application termination notifications
    [[NSWorkspace sharedWorkspace].notificationCenter 
        addObserver:self
           selector:@selector(applicationTerminated:)
               name:NSWorkspaceDidTerminateApplicationNotification
             object:nil];
}

- (void)applicationLaunched:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    
    // Check if this application matches our rules
    if ([self.targetApplications containsObject:app.bundleIdentifier]) {
        // Schedule an immediate window check and several follow-ups
        // (to catch windows that appear during app initialization)
        [self checkForNewWindows];
        
        // Schedule additional checks with increasing delays
        [self performSelector:@selector(checkForNewWindows) withObject:nil afterDelay:0.5];
        [self performSelector:@selector(checkForNewWindows) withObject:nil afterDelay:1.0];
        [self performSelector:@selector(checkForNewWindows) withObject:nil afterDelay:2.0];
    }
}
```

### 2.2 Window Modification Techniques

The XPC service implements window modifications using CoreGraphics APIs:

#### 2.2.1 Window Positioning and Level

```objective-c
- (void)setWindowLevel:(CGWindowID)windowID level:(CGWindowLevel)level {
    // Technique 1: Using CoreGraphics SPI (Requires entitlements)
    CGSSetWindowLevel(CGSMainConnectionID(), windowID, level);
    
    // Technique 2: Using public APIs (more limited)
    CGSConnectionID connection = CGSMainConnectionID();
    
    // Get window bounds
    CGRect bounds;
    CGSGetWindowBounds(connection, windowID, &bounds);
    
    // Create a window description
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                                              &kCFTypeDictionaryKeyCallBacks,
                                                              &kCFTypeDictionaryValueCallBacks);
    
    // Set the new level
    CFNumberRef levelValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &level);
    CFDictionarySetValue(options, CFSTR("Level"), levelValue);
    
    // Apply changes
    CGSOrderWindow(connection, windowID, kCGSOrderAbove, 0);
    
    CFRelease(levelValue);
    CFRelease(options);
}
```

#### 2.2.2 Window Properties Modification

```objective-c
- (void)setWindowSharingType:(CGWindowID)windowID sharingType:(CGSWindowSharingType)sharingType {
    // Set window sharing type (screen capture)
    CGSConnectionID connection = CGSMainConnectionID();
    CGSSetWindowSharingState(connection, windowID, sharingType);
}

- (void)setWindowCollectionBehavior:(CGWindowID)windowID behavior:(NSWindowCollectionBehavior)behavior {
    // This requires working with Window Server SPI or Accessibility APIs
    
    // Technique 1: Using CoreGraphics SPI
    int tags = 0;
    
    // Convert NSWindowCollectionBehavior to CGS tags
    if (behavior & NSWindowCollectionBehaviorCanJoinAllSpaces)
        tags |= kCGSTagSticky;
    
    if (behavior & NSWindowCollectionBehaviorMoveToActiveSpace)
        tags |= kCGSTagNoShadow; // Not exact mapping
    
    CGSSetWindowTags(CGSMainConnectionID(), windowID, &tags, 32);
    
    // Technique 2: Find window via Accessibility and modify (requires permissions)
    AXUIElementRef app = AXUIElementCreateApplication(windowOwnerPID);
    if (app) {
        CFArrayRef windowArray = NULL;
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windowArray);
        
        if (windowArray) {
            // Find matching window and apply modifications
            // ...
            
            CFRelease(windowArray);
        }
        CFRelease(app);
    }
}
```

#### 2.2.3 Non-activating Windows

```objective-c
- (void)makeWindowNonActivating:(CGWindowID)windowID ownerPID:(pid_t)ownerPID {
    // This is the most challenging modification as it typically requires
    // private API access within the app process
    
    // Approach 1: Using CGSConnection APIs
    CGSSetWindowAlpha(CGSMainConnectionID(), windowID, 0.999); // Nearly invisible change
    CGSSetWindowFlags(CGSMainConnectionID(), windowID, kCGSWindowIsNonactivating);
    
    // Approach 2: Using Accessibility APIs (limited effectiveness)
    AXUIElementRef app = AXUIElementCreateApplication(ownerPID);
    // Find window and set attributes that minimize activation impact
    // ...
    
    // Approach 3: Advanced Window Server SPI (limited availability)
    // This would require additional research on private APIs
}
```

### 2.3 XPC Service Implementation

The XPC service provides a secure, privileged interface for window modifications:

```objective-c
// XPC Service Interface
@protocol WindowModifierService

- (void)setWindowLevel:(CGWindowID)windowID level:(CGWindowLevel)level;
- (void)setWindowSharingType:(CGWindowID)windowID sharingType:(CGSWindowSharingType)sharingType;
- (void)setWindowCollectionBehavior:(CGWindowID)windowID behavior:(NSWindowCollectionBehavior)behavior;
- (void)makeWindowNonActivating:(CGWindowID)windowID ownerPID:(pid_t)ownerPID;
- (void)applyAllModifications:(CGWindowID)windowID ownerPID:(pid_t)ownerPID;

@end

// XPC Service Implementation
@interface WindowModifierService : NSObject <WindowModifierService>
@end

@implementation WindowModifierService

- (void)applyAllModifications:(CGWindowID)windowID ownerPID:(pid_t)ownerPID {
    // Apply cached configuration for this window/app
    WindowModificationConfig *config = [self configForWindowID:windowID ownerPID:ownerPID];
    
    if (config.alwaysOnTop) {
        [self setWindowLevel:windowID level:kCGFloatingWindowLevel];
    }
    
    if (config.preventScreenCapture) {
        [self setWindowSharingType:windowID sharingType:kCGSWindowSharingNone];
    }
    
    if (config.showInAllSpaces) {
        [self setWindowCollectionBehavior:windowID 
                                 behavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
    }
    
    if (config.nonActivating) {
        [self makeWindowNonActivating:windowID ownerPID:ownerPID];
    }
    
    // Log the modification for debugging
    NSLog(@"Applied modifications to window %u (PID: %d)", windowID, ownerPID);
}

// Other implementation methods...

@end
```

### 2.4 Launch Agent Configuration

The Launch Agent is installed as a user-level daemon:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.windowmodifieragent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/Application Support/WindowModifier/WindowModifierAgent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

## 3. Rule-Based Configuration System

### 3.1 Application and Window Matching Rules

```objective-c
@interface WindowRule : NSObject

@property (nonatomic, strong) NSString *bundleIdentifier;  // Application bundle ID
@property (nonatomic, strong) NSString *windowTitlePattern; // Regex for window title
@property (nonatomic, assign) CGSize minWindowSize;        // Min window dimensions
@property (nonatomic, assign) CGSize maxWindowSize;        // Max window dimensions

// Modification flags
@property (nonatomic, assign) BOOL alwaysOnTop;
@property (nonatomic, assign) BOOL nonActivating;
@property (nonatomic, assign) BOOL preventScreenCapture;
@property (nonatomic, assign) BOOL showInAllSpaces;
@property (nonatomic, assign) BOOL showInMissionControl;

@end

// Rule matching logic
- (BOOL)windowMatchesRule:(CGWindowID)windowID info:(NSDictionary *)windowInfo rule:(WindowRule *)rule {
    // Check application bundle ID
    NSString *bundleID = [self bundleIDForPID:[windowInfo[kCGWindowOwnerPID] intValue]];
    if (rule.bundleIdentifier && ![bundleID isEqualToString:rule.bundleIdentifier]) {
        return NO;
    }
    
    // Check window title using regex
    if (rule.windowTitlePattern) {
        NSString *windowTitle = windowInfo[kCGWindowName];
        if (!windowTitle || ![self string:windowTitle matchesPattern:rule.windowTitlePattern]) {
            return NO;
        }
    }
    
    // Check window size constraints
    CGRect bounds;
    CGSGetWindowBounds(CGSMainConnectionID(), windowID, &bounds);
    
    if (!CGSizeEqualToSize(rule.minWindowSize, CGSizeZero)) {
        if (bounds.size.width < rule.minWindowSize.width ||
            bounds.size.height < rule.minWindowSize.height) {
            return NO;
        }
    }
    
    if (!CGSizeEqualToSize(rule.maxWindowSize, CGSizeZero)) {
        if (bounds.size.width > rule.maxWindowSize.width ||
            bounds.size.height > rule.maxWindowSize.height) {
            return NO;
        }
    }
    
    return YES;
}
```

### 3.2 Configuration Persistence

```objective-c
- (void)saveConfiguration {
    NSMutableArray *rulesArray = [NSMutableArray array];
    
    for (WindowRule *rule in self.rules) {
        [rulesArray addObject:@{
            @"bundleIdentifier": rule.bundleIdentifier ?: @"",
            @"windowTitlePattern": rule.windowTitlePattern ?: @"",
            @"minWidth": @(rule.minWindowSize.width),
            @"minHeight": @(rule.minWindowSize.height),
            @"maxWidth": @(rule.maxWindowSize.width),
            @"maxHeight": @(rule.maxWindowSize.height),
            @"alwaysOnTop": @(rule.alwaysOnTop),
            @"nonActivating": @(rule.nonActivating),
            @"preventScreenCapture": @(rule.preventScreenCapture),
            @"showInAllSpaces": @(rule.showInAllSpaces),
            @"showInMissionControl": @(rule.showInMissionControl)
        }];
    }
    
    // Save to user preferences
    [[NSUserDefaults standardUserDefaults] setObject:rulesArray forKey:@"WindowModifierRules"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
```

## 4. Technical Challenges and Solutions

### 4.1 Window Server Limitations

**Challenge**: Not all window properties can be modified through CoreGraphics APIs, especially with hardened applications.

**Solution**: 
- Implement tiered capabilities based on what's possible with public APIs
- Provide graceful fallbacks when certain modifications can't be applied
- Use multiple combined techniques for greater effectiveness

### 4.2 Window Identification Stability

**Challenge**: Window IDs can change when windows are hidden/shown or applications restart.

**Solution**:
- Maintain a registry mapping window properties (title, position, size) to configurations
- Re-identify windows after application restarts
- Use multiple identification techniques beyond just window ID

```objective-c
- (void)trackWindowChanges:(CGWindowID)windowID info:(NSDictionary *)windowInfo {
    // Create a fingerprint for this window
    NSString *windowTitle = windowInfo[kCGWindowName] ?: @"";
    pid_t ownerPID = [windowInfo[kCGWindowOwnerPID] intValue];
    NSString *ownerName = windowInfo[kCGWindowOwnerName] ?: @"";
    CGRect bounds;
    CGSGetWindowBounds(CGSMainConnectionID(), windowID, &bounds);
    
    NSString *fingerprint = [NSString stringWithFormat:@"%@|%@|%d|%.0f,%.0f",
                            windowTitle, ownerName, ownerPID, bounds.size.width, bounds.size.height];
    
    // Store the fingerprint mapping
    self.windowFingerprints[@(windowID)] = fingerprint;
    self.fingerprintToWindowID[fingerprint] = @(windowID);
    
    // When a window disappears, we can use the fingerprint to recognize it if it reappears
}
```

### 4.3 Performance and Resource Usage

**Challenge**: Constantly polling the window list could impact system performance.

**Solution**:
- Implement adaptive polling frequencies based on system activity
- Focus monitoring on target applications rather than all system windows
- Batch window modification operations to reduce IPC overhead

```objective-c
- (void)adjustPollingFrequency {
    // Get system load
    double loadAverage;
    if (getloadavg(&loadAverage, 1) == 1) {
        // Adjust polling interval based on system load
        NSTimeInterval interval = MIN(MAX(0.1, loadAverage / 2.0), 2.0);
        
        // Update timer if needed
        if (fabs(interval - self.windowMonitorTimer.timeInterval) > 0.1) {
            [self.windowMonitorTimer invalidate];
            self.windowMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                                     target:self
                                                                   selector:@selector(checkForNewWindows)
                                                                   userInfo:nil
                                                                    repeats:YES];
        }
    }
}
```

### 4.4 Security and Permissions

**Challenge**: Some operations require elevated privileges or user authorization.

**Solution**:
- Use the principle of least privilege in the XPC service design
- Request only the necessary permissions during installation
- Provide clear user documentation on required permissions

## 5. Testing Methodology

### 5.1 Basic Functionality Tests

1. **Window Detection Test**
   - Launch various applications (native, Electron, Tauri, etc.)
   - Verify the system correctly detects and identifies windows
   - Test with normal, minimized, and hidden windows

2. **Window Modification Test**
   - Apply each modification type individually
   - Verify modifications persist across window operations
   - Test with both native and non-native applications

### 5.2 Edge Case Testing

1. **Application Lifecycle Testing**
   - Launch, quit, and restart target applications
   - Verify modifications are reapplied correctly
   - Test with application updates and version changes

2. **Window Transformation Testing**
   - Minimize, maximize, resize, and move windows
   - Switch between normal and fullscreen modes
   - Test behavior with Mission Control and Spaces

3. **System Integration Testing**
   - Test interaction with system features (e.g., Screenshot, Mission Control)
   - Verify behavior during login/logout and system sleep/wake
   - Test compatibility with different macOS versions

### 5.3 Performance Testing

1. **Resource Usage Monitoring**
   - Monitor CPU, memory, and energy impact
   - Test with many simultaneous windows
   - Measure impact on system responsiveness

2. **Long-running Stability Test**
   - Run the system for extended periods
   - Monitor for memory leaks or degraded performance
   - Test with typical daily usage patterns

## 6. Implementation Plan

### 6.1 Phase 1: Core Window Detection

1. Implement Launch Agent framework
2. Create window monitoring system using CGWindowListCreateDescriptionFromArray
3. Build window registry and identification system
4. Test basic window detection across application types

### 6.2 Phase 2: XPC Service Development

5. Implement XPC service for window modifications
6. Create basic window property modification functions
7. Develop rule-based configuration system
8. Test modification persistence and reliability

### 6.3 Phase 3: Enhanced Capabilities

9. Implement advanced window property modifications
10. Add performance optimizations and adaptive polling
11. Create user interface for configuration
12. Conduct comprehensive testing across application types

### 6.4 Phase 4: Refinement and Documentation

13. Address edge cases and reliability issues
14. Optimize performance and resource usage
15. Create installation package and documentation
16. Conduct final validation and user testing

## 7. Advantages Over Previous Approaches

1. **Universal Compatibility**: Works with any application regardless of framework, hardening, or architecture
2. **Maintenance Simplicity**: Single codebase works across all application types without framework-specific code
3. **Stability**: Uses public APIs that are less likely to change across macOS versions
4. **Security**: Does not require bypassing hardened runtime or library validation
5. **Robustness**: Window modifications persist across application restarts and updates

## 8. Limitations and Considerations

1. **Limited Modification Scope**: Some deep window properties may not be modifiable without direct injection
2. **Performance Impact**: Real-time window monitoring has some system impact
3. **Permission Requirements**: May require user authorization for certain operations
4. **Technical Complexity**: Requires careful synchronization between window state and modifications

## 9. Conclusion

The System-Wide Window Proxy via XPC approach provides a robust, framework-agnostic solution for enhancing windows in macOS applications. By operating at the window server level rather than within application processes, it bypasses the limitations of hardened runtime and library validation while maintaining compatibility across multiple application frameworks.

This approach strikes a balance between capability, reliability, and maintainability. It avoids the complexity of framework-specific code while still providing effective window modifications for applications like Discord, regardless of their underlying architecture.
