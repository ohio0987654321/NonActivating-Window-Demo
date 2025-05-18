// injection_entry.c - Entry point for the injected DYLIB
#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <libproc.h>
#include <unistd.h>
#include <time.h>
#include "window_registry.h"

// Forward declaration
extern void* window_modifier_main(void*);

// Process type detection
typedef enum {
    PROCESS_TYPE_UNKNOWN,
    PROCESS_TYPE_MAIN,
    PROCESS_TYPE_RENDERER,
    PROCESS_TYPE_HELPER,
    PROCESS_TYPE_PLUGIN,
    PROCESS_TYPE_GPU,
    PROCESS_TYPE_NETWORK,
    PROCESS_TYPE_UTILITY
} process_type_t;

// Detect what type of process we're running in
static process_type_t detect_process_type(void) {
    // Get the process name
    char proc_path[PROC_PIDPATHINFO_MAXSIZE];
    char proc_name[256] = {0};
    
    pid_t pid = getpid();
    proc_pidpath(pid, proc_path, sizeof(proc_path));
    
    // Extract basename
    const char *last_slash = strrchr(proc_path, '/');
    if (last_slash) {
        strncpy(proc_name, last_slash + 1, sizeof(proc_name) - 1);
    } else {
        strncpy(proc_name, proc_path, sizeof(proc_name) - 1);
    }
    
    // Enhanced detection for Discord and Electron apps
    
    // Common patterns for renderer processes in various frameworks
    if (strstr(proc_name, "Renderer") || 
        strstr(proc_name, "renderer") || 
        strstr(proc_name, "WebProcess") || 
        strstr(proc_name, "WebContent")) {
        return PROCESS_TYPE_RENDERER;
    }
    
    // Network service processes
    if (strstr(proc_name, "Network") || 
        strstr(proc_name, "network") ||
        strstr(proc_name, "Service") ||
        strstr(proc_name, "service")) {
        return PROCESS_TYPE_NETWORK;
    }
    
    // GPU process types
    if (strstr(proc_name, "GPU") || 
        strstr(proc_name, "Gpu") ||
        strstr(proc_name, "gpu")) {
        return PROCESS_TYPE_GPU;
    }
    
    // Plugin process types
    if (strstr(proc_name, "Plugin") || 
        strstr(proc_name, "plugin")) {
        return PROCESS_TYPE_PLUGIN;
    }
    
    // Utility process types - expanded patterns
    if (strstr(proc_name, "Utility") || 
        strstr(proc_name, "utility") ||
        strstr(proc_name, "crashpad") ||
        strstr(proc_name, "Crashpad")) {
        return PROCESS_TYPE_UTILITY;
    }
    
    // Helper process types
    if (strstr(proc_name, "Helper") || 
        strstr(proc_name, "helper") || 
        strstr(proc_name, "Agent")) {
        return PROCESS_TYPE_HELPER;
    }
    
    // Check if it's likely the main executable
    if (strstr(proc_path, ".app/Contents/MacOS/")) {
        return PROCESS_TYPE_MAIN;
    }
    
    // Couldn't determine definitively
    return PROCESS_TYPE_UNKNOWN;
}

// Get process type as string
static const char* process_type_name(process_type_t type) {
    switch (type) {
        case PROCESS_TYPE_MAIN: return "Main";
        case PROCESS_TYPE_RENDERER: return "Renderer";
        case PROCESS_TYPE_HELPER: return "Helper";
        case PROCESS_TYPE_PLUGIN: return "Plugin";
        case PROCESS_TYPE_GPU: return "GPU";
        case PROCESS_TYPE_NETWORK: return "Network";
        case PROCESS_TYPE_UTILITY: return "Utility";
        default: return "Unknown";
    }
}

// Entry point function for DYLIB injection
__attribute__((constructor))
void dylib_entry(void) {
    // Get process information
    pid_t pid = getpid();
    char proc_path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    proc_pidpath(pid, proc_path, sizeof(proc_path));
    process_type_t proc_type = detect_process_type();
    
    printf("[WINDOW-MOD] Window Modifier v1.0 loaded!\n");
    printf("[WINDOW-MOD] Process: %s (PID: %d)\n", proc_path, pid);
    printf("[WINDOW-MOD] Process type: %s\n", process_type_name(proc_type));
    
    // Initialize registry (shared across all processes)
    window_registry_t *registry = registry_init();
    if (!registry) {
        printf("[WINDOW-MOD] Warning: Failed to initialize window registry\n");
        printf("[WINDOW-MOD] Continuing in standalone mode (no cross-process coordination)\n");
    } else {
        printf("[WINDOW-MOD] Window registry initialized successfully\n");
    }
    
    // Time-based protection for certain process types
    if (proc_type == PROCESS_TYPE_NETWORK || 
        proc_type == PROCESS_TYPE_GPU || 
        proc_type == PROCESS_TYPE_UTILITY) {
        // No need to modify windows for these service processes
        printf("[WINDOW-MOD] Service process detected, window modification disabled\n");
        return;
    }
    
    // Call window_modifier_main in a separate thread
    pthread_t thread;
    int create_result = pthread_create(&thread, NULL, window_modifier_main, NULL);
    
    if (create_result != 0) {
        printf("[WINDOW-MOD] Error: Failed to create window modifier thread (error: %d)\n", 
               create_result);
        
        // For critical process types, don't try to run in main thread
        // as it could interfere with the application's functionality
        if (proc_type == PROCESS_TYPE_MAIN) {
            printf("[WINDOW-MOD] Attempting to start modifier in main thread (fallback mode)\n");
            window_modifier_main(NULL);
        } else {
            printf("[WINDOW-MOD] Skipping window modification for safety\n");
        }
    } else {
        pthread_detach(thread);
        printf("[WINDOW-MOD] Window modifier thread started successfully\n");
    }
    
    printf("[WINDOW-MOD] Window modifier initialized\n");
}
