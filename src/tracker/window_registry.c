// window_registry.c - Cross-process window modification registry
#include "window_registry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>

// Registry shared memory structure
#define MAX_REGISTRY_ENTRIES 2048
#define REGISTRY_SHM_NAME "/window_modifier_registry"
#define REGISTRY_LOCK_NAME "/window_modifier_registry_lock"
#define MAX_PROCESS_AGE_SECONDS 3600 // 1 hour

// Entry in the registry
typedef struct {
    CGSWindowID windowID;        // Window ID
    pid_t processID;             // Process that modified the window
    time_t timestamp;            // When the window was modified
    bool valid;                  // Whether the entry is valid
} registry_entry_t;

// Shared memory structure
typedef struct {
    int entry_count;                          // Current number of entries
    registry_entry_t entries[MAX_REGISTRY_ENTRIES]; // Entries
    pid_t active_processes[256];              // Active processes
    int process_count;                        // Number of active processes
    time_t last_cleanup;                      // Last cleanup time
} registry_shared_t;

// Registry structure
struct window_registry {
    int shm_fd;                  // Shared memory file descriptor
    registry_shared_t* shared;   // Pointer to shared memory
    pthread_mutex_t* lock;       // Inter-process mutex
    int lock_fd;                 // Lock file descriptor
    bool initialized;            // Whether initialization succeeded
    pid_t process_id;            // Current process ID
};

// Forward declarations
static bool registry_create_lock(window_registry_t* registry);
static void registry_cleanup_stale(window_registry_t* registry);
static bool registry_register_process(window_registry_t* registry);
static void registry_unregister_process(window_registry_t* registry);
static bool registry_perform_cleanup(window_registry_t* registry);
static bool registry_acquire_lock(window_registry_t* registry, bool block);
static void registry_release_lock(window_registry_t* registry);

// Initialize the registry
window_registry_t* registry_init(void) {
    // Allocate registry structure
    window_registry_t* registry = malloc(sizeof(window_registry_t));
    if (!registry) {
        perror("[Registry] Failed to allocate registry");
        return NULL;
    }
    
    // Initialize registry
    registry->shm_fd = -1;
    registry->shared = NULL;
    registry->lock = NULL;
    registry->lock_fd = -1;
    registry->initialized = false;
    registry->process_id = getpid();
    
    // Try to open existing shared memory
    registry->shm_fd = shm_open(REGISTRY_SHM_NAME, O_RDWR, 0666);
    bool created = false;
    
    if (registry->shm_fd == -1) {
        // Create new shared memory
        registry->shm_fd = shm_open(REGISTRY_SHM_NAME, O_RDWR | O_CREAT, 0666);
        if (registry->shm_fd == -1) {
            perror("[Registry] Failed to create shared memory");
            free(registry);
            return NULL;
        }
        
        // Set size
        if (ftruncate(registry->shm_fd, sizeof(registry_shared_t)) == -1) {
            perror("[Registry] Failed to set shared memory size");
            close(registry->shm_fd);
            shm_unlink(REGISTRY_SHM_NAME);
            free(registry);
            return NULL;
        }
        
        created = true;
    }
    
    // Map shared memory
    registry->shared = mmap(NULL, sizeof(registry_shared_t), PROT_READ | PROT_WRITE, 
                            MAP_SHARED, registry->shm_fd, 0);
    
    if (registry->shared == MAP_FAILED) {
        perror("[Registry] Failed to map shared memory");
        close(registry->shm_fd);
        if (created) {
            shm_unlink(REGISTRY_SHM_NAME);
        }
        free(registry);
        return NULL;
    }
    
    // Initialize shared memory if we created it
    if (created) {
        memset(registry->shared, 0, sizeof(registry_shared_t));
        registry->shared->entry_count = 0;
        registry->shared->process_count = 0;
        registry->shared->last_cleanup = time(NULL);
    }
    
    // Create lock
    if (!registry_create_lock(registry)) {
        munmap(registry->shared, sizeof(registry_shared_t));
        close(registry->shm_fd);
        if (created) {
            shm_unlink(REGISTRY_SHM_NAME);
        }
        free(registry);
        return NULL;
    }
    
    // Register this process
    if (!registry_register_process(registry)) {
        perror("[Registry] Failed to register process");
        munmap(registry->shared, sizeof(registry_shared_t));
        close(registry->shm_fd);
        if (registry->lock) {
            pthread_mutex_destroy(registry->lock);
            if (registry->lock_fd != -1) {
                close(registry->lock_fd);
            }
            shm_unlink(REGISTRY_LOCK_NAME);
        }
        if (created) {
            shm_unlink(REGISTRY_SHM_NAME);
        }
        free(registry);
        return NULL;
    }
    
    // Clean up stale entries
    registry_cleanup_stale(registry);
    
    registry->initialized = true;
    printf("[Registry] Initialized (mode: %s, entries: %d, processes: %d)\n", 
           created ? "created" : "joined", 
           registry->shared->entry_count, 
           registry->shared->process_count);
    
    return registry;
}

// Clean up the registry
void registry_cleanup(window_registry_t* registry) {
    if (!registry || !registry->initialized) {
        return;
    }
    
    // Final cleanup
    registry_cleanup_stale(registry);
    
    // Unregister this process
    registry_unregister_process(registry);
    
    // Unmap shared memory
    if (registry->shared != MAP_FAILED && registry->shared != NULL) {
        munmap(registry->shared, sizeof(registry_shared_t));
    }
    
    // Close file descriptor
    if (registry->shm_fd != -1) {
        close(registry->shm_fd);
    }
    
    // Clean up lock
    if (registry->lock) {
        pthread_mutex_destroy(registry->lock);
        if (registry->lock_fd != -1) {
            close(registry->lock_fd);
        }
        shm_unlink(REGISTRY_LOCK_NAME);
    }
    
    // If this was the last process, unlink shared memory
    if (registry->shared && registry->shared->process_count == 0) {
        shm_unlink(REGISTRY_SHM_NAME);
    }
    
    registry->initialized = false;
    free(registry);
}

// Mark a window as modified
bool registry_mark_window_modified(window_registry_t* registry, CGSWindowID windowID) {
    if (!registry || !registry->initialized || !registry->shared) {
        return false;
    }
    
    bool success = false;
    
    // Acquire lock
    if (!registry_acquire_lock(registry, true)) {
        return false;
    }
    
    // Check if window is already in registry
    bool found = false;
    for (int i = 0; i < registry->shared->entry_count; i++) {
        if (registry->shared->entries[i].valid && 
            registry->shared->entries[i].windowID == windowID) {
            // Update timestamp
            registry->shared->entries[i].timestamp = time(NULL);
            found = true;
            success = true;
            break;
        }
    }
    
    // Add new entry if not found
    if (!found) {
        // Find empty slot
        int slot = -1;
        for (int i = 0; i < registry->shared->entry_count; i++) {
            if (!registry->shared->entries[i].valid) {
                slot = i;
                break;
            }
        }
        
        // If no empty slot, add at end
        if (slot == -1) {
            if (registry->shared->entry_count >= MAX_REGISTRY_ENTRIES) {
                // Registry full, try to clean up
                if (!registry_perform_cleanup(registry)) {
                    registry_release_lock(registry);
                    return false;
                }
                
                // Try again
                for (int i = 0; i < registry->shared->entry_count; i++) {
                    if (!registry->shared->entries[i].valid) {
                        slot = i;
                        break;
                    }
                }
                
                // Still full
                if (slot == -1) {
                    registry_release_lock(registry);
                    return false;
                }
            } else {
                // Add at end
                slot = registry->shared->entry_count;
                registry->shared->entry_count++;
            }
        }
        
        // Add entry
        registry->shared->entries[slot].windowID = windowID;
        registry->shared->entries[slot].processID = registry->process_id;
        registry->shared->entries[slot].timestamp = time(NULL);
        registry->shared->entries[slot].valid = true;
        
        success = true;
    }
    
    // Periodic cleanup (every ~10 operations)
    if (rand() % 10 == 0) {
        registry_cleanup_stale(registry);
    }
    
    // Release lock
    registry_release_lock(registry);
    
    return success;
}

// Check if a window has been modified
bool registry_is_window_modified(window_registry_t* registry, CGSWindowID windowID) {
    if (!registry || !registry->initialized || !registry->shared) {
        return false;
    }
    
    bool found = false;
    
    // Acquire lock
    if (!registry_acquire_lock(registry, true)) {
        return false;
    }
    
    // Search registry
    for (int i = 0; i < registry->shared->entry_count; i++) {
        if (registry->shared->entries[i].valid && 
            registry->shared->entries[i].windowID == windowID) {
            found = true;
            break;
        }
    }
    
    // Release lock
    registry_release_lock(registry);
    
    return found;
}

// Get modified window count
int registry_get_modified_count(window_registry_t* registry) {
    if (!registry || !registry->initialized || !registry->shared) {
        return 0;
    }
    
    int count = 0;
    
    // Acquire lock
    if (!registry_acquire_lock(registry, true)) {
        return 0;
    }
    
    // Count valid entries
    for (int i = 0; i < registry->shared->entry_count; i++) {
        if (registry->shared->entries[i].valid) {
            count++;
        }
    }
    
    // Release lock
    registry_release_lock(registry);
    
    return count;
}

// Create inter-process lock
static bool registry_create_lock(window_registry_t* registry) {
    // Open shared memory for lock - first unlink any existing one to ensure clean state
    shm_unlink(REGISTRY_LOCK_NAME); // Ignore errors - may not exist
    
    // Open shared memory for lock
    registry->lock_fd = shm_open(REGISTRY_LOCK_NAME, O_RDWR | O_CREAT | O_EXCL, 0666);
    if (registry->lock_fd == -1) {
        // If it failed with EEXIST, try to open existing
        if (errno == EEXIST) {
            registry->lock_fd = shm_open(REGISTRY_LOCK_NAME, O_RDWR, 0666);
            if (registry->lock_fd == -1) {
                perror("[Registry] Failed to open existing lock shared memory");
                return false;
            }
        } else {
            perror("[Registry] Failed to create lock shared memory");
            return false;
        }
    }
    
    // Get size of pthread_mutex_t on this system
    size_t mutex_size = sizeof(pthread_mutex_t);
    // Round up to page size to ensure compatibility
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size < 0) page_size = 4096; // Default to 4K if sysconf fails
    
    size_t shm_size = ((mutex_size + page_size - 1) / page_size) * page_size;
    
    // Set size - ensure it's at least one page
    if (ftruncate(registry->lock_fd, shm_size) == -1) {
        perror("[Registry] Failed to set lock shared memory size");
        close(registry->lock_fd);
        shm_unlink(REGISTRY_LOCK_NAME);
        return false;
    }
    
    // Map shared memory
    registry->lock = mmap(NULL, sizeof(pthread_mutex_t), PROT_READ | PROT_WRITE, 
                         MAP_SHARED, registry->lock_fd, 0);
    
    if (registry->lock == MAP_FAILED) {
        perror("[Registry] Failed to map lock shared memory");
        close(registry->lock_fd);
        shm_unlink(REGISTRY_LOCK_NAME);
        return false;
    }
    
    // Initialize mutex with process-shared attribute
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr) != 0) {
        perror("[Registry] Failed to initialize mutex attributes");
        munmap(registry->lock, sizeof(pthread_mutex_t));
        close(registry->lock_fd);
        shm_unlink(REGISTRY_LOCK_NAME);
        return false;
    }
    
    if (pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED) != 0) {
        perror("[Registry] Failed to set mutex as process-shared");
        pthread_mutexattr_destroy(&attr);
        munmap(registry->lock, sizeof(pthread_mutex_t));
        close(registry->lock_fd);
        shm_unlink(REGISTRY_LOCK_NAME);
        return false;
    }
    
    if (pthread_mutex_init(registry->lock, &attr) != 0) {
        perror("[Registry] Failed to initialize mutex");
        pthread_mutexattr_destroy(&attr);
        munmap(registry->lock, sizeof(pthread_mutex_t));
        close(registry->lock_fd);
        shm_unlink(REGISTRY_LOCK_NAME);
        return false;
    }
    
    pthread_mutexattr_destroy(&attr);
    return true;
}

// Register this process in the registry
static bool registry_register_process(window_registry_t* registry) {
    if (!registry || !registry->shared) {
        return false;
    }
    
    // Acquire lock
    if (!registry_acquire_lock(registry, true)) {
        return false;
    }
    
    // Check if process is already registered
    for (int i = 0; i < registry->shared->process_count; i++) {
        if (registry->shared->active_processes[i] == registry->process_id) {
            // Already registered
            registry_release_lock(registry);
            return true;
        }
    }
    
    // Add process
    if (registry->shared->process_count >= 256) {
        // Registry full, try to clean up
        if (!registry_perform_cleanup(registry)) {
            registry_release_lock(registry);
            return false;
        }
        
        // Check again
        if (registry->shared->process_count >= 256) {
            registry_release_lock(registry);
            return false;
        }
    }
    
    // Add process
    registry->shared->active_processes[registry->shared->process_count] = registry->process_id;
    registry->shared->process_count++;
    
    // Release lock
    registry_release_lock(registry);
    
    return true;
}

// Unregister this process
static void registry_unregister_process(window_registry_t* registry) {
    if (!registry || !registry->shared) {
        return;
    }
    
    // Acquire lock
    if (!registry_acquire_lock(registry, true)) {
        return;
    }
    
    // Find process
    for (int i = 0; i < registry->shared->process_count; i++) {
        if (registry->shared->active_processes[i] == registry->process_id) {
            // Remove process by shifting all others down
            for (int j = i; j < registry->shared->process_count - 1; j++) {
                registry->shared->active_processes[j] = registry->shared->active_processes[j + 1];
            }
            registry->shared->process_count--;
            break;
        }
    }
    
    // Release lock
    registry_release_lock(registry);
}

// Perform registry cleanup
static bool registry_perform_cleanup(window_registry_t* registry) {
    if (!registry || !registry->shared) {
        return false;
    }
    
    time_t now = time(NULL);
    
    // Check if we need to clean up
    if (now - registry->shared->last_cleanup < 60) {
        // Less than a minute since last cleanup
        return true;
    }
    
    printf("[Registry] Performing cleanup (entries: %d, processes: %d)\n", 
           registry->shared->entry_count, registry->shared->process_count);
    
    // Mark entries for dead processes as invalid
    for (int i = 0; i < registry->shared->entry_count; i++) {
        if (!registry->shared->entries[i].valid) {
            continue;
        }
        
        // Check if process is still active
        bool active = false;
        for (int j = 0; j < registry->shared->process_count; j++) {
            if (registry->shared->entries[i].processID == registry->shared->active_processes[j]) {
                active = true;
                break;
            }
        }
        
        // If not active, mark as invalid
        if (!active) {
            registry->shared->entries[i].valid = false;
        }
    }
    
    // Compact registry
    int write_index = 0;
    for (int i = 0; i < registry->shared->entry_count; i++) {
        if (registry->shared->entries[i].valid) {
            if (i != write_index) {
                registry->shared->entries[write_index] = registry->shared->entries[i];
            }
            write_index++;
        }
    }
    
    // Update entry count
    registry->shared->entry_count = write_index;
    
    // Update last cleanup time
    registry->shared->last_cleanup = now;
    
    printf("[Registry] Cleanup complete (new entries: %d)\n", registry->shared->entry_count);
    
    return true;
}

// Clean up stale registry entries
static void registry_cleanup_stale(window_registry_t* registry) {
    if (!registry || !registry->shared) {
        return;
    }
    
    // Acquire lock
    if (!registry_acquire_lock(registry, false)) {
        return;
    }
    
    // Perform cleanup
    registry_perform_cleanup(registry);
    
    // Release lock
    registry_release_lock(registry);
}

// Acquire lock with timeout and retry functionality for better resilience
static bool registry_acquire_lock(window_registry_t* registry, bool block) {
    if (!registry || !registry->lock) {
        return false;
    }
    
    int result;
    
    if (block) {
        // For blocking mode, implement a timeout and retry mechanism to avoid deadlocks
        // This is especially important for cross-process locks which can be more fragile
        int retries = 0;
        const int max_retries = 3;
        
        do {
            result = pthread_mutex_lock(registry->lock);
            
            // If successful or error other than timeout, break
            if (result == 0 || result != ETIMEDOUT) {
                break;
            }
            
            // If timeout, log and retry
            printf("[Registry] Lock acquisition timeout, retrying (%d/%d)...\n", 
                   retries + 1, max_retries);
            
            // Small delay before retry to help with contention
            usleep(10000 * (retries + 1));  // 10ms, 20ms, 30ms
            retries++;
        } while (retries < max_retries);
    } else {
        result = pthread_mutex_trylock(registry->lock);
    }
    
    if (result != 0 && result != EBUSY) {
        printf("[Registry] Lock acquisition failed: %s (error %d)\n", 
               strerror(result), result);
    }
    
    return (result == 0);
}

// Release lock
static void registry_release_lock(window_registry_t* registry) {
    if (!registry || !registry->lock) {
        return;
    }
    
    pthread_mutex_unlock(registry->lock);
}
