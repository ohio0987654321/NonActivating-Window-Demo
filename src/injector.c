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

static const AppPattern knownApps[] = {
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
 * Finds the main executable in an .app bundle
 */
static bool findMainExecutable(const char *appPath, char *exePath, size_t maxLen) {
    // For .app bundles, construct the path to the main executable
    if (strstr(appPath, ".app") != NULL) {
        // First try the modern structure: AppName.app/Contents/MacOS/AppName
        snprintf(exePath, maxLen, "%s/Contents/MacOS", appPath);
        
        // Check if the MacOS directory exists
        struct stat s;
        if (stat(exePath, &s) != 0 || !S_ISDIR(s.st_mode)) {
            printf("Error: Invalid application bundle structure: MacOS directory not found\n");
            return false;
        }
        
        // Find the executable in the MacOS directory
        DIR *dir = opendir(exePath);
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
            snprintf(potentialExe, sizeof(potentialExe), "%s/%s", exePath, entry->d_name);
            
            // Check if it's executable
            if (isExecutable(potentialExe)) {
                // Found an executable, use it
                snprintf(exePath, maxLen, "%s", potentialExe);
                found = true;
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
    
    // For direct executables, just copy the path
    if (isExecutable(appPath)) {
        strncpy(exePath, appPath, maxLen);
        return true;
    }
    
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
 * Main entry point
 */
int main(int argc, char *argv[]) {
    // Check command line arguments
    if (argc != 2) {
        printf("Usage: %s /path/to/application.(app|executable)\n", argv[0]);
        printf("Examples:\n");
        printf("  %s /Applications/Discord.app\n", argv[0]);
        printf("  %s /Applications/Slack.app\n", argv[0]);
        printf("  %s /Applications/Google\\ Chrome.app\n", argv[0]);
        return 1;
    }
    
    // Get the application path from arguments
    const char *appPath = argv[1];
    
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
    
    // Get the DYLIB path (expected to be in the current directory)
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
    
        // Create or clean up the registry directory in the temp location
    const char *tmp_dir = getenv("TMPDIR");
    if (!tmp_dir) {
        tmp_dir = "/tmp";
    }
    
    char registry_dir[PATH_MAX];
    snprintf(registry_dir, sizeof(registry_dir), "%s/window_modifier", tmp_dir);
    
    // Create registry directory if it doesn't exist
    struct stat st;
    if (stat(registry_dir, &st) != 0) {
        mkdir(registry_dir, 0755);
        printf("Created registry directory: %s\n", registry_dir);
    } else {
        // Clean registry to avoid using stale data
        char registry_file[PATH_MAX];
        snprintf(registry_file, sizeof(registry_file), "%s/registry.dat", registry_dir);
        if (access(registry_file, F_OK) == 0) {
            if (unlink(registry_file) == 0) {
                printf("Removed stale registry file: %s\n", registry_file);
            } else {
                printf("Note: Failed to remove stale registry file: %s\n", registry_file);
            }
        }
    }
    
    // Kill any existing instances of the app
    killRunningInstances(appName);
    
    // Set up signal handlers for clean termination
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);
    signal(SIGSEGV, signalHandler); // Also catch segfaults
    
    printf("\nLaunching %s with window modifier...\n", appName);
    printf("Press Ctrl+C to exit\n\n");
    
    // Inject the DYLIB into the executable
    if (injectDylib(executablePath, dylibPath, true) != 0) {
        printf("Error: Failed to inject DYLIB into application\n");
        return 1;
    }
    
    return 0;
}
