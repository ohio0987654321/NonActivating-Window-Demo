#import "AppDelegate.h"

@interface NonActivatingWindow : NSPanel
@end

@implementation NonActivatingWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Initialize as a regular app temporarily (for Mission Control visibility)
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    
    // Create a non-activating panel
    NonActivatingWindow *customWindow = [[NonActivatingWindow alloc] 
                                        initWithContentRect:NSMakeRect(100, 100, 400, 300)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | 
                                                 NSWindowStyleMaskResizable | NSWindowStyleMaskNonactivatingPanel
                                        backing:NSBackingStoreBuffered
                                        defer:NO];
    
    self.window = customWindow;
    
    // Basic window configuration
    [self.window setTitle:@"Window"];
    [self.window setBackgroundColor:[NSColor systemBlueColor]];
    [self.window setSharingType:NSWindowSharingNone]; // Screen capture bypass
    [self.window setLevel:NSFloatingWindowLevel]; // Always on top
    
    // Configure for Mission Control and window management
    [self.window setCollectionBehavior:NSWindowCollectionBehaviorDefault | 
                                      NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorParticipatesInCycle |
                                      NSWindowCollectionBehaviorManaged];
    
    // Panel-specific settings
    [(NSPanel *)self.window setBecomesKeyOnlyIfNeeded:YES];
    [(NSPanel *)self.window setWorksWhenModal:YES];
    [(NSPanel *)self.window setHidesOnDeactivate:NO];
    
    // Add a text field
    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 150, 300, 30)];
    [textField setPlaceholderString:@"Key input test"];
    [[self.window contentView] addSubview:textField];
    
    // Show the window
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    
    // Hide Dock icon
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

@end