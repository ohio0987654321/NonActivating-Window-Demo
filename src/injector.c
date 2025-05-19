// injector.c - Universal injector for all macOS applications with arch detection
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
#include <sys/types.h>
#include <sys/sysctl.h>

// Constants for registry paths
#define REGISTRY_DIR "/tmp/window_modifier"
#define REGISTRY_FILE "registry.dat"

// Process Types - Classification for application architecture
typedef enum {
    PROCESS_TYPE_STANDARD,       // Standard single-process app (most macOS applications)
    PROCESS_TYPE_MULTI_PROCESS,  // App with multiple processes architecture
    PROCESS_TYPE_AGENT           // Background agent or daemon process
} process_type_t;

// Process identification and detection
typedef struct {
    const char *processName;       // Process name pattern
    process_type_t processType;    // Type of process
} ProcessPattern;

// Common process architectural patterns
// This detects common patterns across macOS applications
// No application-specific patterns should be here
static const ProcessPattern knownPatterns[] = {
    // Multi-process architecture indicators - found in many modern macOS apps
    {"Helper", PROCESS_TYPE_MULTI_PROCESS},
    {"GPU", PROCESS_TYPE_MULTI_PROCESS},
    {"Renderer", PROCESS_TYPE_MULTI_PROCESS},
    {"WebProcess", PROCESS_TYPE_MULTI_PROCESS},
    {"WebContent", PROCESS_TYPE_MULTI_PROCESS},
    
    // Services and agents
    {"Agent", PROCESS_TYPE_AGENT},
    {"Service", PROCESS_TYPE_AGENT},
    {"Daemon", PROCESS_TYPE_AGENT},
    
    // Framework processes
    {"XPC", PROCESS_TYPE_MULTI_PROCESS},
    {"Extension", PROCESS_TYPE_MULTI_PROCESS},
    {"Plugin", PROCESS_TYPE_MULTI_PROCESS},
    
    // Default - all other apps
    {NULL, PROCESS_TYPE_STANDARD}  // Sentinel
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
 * Detects the type of application based on its executable name and structure
 */
static process_type_t detectProcessType(const char *executablePath) {
    const char *execName = strrchr(executablePath, '/');
    execName = execName ? execName + 1 : executablePath;
    
    // Check against known patterns
    for (int i = 0; knownPatterns[i].processName != NULL; i++) {
        if (strstr(execName, knownPatterns[i].processName) != NULL) {
            return knownPatterns[i].processType;
        }
    }
    
    // If executable is in a standard macOS app bundle, it's likely a standard app
    if (strstr(executablePath, ".app/Contents/MacOS/") != NULL) {
        return PROCESS_TYPE_STANDARD;
    }
    
    // Default to standard
    return PROCESS_TYPE_STANDARD;
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
    
    // Check if it's a direct path to an executable inside a bundle
    if (strstr(appPath, "/Contents/MacOS/") != NULL) {
        if (stat(appPath, &s) == 0 && S_ISREG(s.st_mode) && isExecutable(appPath)) {
            printf("Using executable in app bundle: %s\n", appPath);
            strncpy(exePath, appPath, maxLen);
            return true;
        }
    }
    
    // For .app bundles, construct the path to the main executable
    if (strstr(appPath, ".app") != NULL) {
        // Try to find the executable in the bundle
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
 * Enhanced DYLIB injection with robust error handling for all macOS applications
 */
static int injectDylib(const char *executablePath, const char *dylibPath, bool waitForExit) {
    // Validate inputs with detailed error reporting
    if (!executablePath) {
        fprintf(stderr, "Error: No executable path provided for injection\n");
        return 1;
    }
    
    if (!dylibPath) {
        fprintf(stderr, "Error: No DYLIB path provided for injection\n");
        return 1;
    }
    
    // Verify executable exists and has proper permissions
    if (access(executablePath, F_OK) != 0) {
        fprintf(stderr, "Error: Executable not found: %s (errno: %d - %s)\n", 
                executablePath, errno, strerror(errno));
        return 1;
    }
    
    if (access(executablePath, X_OK) != 0) {
        fprintf(stderr, "Error: Executable not executable: %s (errno: %d - %s)\n", 
                executablePath, errno, strerror(errno));
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
    
    printf("Launching %s with window modifier...\n", execName);
    printf("DYLIB: %s\n", dylibPath);
    printf("Executable: %s\n", executablePath);
    
    // Detect process type for logging
    process_type_t processType = detectProcessType(executablePath);
    printf("Detected process type: %s\n", 
           processType == PROCESS_TYPE_MULTI_PROCESS ? "Multi-process application" : 
           processType == PROCESS_TYPE_AGENT ? "Agent/service process" : 
           "Standard application");
    
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
 * Get the CPU architecture of the current system
 * Returns a string representing the architecture: "x86_64", "arm64", "arm64e", or "unknown"
 */
static const char* detectCPUArchitecture(void) {
    // Method 1: Use native macOS APIs (most reliable)
    char buffer[128];
    size_t size = sizeof(buffer);
    
    // Get the machine hardware name
    if (sysctlbyname("hw.machine", buffer, &size, NULL, 0) == 0) {
        printf("Hardware machine: %s\n", buffer);
        
        // Check for ARM-based Macs with specific models
        if (strncmp(buffer, "arm64e", 6) == 0) {
            return "arm64e";  // M1 Pro, M1 Max, M1 Ultra, M2 etc.
        }
        else if (strncmp(buffer, "arm64", 5) == 0) {
            return "arm64";   // Base M1
        }
    }
    
    // Method 2: Get the CPU type and subtype as a fallback
    size = sizeof(buffer);
    if (sysctlbyname("hw.cputype", buffer, &size, NULL, 0) == 0) {
        unsigned int cpu_type = *(unsigned int*)buffer;
        
        size = sizeof(buffer);
        if (sysctlbyname("hw.cpusubtype", buffer, &size, NULL, 0) == 0) {
            unsigned int cpu_subtype = *(unsigned int*)buffer;
            printf("CPU type: 0x%08x, subtype: 0x%08x\n", cpu_type, cpu_subtype);
            
            // CPU_TYPE_X86_64 is 0x01000007
            if (cpu_type == 0x01000007) {
                return "x86_64";
            } 
            // CPU_TYPE_ARM64 is 0x0100000c
            else if (cpu_type == 0x0100000c) {
                // CPU_SUBTYPE_ARM64E is 2
                if (cpu_subtype == 2) {
                    return "arm64e";
                }
                return "arm64";
            }
        }
    }
    
    // Method 3: Use NXGetLocalArchInfo() if available via dyld
    #if defined(__APPLE__)
    // The following code attempts to use NXGetLocalArchInfo() but is wrapped in
    // preprocessor directives to avoid link-time errors
    #ifdef HAVE_NXGETLOCALARCHINFO
    #include <mach-o/arch.h>
    const NXArchInfo *archInfo = NXGetLocalArchInfo();
    if (archInfo != NULL) {
        printf("Arch info name: %s, description: %s\n", 
               archInfo->name, archInfo->description);
        
        if (strcmp(archInfo->name, "x86_64") == 0) {
            return "x86_64";
        } else if (strcmp(archInfo->name, "arm64") == 0) {
            return "arm64";
        } else if (strcmp(archInfo->name, "arm64e") == 0) {
            return "arm64e";
        }
    }
    #endif
    #endif
    
    // Method 4: Use compiler-defined macros as last resort
    #ifdef __x86_64__
        return "x86_64";
    #elif defined(__arm64e__)
        return "arm64e";
    #elif defined(__arm64__) || defined(__aarch64__)
        return "arm64";
    #else
        return "unknown";
    #endif
}

/**
 * Main entry point
 */
int main(int argc, char *argv[]) {
    // Detect system architecture
    const char* arch = detectCPUArchitecture();
    printf("Detected CPU Architecture: %s\n", arch);
    
    // Check command line arguments
    if (argc < 2) {
        printf("Usage: %s /path/to/application.(app|executable) [--debug]\n", argv[0]);
        printf("Description: Makes windows of the specified application float on top and non-activating.\n");
        printf("Examples:\n");
        printf("  %s /Applications/YourApp.app\n", argv[0]);
        printf("  %s /Applications/AnotherApp.app --debug\n", argv[0]);
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
