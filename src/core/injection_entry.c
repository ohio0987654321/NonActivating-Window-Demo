// injection_entry.c - Entry point for injected code
#include <stdio.h>
#include <stdlib.h>
#include <string.h>  // For strerror()
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <mach-o/dyld.h>

#include "common_types.h" // Centralized type definitions

// Forward declarations for external components
extern bool init_window_classifier(void);
extern void cleanup_window_classifier(void);
extern void* window_modifier_main(void* arg);

// Global state
static pthread_t window_modifier_thread = 0;
static bool injection_initialized = false;

// Forward declarations
static void cleanup_injection(void);

// Print basic process info for diagnostics
static void print_process_info(void) {
    // Get executable path
    char path[1024];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        printf("[Injector] Process path: %s\n", path);
    } else {
        printf("[Injector] Failed to get process path\n");
    }
    
    // Get process ID and parent
    pid_t pid = getpid();
    pid_t ppid = getppid();
    printf("[Injector] Process ID: %d, Parent: %d\n", pid, ppid);
    
    // Get executable name
    const char* processName = getprogname();
    printf("[Injector] Process name: %s\n", processName);
}

// Register for cleanup during process termination
static void register_cleanup(void) {
    // Register our cleanup function with atexit
    atexit(cleanup_injection);
    
    printf("[Injector] Cleanup handler registered\n");
}

// Clean up resources before termination
static void cleanup_injection(void) {
    if (!injection_initialized) {
        return;
    }
    
    printf("[Injector] Performing injection cleanup\n");
    
    // Stop window modifier thread
    if (window_modifier_thread != 0) {
        pthread_cancel(window_modifier_thread);
        printf("[Injector] Window modifier thread stopped\n");
    }
    
    // Clean up window classifier
    cleanup_window_classifier();
    
    injection_initialized = false;
    printf("[Injector] Injection cleanup complete\n");
}

// Initialize the window modifier with enhanced error handling
static bool init_window_modifier(void) {
    // Initialize window classifier
    if (!init_window_classifier()) {
        printf("[Injector] Failed to initialize window classifier\n");
        return false;
    }
    
    // Create window modifier thread with better error recovery
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) {
        printf("[Injector] Failed to initialize thread attributes\n");
        cleanup_window_classifier();
        return false;
    }
    
    // Set thread as detached to avoid resource leaks
    if (pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED) != 0) {
        printf("[Injector] Failed to set thread as detached\n");
        pthread_attr_destroy(&attr);
        cleanup_window_classifier();
        return false;
    }
    
    // Set higher thread priority for better responsiveness
    struct sched_param param;
    param.sched_priority = 50; // Mid-range priority
    if (pthread_attr_setschedparam(&attr, &param) != 0) {
        printf("[Injector] Warning: Failed to set thread priority (non-fatal)\n");
        // Continue despite this error as it's not critical
    }
    
    // Create the thread
    int result = pthread_create(&window_modifier_thread, &attr, window_modifier_main, NULL);
    pthread_attr_destroy(&attr);
    
    if (result != 0) {
        printf("[Injector] Failed to create window modifier thread: %d (%s)\n", 
               result, strerror(result));
        cleanup_window_classifier();
        return false;
    }
    
    printf("[Injector] Window modifier thread created\n");
    return true;
}

// Main entry point for injected code
__attribute__((constructor))
static void injection_entry(void) {
    // Print banner
    printf("\n=======================================\n");
    printf("Window Modifier Injection Started\n");
    printf("=======================================\n");
    
    // Print process info
    print_process_info();
    
    // Register cleanup handler
    register_cleanup();
    
    // Initialize window modifier
    if (!init_window_modifier()) {
        printf("[Injector] Failed to initialize window modifier\n");
        return;
    }
    
    injection_initialized = true;
    printf("[Injector] Injection successfully initialized\n");
}
