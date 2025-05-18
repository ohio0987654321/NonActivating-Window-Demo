# Research Report: Extending Window Modifier Injection for Multi-Process Applications

## 1. Executive Summary

This research report analyzes the current Window Modifier Injection proof-of-concept (PoC) and outlines a comprehensive refactoring approach to extend its functionality to multi-process applications like Discord. The current implementation works well for traditional single-process applications but lacks support for modern multi-process architectures used by Electron-based applications.

## 2. Project Context

### 2.1 What is Window Modifier Injection?

Window Modifier Injection enhances macOS application windows with special properties by injecting custom code at runtime, enabling features like:

- Always-on-top windows that stay above other applications
- Non-activating windows that don't steal focus when interacted with
- Screen capture bypass to prevent windows from appearing in recordings
- Persistent Mission Control visibility and appearance customization

These modifications are valuable for utility applications, development and accessibility tools, and specialized interfaces that need to remain accessible without disrupting workflow.

### 2.2 Current Architecture

The existing implementation consists of three core components:

1. **Window Modifier (`window_modifier.m`)**: Core logic that applies window modifications using private AppKit methods and CGS APIs, running in a continuous loop to repeatedly enhance all application windows.

2. **Injection Entry Point (`injection_entry.c`)**: Constructor-based entry point that creates a detached thread to run the window modifier.

3. **Injector (`injector.c`)**: Command-line tool that injects the dylib into target applications using the DYLD_INSERT_LIBRARIES environment variable.

### 2.3 Discord-Specific Implementation

The Discord implementation (`discord_final.m`) uses a markedly different approach:

1. **Process Awareness**: Identifies if it's running in a renderer process or main process
2. **Event-Based Detection**: Uses method swizzling to intercept window creation events
3. **Multiple Discovery Mechanisms**: Employs notification observers, delayed initialization, and periodic checks
4. **Robust Error Handling**: Implements process-specific logging and exception management

## 3. Multi-Process Application Challenges

### 3.1 Electron Architecture

Modern applications like Discord are built on Electron, which uses a multi-process architecture:

- **Main Process**: Controls application lifecycle and coordinates other processes
- **Renderer Processes**: Create and manage UI windows (where modification needs to happen)
- **GPU/Utility Processes**: Handle specialized tasks like hardware acceleration

### 3.2 Current Limitations

1. **Single-Process Targeting**: Current injector only affects the main executable
2. **Limited Window Discovery**: Windows in renderer processes remain unmodified
3. **No Process Lifecycle Awareness**: Cannot detect and inject into new child processes
4. **Different Window Creation Patterns**: Current timing mechanisms may miss Electron's window creation

## 4. Proposed Refactoring Strategy

### 4.1 Architecture Overview

We propose a comprehensive refactoring with three main components:

1. **Enhanced Multi-Process Injector**
   - Application profile detection to identify architecture types
   - Child process monitoring to track new processes
   - Dynamic injection capability for runtime process management

2. **Process-Aware Window Modifier**
   - Process type detection to customize behavior by process role
   - Unified modification interface using strategy pattern
   - Multiple window discovery mechanisms combined

3. **Configuration System**
   - Application profiles for common multi-process applications
   - Runtime configuration options for behavior customization

### 4.2 Implementation Approach

#### 4.2.1 Process Detection and Monitoring

For child process detection and monitoring, we can use:

```c
// Process type detection
typedef enum {
    PROCESS_TYPE_MAIN,
    PROCESS_TYPE_RENDERER,
    PROCESS_TYPE_GPU,
    PROCESS_TYPE_UTILITY,
    PROCESS_TYPE_UNKNOWN
} process_type_t;

// Process detection implementation
process_type_t detect_process_type() {
    NSString *procName = [[NSProcessInfo processInfo] processName];
    
    if ([procName containsString:@"Renderer"]) return PROCESS_TYPE_RENDERER;
    if ([procName containsString:@"GPU"]) return PROCESS_TYPE_GPU;
    if ([procName containsString:@"Utility"]) return PROCESS_TYPE_UTILITY;
    
    // Check bundle identifier to determine if main process
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([known_main_processes containsObject:bundleID]) {
        return PROCESS_TYPE_MAIN;
    }
    
    return PROCESS_TYPE_UNKNOWN;
}
```

#### 4.2.2 Window Modification Strategy

We'll implement a strategy pattern for window modifications:

```objective-c
// Window modification strategy interface
@protocol WindowModificationStrategy
- (BOOL)applyToWindow:(NSWindow *)window;
@end

// Implementation for different strategies
@interface NonActivatingModifier : NSObject <WindowModificationStrategy>
@end

@interface AlwaysOnTopModifier : NSObject <WindowModificationStrategy>
@end

// Main coordinator class
@interface WindowModifier : NSObject
@property (nonatomic, strong) NSArray<id<WindowModificationStrategy>> *strategies;
@property (nonatomic, assign) process_type_t processType;

- (instancetype)initWithProcessType:(process_type_t)type;
- (BOOL)applyToWindow:(NSWindow *)window;
- (BOOL)applyToAllWindows;
@end
```

#### 4.2.3 Process-Specific Behaviors

Different process types will have different responsibilities:

```objective-c
// Apply behaviors based on process type
- (void)setupForProcessType:(process_type_t)type {
    switch (type) {
        case PROCESS_TYPE_MAIN:
            // Setup child process monitoring
            [self setupProcessMonitoring];
            break;
            
        case PROCESS_TYPE_RENDERER:
            // Setup window event interception
            [self setupWindowSwizzling];
            [self setupNotificationObservers];
            [self startPeriodicChecks];
            break;
            
        case PROCESS_TYPE_GPU:
        case PROCESS_TYPE_UTILITY:
            // Minimal setup for non-window processes
            break;
            
        default:
            // Conservative approach for unknown processes
            [self setupBasicWindowDetection];
            break;
    }
}
```

#### 4.2.4 Application Profiles

Application profiles will contain configuration for different applications:

```objective-c
// Application profile structure
typedef struct {
    const char *name;
    const char *bundleID;
    const char *mainProcessPattern;
    const char *rendererProcessPatterns[5];
    BOOL needsNonActivating;
    BOOL needsAlwaysOnTop;
    BOOL needsScreenCaptureBypass;
    int refreshInterval;
} AppProfile;

// Example profiles
static AppProfile kDiscordProfile = {
    .name = "Discord",
    .bundleID = "com.discord.discord",
    .mainProcessPattern = "^Discord$",
    .rendererProcessPatterns = {"Discord Helper.*Renderer", NULL},
    .needsNonActivating = YES,
    .needsAlwaysOnTop = YES,
    .needsScreenCaptureBypass = YES,
    .refreshInterval = 2
};

static AppProfile kSlackProfile = {
    .name = "Slack",
    .bundleID = "com.slack.Slack",
    .mainProcessPattern = "^Slack$",
    .rendererProcessPatterns = {"Slack Helper.*Renderer", NULL},
    .needsNonActivating = YES,
    .needsAlwaysOnTop = YES, 
    .needsScreenCaptureBypass = YES,
    .refreshInterval = 2
};

// Profile detection
AppProfile* detectAppProfile() {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    
    // Check against known profiles
    if ([bundleID isEqualToString:@"com.discord.discord"]) {
        return &kDiscordProfile;
    }
    else if ([bundleID isEqualToString:@"com.slack.Slack"]) {
        return &kSlackProfile;
    }
    
    // Default generic profile
    return &kGenericElectronProfile;
}
```

### 4.3 Integration Approach

To tie everything together, we'll implement:

1. **A launcher script generator** that creates application-specific launchers
2. **A dynamic injection manager** for handling process lifecycle events
3. **A unified window modification system** that applies the right strategies in each process

## 5. Implementation Roadmap

### 5.1 Phase 1: Core Refactoring

1. **Create the unified window modifier interface**
   - Implement strategy pattern for different modification types
   - Add abstraction layer for window discovery methods

2. **Implement process type detection**
   - Add utilities to identify process roles
   - Create process-specific behavior configurations

### 5.2 Phase 2: Multi-Process Support

3. **Enhance the injector for multi-process support**
   - Implement child process monitoring
   - Create dynamic injection capability

4. **Create the application profile system**
   - Define profiles for common applications
   - Implement profile-based configuration

### 5.3 Phase 3: Testing and Optimization

5. **Test with multiple application types**
   - Validate with Discord and other Electron apps
   - Test with non-Electron multi-process applications

6. **Optimize performance**
   - Minimize overhead in renderer processes
   - Optimize process monitoring techniques

## 6. Challenges and Mitigations

### 6.1 Security Restrictions

**Challenge:** System Integrity Protection may prevent injection into certain processes.

**Mitigation:**
- Implement fallback mechanisms for restricted environments
- Investigate XPC services for alternative communication approaches

### 6.2 Performance Considerations

**Challenge:** Continuous process monitoring could introduce overhead.

**Mitigation:**
- Use efficient process monitoring techniques
- Implement adaptive polling with exponential backoff
- Leverage existing IPC mechanisms where possible

### 6.3 Reliability Concerns

**Challenge:** Different applications create windows through diverse mechanisms.

**Mitigation:**
- Implement multiple parallel window detection strategies
- Use application profiles to customize for specific architectures
- Include thorough error handling and recovery

## 7. Conclusion

By refactoring the Window Modifier Injection PoC to support multi-process applications, we can create a robust solution that works across different application architectures without requiring application-specific implementations. The proposed approach combines the strengths of the original implementation with the more sophisticated techniques from the Discord-specific solution, creating a flexible framework that can adapt to various multi-process application patterns.

