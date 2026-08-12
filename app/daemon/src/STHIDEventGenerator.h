/*
 * STHIDEventGenerator - TrollVNC HID Event Generator
 * Adapted from TrollVNC (https://github.com/OwnGoalStudio/TrollVNC)
 * Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 * Licensed under GPL-2.0
 */

#ifndef STHIDEventGenerator_h
#define STHIDEventGenerator_h

#import <CoreGraphics/CGGeometry.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static NSUInteger const HIDMaxTouchCount = 30;

@interface STHIDEventGenerator : NSObject

+ (STHIDEventGenerator *)sharedGenerator;

- (void)setPhysicalScreenSize:(CGSize)size;
- (CGSize)physicalScreenSize;
- (BOOL)isAvailable;

- (void)touchDown:(CGPoint)location;
- (void)liftUp:(CGPoint)location;
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;

- (void)tap:(CGPoint)location;
- (void)doubleTap:(CGPoint)location;
- (void)longPress:(CGPoint)location;

- (void)dragLinearWithStartPoint:(CGPoint)startLocation endPoint:(CGPoint)endLocation duration:(NSTimeInterval)seconds;

- (void)menuDown;
- (void)menuUp;
- (void)menuPress;

- (void)powerDown;
- (void)powerUp;
- (void)powerPress;

- (void)keyPress:(NSString *)character;
- (void)keyDown:(NSString *)character;
- (void)keyUp:(NSString *)character;

@end

NS_ASSUME_NONNULL_END

#endif /* STHIDEventGenerator_h */
