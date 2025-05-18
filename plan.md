# Window Modifier Refactoring Plan: Multi-Process Support

## Executive Summary

This document outlines a comprehensive plan to refactor the existing Window Modifier proof-of-concept to support multi-process applications such as Discord. The current implementation can successfully modify windows in single-process applications but fails when targeting modern multi-process applications where windows may be created in different processes.

The refactoring will implement a hybrid injection architecture with robust process management, cross-process communication, and framework-agnostic window interception. A critical requirement is the ability to re-sign target applications with specific entitlements to enable our injection mechanism under macOS's security constraints.

This plan provides the engineering team with all necessary context, technical requirements, architecture details, and implementation steps to successfully complete the refactoring.

## 1. Project Background

### 1.1 Purpose

The Window Modifier is a macOS utility that injects functionality into existing applications to modify their window properties, providing features that the original applications don't natively support:

- **Screen Recording Bypass**: Makes windows invisible to screen recording tools
- **Always-on-top Display**: Forces windows to float above other applications
- **Focus-preserving Interaction**: Allows interaction without stealing focus from other apps
- **Title Bar State Control**: Preserves the active appearance of title bars
- **Mission Control Visibility**: Ensures modified windows appear properly in Mission Control

These modifications are particularly useful for creating floating utilities, reference windows, or picture-in-picture displays that don't interrupt workflow.

### 1.2 Current Approach

The current implementation uses dynamic library injection to insert custom window-handling code into target applications at runtime. The injected code intercepts window creation and modifies window properties using both public AppKit APIs and private CoreGraphics Server (CGS) functions.

### 1.3 Problem Statement

Modern applications like Discord, Slack, and VS Code use multi-process architectures (typically based on Electron) where the main process and renderer processes run as separate executables. Our current injection approach only targets the main process, but windows may be created and managed by renderer processes, causing our modifications to fail.

## 2. Current Implementation Overview

### 2.1 Project Structure

The current codebase has these key components:

- **src/window_modifier.m**: Core window modification logic
- **src/injection_entry.c**: Entry point for dylib injection
- **src/injector.c**: Command-line tool that launches apps with injection
- **discord/discord_final.m**: Discord-specific implementation

### 2.2 How It Works

1. **Injection**: The `injector` tool launches the target application with `DYLD_INSERT_LIBRARIES` set to our dylib
2. **Initialization**: When loaded, our dylib's constructor (`dylib_entry`) runs in the target process
3. **Window Detection**: The injected code identifies windows using various methods:
   - Method swizzling of NSWindow creation methods
   - NSNotification observers for window events
   - Periodic scanning of [NSApp windows]
4. **Window Modification**: For each detected window, we:
   - Set non-activating behavior using private AppKit methods (`_setPreventsActivation:`)
   - Set floating window level (`NSFloatingWindowLevel`)
   - Disable screen capture (`NSWindowSharingNone`)
   - Configure Mission Control behavior (`NSWindowCollectionBehavior`)
   - Manage focus preservation (saving/restoring previous app)

### 2.3 Discord-Specific Implementation

For Discord, we've created a specialized version (`discord_final.m`) that includes:
- More robust window detection mechanisms
- Additional error handling and logging
- Process type detection for Electron

## 3. Technical Requirements

### 3.1 Core Requirements

1. **Multi-Process Support**: Successfully modify windows in all processes of applications like Discord
2. **Complete Feature Set**: Maintain all existing window modifications:
   - Always-on-top behavior
   - Non-activating interaction
   - Screen capture prevention
   - Mission Control integration
   - Focus preservation
3. **Framework Agnosticism**: Support different application frameworks (Electron, Tauri, WebKit, native AppKit)
4. **macOS Compatibility**: Work on macOS 14 (Sonoma) and later versions

### 3.2 Security Constraints

1. **System Integrity Protection (SIP)**: Must function with SIP enabled
2. **Hardened Runtime**: Must handle applications that use Apple's Hardened Runtime
3. **Application Signing**: Must re-sign target applications with required entitlements
4. **Library Validation**: Must ensure injected dylibs pass library validation checks

### 3.3 Performance Requirements

1. **Low Overhead**: Minimal CPU/memory impact during normal operation
2. **Timing Reliability**: No visual artifacts or flickering during window creation
3. **Stability**: No crashes or hangs in target applications

## 4. Proposed Architecture

Based on extensive research and technical constraints, we've designed a layered architecture that addresses the multi-process challenge while maintaining security compliance:

```
┌───────────────────────────────────────────────────────────────┐
│                Application Preparation Module                  │
│  Re-signing, entitlement configuration, certificate management │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│                   Process Management Layer                     │
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

### 4.1 Application Preparation Module

This new module handles security requirements:

- **App Re-signing**: Re-signs target applications with required entitlements
  - `com.apple.security.cs.allow-dyld-environment-variables` to enable injection
  - Custom certificate generation/management for development use
- **Dylib Signing**: Signs injection libraries with matching certificate
- **Backup Management**: Creates/restores backups of original applications

### 4.2 Process Management Layer

Detects and manages processes within target applications:

- **Process Detection**: Identifies main and renderer processes using heuristics
  - Command-line argument scanning (`--type=renderer`)
  - Executable path analysis
  - Parent-child relationship tracking
- **Targeted Injection**: Injects appropriate dylibs into relevant processes
  - Main process injection using DYLD environment variables
  - Child process injection using launch environment manipulation
- **Process Monitoring**: Tracks process creation/termination for dynamic injection

### 4.3 Universal Window Interception Layer

Provides reliable window detection across all application frameworks through a foundation-level approach:

- **Core Foundation Interception**: Focuses on the common foundation of all macOS windows
  - Method swizzling of NSWindow class hierarchy at the lowest level
  - Comprehensive coverage of window lifecycle methods
  - Interception of core AppKit window events
  
- **Multi-Strategy Detection**: Combines multiple methods to ensure all windows are caught
  - Low-level AppKit method interception
  - NSNotification observer system
  - Periodic window scanning as fallback
  
- **Window Registry**: Maintains a database of detected windows
  - Window fingerprinting for persistent identification
  - Modification state tracking
  
- **Pattern-Based Detection**: Uses runtime behavior analysis instead of framework-specific code
  - Pattern matching for window creation sequences
  - Behavior-based window classification
  - Self-learning system to adapt to new patterns

### 4.4 Cross-Process Communication

Enables coordination between injected libraries in different processes:

- **IPC Mechanism**: Fast, reliable inter-process communication
  - XPC services for secure messaging
  - Shared memory for performance-critical data
- **Coordination Protocol**: Manages window state across processes
  - Window announcement broadcasting
  - Configuration synchronization
  - Modification request routing
- **State Persistence**: Maintains configuration across app restarts

### 4.5 Core Modification Engine

Implements the actual window modifications:

- **Unified API**: Clean interface for all modifications
  - Standardized method for setting window properties
  - Error handling and reporting
- **Multiple Strategy Implementation**: Different approaches for each modification
  - AppKit API methods (primary)
  - Private API methods (when necessary)
  - CGS function calls (fallback)
- **Compatibility Layer**: Adapts to different macOS versions
  - Version detection
  - API availability checking
  - Alternative implementation selection

## 5. Implementation Plan

The refactoring will proceed in phases, with each phase building on the previous one:

### 5.1 Phase 1: Application Preparation Module (2-3 weeks)

1. **Certificate Management System**
   - Create utilities for generating/managing developer certificates
   - Implement secure storage for certificates

2. **App Re-signing Tool**
   - Develop tool to extract, modify, and re-add entitlements
   - Implement application backup/restore functionality
   - Create command-line interface for re-signing workflow

3. **Dylib Signing Integration**
   - Modify build system to sign dylibs with appropriate certificate
   - Create validation tools to verify signing status

### 5.2 Phase 2: Process Management (2-3 weeks)

1. **Process Detection System**
   - Implement process enumeration using `proc_listpids`/`proc_pidinfo`
   - Create heuristics for identifying process types
   - Develop parent-child relationship mapping

2. **Injection Framework**
   - Create abstraction layer for injection methods
   - Implement DYLD environment variable injection
   - Develop launcher approach for process creation control

3. **Process Monitoring**
   - Implement callbacks for process creation events
   - Create dynamic injection mechanism for new processes

### 5.3 Phase 3: Universal Window Interception Layer (3-4 weeks)

1. **Foundation-Level Method Swizzling**
   - Create robust, conflict-free swizzling system
   - Implement comprehensive NSWindow hierarchy interception
   - Develop complete window lifecycle coverage

2. **Window Registry System**
   - Develop window tracking database
   - Implement window fingerprinting algorithms
   - Create modification state tracking

3. **Pattern Detection System**
   - Implement behavior-based pattern recognition
   - Develop runtime classification of window types
   - Create configuration system for pattern updates
   - Build learning mechanism to adapt to new frameworks

### 5.4 Phase 4: Cross-Process Communication (2-3 weeks)

1. **XPC Service Implementation**
   - Create XPC service definition
   - Implement connection management
   - Develop message serialization/deserialization

2. **Communication Protocol**
   - Define message types and formats
   - Implement window announcement system
   - Create configuration synchronization

3. **Synchronization Mechanisms**
   - Develop waiting barrier system for window creation
   - Implement state sharing across processes
   - Create reconnection/recovery mechanisms

### 5.5 Phase 5: Enhanced Modification Engine (2-3 weeks)

1. **Unified Modification API**
   - Create abstraction layer for window modifications
   - Implement strategy pattern for modification methods
   - Develop comprehensive error handling

2. **Multi-Strategy Implementation**
   - Implement AppKit-based modification methods
   - Create private API-based alternatives
   - Develop CGS-based fallback mechanisms

3. **Compatibility System**
   - Create macOS version detection
   - Implement API availability checking
   - Develop dynamic strategy selection

### 5.6 Phase 6: Integration and Testing (2-3 weeks)

1. **Component Integration**
   - Connect all subsystems
   - Resolve interface mismatches
   - Streamline workflow

2. **Performance Optimization**
   - Identify bottlenecks
   - Optimize critical paths
   - Reduce resource usage

3. **Final Testing and Bug Fixing**
   - Comprehensive test suite execution
   - Edge case identification and resolution
   - Documentation and code cleanup

## 6. Testing Strategy

### 6.1 Unit Testing

- Test each component in isolation
- Mock dependencies for controlled testing
- Verify core functionality of each module

### 6.2 Integration Testing

- Test interaction between components
- Verify correct data flow between modules
- Ensure coordinated behavior across the system

### 6.3 Application Testing

Test with various application types:

1. **Electron Applications**
   - Discord
   - Slack
   - VS Code
   - Spotify (Electron-based version)

2. **WebKit Applications**
   - Safari
   - Chrome
   - Edge

3. **Other Frameworks**
   - Tauri applications
   - Native AppKit applications
   - Qt applications (if available)

### 6.4 Feature Testing

Verify each window modification feature:

1. **Always-on-top Behavior**
   - Window stays above other applications
   - Maintains position during window switching
   - Handles z-order correctly

2. **Non-activating Interaction**
   - Can interact without stealing focus
   - Maintains keyboard focus in other applications
   - Properly handles mouse events

3. **Screen Capture Prevention**
   - Window doesn't appear in screenshots
   - Window doesn't appear in screen recordings
   - Window doesn't appear in AirPlay/mirroring

4. **Mission Control Integration**
   - Appears correctly in Mission Control
   - Handles Spaces transitions properly
   - Maintains properties during workspace switching

5. **Focus Preservation**
   - Correctly saves previous frontmost application
   - Properly restores focus after interaction
   - Handles rapid focus switching

### 6.5 Stress Testing

- Rapid window creation/destruction
- Multiple simultaneous modifications
- Application restart during modification
- System sleep/wake during operation
- Heavy system load conditions

## 7. Known Challenges and Mitigations

### 7.1 Hardened Runtime Limitations

**Challenge**: Apple's Hardened Runtime blocks DYLD-based injection.

**Mitigation**:
- Re-sign applications with the `com.apple.security.cs.allow-dyld-environment-variables` entitlement
- Sign injection dylibs with the same certificate as the modified application
- Implement fallback injection methods for different scenarios

### 7.2 Process Detection Limitations

**Challenge**: Limited visibility into process information without elevated privileges.

**Mitigation**:
- Use multiple heuristics for process identification
- Implement robust error handling for missed processes
- Develop recovery mechanisms for late process detection

### 7.3 Window Timing Issues

**Challenge**: Race conditions between window creation and modification.

**Mitigation**:
- Implement pre-creation hooks using method swizzling
- Use synchronization barriers with the IPC system
- Develop periodic scanning as a fallback for missed windows

### 7.4 Framework Diversity and Evolution

**Challenge**: Different frameworks have unique window creation patterns and new frameworks continually emerge.

**Mitigation**:
- Focus on the common foundation (NSWindow) that all frameworks ultimately use
- Implement pattern detection instead of framework-specific code
- Create a self-updating pattern database that can adapt to new frameworks
- Use runtime behavior analysis to classify windows without prior knowledge
- Implement a configuration system that allows updates without code changes

### 7.5 Long-term Viability

**Challenge**: Apple may further restrict injection capabilities in future macOS versions.

**Mitigation**:
- Design for modularity to easily adapt to API changes
- Minimize reliance on private APIs where possible
- Monitor macOS beta releases for breaking changes
- Implement graceful degradation for unsupported features

## 8. Documentation Requirements

The engineering team should create and maintain:

1. **Technical Design Document**
   - Detailed component specifications
   - Interface definitions
   - Data flow diagrams

2. **API Documentation**
   - Public interfaces for each module
   - Usage examples
   - Error handling guidelines

3. **Integration Guide**
   - How to integrate with new application types
   - Customization options
   - Configuration reference

4. **Troubleshooting Guide**
   - Common issues and solutions
   - Diagnostic procedures
   - Performance tuning recommendations

## 9. Project Timeline

Total estimated time: **14-18 weeks**

- Phase 1 (Application Preparation): 2-3 weeks
- Phase 2 (Process Management): 2-3 weeks
- Phase 3 (Window Interception): 3-4 weeks
- Phase 4 (Cross-Process Communication): 2-3 weeks
- Phase 5 (Modification Engine): 2-3 weeks
- Phase 6 (Integration and Testing): 2-3 weeks

### 9.1 Dependencies and Critical Path

The critical path follows the phase sequence, with these key dependencies:

- Application Preparation Module must be completed before Process Management
- Process Management must be functional before Window Interception can be fully tested
- Window Interception and Cross-Process Communication can be developed in parallel
- Modification Engine requires Window Interception to be functional
- Integration testing requires all previous phases to be completed

## 10. Conclusion

This refactoring project will transform the Window Modifier from a single-process utility into a robust system capable of modifying windows across multi-process applications. By addressing security constraints head-on and implementing a layered architecture, we create a solution that can work with modern applications like Discord while maintaining the full set of window modification features.

The architecture is designed for long-term sustainability, with careful consideration of macOS security trends and application framework evolution. The phased implementation approach allows for incremental progress and validation throughout the development process.

### Key Success Metrics

The project will be considered successful when:

1. Window modifications work correctly in Discord and similar multi-process applications
2. All current window modification features are preserved
3. Performance overhead is minimal during normal operation
4. The system functions reliably across macOS 14 and newer versions

### Next Steps

1. Review and approve this refactoring plan
2. Allocate engineering resources for implementation
3. Set up development environment with required certificates
4. Begin work on Phase 1 (Application Preparation Module)
