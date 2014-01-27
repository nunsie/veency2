/* Veency - VNC Remote Access Server for iPhoneOS
 * Copyright (C) 2008-2012  Jay Freeman (saurik)
*/

/* GNU Affero General Public License, Version 3 {{{ */
/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.

 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#define _trace() \
    fprintf(stderr, "_trace()@%s:%u[%s]\n", __FILE__, __LINE__, __FUNCTION__)
#define _likely(expr) \
    __builtin_expect(expr, 1)
#define _unlikely(expr) \
    __builtin_expect(expr, 0)

#include <substrate.h>

#include <rfb/rfb.h>
#include <rfb/keysym.h>

#include <mach/mach.h>
#include <mach/mach_time.h>

#include <sys/mman.h>
#include <sys/sysctl.h>

#undef assert

#include <CoreFoundation/CFUserNotification.h>
#import <CoreGraphics/CGGeometry.h>
#import <GraphicsServices/GraphicsServices.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <IOKit/hid/IOHIDEventTypes.h>
#include <IOKit/hidsystem/IOHIDUsageTables.h>

extern "C" {
#include "SpringBoardAccess.h"
}

MSClassHook(UIApplication)

@interface UIApplication (Apple)
- (void) addStatusBarImageNamed:(NSString *)name;
- (void) removeStatusBarImageNamed:(NSString *)name;
@end

@interface CAWindowServerDisplay : NSObject
- (mach_port_t) clientPortAtPosition:(CGPoint)position;
@end

@interface CAWindowServer : NSObject
+ (CAWindowServer *) serverIfRunning;
- (NSArray *) displays;
@end

@interface UIModalView : UIView
- (id) addButtonWithTitle:(NSString *)title;
- (void) setBodyText:(NSString *)text;
- (void) setDelegate:(id)delegate;
- (void) setTitle:(NSString *)title;
@end

@interface SBAlertItem : NSObject
- (void) dismiss;
- (UIModalView *) alertSheet;
@end

@interface SBAlertItemsController : NSObject
+ (SBAlertItemsController *) sharedInstance;
- (void) activateAlertItem:(SBAlertItem *)item;
@end

@interface SBStatusBarController : NSObject
+ (SBStatusBarController *) sharedStatusBarController;
- (void) addStatusBarItem:(NSString *)item;
- (void) removeStatusBarItem:(NSString *)item;
@end

typedef void *CoreSurfaceBufferRef;

extern CFStringRef kCoreSurfaceBufferGlobal;
extern CFStringRef kCoreSurfaceBufferMemoryRegion;
extern CFStringRef kCoreSurfaceBufferPitch;
extern CFStringRef kCoreSurfaceBufferWidth;
extern CFStringRef kCoreSurfaceBufferHeight;
extern CFStringRef kCoreSurfaceBufferPixelFormat;
extern CFStringRef kCoreSurfaceBufferAllocSize;

extern "C" CoreSurfaceBufferRef CoreSurfaceBufferCreate(CFDictionaryRef dict);
extern "C" int CoreSurfaceBufferLock(CoreSurfaceBufferRef surface, unsigned int lockType);
extern "C" int CoreSurfaceBufferUnlock(CoreSurfaceBufferRef surface);
extern "C" void *CoreSurfaceBufferGetBaseAddress(CoreSurfaceBufferRef surface);

extern "C" void CoreSurfaceBufferFlushProcessorCaches(CoreSurfaceBufferRef buffer);

typedef void *CoreSurfaceAcceleratorRef;

extern "C" int CoreSurfaceAcceleratorCreate(CFAllocatorRef allocator, void *type, CoreSurfaceAcceleratorRef *accel);
extern "C" unsigned int CoreSurfaceAcceleratorTransferSurface(CoreSurfaceAcceleratorRef accelerator, CoreSurfaceBufferRef dest, CoreSurfaceBufferRef src, CFDictionaryRef options/*, void *, void *, void **/);

typedef void *IOMobileFramebufferRef;

extern "C" kern_return_t IOMobileFramebufferSwapSetLayer(
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
);

extern "C" void IOMobileFramebufferGetDisplaySize(IOMobileFramebufferRef connect, CGSize *size);
extern "C" void IOMobileFramebufferIsMainDisplay(IOMobileFramebufferRef connect, int *main);

typedef CFTypeRef IOHIDEventRef;
typedef CFTypeRef IOHIDEventSystemClientRef;

extern "C" {
    IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef allocator, uint64_t time, uint16_t page, uint16_t usage, Boolean down, IOHIDEventOptionBits flags);
    IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
    void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t sender);
    void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
}

static size_t width_;
static size_t height_;
static NSUInteger ratio_ = 0;

static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static CoreSurfaceAcceleratorRef accelerator_;
static CoreSurfaceBufferRef buffer_;
static CFDictionaryRef options_;

static NSMutableSet *handlers_;
static rfbScreenInfoPtr screen_;
static bool running_;
static int buttons_;
static int x_, y_;

static unsigned clients_;

static CFMessagePortRef ashikase_;
static bool cursor_;

static rfbPixel *black_;

static void VNCBlack() {
    if (_unlikely(black_ == NULL))
        black_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
    screen_->frameBuffer = reinterpret_cast<char *>(black_);
}

static bool Ashikase(bool always) {
    if (!always && !cursor_)
        return false;

    if (ashikase_ == NULL)
        ashikase_ = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("jp.ashikase.mousesupport"));
    if (ashikase_ != NULL)
        return true;

    cursor_ = false;
    return false;
}

static CFDataRef cfTrue_;
static CFDataRef cfFalse_;

typedef struct {
    float x, y;
    int buttons;
    BOOL absolute;
} MouseEvent;

static MouseEvent event_;
static CFDataRef cfEvent_;

typedef enum {
    MouseMessageTypeEvent,
    MouseMessageTypeSetEnabled
} MouseMessageType;

static void AshikaseSendEvent(float x, float y, int buttons = 0) {
    event_.x = x;
    event_.y = y;
    event_.buttons = buttons;
    event_.absolute = true;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeEvent, cfEvent_, 0, 0, NULL, NULL);
}

static void AshikaseSetEnabled(bool enabled, bool always) {
    if (!Ashikase(always))
        return;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeSetEnabled, enabled ? cfTrue_ : cfFalse_, 0, 0, NULL, NULL);

    if (enabled)
        AshikaseSendEvent(x_, y_);
}

MSClassHook(SBAlertItem)
MSClassHook(SBAlertItemsController)
MSClassHook(SBStatusBarController)

@interface VNCAlertItem : SBAlertItem
@end

static Class $VNCAlertItem;

static NSString *DialogTitle(@"Remote Access Request");
static NSString *DialogFormat(@"Accept connection from\n%s?\n\nVeency VNC Server\nby Jay Freeman (saurik)\nsaurik@saurik.com\nhttp://www.saurik.com/\n\nSet a VNC password in Settings!");
static NSString *DialogAccept(@"Accept");
static NSString *DialogReject(@"Reject");

static volatile rfbNewClientAction action_ = RFB_CLIENT_ON_HOLD;
static NSCondition *condition_;
static NSLock *lock_;

static rfbClientPtr client_;

static void VNCSetup();
static void VNCEnabled();

float (*$GSMainScreenScaleFactor)();

static void OnUserNotification(CFUserNotificationRef notification, CFOptionFlags flags) {
    [condition_ lock];

    if ((flags & 0x3) == 1)
        action_ = RFB_CLIENT_ACCEPT;
    else
        action_ = RFB_CLIENT_REFUSE;

    [condition_ signal];
    [condition_ unlock];

    CFRelease(notification);
}

@interface VNCBridge : NSObject {
}

+ (void) askForConnection;
+ (void) removeStatusBarItem;
+ (void) registerClient;

@end

@implementation VNCBridge

+ (void) askForConnection {
    if ($VNCAlertItem != nil) {
        [[$SBAlertItemsController sharedInstance] activateAlertItem:[[[$VNCAlertItem alloc] init] autorelease]];
        return;
    }

    SInt32 error;
    CFUserNotificationRef notification(CFUserNotificationCreate(kCFAllocatorDefault, 0, kCFUserNotificationPlainAlertLevel, &error, (CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
        DialogTitle, kCFUserNotificationAlertHeaderKey,
        [NSString stringWithFormat:DialogFormat, client_->host], kCFUserNotificationAlertMessageKey,
        DialogAccept, kCFUserNotificationAlternateButtonTitleKey,
        DialogReject, kCFUserNotificationDefaultButtonTitleKey,
    nil]));

    if (error != 0) {
        CFRelease(notification);
        notification = NULL;
    }

    if (notification == NULL) {
        [condition_ lock];
        action_ = RFB_CLIENT_REFUSE;
        [condition_ signal];
        [condition_ unlock];
        return;
    }

    CFRunLoopSourceRef source(CFUserNotificationCreateRunLoopSource(kCFAllocatorDefault, notification, &OnUserNotification, 0));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
}

+ (void) removeStatusBarItem {
    AshikaseSetEnabled(false, false);

    if (SBA_available())
        SBA_removeStatusBarImage(const_cast<char *>("Veency"));
    else if ($SBStatusBarController != nil)
        [[$SBStatusBarController sharedStatusBarController] removeStatusBarItem:@"Veency"];
    else if (UIApplication *app = [$UIApplication sharedApplication])
        [app removeStatusBarImageNamed:@"Veency"];
}

+ (void) registerClient {
    // XXX: this could find a better home
    if (ratio_ == 0) {
        if ($GSMainScreenScaleFactor == NULL)
            ratio_ = 1.0f;
        else
            ratio_ = $GSMainScreenScaleFactor();
    }

    ++clients_;
    AshikaseSetEnabled(true, false);

    if (SBA_available())
        SBA_addStatusBarImage(const_cast<char *>("Veency"));
    else if ($SBStatusBarController != nil)
        [[$SBStatusBarController sharedStatusBarController] addStatusBarItem:@"Veency"];
    else if (UIApplication *app = [$UIApplication sharedApplication])
        [app addStatusBarImageNamed:@"Veency"];
}

+ (void) performSetup:(NSThread *)thread {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
    [thread autorelease];
    VNCSetup();
    VNCEnabled();
    [pool release];
}

@end

MSInstanceMessage2(void, VNCAlertItem, alertSheet,buttonClicked, id, sheet, int, button) {
    [condition_ lock];

    switch (button) {
        case 1:
            action_ = RFB_CLIENT_ACCEPT;

            @synchronized (condition_) {
                [VNCBridge registerClient];
            }
        break;

        case 2:
            action_ = RFB_CLIENT_REFUSE;
        break;
    }

    [condition_ signal];
    [condition_ unlock];
    [self dismiss];
}

MSInstanceMessage2(void, VNCAlertItem, configure,requirePasscodeForActions, BOOL, configure, BOOL, require) {
    UIModalView *sheet([self alertSheet]);
    [sheet setDelegate:self];
    [sheet setTitle:DialogTitle];
    [sheet setBodyText:[NSString stringWithFormat:DialogFormat, client_->host]];
    [sheet addButtonWithTitle:DialogAccept];
    [sheet addButtonWithTitle:DialogReject];
}

MSInstanceMessage0(void, VNCAlertItem, performUnlockAction) {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:self];
}

static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static int Level_;

static void FixRecord(GSEventRecord *record) {
    if (Level_ < 1)
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->size);
}

static void VNCSettings() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    @synchronized (lock_) {
        for (NSValue *handler in handlers_)
            rfbUnregisterSecurityHandler(reinterpret_cast<rfbSecurityHandler *>([handler pointerValue]));
        [handlers_ removeAllObjects];
    }

    @synchronized (condition_) {
        if (screen_ == NULL)
            return;

        [reinterpret_cast<NSString *>(screen_->authPasswdData) release];
        screen_->authPasswdData = NULL;

        if (settings != nil)
            if (NSString *password = [settings objectForKey:@"Password"])
                if ([password length] != 0)
                    screen_->authPasswdData = [password retain];

        NSNumber *cursor = [settings objectForKey:@"ShowCursor"];
        cursor_ = cursor == nil ? true : [cursor boolValue];

        if (clients_ != 0)
            AshikaseSetEnabled(cursor_, true);
    }
}

static void VNCNotifySettings(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCSettings();
}

static rfbBool VNCCheck(rfbClientPtr client, const char *data, int size) {
    @synchronized (condition_) {
        if (NSString *password = reinterpret_cast<NSString *>(screen_->authPasswdData)) {
            NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
            rfbEncryptBytes(client->authChallenge, const_cast<char *>([password UTF8String]));
            bool good(memcmp(client->authChallenge, data, size) == 0);
            [pool release];
            return good;
        } return TRUE;
    }
}

static bool iPad1_;

struct VeencyEvent {
    struct GSEventRecord record;
    struct {
        struct GSEventRecordInfo info;
        struct GSPathInfo path;
    } data;
};

static void VNCPointerOld(int buttons, int x, int y, CGPoint location, int diff, bool twas, bool tis);
static void VNCPointerNew(int buttons, int x, int y, CGPoint location, int diff, bool twas, bool tis);

static void VNCPointer(int buttons, int x, int y, rfbClientPtr client) {
    if (ratio_ == 0)
        return;

    CGPoint location = {x, y};

    if (width_ > height_) {
        int t(x);
        x = height_ - 1 - y;
        y = t;

        if (!iPad1_) {
            x = height_ - 1 - x;
            y = width_ - 1 - y;
        }
    }

    x /= ratio_;
    y /= ratio_;

    x_ = x; y_ = y;
    int diff = buttons_ ^ buttons;
    bool twas((buttons_ & 0x1) != 0);
    bool tis((buttons & 0x1) != 0);
    buttons_ = buttons;

    rfbDefaultPtrAddEvent(buttons, x, y, client);

    if (Ashikase(false)) {
        AshikaseSendEvent(x, y, buttons);
        return;
    }

    if (kCFCoreFoundationVersionNumber >= 800)
        return VNCPointerNew(buttons, x, y, location, diff, twas, tis);
    else
        return VNCPointerOld(buttons, x, y, location, diff, twas, tis);
}

static void VNCPointerOld(int buttons, int x, int y, CGPoint location, int diff, bool twas, bool tis) {
    mach_port_t purple(0);

    if ((diff & 0x10) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x10) != 0 ?
            GSEventTypeHeadsetButtonDown :
            GSEventTypeHeadsetButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x04) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x04) != 0 ?
            GSEventTypeMenuButtonDown :
            GSEventTypeMenuButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x02) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x02) != 0 ?
            GSEventTypeLockButtonDown :
            GSEventTypeLockButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if (twas != tis || tis) {
        struct VeencyEvent event;

        memset(&event, 0, sizeof(event));

        event.record.type = GSEventTypeMouse;
        event.record.locationInWindow.x = x;
        event.record.locationInWindow.y = y;
        event.record.timestamp = GSCurrentEventTimestamp();
        event.record.size = sizeof(event.data);

        event.data.info.handInfo.type = twas == tis ?
            GSMouseEventTypeDragged :
        tis ?
            GSMouseEventTypeDown :
            GSMouseEventTypeUp;

        event.data.info.handInfo.x34 = 0x1;
        event.data.info.handInfo.x38 = tis ? 0x1 : 0x0;

        if (Level_ < 3)
            event.data.info.pathPositions = 1;
        else
            event.data.info.x52 = 1;

        event.data.path.x00 = 0x01;
        event.data.path.x01 = 0x02;
        event.data.path.x02 = tis ? 0x03 : 0x00;
        event.data.path.position = event.record.locationInWindow;

        mach_port_t port(0);

        if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
            NSArray *displays([server displays]);
            if (displays != nil && [displays count] != 0)
                if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                    port = [display clientPortAtPosition:location];
        }

        if (port == 0) {
            if (purple == 0)
                purple = (*GSTakePurpleSystemEventPort)();
            port = purple;
        }

        FixRecord(&event.record);
        GSSendEvent(&event.record, port);
    }

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);
}

static void VNCSendHIDEvent(IOHIDEventRef event) {
    static IOHIDEventSystemClientRef client_(NULL);
    if (client_ == NULL)
        client_ = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSetSenderID(event, 0xDEFACEDBEEFFECE5);

    IOHIDEventSystemClientDispatchEvent(client_, event);
    CFRelease(event);
}

static void VNCPointerNew(int buttons, int x, int y, CGPoint location, int diff, bool twas, bool tis) {
    if ((diff & 0x10) != 0)
        VNCSendHIDEvent(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), kHIDPage_Telephony, kHIDUsage_Tfon_Flash, (buttons & 0x10) != 0, 0));
    if ((diff & 0x04) != 0)
        VNCSendHIDEvent(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), kHIDPage_Consumer, kHIDUsage_Csmr_Menu, (buttons & 0x04) != 0, 0));
    if ((diff & 0x02) != 0)
        VNCSendHIDEvent(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), kHIDPage_Consumer, kHIDUsage_Csmr_Power, (buttons & 0x02) != 0, 0));

    if (twas != tis || tis) {
    }
}

GSEventRef (*$GSEventCreateKeyEvent)(int, CGPoint, CFStringRef, CFStringRef, id, UniChar, short, short);
GSEventRef (*$GSCreateSyntheticKeyEvent)(UniChar, BOOL, BOOL);

static void VNCKeyboardNew(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    //NSLog(@"VNC d:%u k:%04x", down, key);

    uint16_t usage;

    switch (key) {
        case XK_exclam: case XK_1: usage = kHIDUsage_Keyboard1; break;
        case XK_at: case XK_2: usage = kHIDUsage_Keyboard2; break;
        case XK_numbersign: case XK_3: usage = kHIDUsage_Keyboard3; break;
        case XK_dollar: case XK_4: usage = kHIDUsage_Keyboard4; break;
        case XK_percent: case XK_5: usage = kHIDUsage_Keyboard5; break;
        case XK_asciicircum: case XK_6: usage = kHIDUsage_Keyboard6; break;
        case XK_ampersand: case XK_7: usage = kHIDUsage_Keyboard7; break;
        case XK_asterisk: case XK_8: usage = kHIDUsage_Keyboard8; break;
        case XK_parenleft: case XK_9: usage = kHIDUsage_Keyboard9; break;
        case XK_parenright: case XK_0: usage = kHIDUsage_Keyboard0; break;

        case XK_A: case XK_a: usage = kHIDUsage_KeyboardA; break;
        case XK_B: case XK_b: usage = kHIDUsage_KeyboardB; break;
        case XK_C: case XK_c: usage = kHIDUsage_KeyboardC; break;
        case XK_D: case XK_d: usage = kHIDUsage_KeyboardD; break;
        case XK_E: case XK_e: usage = kHIDUsage_KeyboardE; break;
        case XK_F: case XK_f: usage = kHIDUsage_KeyboardF; break;
        case XK_G: case XK_g: usage = kHIDUsage_KeyboardG; break;
        case XK_H: case XK_h: usage = kHIDUsage_KeyboardH; break;
        case XK_I: case XK_i: usage = kHIDUsage_KeyboardI; break;
        case XK_J: case XK_j: usage = kHIDUsage_KeyboardJ; break;
        case XK_K: case XK_k: usage = kHIDUsage_KeyboardK; break;
        case XK_L: case XK_l: usage = kHIDUsage_KeyboardL; break;
        case XK_M: case XK_m: usage = kHIDUsage_KeyboardM; break;
        case XK_N: case XK_n: usage = kHIDUsage_KeyboardN; break;
        case XK_O: case XK_o: usage = kHIDUsage_KeyboardO; break;
        case XK_P: case XK_p: usage = kHIDUsage_KeyboardP; break;
        case XK_Q: case XK_q: usage = kHIDUsage_KeyboardQ; break;
        case XK_R: case XK_r: usage = kHIDUsage_KeyboardR; break;
        case XK_S: case XK_s: usage = kHIDUsage_KeyboardS; break;
        case XK_T: case XK_t: usage = kHIDUsage_KeyboardT; break;
        case XK_U: case XK_u: usage = kHIDUsage_KeyboardU; break;
        case XK_V: case XK_v: usage = kHIDUsage_KeyboardV; break;
        case XK_W: case XK_w: usage = kHIDUsage_KeyboardW; break;
        case XK_X: case XK_x: usage = kHIDUsage_KeyboardX; break;
        case XK_Y: case XK_y: usage = kHIDUsage_KeyboardY; break;
        case XK_Z: case XK_z: usage = kHIDUsage_KeyboardZ; break;

        case XK_underscore: case XK_minus: usage = kHIDUsage_KeyboardHyphen; break;
        case XK_plus: case XK_equal: usage = kHIDUsage_KeyboardEqualSign; break;
        case XK_braceleft: case XK_bracketleft: usage = kHIDUsage_KeyboardOpenBracket; break;
        case XK_braceright: case XK_bracketright: usage = kHIDUsage_KeyboardCloseBracket; break;
        case XK_bar: case XK_backslash: usage = kHIDUsage_KeyboardBackslash; break;
        case XK_colon: case XK_semicolon: usage = kHIDUsage_KeyboardSemicolon; break;
        case XK_quotedbl: case XK_apostrophe: usage = kHIDUsage_KeyboardQuote; break;
        case XK_asciitilde: case XK_grave: usage = kHIDUsage_KeyboardGraveAccentAndTilde; break;
        case XK_less: case XK_comma: usage = kHIDUsage_KeyboardComma; break;
        case XK_greater: case XK_period: usage = kHIDUsage_KeyboardPeriod; break;
        case XK_question: case XK_slash: usage = kHIDUsage_KeyboardSlash; break;

        case XK_Return: usage = kHIDUsage_KeyboardReturnOrEnter; break;
        case XK_BackSpace: usage = kHIDUsage_KeyboardDeleteOrBackspace; break;
        case XK_Tab: usage = kHIDUsage_KeyboardTab; break;
        case XK_space: usage = kHIDUsage_KeyboardSpacebar; break;

        case XK_Shift_L: usage = kHIDUsage_KeyboardLeftShift; break;
        case XK_Shift_R: usage = kHIDUsage_KeyboardRightShift; break;
        case XK_Control_L: usage = kHIDUsage_KeyboardLeftControl; break;
        case XK_Control_R: usage = kHIDUsage_KeyboardRightControl; break;
        case XK_Meta_L: usage = kHIDUsage_KeyboardLeftAlt; break;
        case XK_Meta_R: usage = kHIDUsage_KeyboardRightAlt; break;
        case XK_Alt_L: usage = kHIDUsage_KeyboardLeftGUI; break;
        case XK_Alt_R: usage = kHIDUsage_KeyboardRightGUI; break;

        case XK_Up: usage = kHIDUsage_KeyboardUpArrow; break;
        case XK_Down: usage = kHIDUsage_KeyboardDownArrow; break;
        case XK_Left: usage = kHIDUsage_KeyboardLeftArrow; break;
        case XK_Right: usage = kHIDUsage_KeyboardRightArrow; break;

        case XK_Home: case XK_Begin: usage = kHIDUsage_KeyboardHome; break;
        case XK_End: usage = kHIDUsage_KeyboardEnd; break;
        case XK_Page_Up: usage = kHIDUsage_KeyboardPageUp; break;
        case XK_Page_Down: usage = kHIDUsage_KeyboardPageDown; break;

        default: return;
    }

    VNCSendHIDEvent(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), kHIDPage_KeyboardOrKeypad, usage, down, 0));
}

static void VNCKeyboard(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    if (kCFCoreFoundationVersionNumber >= 800)
        return VNCKeyboardNew(down, key, client);

    if (!down)
        return;

    switch (key) {
        case XK_Return: key = '\r'; break;
        case XK_BackSpace: key = 0x7f; break;
    }

    if (key > 0xfff)
        return;

    CGPoint point(CGPointMake(x_, y_));

    UniChar unicode(key);
    CFStringRef string(NULL);

    GSEventRef event0, event1(NULL);
    if ($GSEventCreateKeyEvent != NULL) {
        string = CFStringCreateWithCharacters(kCFAllocatorDefault, &unicode, 1);
        event0 = (*$GSEventCreateKeyEvent)(10, point, string, string, nil, 0, 0, 1);
        event1 = (*$GSEventCreateKeyEvent)(11, point, string, string, nil, 0, 0, 1);
    } else if ($GSCreateSyntheticKeyEvent != NULL) {
        event0 = (*$GSCreateSyntheticKeyEvent)(unicode, YES, YES);
        GSEventRecord *record(_GSEventGetGSEventRecord(event0));
        record->type = GSEventTypeKeyDown;
    } else return;

    mach_port_t port(0);

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0)
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                port = [display clientPortAtPosition:point];
    }

    mach_port_t purple(0);

    if (port == 0) {
        if (purple == 0)
            purple = (*GSTakePurpleSystemEventPort)();
        port = purple;
    }

    if (port != 0) {
        GSSendEvent(_GSEventGetGSEventRecord(event0), port);
        if (event1 != NULL)
            GSSendEvent(_GSEventGetGSEventRecord(event1), port);
    }

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);

    CFRelease(event0);
    if (event1 != NULL)
        CFRelease(event1);
    if (string != NULL)
        CFRelease(string);
}

static void VNCDisconnect(rfbClientPtr client) {
    @synchronized (condition_) {
        if (--clients_ == 0)
            [VNCBridge performSelectorOnMainThread:@selector(removeStatusBarItem) withObject:nil waitUntilDone:YES];
    }
}

static rfbNewClientAction VNCClient(rfbClientPtr client) {
    @synchronized (condition_) {
        if (screen_->authPasswdData != NULL) {
            [VNCBridge performSelectorOnMainThread:@selector(registerClient) withObject:nil waitUntilDone:YES];
            client->clientGoneHook = &VNCDisconnect;
            return RFB_CLIENT_ACCEPT;
        }
    }

    [condition_ lock];
    client_ = client;
    [VNCBridge performSelectorOnMainThread:@selector(askForConnection) withObject:nil waitUntilDone:NO];
    while (action_ == RFB_CLIENT_ON_HOLD)
        [condition_ wait];
    rfbNewClientAction action(action_);
    action_ = RFB_CLIENT_ON_HOLD;
    [condition_ unlock];

    if (action == RFB_CLIENT_ACCEPT)
        client->clientGoneHook = &VNCDisconnect;
    return action;
}

extern "C" bool GSSystemHasCapability(NSString *);

static CFTypeRef (*$GSSystemCopyCapability)(CFStringRef);
static CFTypeRef (*$GSSystemGetCapability)(CFStringRef);
static BOOL (*$MGGetBoolAnswer)(CFStringRef);

static void VNCSetup() {
    rfbLogEnable(false);

    @synchronized (condition_) {
        int argc(1);
        char *arg0(strdup("VNCServer"));
        char *argv[] = {arg0, NULL};
        screen_ = rfbGetScreen(&argc, argv, width_, height_, BitsPerSample, 3, BytesPerPixel);
        free(arg0);

        VNCSettings();
    }

    screen_->desktopName = strdup([[[NSProcessInfo processInfo] hostName] UTF8String]);

    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 1000 / 25;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    $GSSystemCopyCapability = reinterpret_cast<CFTypeRef (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "GSSystemCopyCapability"));
    $GSSystemGetCapability = reinterpret_cast<CFTypeRef (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "GSSystemGetCapability"));
    $MGGetBoolAnswer = reinterpret_cast<BOOL (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "MGGetBoolAnswer"));

    CFTypeRef opengles2;

    if ($GSSystemCopyCapability != NULL) {
        opengles2 = (*$GSSystemCopyCapability)(CFSTR("opengles-2"));
    } else if ($GSSystemGetCapability != NULL) {
        opengles2 = (*$GSSystemGetCapability)(CFSTR("opengles-2"));
        if (opengles2 != NULL)
            CFRetain(opengles2);
    } else if ($MGGetBoolAnswer != NULL) {
        opengles2 = $MGGetBoolAnswer(CFSTR("opengles-2")) ? kCFBooleanTrue : kCFBooleanFalse;
        CFRetain(opengles2);
    } else
        opengles2 = NULL;

    bool accelerated(opengles2 != NULL && [(NSNumber *)opengles2 boolValue]);

    if (accelerated)
        CoreSurfaceAcceleratorCreate(NULL, NULL, &accelerator_);

    if (opengles2 != NULL)
        CFRelease(opengles2);

    if (accelerator_ != NULL)
        buffer_ = CoreSurfaceBufferCreate((CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
            @"PurpleEDRAM", kCoreSurfaceBufferMemoryRegion,
            [NSNumber numberWithBool:YES], kCoreSurfaceBufferGlobal,
            [NSNumber numberWithInt:(width_ * BytesPerPixel)], kCoreSurfaceBufferPitch,
            [NSNumber numberWithInt:width_], kCoreSurfaceBufferWidth,
            [NSNumber numberWithInt:height_], kCoreSurfaceBufferHeight,
            [NSNumber numberWithInt:'BGRA'], kCoreSurfaceBufferPixelFormat,
            [NSNumber numberWithInt:(width_ * height_ * BytesPerPixel)], kCoreSurfaceBufferAllocSize,
        nil]);
    else
        VNCBlack();

    //screen_->frameBuffer = reinterpret_cast<char *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));

    CoreSurfaceBufferLock(buffer_, 3);
    screen_->frameBuffer = reinterpret_cast<char *>(CoreSurfaceBufferGetBaseAddress(buffer_));
    CoreSurfaceBufferUnlock(buffer_);

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    screen_->newClientHook = &VNCClient;
    screen_->passwordCheck = &VNCCheck;

    screen_->cursor = NULL;
}

static void VNCEnabled() {
    if (screen_ == NULL)
        return;

    [lock_ lock];

    bool enabled(true);
    if (NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]])
        if (NSNumber *number = [settings objectForKey:@"Enabled"])
            enabled = [number boolValue];

    if (enabled != running_)
        if (enabled) {
            running_ = true;
            screen_->socketState = RFB_SOCKET_INIT;
            rfbInitServer(screen_);
            rfbRunEventLoop(screen_, -1, true);
        } else {
            rfbShutdownServer(screen_, true);
            running_ = false;
        }

    [lock_ unlock];
}

static void VNCNotifyEnabled(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCEnabled();
}

void (*$IOMobileFramebufferIsMainDisplay)(IOMobileFramebufferRef, int *);

static IOMobileFramebufferRef main_;
static CoreSurfaceBufferRef layer_;

static void OnLayer(IOMobileFramebufferRef fb, CoreSurfaceBufferRef layer) {
    if (_unlikely(width_ == 0 || height_ == 0)) {
        CGSize size;
        IOMobileFramebufferGetDisplaySize(fb, &size);

        width_ = size.width;
        height_ = size.height;

        if (width_ == 0 || height_ == 0)
            return;

        NSThread *thread([NSThread alloc]);

        [thread
            initWithTarget:[VNCBridge class]
            selector:@selector(performSetup:)
            object:thread
        ];

        [thread start];
    } else if (_unlikely(clients_ != 0)) {
        if (layer == NULL) {
            if (accelerator_ != NULL)
                memset(screen_->frameBuffer, 0, sizeof(rfbPixel) * width_ * height_);
            else
                VNCBlack();
        } else {
            if (accelerator_ != NULL)
                CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);
            else {
                CoreSurfaceBufferLock(layer, 2);
                rfbPixel *data(reinterpret_cast<rfbPixel *>(CoreSurfaceBufferGetBaseAddress(layer)));

                CoreSurfaceBufferFlushProcessorCaches(layer);

                /*rfbPixel corner(data[0]);
                data[0] = 0;
                data[0] = corner;*/

                screen_->frameBuffer = const_cast<char *>(reinterpret_cast<volatile char *>(data));
                CoreSurfaceBufferUnlock(layer);
            }
        }

        rfbMarkRectAsModified(screen_, 0, 0, width_, height_);
    }
}

static bool wait_ = false;

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    int main(false);

    if (_unlikely(buffer == NULL))
        main = fb == main_;
    else if (_unlikely(fb == NULL))
        main = false;
    else if ($IOMobileFramebufferIsMainDisplay == NULL)
        main = true;
    else
        (*$IOMobileFramebufferIsMainDisplay)(fb, &main);

    if (_likely(main)) {
        main_ = fb;
        if (wait_)
            layer_ = buffer;
        else
            OnLayer(fb, buffer);
    }

    return _IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags);
}

// XXX: beg rpetrich for the type of this function
extern "C" void *IOMobileFramebufferSwapWait(IOMobileFramebufferRef, void *, unsigned);

MSHook(void *, IOMobileFramebufferSwapWait, IOMobileFramebufferRef fb, void *arg1, unsigned flags) {
    void *value(_IOMobileFramebufferSwapWait(fb, arg1, flags));
    if (fb == main_)
        OnLayer(fb, layer_);
    return value;
}

MSHook(void, rfbRegisterSecurityHandler, rfbSecurityHandler *handler) {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    @synchronized (lock_) {
        [handlers_ addObject:[NSValue valueWithPointer:handler]];
        _rfbRegisterSecurityHandler(handler);
    }

    [pool release];
}

template <typename Type_>
static void dlset(Type_ &function, const char *name) {
    function = reinterpret_cast<Type_>(dlsym(RTLD_DEFAULT, name));
}

MSInitialize {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    MSHookSymbol(GSTakePurpleSystemEventPort, "_GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MSHookSymbol(GSTakePurpleSystemEventPort, "_GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }

    if (dlsym(RTLD_DEFAULT, "GSLibraryCopyGenerationInfoValueForKey") != NULL)
        Level_ = 3;
    else if (dlsym(RTLD_DEFAULT, "GSKeyboardCreate") != NULL)
        Level_ = 2;
    else if (dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId") != NULL)
        Level_ = 1;
    else
        Level_ = 0;

    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char machine[size];
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    iPad1_ = strcmp(machine, "iPad1,1") == 0;

    dlset($GSMainScreenScaleFactor, "GSMainScreenScaleFactor");
    dlset($GSEventCreateKeyEvent, "GSEventCreateKeyEvent");
    dlset($GSCreateSyntheticKeyEvent, "_GSCreateSyntheticKeyEvent");
    dlset($IOMobileFramebufferIsMainDisplay, "IOMobileFramebufferIsMainDisplay");

    MSHookFunction(&IOMobileFramebufferSwapSetLayer, MSHake(IOMobileFramebufferSwapSetLayer));
    MSHookFunction(&rfbRegisterSecurityHandler, MSHake(rfbRegisterSecurityHandler));

    if (wait_)
        MSHookFunction(&IOMobileFramebufferSwapWait, MSHake(IOMobileFramebufferSwapWait));

    if ($SBAlertItem != nil) {
        $VNCAlertItem = objc_allocateClassPair($SBAlertItem, "VNCAlertItem", 0);
        MSAddMessage2(VNCAlertItem, "v@:@i", alertSheet,buttonClicked);
        MSAddMessage2(VNCAlertItem, "v@:cc", configure,requirePasscodeForActions);
        MSAddMessage0(VNCAlertItem, "v@:", performUnlockAction);
        objc_registerClassPair($VNCAlertItem);
    }

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifyEnabled, CFSTR("com.saurik.Veency-Enabled"), NULL, 0
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifySettings, CFSTR("com.saurik.Veency-Settings"), NULL, 0
    );

    condition_ = [[NSCondition alloc] init];
    lock_ = [[NSLock alloc] init];
    handlers_ = [[NSMutableSet alloc] init];

    bool value;

    value = true;
    cfTrue_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    value = false;
    cfFalse_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    cfEvent_ = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&event_), sizeof(event_), kCFAllocatorNull);

    options_ = (CFDictionaryRef) [[NSDictionary dictionaryWithObjectsAndKeys:
    nil] retain];

    [pool release];
}
