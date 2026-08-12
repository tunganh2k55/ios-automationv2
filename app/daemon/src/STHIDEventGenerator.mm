/*
 * STHIDEventGenerator - TrollVNC HID Event Generator
 * Adapted from TrollVNC (https://github.com/OwnGoalStudio/TrollVNC)
 * Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 * Licensed under GPL-2.0
 *
 * Uses dlopen/dlsym to load private IOKit HID symbols at runtime.
 */

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

#import "IOKitSPI.h"
#import "STHIDEventGenerator.h"
#import "log.h"

static const NSTimeInterval fingerLiftDelay = 0.05;
static const NSTimeInterval multiTapInterval = 0.15;
static const NSTimeInterval fingerMoveInterval = 0.016;
static const NSTimeInterval longPressHoldDelay = 2.0;
static const IOHIDFloat defaultMajorRadius = 5;
static const IOHIDFloat defaultPathPressure = 0;
static const long nanosecondsPerSecond = 1e9;

static int fingerIdentifiers[] = {
    2, 3, 4, 5, 1, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
};

typedef enum {
    HandEventNull,
    HandEventTouched,
    HandEventMoved,
    HandEventChordChanged,
    HandEventLifted,
    HandEventCanceled,
} HandEventType;

typedef struct {
    int identifier;
    CGPoint point;
    IOHIDFloat pathMajorRadius;
    IOHIDFloat pathPressure;
    UInt8 pathProximity;
} SyntheticEventDigitizerInfo;

#pragma mark - Dynamic IOKit Symbol Loading

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFunc)(CFAllocatorRef, uint64_t, IOHIDDigitizerTransducerType, uint32_t, uint32_t, IOHIDDigitizerEventMask, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFunc)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, IOHIDDigitizerEventMask, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOHIDEventOptionBits);
typedef IOHIDEventRef (*IOHIDEventCreateKeyboardEventFunc)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, IOOptionBits);
typedef void (*IOHIDEventSetIntegerValueFunc)(IOHIDEventRef, IOHIDEventField, CFIndex);
typedef void (*IOHIDEventSetFloatValueFunc)(IOHIDEventRef, IOHIDEventField, IOHIDFloat);
typedef void (*IOHIDEventSetSenderIDFunc)(IOHIDEventRef, uint64_t);
typedef void (*IOHIDEventAppendEventFunc)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreateFunc)(CFAllocatorRef);
typedef void (*IOHIDEventSystemClientDispatchEventFunc)(IOHIDEventSystemClientRef, IOHIDEventRef);

static IOHIDEventCreateDigitizerEventFunc _IOHIDEventCreateDigitizerEvent = NULL;
static IOHIDEventCreateDigitizerFingerEventFunc _IOHIDEventCreateDigitizerFingerEvent = NULL;
static IOHIDEventCreateKeyboardEventFunc _IOHIDEventCreateKeyboardEvent = NULL;
static IOHIDEventSetIntegerValueFunc _IOHIDEventSetIntegerValue = NULL;
static IOHIDEventSetFloatValueFunc _IOHIDEventSetFloatValue = NULL;
static IOHIDEventSetSenderIDFunc _IOHIDEventSetSenderID = NULL;
static IOHIDEventAppendEventFunc _IOHIDEventAppendEvent = NULL;
static IOHIDEventSystemClientCreateFunc _IOHIDEventSystemClientCreate = NULL;
static IOHIDEventSystemClientDispatchEventFunc _IOHIDEventSystemClientDispatchEvent = NULL;

static BOOL gIOKitLoaded = NO;

static void loadIOKitSymbols(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!iokit) {
            log_msg("STHIDEventGenerator: Failed to load IOKit framework");
            return;
        }

        _IOHIDEventCreateDigitizerEvent = (IOHIDEventCreateDigitizerEventFunc)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
        _IOHIDEventCreateDigitizerFingerEvent = (IOHIDEventCreateDigitizerFingerEventFunc)dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
        _IOHIDEventCreateKeyboardEvent = (IOHIDEventCreateKeyboardEventFunc)dlsym(iokit, "IOHIDEventCreateKeyboardEvent");
        _IOHIDEventSetIntegerValue = (IOHIDEventSetIntegerValueFunc)dlsym(iokit, "IOHIDEventSetIntegerValue");
        _IOHIDEventSetFloatValue = (IOHIDEventSetFloatValueFunc)dlsym(iokit, "IOHIDEventSetFloatValue");
        _IOHIDEventSetSenderID = (IOHIDEventSetSenderIDFunc)dlsym(iokit, "IOHIDEventSetSenderID");
        _IOHIDEventAppendEvent = (IOHIDEventAppendEventFunc)dlsym(iokit, "IOHIDEventAppendEvent");
        _IOHIDEventSystemClientCreate = (IOHIDEventSystemClientCreateFunc)dlsym(iokit, "IOHIDEventSystemClientCreate");
        _IOHIDEventSystemClientDispatchEvent = (IOHIDEventSystemClientDispatchEventFunc)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");

        if (_IOHIDEventCreateDigitizerEvent && _IOHIDEventCreateDigitizerFingerEvent &&
            _IOHIDEventSetIntegerValue && _IOHIDEventSetFloatValue &&
            _IOHIDEventSetSenderID && _IOHIDEventAppendEvent &&
            _IOHIDEventSystemClientCreate && _IOHIDEventSystemClientDispatchEvent) {
            gIOKitLoaded = YES;
            log_msg("STHIDEventGenerator: IOKit symbols loaded successfully");
        } else {
            log_msg("STHIDEventGenerator: Failed to load some IOKit symbols");
        }
    });
}

NS_INLINE CFTimeInterval secondsSinceAbsoluteTime(CFAbsoluteTime startTime) {
    return (CFAbsoluteTimeGetCurrent() - startTime);
}

NS_INLINE double linearInterpolation(double a, double b, double t) {
    return (a + (b - a) * t);
}

NS_INLINE CGPoint calculateNextLinearLocation(CGPoint a, CGPoint b, CFTimeInterval t) {
    return CGPointMake(linearInterpolation(a.x, b.x, t), linearInterpolation(a.y, b.y, t));
}

NS_INLINE void delayBetweenMove(int eventIndex, double elapsed) {
    double delay = (eventIndex * fingerMoveInterval) - elapsed;
    if (delay > 0) {
        struct timespec moveDelay = {0, (long)(delay * nanosecondsPerSecond)};
        nanosleep(&moveDelay, NULL);
    }
}

@implementation STHIDEventGenerator {
    SyntheticEventDigitizerInfo _activePoints[HIDMaxTouchCount];
    NSUInteger _activePointCount;
    CGSize _physicalScreenSize;
    dispatch_queue_t _hidEventQueue;
}

+ (STHIDEventGenerator *)sharedGenerator {
    static STHIDEventGenerator *_eventGenerator = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            _eventGenerator = [[STHIDEventGenerator alloc] init];
        }
    });
    return _eventGenerator;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    loadIOKitSymbols();

    _physicalScreenSize = CGSizeMake(1170, 2532);

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _hidEventQueue = dispatch_queue_create("com.iosauto.hid-events", attr);

    for (NSUInteger i = 0; i < HIDMaxTouchCount; ++i)
        _activePoints[i].identifier = fingerIdentifiers[i];

    return self;
}

- (void)setPhysicalScreenSize:(CGSize)size {
    _physicalScreenSize = size;
    log_msg("STHIDEventGenerator: screen size set to %.0fx%.0f", size.width, size.height);
}

- (BOOL)isAvailable {
    return gIOKitLoaded;
}

#pragma mark - HID Event Creation

- (IOHIDEventRef)_createIOHIDEventType:(HandEventType)eventType {
    if (!gIOKitLoaded) return NULL;

    BOOL isTouching = (eventType == HandEventTouched || eventType == HandEventMoved || eventType == HandEventChordChanged);

    IOHIDDigitizerEventMask eventMask = kIOHIDDigitizerEventTouch;
    if (eventType == HandEventMoved) {
        eventMask &= ~kIOHIDDigitizerEventTouch;
        eventMask |= kIOHIDDigitizerEventPosition;
        eventMask |= kIOHIDDigitizerEventAttribute;
    } else if (eventType == HandEventChordChanged) {
        eventMask |= kIOHIDDigitizerEventPosition;
        eventMask |= kIOHIDDigitizerEventAttribute;
    } else if (eventType == HandEventTouched || eventType == HandEventCanceled || eventType == HandEventLifted) {
        eventMask |= kIOHIDDigitizerEventIdentity;
    }

    uint64_t machTime = mach_absolute_time();
    IOHIDEventRef eventRef = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, machTime, kIOHIDDigitizerTransducerTypeHand, 0, 0,
        eventMask, 0, 0, 0, 0, 0, 0, 0, isTouching, kIOHIDEventOptionNone);

    if (!eventRef) return NULL;

    _IOHIDEventSetIntegerValue(eventRef, kIOHIDEventFieldIsBuiltIn, 1);
    _IOHIDEventSetIntegerValue(eventRef, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    for (NSUInteger i = 0; i < _activePointCount; ++i) {
        SyntheticEventDigitizerInfo *pointInfo = &_activePoints[i];

        if (eventType == HandEventTouched) {
            if (!pointInfo->pathMajorRadius) pointInfo->pathMajorRadius = defaultMajorRadius;
            if (!pointInfo->pathPressure) pointInfo->pathPressure = defaultPathPressure;
            if (!pointInfo->pathProximity) pointInfo->pathProximity = kGSEventPathInfoInTouch | kGSEventPathInfoInRange;
        } else if (eventType == HandEventLifted || eventType == HandEventCanceled) {
            pointInfo->pathMajorRadius = 0;
            pointInfo->pathPressure = 0;
            pointInfo->pathProximity = 0;
        }

        CGPoint point = pointInfo->point;
        point = CGPointMake(point.x / _physicalScreenSize.width, point.y / _physicalScreenSize.height);

        IOHIDEventRef subEvent = _IOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault,
            machTime,
            pointInfo->identifier,
            pointInfo->identifier,
            eventMask,
            point.x, point.y, 0,
            pointInfo->pathPressure,
            90.0,
            pointInfo->pathProximity & kGSEventPathInfoInRange,
            pointInfo->pathProximity & kGSEventPathInfoInTouch,
            kIOHIDEventOptionNone);

        if (subEvent) {
            _IOHIDEventSetFloatValue(subEvent, kIOHIDEventFieldDigitizerMinorRadius, pointInfo->pathMajorRadius);
            _IOHIDEventSetFloatValue(subEvent, kIOHIDEventFieldDigitizerMajorRadius, pointInfo->pathMajorRadius);
            _IOHIDEventAppendEvent(eventRef, subEvent, 0);
            CFRelease(subEvent);
        }
    }

    return eventRef;
}

static void _sendHIDEvent(IOHIDEventRef eventRef, dispatch_queue_t queue) {
    if (!gIOKitLoaded || !eventRef) return;

    static IOHIDEventSystemClientRef _ioSystemClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            _ioSystemClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        }
    });

    if (_ioSystemClient) {
        IOHIDEventRef strongEvent = (IOHIDEventRef)CFRetain(eventRef);
        dispatch_async(queue, ^{
            _IOHIDEventSetSenderID(strongEvent, 0x8000000817319371);
            _IOHIDEventSystemClientDispatchEvent(_ioSystemClient, strongEvent);
            CFRelease(strongEvent);
        });
    }
}

#pragma mark - Touch Methods

- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count {
    if (!gIOKitLoaded) return;
    NSParameterAssert(count > 0);

    HandEventType handEventType;
    if (!_activePointCount)
        handEventType = HandEventTouched;
    else if (!count)
        handEventType = HandEventLifted;
    else if (count == _activePointCount)
        handEventType = HandEventMoved;
    else
        handEventType = HandEventChordChanged;

    _activePointCount = count;

    for (NSUInteger i = 0; i < count; ++i) {
        _activePoints[i].point = points[i];
    }

    IOHIDEventRef eventRef = [self _createIOHIDEventType:handEventType];
    if (eventRef) {
        _sendHIDEvent(eventRef, _hidEventQueue);
        CFRelease(eventRef);
    }
}

- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount {
    if (!gIOKitLoaded) return;
    NSParameterAssert(touchCount > 0);
    touchCount = MIN(touchCount, HIDMaxTouchCount);

    _activePointCount = touchCount;

    for (NSUInteger index = 0; index < touchCount; ++index) {
        _activePoints[index].point = locations[index];
    }

    IOHIDEventRef eventRef = [self _createIOHIDEventType:HandEventTouched];
    if (eventRef) {
        _sendHIDEvent(eventRef, _hidEventQueue);
        CFRelease(eventRef);
    }
}

- (void)touchDown:(CGPoint)location {
    [self touchDownAtPoints:&location touchCount:1];
}

- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount {
    if (!gIOKitLoaded) return;
    NSParameterAssert(touchCount > 0);
    touchCount = MIN(touchCount, HIDMaxTouchCount);
    touchCount = MIN(touchCount, _activePointCount);

    NSUInteger newPointCount = _activePointCount - touchCount;

    for (NSUInteger index = 0; index < touchCount; ++index) {
        _activePoints[newPointCount + index].point = locations[index];
    }

    IOHIDEventRef eventRef = [self _createIOHIDEventType:HandEventLifted];
    if (eventRef) {
        _sendHIDEvent(eventRef, _hidEventQueue);
        CFRelease(eventRef);
    }

    _activePointCount = newPointCount;
}

- (void)liftUp:(CGPoint)location {
    [self liftUpAtPoints:&location touchCount:1];
}

- (void)_moveLinearToPoints:(CGPoint *)newLocations touchCount:(NSUInteger)touchCount duration:(NSTimeInterval)seconds {
    if (!gIOKitLoaded) return;
    NSParameterAssert(seconds > 0.0);
    touchCount = MIN(touchCount, HIDMaxTouchCount);

    CGPoint startLocations[HIDMaxTouchCount];
    CGPoint nextLocations[HIDMaxTouchCount];

    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    CFTimeInterval elapsed = 0;

    int eventIndex = 0;
    while (elapsed < (seconds - fingerMoveInterval)) {
        elapsed = secondsSinceAbsoluteTime(startTime);
        CFTimeInterval interval = elapsed / seconds;

        for (NSUInteger i = 0; i < touchCount; ++i) {
            if (!eventIndex) startLocations[i] = _activePoints[i].point;
            nextLocations[i] = calculateNextLinearLocation(startLocations[i], newLocations[i], interval);
        }
        [self _updateTouchPoints:nextLocations count:touchCount];
        delayBetweenMove(eventIndex++, elapsed);
    }

    [self _updateTouchPoints:newLocations count:touchCount];
}

#pragma mark - Gestures

- (void)tap:(CGPoint)location {
    struct timespec pressDelay = {0, (long)(fingerLiftDelay * nanosecondsPerSecond)};
    [self touchDown:location];
    nanosleep(&pressDelay, 0);
    [self liftUp:location];
}

- (void)doubleTap:(CGPoint)location {
    struct timespec doubleDelay = {0, (long)(multiTapInterval * nanosecondsPerSecond)};
    struct timespec pressDelay = {0, (long)(fingerLiftDelay * nanosecondsPerSecond)};

    [self touchDown:location];
    nanosleep(&pressDelay, 0);
    [self liftUp:location];
    nanosleep(&doubleDelay, 0);
    [self touchDown:location];
    nanosleep(&pressDelay, 0);
    [self liftUp:location];
}

- (void)longPress:(CGPoint)location {
    struct timespec longPressDelay = {0, (long)(longPressHoldDelay * nanosecondsPerSecond)};
    [self touchDown:location];
    nanosleep(&longPressDelay, 0);
    [self liftUp:location];
}

- (void)dragLinearWithStartPoint:(CGPoint)startLocation endPoint:(CGPoint)endLocation duration:(NSTimeInterval)seconds {
    if (!gIOKitLoaded) return;
    NSParameterAssert(seconds > 0.0);
    [self touchDown:startLocation];
    [self _moveLinearToPoints:&endLocation touchCount:1 duration:seconds];
    [self liftUp:endLocation];
}

#pragma mark - Keyboard Events

- (void)_sendIOHIDKeyboardEvent:(uint32_t)page usage:(uint32_t)usage isKeyDown:(boolean_t)isKeyDown {
    if (!gIOKitLoaded || !_IOHIDEventCreateKeyboardEvent) return;

    IOHIDEventRef eventRef = _IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, mach_absolute_time(), page, usage, isKeyDown, kIOHIDEventOptionNone);
    if (eventRef) {
        _sendHIDEvent(eventRef, _hidEventQueue);
        CFRelease(eventRef);
    }
}

- (void)menuPress {
    struct timespec pressDelay = {0, (long)(fingerLiftDelay * nanosecondsPerSecond)};
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Menu isKeyDown:true];
    nanosleep(&pressDelay, 0);
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Menu isKeyDown:false];
}

- (void)menuDown {
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Menu isKeyDown:true];
}

- (void)menuUp {
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Menu isKeyDown:false];
}

- (void)powerPress {
    struct timespec pressDelay = {0, (long)(fingerLiftDelay * nanosecondsPerSecond)};
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Power isKeyDown:true];
    nanosleep(&pressDelay, 0);
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Power isKeyDown:false];
}

- (void)powerDown {
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Power isKeyDown:true];
}

- (void)powerUp {
    [self _sendIOHIDKeyboardEvent:kHIDPage_Consumer usage:kHIDUsage_Csmr_Power isKeyDown:false];
}

static uint32_t hidUsageCodeForCharacter(NSString *key) {
    const int lowercaseAlphabeticOffset = 'a' - kHIDUsage_KeyboardA;
    const int uppercaseAlphabeticOffset = 'A' - kHIDUsage_KeyboardA;
    const int numericNonZeroOffset = '1' - kHIDUsage_Keyboard1;

    if (key.length == 1) {
        int keyCode = [key characterAtIndex:0];
        if (97 <= keyCode && keyCode <= 122) return keyCode - lowercaseAlphabeticOffset;
        if (65 <= keyCode && keyCode <= 90) return keyCode - uppercaseAlphabeticOffset;
        if (49 <= keyCode && keyCode <= 57) return keyCode - numericNonZeroOffset;

        switch (keyCode) {
            case '0': return kHIDUsage_Keyboard1 + 9;
            case ' ': return kHIDUsage_KeyboardSpacebar;
            case '\n': case '\r': return kHIDUsage_KeyboardReturnOrEnter;
            case '\t': return kHIDUsage_KeyboardTab;
            case '\b': return kHIDUsage_KeyboardDeleteOrBackspace;
            case '.': return kHIDUsage_KeyboardPeriod;
            case ',': return kHIDUsage_KeyboardComma;
            case '-': return kHIDUsage_KeyboardHyphen;
            case '=': return kHIDUsage_KeyboardEqualSign;
            case '/': return kHIDUsage_KeyboardSlash;
            case ';': return kHIDUsage_KeyboardSemicolon;
            case '\'': return kHIDUsage_KeyboardQuote;
            case '[': return kHIDUsage_KeyboardOpenBracket;
            case ']': return kHIDUsage_KeyboardCloseBracket;
            case '\\': return kHIDUsage_KeyboardBackslash;
            case '`': return kHIDUsage_KeyboardGraveAccentAndTilde;
        }
    }
    return 0;
}

- (void)keyPress:(NSString *)character {
    struct timespec pressDelay = {0, (long)(fingerLiftDelay * nanosecondsPerSecond)};
    uint32_t usage = hidUsageCodeForCharacter(character);
    if (usage == 0) return;

    [self _sendIOHIDKeyboardEvent:kHIDPage_KeyboardOrKeypad usage:usage isKeyDown:true];
    nanosleep(&pressDelay, 0);
    [self _sendIOHIDKeyboardEvent:kHIDPage_KeyboardOrKeypad usage:usage isKeyDown:false];
}

- (void)keyDown:(NSString *)character {
    uint32_t usage = hidUsageCodeForCharacter(character);
    if (usage == 0) return;
    [self _sendIOHIDKeyboardEvent:kHIDPage_KeyboardOrKeypad usage:usage isKeyDown:true];
}

- (void)keyUp:(NSString *)character {
    uint32_t usage = hidUsageCodeForCharacter(character);
    if (usage == 0) return;
    [self _sendIOHIDKeyboardEvent:kHIDPage_KeyboardOrKeypad usage:usage isKeyDown:false];
}

@end

// C wrapper để touch.c có thể gọi tap HID
// x,y là tọa độ POINT (từ tweak/UIKit). STHIDEventGenerator dùng tọa độ PIXEL.
// Nhân với UIScreen.scale để chuyển đổi.
extern "C" void sthid_tap(float x, float y) {
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    if ([gen isAvailable]) {
        CGFloat scale = [UIScreen mainScreen].scale;  // @2x hoặc @3x
        CGPoint pixelPt = CGPointMake(x * scale, y * scale);
        [gen tap:pixelPt];
    }
}

extern "C" int sthid_available(void) {
    return [[STHIDEventGenerator sharedGenerator] isAvailable] ? 1 : 0;
}
