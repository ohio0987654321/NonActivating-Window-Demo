// injector.c - Standalone executable for DYLIB injection
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <CoreFoundation/CoreFoundation.h>

/**
 * Injects a DYLIB into the specified executable
 * 
 * @param executablePath Path to the target executable
 * @param dylibPath Path to the DYLIB to inject
 * @return 0 on success, non-zero on failure
 */
static int injectDylib(const char *executablePath, const char *dylibPath) {
    // Validate inputs
    if (!executablePath || !dylibPath) {
        return 1;
    }
    
    // Prepare environment variables for injection
    char dyldInsertLibraries[PATH_MAX + 50];
    sprintf(dyldInsertLibraries, "DYLD_INSERT_LIBRARIES=%s", dylibPath);
    
    // Environment variables to pass to the child process
    char *env[] = { dyldInsertLibraries, NULL };
    
    // Arguments for the executable
    char *args[] = { (char *)executablePath, NULL };
    
    // Create and run the child process
    pid_t pid;
    int status;
    
    printf("Injecting %s into %s\n", dylibPath, executablePath);
    
    // Launch the process using posix_spawnp
    status = posix_spawnp(&pid, executablePath, NULL, NULL, args, env);
    
    if (status != 0) {
        printf("Error: posix_spawn: %s\n", strerror(status));
        return 1;
    }
    
    printf("Process started with PID: %d\n", pid);
    
    // Wait for the child process to exit
    if (waitpid(pid, &status, 0) != -1) {
        printf("Process exited with status: %d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status);
    } else {
        perror("waitpid failed");
        return 1;
    }
}

int main(int argc, char *argv[]) {
    // Check command line arguments
    if (argc != 2) {
        printf("Usage: %s /path/to/application/executable\n", argv[0]);
        printf("Example: %s /Applications/App.app/Contents/MacOS/App\n", argv[0]);
        return 1;
    }
    
    // Get the executable path from arguments
    const char *executablePath = argv[1];
    
    // Verify the executable exists and is executable
    if (access(executablePath, X_OK) != 0) {
        printf("Error: Executable not found or not executable: %s\n", executablePath);
        return 1;
    }
    
    // Get the path to the DYLIB (expected to be in the current directory)
    char dylibPath[PATH_MAX];
    if (getcwd(dylibPath, sizeof(dylibPath)) == NULL) {
        perror("Failed to get current directory");
        return 1;
    }
    strcat(dylibPath, "/build/libwindowmodifier.dylib");
    
    // Verify the DYLIB exists
    if (access(dylibPath, R_OK) != 0) {
        printf("Error: libwindowmodifier.dylib not found in build directory\n");
        return 1;
    }
    
    // Inject the DYLIB into the executable
    return injectDylib(executablePath, dylibPath);
}