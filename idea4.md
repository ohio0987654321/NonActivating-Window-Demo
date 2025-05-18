# Multi-Process Window Modifier: A Hybrid Injection Architecture

## Executive Summary

This document outlines a comprehensive refactoring strategy for the existing window modification proof-of-concept. The goal is to extend its capabilities to support multi-process applications like Discord while maintaining the full feature set (always-on-top, non-activating behavior, screen capture prevention, etc.) across diverse application frameworks.

Unlike the system-wide XPC approach (which research confirms has critical limitations), this hybrid architecture leverages targeted injection techniques but adds sophisticated process management, window interception, and cross-process communication layers. This approach acknowledges that core macOS window property modifications truly require in-process code execution, while addressing the complexity of today's multi-process application architectures.

## Technical Background

### Current State Assessment

The existing implementation consists of:

1. **Core Window Modifier**: Uses private AppKit methods, CoreGraphics APIs, and NSWindow property modifications
2. **Simple Injector**: Uses `DYLD_INSERT_LIBRARIES` to get code into the target process
3. **Discord-Specific Implementation**: Uses method swizzling and multiple detection strategies

### Key Challenges

1. **Multi-Process Architecture**
   - Modern applications use separate processes for main UI, rendering, GPU, networking, etc.
   - In Electron apps like Discord, window management responsibilities are split across processes
   - Process lifecycle is complex with dynamic creation and termination
   
2. **Technical Limitations**
   - Research confirms key window modifications (always-on-top, screen capture prevention) require in-process code execution
   - External approaches using Accessibility or CGWindowList can detect but cannot fully modify windows
   - Window IDs are ephemeral and cannot be reliably tracked across process restarts
   
3. **Security Constraints**
   - Hardened Runtime blocks standard DYLD injection
   - System Integrity Protection adds complexity to any injection mechanism
   - Process isolation mechanisms are strengthening with each macOS release

## Hybrid Architecture Overview

The proposed architecture consists of four integrated layers:

```
┌───────────────────────────────────────────────────────────────┐
│                     Process Management Layer                   │
│  Process detection, relationship mapping, targeted injection   │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│               Framework-Agnostic Window Interception           │
│    Method swizzling, notification hooks, window registry       │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│                 Cross-Process Communication                    │
│     IPC mechanism, coordination protocol, state sharing        │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│                   Core Modification Engine                     │
│  Abstraction API, compatibility layer, fallback mechanisms     │
└───────────────────────────────────────────────────────────────┘
```

This layered approach decouples the detection, management, communication, and modification aspects, creating a more maintainable and extensible system.

## Detailed Design

### 1. Process Management Layer

#### 1.1 Process Detection and Classification

The Process Manager must identify and categorize all processes within a target application:

```objective-c
@interface PMProcessInfo : NSObject

@property (nonatomic, readonly) pid_t pid;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *processName;
@property (nonatomic, readonly) PMProcessType processType;  // Main, Renderer, Helper, etc.
@property (nonatomic, readonly) pid_t parentPID;
@property (nonatomic, readonly) NSArray<PMProcessInfo *> *childProcesses;
@property (nonatomic, readonly) BOOL hasWindowCreationCapability;
@property (nonatomic, readonly) BOOL needsInjection;

@end
```

For Electron apps, the process detector would:
1. Identify the main Electron process
2. Track renderer processes (which may create windows)
3. Ignore helper processes (GPU, network) that don't create windows

#### 1.2 Process Relationship Tracking

```objective-c
@interface PMProcessManager : NSObject

// Detect all processes belonging to an application
- (NSArray<PMProcessInfo *> *)detectProcessesForApplication:(NSString *)bundleIdentifier;

// Monitor for new process launches
- (void)startProcessMonitoring:(void(^)(PMProcessInfo *newProcess))callback;

// Determine if a process needs window modification
- (BOOL)shouldInjectIntoProcess:(PMProcessInfo *)process;

// Get appropriate dylib path for process type
- (NSString *)dylibPathForProcess:(PMProcessInfo *)process;

@end
```

This subsystem would:
- Monitor process creation using `proc_listpids` and `proc_pidinfo`
- Build a process hierarchy using parent-child relationships
- Track command-line arguments to identify process roles
- Handle process termination and restart scenarios

#### 1.3 Targeted Injection Strategy

```c
typedef enum {
    InjectionMethodDYLD,     // Environment variable injection
    InjectionMethodPtrace,   // Direct memory manipulation (requires SIP disabled)
    InjectionMethodTask,     // task_for_pid based code loading
    InjectionMethodLauncher  // Wrapper/launcher approach
} InjectionMethod;

// Smart injection function
bool inject_into_process(pid_t pid, const char *dylib_path, InjectionMethod method) {
    // Validate we can inject into this process
    if (!can_inject(pid)) {
        return false;
    }
    
    // Select appropriate method based on process state and system security
    if (method == InjectionMethodAuto) {
        method = determine_best_injection_method(pid);
    }
    
    // Perform the injection using the selected method
    switch (method) {
        case InjectionMethodDYLD:
            return inject_using_dyld(pid, dylib_path);
        case InjectionMethodLauncher:
            return inject_using_launcher(pid, dylib_path);
        // Other methods...
    }
    
    return false;
}
```

This subsystem handles:
- Determining which processes need injection
- Selecting the appropriate injection mechanism based on process state
- Handling secure injection timing to catch window creation
- Monitoring injection success and retrying if needed

### 2. Framework-Agnostic Window Interception

#### 2.1 Multi-Strategy Window Detection

To catch windows across different frameworks, we implement multiple detection strategies:

```objective-c
@interface WIWindowInterceptor : NSObject

// Initialize with different detection strategies enabled
- (instancetype)initWithOptions:(WIDetectionOptions)options;

// Method swizzling for NSWindow creation
- (void)setupMethodSwizzling;

// Notification-based window detection
- (void)setupNotificationObservers;

// Periodic window scanning
- (void)startPeriodicWindowScan:(NSTimeInterval)interval;

// Window creation callback
@property (nonatomic, copy) void (^windowDetectedCallback)(NSWindow *window, WIDetectionMethod method);

@end
```

The interceptor would:
- Swizzle key NSWindow methods (`orderFront:`, `makeKeyAndOrderFront:`, etc.)
- Register for NSWindow notifications (`NSWindowDidBecomeKeyNotification`, etc.)
- Periodically scan `[NSApp windows]` to catch windows created by other means
- Support pattern-matching for window identification (title, size, class, etc.)

#### 2.2 Window Registry System

```objective-c
@interface WIWindowRegistry : NSObject

// Register a window with the system
- (void)registerWindow:(NSWindow *)window withIdentifier:(NSString *)identifier;

// Check if a window has been modified
- (BOOL)isWindowModified:(NSWindow *)window;

// Track window state
- (void)updateWindowState:(NSWindow *)window withModifications:(WIModificationFlags)flags;

// Create a fingerprint for window tracking
- (NSString *)createFingerprintForWindow:(NSWindow *)window;

// Find window by various attributes
- (NSWindow *)findWindowMatchingCriteria:(NSDictionary *)criteria;

@end
```

This subsystem:
- Maintains a registry of all detected windows
- Creates persistent identifiers for windows that survive reopening
- Tracks which modifications have been applied to which windows
- Handles window destruction and recreation scenarios
- Shares window information across process boundaries

#### 2.3 Framework-Specific Adapters

To handle different application frameworks, we implement adapters:

```objective-c
@protocol WIFrameworkAdapter <NSObject>

// Check if this adapter can handle the current application
+ (BOOL)canHandleCurrentApplication;

// Initialize the adapter
- (instancetype)initWithProcessInfo:(PMProcessInfo *)processInfo;

// Get framework-specific window detection hooks
- (NSArray<WIDetectionHook *> *)getWindowDetectionHooks;

// Customize window modifications for this framework
- (void)customizeModifications:(WIModificationContext *)context forWindow:(NSWindow *)window;

@end

// Concrete implementations
@interface WIElectronAdapter : NSObject <WIFrameworkAdapter>
@end

@interface WITauriAdapter : NSObject <WIFrameworkAdapter>
@end

@interface WIWebKitAdapter : NSObject <WIFrameworkAdapter>
@end
```

These adapters provide framework-specific knowledge:
- Where and how windows are created
- Special handling for framework-specific window subclasses
- Appropriate timing for modifications
- Framework-specific workarounds for limitations

### 3. Cross-Process Communication

#### 3.1 IPC Mechanism

```objective-c
@interface CPCommunicationChannel : NSObject

// Initialize with process info
- (instancetype)initWithProcessInfo:(PMProcessInfo *)processInfo;

// Send a message to another process
- (void)sendMessage:(CPMessage *)message toProcess:(pid_t)targetPID;

// Broadcast a message to all related processes
- (void)broadcastMessage:(CPMessage *)message;

// Register for message reception
- (void)registerMessageHandler:(void(^)(CPMessage *message, pid_t sourcePID))handler
                     forMessageType:(CPMessageType)type;

@end
```

The IPC layer would:
- Use a combination of shared memory and Mach ports or XPC for fast communication
- Provide reliable message delivery with acknowledgments
- Support both targeted and broadcast messaging patterns
- Handle connection management and reconnection scenarios

#### 3.2 Coordination Protocol

```objective-c
@interface CPCoordinator : NSObject

// Register this process's capabilities
- (void)registerCapabilities:(CPProcessCapabilities)capabilities;

// Announce a window was detected locally
- (void)announceWindowDetected:(CPWindowInfo *)windowInfo;

// Request window modification in another process
- (void)requestWindowModification:(CPWindowInfo *)windowInfo
                     inProcess:(pid_t)targetPID
                    completion:(void(^)(BOOL success))completion;

// Synchronize configuration across processes
- (void)syncConfiguration:(NSDictionary *)config;

@end
```

This protocol would enable:
- Process discovery and capability exchange
- Window announcement and tracking across process boundaries
- Coordinated modifications when a window appears in one process but needs changes in another
- Configuration synchronization to ensure consistent behavior

#### 3.3 State Persistence

```objective-c
@interface CPStateManager : NSObject

// Save state to persistent storage
- (void)saveState;

// Restore state after process restart
- (void)restoreState;

// Register window state
- (void)registerWindowState:(CPWindowState *)state;

// Update window state
- (void)updateWindowState:(CPWindowState *)state;

// Find window state by identifier
- (CPWindowState *)findWindowStateByIdentifier:(NSString *)identifier;

@end
```

This component ensures:
- Window modifications persist across application restarts
- Configuration settings remain consistent
- Process relationship information is preserved
- Recovery from crashes or unexpected terminations

### 4. Core Modification Engine

#### 4.1 Unified Modification API

```objective-c
@interface MEModifier : NSObject

// Apply a set of modifications to a window
- (BOOL)applyModifications:(MEModificationSet *)modifications
                  toWindow:(NSWindow *)window
                    options:(MEModificationOptions)options;

// Make a window non-activating
- (BOOL)makeWindowNonActivating:(NSWindow *)window;

// Make a window always-on-top
- (BOOL)makeWindowAlwaysOnTop:(NSWindow *)window
                        level:(NSWindowLevel)level;

// Prevent screen capture
- (BOOL)preventScreenCapture:(NSWindow *)window;

// Set space behavior
- (BOOL)setSpaceBehavior:(NSWindowCollectionBehavior)behavior
                forWindow:(NSWindow *)window;

@end
```

This API would:
- Provide a clean, unified interface for all window modifications
- Handle different modification strategies internally
- Implement fallback mechanisms when primary methods fail
- Track modification success and report detailed errors

#### 4.2 Compatibility Layer

```objective-c
@interface MECompatibilityManager : NSObject

// Check if a specific modification is supported
- (BOOL)isModificationSupported:(MEModificationType)type
                    onPlatform:(MEPlatformVersion)platform;

// Get alternative implementation for unsupported modification
- (id<MEModificationStrategy>)alternativeForUnsupportedModification:(MEModificationType)type;

// Register custom modification strategies
- (void)registerModificationStrategy:(id<MEModificationStrategy>)strategy
                             forType:(MEModificationType)type
                            priority:(NSInteger)priority;

@end
```

This layer handles:
- macOS version-specific behavior and API availability
- Framework-specific compatibility issues
- Fallback strategies when primary methods are unavailable
- Dynamic loading of modification techniques based on availability

#### 4.3 Method Resolution and Fallbacks

```objective-c
@protocol MEModificationStrategy <NSObject>

// Check if this strategy can be applied
- (BOOL)canApplyToWindow:(NSWindow *)window;

// Apply the modification
- (BOOL)applyToWindow:(NSWindow *)window withContext:(MEModificationContext *)context;

// Get priority relative to other strategies
- (NSInteger)priority;

// Get supported platforms
- (NSArray<NSNumber *> *)supportedPlatforms;

@end
```

The engine would implement multiple strategies for each modification:
- AppKit API strategies (using standard APIs when available)
- Private API strategies (using private but stable private methods)
- CGS-based strategies (using CoreGraphics Server functions)
- Swizzling-based strategies (intercepting and modifying window behavior)
- Composite strategies (combining multiple approaches for greater reliability)

## Implementation Strategy

### 1. Phase 1: Process Management and Basic Injection

Implement the core process detection and management system:
- Process hierarchy construction
- Process type identification
- Basic injection mechanism for identified processes
- Process monitoring for new/terminated processes

This phase produces a foundational layer that can identify and inject into all processes of a multi-process application.

### 2. Phase 2: Window Interception Framework

Build the window detection and tracking system:
- Multiple window detection strategies
- Window registry with persistent identification
- Framework detection and adaptation
- Initial set of framework adapters (Electron, native AppKit)

This phase enables reliable window detection across different application frameworks and process types.

### 3. Phase 3: Cross-Process Communication

Develop the IPC system to coordinate across processes:
- Basic IPC channel implementation
- Message protocol for window announcements
- Coordination for window modifications
- Configuration synchronization

This phase allows the various injected library instances to communicate and coordinate actions.

### 4. Phase 4: Enhanced Modification Engine

Refine the window modification capabilities:
- Unified modification API
- Multiple strategy implementation for each modification
- Fallback mechanisms
- Compatibility layer for different macOS versions

This phase completes the system with robust window modification capabilities.

### 5. Phase 5: Integration and Optimization

Combine all components into a cohesive system:
- End-to-end testing with multiple application types
- Performance optimization
- Error handling and recovery
- User configuration interface

## Technical Challenges and Mitigations

### Challenge 1: Hardened Runtime Blocking Injection

**Mitigation:**
- Implement multiple injection strategies
- Use a launcher-based approach for hardened applications
- Explore limited code signing options for development use

### Challenge 2: Window Creation Timing

**Mitigation:**
- Implement multiple detection strategies
- Use early process injection for critical processes
- Employ periodic scanning as a fallback

### Challenge 3: Process Independence and Communication

**Mitigation:**
- Robust IPC with reliability features
- State persistence to handle process restarts
- Fingerprinting for window identification across process boundaries

### Challenge 4: Framework Differences

**Mitigation:**
- Adapter system to handle framework-specific behaviors
- Extensive testing across framework types
- Fallback mechanisms when framework detection fails

## Testing Methodology

### 1. Multi-Process Testing

Test across applications with different process architectures:
- Electron apps (Discord, Slack, VS Code)
- WebKit-based apps (Safari, Chrome)
- Tauri apps
- Native AppKit applications

### 2. Feature Testing

Verify each window modification feature works correctly:
- Always-on-top behavior
- Non-activating interaction
- Screen capture prevention
- Mission Control visibility
- Spaces behavior

### 3. Reliability Testing

Stress test the system under various conditions:
- Rapid window creation/destruction
- Application restarts
- System sleep/wake cycles
- Different macOS versions

### 4. Performance Testing

Measure system impact and optimize:
- CPU usage during normal operation
- Memory footprint
- Injection timing
- Window modification latency

## Conclusion

The hybrid architecture described here combines the power of in-process window modification with the flexibility needed to handle modern multi-process applications. By breaking down the system into layered components with clear responsibilities, we create a solution that is both powerful and maintainable.

Unlike the external XPC approach, this solution can deliver the full feature set by running code within each relevant process. Unlike the original implementation, it can handle the complexity of multi-process applications by coordinating across process boundaries.

This architecture represents a significant step forward in window modification capabilities, enabling powerful features like always-on-top, non-activating interaction, and screen capture prevention across modern application frameworks.
