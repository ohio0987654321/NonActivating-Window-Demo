// window_modifier_cgs.h - Core Graphics Services functions
#ifndef WINDOW_MODIFIER_CGS_H
#define WINDOW_MODIFIER_CGS_H

#import <Cocoa/Cocoa.h>
#include "../core/window_modifier_types.h"

// CGS function pointers
extern CGSConnectionID (*CGSDefaultConnection_ptr)(void);
extern OSStatus (*CGSGetOnScreenWindowList_ptr)(CGSConnectionID cid, CGSConnectionID targetCID, int maxCount, CGSWindowID *list, int *outCount);
extern OSStatus (*CGSSetWindowLevel_ptr)(CGSConnectionID cid, CGSWindowID wid, int level);
extern OSStatus (*CGSSetWindowSharingState_ptr)(CGSConnectionID cid, CGSWindowID wid, int sharingState);
extern OSStatus (*CGSSetWindowTags_ptr)(CGSConnectionID cid, CGSWindowID wid, int *tags, int count);
extern OSStatus (*CGSRegisterNotifyProc_ptr)(CGSNotifyConnectionProcPtr proc, int event, void *userdata);
extern CGSConnectionID (*CGSGetWindowOwner_ptr)(CGSConnectionID cid, CGSWindowID wid);

// Load CGS functions
bool loadCGSFunctions(void);

// Window info functions
NSDictionary* getWindowInfoWithCGS(CGSWindowID windowID);
window_class_t determineWindowClass(CGSWindowID windowID, NSDictionary *windowInfo);
bool isUtilityWindow(CGSWindowID windowID);
bool isWindowReadyForModification(CGSWindowID windowID);
bool isWindowInitialized(CGSWindowID windowID);

#endif // WINDOW_MODIFIER_CGS_H
