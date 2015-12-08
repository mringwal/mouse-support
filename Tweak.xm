/**
 * New maintainer/developer: Matthias Ringwald (mringwal)
 * see README.mdfor details
 *
 */

/**
 * Name: Mouse
 * Type: iPhone OS 3.x SpringBoard extension (MobileSubstrate-based)
 * Description: Support for controlling touches externally;
 *              translates of position/clicks, provides a visible mouse pointer
 * Author: Lance Fetters (aka. ashikase)
 * Last-modified: 2010-05-22 19:41:54
 */

/**
 * Copyright (C) 2009-2010  Lance Fetters (aka. ashikase)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. The name of the author may not be used to endorse or promote
 *    products derived from this software without specific prior
 *    written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include "substrate.h"

#import <UIKit/UIKit.h>
#import <GraphicsServices/GSEvent.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_port.h>
#include <mach/mach_init.h>
#include <dlfcn.h>

#include "hid-support.h"
#include "RocketBootstrap.h"

typedef struct {
    float x, y;
    int buttons;
    BOOL absolute;
} MouseEvent;

typedef enum {
    MouseMessageTypeEvent,
    MouseMessageTypeSetEnabled,
} MouseMessageType;

@interface CAWindowServer : NSObject
@property(readonly, assign) NSArray *displays;
+ (id)serverIfRunning;
@end

@interface CAWindowServerDisplay : NSObject
- (unsigned)clientPortAtPosition:(CGPoint)position;
@end

@interface CAContext : NSObject
@end

typedef struct {} Context;

@interface CAContextImpl : CAContext
- (Context *)renderContext;
@end

@interface SpringBoard : UIApplication
// active UI on 3.2+
-(int) activeInterfaceOrientation;
// frontmost app port on 6.0+
-(unsigned)_frontmostApplicationPort;
// unlock && undim on 3.0 & 3.1 - 6.x
-(void)resetIdleTimerAndUndim:(BOOL)fp8; 
// iOS 7+
-(void)resetIdleTimerAndUndim;
@end

@interface SBAwayController : NSObject
+ (id)sharedAwayController;
- (BOOL)undimsDisplay;
- (id)awayView;
- (void)lock;
- (void)_unlockWithSound:(BOOL)fp8;
- (void)unlockWithSound:(BOOL)fp8;
- (void)unlockWithSound:(BOOL)fp8 alertDisplay:(id)fp12;
- (void)loadPasscode;
- (id)devicePasscode;
- (BOOL)isPasswordProtected;
- (void)activationChanged:(id)fp8;
- (BOOL)isDeviceLockedOrBlocked;
- (void)setDeviceLocked:(BOOL)fp8;
- (void)applicationRequestedDeviceUnlock;
- (void)cancelApplicationRequestedDeviceLockEntry;
- (BOOL)isBlocked;
- (BOOL)isPermanentlyBlocked:(double *)fp8;
- (BOOL)isLocked;
- (void)attemptUnlock;
- (BOOL)isAttemptingUnlock;
- (BOOL)attemptDeviceUnlockWithPassword:(id)fp8 alertDisplay:(id)fp12;
- (void)cancelDimTimer;
- (void)restartDimTimer:(float)fp8;
- (id)dimTimer;
- (BOOL)isDimmed;
- (void)finishedDimmingScreen;
- (void)dimScreen:(BOOL)fp8;
- (void)undimScreen;
- (void)userEventOccurred;
- (void)activate;
- (void)deactivate;
@end

// from iOS 7+
@interface SBLockScreenManager
+(id)sharedInstance;
-(void)unlockUIFromSource:(int)source withOptions:(id)options;
@property(readonly, assign) BOOL isUILocked;
@end

// from iOS 7+
@interface SBUserAgent
+(id)sharedUserAgent;
-(void)undimScreen;
@end

@interface SBUIController : NSObject
+(SBUIController*) sharedInstance;
-(void) dismissSwitcherAnimated:(BOOL)animated;
// iOS 6
-(BOOL) isSwitcherShowing;
// iOS 7
-(BOOL) isAppSwitcherShowing;
@end

// from iOS 7+
@interface SBNotificationCenterController
+(id) sharedInstance;
-(BOOL)isVisible;
- (void)presentAnimated:(BOOL)animated;
- (void)dismissAnimated:(BOOL)animated;
@end

// from iOS 7+
@interface SBControlCenterController
+(id) sharedInstance;
-(BOOL)isVisible;
- (void)presentAnimated:(BOOL)animated;
- (void)dismissAnimated:(BOOL)animated;
@end

#if !defined(__IPHONE_3_2) || __IPHONE_3_2 > __IPHONE_OS_VERSION_MAX_ALLOWED
typedef enum {
    UIUserInterfaceIdiomPhone,           // iPhone and iPod touch style UI
    UIUserInterfaceIdiomPad,             // iPad style UI
} UIUserInterfaceIdiom;
@interface UIDevice (privateAPI)
- (BOOL) userInterfaceIdiom;
@end
#endif

@interface UIView (Private)
@property(assign) CGPoint origin;
@end

@interface UIWindow (Private)
- (void)setHidden:(BOOL)fp8;
// since iOS 8
- (void)_setSecure:(BOOL)arg1;
@end

@interface UIDevice (Private)
- (BOOL)isWildcat;
@end

@interface UIScreen (fourZeroAndLater)
+(UIScreen*) mainScreen;
@property(nonatomic,readonly) CGFloat scale;
@end

@interface SpringBoard (Mouse)
- (void)setMousePointerEnabled:(BOOL)enabled;
- (void)handleMouseEventAtPoint:(CGPoint)point buttons:(int)buttons;
- (CGPoint)handleMouseEventWithX:(float)x Y:(float)y buttons:(int)buttons;
- (void)moveMousePointerToPoint:(CGPoint)point;
- (CGPoint)mouseLocation;
- (void)mouseHandleOrientationChange:(int)orientation;
- (BOOL)mouseIsLocked;
@end


#define APP_ID "jp.ashikase.mousesupport"
#define MACH_PORT_NAME APP_ID

static CFDataRef mouseCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef cfData, void *info);

// View objects for the pointer
static UIWindow *mouseWin = nil;
static UIImageView *mouseView = nil;
static Context *mouseRenderContext = NULL;
static CGSize mouseImageSize;

// Screen limits (portrait)
static float screen_width = 320;
static float screen_height = 480;

// coordinates in portrait orientatino
static CGPoint currentMouseLocation = { 0, 0};

// Define button values
#define BUTTON_PRIMARY   0x01
#define BUTTON_SECONDARY 0x02
#define BUTTON_TERTIARY  0x04
static char buttonClick = BUTTON_PRIMARY;
static char buttonLock  = BUTTON_SECONDARY;
static char buttonHome  = BUTTON_TERTIARY;

// cloaking works
static BOOL cloakingSupport = NO;

// iPad support
static BOOL is_iPad = NO;

// iOS 5
static BOOL is_50_or_higher = NO;

// iOS 6
static BOOL is_60_or_higher = NO;

// Window server uses bitmap coordinates
static float retina_factor = 1.0f;

// Pointer orientation
static int orientation_ = 0;

// Speed is used with relative mouse positioning
static float mouseSpeed = 1.0f;

// GS functions
static bool PurpleAllocated = NO;
static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static CGSize      (*$GSMainScreenSize)(void);
static float       (*$GSMainScreenScaleFactor)(void);
static float       (*$GSMainScreenOrientation)(void);

//==============================================================================

// NOTE: Swiped from Jay Freeman (saurik)'s Veency

//==============================================================================

#ifndef __LP64__
template <typename Type_>
static inline void lookupSymbol(const char *libraryFilePath, const char *symbolName, Type_ &function)
{
    // Lookup the function
    struct nlist nl[2];
    memset(nl, 0, sizeof(nl));
    nl[0].n_un.n_name = (char *)symbolName;
    nlist(libraryFilePath, nl);

    // Check whether it is ARM or Thumb
    uintptr_t value = nl[0].n_value;
    if ((nl[0].n_desc & N_ARM_THUMB_DEF) != 0)
        value |= 0x00000001;

    function = reinterpret_cast<Type_>(value);
}
#endif

template <typename Type2>
static inline void MyMSHookSymbol(Type2 *&value, const char *name, void *handle = RTLD_DEFAULT) {
    value = reinterpret_cast<Type2 *>(dlsym(handle, name));
}

template <typename Type_>
static void dlset(Type_ &function, const char *name) {
    function = reinterpret_cast<Type_>(dlsym(RTLD_DEFAULT, name));
    // NSLog(@"hid-support: dlset %s = %p", name, function);
}

//==============================================================================
static uint8_t  touchEvent[sizeof(GSEventRecord) + sizeof(GSHandInfo) + sizeof(GSPathInfo)];

// types for touches
typedef enum __GSHandInfoType2 {
        kGSHandInfoType2TouchDown    = 1,    // first down
        kGSHandInfoType2TouchDragged = 2,    // drag
        kGSHandInfoType2TouchChange  = 5,    // nr touches change
        kGSHandInfoType2TouchFinal   = 6,    // final up
} GSHandInfoType2;

static void sendGSEventToSpringBoard(GSEventRecord *eventRecord){
    mach_port_t purple(0);
    purple = (*GSTakePurpleSystemEventPort)();
    if (purple) {
        GSSendEvent(eventRecord, purple);
    }
    if (purple && PurpleAllocated){
        mach_port_deallocate(mach_task_self(), purple);
    }
}

// decide on GSHandInfoType
static GSHandInfoType getHandInfoType(int touch_before, int touch_now){
    if (!touch_before) {
        return (GSHandInfoType) kGSHandInfoType2TouchDown;
    }
    if (touch_before == touch_now){
        return (GSHandInfoType) kGSHandInfoType2TouchDragged;        
    }
    if (touch_now) {
        return (GSHandInfoType) kGSHandInfoType2TouchChange;
    }
    return (GSHandInfoType) kGSHandInfoType2TouchFinal;
}

static void postMouseEventToSpringBoard(float x, float y, int click){

    static int prev_click = 0;

    if (!click && !prev_click) return;

    CGPoint location = CGPointMake(x, y);

    // structure of touch GSEvent
    struct GSTouchEvent {
        GSEventRecord record;
        GSHandInfo    handInfo;
    } * event = (struct GSTouchEvent*) &touchEvent;
    bzero(touchEvent, sizeof(touchEvent));
    
    // set up GSEvent
    event->record.type = kGSEventHand;
    event->record.windowLocation = location;
    event->record.timestamp = GSCurrentEventTimestamp();
    event->record.infoSize = sizeof(GSHandInfo) + sizeof(GSPathInfo);
    event->handInfo.type = getHandInfoType(prev_click, click);
    if (is_50_or_higher){
        event->handInfo.x52 = 1;
    } else {
        event->handInfo.pathInfosCount = 1;
    }
    bzero(&event->handInfo.pathInfos[0], sizeof(GSPathInfo));
    event->handInfo.pathInfos[0].pathIndex     = 1;
    event->handInfo.pathInfos[0].pathIdentity  = 2;
    event->handInfo.pathInfos[0].pathProximity = click ? 0x03 : 0x00;;
    event->handInfo.pathInfos[0].pathLocation  = location;

    // send GSEvent to SpringBoard
    sendGSEventToSpringBoard( (GSEventRecord*) event);  
    
    prev_click = click;  
}

//==============================================================================

static void try_rocketbootstrap_cfmessageportexposelocal(CFMessagePortRef local){
    void * rbs_lib = dlopen("/usr/lib/librocketbootstrap.dylib", RTLD_LAZY);
    if (!rbs_lib) return;
    void (*cfmessageportexposelocal)(CFMessagePortRef) =(void (*)(CFMessagePortRef)) dlsym(rbs_lib, "rocketbootstrap_cfmessageportexposelocal");
    if (!cfmessageportexposelocal);
    cfmessageportexposelocal(local);
}

//==============================================================================

static void loadPreferences()
{
    // defaults
    BOOL swapButtonsLeftRight = NO;
    mouseSpeed = 1.0f;

    NSArray *keys = [NSArray arrayWithObjects:@"swapButtonsOneTwo", @"swapButtonsTwoThree", @"mouseSpeed", nil];
    NSDictionary *dict = (NSDictionary *)CFPreferencesCopyMultiple((CFArrayRef)keys, CFSTR(APP_ID),
        kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    // NSLog(@"MouseSupport prefs %@", dict);
    if (dict) {
        NSArray *values = [dict objectsForKeys:keys notFoundMarker:[NSNull null]];
        id obj;

        obj = [values objectAtIndex:0];
        if ([obj isKindOfClass:[NSNumber class]])
            swapButtonsLeftRight = [obj boolValue];

        //
        // ignore swap buttons 2 & 3
        //

        obj = [values objectAtIndex:2];
        if ([obj isKindOfClass:[NSNumber class]])
            mouseSpeed = [obj floatValue];

        [dict release];
    }

    // set mouse buttons
    if (swapButtonsLeftRight) {
        buttonHome  = BUTTON_PRIMARY;
        buttonLock  = BUTTON_SECONDARY;
        buttonClick = BUTTON_TERTIARY;
    } else {
        buttonClick = BUTTON_PRIMARY;
        buttonLock  = BUTTON_SECONDARY;
        buttonHome  = BUTTON_TERTIARY;
    }
}

static void reloadPreferences(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    // NOTE: Must synchronize preferences from disk
    CFPreferencesAppSynchronize(CFSTR(APP_ID));
    loadPreferences();
}

static void updateOrientation()
{
    mouseView.transform = CGAffineTransformMakeRotation(orientation_ * M_PI / 180.0f);
}

static CFDataRef mouseCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef cfData, void *info)
{
    // orig:
    // static BOOL idleTimerDisabled = NO;

    // NOTE: Handle the most common case first
    switch (msgid) {
        case MouseMessageTypeEvent:
            // Handle the mouse event
            if (CFDataGetLength(cfData) == sizeof(MouseEvent)) {
                MouseEvent *event = (MouseEvent *)[(NSData *)cfData bytes];
                if (event != NULL) {
                    SpringBoard *springBoard = (SpringBoard *)[UIApplication sharedApplication];
                    if (event->absolute) {
                        [springBoard handleMouseEventAtPoint:CGPointMake(event->x, event->y) buttons:event->buttons];
                    }
                    else {
                        [springBoard handleMouseEventWithX:event->x Y:event->y buttons:event->buttons];
                    }
                }
            }
            break;
        case MouseMessageTypeSetEnabled:
            // Make sure pointer is visible and matches device orientation
            if (CFDataGetLength(cfData) == sizeof(BOOL)) {
                BOOL *enabled = (BOOL *)[(NSData *)cfData bytes];
                if (enabled != NULL) {
                    SpringBoard *springBoard = (SpringBoard *)[UIApplication sharedApplication];
                    [springBoard setMousePointerEnabled:(*enabled)];
                }
            }
            break;
        default:
            NSLog(@"Mouse: Unknown message type: %x", (int) msgid);
            break;
    }

    // Do not return a reply to the caller
    return NULL;
}

//
// support for notification center gestures 
//

#define EDGE_THRESHOLD 2.0f
#define ACTIVATE_THRESHOLD 100.0f;

@interface SBBulletinListController : NSObject 
-(void)showListViewAnimated:(BOOL)animated;
-(void)hideListViewAnimated:(BOOL)animated;
-(BOOL)listViewIsActive;
@end

typedef enum {
    no_touch = 1,
    swipe_from_top,
    swipe_from_bottom,
    wait_for_release
} gesture_t;
static gesture_t control_gesture_state = no_touch;
static gesture_t notification_gesture_state = no_touch;

float getMouseInterfaceYForCurrentOrientation(CGPoint point){
    switch (orientation_) {
        default:
        case 0: // Home button bottom
            return point.y;
        case 90: // Home button right
            return screen_width - point.x;
        case -90: // Home button left
            return point.x;
        case 180: // Home button top
            return screen_height - point.y;
    }
}
float getInterfaceHeightForCurrentOrientation(void){
    switch (orientation_) {
        default:
        case 0:   // Home button bottom
        case 180: // Home button top
            return screen_height;
        case -90: // Home button left
        case 90:  // Home button right
            return screen_width;
    }
}
BOOL mouseAtTopEdge(CGPoint point){
    return getMouseInterfaceYForCurrentOrientation(point) <= EDGE_THRESHOLD;
}
BOOL mouseAtBottomEdge(CGPoint point){
    float distanceToBottom = getInterfaceHeightForCurrentOrientation() - getMouseInterfaceYForCurrentOrientation(point);
    return distanceToBottom <= EDGE_THRESHOLD;
}
BOOL mouseBelowTopThreshold(CGPoint point){
    return getMouseInterfaceYForCurrentOrientation(point) >= ACTIVATE_THRESHOLD;
}
BOOL mouseAboveBottomThreshold(CGPoint point){
    return getInterfaceHeightForCurrentOrientation() - getMouseInterfaceYForCurrentOrientation(point) >= ACTIVATE_THRESHOLD;
}

// return true if event was handled/eaten
BOOL isControlCenterShown(){
     return [(SBControlCenterController*) [%c(SBControlCenterController) sharedInstance] isVisible];
}

BOOL isNotificationCenterShown(){
    return [(SBBulletinListController*)       [%c(SBBulletinListController) sharedInstance] listViewIsActive] ||
           [(SBNotificationCenterController*) [%c(SBNotificationCenterController) sharedInstance] isVisible];
}

BOOL handleNotificationCenterGestures(CGPoint point, int button){

    if (isControlCenterShown()) return false;
    if (control_gesture_state != no_touch) false;

    // iOS 5-6
    SBBulletinListController * bulletinController = (SBBulletinListController*) [%c(SBBulletinListController) sharedInstance];
    // iOS 7
    SBNotificationCenterController * notificationController = (SBNotificationCenterController*) [%c(SBNotificationCenterController) sharedInstance];

    if (!bulletinController && !notificationController) return false;

    BOOL isShown = isNotificationCenterShown();

    // state = local state + list view is active 
    switch (notification_gesture_state){
        case no_touch:
            if (!button) break;
            if (isShown){
                if (!mouseAtBottomEdge(point)) break;
                notification_gesture_state = swipe_from_bottom;
            } else {
                if (!mouseAtTopEdge(point)) break;
                notification_gesture_state = swipe_from_top;
            }
            return true;
        case swipe_from_top:
            if (!button || isShown){
                notification_gesture_state = no_touch;
                break;
            }
            if (!mouseBelowTopThreshold(point)) break;
            [bulletinController showListViewAnimated:YES];
            [notificationController presentAnimated:YES];
            notification_gesture_state = wait_for_release;
            return true;
        case swipe_from_bottom:
            if (!button || !isShown){
                notification_gesture_state = no_touch;
                break;
            }
            if (!mouseAboveBottomThreshold(point)) break;
            [bulletinController hideListViewAnimated:YES];
            [notificationController dismissAnimated:YES];
            notification_gesture_state = wait_for_release;
            return true;
        case wait_for_release:
            if (button) break;
            notification_gesture_state = no_touch;
            return true;
    }
    return false;
}

// return true if event was handled/eaten
BOOL handleControlCenterGestures(CGPoint point, int button){

    if (isNotificationCenterShown()) return false;
    if (notification_gesture_state != no_touch) false;

    // iOS 7
    SBControlCenterController * controlCenterController = (SBControlCenterController*) [%c(SBControlCenterController) sharedInstance];

    if (!controlCenterController) return false;

    BOOL isShown = isControlCenterShown();

    // state = local state + list view is active 
    switch (control_gesture_state){
        case no_touch:
            if (!button) break;
            if (isShown){
                if (!mouseAtTopEdge(point)) break;
                control_gesture_state = swipe_from_top;
            } else {
                if (!mouseAtBottomEdge(point)) break;
                control_gesture_state = swipe_from_bottom;
            }
            return true;
        case swipe_from_bottom:
            if (!button || isShown){
                control_gesture_state = no_touch;
                break;
            }
            if (!mouseAboveBottomThreshold(point)) break;
            [controlCenterController presentAnimated:YES];
            control_gesture_state = wait_for_release;
            return true;
        case swipe_from_top:
            if (!button || !isShown){
                control_gesture_state = no_touch;
                break;
            }
            if (!mouseBelowTopThreshold(point)) break;
            [controlCenterController dismissAnimated:YES];
            control_gesture_state = wait_for_release;
            return true;
        case wait_for_release:
            if (button) break;
            control_gesture_state = no_touch;
            return true;
    }
    return false;
}


// END NOTIFICATION CENTER CODE

#ifndef __LP64__

#define QuartzCore "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"
// NOTE: The mouse pointer image interferes with hit tests as the pointer
//       covers the point being clicked. To work around this, make hit tests
//       on the render context of the mouse pointer always return NULL;

// CA::Render::Context::hit_test(CGPoint, unsigned int) 
MSHook(void *, _ZN2CA6Render7Context8hit_testE7CGPointj, Context *context, CGPoint point, unsigned int unknown)
{
    return (context == mouseRenderContext) ? NULL : __ZN2CA6Render7Context8hit_testE7CGPointj(context, point, unknown);
}
// CA::Render::Context::hit_test(CA::Vec2<float> const&, unsigned int)
MSHook(void *, _ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj, Context *context, void * point, unsigned int unknown)
{
    return (context == mouseRenderContext) ? NULL : __ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj(context, point, unknown);
}
#endif

//
// Lock/Dim management - handled by hid-support before iOS 6
// -- hid-support is in backboardd from iOS 6 on, so it cannot handle lock/dimming
// -- we do it here in lack of a better / not complex solution to this

static bool isLocked() {
    // pre iOS 7:
    if (%c(SBAwayController)){
        return [[%c(SBAwayController) sharedAwayController] isLocked];
    }        
    if (%c(SBLockScreenManager)){
        // request device unlock, if locked
        SBLockScreenManager * sbLockScreenManager = (SBLockScreenManager*) [%c(SBLockScreenManager) sharedInstance];
        return [sbLockScreenManager isUILocked];
    }
    return NO;
}

static void undimDisplay(){
    // pre iOS 7:
    if (%c(SBAwayController)){
        // prevent dimming - from BTstack Keyboard
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] resetIdleTimerAndUndim:YES];
    }
    if (%c(SBLockScreenManager)){
        // turn on screen (nop if already on)
        SBUserAgent * sbUserAget = [%c(SBUserAgent) sharedUserAgent];
        [sbUserAget undimScreen];

        // and prevent dimming
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] resetIdleTimerAndUndim];
    }
}

static void unlockDevice(){
    // pre iOS 7:
    if (%c(SBAwayController)){
        // from BTstack Keyboard                    
        bool wasDimmed = [[%c(SBAwayController) sharedAwayController] isDimmed ];
        bool wasLocked = [[%c(SBAwayController) sharedAwayController] isLocked ];
        
        // handle user unlock
        if ( wasDimmed || wasLocked ){
            [[%c(SBAwayController) sharedAwayController] attemptUnlock];
            [[%c(SBAwayController) sharedAwayController] unlockWithSound:NO];
        }
    }
    if (%c(SBLockScreenManager)){
        // request device unlock, if locked
        SBLockScreenManager * sbLockScreenManager = (SBLockScreenManager*) [%c(SBLockScreenManager) sharedInstance];
        if ([sbLockScreenManager isUILocked]){
            [sbLockScreenManager unlockUIFromSource:0 withOptions:nil];
        }
    }
}

%hook SpringBoard

%new(v@:c)
- (void)setMousePointerEnabled:(BOOL)enabled
{
    static int pointerRefCount = 0;

    // update ref count
    if (enabled) {
        pointerRefCount++;
    } else if (pointerRefCount > 0){
        pointerRefCount--;
    }

    if (pointerRefCount) {
        if (mouseWin) return;
        // Create a transparent window that will float above everything else
        // NOTE: The window level value was not chosen scientifically; it is
        //       assumed to be large enough (the largest values used by
        //       SpringBoard seen so far have been less than 2000).
        mouseWin = [[UIWindow alloc] initWithFrame:CGRectZero];
        mouseWin.windowLevel = 5001;    // CallBar uses 5000

        [mouseWin setUserInteractionEnabled:NO];
        [mouseWin setHidden:NO];

        if ([mouseWin respondsToSelector:@selector(_setSecure:)]){
            NSLog(@"Set Secure to YES");
            [mouseWin _setSecure:YES];
        }

        // Create a mouse pointer and add to the window
        mouseView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"MousePointer.png"]];
        mouseImageSize = mouseView.bounds.size;
        // NSLog(@"image size %f,%f", mouseImageSize.width, mouseImageSize.height);
        
        [mouseWin addSubview:mouseView];
        
        // Set the initial orientation and limits for the pointer
        updateOrientation();

        if (cloakingSupport) {
            // Store the address of the window's render context to cloak it from clicks
            CAContextImpl *&_layerContext = MSHookIvar<CAContextImpl *>(mouseWin, "_layerContext");
            if (_layerContext != NULL)
                mouseRenderContext = [_layerContext renderContext];
        }
    } else {
        mouseRenderContext = NULL;
        [mouseView release];
        mouseView = nil;
        [mouseWin release];
        mouseWin = nil;
    }
}

// handles size of mouse pointer
%new(v@:{CGPoint=ff})
-(void)moveMousePointerToPoint:(CGPoint)point
{
    currentMouseLocation = point;

    // NSLog(@"moveMousePointerToPoint %f/%f orientation %u, cloakingSupport", point.x, point.y, orientation_, cloakingSupport);

    // Get pos of on-screen pointer
    CGPoint mousePoint;
    switch(orientation_){
        default:
        case 0:
            mousePoint.x = point.x;
            mousePoint.y = point.y;
            if (!cloakingSupport){
                mousePoint.x += 1;
                mousePoint.y += 1;
            }
            break;
        case 90:
            mousePoint.x = point.x - mouseImageSize.height;
            mousePoint.y = point.y;
            break;
        case 180:
            mousePoint.x = point.x - mouseImageSize.width;
            mousePoint.y = point.y - mouseImageSize.height;
            break;
        case -90: // Home button left
        case 270: 
            mousePoint.x = point.x;
            mousePoint.y = point.y - mouseImageSize.width;
            break;
    }
    mouseView.origin = mousePoint;
}

%new({CGPoint=ff}@:)
- (CGPoint)mouseLocation{
    return currentMouseLocation;
}

// @deprecated: use hid_inject_gseventrecord directly
%new(v@:^v)
-(void)sendCustomMouseEvent:(void *) event{
    // NSLog(@"sendCustomMouseEvent");
    hid_inject_gseventrecord((uint8_t*)event);
}

%new(v@:{CGPoint=ff}i)
- (void)handleMouseEventAtPoint:(CGPoint)point buttons:(int)buttons
{
    // NSLog(@"handleMouseEventAtPoint %f/%f, buttons %u (click %u, home %u)", point.x, point.y, buttons, buttonClick, buttonHome);

    // NOTE: Must store button state for comparision, port for
    //       mouse dragging and button up
    static int buttons_;

    int diff = buttons_ ^ buttons;
    bool twas((buttons_ & buttonClick) != 0);
    bool tis ((buttons  & buttonClick) != 0);
    buttons_ = buttons;

    // Round point values to prevent subpixel coordinates
    point.x = roundf(point.x);
    point.y = roundf(point.y);

    // Get pos of on-screen pointer
    [self moveMousePointerToPoint:point];

    // unlock/undim if needed on iOS 6 and higher
    if (is_60_or_higher) {
        if (isLocked()){
            if (diff){
                unlockDevice();
                undimDisplay();
            }
        } else {
            undimDisplay();
        }
    }

    // Check for mouse button events
    if ((diff & 0x10) != 0) {
        // Simulate Headset button press
        struct GSEventRecord record;
        memset(&record, 0, sizeof(record));
        record.timestamp = GSCurrentEventTimestamp();
        record.type = (buttons & 0x10) != 0 ? kGSEventHeadsetButtonDown : kGSEventHeadsetButtonUp;
        GSSendSystemEvent(&record);
    }

    if ((diff & buttonHome) != 0) {
        if (buttons & buttonHome){
            hid_inject_button_down(HWButtonHome);
         } else {
            hid_inject_button_up(HWButtonHome);
        }
    }

    if ((diff & buttonLock) != 0) {
        if (buttons & buttonLock){
            hid_inject_button_down(HWButtonLock);
         } else {
            hid_inject_button_up(HWButtonLock);
        }
    }
    
    if (twas != tis || tis) {
        // support notification center
        BOOL done = handleNotificationCenterGestures(point, tis);
        if (done) return;
        done = handleControlCenterGestures(point, tis);
        if (done) return;

        // forward all apps to SpringBoard while app switcher is showing
        SBUIController * controller = [%c(SBUIController) sharedInstance];
        if ([controller respondsToSelector:@selector(isSwitcherShowing)]){
            if ([controller isSwitcherShowing]){
                postMouseEventToSpringBoard(point.x, point.y, buttons & 1);
                return;
            }
        }
        hid_inject_mouse_abs_move(buttons & buttonClick ? 1 : 0, point.x, point.y);
    }
}



// NOTE: Values of x and y are relative to the previous value, not absolute
%new({CGPoint=ff}@:{CGPoint=ff}i)
- (CGPoint)handleMouseEventWithX:(float)x Y:(float)y buttons:(int)buttons
{
    x *= mouseSpeed;
    y *= mouseSpeed;

    CGPoint point = [self mouseLocation];

    switch (orientation_) {
        case 0: // Home button bottom
            point.x += x;
            point.y += y;
            break;
        case 90: // Home button right
            point.x -= y;
            point.y += x;
            break;
        case -90: // Home button left
            point.x += y;
            point.y -= x;
            break;
        case 180: // Home button top
            point.x -= x;
            point.y -= y;
            break;
        default:
            break;
    }

    CGPoint outer = { 0,0 };

    if (point.x < 0) {
        outer.x = point.x;
        point.x = 0;
    }
    if (point.x > screen_width) {
        outer.x = point.x - screen_width;
        point.x = screen_width;
    }
    if (point.y < 0) {
        outer.y = point.y;
        point.y = 0;
    }
    if (point.y > screen_height) {
        outer.y = point.y - screen_height;
        point.y = screen_height;
    }

    [self handleMouseEventAtPoint:point buttons:buttons];

    return outer;
}

%new
-(void)mouseHandleOrientationChange:(int)orientation{
    // Update pointer orientation
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown:
            orientation_ = 180;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            orientation_ = -90;
            break;
        case UIInterfaceOrientationLandscapeRight:
            orientation_ = 90;
            break;
        case UIInterfaceOrientationPortrait:
        default:
            orientation_ = 0;
    }
    updateOrientation();
    [self moveMousePointerToPoint:currentMouseLocation];
}


- (void)applicationDidFinishLaunching:(UIApplication *)application
{
    %orig;

    // Apply settings
    // FIXME: Read from preferences
    loadPreferences();

    // Add observer for changes made to preferences
    CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, reloadPreferences, CFSTR(APP_ID"-settings"),
            NULL, 0);

    // Setup a mach port for receiving mouse events from outside of SpringBoard
    // NOTE: Using kCFRunLoopDefaultMode causes issues when dragging SpringBoard's
    //       scrollview; why kCFRunLoopCommonModes fixes the issue, I do not know.
    CFMessagePortRef local = CFMessagePortCreateLocal(NULL, CFSTR(MACH_PORT_NAME), mouseCallBack, NULL, NULL);
    try_rocketbootstrap_cfmessageportexposelocal(local);

    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, local, 0);
    //CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);

    // Get initial screen size
    dlset($GSMainScreenSize, "GSMainScreenSize");
    dlset($GSMainScreenScaleFactor, "GSMainScreenScaleFactor");
    dlset($GSMainScreenOrientation, "GSMainScreenOrientation");

    if ($GSMainScreenScaleFactor) {
        retina_factor = $GSMainScreenScaleFactor();
    }
    if ($GSMainScreenSize){
        CGSize screenSize = $GSMainScreenSize();
        screen_width = screenSize.width / retina_factor;
        screen_height = screenSize.height / retina_factor;
    }
    
    // iPad has rotated framebuffer
    if ([[UIDevice currentDevice] respondsToSelector:@selector(userInterfaceIdiom)]){
        is_iPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
    }

    NSLog(@"MouseSupport: screen size: %f x %f, retina %f, is_iPad %u", screen_width, screen_height, retina_factor, is_iPad);
}

%end

//==============================================================================

%group GFirmware3x
// NOTE: Only hooked for firmware < 3.2
%hook SpringBoard
- (void)noteUIOrientationChanged:(int)orientation display:(id)display
{
    %orig;

    // Update pointer orientation
    orientation_ = orientation;

    updateOrientation();
    [self moveMousePointerToPoint:currentMouseLocation];
}
%end 
%end // GFirmware3x

%group GFirmware32x
// NOTE: Only hooked for firmware >= 3.2
%hook SpringBoard
-(void)frontDisplayDidChange{
    %orig;
    [self mouseHandleOrientationChange:[self activeInterfaceOrientation]];
}

- (void)noteInterfaceOrientationChanged:(int)orientation
{
    %orig;
    [self mouseHandleOrientationChange:orientation];
}
%end // GFirmware32x
%end // GFirmware32x

%group GFirmware6x
%hook SpringBoard
-(void)noteInterfaceOrientationChanged:(int)orientation duration:(double)duration{
    %orig;
    [self mouseHandleOrientationChange:orientation];
}
%end
%end

static void orientationUpdateListener(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SpringBoard *springBoard = (SpringBoard *)[UIApplication sharedApplication];
    [springBoard mouseHandleOrientationChange:[springBoard activeInterfaceOrientation]];
}
//==============================================================================

%ctor {

    Class $SpringBoard = objc_getClass("SpringBoard");
    if (class_getInstanceMethod($SpringBoard, @selector(noteInterfaceOrientationChanged:))) {
        // Firmware >= 3.2
        %init(GFirmware32x);
    } else {
        // Firmware < 3.2
        %init(GFirmware3x);
    }

    // GraphicsServices used
    MyMSHookSymbol(GSTakePurpleSystemEventPort, "GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MyMSHookSymbol(GSTakePurpleSystemEventPort, "GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }

    if (dlsym(RTLD_DEFAULT, "GSLibraryCopyGenerationInfoValueForKey")){
        is_50_or_higher = YES;
    }

    if (dlsym(RTLD_DEFAULT, "GSGetPurpleWorkspacePort")){
        is_60_or_higher = YES;
        %init(GFirmware6x);

        // register for orientation events on iOS 6
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            orientationUpdateListener,
            CFSTR("com.apple.backboardd.orientation"),
            NULL,
            0);
    }

#ifndef __LP64__
    // only makes sense before iOS 6 - later, CARenderServer is part of backboardd now
    if (!is_60_or_higher){
        void * (*_ZN2CA6Render7Context8hit_testE7CGPointj)(Context *, CGPoint, unsigned int);
        lookupSymbol(QuartzCore, "__ZN2CA6Render7Context8hit_testE7CGPointj", _ZN2CA6Render7Context8hit_testE7CGPointj);
        if (_ZN2CA6Render7Context8hit_testE7CGPointj) {
            MSHookFunction(_ZN2CA6Render7Context8hit_testE7CGPointj, MSHake(_ZN2CA6Render7Context8hit_testE7CGPointj));
            cloakingSupport = YES;
        }
        
        void * (*_ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj)(Context *, void *, unsigned int);
        lookupSymbol(QuartzCore, "__ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj", _ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj);
        if (!cloakingSupport && _ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj) {
            MSHookFunction(_ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj, MSHake(_ZN2CA6Render7Context8hit_testERKNS_4Vec2IfEEj));
            cloakingSupport = YES;
        }
    }
#endif

    // NSLog(@"MouseSupport loaded");
    
    %init;
}

/* vim: set filetype=objcpp sw=4 ts=4 sts=4 expandtab textwidth=80 ff=unix: */
