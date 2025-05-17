// injection_entry.c - Entry point for the injected DYLIB
#include <stdio.h>
#include <pthread.h>

// Forward declaration
extern void* window_modifier_main(void*);

// Entry point function for DYLIB injection
__attribute__((constructor))
void dylib_entry(void) {
    printf("Window modifier dylib injected successfully\n");
    
    // Call window_modifier_main in a separate thread
    pthread_t thread;
    pthread_create(&thread, NULL, window_modifier_main, NULL);
    pthread_detach(thread);
}