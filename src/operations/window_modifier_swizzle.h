// window_modifier_swizzle.h - Method swizzling for NSWindow modifications
#ifndef WINDOW_MODIFIER_SWIZZLE_H
#define WINDOW_MODIFIER_SWIZZLE_H

#import <Cocoa/Cocoa.h>
#include "../core/common_types.h"

// This module provides Objective-C method swizzling for NSWindow to intercept
// window creation and modification events. It allows the window modifier to
// apply modifications as windows are created or made visible.

// Initialize method swizzling
void initializeWindowSwizzling(void);

#endif // WINDOW_MODIFIER_SWIZZLE_H
