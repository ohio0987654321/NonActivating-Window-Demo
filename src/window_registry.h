// window_registry.h - Cross-process registry for window state
#ifndef WINDOW_REGISTRY_H
#define WINDOW_REGISTRY_H

#include <stdbool.h>
#include <stdint.h>

// Registry structure (opaque pointer)
typedef struct window_registry window_registry_t;

// Initialize the window registry
// Returns a pointer to the registry, or NULL on error
window_registry_t* registry_init(void);

// Check if a window is already modified
// Returns true if the window is already marked as modified
bool registry_is_window_modified(window_registry_t* registry, uint32_t window_id);

// Mark a window as modified
// Returns true if successful
bool registry_mark_window_modified(window_registry_t* registry, uint32_t window_id);

// Clean up the registry
// Returns true if successful
bool registry_cleanup(window_registry_t* registry);

// Clean stale entries from the registry
// Returns number of entries removed
int registry_cleanup_stale(window_registry_t* registry);

#endif // WINDOW_REGISTRY_H
