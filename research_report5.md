# Window Modifier Refactoring Plan: System-Level Approach for Multi-Process Support

## Executive Summary

This document presents a system-level approach to refactoring the Window Modifier utility to support multi-process applications like Discord, Slack, and VS Code. Rather than implementing framework-specific solutions that would require ongoing maintenance as frameworks evolve, this plan proposes leveraging low-level macOS mechanisms to create a framework-agnostic solution similar to how our existing CGS API implementation successfully handles both AppKit and non-AppKit windows.

The architecture focuses on macOS kernel primitives, system APIs, and OS-level integration to provide a solution that will remain robust across changes in application frameworks and future macOS updates.

## 1. System-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Security Foundation                      │
│ Binary Patching, Code Signing, Entitlement Configuration    │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                 Process Monitoring Daemon                    │
│ Process Detection, Relationship Tracking, Injection Control  │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                 Universal Injection System                   │
│ Multi-technique Injection, Dynamic Loader Manipulation       │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│              OS-Level Window Interception                    │
│ WindowServer Integration, System-Wide Window Monitoring      │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│              Low-Level Communication Layer                   │
│ Kernel Primitives, Shared Memory, Mach Messaging            │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                Core Window Modification Engine               │
│ CGS API, Window Behavior Control, Focus Management          │
└─────────────────────────────────────────────────────────────┘
```

## 2. Component Details

### 2.1 Security Foundation

This layer handles macOS security constraints and prepares applications for modification:

**Binary Patching & Code Signing**
- Implements minimal, targeted patches to application binaries rather than full re-signing
- Focuses on dynamic loader configuration sections that control DYLD behavior
- Creates and manages code signing certificates when needed
- Preserves original code signature for validation while enabling injection

**Dynamic Entitlement Management**
- Temporarily alters process entitlements during runtime rather than permanently modifying the binary
- Utilizes task_for_pid-based entitlement manipulation techniques
- Implements "just-in-time" entitlement granting for minimum security impact

**Backup & Recovery**
- Creates efficient, delta-based backups for easy restoration
- Maintains application integrity through atomic operations
- Implements fallback mechanisms for interrupted operations

### 2.2 Process Monitoring Daemon

A persistent system service that manages application processes:

**System-Level Process Detection**
- Utilizes kernel-level process notifications via `process_set_dyld_image_notifier` hooks
- Monitors process creation using `kqueue` with `EVFILT_PROC` events
- Implements efficient process relationship tracking using BSD process group IDs
- Captures process launches through `launchd` interposition

**Process Relationship Mapping**
- Builds process hierarchy trees using `proc_pidinfo` with `PROC_PIDLISTCHILDPIDS`
- Identifies application bundles and all related processes by executable paths
- Maintains real-time graph of process relationships for targeting

**Injection Controller**
- Determines optimal injection timing based on process state
- Coordinates multiple injection techniques
- Manages recovery from failed injections
- Implements adaptive injection based on process characteristics

### 2.3 Universal Injection System

A flexible system supporting multiple injection techniques:

**Multi-technique Injection Framework**
- Implements DYLD environment variable injection (primary method)
- Supports mach_inject for runtime process injection
- Utilizes task_for_pid and thread manipulation for targeted injection
- Develops LC_LOAD_DYLIB binary modification as a fallback mechanism

**Dynamic Loader Manipulation**
- Creates custom DYLD interposition points
- Implements targeted function hooking in the dynamic loader
- Develops DYLD cache manipulation techniques
- Utilizes dyld_process_info API for process analysis

**Process Launch Control**
- Intercepts process creation to inject into child processes
- Modifies process launch environments via launchd integration
- Implements execve/posix_spawn wrappers for launch-time injection
- Develops comprehensive spawn monitoring for all process creation paths

### 2.4 OS-Level Window Interception

A framework-agnostic approach to window detection:

**WindowServer Integration**
- Leverages CGWindowListCopyWindowInfo for system-wide window monitoring
- Implements window events subscription via CGSEventRecord hooks
- Utilizes private CGS APIs for direct WindowServer communication
- Develops SPI registration for window creation notifications

**Window Ownership Tracking**
- Maps windows to processes using CGWindowListCopyWindowInfo owner PIDs
- Implements window-to-process correlation algorithms
- Maintains comprehensive window registry with ownership information
- Develops heuristics for identifying window relationships

**Window Creation Interception**
- Hooks low-level window creation primitives common to all frameworks
- Implements early-stage CoreGraphics callbacks
- Utilizes surface creation monitoring via IOKit connections
- Develops pre-composition hooks for all window types

### 2.5 Low-Level Communication Layer

Efficient, reliable inter-process communication:

**Kernel Primitives**
- Implements shared memory regions for high-performance state sharing
- Utilizes Mach ports for direct message passing
- Develops semaphore-based synchronization mechanisms
- Creates memory-mapped files for state persistence

**Minimal Protocol**
- Designs a binary protocol with minimal overhead
- Implements message prioritization for critical operations
- Develops reliable delivery guarantees
- Creates compact state representation formats

**Fault Tolerance**
- Implements reconnection mechanisms for process restarts
- Develops state recovery procedures
- Creates timeout and retry logic for all operations
- Implements error detection and correction protocols

### 2.6 Core Window Modification Engine

The existing, proven modification mechanism with enhancements:

**CGS API Integration**
- Leverages existing CGS-based window modification techniques
- Extends API usage for multi-process scenarios
- Implements fallback mechanisms for API changes
- Develops comprehensive error recovery

**Window Behavior Control**
- Enhances always-on-top implementation for multi-process windows
- Refines non-activating window behavior
- Improves screen capture prevention
- Extends Mission Control integration

**Focus Management**
- Enhances cross-process focus preservation
- Implements robust focus tracking across application boundaries
- Develops optimized context switching mechanisms
- Creates consistent focus restoration protocols

## 3. Implementation Approach

### 3.1 Layered Development

The implementation will follow a bottom-up approach:

1. **Core Infrastructure** (3-4 weeks)
   - Process monitoring daemon foundation
   - Basic IPC mechanisms
   - Initial security tooling

2. **Process Management & Injection** (4-5 weeks)
   - Complete process detection system
   - Universal injection framework
   - Process relationship tracking

3. **Window System Integration** (3-4 weeks)
   - WindowServer monitoring
   - Window-to-process mapping
   - Creation interception mechanisms

4. **Coordination & Synchronization** (2-3 weeks)
   - Full IPC protocol implementation
   - Cross-process state management
   - Timing coordination systems

5. **Modification Extensions** (2-3 weeks)
   - Multi-process window modification techniques
   - Focus management enhancements
   - Performance optimizations

6. **Testing & Refinement** (2-3 weeks)
   - Comprehensive testing across application types
   - Edge case identification and resolution
   - Performance profiling and optimization

### 3.2 Key Implementation Decisions

**Binary Modification vs. Re-signing**
- Minimal, targeted binary modifications rather than full re-signing
- Focus on specific binary sections affecting dynamic loading
- Preserve code signature validity where possible

**Process Identification Strategy**
- Process lineage tracking rather than framework-specific markers
- Bundle identifier and executable path analysis for application grouping
- Comprehensive parent-child relationship mapping for complete coverage

**Window Interception Method**
- System-level window detection through WindowServer interfaces
- Direct CGS connections for window events
- Low-level surface creation monitoring

**Communication Architecture**
- Hybrid approach using shared memory for state and Mach messages for events
- Optimized for minimal overhead and maximum reliability
- Fault-tolerant design with automatic recovery

## 4. Technical Challenges and Solutions

### 4.1 macOS Security Constraints

**Challenge:** SIP, Hardened Runtime, and library validation restrict code injection.

**Solution:**
- Develop a selective binary modification technique that alters only necessary sections
- Implement temporary entitlement grants during runtime
- Create a process launch interception layer that works with library validation
- Design a dynamic DYLD path manipulation technique compatible with SIP

### 4.2 Process Detection Reliability

**Challenge:** Reliably detecting all processes belonging to an application without framework-specific knowledge.

**Solution:**
- Implement kernel-level process creation monitoring
- Utilize executable path and bundle identifier correlation
- Develop comprehensive process lineage tracking
- Create heuristic-based process classification that doesn't rely on framework details

### 4.3 Window Timing Synchronization

**Challenge:** Ensuring window modifications occur immediately after creation without framework knowledge.

**Solution:**
- Implement WindowServer event monitoring for all window creation
- Develop pre-composition interception techniques
- Create a synchronization protocol with minimal latency
- Design a multi-layered detection system with redundant mechanisms

### 4.4 Inter-Process Communication Reliability

**Challenge:** Ensuring reliable communication across all processes with minimal overhead.

**Solution:**
- Utilize kernel-level primitives for maximum reliability
- Implement multiple communication channels with automatic failover
- Design a minimal, binary protocol with error correction
- Create state persistence mechanisms for recovery

### 4.5 Long-term Maintainability

**Challenge:** Creating a solution that remains functional across macOS and framework updates.

**Solution:**
- Focus exclusively on system-level mechanisms rather than framework specifics
- Implement layered abstractions that isolate OS-dependent components
- Design a runtime adaptation system that detects and adjusts to changes
- Create extensive telemetry and diagnostics for rapid issue identification

## 5. Testing Strategy

### 5.1 Application Diversity Testing

Test across multiple application types including:

- Electron applications (Discord, Slack, VS Code)
- WebKit-based applications (Safari, Chrome)
- Native AppKit applications
- Qt applications
- Tauri applications
- SwiftUI applications

### 5.2 Functionality Testing

Verify all window modification features:

- Always-on-top behavior
- Non-activating interaction
- Screen capture prevention
- Mission Control integration
- Focus preservation

### 5.3 Reliability Testing

- Stress testing with rapid window creation/destruction
- Application restart scenarios
- System sleep/wake transitions
- Heavy system load conditions
- Multiple simultaneous modifications

### 5.4 Security Impact Assessment

- Verify application integrity post-modification
- Assess impact on application security properties
- Test compatibility with security software
- Verify uninstallation completely restores original state

## 6. Timeline and Milestones

Total estimated time: **16-22 weeks**

- **Milestone 1** (Week 4): Process monitoring daemon operational
- **Milestone 2** (Week 8): Universal injection system complete
- **Milestone 3** (Week 12): Window interception framework operational
- **Milestone 4** (Week 15): Full communication layer implemented
- **Milestone 5** (Week 18): Complete integration with modification engine
- **Milestone 6** (Week 22): Final testing and refinement complete

## 7. Conclusion

This system-level approach to the Window Modifier refactoring creates a robust, maintainable solution for multi-process applications without relying on framework-specific implementations. By focusing on macOS kernel primitives and system-level interfaces, the solution will remain effective even as application frameworks evolve.

The architecture builds on the success of our existing CGS API approach for window modifications, extending it with comprehensive process management, universal injection, and reliable cross-process communication. This approach minimizes the maintenance burden by eliminating dependencies on framework details while providing complete functionality across all application types.

The phased implementation plan allows for incremental development and testing, with clear milestones to track progress. The end result will be a powerful, flexible utility that works reliably with modern multi-process applications while maintaining compatibility with future macOS updates.
