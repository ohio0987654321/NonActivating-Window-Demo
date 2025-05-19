// window_classifier.h - Window classification and tracking
#ifndef WINDOW_CLASSIFIER_H
#define WINDOW_CLASSIFIER_H

#import <Cocoa/Cocoa.h>
#include "../core/window_modifier_types.h"

// Window classifier interface
bool init_window_classifier(void);
void cleanup_window_classifier(void);

// Track window state - core functions
void track_window_event(CGSWindowID windowID, int eventType);
bool is_window_standard(CGSWindowID windowID);
bool is_window_initialized(CGSWindowID windowID);

#endif // WINDOW_CLASSIFIER_H
