// window_classifier.h - Window classification and tracking
#ifndef WINDOW_CLASSIFIER_H
#define WINDOW_CLASSIFIER_H

#import <Cocoa/Cocoa.h>
#include "../core/window_modifier_types.h"

// Window classification callbacks
typedef void (*window_class_callback_t)(CGSWindowID windowID, window_class_t classification);

// Window classifier interface
bool init_window_classifier(void);
void cleanup_window_classifier(void);

// Register for window classification
void register_classification_callback(window_class_callback_t callback);

// Track window state
void track_window_event(CGSWindowID windowID, int eventType);
bool is_window_standard(CGSWindowID windowID);
bool is_window_initialized(CGSWindowID windowID);

#endif // WINDOW_CLASSIFIER_H
