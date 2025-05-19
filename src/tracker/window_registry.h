// window_registry.h - Cross-process window modification registry
#ifndef WINDOW_REGISTRY_H
#define WINDOW_REGISTRY_H

#include <stdbool.h>
#include "../core/window_modifier_types.h"

// Window registry opaque type
typedef struct window_registry window_registry_t;

// Initialize registry (returns NULL on failure)
window_registry_t* registry_init(void);

// Clean up registry
void registry_cleanup(window_registry_t* registry);

// Mark a window as modified
bool registry_mark_window_modified(window_registry_t* registry, CGSWindowID windowID);

// Check if a window has been modified 
bool registry_is_window_modified(window_registry_t* registry, CGSWindowID windowID);

// Get modified window count
int registry_get_modified_count(window_registry_t* registry);

#endif // WINDOW_REGISTRY_H
