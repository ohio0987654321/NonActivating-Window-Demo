// injection_entry.c
#include <stdio.h>
#include <pthread.h>

// Declaration of window_modifier_main function
void* window_modifier_main(void* arg);

// Function called when DyLib is loaded
__attribute__((constructor))
static void dylib_entry(void) {
    printf("Window modifier dylib injected successfully\n");
    
    // Runs in a separate thread (does not block the main thread)
    pthread_t thread;
    pthread_create(&thread, NULL, window_modifier_main, NULL);
    pthread_detach(thread);
}