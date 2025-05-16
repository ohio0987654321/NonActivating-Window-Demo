// injector.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <path-to-app>\n", argv[0]);
        return 1;
    }
    
    // Get the path to the executable file
    char execPath[1024];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        fprintf(stderr, "Path buffer too small\n");
        return 1;
    }
    
    // Convert to absolute path
    char realPath[1024];
    if (!realpath(execPath, realPath)) {
        perror("Could not determine executable path");
        return 1;
    }
    
    // Get executable file directory
    char *execDir = dirname(realPath);
    
    // Path construction to dylib
    char dylibPath[1024];
    snprintf(dylibPath, sizeof(dylibPath), "%s/libwindowmodifier.dylib", execDir);
    
    // Target path processing
    char targetPath[2048];
    if (strstr(argv[1], ".app") && !strstr(argv[1], "Contents/MacOS")) {
        // For .app bundles, build the executable file path
        char appName[256];
        strcpy(appName, basename((char*)argv[1]));
        char *dotApp = strstr(appName, ".app");
        if (dotApp) *dotApp = '\0';
        
        snprintf(targetPath, sizeof(targetPath), "%s/Contents/MacOS/%s", argv[1], appName);
    } else {
        // For direct executable files
        strncpy(targetPath, argv[1], sizeof(targetPath)-1);
    }
    
    // Injection command execution
    char command[4096];
    snprintf(command, sizeof(command), "DYLD_INSERT_LIBRARIES=\"%s\" \"%s\"", 
             dylibPath, targetPath);
    
    printf("Injecting into %s...\n", targetPath);
    return system(command);
}