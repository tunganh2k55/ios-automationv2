/*
 * IOKit Private API Headers for HID Event Generation
 * Extracted from Apple WebKit and TrollVNC sources
 */

#ifndef IOKitSPI_h
#define IOKitSPI_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef double IOHIDFloat;

enum {
    kIOHIDEventOptionNone = 0,
};

typedef UInt32 IOOptionBits;
typedef uint32_t IOHIDEventOptionBits;
typedef uint32_t IOHIDEventField;
typedef kern_return_t IOReturn;

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef void *IOHIDEventQueueRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

#define IOHIDEventFieldBase(type) (type << 16)

enum {
    kHIDPage_KeyboardOrKeypad = 0x07,
    kHIDPage_Telephony = 0x0B,
    kHIDPage_Consumer = 0x0C,
    kHIDPage_VendorDefinedStart = 0xFF00
};

enum {
    kIOHIDDigitizerEventRange = 1 << 0,
    kIOHIDDigitizerEventTouch = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
    kIOHIDDigitizerEventIdentity = 1 << 5,
    kIOHIDDigitizerEventAttribute = 1 << 6,
    kIOHIDDigitizerEventCancel = 1 << 7,
    kIOHIDDigitizerEventStart = 1 << 8,
    kIOHIDDigitizerEventEstimatedAltitude = 1 << 28,
    kIOHIDDigitizerEventEstimatedAzimuth = 1 << 29,
    kIOHIDDigitizerEventEstimatedPressure = 1 << 30,
};
typedef uint32_t IOHIDDigitizerEventMask;

enum {
    kIOHIDEventTypeNULL,
    kIOHIDEventTypeVendorDefined,
    kIOHIDEventTypeKeyboard = 3,
    kIOHIDEventTypeRotation = 5,
    kIOHIDEventTypeScroll = 6,
    kIOHIDEventTypeZoom = 8,
    kIOHIDEventTypeDigitizer = 11,
    kIOHIDEventTypeNavigationSwipe = 16,
    kIOHIDEventTypeForce = 32,
};
typedef uint32_t IOHIDEventType;

enum {
    kIOHIDEventFieldIsRelative = IOHIDEventFieldBase(kIOHIDEventTypeNULL),
    kIOHIDEventFieldIsCollection,
    kIOHIDEventFieldIsPixelUnits,
    kIOHIDEventFieldIsCenterOrigin,
    kIOHIDEventFieldIsBuiltIn
};

enum {
    kIOHIDEventFieldDigitizerX = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer),
    kIOHIDEventFieldDigitizerY,
    kIOHIDEventFieldDigitizerType = kIOHIDEventFieldDigitizerX + 4,
    kIOHIDEventFieldDigitizerIndex,
    kIOHIDEventFieldDigitizerIdentity,
    kIOHIDEventFieldDigitizerEventMask,
    kIOHIDEventFieldDigitizerRange,
    kIOHIDEventFieldDigitizerTouch,
    kIOHIDEventFieldDigitizerPressure,
    kIOHIDEventFieldDigitizerBarrelPressure,
    kIOHIDEventFieldDigitizerTwist,
    kIOHIDEventFieldDigitizerMajorRadius = kIOHIDEventFieldDigitizerX + 20,
    kIOHIDEventFieldDigitizerMinorRadius,
    kIOHIDEventFieldDigitizerIsDisplayIntegrated = kIOHIDEventFieldDigitizerMajorRadius + 5,
};

enum {
    kIOHIDTransducerRange = 0x00010000,
    kIOHIDTransducerTouch = 0x00020000,
    kIOHIDTransducerInvert = 0x00040000,
    kIOHIDTransducerDisplayIntegrated = 0x00080000
};

enum {
    kIOHIDDigitizerTransducerTypeStylus = 0,
    kIOHIDDigitizerTransducerTypeFinger = 2,
    kIOHIDDigitizerTransducerTypeHand = 3
};
typedef uint32_t IOHIDDigitizerTransducerType;

enum {
    kHIDUsage_KeyboardA = 0x04,
    kHIDUsage_Keyboard1 = 0x1E,
    kHIDUsage_KeyboardReturnOrEnter = 0x28,
    kHIDUsage_KeyboardEscape = 0x29,
    kHIDUsage_KeyboardDeleteOrBackspace = 0x2A,
    kHIDUsage_KeyboardTab = 0x2B,
    kHIDUsage_KeyboardSpacebar = 0x2C,
    kHIDUsage_KeyboardHyphen = 0x2D,
    kHIDUsage_KeyboardEqualSign = 0x2E,
    kHIDUsage_KeyboardOpenBracket = 0x2F,
    kHIDUsage_KeyboardCloseBracket = 0x30,
    kHIDUsage_KeyboardBackslash = 0x31,
    kHIDUsage_KeyboardSemicolon = 0x33,
    kHIDUsage_KeyboardQuote = 0x34,
    kHIDUsage_KeyboardGraveAccentAndTilde = 0x35,
    kHIDUsage_KeyboardComma = 0x36,
    kHIDUsage_KeyboardPeriod = 0x37,
    kHIDUsage_KeyboardSlash = 0x38,
    kHIDUsage_KeyboardCapsLock = 0x39,
    kHIDUsage_KeyboardF1 = 0x3A,
    kHIDUsage_KeyboardF12 = 0x45,
    kHIDUsage_KeyboardF13 = 0x68,
    kHIDUsage_KeyboardLeftControl = 0xE0,
    kHIDUsage_KeyboardLeftShift = 0xE1,
    kHIDUsage_KeyboardLeftAlt = 0xE2,
    kHIDUsage_KeyboardLeftGUI = 0xE3,
    kHIDUsage_KeyboardRightControl = 0xE4,
    kHIDUsage_KeyboardRightShift = 0xE5,
    kHIDUsage_KeyboardRightAlt = 0xE6,
    kHIDUsage_KeyboardRightGUI = 0xE7,
    kHIDUsage_KeyboardPageUp = 0x4B,
    kHIDUsage_KeyboardPageDown = 0x4E,
    kHIDUsage_KeyboardHome = 0x4A,
    kHIDUsage_KeyboardEnd = 0x4D,
    kHIDUsage_KeyboardInsert = 0x49,
    kHIDUsage_KeyboardDeleteForward = 0x4C,
    kHIDUsage_KeyboardLeftArrow = 0x50,
    kHIDUsage_KeyboardRightArrow = 0x4F,
    kHIDUsage_KeyboardUpArrow = 0x52,
    kHIDUsage_KeyboardDownArrow = 0x51,
    kHIDUsage_KeypadNumLock = 0x53,
    kHIDUsage_KeypadComma = 0x85,
    kHIDUsage_KeyboardPause = 0x48,
};

enum {
    kHIDUsage_Csmr_Power = 0x30,
    kHIDUsage_Csmr_Menu = 0x40,
    kHIDUsage_Csmr_Snapshot = 0x65,
    kHIDUsage_Csmr_DisplayBrightnessIncrement = 0x6F,
    kHIDUsage_Csmr_DisplayBrightnessDecrement = 0x70,
    kHIDUsage_Csmr_PlayOrPause = 0xCD,
    kHIDUsage_Csmr_Mute = 0xE2,
    kHIDUsage_Csmr_VolumeIncrement = 0xE9,
    kHIDUsage_Csmr_VolumeDecrement = 0xEA,
    kHIDUsage_Csmr_ALKeyboardLayout = 0x1AE,
    kHIDUsage_Csmr_ACSearch = 0x221,
    kHIDUsage_Csmr_ACLock = 0x26B,
    kHIDUsage_Csmr_ACUnlock = 0x26C,
};

#define kGSEventPathInfoInRange (1 << 0)
#define kGSEventPathInfoInTouch (1 << 1)

IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, IOHIDDigitizerTransducerType, uint32_t, uint32_t,
                                             IOHIDDigitizerEventMask, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                             IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);

IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp, uint32_t index,
                                                   uint32_t identity, IOHIDDigitizerEventMask eventMask, IOHIDFloat x,
                                                   IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
                                                   boolean_t range, boolean_t touch, IOHIDEventOptionBits options);

IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, IOOptionBits);

IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint8_t *,
                                                 CFIndex, IOHIDEventOptionBits);

CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef, IOHIDEventField);
void IOHIDEventSetIntegerValue(IOHIDEventRef, IOHIDEventField, CFIndex);

IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, IOHIDEventField field);
void IOHIDEventSetFloatValue(IOHIDEventRef event, IOHIDEventField field, IOHIDFloat value);

void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, IOOptionBits);

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);

#ifdef __cplusplus
}
#endif

#endif /* IOKitSPI_h */
