// iOSAutoTouch — click AN TOÀN bên trong app (Telegram), inject in-process.
// KHÔNG dùng IOHID/BackBoard/HID hệ thống (route đó làm hỏng JB) → KHÔNG THỂ BRICK.
// Cách click: hitTest tại toạ độ → kích hoạt phần tử trực tiếp:
//   1) UIControl  → sendActionsForControlEvents:TouchUpInside
//   2) bất kỳ     → accessibilityActivate (cơ chế VoiceOver "chạm 2 lần")
// Cuộn: accessibilityScroll: theo hướng.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>   // arc4random_uniform (jitter nhịp gõ safari.type)
#include <string>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <mach/mach_time.h>   // mach_absolute_time (IAEmitDigit timestamp)
#include <errno.h>

// BackBoardServices: bật màn hình (dlsym, tránh link private framework).
static void IAWakeScreen(void) {
    typedef void (*SetBlankedFn)(int);
    static SetBlankedFn fn = NULL; static int tried = 0;
    if (!tried) {
        tried = 1;
        void *h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        if (h) fn = (SetBlankedFn)dlsym(h, "BKSDisplayServicesSetScreenBlanked");
    }
    if (fn) fn(0);   // 0 = unblank = bật màn
}

// isUILocked của SBLockScreenManager (an toàn nếu selector vắng).
static BOOL IAIsLocked(id mgr) {
    return (mgr && [mgr respondsToSelector:@selector(isUILocked)])
         ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isUILocked)) : NO;
}

// Đánh thức màn TRONG SpringBoard đúng cách: SBBacklightController turnOnScreenFully… để state machine
// của SpringBoard coi máy là "đã sáng" (BKSDisplayServicesSetScreenBlanked chỉ bật panel, SpringBoard vẫn
// tưởng đang ngủ → giữ/khôi phục CoverSheet khoá). Fallback về BKS nếu không có API.
static void IASpringBoardWakeScreen(void) {
    @try {
        Class blc = NSClassFromString(@"SBBacklightController");
        id bl = (blc && [blc respondsToSelector:@selector(sharedInstance)])
              ? [blc performSelector:@selector(sharedInstance)] : nil;
        if (bl) {
            for (NSString *ss in @[@"turnOnScreenFullyWithBacklightSource:",
                                   @"_startTransitionToState:withBacklightSource:",
                                   @"turnOnScreenAtFullBrightnessWithBacklightSource:"]) {
                SEL s = NSSelectorFromString(ss);
                if ([bl respondsToSelector:s]) {
                    ((void (*)(id, SEL, long long))objc_msgSend)(bl, s, 1);   // source=1 (người dùng)
                    break;
                }
            }
        }
    } @catch (__unused NSException *e) {}
    IAWakeScreen();   // BKS unblank — bổ trợ + chạy được ở mọi tiến trình
}

// Ghi dump method list (để chẩn đoán selector đúng qua SSH). An toàn, chỉ ghi file.
static void IADumpUnlockMethods(id mgr) {
    @try {
        NSMutableString *d = [NSMutableString string];
        Class lsm = object_getClass(mgr);
        [d appendString:@"== SBLockScreenManager (instance) ==\n"];
        unsigned int m = 0; Method *ms = class_copyMethodList(lsm, &m);
        for (unsigned i = 0; i < m; i++) [d appendFormat:@"-%s\n", sel_getName(method_getName(ms[i]))];
        free(ms);
        Class blc = NSClassFromString(@"SBBacklightController");
        if (blc) {
            [d appendString:@"\n== SBBacklightController (instance) ==\n"];
            unsigned int m2 = 0; Method *ms2 = class_copyMethodList(blc, &m2);
            for (unsigned i = 0; i < m2; i++) { const char *sn = sel_getName(method_getName(ms2[i]));
                if (strcasestr(sn, "screen") || strcasestr(sn, "backlight") || strcasestr(sn, "turnon")) [d appendFormat:@"-%s\n", sn]; }
            free(ms2);
        }
        [d writeToFile:@"/var/jb/tmp/iaunlock.txt" atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e) {}
}

// Thử 1 selector unlock, trả YES nếu (sau khi gọi + chờ ngắn) máy đã mở khoá.
static BOOL IATryUnlockSel(id mgr, NSString *selName, long source) {
    SEL sel = NSSelectorFromString(selName);
    if (![mgr respondsToSelector:sel]) return NO;
    @try {
        if ([selName hasSuffix:@"withOptions:"])
            ((void (*)(id, SEL, long, id))objc_msgSend)(mgr, sel, source, nil);
        else if ([selName hasSuffix:@":"])
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, sel, nil);
        else
            ((void (*)(id, SEL))objc_msgSend)(mgr, sel);
    } @catch (__unused NSException *e) { return NO; }
    usleep(180 * 1000);   // chờ CoverSheet hoàn tất chuyển cảnh
    return !IAIsLocked(mgr);
}

// WAKE: bật màn + nếu đang khoá và máy KHÔNG có passcode thì mở khoá về home. Mục đích:
// sau respring có thể TỰ mở màn để launch app (uiopen không foreground được khi màn tắt/khoá).
// AN TOÀN: KHÔNG bypass passcode — nếu có passcode các API unlock này chỉ hiện màn nhập (không mở).
// Phần unlock chỉ chạy trong SpringBoard. Thử nhiều selector iOS 15/16 + kiểm tra isUILocked sau mỗi lần.
static NSString *IAWake(void) {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        IAWakeScreen();   // ngoài SpringBoard: chỉ unblank được
        return @"OK wake";
    }
    __block NSString *diag = @"OK wake";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            IASpringBoardWakeScreen();   // đánh thức đúng cách trong SpringBoard
            Class cls = NSClassFromString(@"SBLockScreenManager");
            id mgr = (cls && [cls respondsToSelector:@selector(sharedInstance)])
                     ? [cls performSelector:@selector(sharedInstance)] : nil;
            if (!mgr) { diag = @"OK wake (no-lsm)"; return; }
            if (!IAIsLocked(mgr)) { diag = @"OK wake (đã mở khoá)"; return; }
            // Thử lần lượt các selector unlock; dừng ngay khi isUILocked=NO. attemptUnlockWithPasscode:
            // (gọi nil) là selector CHẠY trên iOS 16.2 → để đầu cho nhanh; còn lại làm dự phòng đa phiên bản.
            // AN TOÀN: nil passcode chỉ mở được khi máy KHÔNG đặt passcode (có passcode → sai mã → giữ khoá).
            struct { NSString *sel; long src; } tries[] = {
                { @"attemptUnlockWithPasscode:", 0 },
                { @"_attemptUnlockWithPasscode:", 0 },
                { @"unlockUIFromSource:withOptions:", 0 },
                { @"unlockUIFromSource:withOptions:", 1 },
                { @"unlockWithSource:", 0 },
                { @"_finishUIUnlockFromSource:", 0 },
            };
            for (int i = 0; i < (int)(sizeof(tries)/sizeof(tries[0])); i++) {
                if (IATryUnlockSel(mgr, tries[i].sel, tries[i].src)) {
                    diag = [NSString stringWithFormat:@"OK wake+unlock (%@ src=%ld)", tries[i].sel, tries[i].src];
                    return;
                }
            }
            IADumpUnlockMethods(mgr);     // chỉ dump khi KHÔNG unlock được (để chẩn đoán qua SSH)
            diag = @"OK wake (unblank, chưa unlock — xem /var/jb/tmp/iaunlock.txt)";
        } @catch (NSException *e) { diag = [@"OK wake (unlock-err " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// RadiosPreferences (Preferences.framework) — khai báo selector qua protocol để gọi được mà không link class.
@protocol IARadiosPrefsSB <NSObject>
- (void)setAirplaneMode:(BOOL)mode;
- (BOOL)airplaneMode;
- (void)synchronize;
@end

// IAAirplane(on): BẬT/TẮT Airplane Mode. CHỈ có tác dụng khi chạy TRONG SpringBoard — RadiosPreferences
// là chủ sở hữu radio thật sự Ở TIẾN TRÌNH SpringBoard (đúng đường Cài đặt dùng), nên setAirplaneMode:
// tại đây CẮT/BẬT sóng thật. Gọi từ daemon root (0.7.82) chỉ ghi plist, KHÔNG cắt sóng → thất bại.
// Chạy trên MAIN THREAD (giống Settings) cho chắc. Trả "OK airplane <on|off> read=<..>" hoặc ERR.
static NSString *IAAirplane(int on) {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
        return @"SKIP airplane (chỉ SpringBoard đổi được sóng)";
    __block NSString *diag = @"ERR airplane";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            static Class cls = nil; static int tried = 0;
            if (!tried) {
                tried = 1;
                dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY);
                cls = objc_getClass("RadiosPreferences");
            }
            if (!cls) { diag = @"ERR airplane (no RadiosPreferences)"; return; }
            id<IARadiosPrefsSB> rp = [[cls alloc] init];
            if (!rp) { diag = @"ERR airplane (alloc nil)"; return; }
            [rp setAirplaneMode:(on ? YES : NO)];
            if ([rp respondsToSelector:@selector(synchronize)]) [rp synchronize];
            BOOL rb = on ? YES : NO;
            if ([rp respondsToSelector:@selector(airplaneMode)]) rb = [rp airplaneMode];
            diag = [NSString stringWithFormat:@"OK airplane %s read=%s", on ? "on" : "off", rb ? "on" : "off"];
        } @catch (NSException *e) { diag = [@"ERR airplane " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

static const int TOUCH_PORT = 8399;

// ---- IOKit IOHIDEvent (CHỈ để gắn vào UITouch, KHÔNG dispatch hệ thống → an toàn) ----
typedef double IOHIDFloat;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern "C" {
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, uint32_t);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, uint32_t);
void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
}
@interface UIApplication (IAse)
- (UIEvent *)_touchesEvent;
@end
@interface UIEvent (IAse)
- (void)_clearTouches;
- (void)_setHIDEvent:(IOHIDEventRef)e;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
@end
@interface UITouch (IAse)
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)setPhase:(UITouchPhase)p;
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)p;
- (void)setTapCount:(NSUInteger)c;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)_setHidEvent:(IOHIDEventRef)e;
- (void)setIsTap:(BOOL)b;
- (void)_setIsTapToClick:(BOOL)b;
@end

static UIWindow *IAActiveWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *best = nil;
    @try {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
                if (!best || w.windowLevel >= best.windowLevel) best = w;
            }
        }
    } @catch (__unused NSException *e) {}
    if (best) return best;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow) return app.keyWindow;
    return app.windows.firstObject;
#pragma clang diagnostic pop
}

// ---- AutoTouch-style: synth UITouch + sendEvent (in-app, KHÔNG dispatch HID hệ thống) ----
// Giao touchesBegan/Moved/Ended cho view — hợp app xử lý chạm tuỳ biến (Telegram).
// freshSet=YES: xoá touch-set cũ + add touch mới (dùng cho TAP, và ở phase Began của SWIPE).
// freshSet=NO: GIỮ nguyên touch đang có, chỉ cập nhật vị trí/phase rồi gửi (các phase Moved/Ended
//   của SWIPE) → 1 touch LIÊN TỤC, tránh "đa điểm" khiến màn chính kéo icon.
static UITouch *IASynthPhase(CGPoint pt, UITouchPhase phase, UITouch *reuse, BOOL freshSet) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *win = IAActiveWindow();
    if (!win) return reuse;
    CGSize scr = win.bounds.size;
    CGPoint norm = CGPointMake(pt.x / scr.width, pt.y / scr.height);
    BOOL down = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
    UIView *hitv = [win hitTest:pt withEvent:nil];

    UITouch *t = reuse;
    if (!t) {
        t = [[UITouch alloc] init];
        if ([t respondsToSelector:@selector(setWindow:)]) [t setWindow:win];
        if ([t respondsToSelector:@selector(setView:)]) [t setView:hitv];
        if ([t respondsToSelector:@selector(setTapCount:)]) [t setTapCount:1];
        if ([t respondsToSelector:@selector(setIsTap:)]) [t setIsTap:YES];
        if ([t respondsToSelector:@selector(_setIsTapToClick:)]) [t _setIsTapToClick:YES];
    }
    if ([t respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)])
        [t _setLocationInWindow:pt resetPrevious:(phase == UITouchPhaseBegan)];
    if ([t respondsToSelector:@selector(setTimestamp:)])
        [t setTimestamp:[[NSProcessInfo processInfo] systemUptime]];
    if ([t respondsToSelector:@selector(setPhaseAndUpdateTimestamp:)]) [t setPhaseAndUpdateTimestamp:phase];
    if ([t respondsToSelector:@selector(setPhase:)]) [t setPhase:phase];

    uint32_t mask = down ? 0x00000003 /*Range|Touch*/ : 0x00000002 /*Touch*/;
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, 0x23, 0, 0, mask, 0,
        norm.x, norm.y, 0, 0, 0, down, down, 0);
    if (parent) {
        IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 2, 2, mask,
            norm.x, norm.y, 0, 0, 0, down, down, 0);
        if (finger) { IOHIDEventAppendEvent(parent, finger, 0); CFRelease(finger); }
        if ([t respondsToSelector:@selector(_setHidEvent:)]) [t _setHidEvent:parent];
    }
    UIEvent *ev = [app respondsToSelector:@selector(_touchesEvent)] ? [app _touchesEvent] : nil;
    if (ev) {
        if (freshSet && [ev respondsToSelector:@selector(_clearTouches)]) [ev _clearTouches];
        if (parent && [ev respondsToSelector:@selector(_setHIDEvent:)]) [ev _setHIDEvent:parent];
        if (freshSet && [ev respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) [ev _addTouch:t forDelayedDelivery:NO];
        [app sendEvent:ev];
    }
    if (parent) CFRelease(parent);
    return t;
}

// Lõi chạy TRỰC TIẾP trên main (không dispatch_sync) — gọi được từ IATap.
// began → stationary (kiểu AutoTouch, giúp gesture recognizer) → ended.
static void IADoSendEvent(CGPoint pt) {
    // began → ended trên CÙNG 1 touch liên tục (freshSet=NO ở ended). Đây là điểm mấu chốt cho
    // SwiftUI: UITapGestureRecognizer của SwiftUI cần ghép began↔ended của cùng touch. Nếu ended
    // dùng freshSet=YES (clear+add lại) thì recognizer coi như touch mới → KHÔNG nhận tap (nút/tab/
    // toggle SwiftUI không ăn). Với UIKit UIControl thì cả hai kiểu đều actuate nên đổi sang NO an toàn.
    UITouch *t = IASynthPhase(pt, UITouchPhaseBegan, nil, YES);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);   // giữ ~50ms cho recognizer nhận diện
    IASynthPhase(pt, UITouchPhaseEnded, t, NO);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
}

// VUỐT THẬT bằng synthetic touch: began → moved×N (nội suy) → ended.
// Driをve được MỌI pan gesture (scroll view, PAGING màn hình chính, gesture tuỳ biến app).
// Vẫn IN-PROCESS sendEvent (KHÔNG dispatch HID hệ thống) → an toàn như TAP sendEvent.
static void IADoSwipeSendEvent(CGPoint a, CGPoint b, double dur) {
    if (dur <= 0.05) dur = 0.28;
    if (dur > 1.2) dur = 1.2;
    const int steps = 16;
    UITouch *t = IASynthPhase(a, UITouchPhaseBegan, nil, YES);   // began: tạo touch mới
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.008, false);
    for (int i = 1; i <= steps; i++) {
        double f = (double)i / steps;
        CGPoint p = CGPointMake(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f);
        IASynthPhase(p, UITouchPhaseMoved, t, NO);               // moved: GIỮ 1 touch liên tục
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, dur / steps, false);
    }
    IASynthPhase(b, UITouchPhaseEnded, t, NO);                    // ended: kết thúc chính touch đó
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.015, false);
}

// ---- TYPE: gõ chữ vào ô nhập đang focus (first responder) ----
static UIResponder *IAFindFirstResponder(UIView *v) {
    if (v.isFirstResponder) return v;
    for (UIView *s in v.subviews) { UIResponder *r = IAFindFirstResponder(s); if (r) return r; }
    return nil;
}
// Tìm view con nhận text (UIKeyInput) trong subtree.
static UIView *IAFindKeyInput(UIView *v) {
    if ([v conformsToProtocol:@protocol(UIKeyInput)]) return v;
    for (UIView *s in v.subviews) { UIView *r = IAFindKeyInput(s); if (r) return r; }
    return nil;
}
// Phân giải ô nhận text (UIKeyInput) từ first responder hiện tại. GỌI TRÊN MAIN THREAD.
// Dùng chung cho TYPE (gõ chữ/paste) & KEY (phím đặc biệt).
static id<UIKeyInput> IAResolveKeyInput(void) {
    UIWindow *win = IAActiveWindow();
    UIResponder *fr = win ? IAFindFirstResponder(win) : nil;
    id target = nil;
    if (fr && [fr conformsToProtocol:@protocol(UIKeyInput)]) target = fr;
    else if ([fr isKindOfClass:UISearchBar.class] &&
             [(UISearchBar *)fr respondsToSelector:@selector(searchTextField)])
        target = [(UISearchBar *)fr searchTextField];                     // vỏ search → text field con
    else if ([fr isKindOfClass:UIView.class])
        target = IAFindKeyInput((UIView *)fr);                            // tìm sâu trong subtree
    if (!target && win) target = IAFindKeyInput(win);                     // cứu cánh: cả window
    if (target && [target conformsToProtocol:@protocol(UIKeyInput)]) return (id<UIKeyInput>)target;
    return nil;
}
static NSString *IAType(NSString *text) {
    __block NSString *diag = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            id<UIKeyInput> target = IAResolveKeyInput();
            if (!target) { diag = @"ERR chưa focus ô nhập (tap ô nhập trước)"; return; }
            [target insertText:text];   // nhận cả chuỗi dài (paste Ctrl+V) lẫn ký tự lẻ
            diag = [NSString stringWithFormat:@"OK type vào %@", NSStringFromClass([(id)target class])];
        } @catch (NSException *e) { diag = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}
// ---- KEY: phím đặc biệt vào ô đang focus. BACK=xoá lùi (deleteBackward), RETURN=xuống dòng ----
static NSString *IAKey(NSString *name) {
    __block NSString *diag = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            id<UIKeyInput> target = IAResolveKeyInput();
            if (!target) { diag = @"ERR chưa focus ô nhập"; return; }
            NSString *n = name.uppercaseString;
            if ([n isEqualToString:@"BACK"] || [n isEqualToString:@"BACKSPACE"]) {
                [target deleteBackward];
                diag = @"OK key back";
            } else if ([n isEqualToString:@"RETURN"] || [n isEqualToString:@"ENTER"]) {
                [target insertText:@"\n"];
                diag = @"OK key return";
            } else diag = [@"ERR key? " stringByAppendingString:name];
        } @catch (NSException *e) { diag = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}
static NSString *IATapSendEvent(CGPoint pt) {
    __block NSString *diag = @"OK sendEvent";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { IADoSendEvent(pt); } @catch (NSException *e) { diag = [@"ERR se " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// ================= Hiệu ứng hình ảnh trên iPhone (chấm đỏ / mũi tên) =================
static BOOL gFxEnabled = YES;  // BẬT mặc định: chấm đỏ/mũi tên khi tap/vuốt hiện trên màn (và lọt
                               // vào view fbcap) → thấy được click ở đâu. Tắt bằng verb "FX 0".
static UIWindow *gFxWindow = nil;
static UIColor *IAFxColor(void) { return [UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:0.92]; }

static UIWindow *IAFxWindow(void) {
    UIWindow *key = IAActiveWindow();
    if (!key) return nil;
    if (gFxWindow && gFxWindow.windowScene == key.windowScene && !gFxWindow.hidden) return gFxWindow;
    UIWindow *w;
    if (key.windowScene) w = [[UIWindow alloc] initWithWindowScene:key.windowScene];
    else w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelStatusBar + 2000;   // trên cùng
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = NO;                    // KHÔNG chặn chạm thật
    w.hidden = NO;
    gFxWindow = w;
    return w;
}

// Gọi trên main thread.
static void IAShowDot(CGPoint pt) {
    if (!gFxEnabled) return;
    UIWindow *w = IAFxWindow();
    if (!w) return;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    dot.center = pt;
    dot.backgroundColor = IAFxColor();
    dot.layer.cornerRadius = 15;
    dot.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9].CGColor;
    dot.layer.borderWidth = 2.5;
    dot.userInteractionEnabled = NO;
    [w addSubview:dot];
    dot.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.12 animations:^{ dot.transform = CGAffineTransformIdentity; }
                     completion:^(BOOL f) {
        [UIView animateWithDuration:0.45 delay:0.15 options:UIViewAnimationOptionCurveEaseOut animations:^{
            dot.alpha = 0; dot.transform = CGAffineTransformMakeScale(1.9, 1.9);
        } completion:^(BOOL f2) { [dot removeFromSuperview]; }];
    }];
}

static void IAShowArrow(CGPoint a, CGPoint b) {
    if (!gFxEnabled) return;
    UIWindow *w = IAFxWindow();
    if (!w) return;
    // Bọc trong 1 UIView container (để drawViewHierarchy chụp được cả đường vẽ).
    UIView *container = [[UIView alloc] initWithFrame:w.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.userInteractionEnabled = NO;
    [w addSubview:container];

    CAShapeLayer *layer = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:a]; [p addLineToPoint:b];
    CGFloat ang = atan2(b.y - a.y, b.x - a.x), head = 26;   // đầu mũi tên to
    [p moveToPoint:b];
    [p addLineToPoint:CGPointMake(b.x - head * cos(ang - M_PI / 6), b.y - head * sin(ang - M_PI / 6))];
    [p moveToPoint:b];
    [p addLineToPoint:CGPointMake(b.x - head * cos(ang + M_PI / 6), b.y - head * sin(ang + M_PI / 6))];
    layer.path = p.CGPath;
    layer.strokeColor = IAFxColor().CGColor;
    layer.fillColor = [UIColor clearColor].CGColor;
    layer.lineWidth = 6;
    layer.lineCap = kCALineCapRound; layer.lineJoin = kCALineJoinRound;
    [container.layer addSublayer:layer];

    // chấm ở điểm bắt đầu
    UIView *sdot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
    sdot.center = a; sdot.backgroundColor = IAFxColor(); sdot.layer.cornerRadius = 10;
    sdot.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9].CGColor; sdot.layer.borderWidth = 2;
    [container addSubview:sdot];

    [UIView animateWithDuration:0.5 delay:0.7 options:UIViewAnimationOptionCurveEaseOut animations:^{  // hiện ~1.2s
        container.alpha = 0;
    } completion:^(BOOL f) { [container removeFromSuperview]; }];
}

// ---- ĐIỀU KHIỂN REALTIME: 1 UITouch LIÊN TỤC theo con trỏ (bám tay), in-app sendEvent ----
// APP: touch tổng hợp realtime (cuộn/kéo theo tay). SPRINGBOARD: KHÔNG realtime được (touch tổng
// hợp/ép offset → trang kế lazy-load render ĐEN) → dùng IASwipe (animation sạch) và kích hoạt SỚM
// ngay khi kéo ngang đủ xa (không đợi thả) cho phản hồi nhanh. Tap dùng IATap.
static NSString *IASwipe(CGPoint a, CGPoint b, double dur);   // forward-decl
static UITouch *gLiveTouch = nil;
static CGPoint gPtrStart; static BOOL gSbSwiped = NO;
static BOOL gSwitcherMode = NO;   // App Switcher đang mở → dùng synthetic touch (không paging home)
static NSString *IAPointer(unichar phase, CGPoint pt) {
    BOOL isSB = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
    if (isSB) {
        if (phase == 'd') {   // đầu cử chỉ: App Switcher có đang mở không?
            gPtrStart = pt; gSbSwiped = NO;
            __block BOOL sw = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                @try { UIApplication *app = [UIApplication sharedApplication]; SEL s = NSSelectorFromString(@"_accessibilityIsAppSwitcherVisible");
                    if ([app respondsToSelector:s]) sw = ((BOOL (*)(id, SEL))objc_msgSend)(app, s); } @catch (__unused NSException *e) {}
            });
            gSwitcherMode = sw;
        }
        if (!gSwitcherMode) {   // MÀN CHÍNH: kéo ngang = lật trang (IASwipe)
            if (phase == 'd') return @"OK ptr sb-d";
            if (phase == 'm') {
                if (gSbSwiped) return @"OK ptr sb-done";
                CGFloat dx = pt.x - gPtrStart.x, dy = pt.y - gPtrStart.y;
                if (fabs(dx) > 55 && fabs(dx) > fabs(dy)) { gSbSwiped = YES; return IASwipe(gPtrStart, CGPointMake(pt.x, gPtrStart.y), 0.28); }
                return @"OK ptr sb-m";
            }
            if (gSbSwiped) { gSbSwiped = NO; return @"OK ptr sb-done"; }
            CGFloat dist = hypot(pt.x - gPtrStart.x, pt.y - gPtrStart.y);
            if (dist < 8) return @"OK ptr sb-tap";
            return IASwipe(gPtrStart, pt, 0.25);
        }
        // gSwitcherMode: rơi xuống synthetic dưới (cuộn card ngang / vuốt LÊN đóng app / chọn app)
    }
    __block NSString *diag = @"OK ptr";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            if (phase == 'd') {
                gLiveTouch = IASynthPhase(pt, UITouchPhaseBegan, nil, YES);
                IAShowDot(pt);
            } else if (phase == 'm') {
                if (!gLiveTouch) gLiveTouch = IASynthPhase(pt, UITouchPhaseBegan, nil, YES);
                else gLiveTouch = IASynthPhase(pt, UITouchPhaseMoved, gLiveTouch, NO);
            } else {   // 'u'
                if (gLiveTouch) IASynthPhase(pt, UITouchPhaseEnded, gLiveTouch, NO);
                gLiveTouch = nil;
            }
        } @catch (NSException *e) { gLiveTouch = nil; diag = [@"ERR ptr " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// Quét ĐỆ QUY toàn hierarchy tìm UITabBar mà điểm pt (toạ độ window) nằm trong frame.
// Chắc hơn hitTest (hitTest có thể trả UIView con/overlay không có UITabBarButton trong chuỗi cha).
static UITabBar *IAFindTabBarAt(UIView *root, UIWindow *win, CGPoint pt) {
    if (root.hidden || root.alpha < 0.01) return nil;
    if ([root isKindOfClass:UITabBar.class]) {
        CGRect f = [root convertRect:root.bounds toView:win];
        if (CGRectContainsPoint(f, pt)) return (UITabBar *)root;
    }
    for (UIView *sub in root.subviews) {
        UITabBar *r = IAFindTabBarAt(sub, win, pt);
        if (r) return r;
    }
    return nil;
}
// Tìm UITabBarController đang QUẢN LÝ `bar`. Với UITabBarController, thanh tab do controller
// sở hữu: public `bar.delegate` THƯỜNG NIL (controller lắng nghe chạm qua đường nội bộ, không
// qua delegate công khai) → chỉ set `bar.selectedItem` chỉ đổi HIGHLIGHT chứ KHÔNG đổi trang.
// Muốn đổi trang phải set `controller.selectedIndex`. Đây là lý do tab (vd "Cài đặt") bấm không ăn.
static UITabBarController *IAOwningTabBarController(UITabBar *bar) {
    if ([bar.delegate isKindOfClass:UITabBarController.class]) return (UITabBarController *)bar.delegate;
    // bar là subview trong view của controller → đi ngược responder chain sẽ tới controller.
    for (UIResponder *r = bar; r; r = r.nextResponder)
        if ([r isKindOfClass:UITabBarController.class] && ((UITabBarController *)r).tabBar == bar)
            return (UITabBarController *)r;
    return nil;
}
// Nếu pt rơi vào 1 UITabBar (quét MỌI window của các scene foreground) → chọn tab qua delegate.
static NSString *IATryTabBar(UIWindow *ignored, CGPoint pt) {
    (void)ignored;
    Class TBB = NSClassFromString(@"UITabBarButton");
    UIApplication *app = [UIApplication sharedApplication];
    UITabBar *bar = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || w.alpha < 0.01 || w == gFxWindow) continue;
            bar = IAFindTabBarAt(w, w, pt);
            if (bar) break;
        }
        if (bar) break;
    }
    if (!bar || bar.items.count == 0) return nil;
    NSMutableArray<UIView *> *btns = [NSMutableArray array];
    for (UIView *sub in bar.subviews) if (!TBB || [sub isKindOfClass:TBB]) {
        if (TBB ? [sub isKindOfClass:TBB] : [NSStringFromClass(sub.class) containsString:@"Button"]) [btns addObject:sub];
    }
    [btns sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    // button dưới điểm (frame trong toạ độ bar). Fallback: nếu không button nào chứa điểm,
    // map theo cột x (pt.x / bề rộng bar × số item) — vẫn chọn đúng tab.
    CGPoint pInBar = [bar.window convertPoint:pt toView:bar];
    NSInteger idx = -1;
    for (NSUInteger i = 0; i < btns.count; i++)
        if (CGRectContainsPoint(btns[i].frame, pInBar)) { idx = (NSInteger)i; break; }
    if (idx < 0 && bar.bounds.size.width > 0) {
        NSInteger col = (NSInteger)(pInBar.x / bar.bounds.size.width * (CGFloat)bar.items.count);
        if (col >= 0 && (NSUInteger)col < bar.items.count) idx = col;
    }
    if (idx < 0 || (NSUInteger)idx >= bar.items.count) return nil;
    UITabBarItem *item = bar.items[idx];

    // A) Thanh tab thuộc UITabBarController (phổ biến nhất: iOSAuto & đa số app) → đổi selectedIndex.
    //    Set selectedItem đơn thuần chỉ đổi highlight chứ KHÔNG chuyển trang (public delegate của
    //    controller thường nil). selectedIndex chuyển CẢ trang lẫn highlight, đúng như chạm thật.
    UITabBarController *tbc = IAOwningTabBarController(bar);
    if (tbc && tbc.viewControllers.count > 0) {
        // Map item → view controller (an toàn cả khi có tab "More" khiến index của bar ≠ của VC).
        NSUInteger vcIdx = (NSUInteger)idx;
        for (NSUInteger i = 0; i < tbc.viewControllers.count; i++)
            if (tbc.viewControllers[i].tabBarItem == item) { vcIdx = i; break; }
        if (vcIdx >= tbc.viewControllers.count) vcIdx = tbc.viewControllers.count - 1;
        UIViewController *target = tbc.viewControllers[vcIdx];
        id<UITabBarControllerDelegate> d = tbc.delegate;   // delegate của CONTROLLER (khác delegate của bar)
        BOOL ok = YES;
        if ([d respondsToSelector:@selector(tabBarController:shouldSelectViewController:)])
            ok = [d tabBarController:tbc shouldSelectViewController:target];
        if (ok) {
            tbc.selectedIndex = vcIdx;
            if ([d respondsToSelector:@selector(tabBarController:didSelectViewController:)])
                [d tabBarController:tbc didSelectViewController:target];
        }
        return [NSString stringWithFormat:@"OK tabbarctl idx=%lu/%lu", (unsigned long)vcIdx, (unsigned long)tbc.viewControllers.count];
    }

    // B) UITabBar "trần" do app tự quản (không có UITabBarController) → set selectedItem + báo delegate app.
    bar.selectedItem = item;
    if ([bar.delegate respondsToSelector:@selector(tabBar:didSelectItem:)])
        [bar.delegate tabBar:bar didSelectItem:item];
    return [NSString stringWithFormat:@"OK tabbar idx=%ld/%lu", (long)idx, (unsigned long)bar.items.count];
}

// Bật automation-accessibility TRONG tiến trình app (không HID, không VoiceOver) → UIKit/SwiftUI
// dựng accessibility tree để _accessibilityHitTest + accessibilityActivate hoạt động. Nhiều app
// dùng UIGestureRecognizer (không phải UIControl) → synthetic UITouch không kích hoạt; accessibilityActivate
// gọi thẳng hành động mặc định như VoiceOver nên ăn chắc. An toàn (chỉ ảnh hưởng process hiện tại).
static void IAEnableAX(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
        if (!h) h = dlopen("libAccessibility.dylib", RTLD_LAZY);
        if (!h) return;
        void (*setAuto)(int) = (void (*)(int))dlsym(h, "_AXSSetAutomationEnabled");
        if (setAuto) setAuto(1);
        void (*setApp)(int) = (void (*)(int))dlsym(h, "_AXSApplicationAccessibilitySetEnabled");
        if (setApp) setApp(1);
    });
}

// TAP qua HID enqueue: bơm IOHIDEvent digitizer vào ĐÚNG event queue của CHÍNH app
// (`-[UIApplication _enqueueHIDEvent:]`, in-process — KHÔNG phải system dispatch qua BackBoard/IOKit,
// nên an toàn cho jailbreak). Đi qua UIEventFetcher → gesture-environment như chạm THẬT → kích hoạt
// được UIGestureRecognizer (tab/nút/toggle tự vẽ) mà synthetic sendEvent bỏ sót. Chạy trên main.
static BOOL IAHIDAvailable(void) {
    return [[UIApplication sharedApplication] respondsToSelector:NSSelectorFromString(@"_enqueueHIDEvent:")];
}
// Bơm 1 event digitizer (hand + finger con) tại (nx,ny) chuẩn hoá. touch/range: trạng thái ngón.
// mask: 0x3 = range|touch (đang chạm), 0x2 = range (nhấc). Dùng chung cho down/move/up.
static void IAEmitDigit(UIApplication *app, SEL sel, CGFloat nx, CGFloat ny,
                        uint32_t mask, bool touch, bool range) {
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef e = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, 0x23, 0, 0, mask, 0,
                                                     nx, ny, 0, 0, 0, range, touch, 0);
    if (!e) return;
    IOHIDEventRef f = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 2, 2, mask,
                                                           nx, ny, 0, 0, 0, range, touch, 0);
    if (f) { IOHIDEventAppendEvent(e, f, 0); CFRelease(f); }
    ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, sel, e);
    CFRelease(e);
}

// TAP "NGƯỜI THẬT": bơm chuỗi HID đầy đủ như ngón tay — DOWN → nhiều event GIỮ NGÓN (báo vị trí
// liên tục ~mỗi 16ms, tổng ~112ms) → UP. WebKit (WKWebView: _UIWebTouchEventsGestureRecognizer) và
// SwiftUI hay BỎ QUA chuỗi down→up cụt; chuỗi liên tục này khớp đúng "touch stream" thật nên nút web
// mới nhận. Vẫn in-process (_enqueueHIDEvent:) → an toàn cho jailbreak.
static void IADoTapHID(CGPoint pt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            SEL sel = NSSelectorFromString(@"_enqueueHIDEvent:");
            if (![app respondsToSelector:sel]) return;
            UIWindow *win = IAActiveWindow(); if (!win) return;
            CGSize scr = win.bounds.size; if (scr.width <= 0 || scr.height <= 0) return;
            CGFloat nx = pt.x / scr.width, ny = pt.y / scr.height;

            IAEmitDigit(app, sel, nx, ny, 0x3, true, true);   // DOWN (ngón chạm)

            // GIỮ NGÓN: 6 nhịp báo vị trí (đứng yên, nhích cực nhỏ như tay người) mỗi ~16ms.
            const int HOLD = 6;
            for (int k = 1; k <= HOLD; k++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(k * 0.016 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        CGFloat jx = nx + ((k % 2) ? 0.0006 : -0.0006);   // rung nhẹ ~0.2px → "sống" như tay
                        IAEmitDigit(app, sel, jx, ny, 0x3, true, true);
                    } @catch (__unused NSException *e) {}
                });
            }
            // UP sau ~112ms (giữ đủ lâu để tap gesture của WebKit/SwiftUI ghi nhận).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.112 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { IAEmitDigit(app, sel, nx, ny, 0x2, false, false); } @catch (__unused NSException *e) {}
            });
        } @catch (__unused NSException *e) {}
    });
}

// TAP "tự nhiên": gửi began, để RUNLOOP CHÍNH chạy bình thường ~60ms rồi mới gửi ended.
// MẤU CHỐT cho SwiftUI: Button/TabView của SwiftUI gửi action trên vòng runloop SAU touchEnded
// (qua observer/MainActor). Nếu tap chạy trong dispatch_sync + nested CFRunLoopRunInMode (chặn main)
// thì action bị treo → không ăn. Ở đây dùng dispatch_async + dispatch_after nên main runloop chạy
// tự nhiên giữa began↔ended → SwiftUI nhận diện tap. UIKit UIControl cũng ăn bình thường.
static void IADoTapNatural(CGPoint pt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UITouch *t = IASynthPhase(pt, UITouchPhaseBegan, nil, YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { IASynthPhase(pt, UITouchPhaseEnded, t, NO); } @catch (__unused NSException *e) {}
            });
        } @catch (__unused NSException *e) {}
    });
}

// Kích hoạt cell của UITableView / UICollectionView ĐÚNG như chạm thật: gọi thẳng
// didSelectRow/didSelectItem qua delegate. Lý do: app Cài đặt (com.apple.Preferences) gần như
// TOÀN BỘ là UITableView; cell KHÔNG phải UIControl nên synthetic/HID touch nhiều khi không được
// UITableView track (giống UITabBar phải xử lý riêng) → hàng bấm "không phản ứng". Đi thẳng delegate
// là cách chắc chắn nhất. CHỈ dùng khi delegate CÓ cài didSelect (app dùng gesture tự vẽ trong cell
// sẽ không có → trả nil để rơi xuống đường HID/synthetic, tránh regress). Gọi trên MAIN THREAD.
static NSString *IATryListCell(UIView *hit, UIWindow *win) {
    // 1) UITableViewCell trong UITableView
    UITableViewCell *tvc = nil;
    for (UIView *v = hit; v && v != win.superview; v = v.superview)
        if ([v isKindOfClass:UITableViewCell.class]) { tvc = (UITableViewCell *)v; break; }
    if (tvc) {
        UITableView *tv = nil;
        for (UIView *v = tvc.superview; v && v != win.superview; v = v.superview)
            if ([v isKindOfClass:UITableView.class]) { tv = (UITableView *)v; break; }
        id<UITableViewDelegate> d = tv.delegate;
        NSIndexPath *ip = tv ? [tv indexPathForCell:tvc] : nil;
        if (ip && [d respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            if ([d respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)]) {
                NSIndexPath *want = [d tableView:tv willSelectRowAtIndexPath:ip];
                if (!want) return @"OK tvcell-blocked";   // delegate chặn chọn (như chạm thật)
                ip = want;
            }
            if (tv.allowsSelection)
                [tv selectRowAtIndexPath:ip animated:YES scrollPosition:UITableViewScrollPositionNone];
            [d tableView:tv didSelectRowAtIndexPath:ip];
            return [NSString stringWithFormat:@"OK tvcell %ld/%ld", (long)ip.section, (long)ip.row];
        }
    }
    // 2) UICollectionViewCell trong UICollectionView
    UICollectionViewCell *cvc = nil;
    for (UIView *v = hit; v && v != win.superview; v = v.superview)
        if ([v isKindOfClass:UICollectionViewCell.class]) { cvc = (UICollectionViewCell *)v; break; }
    if (cvc) {
        UICollectionView *cv = nil;
        for (UIView *v = cvc.superview; v && v != win.superview; v = v.superview)
            if ([v isKindOfClass:UICollectionView.class]) { cv = (UICollectionView *)v; break; }
        id<UICollectionViewDelegate> d = cv.delegate;
        NSIndexPath *ip = cv ? [cv indexPathForCell:cvc] : nil;
        if (ip && [d respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
            if ([d respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)]
                && ![d collectionView:cv shouldSelectItemAtIndexPath:ip])
                return @"OK cvitem-blocked";
            if (cv.allowsSelection)
                [cv selectItemAtIndexPath:ip animated:YES scrollPosition:UICollectionViewScrollPositionNone];
            [d collectionView:cv didSelectItemAtIndexPath:ip];
            return [NSString stringWithFormat:@"OK cvitem %ld/%ld", (long)ip.section, (long)ip.item];
        }
    }
    return nil;
}

// Tìm UINavigationController đang quản lý `nb` trong cây view-controller (đệ quy child + presented).
static UINavigationController *IANavForBar(UIViewController *vc, UINavigationBar *nb) {
    if (!vc) return nil;
    if ([vc isKindOfClass:UINavigationController.class] && ((UINavigationController *)vc).navigationBar == nb)
        return (UINavigationController *)vc;
    for (UIViewController *c in vc.childViewControllers) {
        UINavigationController *r = IANavForBar(c, nb); if (r) return r;
    }
    return IANavForBar(vc.presentedViewController, nb);
}
// Nút BACK trên navigation bar: _UIButtonBarButton là UIControl nhưng KHÔNG nhận synthetic/HID
// (đã thử — không pop). Cách chắc chắn: tìm UINavigationController của thanh rồi popViewController
// (đúng như UITabBar phải set selectedIndex, UITableViewCell phải gọi didSelectRow). CHỈ coi là
// "back" khi điểm chạm nằm NỬA TRÁI thanh (vùng nút back) và stack có >1 VC (có cái để pop) →
// không nhầm với nút phải (Edit/Done) hay khi đang ở gốc. Gọi trên MAIN THREAD.
static NSString *IATryNavBack(UIView *hit, UIWindow *win, CGPoint pt) {
    UINavigationBar *nb = nil;
    for (UIView *v = hit; v && v != win.superview; v = v.superview)
        if ([v isKindOfClass:UINavigationBar.class]) { nb = (UINavigationBar *)v; break; }
    if (!nb) return nil;
    CGRect bf = [nb convertRect:nb.bounds toView:win];
    if (pt.x > bf.origin.x + bf.size.width * 0.45) return nil;   // không ở vùng nút back
    UINavigationController *nc = [nb.delegate isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)nb.delegate : nil;
    if (!nc) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                nc = IANavForBar(w.rootViewController, nb); if (nc) break;
            }
            if (nc) break;
        }
    }
    if (nc && nc.viewControllers.count > 1) {
        unsigned long before = (unsigned long)nc.viewControllers.count;
        [nc popViewControllerAnimated:YES];
        return [NSString stringWithFormat:@"OK navback (stack %lu->%lu)", before, before - 1];
    }
    return nil;
}

// ---- TAP: kích hoạt phần tử tại toạ độ (không HID) ----
static NSString *IATap(CGPoint pt) {
    __block NSString *diag = @"ERR";
    __block BOOL general = NO;
    __block BOOL wantHID = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = IAActiveWindow();
            if (!win) { diag = @"ERR no-window"; return; }
            IAShowDot(pt);   // chấm đỏ trên iPhone
            UIView *hit = [win hitTest:pt withEvent:nil];
            if (!hit) { diag = @"ERR no-hit"; return; }
            NSString *hc = NSStringFromClass(hit.class);

            // 0a) UISwitch → LẬT + báo ValueChanged. (sendActions:TouchUpInside KHÔNG lật switch nên
            //     toggle đổi Dark Mode… trong app không ăn.) Phải xử lý TRƯỚC nhánh UIControl.
            for (UIView *v = hit; v && v != win.superview; v = v.superview) {
                if ([v isKindOfClass:UISwitch.class] && ((UISwitch *)v).enabled) {
                    UISwitch *sw = (UISwitch *)v;
                    [sw setOn:!sw.isOn animated:YES];
                    [sw sendActionsForControlEvents:UIControlEventValueChanged];
                    diag = [NSString stringWithFormat:@"OK switch=%d hit=%@", sw.isOn ? 1 : 0, hc];
                    return;
                }
            }
            // 0b) UITabBar → chọn tab qua delegate. UITabBar xử lý chạm NỘI BỘ (không dùng action
            //     UIControl thường) nên synthetic began→ended KHÔNG lật tab. Quét theo FRAME (không
            //     lệ thuộc hitTest vì nó hay trả UIView con/overlay) rồi set selectedItem +
            //     tabBar:didSelectItem: (UITabBarController / coordinator SwiftUI là delegate → đổi trang).
            NSString *tb = IATryTabBar(win, pt);
            if (tb) { diag = [NSString stringWithFormat:@"%@ hit=%@", tb, hc]; return; }
            // 1) CÒN LẠI: CHẠM THẬT (synthetic began→ended) — như ngón tay. Hoạt động cho nút, ô nhập
            //    text/search (Safari mở bàn phím), cell tuỳ biến, thanh địa chỉ capsule…
            //    KHÔNG dùng sendActionsForControlEvents:TouchUpInside vì nhiều UI kiểu gesture (Safari
            //    SFCapsuleNavigationBar, ô tìm kiếm) bỏ qua action đó → tap không ăn.
            // 0c) SwiftUI (Button/TabView/Toggle) dùng UIGestureRecognizer/accessibility, KHÔNG nhận
            //     synthetic UITouch (gesture-environment bỏ qua event tự tạo). UIControl (Safari, UIButton)
            //     thì nhận vì override touchesBegan/Ended trực tiếp. → Nếu target KHÔNG phải UIControl,
            //     thử accessibilityActivate (kích hoạt hành động mặc định như VoiceOver — an toàn, không HID).
            // Chỉ coi UIControl ENABLED là control (control disabled không xử lý chạm — bỏ qua nó,
            // vì thường tab/nút thật nằm ở view con có gesture recognizer).
            UIControl *ctl = nil;
            for (UIView *v = hit; v && v != win.superview; v = v.superview)
                if ([v isKindOfClass:UIControl.class] && ((UIControl *)v).enabled) { ctl = (UIControl *)v; break; }
            BOOL isSBproc = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];

            // 0c) UIControl có UIView CON phủ lên trên (hitTest trả con, không phải control) → synthetic
            //     UITouch đặt touch.view=con nên UIControl KHÔNG track began→ended → TouchUpInside không
            //     bắn. Bắn thẳng action. CHỈ khi hit ≠ control (hit CHÍNH là control thì để synthetic —
            //     hợp UI kiểu gesture như Safari mà TouchUpInside bị bỏ qua). Bỏ qua SpringBoard.
            if (ctl && ctl != hit && !isSBproc) {
                [ctl sendActionsForControlEvents:UIControlEventTouchDown];
                [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
                diag = [NSString stringWithFormat:@"OK ctl-fire %@ hit=%@", NSStringFromClass(ctl.class), hc];
                return;
            }
            // 0c-nav) Nút dạng "button" mà hitTest trả CHÍNH nó (hit==ctl) — điển hình là nút Back
            //   _UIButtonBarButton trên navigation bar (là UIControl NHƯNG KHÔNG kế thừa UIButton,
            //   nên isKindOfClass:UIButton trượt). Synthetic/natural touch KHÔNG kích hoạt nó →
            //   trước đây "ấn Back không được". Dùng HID (chạm THẬT, đi đúng pipeline sự kiện) nếu có;
            //   nếu không thì bắn action trực tiếp. Nhận diện qua TÊN LỚP chứa "Button" để loại trừ
            //   control cần chạm thật để focus/kéo (UITextField, UISearchBar, UISlider…).
            BOOL ctlButtonish = ctl && ([ctl isKindOfClass:UIButton.class] ||
                                        [NSStringFromClass(ctl.class) containsString:@"Button"]);
            if (ctlButtonish && !isSBproc) {
                // Ưu tiên: nút BACK trên navigation bar → pop nav controller (chắc chắn; synthetic/HID
                // không kích hoạt _UIButtonBarButton).
                NSString *nb = IATryNavBack(hit, win, pt);
                if (nb) { diag = [NSString stringWithFormat:@"%@ hit=%@", nb, hc]; return; }
                // Nút bar khác (Edit/Done/Add…) hoặc UIButton thường: bắn action trực tiếp.
                [ctl sendActionsForControlEvents:UIControlEventTouchDown];
                [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
                diag = [NSString stringWithFormat:@"OK ctl-fire %@ hit=%@", NSStringFromClass(ctl.class), hc];
                return;
            }
            // 0c-bis) Cell UITableView/UICollectionView (Settings iOS toàn table): kích hoạt qua
            //     delegate didSelectRow/didSelectItem — chắc chắn hơn HID/synthetic (cell không phải
            //     UIControl nên hay bị bỏ qua). CHỈ khi không có UIControl cụ thể dưới ngón tay.
            if (!ctl && !isSBproc) {
                NSString *lc = IATryListCell(hit, win);
                if (lc) { diag = [NSString stringWithFormat:@"%@ hit=%@", lc, hc]; return; }
            }
            // 0c-web) Nội dung WKWebView (Safari, app web như jp.round1 = RaupokeV2.CustomWkWebView):
            //     nút là phần tử HTML, KHÔNG native. Trước đây CHỈ bơm click JS (elementFromPoint) →
            //     trên Safari KHÔNG ăn (site nghe touch-event thật, iframe, hoặc chặn hành động ngoài
            //     "user gesture"). Nay TAP như NGƯỜI THẬT: chạm HID (đi qua _UIWebTouchEventsGesture
            //     Recognizer → WebKit sinh touchstart/touchmove/touchend THẬT trong trang, đúng như ngón
            //     tay). Kèm LƯỚI AN TOÀN JS cho app web mà WKDeferringGestureRecognizer nuốt chạm
            //     (jp.round1): sau khi HID xong, NẾU trang chưa nhận được touch thật → mới bơm click JS.
            //     Cờ window.__iaTS (đã thấy touch) + window.__iaHook (document còn nguyên) tránh double-
            //     fire: link đã điều hướng (document mới → __iaHook mất) hoặc nút đã nhận touch → BỎ JS.
            if (!ctl && !isSBproc) {
                UIView *wv = nil;
                for (UIView *v = hit; v && v != win.superview; v = v.superview)
                    if ([v isKindOfClass:NSClassFromString(@"WKWebView")]) { wv = v; break; }
                SEL ejs = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
                if (wv && [wv respondsToSelector:ejs]) {
                    CGPoint p = [wv convertPoint:pt fromView:win];   // → toạ độ trong webview (viewport)
                    CGFloat z = 1;
                    id sv = ((id (*)(id, SEL))objc_msgSend)(wv, NSSelectorFromString(@"scrollView"));
                    if (sv) { CGFloat zz = [(UIScrollView *)sv zoomScale]; if (zz > 0) z = zz; }
                    int cx = (int)lround(p.x / z), cy = (int)lround(p.y / z);   // CSS px (client, theo viewport)
                    // Click JS (lưới an toàn) — TỰ BỎ nếu trang đã nhận touch thật (__iaTS) hoặc đã điều
                    // hướng sang document mới (__iaHook mất) → chỉ chạy khi HID thật sự không tới được trang.
                    // Mô phỏng CHẠM THẬT ĐẦY ĐỦ: pointerdown → touchstart → mousedown → pointerup →
                    // touchend → mouseup → click (+ focus). Trên Safari HID KHÔNG tới được WebContent
                    // (đã kiểm chứng trên máy: web page chỉ nhận mouse/click, không có touchstart) nên
                    // đây mới là đường ăn thật sự. Safari iOS16 dựng được Touch/TouchEvent → nút web CHỈ
                    // nghe touch (game, menu tuỳ biến) nay cũng nhận.
                    NSString *clickJS = [NSString stringWithFormat:
                        @"(function(){if(window.__iaTS||!window.__iaHook)return 'hid';"
                        "var x=%d,y=%d;var e=document.elementFromPoint(x,y);if(!e)return 'noel';"
                        "function P(t){try{e.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,view:window,pointerId:1,pointerType:'touch',isPrimary:true,clientX:x,clientY:y}));}catch(_){}}"
                        "function M(t){try{e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y,button:0}));}catch(_){}}"
                        "function T(t,end){try{var tt=new Touch({identifier:1,target:e,clientX:x,clientY:y,pageX:x,pageY:y,radiusX:8,radiusY:8,force:1});"
                        "e.dispatchEvent(new TouchEvent(t,{bubbles:true,cancelable:true,view:window,touches:end?[]:[tt],targetTouches:end?[]:[tt],changedTouches:[tt]}));}catch(_){}}"
                        "P('pointerdown');T('touchstart',false);M('mousedown');P('pointerup');T('touchend',true);M('mouseup');M('click');"
                        "try{if(e.focus)e.focus();}catch(_){}"
                        "try{if(typeof e.click==='function')e.click();}catch(_){}"
                        "return 'js:'+(e.tagName||'?');})()", cx, cy];
                    if (IAHIDAvailable()) {
                        // 1) Gài listener bắt touch thật (1 lần/ document) + reset cờ mỗi lần tap.
                        NSString *hookJS =
                            @"(function(){if(!window.__iaHook){window.__iaHook=1;"
                            "['touchstart','touchmove','touchend'].forEach(function(t){"
                            "document.addEventListener(t,function(){window.__iaTS=true;},{capture:true,passive:true});});}"
                            "window.__iaTS=false;return 1;})()";
                        __block BOOL fired = NO;
                        void (^fireHID)(void) = ^{
                            if (fired) return; fired = YES;
                            IADoTapHID(pt);   // CHẠM THẬT như ngón tay (HID in-process)
                            // 2) Sau khi chuỗi HID kết thúc (~260ms), nếu trang chưa thấy touch → click JS.
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.26 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                @try {
                                    void (^cb2)(id, id) = ^(id res, id err){ (void)res; (void)err; };
                                    ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, clickJS, cb2);
                                } @catch (__unused NSException *e) {}
                            });
                        };
                        // Gài cờ XONG mới chạm (để listener kịp bắt touchstart). Có dự phòng nếu callback
                        // không về (hiếm, Safari IPC): vẫn chạm sau 200ms.
                        void (^hookCb)(id, id) = ^(id res, id err){ (void)res; (void)err; fireHID(); };
                        ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, hookJS, hookCb);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{ fireHID(); });
                        diag = [NSString stringWithFormat:@"OK web-hid (%d,%d) hit=%@", cx, cy, hc];
                        return;
                    }
                    // iOS cũ không có _enqueueHIDEvent: → chỉ còn click JS (bỏ điều kiện __iaTS/__iaHook).
                    NSString *jsOnly = [clickJS stringByReplacingOccurrencesOfString:
                        @"if(window.__iaTS||!window.__iaHook)return 'hid';" withString:@""];
                    void (^cb)(id, id) = ^(id res, id err){ (void)res; (void)err; };
                    ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, jsOnly, cb);
                    diag = [NSString stringWithFormat:@"OK webjs (%d,%d) hit=%@", cx, cy, hc];
                    return;
                }
            }
            // 0d) Target gesture-based (không phải UIControl trực tiếp): ưu tiên HID enqueue (đi đúng
            //     pipeline gesture như chạm thật) — kích hoạt UIGestureRecognizer của tab/nút tự vẽ.
            NSString *dbg = @"";
            if (!ctl && !isSBproc && IAHIDAvailable()) {
                wantHID = YES;
                dbg = @" [hid]";
            } else if (!ctl && !isSBproc) {
                NSMutableArray *grNames = [NSMutableArray array];
                for (UIView *v = hit; v && v != win.superview; v = v.superview)
                    for (UIGestureRecognizer *g in v.gestureRecognizers)
                        [grNames addObject:NSStringFromClass(g.class)];
                dbg = [NSString stringWithFormat:@" [grs=%@ noHID]", grNames.count ? [grNames componentsJoinedByString:@","] : @"none"];
            }
            general = YES;   // gửi tap SAU khi thoát dispatch_sync (để main runloop chạy)
            diag = [NSString stringWithFormat:@"OK tap hit=%@%@", hc, dbg];
        } @catch (NSException *e) { diag = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    if (general) { if (wantHID) IADoTapHID(pt); else IADoTapNatural(pt); }
    return diag;
}

// ---- SWIPE: cuộn qua accessibilityScroll theo hướng ----
static NSString *IASwipe(CGPoint a, CGPoint b, double dur) {
    __block NSString *diag = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = IAActiveWindow();
            if (!win) { diag = @"ERR no-window"; return; }
            IAShowArrow(a, b);   // mũi tên vuốt trên iPhone
            CGFloat dx = b.x - a.x, dy = b.y - a.y;
            BOOL wantV = fabs(dy) >= fabs(dx);
            UIView *hit = [win hitTest:a withEvent:nil];
            BOOL isSB = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];

            // 1) Cuộn UIScrollView/UITableView bằng contentOffset CÓ ANIMATION + QUÁN TÍNH.
            //    Vì sao KHÔNG dùng touch synthetic/HID: pan của UITableView (vd app Cài đặt) KHÔNG bị
            //    touch tổng hợp/HID lái đáng tin (cell bypass touch sim) → contentOffset là cách DUY
            //    NHẤT chắc chắn cuộn. Bù lại "giống người dùng" bằng ANIMATION giảm tốc; và cho dur
            //    ĐIỀU KHIỂN quãng: vuốt nhanh (dur nhỏ)=vận tốc cao=văng xa; rê chậm=gần đúng quãng kéo.
            //    (SpringBoard vuốt ngang vẫn phân trang riêng ở dưới.)
            for (UIView *v = hit ?: win; v && v != win.superview; v = v.superview) {
                if (![v isKindOfClass:UIScrollView.class]) continue;
                UIScrollView *sv = (UIScrollView *)v;
                if (!sv.scrollEnabled) continue;
                UIEdgeInsets ins = sv.adjustedContentInset;
                CGFloat spanY = sv.contentSize.height - sv.bounds.size.height + ins.top + ins.bottom;
                CGFloat spanX = sv.contentSize.width - sv.bounds.size.width + ins.left + ins.right;
                BOOL vScroll = spanY > 1, hScroll = spanX > 1;
                if ((wantV && !vScroll) || (!wantV && !hScroll)) continue;  // trục này không cuộn → bỏ qua
                CGPoint start = sv.contentOffset, off = start;

                // MÀN HÌNH CHÍNH (SpringBoard) vuốt ngang = PHÂN TRANG: snap NGUYÊN TRANG
                // (không momentum → không lệch giữa 2 trang; setContentOffset → KHÔNG kéo icon).
                if (isSB && !wantV && hScroll) {
                    CGFloat pageW = sv.bounds.size.width;
                    int numPages = (pageW > 1) ? (int)roundf(sv.contentSize.width / pageW) : 1;
                    if (numPages < 1) numPages = 1;
                    CGFloat step = sv.contentSize.width / numPages;   // chia đều (gồm cả khoảng cách trang)
                    int curPage = (step > 1) ? (int)roundf(start.x / step) : 0;
                    int target = curPage + (dx < 0 ? 1 : -1);         // finger sang trái → trang kế
                    if (target < 0) target = 0;
                    if (target > numPages - 1) target = numPages - 1;
                    off.x = target * step;
                    // Animation mượt: view (fbcap từ daemon, có entitlement global/secure-capture)
                    // giờ chụp được cả lúc chuyển trang mà KHÔNG đen → animate lại cho đẹp.
                    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut
                                     animations:^{ sv.contentOffset = off; } completion:nil];
                    diag = [NSString stringWithFormat:@"OK page %d/%d", target + 1, numPages];
                    return;
                }

                // Quán tính: dur nhỏ → mom lớn → văng xa; dur lớn → gần đúng quãng kéo. Hệ số 0.35
                // (rộng hơn 0.21 cũ) để dur ĐỔI quãng RÕ RÀNG. Không truyền dur → 0.3s.
                double du = (dur > 0.01) ? dur : 0.3;
                du = MAX(0.05, MIN(3.0, du));
                CGFloat mom = 1.0 + 0.35 / du;            // dur 0.1→4.5 · 0.3→2.17 · 1.0→1.35
                if (mom > 6.0) mom = 6.0;
                CGFloat maxX = sv.contentSize.width - sv.bounds.size.width + ins.right;
                CGFloat maxY = sv.contentSize.height - sv.bounds.size.height + ins.bottom;
                // finger lên (dy<0) → content offset TĂNG (cuộn xuống): contentD = -fingerD × mom
                CGPoint raw = CGPointMake(start.x - dx * mom, start.y - dy * mom);
                off.x = MAX(-ins.left, MIN(raw.x, maxX));
                off.y = MAX(-ins.top, MIN(raw.y, maxY));
                CGFloat dist = hypot(off.x - start.x, off.y - start.y);
                // ANIMATE giảm tốc (easeOut): xa hơn → lâu hơn → cảm giác "văng rồi dừng" như vuốt thật,
                // thay vì NHẢY tức thời (animated:NO cũ trông như dịch lớp + không cảm nhận được dur).
                NSTimeInterval animDur = MAX(0.28, MIN(1.3, dist / 2200.0 + 0.22));
                [sv.layer removeAllAnimations];
                [UIView animateWithDuration:animDur delay:0
                                    options:(UIViewAnimationOptionCurveEaseOut |
                                             UIViewAnimationOptionAllowUserInteraction |
                                             UIViewAnimationOptionBeginFromCurrentState)
                                 animations:^{ sv.contentOffset = off; } completion:nil];
                diag = [NSString stringWithFormat:
                        @"OK scroll=%@ durInput=%.3f mom=%.2f delta=(%.0f,%.0f) offset=(%.0f,%.0f)->(%.0f,%.0f) animDur=%.2f",
                        NSStringFromClass(v.class), dur, mom, off.x - start.x, off.y - start.y,
                        start.x, start.y, off.x, off.y, animDur];
                return;
            }

            // 2) Không tìm thấy UIScrollView đúng trục:
            //    - App thường: cử chỉ synthetic (pan tuỳ biến / game) để vẫn có tác dụng.
            //    - SpringBoard: accessibilityScroll (bỏ qua dur theo thiết kế UIKit).
            if (!isSB) {
                IADoSwipeSendEvent(a, b, dur);
                diag = [NSString stringWithFormat:@"OK swipe-synthetic durInput=%.3f finger=(%.1f,%.1f)", dur, dx, dy];
                return;
            }
            UIAccessibilityScrollDirection dir;
            if (wantV) dir = (dy < 0) ? UIAccessibilityScrollDirectionDown : UIAccessibilityScrollDirectionUp;
            else dir = (dx < 0) ? UIAccessibilityScrollDirectionRight : UIAccessibilityScrollDirectionLeft;
            for (UIView *v = hit ?: win; v && v != win.superview; v = v.superview) {
                if ([v respondsToSelector:@selector(accessibilityScroll:)] && [v accessibilityScroll:dir]) {
                    diag = [NSString stringWithFormat:@"OK ax-scroll dir=%ld %@ durIgnored=1", (long)dir, NSStringFromClass(v.class)];
                    return;
                }
            }
            diag = @"OK sb no-scrollable";
        } @catch (NSException *e) { diag = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// Tìm SBIconScrollView (scroll view phân trang icon của SpringBoard) trong cây view.
static UIScrollView *IAFindIconScroll(UIView *v) {
    if ([v isKindOfClass:UIScrollView.class] &&
        [NSStringFromClass(v.class) isEqualToString:@"SBIconScrollView"])
        return (UIScrollView *)v;
    for (UIView *s in v.subviews) { UIScrollView *r = IAFindIconScroll(s); if (r) return r; }
    return nil;
}

// ---- HOME: về màn hình chính (app foreground tự suspend, giống bấm Home) ----
static NSString *IAHome(void) {
    // SpringBoard đã là màn chính → cuộn về TRANG ĐẦU (như bấm Home khi đã ở home screen).
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        __block NSString *d = @"OK home (sb)";
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                // Về TRANG ĐẦU: tìm SBIconScrollView (đúng view mà vuốt màn chính dùng)
                // rồi cuộn offset về (0,0) — trang icon đầu tiên. Cơ chế đã chứng minh chạy.
                UIWindow *win = IAActiveWindow();
                UIScrollView *sv = win ? IAFindIconScroll(win) : nil;
                if (sv) {
                    [sv setContentOffset:CGPointZero animated:YES];
                    d = @"OK home first-page";
                } else d = @"OK home (sb no-iconscroll)";
            } @catch (NSException *e) { d = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
        });
        return d;
    }
    __block NSString *diag = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            if ([app respondsToSelector:@selector(suspend)]) {
                [app performSelector:@selector(suspend)];
                diag = @"OK home";
            } else diag = @"ERR không có suspend";
        } @catch (NSException *e) { diag = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// ---- APP SWITCHER: bấm Home 2 lần → mở trình chuyển app (chỉ trong SpringBoard) ----
// Thử nhiều selector qua reflection (an toàn: respondsToSelector); dump selector ứng viên ra
// /var/jb/tmp/iaswitcher.txt để chốt API nếu chưa trúng.
static NSString *IASwitcher(void) {
    __block NSString *diag = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            // Dump ứng viên (chẩn đoán)
            NSMutableString *dump = [NSMutableString string];
            unsigned int im = 0; Method *ims = class_copyMethodList([app class], &im);
            for (unsigned i = 0; i < im; i++) { const char *sn = sel_getName(method_getName(ims[i]));
                if (sn && (strcasestr(sn, "switch") || strcasestr(sn, "menudouble") || strcasestr(sn, "menubutton") || strcasestr(sn, "appswitch"))) [dump appendFormat:@"SB -%s\n", sn]; }
            free(ims);
            Class uiCls = NSClassFromString(@"SBUIController");
            if (uiCls) { unsigned int um = 0; Method *ums = class_copyMethodList(uiCls, &um);
                for (unsigned i = 0; i < um; i++) { const char *sn = sel_getName(method_getName(ums[i]));
                    if (sn && (strcasestr(sn, "switch") || strcasestr(sn, "menu"))) [dump appendFormat:@"SBUIController -%s\n", sn]; } free(ums); }
            [dump writeToFile:@"/var/jb/tmp/iaswitcher.txt" atomically:NO encoding:NSUTF8StringEncoding error:nil];

            // 0) Handler mở App Switcher (shortcut) — nhận 1 tham số, gọi với nil.
            for (NSString *ss in @[@"_handleOpenAppSwitcherShortcut:"]) {
                SEL s = NSSelectorFromString(ss);
                if ([app respondsToSelector:s]) { ((void (*)(id, SEL, id))objc_msgSend)(app, s, nil); diag = [@"OK switcher shortcut " stringByAppendingString:ss]; return; }
            }
            // 1) SpringBoard (double-home handler)
            for (NSString *ss in @[@"_handleMenuDoubleTap", @"handleMenuDoubleTap", @"_handleMenuButtonDoubleTap", @"_toggleSwitcher", @"_showSwitcher", @"activateSwitcher"]) {
                SEL s = NSSelectorFromString(ss);
                if ([app respondsToSelector:s]) { ((void (*)(id, SEL))objc_msgSend)(app, s); diag = [@"OK switcher app " stringByAppendingString:ss]; return; }
            }
            // 2) SBUIController
            id ctrl = (uiCls && [uiCls respondsToSelector:@selector(sharedInstance)]) ? ((id (*)(id, SEL))objc_msgSend)(uiCls, @selector(sharedInstance)) : nil;
            for (NSString *ss in @[@"_toggleSwitcher", @"toggleSwitcher", @"activateSwitcher"]) {
                SEL s = NSSelectorFromString(ss);
                if (ctrl && [ctrl respondsToSelector:s]) { ((void (*)(id, SEL))objc_msgSend)(ctrl, s); diag = [@"OK switcher ui " stringByAppendingString:ss]; return; }
            }
            diag = @"ERR no-switcher-api (xem /var/jb/tmp/iaswitcher.txt)";
        } @catch (NSException *e) { diag = [@"ERR sw " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// ---- Chụp NHANH cả màn qua CARenderServer (tầng render-server, ~10-30ms) ----
// Chỉ ĐỌC ảnh composite của display → an toàn tuyệt đối (không HID, không backboardd).
// Chụp được toàn màn (kể cả app foreground) khi chạy trong SpringBoard.
// Trả UIImage full-res, hoặc nil nếu không khả dụng (sandbox app chặn) → fallback composite.
typedef void (*CARSRenderDisplayFn)(uint32_t, CFStringRef, IOSurfaceRef, int32_t, int32_t);
static UIImage *IACaptureCARender(void) {
    static dispatch_once_t once; static CARSRenderDisplayFn pRender = NULL;
    static id gSurfLock; static dispatch_once_t lo; dispatch_once(&lo, ^{ gSurfLock = [NSObject new]; });
    dispatch_once(&once, ^{ pRender = (CARSRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay"); });
    if (!pRender) return nil;
    @synchronized (gSurfLock) {   // gSurf tái dùng → serialize (shot-stream thread vs screenshot/OCR)

    CGFloat sc = [UIScreen mainScreen].scale;
    CGSize pt = [UIScreen mainScreen].bounds.size;
    size_t w = (size_t)(pt.width * sc), h = (size_t)(pt.height * sc);
    if (w == 0 || h == 0) return nil;

    // TÁI DÙNG 1 IOSurface (SHOT gọi liên tục khi stream) — tránh cấp phát/giải phóng mỗi khung.
    // Chỉ tạo lại khi kích thước đổi (xoay màn). Không thread-safe tuyệt đối nhưng SHOT chạy
    // tuần tự trên 1 socket thread nên an toàn.
    static IOSurfaceRef gSurf = NULL; static size_t gW = 0, gH = 0;
    if (!gSurf || gW != w || gH != h) {
        if (gSurf) { CFRelease(gSurf); gSurf = NULL; }
        size_t bpe = 4;
        size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * bpe);
        size_t total = IOSurfaceAlignProperty(kIOSurfaceAllocSize, h * bpr);
        NSDictionary *props = @{
            (__bridge id)kIOSurfaceWidth: @(w),
            (__bridge id)kIOSurfaceHeight: @(h),
            (__bridge id)kIOSurfaceBytesPerElement: @(bpe),
            (__bridge id)kIOSurfaceBytesPerRow: @(bpr),
            (__bridge id)kIOSurfaceAllocSize: @(total),
            (__bridge id)kIOSurfacePixelFormat: @((uint32_t)0x42475241),  // 'BGRA'
        };
        gSurf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        gW = w; gH = h;
    }
    IOSurfaceRef surf = gSurf;
    if (!surf) return nil;

    pRender(0, CFSTR("LCD"), surf, 0, 0);   // render display "LCD" vào surface

    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surf);
    size_t sbpr = IOSurfaceGetBytesPerRow(surf);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bmp = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = base ? CGBitmapContextCreate(base, w, h, 8, sbpr, cs, bmp) : NULL;
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;

    // Thu nhỏ ~0.7 điểm ngay bằng CoreGraphics (thread-safe → không cần main thread,
    // SpringBoard không giật). Ảnh nhỏ → JPEG nhẹ, stream nhanh.
    UIImage *img = nil;
    if (cg) {
        size_t tw = (size_t)(pt.width * 0.7), th = (size_t)(pt.height * 0.7);
        if (tw < 1) tw = 1; if (th < 1) th = 1;
        CGContextRef dctx = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs, bmp);
        if (dctx) {
            CGContextSetInterpolationQuality(dctx, kCGInterpolationLow);
            CGContextDrawImage(dctx, CGRectMake(0, 0, tw, th), cg);
            CGImageRef small = CGBitmapContextCreateImage(dctx);
            if (small) { img = [UIImage imageWithCGImage:small]; CGImageRelease(small); }
            CGContextRelease(dctx);
        }
    }
    if (cg) CGImageRelease(cg);
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    // KHÔNG CFRelease(surf): tái dùng cho khung sau (gSurf giữ nó).
    return img;
    }   // @synchronized(gSurfLock)
}

// ---- Chụp FRAMEBUFFER THẬT (như TrollVNC): IOMobileFramebuffer + IOSurfaceAccelerator ----
// Đọc output vật lý đang scan-out → KHÔNG đen khi SpringBoard chuyển trang (khác CARenderServer
// phải re-render). dlsym để tránh link private framework (nguy cơ dyld SpringBoard từ chối).
typedef struct __IOMobileFramebuffer *IAMFBRef;
typedef struct __IOSurfaceAccelerator *IAAccelRef;
typedef int (*IAMFBMainFn)(IAMFBRef *);
typedef int (*IAMFBSurfFn)(IAMFBRef, int, IOSurfaceRef *);
typedef int (*IAAccelCreateFn)(CFAllocatorRef, void *, IAAccelRef *);
typedef int (*IAAccelXferFn)(IAAccelRef, IOSurfaceRef, IOSurfaceRef, CFDictionaryRef, void *);
static UIImage *IACaptureFramebuffer(void) {
    static dispatch_once_t once;
    static IAMFBMainFn pMain = NULL; static IAMFBSurfFn pSurf = NULL;
    static IAAccelCreateFn pACreate = NULL; static IAAccelXferFn pXfer = NULL;
    static IAMFBRef fb = NULL; static IAAccelRef accel = NULL;
    static id lock;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator", RTLD_LAZY);
        pMain = (IAMFBMainFn)dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetMainDisplay");
        pSurf = (IAMFBSurfFn)dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetLayerDefaultSurface");
        pACreate = (IAAccelCreateFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorCreate");
        pXfer = (IAAccelXferFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorTransferSurface");
        if (pMain) pMain(&fb);
        if (pACreate) pACreate(kCFAllocatorDefault, NULL, &accel);
    });
    if (!pSurf || !pXfer || !fb || !accel) return nil;
    @synchronized (lock) {
        @try {
            IOSurfaceRef screen = NULL;
            if (pSurf(fb, 0, &screen) != 0 || !screen) return nil;
            size_t w = IOSurfaceGetWidth(screen), h = IOSurfaceGetHeight(screen);
            if (!w || !h) return nil;
            static IOSurfaceRef dest = NULL; static size_t dw = 0, dh = 0;
            if (!dest || dw != w || dh != h) {
                if (dest) { CFRelease(dest); dest = NULL; }
                size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4);
                size_t tot = IOSurfaceAlignProperty(kIOSurfaceAllocSize, h * bpr);
                NSDictionary *props = @{ (__bridge id)kIOSurfaceWidth:@(w), (__bridge id)kIOSurfaceHeight:@(h),
                    (__bridge id)kIOSurfaceBytesPerElement:@(4), (__bridge id)kIOSurfaceBytesPerRow:@(bpr),
                    (__bridge id)kIOSurfaceAllocSize:@(tot), (__bridge id)kIOSurfacePixelFormat:@((uint32_t)0x42475241) };
                dest = IOSurfaceCreate((__bridge CFDictionaryRef)props); dw = w; dh = h;
            }
            if (!dest) return nil;
            if (pXfer(accel, screen, dest, NULL, NULL) != 0) return nil;   // copy/detile framebuffer
            IOSurfaceLock(dest, kIOSurfaceLockReadOnly, NULL);
            void *base = IOSurfaceGetBaseAddress(dest); size_t sbpr = IOSurfaceGetBytesPerRow(dest);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGBitmapInfo bmp = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
            CGContextRef ctx = base ? CGBitmapContextCreate(base, w, h, 8, sbpr, cs, bmp) : NULL;
            CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
            UIImage *img = nil;
            if (cg) {
                CGSize pt = [UIScreen mainScreen].bounds.size;
                size_t tw = (size_t)(pt.width * 0.7), th = (size_t)(pt.height * 0.7);
                if (tw < 1) tw = 1; if (th < 1) th = 1;
                CGContextRef dctx = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs, bmp);
                if (dctx) { CGContextSetInterpolationQuality(dctx, kCGInterpolationLow); CGContextDrawImage(dctx, CGRectMake(0, 0, tw, th), cg);
                    CGImageRef s = CGBitmapContextCreateImage(dctx); if (s) { img = [UIImage imageWithCGImage:s]; CGImageRelease(s); } CGContextRelease(dctx); }
            }
            if (cg) CGImageRelease(cg); if (ctx) CGContextRelease(ctx); CGColorSpaceRelease(cs);
            IOSurfaceUnlock(dest, kIOSurfaceLockReadOnly, NULL);
            return img;
        } @catch (__unused NSException *e) { return nil; }
    }
}

// ---- SHOT: chụp màn ----
static NSString *IAShot(void) {
    // 1) NHANH: CARenderServer — cả màn ở tầng render-server, chạy NGOÀI main thread
    //    (chỉ CoreGraphics/IOSurface, không đụng UIKit) → SpringBoard không giật.
    @try {
        UIImage *fast = IACaptureCARender();
        if (fast) {
            NSData *jpg = UIImageJPEGRepresentation(fast, 0.5);
            if (jpg.length) {
                NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iashot.jpg"];
                if ([jpg writeToFile:path atomically:NO])
                    return [@"OK shot " stringByAppendingString:path];
            }
        }
    } @catch (NSException *e) { /* rơi xuống fallback */ }

    // 2) FALLBACK: composite cửa sổ (khi CARenderServer bị sandbox app chặn) — cần main thread.
    __block NSString *out = @"ERR no-window";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = IAActiveWindow();
            if (!w) return;
            CGSize sz = [UIScreen mainScreen].bounds.size;
            // GHÉP tất cả cửa sổ của scene (wallpaper+icon home screen ở nhiều cửa sổ),
            // theo windowLevel tăng dần; bỏ FX overlay của mình. NHANH: opaque + JPEG.
            NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
            UIWindowScene *scene = w.windowScene;
            if (scene) for (UIWindow *cand in scene.windows) {
                if (cand == gFxWindow || cand.hidden || cand.alpha < 0.01) continue;  // BỎ FX overlay khỏi ảnh (web không thấy chấm/mũi tên; iPhone vẫn hiện)
                [wins addObject:cand];
            }
            if (wins.count == 0) [wins addObject:w];
            [wins sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
            }];
            // scale 0.7 + JPEG nhẹ → ảnh nhỏ, tải nhanh (toạ độ click theo tỉ lệ nên không ảnh hưởng).
            UIGraphicsBeginImageContextWithOptions(sz, YES, 0.7);
            for (UIWindow *win in wins)
                [win drawViewHierarchyInRect:CGRectMake(0, 0, sz.width, sz.height) afterScreenUpdates:NO];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iashot.jpg"];
            BOOL ok = [UIImageJPEGRepresentation(img, 0.38) writeToFile:path atomically:NO];
            out = ok ? [@"OK shot " stringByAppendingString:path] : @"ERR write-fail";
        } @catch (NSException *e) { out = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return out;
}

// ---- APPEARANCE: đổi Dark Mode (mode: 0=theo hệ thống, 1=sáng, 2=tối) ----
// AN TOÀN TUYỆT ĐỐI — KHÔNG BAO GIỜ crash SpringBoard (README cấm route làm hỏng JB):
//   Tier A (public): overrideUserInterfaceStyle trên cửa sổ process hiện tại — luôn chạy.
//   Tier B (private, CHỈ trong SpringBoard): private API UISUserInterfaceStyleMode +
//     UIScreen -_setUserInterfaceStyleMode: để đổi CẢ HỆ THỐNG. Bọc reflection đầy đủ
//     (NSClassFromString + respondsToSelector + @try) → thiếu selector thì bỏ qua, KHÔNG crash.
// Reply cho biết Tier B chạy chưa: "... system=applied" / "system=unavailable" (để verify an toàn).
static NSString *IAAppearance(int mode) {
    __block NSString *diag = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSMutableString *r = [NSMutableString stringWithString:@"OK"];

            // --- Tier A: đổi giao diện các cửa sổ của CHÍNH process (public, không thể crash) ---
            UIUserInterfaceStyle s = (mode == 1) ? UIUserInterfaceStyleLight
                                   : (mode == 2) ? UIUserInterfaceStyleDark
                                                 : UIUserInterfaceStyleUnspecified;
            NSUInteger nw = 0;
            // iOS 15: duyệt qua UIWindowScene.windows (UIApplication.windows đã deprecated).
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    @try { w.overrideUserInterfaceStyle = s; nw++; } @catch (__unused NSException *e) {}
                }
            }
            [r appendFormat:@" win=%lu", (unsigned long)nw];

            // --- Tier B: đổi Dark Mode TOÀN HỆ THỐNG (chỉ khi chạy trong SpringBoard) ---
            // API đã VERIFY qua SDIAG trên máy thật iOS 15.8.8:
            //   [UIUserInterfaceStyleArbiter sharedInstance] (KHÔNG gạch dưới)
            //     -currentStyle (1=sáng,2=tối) · -toggleCurrentStyle (đảo sáng↔tối).
            //   Fallback: UIApplication -_setSystemUserInterfaceStyle:.
            //   (mode 1=sáng, 2=tối; 0=theo hệ thống hiện bỏ qua — app-level đã xử lý.)
            BOOL isSB = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
            if (isSB && mode != 0) {
                NSInteger want = (mode == 2) ? 2 : 1;   // UIUserInterfaceStyle: 1 light, 2 dark
                Class arbCls = NSClassFromString(@"UIUserInterfaceStyleArbiter");
                SEL sharedSel = NSSelectorFromString(@"sharedInstance");
                id arb = (arbCls && [arbCls respondsToSelector:sharedSel])
                    ? ((id (*)(id, SEL))objc_msgSend)(arbCls, sharedSel) : nil;
                SEL curSel = NSSelectorFromString(@"currentStyle");
                SEL togSel = NSSelectorFromString(@"toggleCurrentStyle");
                if (arb && [arb respondsToSelector:curSel] && [arb respondsToSelector:togSel]) {
                    NSInteger cur = ((NSInteger (*)(id, SEL))objc_msgSend)(arb, curSel);
                    if (cur != want) ((void (*)(id, SEL))objc_msgSend)(arb, togSel);
                    NSInteger now = ((NSInteger (*)(id, SEL))objc_msgSend)(arb, curSel);
                    [r appendFormat:@" system=arbiter(%ld->%ld)", (long)cur, (long)now];
                } else {
                    // Fallback: đặt thẳng trên UIApplication
                    UIApplication *app = [UIApplication sharedApplication];
                    SEL setSys = NSSelectorFromString(@"_setSystemUserInterfaceStyle:");
                    if ([app respondsToSelector:setSys]) {
                        ((void (*)(id, SEL, NSInteger))objc_msgSend)(app, setSys, want);
                        [r appendString:@" system=appSetSys"];
                    } else [r appendString:@" system=unavailable"];
                }
            } else if (isSB) {
                [r appendString:@" system=auto-skip"];
            }
            diag = r;
        } @catch (NSException *e) { diag = [@"ERR appear " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return diag;
}

// ---- SDIAG: dump runtime để tìm đúng API đổi appearance hệ thống (ghi ra file) ----
static NSString *IADiag(void) {
    __block NSString *res = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSMutableString *r = [NSMutableString string];
            [r appendFormat:@"bundle=%@\n", [[NSBundle mainBundle] bundleIdentifier] ?: @"?"];

            unsigned int n = 0; Ivar *iv = class_copyIvarList([UIScreen class], &n);
            [r appendString:@"UIScreen ivars(rbiter/tyle):\n"];
            for (unsigned i = 0; i < n; i++) { const char *nm = ivar_getName(iv[i]); if (nm && (strstr(nm, "rbiter") || strstr(nm, "tyle"))) [r appendFormat:@"  %s\n", nm]; }
            free(iv);

            unsigned int m = 0; Method *me = class_copyMethodList([UIScreen class], &m);
            [r appendString:@"UIScreen methods(rbiter/tyleMode):\n"];
            for (unsigned i = 0; i < m; i++) { const char *sn = sel_getName(method_getName(me[i])); if (sn && (strstr(sn, "rbiter") || strstr(sn, "tyleMode"))) [r appendFormat:@"  %s\n", sn]; }
            free(me);

            // UIApplication methods liên quan style hệ thống
            unsigned int am = 0; Method *ame = class_copyMethodList([UIApplication class], &am);
            [r appendString:@"UIApplication methods(ystemUserInterface/tyleMode):\n"];
            for (unsigned i = 0; i < am; i++) { const char *sn = sel_getName(method_getName(ame[i])); if (sn && (strstr(sn, "ystemUserInterface") || strstr(sn, "tyleMode"))) [r appendFormat:@"  %s\n", sn]; }
            free(ame);

            // Dump đầy đủ method của các class MỤC TIÊU để chốt API đổi appearance hệ thống.
            const char *targets[] = {"UIUserInterfaceStyleArbiter", "UISUserInterfaceStyleMode", "UISCurrentUserInterfaceStyleValue", "UIApplication"};
            for (int t = 0; t < 4; t++) {
                BOOL isApp = (strcmp(targets[t], "UIApplication") == 0);
                Class c = objc_getClass(targets[t]);
                [r appendFormat:@"\n== %s (exists=%d) ==\n", targets[t], c ? 1 : 0];
                if (!c) continue;
                unsigned int km = 0; Method *kme = class_copyMethodList(object_getClass(c), &km);
                [r appendString:@" +class:\n"];
                for (unsigned j = 0; j < km; j++) { const char *sn = sel_getName(method_getName(kme[j])); if (!isApp || strstr(sn, "tyle") || strstr(sn, "rbiter")) [r appendFormat:@"  +%s\n", sn]; }
                free(kme);
                unsigned int im = 0; Method *ime = class_copyMethodList(c, &im);
                [r appendString:@" -inst:\n"];
                for (unsigned j = 0; j < im; j++) { const char *sn = sel_getName(method_getName(ime[j])); if (!isApp || strstr(sn, "tyle")) [r appendFormat:@"  -%s\n", sn]; }
                free(ime);
            }

            NSString *p = @"/var/jb/tmp/iadiag.txt";
            [r writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
            res = [@"OK wrote " stringByAppendingString:p];
        } @catch (NSException *e) { res = [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return res;
}

// ================= DUMP: xuất cây UIView của app foreground thành XML =================
// Chạy TRONG app foreground (in-process) nên đọc được TOÀN BỘ view hierarchy thật —
// giống "page source" của Appium. Ghi ra file tmp (như SHOT), daemon đọc & trả về.
// Toạ độ theo POINT trong hệ quy chiếu cửa sổ (convertRect:toView:nil) — TRÙNG hệ toạ độ
// mà TAP/hitTest dùng → có thể tap thẳng theo x/y trong XML.

// Escape ký tự đặc biệt XML cho giá trị thuộc tính.
static void IAXmlEsc(NSString *s, NSMutableString *out) {
    if (!s) return;
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '&': [out appendString:@"&amp;"]; break;
            case '<': [out appendString:@"&lt;"];  break;
            case '>': [out appendString:@"&gt;"];  break;
            case '"': [out appendString:@"&quot;"];break;
            case '\n': case '\r': case '\t': [out appendString:@" "]; break;
            default: if (c >= 0x20) [out appendFormat:@"%C", c]; break;
        }
    }
}
// Thêm 1 thuộc tính (bỏ qua nếu rỗng).
static void IAAttr(NSMutableString *xml, NSString *key, NSString *val) {
    if (![val isKindOfClass:NSString.class] || val.length == 0) return;
    [xml appendFormat:@" %@=\"", key];
    IAXmlEsc(val, xml);
    [xml appendString:@"\""];
}
// Lấy text hiển thị của view (label/textfield/textview/button).
static NSString *IANodeText(UIView *v) {
    @try {
        if ([v isKindOfClass:UILabel.class])     return ((UILabel *)v).text;
        if ([v isKindOfClass:UITextField.class]) return ((UITextField *)v).text;
        if ([v isKindOfClass:UITextView.class])  return ((UITextView *)v).text;
        if ([v isKindOfClass:UIButton.class])    return ((UIButton *)v).currentTitle;
    } @catch (__unused NSException *e) {}
    return nil;
}
// Chuẩn hoá LOẠI phần tử giống XCUIElementType của WebDriverAgent (ngắn, semantic) —
// để script viết selector theo loại ("Button"/"Cell"…) thay vì tên class Obj-C dài.
// Thứ tự KIỂM TRA quan trọng: lớp con phải đứng trước lớp cha (Cell/Table trước ScrollView).
static NSString *IANodeType(UIView *v) {
    if ([v isKindOfClass:UIButton.class])             return @"Button";
    if ([v isKindOfClass:UILabel.class])              return @"StaticText";
    if ([v isKindOfClass:UITextField.class])          return @"TextField";
    if ([v isKindOfClass:UITextView.class])           return @"TextView";
    if ([v isKindOfClass:UISwitch.class])             return @"Switch";
    if ([v isKindOfClass:UISlider.class])             return @"Slider";
    if ([v isKindOfClass:UIImageView.class])          return @"Image";
    if ([v isKindOfClass:UITableViewCell.class])      return @"Cell";
    if ([v isKindOfClass:UICollectionViewCell.class]) return @"Cell";
    if ([v isKindOfClass:UITableView.class])          return @"Table";
    if ([v isKindOfClass:UICollectionView.class])     return @"CollectionView";
    if ([v isKindOfClass:UIScrollView.class])         return @"ScrollView";
    if ([v isKindOfClass:UINavigationBar.class])      return @"NavigationBar";
    if ([v isKindOfClass:UIControl.class])            return @"Control";
    return nil;
}
// Lấy phần tử ACCESSIBILITY con (UIView hoặc UIAccessibilityElement). Ưu tiên accessibilityElements,
// nếu không có dùng accessibilityElementCount/AtIndex:. WebKit phơi NỘI DUNG HTML qua đây khi
// accessibility bật (IAEnableAX) → nhờ đó dump lấy được chữ trong WebView.
static NSArray *IAAXChildren(id el) {
    @try {
        if ([el respondsToSelector:@selector(accessibilityElements)]) {
            NSArray *a = [el accessibilityElements];
            if ([a isKindOfClass:NSArray.class] && a.count) return a;
        }
    } @catch (__unused NSException *e) {}
    NSMutableArray *r = [NSMutableArray array];
    @try {
        if ([el respondsToSelector:@selector(accessibilityElementCount)]) {
            NSInteger n = [el accessibilityElementCount];
            if (n > 800) n = 800;
            for (NSInteger i = 0; i < n; i++) { id c = [el accessibilityElementAtIndex:i]; if (c) [r addObject:c]; }
        }
    } @catch (__unused NSException *e) {}
    return r;
}
// Đệ quy phần tử accessibility KHÔNG phải UIView → <ax ...> (label/value + accessibilityFrame điểm màn).
static void IADumpAX(id el, NSMutableString *xml, int depth, int index, int *pCount) {
    if (!el || depth > 90 || xml.length > 1024 * 1024 || *pCount > 9000) return;
    (*pCount)++;
    NSString *cls = NSStringFromClass([el class]) ?: @"AX";
    CGRect f = CGRectZero;
    @try { if ([el respondsToSelector:@selector(accessibilityFrame)]) f = [el accessibilityFrame]; } @catch (__unused NSException *e) {}
    NSString *label = nil, *val = nil;
    @try { if ([el respondsToSelector:@selector(accessibilityLabel)]) label = [el accessibilityLabel]; } @catch (__unused NSException *e) {}
    @try { if ([el respondsToSelector:@selector(accessibilityValue)]) { id vv = [el accessibilityValue]; if ([vv isKindOfClass:NSString.class]) val = vv; } } @catch (__unused NSException *e) {}
    BOOL acc = NO;
    @try { if ([el respondsToSelector:@selector(isAccessibilityElement)]) acc = [el isAccessibilityElement]; } @catch (__unused NSException *e) {}
    for (int i = 0; i < depth; i++) [xml appendString:@"  "];
    [xml appendString:@"<ax"];
    IAAttr(xml, @"class", cls);
    [xml appendFormat:@" index=\"%d\" x=\"%d\" y=\"%d\" w=\"%d\" h=\"%d\"", index,
        (int)lround(f.origin.x), (int)lround(f.origin.y),
        (int)lround(f.size.width), (int)lround(f.size.height)];
    IAAttr(xml, @"label", label);
    IAAttr(xml, @"value", val);
    [xml appendFormat:@" accessible=\"%d\"", acc ? 1 : 0];
    NSMutableArray *kids = [NSMutableArray array];
    for (id c in IAAXChildren(el)) if (![c isKindOfClass:UIView.class]) [kids addObject:c];
    if (kids.count == 0) { [xml appendString:@"/>\n"]; return; }
    [xml appendString:@">\n"];
    int ki = 0;
    for (id c in kids) IADumpAX(c, xml, depth + 1, ki++, pCount);
    for (int i = 0; i < depth; i++) [xml appendString:@"  "];
    [xml appendString:@"</ax>\n"];
}

// Đệ quy 1 node. Dùng element <node class="..."> để hợp lệ XML với MỌI tên class.
static void IADumpNode(UIView *v, NSMutableString *xml, int depth, int index, int *pCount) {
    if (!v || depth > 60 || xml.length > 1024 * 1024 || *pCount > 6000) return;
    (*pCount)++;
    NSString *cls = NSStringFromClass(v.class) ?: @"UIView";
    CGRect f;
    @try { f = [v convertRect:v.bounds toView:nil]; } @catch (__unused NSException *e) { f = v.frame; }
    BOOL vis = !v.hidden && v.alpha > 0.01 && f.size.width > 0 && f.size.height > 0;

    for (int i = 0; i < depth; i++) [xml appendString:@"  "];
    [xml appendString:@"<node"];
    IAAttr(xml, @"class", cls);
    IAAttr(xml, @"type", IANodeType(v));   // loại chuẩn hoá kiểu XCUIElementType (nếu nhận diện được)
    [xml appendFormat:@" index=\"%d\" x=\"%d\" y=\"%d\" w=\"%d\" h=\"%d\"", index,
        (int)lround(f.origin.x), (int)lround(f.origin.y),
        (int)lround(f.size.width), (int)lround(f.size.height)];
    IAAttr(xml, @"text", IANodeText(v));
    @try { IAAttr(xml, @"label", v.accessibilityLabel); } @catch (__unused NSException *e) {}
    @try { if ([v.accessibilityValue isKindOfClass:NSString.class]) IAAttr(xml, @"value", (NSString *)v.accessibilityValue); } @catch (__unused NSException *e) {}
    @try { IAAttr(xml, @"id", v.accessibilityIdentifier); } @catch (__unused NSException *e) {}
    @try { [xml appendFormat:@" accessible=\"%d\"", v.isAccessibilityElement ? 1 : 0]; } @catch (__unused NSException *e) {}
    if ([v isKindOfClass:UIControl.class]) [xml appendFormat:@" enabled=\"%d\"", ((UIControl *)v).enabled ? 1 : 0];
    @try {
        if (v.gestureRecognizers.count) {
            NSMutableArray *g = [NSMutableArray array];
            for (UIGestureRecognizer *r in v.gestureRecognizers) [g addObject:NSStringFromClass(r.class)];
            IAAttr(xml, @"gr", [g componentsJoinedByString:@","]);
        }
    } @catch (__unused NSException *e) {}
    [xml appendFormat:@" visible=\"%d\"", vis ? 1 : 0];

    NSArray *subs = v.subviews;
    // Phần tử accessibility con KHÔNG phải UIView (nội dung WebView/custom) — để lấy TOÀN BỘ text.
    NSMutableArray *axk = [NSMutableArray array];
    @try { for (id c in IAAXChildren(v)) if (![c isKindOfClass:UIView.class]) [axk addObject:c]; }
    @catch (__unused NSException *e) {}
    if (subs.count == 0 && axk.count == 0) { [xml appendString:@"/>\n"]; return; }
    [xml appendString:@">\n"];
    int ci = 0;
    for (UIView *s in subs) {
        if (s == gFxWindow) continue;   // bỏ overlay FX của mình
        IADumpNode(s, xml, depth + 1, ci++, pCount);
    }
    for (id c in axk) IADumpAX(c, xml, depth + 1, ci++, pCount);
    for (int i = 0; i < depth; i++) [xml appendString:@"  "];
    [xml appendString:@"</node>\n"];
}
static NSString *IADump(void) {
    IAEnableAX();   // bật automation-accessibility → WebKit dựng cây AX (lấy được chữ trong WebView)
    __block NSString *res = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSMutableString *xml = [NSMutableString stringWithCapacity:64 * 1024];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            UIWindow *key = IAActiveWindow();
            CGSize scr = [UIScreen mainScreen].bounds.size;
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
            [xml appendFormat:@"<screen bundle=\"%@\" w=\"%d\" h=\"%d\">\n", bid, (int)scr.width, (int)scr.height];
            // Duyệt mọi cửa sổ của scene theo windowLevel tăng dần (khớp thứ tự hiển thị).
            NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
            UIWindowScene *scene = key.windowScene;
            if (scene) for (UIWindow *w in scene.windows) { if (w == gFxWindow || w.hidden) continue; [wins addObject:w]; }
            if (wins.count == 0 && key) [wins addObject:key];
            [wins sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
            }];
            int count = 0, wi = 0;
            for (UIWindow *w in wins) IADumpNode(w, xml, 1, wi++, &count);
            [xml appendString:@"</screen>\n"];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iadump.xml"];
            if ([xml writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil])
                res = [@"OK dump " stringByAppendingString:path];
            else res = @"ERR write-fail";
        } @catch (NSException *e) { res = [@"ERR dump " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return res;
}

// ================= OCR: nhận dạng chữ trên màn qua Vision =================
// Chụp full-res qua CARenderServer (cả màn, kể cả app foreground — khi chạy TRONG SpringBoard),
// rồi VNRecognizeTextRequest on-device. CHẠY TRÊN SOCKET THREAD (không đụng main) → SpringBoard
// KHÔNG giật. Toạ độ trả theo POINT (khớp hệ toạ độ TAP) để tap thẳng vào chữ.

// Escape chuỗi cho JSON (UTF-8 viết thẳng, chỉ escape ký tự điều khiển + " \).
static void IAJsonEsc(NSString *s, NSMutableString *out) {
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default: if (c < 0x20) [out appendFormat:@"\\u%04x", c]; else [out appendFormat:@"%C", c]; break;
        }
    }
}
// (Bỏ IACaptureCGFull: OCR không dùng CARenderServer nữa — chụp UI app bằng drawViewHierarchy
//  trong IAOcr vì Vision/ANE không được chạy trong SpringBoard.)
// Lõi Vision: nhận CGImage + kích thước POINT của màn (W,H) → JSON {text,x,y,...} ghi file,
// trả "OK ocr <path>". Chạy trong tiến trình APP (ANE ok); KHÔNG gọi trong SpringBoard.
// regionPt: vùng GIỚI HẠN nhận dạng (point màn, gốc trên-trái; w/h<=0 = toàn màn) — map sang
// Vision regionOfInterest (chuẩn hoá, gốc dưới-trái) → vùng nhỏ nhận dạng nhanh hơn NHIỀU.
static NSString *IARunOCROnCG(CGImageRef cg, CGFloat W, CGFloat H, NSString *langCSV, CGRect regionPt) {
    @try {
        if (!NSClassFromString(@"VNRecognizeTextRequest") || !NSClassFromString(@"VNImageRequestHandler"))
            return @"ERR Vision chưa nạp được trong tiến trình này";
        // Vùng → ROI chuẩn hoá [0..1], lật trục y (Vision gốc dưới-trái), kẹp vào trong ảnh.
        CGRect roi = CGRectMake(0, 0, 1, 1);
        BOOL useROI = NO;
        if (regionPt.size.width > 0.5 && regionPt.size.height > 0.5 && W > 0 && H > 0) {
            CGFloat nx = regionPt.origin.x / W, nw = regionPt.size.width / W;
            CGFloat nh = regionPt.size.height / H;
            CGFloat ny = 1.0 - (regionPt.origin.y + regionPt.size.height) / H;
            if (nx < 0) { nw += nx; nx = 0; }
            if (ny < 0) { nh += ny; ny = 0; }
            if (nx + nw > 1) nw = 1 - nx;
            if (ny + nh > 1) nh = 1 - ny;
            if (nw > 0.001 && nh > 0.001 && nx < 1 && ny < 1) { roi = CGRectMake(nx, ny, nw, nh); useROI = YES; }
        }
        NSArray *langs = (langCSV.length ? [langCSV componentsSeparatedByString:@","] : @[@"en-US", @"vi-VN"]);
        // Revision cao nhất máy HỖ TRỢ (iOS16 = 3 → ja/ko/zh; iOS15 tối đa = 2). KHÔNG hardcode 3:
        // trên iOS15 gán req.revision=3 KHÔNG ném exception lúc set (chỉ là gán scalar) mà nổ ở
        // performRequests → "does not support VNRecognizeTextRequestRevision3" → OCR chết cả 2 lần thử.
        NSUInteger useRev = 0;
        @try {
            NSIndexSet *revs = [VNRecognizeTextRequest supportedRevisions];
            if (revs.count) useRev = [revs containsIndex:3] ? 3 : revs.lastIndex;
        } @catch (__unused NSException *e) {}
        // Lọc ngôn ngữ theo revision (vd vi-VN không có ở iOS15/rev2) để lần đầu không lỗi; rỗng → nil (Vision mặc định).
        @try {
            NSArray *sup = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:VNRequestTextRecognitionLevelAccurate
                                                                                                revision:(useRev ?: 1) error:NULL];
            if (sup.count) {
                NSMutableArray *keep = [NSMutableArray array];
                for (NSString *l in langs) if ([sup containsObject:l]) [keep addObject:l];
                langs = keep.count ? keep : nil;
            }
        } @catch (__unused NSException *e) {}
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = YES;
        if (useRev) @try { req.revision = useRev; } @catch (__unused NSException *e) {} // iOS16=3 (ja/ko/zh); iOS15=2
        @try { req.minimumTextHeight = 0.008; } @catch (__unused NSException *e) {} // bắt cả chữ nhỏ (status bar "No SIM"…)
        if (langs) @try { req.recognitionLanguages = langs; } @catch (__unused NSException *e) {}
        if (useROI) { @try { req.regionOfInterest = roi; } @catch (__unused NSException *e) { useROI = NO; } }
        NSError *err = nil;
        BOOL ok = [handler performRequests:@[req] error:&err];
        if (!ok || err) {   // ngôn ngữ không hỗ trợ → thử lại mặc định (không set languages)
            VNRecognizeTextRequest *r2 = [[VNRecognizeTextRequest alloc] init];
            r2.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            r2.usesLanguageCorrection = YES;
            if (useRev) @try { r2.revision = useRev; } @catch (__unused NSException *e) {}
            @try { r2.minimumTextHeight = 0.008; } @catch (__unused NSException *e) {}
            if (useROI) { @try { r2.regionOfInterest = roi; } @catch (__unused NSException *e) { useROI = NO; } }
            err = nil; ok = [handler performRequests:@[r2] error:&err];
            req = r2;
        }
        if (!ok || err)
            return [NSString stringWithFormat:@"ERR ocr vision: %@", err.localizedDescription ?: @"performRequests fail"];

        NSMutableString *js = [NSMutableString stringWithString:@"["];
        BOOL first = YES;
        for (VNRecognizedTextObservation *obs in req.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            NSString *s = top.string;
            if (!s.length) continue;
            CGRect bb = obs.boundingBox;   // normalized, gốc dưới-trái → đổi sang point gốc trên-trái
            if (useROI) {                  // boundingBox chuẩn hoá THEO ROI → quy về toàn ảnh
                bb.origin.x = roi.origin.x + bb.origin.x * roi.size.width;
                bb.origin.y = roi.origin.y + bb.origin.y * roi.size.height;
                bb.size.width  *= roi.size.width;
                bb.size.height *= roi.size.height;
            }
            int x = (int)lround(bb.origin.x * W);
            int y = (int)lround((1.0 - bb.origin.y - bb.size.height) * H);
            int w = (int)lround(bb.size.width * W);
            int h = (int)lround(bb.size.height * H);
            if (!first) [js appendString:@","];
            first = NO;
            [js appendString:@"{\"text\":\""]; IAJsonEsc(s, js);
            [js appendFormat:@"\",\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"cx\":%d,\"cy\":%d,\"conf\":%.2f}",
                x, y, w, h, x + w / 2, y + h / 2, (double)top.confidence];
        }
        [js appendString:@"]"];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iaocr.json"];
        if ([js writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil])
            return [@"OK ocr " stringByAppendingString:path];
        return @"ERR write-fail";
    } @catch (NSException *e) { return [@"ERR ocr " stringByAppendingString:(e.reason ?: @"?")]; }
}

// OCRIMG <base64 JPEG>: daemon lấy ảnh do SpringBoard chụp CẢ MÀN rồi gửi vào app foreground giải
// mã + Vision. Đây là cách DUY NHẤT OCR được app SwiftUI/Metal: drawViewHierarchy trong app trả
// ảnh trắng với SwiftUI, còn Vision/ANE trong SpringBoard thì crash SpringBoard.
static NSString *IAOcrImage(NSString *b64, NSString *langCSV, CGRect regionPt) {
    @try {
        // SpringBoard KHÔNG chạy được Vision/ANE → SKIP (KHÔNG trả ERR) để daemon chuyển sang app
        // foreground và KHÔNG đè lỗi Vision THẬT của app (vd "does not support …Revision3") bằng
        // thông báo "cần app foreground" — giống pattern web-verb (SKIP web-verb) bên dưới.
        if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
            return @"SKIP ocr (SpringBoard không chạy được Vision/ANE)";
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (!data.length) return @"ERR ocr base64 rỗng";
        UIImage *img = [UIImage imageWithData:data];
        if (!img.CGImage) return @"ERR ocr ảnh hỏng";
        CGSize sz = [UIScreen mainScreen].bounds.size;   // toạ độ trả theo POINT màn (khớp TAP)
        return IARunOCROnCG(img.CGImage, sz.width, sz.height, langCSV, regionPt);
    } @catch (NSException *e) { return [@"ERR ocr " stringByAppendingString:(e.reason ?: @"?")]; }
}

// OCR (tự chụp): app chụp UI của CHÍNH nó bằng drawViewHierarchy rồi Vision. Tốt cho app UIKit;
// app SwiftUI/Metal ra ảnh trắng → daemon dùng luồng SHOT+OCRIMG thay thế.
static NSString *IAOcr(void) {
    @try {
        if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
            return @"ERR ocr: mở 1 app rồi OCR (không OCR ở màn chính — ANE crash SpringBoard)";
        __block CGImageRef cg = NULL; __block CGSize sz = CGSizeZero;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                UIWindow *key = IAActiveWindow();
                if (!key) return;
                sz = [UIScreen mainScreen].bounds.size;
                NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
                UIWindowScene *scene = key.windowScene;
                if (scene) for (UIWindow *w in scene.windows) { if (w == gFxWindow || w.hidden || w.alpha < 0.01) continue; [wins addObject:w]; }
                if (wins.count == 0) [wins addObject:key];
                [wins sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                    return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending; }];
                UIGraphicsBeginImageContextWithOptions(sz, YES, 0);
                for (UIWindow *w in wins)
                    [w drawViewHierarchyInRect:CGRectMake(0, 0, sz.width, sz.height) afterScreenUpdates:YES];
                UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                if (img.CGImage) cg = CGImageRetain(img.CGImage);
            } @catch (__unused NSException *e) {}
        });
        if (!cg) return @"ERR ocr no-capture";
        NSString *r = IARunOCROnCG(cg, sz.width, sz.height, @"en-US,vi-VN", CGRectZero);
        CGImageRelease(cg);
        return r;
    } @catch (NSException *e) { return [@"ERR ocr " stringByAppendingString:(e.reason ?: @"?")]; }
}

// ================= safari.fill (ẨN): điền ô web qua JS =================
// Trên Safari bàn phím KHÔNG bật cho ô web bằng chạm tổng hợp (iOS chặn) → điền form bằng cách
// đặt thẳng .value qua evaluateJavaScript (native setter + bắn input/change để hợp React/Vue).
// Tìm WKWebView đầu tiên (DFS) trong cây view của app foreground.
static UIView *IAFindWebView(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSClassFromString(@"WKWebView")]) return v;
    for (UIView *sub in v.subviews) { UIView *r = IAFindWebView(sub); if (r) return r; }
    return nil;
}

// b64field/b64value: base64 (ASCII) — JS tự giải mã (UTF-8) nên không lo escape quote/tiếng Nhật.
// Chạy trên SOCKET THREAD: kick JS trên main rồi CHỜ semaphore (block socket thread, KHÔNG block
// main) → trả reply đồng bộ cho daemon. Timeout 4s.
static NSString *IAWebFill(NSString *b64field, NSString *b64value) {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
        return @"ERR webfill: cần app foreground (không phải màn hình chính)";
    if (!b64field) b64field = @"";
    if (!b64value) b64value = @"";
    __block NSString *result = @"ERR webfill no-webview";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = IAActiveWindow();
            UIView *wv = win ? IAFindWebView(win) : nil;
            if (!wv && win.windowScene)
                for (UIWindow *w in win.windowScene.windows) { wv = IAFindWebView(w); if (wv) break; }
            SEL ejs = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
            if (!wv || ![wv respondsToSelector:ejs]) { result = @"ERR webfill no-webview"; dispatch_semaphore_signal(sem); return; }
            NSString *js = [NSString stringWithFormat:
                @"(function(bf,bv){"
                "function d(b){try{return decodeURIComponent(escape(atob(b)));}catch(e){return atob(b);}}"
                "var field=d(bf),val=d(bv),el=null;"
                "try{el=document.querySelector(field);}catch(e){}"                       // 1) CSS selector
                "if(!el){var f=field.toLowerCase();"                                       // 2) khớp thuộc tính/label
                "var L=document.querySelectorAll('input,textarea,select,[contenteditable]');"
                "for(var i=0;i<L.length;i++){var e=L[i];"
                "if(e.type==='hidden'||e.disabled||e.readOnly)continue;"
                "var lab='';if(e.labels){for(var j=0;j<e.labels.length;j++)lab+=' '+(e.labels[j].textContent||'');}"
                "var hay=[e.placeholder,e.name,e.id,e.type,e.getAttribute('aria-label'),e.getAttribute('autocomplete'),lab].join(' ').toLowerCase();"
                "if(hay.indexOf(f)>=0){el=e;break;}}}"
                "if(!el)return 'noel';"
                "el.scrollIntoView({block:'center',inline:'center'});"                     // tự cuộn tới ô (nếu ngoài màn) trước khi điền
                "el.focus();"
                "if(el.tagName==='SELECT'){"                                              // <select>: chọn option theo value → text
                "var os=el.options,opt=null;"
                "for(var k=0;k<os.length;k++){if(os[k].value===val){opt=os[k];break;}}"
                "if(!opt)for(var k=0;k<os.length;k++){if((os[k].text||'').indexOf(val)>=0){opt=os[k];break;}}"
                "if(!opt)return 'noopt';"
                "el.value=opt.value;el.selectedIndex=opt.index;"
                "el.dispatchEvent(new Event('input',{bubbles:true}));"
                "el.dispatchEvent(new Event('change',{bubbles:true}));"
                "return 'select:'+opt.value;}"
                "if(el.isContentEditable){el.textContent=val;}else{"
                "try{var pr=(el.tagName==='TEXTAREA')?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;"
                "Object.getOwnPropertyDescriptor(pr,'value').set.call(el,val);}catch(e){el.value=val;}}"
                "el.dispatchEvent(new Event('input',{bubbles:true}));"
                "el.dispatchEvent(new Event('change',{bubbles:true}));"
                "return (el.name||el.id||el.placeholder||el.tagName);"
                "})('%@','%@')", b64field, b64value];
            void (^cb)(id, id) = ^(id res, id err) {
                if (err) result = [@"ERR webfill " stringByAppendingString:[err description]];
                else if ([res isKindOfClass:[NSString class]] && [res isEqualToString:@"noel"]) result = @"ERR webfill: không thấy ô khớp";
                else result = [NSString stringWithFormat:@"OK webfill %@", res ?: @"?"];
                dispatch_semaphore_signal(sem);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, js, cb);
        } @catch (NSException *e) {
            result = [@"ERR webfill " stringByAppendingString:(e.reason ?: @"?")];
            dispatch_semaphore_signal(sem);
        }
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)));
    return result;
}

// IAWebRunJS: chạy 1 đoạn JS ĐỒNG BỘ trên WKWebView `wv` (dispatch sang main + chờ semaphore) rồi
// TRẢ kết quả. Gọi ĐƯỢC từ thread nền (verb-handler) — nhờ vậy caller ngủ (usleep) giữa các lần gọi
// để tạo NHỊP thời gian thật. Trả: nil nếu quá `timeoutSec`; chuỗi "__ERR__…" nếu JS ném lỗi; còn lại
// là giá trị JS trả (NSString/số…). KHÔNG gọi trên main thread (dispatch_async main sẽ không chạy).
static id IAWebRunJS(UIView *wv, SEL ejs, NSString *js, double timeoutSec) {
    __block id out = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            void (^cb)(id, id) = ^(id res, id err) {
                out = err ? [@"__ERR__" stringByAppendingString:[err description]] : (res ?: @"");
                dispatch_semaphore_signal(sem);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, js, cb);
        } @catch (NSException *e) {
            out = [@"__ERR__" stringByAppendingString:(e.reason ?: @"?")];
            dispatch_semaphore_signal(sem);
        }
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC))) != 0)
        return nil;                                   // hết giờ → bỏ (cb có thể ghi out sau, vô hại)
    return out;
}

// safari.type (ẨN): GÕ từng ký tự (mô phỏng người gõ) vào ô web khớp field — chống anti-bot phát hiện
// so với safari.fill (đặt cả chuỗi 1 phát). KHÁC bản cũ: MỖI ký tự là 1 lần evaluateJavaScript RIÊNG,
// GIỮA hai phím NGỦ ngẫu nhiên (usleep native) → keydown/input/keyup của các phím có timestamp THẬT
// cách nhau (bản cũ gõ cả chuỗi trong 1 tick JS → cách nhau 0ms, anti-bot bắt ngay). Mỗi phím vẫn bắn
// đủ chuỗi keydown → keypress → beforeinput(insertText) → set value tăng dần → input(insertText) →
// keyup; kết thúc bằng change. Giữ focus (không blur). <select> chọn option như fill. b64*: base64.
// LƯU Ý: event JS luôn isTrusted=false (không giả được) — đây chỉ làm GIÀU event + NHỊP giống người.
static NSString *IAWebType(NSString *b64field, NSString *b64value) {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
        return @"ERR webtype: cần app foreground (không phải màn hình chính)";
    if (!b64field) b64field = @"";
    if (!b64value) b64value = @"";
    SEL ejs = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");

    // 1) Tìm WKWebView (đụng UIWindow → phải trên main).
    __block UIView *wv = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIWindow *win = IAActiveWindow();
        wv = win ? IAFindWebView(win) : nil;
        if (!wv && win.windowScene)
            for (UIWindow *w in win.windowScene.windows) { wv = IAFindWebView(w); if (wv) break; }
    });
    if (!wv || ![wv respondsToSelector:ejs]) return @"ERR webtype no-webview";

    // 2) SETUP: tìm el, focus, xoá value cũ, STASH el/val/setter lên window (dùng lại cho từng phím).
    //    Trả 'noel' | 'noopt' | 'select:<v>' (xong luôn) | số ký tự cần gõ.
    NSString *setup = [NSString stringWithFormat:
        @"(function(bf,bv){"
        "function d(b){try{return decodeURIComponent(escape(atob(b)));}catch(e){return atob(b);}}"
        "var field=d(bf),val=d(bv),el=null;"
        "try{el=document.querySelector(field);}catch(e){}"                       // 1) CSS selector
        "if(!el){var f=field.toLowerCase();"                                       // 2) khớp thuộc tính/label
        "var L=document.querySelectorAll('input,textarea,select,[contenteditable]');"
        "for(var i=0;i<L.length;i++){var e=L[i];"
        "if(e.type==='hidden'||e.disabled||e.readOnly)continue;"
        "var lab='';if(e.labels){for(var j=0;j<e.labels.length;j++)lab+=' '+(e.labels[j].textContent||'');}"
        "var hay=[e.placeholder,e.name,e.id,e.type,e.getAttribute('aria-label'),e.getAttribute('autocomplete'),lab].join(' ').toLowerCase();"
        "if(hay.indexOf(f)>=0){el=e;break;}}}"
        "if(!el)return 'noel';"
        "el.scrollIntoView({block:'center',inline:'center'});"
        "el.focus();"
        "if(el.tagName==='SELECT'){"                                              // <select>: gõ vô nghĩa → chọn option
        "var os=el.options,opt=null;"
        "for(var k=0;k<os.length;k++){if(os[k].value===val){opt=os[k];break;}}"
        "if(!opt)for(var k=0;k<os.length;k++){if((os[k].text||'').indexOf(val)>=0){opt=os[k];break;}}"
        "if(!opt)return 'noopt';"
        "el.value=opt.value;el.selectedIndex=opt.index;"
        "el.dispatchEvent(new Event('input',{bubbles:true}));"
        "el.dispatchEvent(new Event('change',{bubbles:true}));"
        "return 'select:'+opt.value;}"
        "var isCE=el.isContentEditable;"
        "var proto=(el.tagName==='TEXTAREA')?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;"
        "var setter=null;try{setter=Object.getOwnPropertyDescriptor(proto,'value').set;}catch(e){}"
        "window.__iaEl=el;window.__iaVal=val;window.__iaCur='';"                  // stash cho các bước gõ sau
        "window.__iaSet=function(v){if(isCE){el.textContent=v;}else if(setter){setter.call(el,v);}else{el.value=v;}};"
        "window.__iaSet('');"                                                     // xoá value cũ trước khi gõ
        "try{el.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,inputType:'deleteContentBackward'}));}catch(e){}"
        "return String(val.length);"
        "})('%@','%@')", b64field, b64value];
    id r = IAWebRunJS(wv, ejs, setup, 6.0);
    if (r == nil) return @"ERR webtype: timeout (setup)";
    NSString *rs = [r isKindOfClass:[NSString class]] ? (NSString *)r : [r description];
    if ([rs hasPrefix:@"__ERR__"]) return [@"ERR webtype " stringByAppendingString:[rs substringFromIndex:7]];
    if ([rs isEqualToString:@"noel"]) return @"ERR webtype: không thấy ô khớp";
    if ([rs isEqualToString:@"noopt"]) return @"ERR webtype: <select> không có option khớp";
    if ([rs hasPrefix:@"select:"]) return [@"OK webtype " stringByAppendingString:rs];
    int count = [rs intValue];
    if (count < 0) count = 0;
    if (count > 120) count = 120;                     // chặn trần thời gian: 120 phím × ~165ms ≈ 20s <
                                                      // timeout 25s daemon (email/pass thực rất ngắn)

    // Dwell đầu: người vừa focus xong ngập ngừng trước khi gõ phím đầu (130–360ms).
    usleep((130 + arc4random_uniform(230)) * 1000);

    // 3) GÕ TỪNG PHÍM — mỗi phím 1 eval, NGỦ ngẫu nhiên giữa 2 phím → nhịp thời gian thật.
    for (int n = 0; n < count; n++) {
        NSString *step = [NSString stringWithFormat:
            @"(function(n){"
            "var el=window.__iaEl;if(!el)return 'gone';"
            "var ch=window.__iaVal[n];"
            "var kop={key:ch,bubbles:true,cancelable:true,composed:true};"
            "el.dispatchEvent(new KeyboardEvent('keydown',kop));"
            "el.dispatchEvent(new KeyboardEvent('keypress',kop));"
            "try{el.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,cancelable:true,composed:true,inputType:'insertText',data:ch}));}catch(e){}"
            "window.__iaCur+=ch;window.__iaSet(window.__iaCur);"
            "try{el.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,inputType:'insertText',data:ch}));}catch(e){el.dispatchEvent(new Event('input',{bubbles:true}));}"
            "el.dispatchEvent(new KeyboardEvent('keyup',kop));return 'ok';"
            "})(%d)", n];
        id sr = IAWebRunJS(wv, ejs, step, 4.0);
        if (sr == nil) return @"ERR webtype: timeout (gõ)";
        NSString *ss = [sr isKindOfClass:[NSString class]] ? (NSString *)sr : [sr description];
        if ([ss isEqualToString:@"gone"]) return @"ERR webtype: ô biến mất giữa chừng";
        if ([ss hasPrefix:@"__ERR__"]) return [@"ERR webtype " stringByAppendingString:[ss substringFromIndex:7]];
        // Nghỉ giữa 2 phím: cơ bản 55ms + jitter 0–150ms; ~9% lần "ngập ngừng" thêm 180–520ms.
        useconds_t gap = (55 + arc4random_uniform(150)) * 1000;
        if (arc4random_uniform(100) < 9) gap += (180 + arc4random_uniform(340)) * 1000;
        usleep(gap);
    }

    // 4) CHỐT: bắn change, giữ focus, dọn biến tạm trên window.
    NSString *fin =
        @"(function(){var el=window.__iaEl;"
        "try{delete window.__iaEl;delete window.__iaVal;delete window.__iaCur;delete window.__iaSet;}catch(e){}"
        "if(!el)return 'gone';"
        "el.dispatchEvent(new Event('change',{bubbles:true}));"
        "return (el.name||el.id||el.placeholder||el.tagName);})()";
    id fr = IAWebRunJS(wv, ejs, fin, 4.0);
    NSString *fs = (fr && [fr isKindOfClass:[NSString class]]) ? (NSString *)fr : @"?";
    if ([fs hasPrefix:@"__ERR__"]) fs = @"?";
    return [NSString stringWithFormat:@"OK webtype %@", fs];
}

// safari.swipe (ẨN): cuộn (scroll) trong WKWebView tới element web khớp `field` — dùng khi element
// nằm ngoài màn (phải kéo tới mới bấm/điền được). field khớp GIỐNG safari.fill: CSS selector HOẶC
// chuỗi khớp text/placeholder/name/id/aria-label/label (không phân biệt hoa/thường). Gọi
// scrollIntoView({block:'center'}) → element ra GIỮA màn. b64field: base64 (JS tự giải mã UTF-8).
static NSString *IAWebScrollTo(NSString *b64field) {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
        return @"ERR webswipe: cần app foreground (không phải màn hình chính)";
    if (!b64field) b64field = @"";
    __block NSString *result = @"ERR webswipe no-webview";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = IAActiveWindow();
            UIView *wv = win ? IAFindWebView(win) : nil;
            if (!wv && win.windowScene)
                for (UIWindow *w in win.windowScene.windows) { wv = IAFindWebView(w); if (wv) break; }
            SEL ejs = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
            if (!wv || ![wv respondsToSelector:ejs]) { result = @"ERR webswipe no-webview"; dispatch_semaphore_signal(sem); return; }
            NSString *js = [NSString stringWithFormat:
                @"(function(bf){"
                "function d(b){try{return decodeURIComponent(escape(atob(b)));}catch(e){return atob(b);}}"
                "var field=d(bf),el=null;"
                "try{el=document.querySelector(field);}catch(e){}"                        // 1) CSS selector
                "if(!el){var f=field.toLowerCase();"                                        // 2) khớp thuộc tính/label
                "var L=document.querySelectorAll('input,textarea,select,button,a,[contenteditable],[role]');"
                "for(var i=0;i<L.length;i++){var e=L[i];"
                "var lab='';if(e.labels){for(var j=0;j<e.labels.length;j++)lab+=' '+(e.labels[j].textContent||'');}"
                "var hay=[e.placeholder,e.name,e.id,e.type,e.value,e.getAttribute('aria-label'),lab].join(' ').toLowerCase();"
                "if(hay.indexOf(f)>=0){el=e;break;}}}"
                "if(!el){var A=document.querySelectorAll('body *');"                        // 3) khớp text hiển thị
                "for(var k=0;k<A.length;k++){var t=(A[k].textContent||'');"
                "if(A[k].children.length===0&&t.toLowerCase().indexOf(f)>=0){el=A[k];break;}}}"
                "if(!el)return 'noel';"
                "el.scrollIntoView({block:'center',inline:'center'});"
                "var r=el.getBoundingClientRect();"
                "return 'ok '+Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);"
                "})('%@')", b64field];
            void (^cb)(id, id) = ^(id res, id err) {
                if (err) result = [@"ERR webswipe " stringByAppendingString:[err description]];
                else if ([res isKindOfClass:[NSString class]] && [res isEqualToString:@"noel"]) result = @"ERR webswipe: không thấy element khớp";
                else result = [NSString stringWithFormat:@"OK webswipe %@", res ?: @"?"];
                dispatch_semaphore_signal(sem);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, js, cb);
        } @catch (NSException *e) {
            result = [@"ERR webswipe " stringByAppendingString:(e.reason ?: @"?")];
            dispatch_semaphore_signal(sem);
        }
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)));
    return result;
}

// safari.click (ẨN): bấm element web khớp `field` trong WKWebView app foreground. Khớp GIỐNG
// safari.swipe (CSS selector / text / placeholder/name/id/aria-label/label / button / link). Cuộn
// tới element (scrollIntoView) rồi bắn pointerdown→mousedown→pointerup→mouseup + el.click() ngay
// TÂM element (hợp handler React/Vue nghe pointer/mouse). b64field: base64 (JS tự giải mã UTF-8).
static NSString *IAWebClick(NSString *b64field) {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
        return @"ERR webclick: cần app foreground (không phải màn hình chính)";
    if (!b64field) b64field = @"";
    __block NSString *result = @"ERR webclick no-webview";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = IAActiveWindow();
            UIView *wv = win ? IAFindWebView(win) : nil;
            if (!wv && win.windowScene)
                for (UIWindow *w in win.windowScene.windows) { wv = IAFindWebView(w); if (wv) break; }
            SEL ejs = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
            if (!wv || ![wv respondsToSelector:ejs]) { result = @"ERR webclick no-webview"; dispatch_semaphore_signal(sem); return; }
            NSString *js = [NSString stringWithFormat:
                @"(function(bf){"
                "function d(b){try{return decodeURIComponent(escape(atob(b)));}catch(e){return atob(b);}}"
                "var field=d(bf),el=null;"
                "try{el=document.querySelector(field);}catch(e){}"                        // 1) CSS selector
                "if(!el){var f=field.toLowerCase();"                                        // 2) khớp thuộc tính/label
                "var L=document.querySelectorAll('input,textarea,select,button,a,[contenteditable],[role]');"
                "for(var i=0;i<L.length;i++){var e=L[i];"
                "var lab='';if(e.labels){for(var j=0;j<e.labels.length;j++)lab+=' '+(e.labels[j].textContent||'');}"
                "var hay=[e.placeholder,e.name,e.id,e.type,e.value,e.getAttribute('aria-label'),lab].join(' ').toLowerCase();"
                "if(hay.indexOf(f)>=0){el=e;break;}}}"
                "if(!el){var A=document.querySelectorAll('body *');"                        // 3) khớp text hiển thị
                "for(var k=0;k<A.length;k++){var t=(A[k].textContent||'');"
                "if(A[k].children.length===0&&t.toLowerCase().indexOf(f)>=0){el=A[k];break;}}}"
                "if(!el)return 'noel';"
                "el.scrollIntoView({block:'center',inline:'center'});"
                "var r=el.getBoundingClientRect();var cx=r.left+r.width/2,cy=r.top+r.height/2;"
                "function fire(ty,C,o){o=Object.assign({bubbles:true,cancelable:true,composed:true,clientX:cx,clientY:cy,button:0},o||{});try{el.dispatchEvent(new C(ty,o));}catch(e){}}"
                "try{el.focus();}catch(e){}"
                "fire('pointerdown',PointerEvent,{pointerId:1,pointerType:'touch',isPrimary:true});"
                "fire('mousedown',MouseEvent);"
                "fire('pointerup',PointerEvent,{pointerId:1,pointerType:'touch',isPrimary:true});"
                "fire('mouseup',MouseEvent);"
                "try{el.click();}catch(e){fire('click',MouseEvent);}"
                "return 'ok '+Math.round(cx)+','+Math.round(cy);"
                "})('%@')", b64field];
            void (^cb)(id, id) = ^(id res, id err) {
                if (err) result = [@"ERR webclick " stringByAppendingString:[err description]];
                else if ([res isKindOfClass:[NSString class]] && [res isEqualToString:@"noel"]) result = @"ERR webclick: không thấy element khớp";
                else result = [NSString stringWithFormat:@"OK webclick %@", res ?: @"?"];
                dispatch_semaphore_signal(sem);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, js, cb);
        } @catch (NSException *e) {
            result = [@"ERR webclick " stringByAppendingString:(e.reason ?: @"?")];
            dispatch_semaphore_signal(sem);
        }
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)));
    return result;
}

// safari.load (ẨN): đọc document.readyState của WKWebView app foreground → biết trang đã load xong
// chưa. Trả "OK state <loading|interactive|complete>" hoặc ERR. Daemon LẶP gọi verb này tới khi
// gặp 'complete' hoặc hết thời gian (mỗi lần gọi nhanh, không giữ socket 60s).
static NSString *IAWebReadyState(void) {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
        return @"ERR webstate: cần app foreground (không phải màn hình chính)";
    __block NSString *result = @"ERR webstate no-webview";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = IAActiveWindow();
            UIView *wv = win ? IAFindWebView(win) : nil;
            if (!wv && win.windowScene)
                for (UIWindow *w in win.windowScene.windows) { wv = IAFindWebView(w); if (wv) break; }
            SEL ejs = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
            if (!wv || ![wv respondsToSelector:ejs]) { result = @"ERR webstate no-webview"; dispatch_semaphore_signal(sem); return; }
            NSString *js = @"(function(){try{return document.readyState;}catch(e){return 'err';}})()";
            void (^cb)(id, id) = ^(id res, id err) {
                if (err) result = [@"ERR webstate " stringByAppendingString:[err description]];
                else result = [NSString stringWithFormat:@"OK state %@", res ?: @"?"];
                dispatch_semaphore_signal(sem);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(wv, ejs, js, cb);
        } @catch (NSException *e) {
            result = [@"ERR webstate " stringByAppendingString:(e.reason ?: @"?")];
            dispatch_semaphore_signal(sem);
        }
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)));
    return result;
}

// ================= SPIKE VideoToolbox: CARenderServer→IOSurface→H.264 =================
// Kiểm chứng pipeline video độ trễ thấp cho IOScontrol: chụp CARenderServer vào IOSurface →
// bọc CVPixelBuffer → VTCompressionSession (H.264 realtime) → ghi Annex B ra /var/tmp/iavt.h264.
// Chỉ để DE-RISK phần cứng (VideoToolbox có chạy trong SpringBoard không). Chạy trên socket
// thread (không main), block ~seconds giây. Tái dùng 1 IOSurface (spike chấp nhận tearing nhẹ).

static int IAWriteAll(int fd, const void *b, size_t n) {
    const uint8_t *p = (const uint8_t *)b; size_t o = 0;
    while (o < n) { ssize_t k = write(fd, p + o, n - o); if (k <= 0) { if (k < 0 && errno == EINTR) continue; return 0; } o += (size_t)k; }
    return 1;
}
// Dựng 1 access unit H.264 Annex B (SPS/PPS kèm keyframe) vào `out`; *isKey = có phải keyframe.
static void IAVTBuildAnnexB(CMSampleBufferRef sbuf, NSMutableData *out, BOOL *isKey) {
    static const uint8_t sc[4] = {0, 0, 0, 1};
    BOOL key = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts && CFArrayGetCount(atts)) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
        if (notSync && CFBooleanGetValue(notSync)) key = NO;
    }
    if (key) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
        size_t cnt = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &cnt, NULL) == noErr) {
            for (size_t i = 0; i < cnt; i++) {
                const uint8_t *ps = NULL; size_t psz = 0;
                if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psz, NULL, NULL) == noErr && ps) {
                    [out appendBytes:sc length:4]; [out appendBytes:ps length:psz];
                }
            }
        }
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
    size_t total = 0; char *data = NULL;
    if (bb && CMBlockBufferGetDataPointer(bb, 0, NULL, &total, &data) == noErr && data) {
        size_t off = 0;
        while (off + 4 <= total) {
            uint32_t n = ((uint8_t)data[off] << 24) | ((uint8_t)data[off+1] << 16) | ((uint8_t)data[off+2] << 8) | (uint8_t)data[off+3];
            off += 4;
            if (off + n > total) break;
            [out appendBytes:sc length:4]; [out appendBytes:data + off length:n];
            off += n;
        }
    }
    if (isKey) *isKey = key;
}
// Callback spike → ghi Annex B ra FILE*.
static void IAVTOutput(void *outputRef, void *srcRef, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sbuf) {
    (void)srcRef; (void)flags;
    if (status != noErr || !sbuf || !CMSampleBufferDataIsReady(sbuf)) return;
    NSMutableData *au = [NSMutableData data]; BOOL key = NO;
    IAVTBuildAnnexB(sbuf, au, &key);
    if (au.length) fwrite(au.bytes, 1, au.length, (FILE *)outputRef);
}

static NSString *IAVTSpike(int seconds) {
    @try {
        if (seconds < 1) seconds = 1; if (seconds > 15) seconds = 15;
        CARSRenderDisplayFn pRender = (CARSRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!pRender) return @"ERR vt: thiếu CARenderServerRenderDisplay";
        CGFloat scale = [UIScreen mainScreen].scale;
        CGSize pt = [UIScreen mainScreen].bounds.size;
        size_t w = (size_t)(pt.width * scale), h = (size_t)(pt.height * scale);
        if (!w || !h) return @"ERR vt: kích thước 0";

        size_t bpe = 4, bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * bpe), tot = IOSurfaceAlignProperty(kIOSurfaceAllocSize, h * bpr);
        NSDictionary *props = @{ (__bridge id)kIOSurfaceWidth:@(w), (__bridge id)kIOSurfaceHeight:@(h),
            (__bridge id)kIOSurfaceBytesPerElement:@(bpe), (__bridge id)kIOSurfaceBytesPerRow:@(bpr),
            (__bridge id)kIOSurfaceAllocSize:@(tot), (__bridge id)kIOSurfacePixelFormat:@((uint32_t)0x42475241) };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surf) return @"ERR vt: IOSurfaceCreate fail";

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iavt.h264"];
        FILE *fp = fopen(path.UTF8String, "wb");
        if (!fp) { CFRelease(surf); return @"ERR vt: mở file fail"; }

        VTCompressionSessionRef sess = NULL;
        OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)w, (int32_t)h,
            kCMVideoCodecType_H264, NULL, NULL, NULL, IAVTOutput, fp, &sess);
        if (st != noErr || !sess) { fclose(fp); CFRelease(surf); return [NSString stringWithFormat:@"ERR vt: VTCompressionSessionCreate = %d (VideoToolbox KHÔNG chạy được ở đây)", (int)st]; }

        VTSessionSetProperty(sess, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(sess, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(sess, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
        int32_t fps = 24; CFNumberRef v;
        v = CFNumberCreate(NULL, kCFNumberSInt32Type, &fps); VTSessionSetProperty(sess, kVTCompressionPropertyKey_ExpectedFrameRate, v); CFRelease(v);
        int32_t kf = 48; v = CFNumberCreate(NULL, kCFNumberSInt32Type, &kf); VTSessionSetProperty(sess, kVTCompressionPropertyKey_MaxKeyFrameInterval, v); CFRelease(v);
        int32_t br = 1200000; v = CFNumberCreate(NULL, kCFNumberSInt32Type, &br); VTSessionSetProperty(sess, kVTCompressionPropertyKey_AverageBitRate, v); CFRelease(v);
        VTCompressionSessionPrepareToEncodeFrames(sess);

        int totalFrames = seconds * fps, encoded = 0, encErr = 0;
        for (int i = 0; i < totalFrames; i++) {
            pRender(0, CFSTR("LCD"), surf, 0, 0);
            CVPixelBufferRef pb = NULL;
            if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &pb) == kCVReturnSuccess && pb) {
                VTEncodeInfoFlags fl;
                OSStatus es = VTCompressionSessionEncodeFrame(sess, pb, CMTimeMake(i, fps), kCMTimeInvalid, NULL, NULL, &fl);
                if (es == noErr) encoded++; else encErr = (int)es;
                CVPixelBufferRelease(pb);
            }
            usleep(1000000 / fps);
        }
        VTCompressionSessionCompleteFrames(sess, kCMTimeInvalid);
        VTCompressionSessionInvalidate(sess); CFRelease(sess);
        long bytes = ftell(fp);
        fclose(fp); CFRelease(surf);
        return [NSString stringWithFormat:@"OK vtrec %@ frames=%d/%d bytes=%ld %zux%zu encErr=%d", path, encoded, totalFrames, bytes, w, h, encErr];
    } @catch (NSException *e) { return [@"ERR vt " stringByAppendingString:(e.reason ?: @"?")]; }
}

// ---- STREAM liên tục: encode → push framed H.264 tới daemon:8398 (WebSocket fan-out) ----
static const int IA_VIDEO_PORT = 8398;
static volatile int gVTStreaming = 0;
static int gVTStreamFd = -1;

// Callback stream: đóng gói [4-byte BE N][flags][annexb] (N = 1+annexb) rồi push socket.
static void IAVTOutputStream(void *ref, void *src, OSStatus st, VTEncodeInfoFlags fl, CMSampleBufferRef sb) {
    (void)ref; (void)src; (void)fl;
    if (st != noErr || !sb || !CMSampleBufferDataIsReady(sb)) return;
    int fd = gVTStreamFd; if (fd < 0) return;
    NSMutableData *au = [NSMutableData data]; BOOL key = NO;
    IAVTBuildAnnexB(sb, au, &key);
    if (!au.length) return;
    uint32_t N = (uint32_t)(1 + au.length);
    uint8_t hdr[5] = { (uint8_t)(N >> 24), (uint8_t)(N >> 16), (uint8_t)(N >> 8), (uint8_t)N, (uint8_t)(key ? 1 : 0) };
    if (!IAWriteAll(fd, hdr, 5) || !IAWriteAll(fd, au.bytes, au.length)) gVTStreaming = 0;   // client/daemon rớt → dừng
}

static void IAVTStreamLoop(int fps, int bitrate) {
    @try {
        if (fps < 5) fps = 5; if (fps > 60) fps = 60;
        CARSRenderDisplayFn pRender = (CARSRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!pRender) { gVTStreaming = 0; return; }
        CGFloat scale = [UIScreen mainScreen].scale;
        CGSize pt = [UIScreen mainScreen].bounds.size;
        size_t w = (size_t)(pt.width * scale), h = (size_t)(pt.height * scale);
        if (!w || !h) { gVTStreaming = 0; return; }

        // socket tới daemon ingest
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { gVTStreaming = 0; return; }
        int nd = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
        struct sockaddr_in a; memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(IA_VIDEO_PORT);
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); gVTStreaming = 0; return; }
        gVTStreamFd = fd;

        size_t bpe = 4, bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * bpe), tot = IOSurfaceAlignProperty(kIOSurfaceAllocSize, h * bpr);
        NSDictionary *props = @{ (__bridge id)kIOSurfaceWidth:@(w), (__bridge id)kIOSurfaceHeight:@(h),
            (__bridge id)kIOSurfaceBytesPerElement:@(bpe), (__bridge id)kIOSurfaceBytesPerRow:@(bpr),
            (__bridge id)kIOSurfaceAllocSize:@(tot), (__bridge id)kIOSurfacePixelFormat:@((uint32_t)0x42475241) };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surf) { close(fd); gVTStreamFd = -1; gVTStreaming = 0; return; }

        VTCompressionSessionRef sess = NULL;
        OSStatus cs = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)w, (int32_t)h, kCMVideoCodecType_H264, NULL, NULL, NULL, IAVTOutputStream, NULL, &sess);
        if (cs != noErr || !sess) { CFRelease(surf); close(fd); gVTStreamFd = -1; gVTStreaming = 0; return; }
        VTSessionSetProperty(sess, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(sess, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(sess, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
        CFNumberRef v;
        v = CFNumberCreate(NULL, kCFNumberSInt32Type, &fps); VTSessionSetProperty(sess, kVTCompressionPropertyKey_ExpectedFrameRate, v); CFRelease(v);
        int32_t kf = fps;   // keyframe mỗi ~1s → client join nhanh
        v = CFNumberCreate(NULL, kCFNumberSInt32Type, &kf); VTSessionSetProperty(sess, kVTCompressionPropertyKey_MaxKeyFrameInterval, v); CFRelease(v);
        v = CFNumberCreate(NULL, kCFNumberSInt32Type, &bitrate); VTSessionSetProperty(sess, kVTCompressionPropertyKey_AverageBitRate, v); CFRelease(v);
        VTCompressionSessionPrepareToEncodeFrames(sess);

        int i = 0;
        while (gVTStreaming) {
            pRender(0, CFSTR("LCD"), surf, 0, 0);
            CVPixelBufferRef pb = NULL;
            if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &pb) == kCVReturnSuccess && pb) {
                VTEncodeInfoFlags fl;
                VTCompressionSessionEncodeFrame(sess, pb, CMTimeMake(i, fps), kCMTimeInvalid, NULL, NULL, &fl);
                CVPixelBufferRelease(pb);
            }
            i++;
            usleep(1000000 / fps);
        }
        VTCompressionSessionCompleteFrames(sess, kCMTimeInvalid);
        VTCompressionSessionInvalidate(sess); CFRelease(sess);
        CFRelease(surf);
        if (gVTStreamFd == fd) gVTStreamFd = -1;   // đừng clobber fd của luồng mới (start/stop nhanh)
        close(fd);
    } @catch (__unused NSException *e) { gVTStreaming = 0; }
}

static NSString *IAVTStart(void) {
    if (gVTStreaming) return @"OK vtstart (đang chạy)";
    gVTStreaming = 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ IAVTStreamLoop(20, 1500000); });
    return @"OK vtstart";
}
static NSString *IAVTStop(void) { gVTStreaming = 0; return @"OK vtstop"; }

// ---- STREAM JPEG cho MJPEG: chụp trên THREAD RIÊNG, push tới daemon:8397 ----
// Tách khỏi relay điều khiển: SHOT (~100ms) KHÔNG còn chiếm socket relay/thread điều khiển của
// SpringBoard → HOME/kéo không bị nghẽn. Daemon buffer khung mới nhất, phục vụ /api/stream.
static const int IA_SHOT_PORT = 8397;
static volatile int gShotStreaming = 0;
static void IAShotStreamLoop(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { gShotStreaming = 0; return; }
    int nd = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(IA_SHOT_PORT);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); gShotStreaming = 0; return; }
    while (gShotStreaming) {
        @autoreleasepool {
            UIImage *img = IACaptureCARender();
            NSData *jpg = img ? UIImageJPEGRepresentation(img, 0.4) : nil;
            if (jpg.length) {
                uint32_t n = (uint32_t)jpg.length;
                uint8_t hdr[4] = { (uint8_t)(n>>24), (uint8_t)(n>>16), (uint8_t)(n>>8), (uint8_t)n };
                if (!IAWriteAll(fd, hdr, 4) || !IAWriteAll(fd, jpg.bytes, jpg.length)) break;
            } else usleep(50000);
        }
        usleep(15000);   // nhường CPU (chụp đã ~50-100ms → ~10-15fps)
    }
    close(fd);
}
static NSString *IAShotStart(void) {
    if (gShotStreaming) return @"OK shotstart (đang chạy)";
    gShotStreaming = 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ IAShotStreamLoop(); });
    return @"OK shotstart";
}
static NSString *IAShotStop(void) { gShotStreaming = 0; return @"OK shotstop"; }

// ================= Clipboard (UIPasteboard chung = clipboard iPhone) =================
// COPYB64 <base64>: đặt clipboard = chuỗi (giải base64 → UTF-8). Base64 để mang được chuỗi dài /
// nhiều dòng / có dấu cách trong 1 dòng verb.
static NSString *IACopyB64(NSString *b64) {
    __block NSString *res = @"OK copy";
    NSData *d = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64
                              options:NSDataBase64DecodingIgnoreUnknownCharacters] : [NSData data];
    NSString *text = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { [UIPasteboard generalPasteboard].string = text; }
        @catch (NSException *e) { res = [@"ERR copy " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return res;
}
// CLIP: đọc clipboard → ghi file (giống DUMP/OCR: chuỗi có thể nhiều dòng) → reply "OK clip <path>".
static NSString *IAClip(void) {
    __block NSString *res = @"ERR";
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iaclip.txt"];
            if ([s writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil])
                res = [@"OK clip " stringByAppendingString:path];
            else res = @"ERR write-fail";
        } @catch (NSException *e) { res = [@"ERR clip " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return res;
}


static NSString *IAToastB64(NSString *durationText, NSString *b64) {
    double duration = durationText.length ? [durationText doubleValue] : 2.0;
    if (duration <= 0) duration = 2.0;
    if (duration > 30) duration = 30.0;
    NSData *d = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64
                              options:NSDataBase64DecodingIgnoreUnknownCharacters] : [NSData data];
    NSString *text = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
    __block NSString *res = @"OK toast";
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = nil;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (!w.hidden && w.alpha > 0.01) { win = w; if (w.isKeyWindow) break; }
            }
            if (!win) win = [UIApplication sharedApplication].keyWindow;
            if (!win) return;

            UIView *old = [win viewWithTag:8399123];
            [old removeFromSuperview];

            // Kiểu AutoTouch: hộp bo tròn tối, chữ trắng, canh GIỮA màn hình (HUD).
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.tag = 8399123;
            label.text = text.length ? text : @" ";
            label.textColor = UIColor.whiteColor;
            label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.80];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            label.layer.cornerRadius = 14;
            label.layer.masksToBounds = YES;
            label.alpha = 0;

            CGFloat maxW = MIN(win.bounds.size.width - 40, 360);
            CGFloat padX = 22, padY = 16;
            CGSize fit = [label sizeThatFits:CGSizeMake(maxW - padX * 2, CGFLOAT_MAX)];
            CGFloat width = MIN(maxW, MAX(120, fit.width + padX * 2));
            CGFloat height = MAX(48, fit.height + padY * 2);
            // Canh giữa ngang, nằm ở PHẦN TRÊN màn hình (dưới status bar / tai thỏ).
            CGFloat top = win.safeAreaInsets.top > 0 ? win.safeAreaInsets.top : 20;
            label.frame = CGRectMake((win.bounds.size.width - width) / 2,
                                     top + 72,
                                     width, height);
            label.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin |
                                     UIViewAutoresizingFlexibleLeftMargin |
                                     UIViewAutoresizingFlexibleRightMargin;
            label.transform = CGAffineTransformMakeScale(0.92, 0.92);
            [win addSubview:label];
            [UIView animateWithDuration:0.16 animations:^{
                label.alpha = 1;
                label.transform = CGAffineTransformIdentity;
            } completion:^(__unused BOOL done) {
                [UIView animateWithDuration:0.28 delay:duration options:0 animations:^{
                    label.alpha = 0;
                } completion:^(__unused BOOL done2) {
                    [label removeFromSuperview];
                }];
            }];
        } @catch (NSException *e) { res = [@"ERR toast " stringByAppendingString:(e.reason ?: @"?")]; }
    });
    return res;
}

// ================= Socket client (TCP loopback → daemon) =================
// Cache trạng thái active theo NOTIFICATION (không hỏi applicationState qua dispatch_sync — hay
// trả sai lúc app đang chuyển trạng thái → gate SKIP nhầm → TAP/PTR/OCR rơi xuống SpringBoard).
static volatile int gAppActive = 0;

// Kích thước màn CACHE — LUÔN đọc/ghi từ MAIN THREAD. Lý do sống còn: verb INFO chạy trên thread nền
// (connectAndServe). Nếu nền message thẳng [UIScreen mainScreen] khi UIScreen CHƯA +initialize (cửa sổ
// hẹp lúc SpringBoard cold-boot), runtime chạy +[UIScreen initialize] NGAY TRÊN THREAD NỀN → kéo theo
// +[FBSceneManager sharedInstance]/FBSceneWorkspace vốn CHỈ cho main → FrontBoard bắn
// __FB_REPORT_MAIN_THREAD_VIOLATION__ (SIGTRAP, @try KHÔNG bắt được) → SpringBoard crash → kẹt Safe Mode
// (gặp trên iPhone9,1 iOS 15.8.8). Cache do main điền (an toàn) rồi INFO chỉ đọc số → không đụng UIScreen.
static volatile int gScreenW = 0, gScreenH = 0;
// Điền cache trên MAIN THREAD (bọc để gọi được từ bất kỳ đâu). An toàn: chạy khi main rảnh.
static void IARefreshScreenSize(void) {
    void (^grab)(void) = ^{
        @try { CGSize s = [UIScreen mainScreen].bounds.size;
               if (s.width > 0 && s.height > 0) { gScreenW = (int)s.width; gScreenH = (int)s.height; } }
        @catch (__unused NSException *e) {}
    };
    if ([NSThread isMainThread]) grab(); else dispatch_async(dispatch_get_main_queue(), grab);
}

@interface IAClient : NSObject
@property (nonatomic) int fd;
@property (nonatomic, strong) NSThread *thread;
@end
@implementation IAClient
+ (instancetype)shared { static IAClient *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [IAClient new]; s.fd = -1; }); return s; }

- (NSString *)handle:(NSString *)cmd {
    NSArray *p = [cmd componentsSeparatedByString:@" "];
    NSString *verb = p.count ? p[0] : @"";

    // GATE định tuyến: thao tác TƯƠNG TÁC chỉ được app ĐANG FOREGROUND xử lý.
    // App nền đã suspend vẫn giữ kết nối → phải TỪ CHỐI ("SKIP") để daemon chuyển
    // sang client kế (cuối cùng là SpringBoard cho màn hình chính). SHOT/WAKE/INFO KHÔNG gate
    // (SHOT do SpringBoard chụp cả màn kể cả khi app khác foreground).
    static NSSet *interact; static dispatch_once_t io;
    // OCRIMG KHÔNG gate: ảnh do SpringBoard chụp được truyền vào (tự chứa) → app foreground/nền
    // nào chạy Vision cũng cho kết quả như nhau; daemon ưu tiên app mới nhất (foreground). Gate
    // sẽ khiến app foreground SKIP nếu applicationState chưa Active kịp → OCRIMG rơi xuống SpringBoard.
    dispatch_once(&io, ^{ interact = [NSSet setWithArray:@[@"TAP", @"SWIPE", @"TAPSE", @"PTR", @"TYPE", @"KEY", @"HOME", @"DUMP", @"OCR", @"TOASTB64", @"WEBFILL", @"WEBTYPE", @"WEBSWIPE", @"WEBCLICK", @"WEBSTATE"]]; });
    BOOL isSB = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
    if (!isSB && [interact containsObject:verb] && ![self isForeground])
        return @"SKIP not-foreground";
    // Web verb (WKWebView) chỉ app foreground xử lý được. SpringBoard KHÔNG có WKWebView → SKIP để
    // daemon KHÔNG che câu trả lời thật của Safari (vd "không thấy element") bằng "cần app foreground".
    static NSSet *webVerbs; static dispatch_once_t wo;
    dispatch_once(&wo, ^{ webVerbs = [NSSet setWithArray:@[@"WEBFILL", @"WEBTYPE", @"WEBSWIPE", @"WEBCLICK", @"WEBSTATE"]]; });
    if (isSB && [webVerbs containsObject:verb])
        return @"SKIP web-verb (SpringBoard không có WKWebView)";

    @try {
        if ([verb isEqualToString:@"TAP"] && p.count >= 3)
            return IATap(CGPointMake([p[1] floatValue], [p[2] floatValue]));
        if ([verb isEqualToString:@"SWIPE"] && p.count >= 5)
            return IASwipe(CGPointMake([p[1] floatValue], [p[2] floatValue]),
                           CGPointMake([p[3] floatValue], [p[4] floatValue]),
                           p.count >= 6 ? [p[5] doubleValue] : 0.3);
        if ([verb isEqualToString:@"TAPSE"] && p.count >= 3)
            return IATapSendEvent(CGPointMake([p[1] floatValue], [p[2] floatValue]));
        if ([verb isEqualToString:@"PTR"] && p.count >= 4)
            return IAPointer([p[1] characterAtIndex:0], CGPointMake([p[2] floatValue], [p[3] floatValue]));
        if ([verb isEqualToString:@"TYPE"] && cmd.length > 5)
            return IAType([cmd substringFromIndex:5]);   // toàn bộ sau "TYPE "
        if ([verb isEqualToString:@"KEY"] && p.count >= 2)
            return IAKey(p[1]);                          // KEY BACK | KEY RETURN
        if ([verb isEqualToString:@"WEBFILL"] && p.count >= 2)   // safari.fill: "WEBFILL <b64field> <b64value>"
            return IAWebFill(p[1], p.count >= 3 ? p[2] : @"");
        if ([verb isEqualToString:@"WEBTYPE"] && p.count >= 2)   // safari.type: "WEBTYPE <b64field> <b64value>"
            return IAWebType(p[1], p.count >= 3 ? p[2] : @"");
        if ([verb isEqualToString:@"WEBSWIPE"] && p.count >= 2)  // safari.swipe: "WEBSWIPE <b64field>"
            return IAWebScrollTo(p[1]);
        if ([verb isEqualToString:@"WEBCLICK"] && p.count >= 2)  // safari.click: "WEBCLICK <b64field>"
            return IAWebClick(p[1]);
        if ([verb isEqualToString:@"WEBSTATE"])                  // safari.load: "WEBSTATE" → document.readyState
            return IAWebReadyState();
        if ([verb isEqualToString:@"FX"] && p.count >= 2) {
            gFxEnabled = [p[1] intValue] != 0;
            return gFxEnabled ? @"OK fx on" : @"OK fx off";
        }
        if ([verb isEqualToString:@"APPEAR"] && p.count >= 2)
            return IAAppearance([p[1] intValue]);
        if ([verb isEqualToString:@"SDIAG"]) return IADiag();
        if ([verb isEqualToString:@"DUMP"]) return IADump();
        if ([verb isEqualToString:@"VTREC"]) return IAVTSpike(p.count >= 2 ? [p[1] intValue] : 3);
        if ([verb isEqualToString:@"VTSTART"]) return IAVTStart();
        if ([verb isEqualToString:@"VTSTOP"]) return IAVTStop();
        if ([verb isEqualToString:@"SHOTSTART"]) return IAShotStart();
        if ([verb isEqualToString:@"SHOTSTOP"]) return IAShotStop();
        if ([verb isEqualToString:@"FBSHOT"]) {   // test chụp framebuffer thật
            UIImage *img = IACaptureFramebuffer();
            if (!img) return @"ERR fb no-capture (IOMobileFramebuffer không truy cập được ở tiến trình này)";
            NSData *jpg = UIImageJPEGRepresentation(img, 0.5);
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iafb.jpg"];
            if (jpg.length && [jpg writeToFile:path atomically:NO]) return [@"OK fb " stringByAppendingString:path];
            return @"ERR fb write";
        }
        if ([verb isEqualToString:@"OCR"]) return IAOcr();
        if ([verb isEqualToString:@"OCRIMG"] && p.count >= 3) {   // "OCRIMG <lang> <b64> [rx ry rw rh]"
            CGRect rgn = CGRectZero;                              // vùng point (tuỳ chọn) → Vision ROI
            if (p.count >= 7) rgn = CGRectMake([p[3] floatValue], [p[4] floatValue],
                                               [p[5] floatValue], [p[6] floatValue]);
            return IAOcrImage(p[2], p[1], rgn);
        }
        if ([verb isEqualToString:@"COPYB64"]) return IACopyB64(p.count >= 2 ? p[1] : @"");    // đặt clipboard
        if ([verb isEqualToString:@"CLIP"]) return IAClip();                                    // read clipboard
        if ([verb isEqualToString:@"TOASTB64"]) return IAToastB64(p.count >= 2 ? p[1] : @"2", p.count >= 3 ? p[2] : @"");
        if ([verb isEqualToString:@"WAKE"]) return IAWake();
        if ([verb isEqualToString:@"AIRPLANE"] && p.count >= 2) return IAAirplane([p[1] intValue]);
        if ([verb isEqualToString:@"HOME"]) return IAHome();
        if ([verb isEqualToString:@"SWITCHER"]) return IASwitcher();
        if ([verb isEqualToString:@"SHOT"]) return IAShot();
        if ([verb isEqualToString:@"INFO"]) {
            // Chạy trên THREAD NỀN → TUYỆT ĐỐI không message [UIScreen mainScreen] ở đây: lúc SpringBoard
            // cold-boot UIScreen chưa +initialize, message từ nền sẽ kích +initialize trên nền → FBScene
            // main-thread-violation → SIGTRAP → Safe Mode loop (xem IARefreshScreenSize). Bundle lấy trực
            // tiếp (an toàn off-main, luôn đúng → prefer_sb nhận ra SpringBoard ngay). Kích thước lấy từ
            // CACHE do main điền; nếu chưa kịp (0 0) daemon vẫn đăng ký đúng bundle & sẽ INFO lại sau.
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
            if (gScreenW == 0 || gScreenH == 0) IARefreshScreenSize();   // yêu cầu main điền cho lần sau
            return [NSString stringWithFormat:@"OK %@ %d %d", bid, gScreenW, gScreenH];
        }
        if ([verb isEqualToString:@"PING"])
            return [NSString stringWithFormat:@"OK pong %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"?"];
    } @catch (NSException *e) { return [@"ERR " stringByAppendingString:(e.reason ?: @"?")]; }
    return @"ERR unknown-verb";
}

- (BOOL)isSpringBoard {
    static int sb = -1;
    if (sb < 0) sb = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"] ? 1 : 0;
    return sb == 1;
}
- (BOOL)isForeground {
    // SpringBoard = shell hệ thống, LUÔN coi là foreground và giữ kết nối bền.
    // iOS 16: SpringBoard KHÔNG báo applicationState=Active như iOS 15 → nếu gate theo
    // Active thì SpringBoard không bao giờ kết nối relay (SHOT/OCR/màn đầy đủ chết).
    if ([self isSpringBoard]) return YES;
    return gAppActive != 0;   // cờ cache theo notification — nhanh, tin cậy
}
- (void)connectAndServe {
    if (self.fd >= 0) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(TOUCH_PORT);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); return; }
    self.fd = fd;
    char buf[256]; std::string acc;
    for (;;) {
        fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
        struct timeval tv = { 1, 0 };
        int s = select(fd + 1, &rf, NULL, NULL, &tv);
        if (s < 0) break;
        if (s == 0) { if (![self isForeground]) break; else continue; }
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n <= 0) break;
        buf[n] = '\0'; acc += buf;
        size_t nl;
        bool dead = false;
        while ((nl = acc.find('\n')) != std::string::npos) {
            std::string line = acc.substr(0, nl); acc.erase(0, nl + 1);
            // BẮT BUỘC @autoreleasepool: thread này chạy mãi (pool cấp-thread chỉ drain khi
            // thread thoát). Mỗi SHOT tạo UIImage/NSData/JPEG autoreleased — không có pool
            // thì tích luỹ vô hạn → SpringBoard phình RAM → jetsam/respring liên tục.
            @autoreleasepool {
                NSString *reply = [[self handle:[NSString stringWithUTF8String:line.c_str()]] stringByAppendingString:@"\n"];
                const char *rb = reply.UTF8String;
                if (write(fd, rb, strlen(rb)) <= 0) dead = true;
            }
            if (dead) break;
        }
    }
    close(fd); self.fd = -1;
}
- (void)threadMain {
    while (![NSThread currentThread].isCancelled) {
        if ([self isForeground]) [self connectAndServe];
        [NSThread sleepForTimeInterval:1.0];
    }
}
- (void)start { if (!self.thread) { self.thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil]; [self.thread start]; } }
@end

// ============================================================================
// SPOOF ĐỊNH DANH THIẾT BỊ THEO APP — đọc bảng gán do daemon ghi
// (/var/jb/var/mobile/Library/Preferences/com.iosauto.deviceprofiles.plist), chỉ kích
// hoạt cho app CÓ gán. KHÔNG spoof kích thước màn (dễ vỡ layout). Best-effort: phần C
// (hw.machine / uname / MobileGestalt) chỉ hook khi có MSHookFunction (ElleKit); thiếu
// thì các swizzle ObjC vẫn chạy.
// ============================================================================
#define IA_PROFILES_PLIST @"/var/jb/var/mobile/Library/Preferences/com.iosauto.deviceprofiles.plist"

static NSDictionary *gSpoof = nil;     // profile áp cho tiến trình này (nil = tắt spoof)
static char gSpoofHW[64] = {0};        // hardwareIdentifier dạng C (rỗng = không đổi)

static NSString *IASpoofStr(NSString *k) {
    id v = gSpoof[k];
    return ([v isKindOfClass:NSString.class] && [v length]) ? v : nil;
}

// ---- swizzle method trả về object (instance hoặc class), giữ IMP gốc trong *slot ----
static void IASwizzleRet(Method m, id (^blk)(id), IMP *slot) {
    if (!m) return;
    IMP imp = imp_implementationWithBlock(blk);
    IMP old = method_setImplementation(m, imp);
    if (slot) *slot = old;
}

// ---- hook hàm C qua MSHookFunction (ElleKit) nếu có ----
typedef void (*IAMSHookFn)(void *sym, void *repl, void **orig);
static IAMSHookFn IAHookFn(void) {
    static IAMSHookFn f = NULL; static int tried = 0;
    if (!tried) { tried = 1; f = (IAMSHookFn)dlsym(RTLD_DEFAULT, "MSHookFunction"); }
    return f;
}

static int (*ia_orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int ia_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && gSpoofHW[0] && strcmp(name, "hw.machine") == 0) {
        size_t need = strlen(gSpoofHW) + 1;
        if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }
        if (oldlenp && *oldlenp >= need) { memcpy(oldp, gSpoofHW, need); *oldlenp = need; return 0; }
        if (oldlenp) *oldlenp = need; errno = ENOMEM; return -1;
    }
    return ia_orig_sysctlbyname ? ia_orig_sysctlbyname(name, oldp, oldlenp, newp, newlen)
                                : sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int (*ia_orig_uname)(struct utsname *) = NULL;
static int ia_uname(struct utsname *u) {
    int r = ia_orig_uname ? ia_orig_uname(u) : uname(u);
    if (r == 0 && u && gSpoofHW[0]) strlcpy(u->machine, gSpoofHW, sizeof(u->machine));
    return r;
}

static CFTypeRef (*ia_orig_MGCopyAnswer)(CFStringRef) = NULL;
static CFTypeRef ia_MGCopyAnswer(CFStringRef key) {
    if (key) {
        if (CFEqual(key, CFSTR("ProductType")) && gSpoofHW[0])
            return CFStringCreateWithCString(NULL, gSpoofHW, kCFStringEncodingUTF8);
        if (CFEqual(key, CFSTR("ProductVersion"))) {
            NSString *v = IASpoofStr(@"systemVersion");
            if (v) return (__bridge_retained CFStringRef)[v copy];
        }
    }
    return ia_orig_MGCopyAnswer ? ia_orig_MGCopyAnswer(key) : NULL;
}

static void IAApplyDeviceSpoof(NSString *bundleId) {
    @autoreleasepool {
        if (!bundleId.length) return;
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:IA_PROFILES_PLIST];
        if (![root isKindOfClass:NSDictionary.class]) return;

        // App chỉ được spoof nếu nằm trong target list (per-app profile tự đưa vào list qua daemon).
        NSDictionary *perApp = [root[bundleId] isKindOfClass:NSDictionary.class] ? root[bundleId] : nil;
        NSArray *targets = [root[@"_targets"] isKindOfClass:NSArray.class] ? root[@"_targets"] : nil;
        BOOL isTarget = (perApp != nil) || (targets && [targets containsObject:bundleId]);
        if (!isTarget) return;   // không phải target → không spoof

        // Effective = _global làm nền, per-app đè lên (field cụ thể của app thắng).
        NSDictionary *global = [root[@"_global"] isKindOfClass:NSDictionary.class] ? root[@"_global"] : nil;
        NSMutableDictionary *eff = [NSMutableDictionary dictionary];
        if (global) [eff addEntriesFromDictionary:global];
        if (perApp) [eff addEntriesFromDictionary:perApp];
        gSpoof = eff;

        NSString *hw = IASpoofStr(@"hardwareIdentifier");
        if (hw) strlcpy(gSpoofHW, hw.UTF8String, sizeof(gSpoofHW));

        // --- ObjC swizzles (an toàn, luôn chạy) ---
        static IMP o_sysver, o_name, o_locale, o_autolocale, o_localtz, o_systz;
        NSString *sysver = IASpoofStr(@"systemVersion");
        if (sysver) {
            IASwizzleRet(class_getInstanceMethod(UIDevice.class, @selector(systemVersion)),
                         ^id(__unused id s) { return [sysver copy]; }, &o_sysver);
        }
        NSString *devname = IASpoofStr(@"deviceName");
        if (devname) {
            IASwizzleRet(class_getInstanceMethod(UIDevice.class, @selector(name)),
                         ^id(__unused id s) { return [devname copy]; }, &o_name);
        }
        // Locale + Region: regionCode (spoof.region) đè phần vùng của locale → NSLocale.countryCode giả.
        NSString *locId = IASpoofStr(@"localeIdentifier");
        NSString *region = IASpoofStr(@"regionCode");
        if (region.length) {
            NSString *lang = @"en";
            if (locId.length) {
                NSArray *pp = [[locId stringByReplacingOccurrencesOfString:@"-" withString:@"_"] componentsSeparatedByString:@"_"];
                if (pp.count && [pp[0] length]) lang = pp[0];
            }
            locId = [NSString stringWithFormat:@"%@_%@", lang, region.uppercaseString];
        }
        if (locId.length) {
            NSLocale *loc = [NSLocale localeWithLocaleIdentifier:locId];
            IASwizzleRet(class_getClassMethod(NSLocale.class, @selector(currentLocale)),
                         ^id(__unused id s) { return loc; }, &o_locale);
            IASwizzleRet(class_getClassMethod(NSLocale.class, @selector(autoupdatingCurrentLocale)),
                         ^id(__unused id s) { return loc; }, &o_autolocale);
        }
        NSString *tzId = IASpoofStr(@"timezoneIdentifier");
        if (tzId) {
            NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzId];
            if (tz) {
                IASwizzleRet(class_getClassMethod(NSTimeZone.class, @selector(localTimeZone)),
                             ^id(__unused id s) { return tz; }, &o_localtz);
                IASwizzleRet(class_getClassMethod(NSTimeZone.class, @selector(systemTimeZone)),
                             ^id(__unused id s) { return tz; }, &o_systz);
            }
        }

        // --- hook hàm C (chỉ khi có MSHookFunction) ---
        IAMSHookFn H = IAHookFn();
        if (H && gSpoofHW[0]) {
            H((void *)&sysctlbyname, (void *)ia_sysctlbyname, (void **)&ia_orig_sysctlbyname);
            H((void *)&uname,        (void *)ia_uname,        (void **)&ia_orig_uname);
            void *mg = dlsym(RTLD_DEFAULT, "MGCopyAnswer");
            if (mg) H(mg, (void *)ia_MGCopyAnswer, (void **)&ia_orig_MGCopyAnswer);
        }
        NSLog(@"[iOSAuto] spoof áp cho %@: %@ / iOS %@", bundleId, hw ?: @"-", sysver ?: @"-");
    }
}

__attribute__((constructor))
static void IAInit(void) {
    @autoreleasepool {
        // CHỈ app thật (bundle .app, gồm SpringBoard.app) mới làm touch client.
        // Loại mọi daemon/helper/extension (WallpaperMigrator, file provider…) — chúng
        // cũng link UIKit nên bị inject nhưng không phải app foreground, gây chiếm lệnh.
        NSString *bp = [NSBundle mainBundle].bundlePath;
        if (!bp || ![bp hasSuffix:@".app"]) return;
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"];
        // KHÔNG chạy BẤT KỲ việc ObjC/AX/UIScreen/plist/observer NÀO ĐỒNG BỘ trên luồng dlopen lúc
        // process-launch. Ctor được systemhook gọi giữa lúc app đang launch (thường trên MAIN); mọi
        // lệnh ObjC ở đây đua khoá với thread launch nền của app → ABBA deadlock TREO LAUNCH. Đã trúng
        // 2 chỗ: SpringBoard cold-boot (→ watchdog → Safe Mode loop, iPhone7/iOS15) và MobileSafari khi
        // launch CHẬM sau clearAppData (→ process-launch watchdog 0x8badf00d 20s → MÀN TRẮNG). Kiểm
        // chứng .218: gỡ tweak khỏi Safari (chỉ đổi filter, không đụng gì khác) → hết trắng màn hoàn
        // toàn; để tweak vào lại → tái hiện. Fix: DỜI TOÀN BỘ setup sang main qua dispatch_async —
        // block chạy SERIALIZED trên main KHI main đã rảnh (qua đoạn launch nghẽn) nên KHÔNG còn chạy
        // song song với thread launch → hết ABBA. Riêng AX + start (nặng khoá nhất) để trong
        // dispatch_after 1s cho thêm biên an toàn.
        dispatch_async(dispatch_get_main_queue(), ^{
          @autoreleasepool {
            // Spoof định danh theo app (chỉ app CÓ gán). Bỏ qua SpringBoard & app iosauto.
            if (!isSB && ![bid hasPrefix:@"com.iosauto"]) IAApplyDeviceSpoof(bid);
            IARefreshScreenSize();   // điền cache kích thước màn (trên main, đã qua launch) → INFO khỏi đụng UIScreen ở nền

            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                        usingBlock:^(NSNotification *n) { gAppActive = 1; IARefreshScreenSize(); [[IAClient shared] start]; }];
            [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
                        usingBlock:^(NSNotification *n) { gAppActive = 1; IARefreshScreenSize(); [[IAClient shared] start]; }];
            // KHÔNG hạ cờ ở WillResignActive: prompt hệ thống (Lưu mật khẩu/AutoFill, Control Center,
            // banner) chỉ làm app INACTIVE (vẫn hiển thị, WKWebView vẫn chạy JS) — nếu hạ cờ ở đây thì
            // tweak Safari NGẮT kết nối → web verb (safari.fill/click) rơi xuống SpringBoard → "cần app
            // foreground" dù máy vẫn đang ở Safari. Chỉ hạ khi app THẬT SỰ vào nền (DidEnterBackground).
            [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                        usingBlock:^(NSNotification *n) {
                gAppActive = 0;
                // NGẮT relay NGAY khi vào nền (trước khi bị OS đóng băng). Nếu không, app đóng băng vẫn
                // là client → daemon thử nó trước cho TAP/SWIPE → timeout ~1s mỗi lần (sau HOME thấy như
                // tap/vuốt không ăn). shutdown() đánh thức select trong connectAndServe → thread thoát.
                if (!isSB) { int fd = [IAClient shared].fd; if (fd >= 0) shutdown(fd, SHUT_RDWR); }
            }];
          }
        });
        // AX + khởi động client: nặng khoá nhất → để trong dispatch_after 1s (chạy khi main runloop đã
        // quay, qua hẳn cửa sổ nguy hiểm). SpringBoard có thể KHÔNG phát DidBecomeActive và KHÔNG ở
        // state Active → phải chủ động start ở đây.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IAEnableAX();   // bật AX cho MỌI app SAU launch (đã qua cửa sổ deadlock) — WebKit dựng cây AX lấy chữ trong WebView
            @try { if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) gAppActive = 1; } @catch (__unused NSException *e) {}
            if (isSB || gAppActive) [[IAClient shared] start];
        });
    }
}
