// window_modifier.h - Core window modification operations
#ifndef WINDOW_MODIFIER_H
#define WINDOW_MODIFIER_H

#import <Cocoa/Cocoa.h>
#import "../tracker/window_registry.h"
#include "../core/common_types.h"

// Main thread function
void* window_modifier_main(void* arg);

// Handle window events
void handleWindowEvent(int eventType, CGSWindowID windowID);

// Modify a window using CGS
bool modifyWindowWithCGS(CGSWindowID windowID);

// Modify a window using NSWindow
bool modifyNSWindow(NSWindow *window);

// Apply modifications to all visible windows
bool applyAllWindowModifications(void);

// Check if application is fully initialized
bool isApplicationInitialized(void);

#endif // WINDOW_MODIFIER_H
