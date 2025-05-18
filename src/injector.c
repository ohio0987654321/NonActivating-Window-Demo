// injector.c - Enhanced for multi-process applications
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <stdbool.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <libproc.h>
#include <CoreFoundation/CoreFoundation.h>
#include <time.h>

// Constants for registry paths
#define REGISTRY_DIR "/tmp/window_modifier"
#define REGISTRY_FILE "registry.dat"

// Application patterns
typedef struct {
    const char *appName;
    const char *mainExe;
    const char **additionalExes;
    bool isMultiProcess;
} AppPattern;

// List of known multi-process applications and their patterns
static const char *electronExes[] = {"Helper", "GPU", "Renderer", "Plugin", NULL};
static const char *chromeExes[] = {"Renderer", "GPU Process", "Plugin", "Utility", NULL};
static const char *safariExes[] = {"WebProcess", "GPUProcess", "NetworkProcess", "PluginProcess", NULL};
static const char *firefoxExes[] = {"Web Content", "GPU Process", "RDD Process", "Socket Process", NULL};

// We'll keep these patterns available for future enhancements
static const AppPattern knownApps[] __attribute__((unused)) = {
    {"Discord", "Discord", electronExes, true},
    {"Slack", "Slack", electronExes, true},
    {"Chrome", "Google Chrome", chromeExes, true},
    {"Safari", "Safari", safariExes, true},
    {"Firefox", "firefox", firefoxExes, true},
    {NULL, NULL, NULL, false} // Sentinel
};

// Path to our DYLIB
static char dylibPath[PATH_MAX];

// PID of the main process we launched
static pid_t mainPid = 0;

// Forward declaration
static int injectDylib(const char *executablePath, const char *dylibPath, bool waitForExit);

/**
 * Signal handler for clean termination
 */
static void signalHandler(int sig) {
    printf("\nReceived signal %d, shutting down...\n", sig);
    
    // Kill the main process if it's still running
    if (mainPid > 0) {
        kill(mainPid, SIGTERM);
        printf("Sent SIGTERM to process %d\n", mainPid);
        
        // Give a short time for the process to exit gracefully
        usleep(500000); // 500ms
        
        // Force kill if still running
        if (kill(mainPid, 0) == 0) {
            printf("Process still running, sending SIGKILL\n");
            kill(mainPid, SIGKILL);
        }
    }
    
    exit(0);
}

/**
 * Checks if a file exists and is executable
 */
static bool isExecutable(const char *path) {
    return access(path, X_OK) == 0;
}

/**
 * Checks if an application path is valid
 */
static bool isValidAppPath(const char *path) {
    struct stat s;
    if (stat(path, &s) != 0) {
        return false;
    }
    
    // Check if it's a directory or executable file
    if (S_ISDIR(s.st_mode)) {
        // Check if it's a .app bundle
        if (strstr(path, ".app") != NULL) {
            return true;
        }
        return false;
    }
    
    // Check if it's an executable file
    return isExecutable(path);
}

/**
 * Finds the main executable in an .app bundle or validates a direct executable path
 */
static bool findMainExecutable(const char *appPath, char *exePath, size_t maxLen) {
    // First check if the provided path is directly executable
    struct stat s;
    if (stat(appPath, &s) == 0 && S_ISREG(s.st_mode) && isExecutable(appPath)) {
        printf("Using direct executable path: %s\n", appPath);
        strncpy(exePath, appPath, maxLen);
        return true;
    }
    
    // For .app bundles, construct the path to the main executable
    if (strstr(appPath, ".app") != NULL) {
        // Check if path already includes Contents/MacOS/ and points to an executable
        if (strstr(appPath, "/Contents/MacOS/") != NULL) {
            // This might be a direct path to the executable inside the bundle
            if (stat(appPath, &s) == 0 && S_ISREG(s.st_mode) && isExecutable(appPath)) {
                printf("Using executable in app bundle: %s\n", appPath);
                strncpy(exePath, appPath, maxLen);
                return true;
            }
        }
        
        // Otherwise, try to find the executable in the bundle
        char macOSPath[PATH_MAX];
        snprintf(macOSPath, sizeof(macOSPath), "%s/Contents/MacOS", appPath);
        
        // Check if the MacOS directory exists
        if (stat(macOSPath, &s) != 0 || !S_ISDIR(s.st_mode)) {
            printf("Error: Invalid application bundle structure: MacOS directory not found\n");
            return false;
        }
        
        // Find the executable in the MacOS directory
        DIR *dir = opendir(macOSPath);
        if (!dir) {
            printf("Error opening MacOS directory: %s\n", strerror(errno));
            return false;
        }
        
        struct dirent *entry;
        bool found = false;
        
        while ((entry = readdir(dir)) != NULL) {
            // Skip . and .. entries
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            
            // Construct path to potential executable
            char potentialExe[PATH_MAX];
            snprintf(potentialExe, sizeof(potentialExe), "%s/%s", macOSPath, entry->d_name);
            
            // Check if it's executable
            if (isExecutable(potentialExe)) {
                // Found an executable, use it
                snprintf(exePath, maxLen, "%s", potentialExe);
                found = true;
                printf("Found executable in app bundle: %s\n", exePath);
                break;
            }
        }
        
        closedir(dir);
        
        if (!found) {
            printf("Error: No executable found in application bundle\n");
            return false;
        }
        
        return true;
    }
    
    // Neither a direct executable nor a proper app bundle
    printf("Error: Path is neither an executable nor a valid app bundle: %s\n", appPath);
    return false;
}

/**
 * Find and kill all running instances of an application
 */
static void killRunningInstances(const char *appName) {
    char cmd[PATH_MAX + 50];
    
    // Use pkill to kill all processes with the app name
    snprintf(cmd, sizeof(cmd), "pkill -9 \"%s\" 2>/dev/null || true", appName);
    
    printf("Stopping any running %s instances...\n", appName);
    system(cmd);
    
    // Small delay to ensure processes are terminated
    usleep(500000); // 500ms
}

/**
 * Clean up registry directory and files
 */
static void cleanupRegistry(void) {
    char registryPath[PATH_MAX];
    snprintf(registryPath, sizeof(registryPath), "%s/%s", REGISTRY_DIR, REGISTRY_FILE);
    
    // Delete registry file if it exists
    if (access(registryPath, F_OK) == 0) {
        if (unlink(registryPath) == 0) {
            printf("Removed existing registry file: %s\n", registryPath);
        } else {
            printf("Warning: Failed to remove registry file: %s (errno: %d)\n", 
                   registryPath, errno);
        }
    }
    
    // Create registry directory if it doesn't exist
    struct stat st;
    if (stat(REGISTRY_DIR, &st) != 0) {
        if (mkdir(REGISTRY_DIR, 0755) == 0) {
            printf("Created registry directory: %s\n", REGISTRY_DIR);
        } else {
            printf("Warning: Failed to create registry directory: %s (errno: %d)\n", 
                   REGISTRY_DIR, errno);
        }
    }
    
    // Ensure permissions are correct
    chmod(REGISTRY_DIR, 0755);
}

/**
 * Enhanced DYLIB injection with environment setup
 */
static int injectDylib(const char *executablePath, const char *dylibPath, bool waitForExit) {
    // Validate inputs
    if (!executablePath || !dylibPath) {
        return 1;
    }
    
    // Get the file name from path
    const char *execName = strrchr(executablePath, '/');
    execName = execName ? execName + 1 : executablePath;
    
    // Prepare environment variables for injection
    char dyldInsertLibraries[PATH_MAX + 50];
    snprintf(dyldInsertLibraries, sizeof(dyldInsertLibraries), 
            "DYLD_INSERT_LIBRARIES=%s", dylibPath);
    
    char dyldForceFlat[50] = "DYLD_FORCE_FLAT_NAMESPACE=1";
    
    // Set up environment variables for the child process
    // Include the parent environment plus our additions
    extern char **environ;
    char **parentEnv = environ;
    
    // Count parent environment variables
    int parentEnvCount = 0;
    while (parentEnv[parentEnvCount] != NULL) {
        parentEnvCount++;
    }
    
    // Allocate space for parent env + our additions + NULL terminator
    char **newEnv = (char **)malloc((parentEnvCount + 3) * sizeof(char *));
    if (!newEnv) {
        perror("Failed to allocate memory for environment");
        return 1;
    }
    
    // Copy parent environment variables, skipping any existing DYLD_INSERT_LIBRARIES
    int newEnvCount = 0;
    for (int i = 0; i < parentEnvCount; i++) {
        if (strncmp(parentEnv[i], "DYLD_INSERT_LIBRARIES=", 22) != 0 &&
            strncmp(parentEnv[i], "DYLD_FORCE_FLAT_NAMESPACE=", 26) != 0) {
            newEnv[newEnvCount++] = parentEnv[i];
        }
    }
    
    // Add our environment variables
    newEnv[newEnvCount++] = dyldInsertLibraries;
    newEnv[newEnvCount++] = dyldForceFlat;
    newEnv[newEnvCount] = NULL;
    
    // Arguments for the executable
    char *args[] = { (char *)executablePath, NULL };
    
    // Create and run the child process
    pid_t pid;
    int status;
    
    printf("Launching %s with modifier...\n", execName);
    printf("DYLIB: %s\n", dylibPath);
    printf("Executable: %s\n", executablePath);
    
    // Launch the process using posix_spawnp
    status = posix_spawnp(&pid, executablePath, NULL, NULL, args, newEnv);
    
    // Free the environment array (but not the strings themselves)
    free(newEnv);
    
    if (status != 0) {
        printf("Error: posix_spawn: %s\n", strerror(status));
        return 1;
    }
    
    printf("%s started with PID: %d\n", execName, pid);
    
    // Save the main process PID for signal handling
    if (waitForExit) {
        mainPid = pid;
    }
    
    // Wait for the child process to exit if requested
    if (waitForExit) {
        printf("\nProcess is running. Press Ctrl+C to exit.\n");
        if (waitpid(pid, &status, 0) != -1) {
            printf("Process exited with status: %d\n", WEXITSTATUS(status));
            return WEXITSTATUS(status);
        } else {
            perror("waitpid failed");
            return 1;
        }
    }
    
    return 0;
}

/**
 * Wait for processes to initialize and show status
 * 
 * Note: This function is kept for future functionality but not currently used
 */
static void waitForProcessInitialization(pid_t mainPid) __attribute__((unused));
static void waitForProcessInitialization(pid_t mainPid) {
    printf("Waiting for processes to initialize...\n");
    
    // Wait for initial startup
    usleep(1000000); // 1 second
    
    // Check if main process is still running
    if (kill(mainPid, 0) != 0) {
        printf("Warning: Main process %d terminated prematurely\n", mainPid);
        return;
    }
    
    // Count child processes - important for multi-process apps
    int childCount = 0;
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "pgrep -P %d | wc -l", mainPid);
    
    FILE *fp = popen(cmd, "r");
    if (fp) {
        char buffer[32];
        if (fgets(buffer, sizeof(buffer), fp)) {
            childCount = atoi(buffer);
        }
        pclose(fp);
    }
    
    if (childCount > 0) {
        printf("Detected %d child processes - good sign for multi-process apps\n", childCount);
    } else {
        printf("No child processes detected yet - app may be single-process or still initializing\n");
    }
    
    // Wait a little longer for full initialization
    usleep(2000000); // 2 seconds
    
    // Check again
    if (kill(mainPid, 0) != 0) {
        printf("Warning: Main process %d terminated during initialization\n", mainPid);
        return;
    }
    
    printf("\nWindow modifier should now be active on all application windows.\n");
    printf("You should see:\n");
    printf("- Windows that stay on top of other applications\n");
    printf("- Windows that don't steal focus when clicked\n");
    printf("- Windows that are hidden in screenshots (test with ⌘+Shift+4)\n\n");
}

/**
 * Main entry point
 */
int main(int argc, char *argv[]) {
    // Check command line arguments
    if (argc < 2) {
        printf("Usage: %s /path/to/application.(app|executable) [--debug]\n", argv[0]);
        printf("Examples:\n");
        printf("  %s /Applications/Discord.app\n", argv[0]);
        printf("  %s /Applications/Slack.app\n", argv[0]);
        printf("  %s /Applications/Google\\ Chrome.app --debug\n", argv[0]);
        return 1;
    }
    
    // Get the application path from arguments
    const char *appPath = argv[1];
    bool debugMode = (argc > 2 && strcmp(argv[2], "--debug") == 0);
    
    if (debugMode) {
        printf("Debug mode enabled: extra logging will be displayed\n");
    }
    
    // Verify the application exists
    if (!isValidAppPath(appPath)) {
        printf("Error: Application not found or not valid: %s\n", appPath);
        return 1;
    }
    
    // Find the executable path
    char executablePath[PATH_MAX];
    if (!findMainExecutable(appPath, executablePath, sizeof(executablePath))) {
        printf("Error: Could not find main executable in: %s\n", appPath);
        return 1;
    }
    
    // Get the app name (for logging and process management)
    const char *appName = strrchr(executablePath, '/');
    appName = appName ? appName + 1 : executablePath;
    
    // Get the DYLIB path (expected to be in the build directory)
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
    
    // Clean up registry files for fresh start
    cleanupRegistry();
    
    // Kill any existing instances of the app
    killRunningInstances(appName);
    
    // Set up signal handlers for clean termination
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);
    signal(SIGSEGV, signalHandler); // Also catch segfaults
    
    printf("\nLaunching %s with window modifier...\n", appName);
    
    // Set up debug environment if needed
    if (debugMode) {
        putenv("OBJC_DEBUG_MISSING_POOLS=YES");
        putenv("OBJC_PRINT_EXCEPTIONS=YES");
    }
    
    // Inject the DYLIB into the executable
    if (injectDylib(executablePath, dylibPath, true) != 0) {
        printf("Error: Failed to inject DYLIB into application\n");
        return 1;
    }
    
    return 0;
}
