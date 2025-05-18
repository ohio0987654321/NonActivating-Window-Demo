// window_registry.c - Cross-process registry for window state
#include "window_registry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <time.h>

// Registry file path in temporary directory
#define REGISTRY_DIR "/tmp/window_modifier"
#define REGISTRY_FILE "registry.dat"
#define MAX_WINDOWS 1024
#define MAX_REGISTRY_SIZE (MAX_WINDOWS * sizeof(registry_entry_t))
#define STALE_ENTRY_SECONDS 1800 // 30 minutes (reduced from 1 hour)

// Registry entry structure
typedef struct {
    uint32_t window_id;
    pid_t process_id;
    time_t timestamp;
} registry_entry_t;

// Registry structure
struct window_registry {
    char file_path[512];
    int lock_fd;
    time_t last_cleanup;
};

// Create and initialize the registry
window_registry_t* registry_init(void) {
    // Get temp directory
    const char* tmp_dir = getenv("TMPDIR");
    if (!tmp_dir) {
        tmp_dir = "/tmp";
    }
    
    // Allocate registry structure
    window_registry_t* registry = malloc(sizeof(window_registry_t));
    if (!registry) {
        printf("[Registry] Error: Failed to allocate registry\n");
        return NULL;
    }
    
    // Create registry directory if it doesn't exist
    char registry_dir[512];
    snprintf(registry_dir, sizeof(registry_dir), "%s", REGISTRY_DIR);
    
    struct stat st;
    if (stat(registry_dir, &st) != 0) {
        if (mkdir(registry_dir, 0755) != 0) {
            printf("[Registry] Error: Failed to create registry directory: %s\n", strerror(errno));
            free(registry);
            return NULL;
        }
    }
    
    // Initialize registry file path
    snprintf(registry->file_path, sizeof(registry->file_path), 
             "%s/%s", registry_dir, REGISTRY_FILE);
    
    // Open or create registry file with lock
    registry->lock_fd = open(registry->file_path, 
                           O_CREAT | O_RDWR, 
                           S_IRUSR | S_IWUSR);
    
    if (registry->lock_fd < 0) {
        printf("[Registry] Error: Failed to open registry file: %s\n", 
               strerror(errno));
        free(registry);
        return NULL;
    }
    
    // Try to acquire a lock, but don't block
    int lock_result = flock(registry->lock_fd, LOCK_EX | LOCK_NB);
    if (lock_result == 0) {
        // We got the lock, initialize the file if needed
        struct stat st;
        if (fstat(registry->lock_fd, &st) == 0 && st.st_size == 0) {
            // Empty file, initialize
            printf("[Registry] Initializing new registry file\n");
            registry_entry_t empty = {0};
            if (write(registry->lock_fd, &empty, sizeof(registry_entry_t)) < 0) {
                printf("[Registry] Warning: Failed to initialize registry file\n");
            }
        }
        
        // Check if the file is too large and clean it if necessary
        if (fstat(registry->lock_fd, &st) == 0 && st.st_size > MAX_REGISTRY_SIZE) {
            printf("[Registry] Registry file too large (%lld bytes), cleaning up\n", 
                   (long long)st.st_size);
            registry_cleanup_stale(registry);
        }
        
        // Release the lock
        flock(registry->lock_fd, LOCK_UN);
    }
    
    // Set last cleanup time
    registry->last_cleanup = time(NULL);
    
    printf("[Registry] Window registry initialized at %s\n", registry->file_path);
    return registry;
}

// Check if a window is already modified in the registry
bool registry_is_window_modified(window_registry_t* registry, uint32_t window_id) {
    if (!registry || window_id == 0 || registry->lock_fd < 0) {
        return false;
    }
    
    bool is_modified = false;
    
    // Try to acquire a shared lock for reading with timeout
    int lock_attempts = 0;
    const int max_lock_attempts = 3;
    
    while (lock_attempts < max_lock_attempts) {
        if (flock(registry->lock_fd, LOCK_SH | LOCK_NB) == 0) {
            // Got the lock
            break;
        }
        
        // If we can't get the lock immediately, sleep briefly and retry
        usleep(10000); // 10ms
        lock_attempts++;
        
        if (lock_attempts >= max_lock_attempts) {
            printf("[Registry] Warning: Failed to acquire read lock after %d attempts\n", 
                   max_lock_attempts);
            return false;
        }
    }
    
    // Seek to beginning of file
    lseek(registry->lock_fd, 0, SEEK_SET);
    
    // Read entries and check for window ID
    registry_entry_t entry;
    ssize_t bytes_read;
    
    while ((bytes_read = read(registry->lock_fd, &entry, sizeof(registry_entry_t))) == sizeof(registry_entry_t)) {
        if (entry.window_id == window_id && entry.window_id != 0) {
            is_modified = true;
            break;
        }
    }
    
    // Release the lock
    flock(registry->lock_fd, LOCK_UN);
    
    return is_modified;
}

// Mark a window as modified in the registry
bool registry_mark_window_modified(window_registry_t* registry, uint32_t window_id) {
    if (!registry || window_id == 0 || registry->lock_fd < 0) {
        return false;
    }
    
    // Check if already marked (no need to acquire exclusive lock)
    if (registry_is_window_modified(registry, window_id)) {
        return true;
    }
    
    // Periodically clean up the registry (every 5 minutes)
    time_t now = time(NULL);
    if (now - registry->last_cleanup > 300) { // 5 minutes
        registry_cleanup_stale(registry);
        registry->last_cleanup = now;
    }
    
    // Try to acquire an exclusive lock with timeout
    int lock_attempts = 0;
    const int max_lock_attempts = 5;
    
    while (lock_attempts < max_lock_attempts) {
        if (flock(registry->lock_fd, LOCK_EX | LOCK_NB) == 0) {
            // Got the lock
            break;
        }
        
        // If we can't get the lock immediately, sleep briefly and retry
        usleep(20000); // 20ms
        lock_attempts++;
        
        if (lock_attempts >= max_lock_attempts) {
            printf("[Registry] Error: Failed to acquire write lock after %d attempts\n", 
                   max_lock_attempts);
            return false;
        }
    }
    
    // Double-check size after getting lock
    struct stat st;
    if (fstat(registry->lock_fd, &st) == 0) {
        if (st.st_size >= MAX_REGISTRY_SIZE) {
            // Registry is full, clean up
            printf("[Registry] Registry full, cleaning up\n");
            registry_cleanup_stale(registry);
        }
    }
    
    // Create new entry
    registry_entry_t new_entry;
    new_entry.window_id = window_id;
    new_entry.process_id = getpid();
    new_entry.timestamp = time(NULL);
    
    // Seek to end of file
    lseek(registry->lock_fd, 0, SEEK_END);
    
    // Write the new entry
    ssize_t bytes_written = write(registry->lock_fd, &new_entry, sizeof(registry_entry_t));
    bool success = (bytes_written == sizeof(registry_entry_t));
    
    if (!success) {
        printf("[Registry] Error: Failed to write registry entry: %s\n", 
               strerror(errno));
    }
    
    // Flush changes to disk
    fsync(registry->lock_fd);
    
    // Release the lock
    flock(registry->lock_fd, LOCK_UN);
    
    return success;
}

// Clean up stale entries from the registry
int registry_cleanup_stale(window_registry_t* registry) {
    if (!registry || registry->lock_fd < 0) {
        return 0;
    }
    
    int removed_count = 0;
    
    // Try to acquire an exclusive lock with timeout
    int lock_attempts = 0;
    const int max_lock_attempts = 5;
    
    while (lock_attempts < max_lock_attempts) {
        if (flock(registry->lock_fd, LOCK_EX | LOCK_NB) == 0) {
            // Got the lock
            break;
        }
        
        // If we can't get the lock immediately, sleep briefly and retry
        usleep(20000); // 20ms
        lock_attempts++;
        
        if (lock_attempts >= max_lock_attempts) {
            printf("[Registry] Error: Failed to acquire exclusive lock for cleanup after %d attempts\n", 
                   max_lock_attempts);
            return 0;
        }
    }
    
    // Create a temporary file for the new registry
    char temp_file[520];
    snprintf(temp_file, sizeof(temp_file), "%s.tmp", registry->file_path);
    
    int temp_fd = open(temp_file, 
                      O_CREAT | O_WRONLY | O_TRUNC, 
                      S_IRUSR | S_IWUSR);
    
    if (temp_fd < 0) {
        printf("[Registry] Error: Failed to create temp file for cleanup: %s\n", 
               strerror(errno));
        flock(registry->lock_fd, LOCK_UN);
        return 0;
    }
    
    // Read all entries from the original file
    lseek(registry->lock_fd, 0, SEEK_SET);
    
    registry_entry_t entry;
    ssize_t bytes_read;
    time_t now = time(NULL);
    
    // First entry is header/initialization entry - always keep it
    if ((bytes_read = read(registry->lock_fd, &entry, sizeof(registry_entry_t))) == sizeof(registry_entry_t)) {
        // Write header entry to temp file
        write(temp_fd, &entry, sizeof(registry_entry_t));
    }
    
    // Process remaining entries
    while ((bytes_read = read(registry->lock_fd, &entry, sizeof(registry_entry_t))) == sizeof(registry_entry_t)) {
        if (entry.window_id == 0) {
            // Skip empty entries
            continue;
        }
        
        // Check if the entry is stale
        if (now - entry.timestamp > STALE_ENTRY_SECONDS) {
            removed_count++;
            continue;
        }
        
        // Check if the process still exists
        char proc_path[64];
        snprintf(proc_path, sizeof(proc_path), "/proc/%d", entry.process_id);
        struct stat proc_stat;
        if (stat(proc_path, &proc_stat) != 0) {
            // Process no longer exists
            removed_count++;
            continue;
        }
        
        // Non-stale entry, write to temp file
        write(temp_fd, &entry, sizeof(registry_entry_t));
    }
    
    // Flush changes to temp file
    fsync(temp_fd);
    close(temp_fd);
    
    // Replace original with temp file
    if (rename(temp_file, registry->file_path) != 0) {
        printf("[Registry] Error: Failed to replace registry file: %s\n", 
               strerror(errno));
        unlink(temp_file);  // Clean up temp file on error
        flock(registry->lock_fd, LOCK_UN);
        return 0;
    }
    
    // Release the lock and reopen the new file
    flock(registry->lock_fd, LOCK_UN);
    close(registry->lock_fd);
    
    registry->lock_fd = open(registry->file_path, 
                            O_CREAT | O_RDWR, 
                            S_IRUSR | S_IWUSR);
    
    if (registry->lock_fd < 0) {
        printf("[Registry] Error: Failed to reopen registry after cleanup\n");
        return removed_count;
    }
    
    printf("[Registry] Cleanup complete: removed %d stale entries\n", removed_count);
    return removed_count;
}

// Clean up and free the registry
bool registry_cleanup(window_registry_t* registry) {
    if (!registry) {
        return false;
    }
    
    // Cleanup stale entries before closing
    if (registry->lock_fd >= 0) {
        registry_cleanup_stale(registry);
        close(registry->lock_fd);
    }
    
    // Free the struct
    free(registry);
    
    return true;
}
