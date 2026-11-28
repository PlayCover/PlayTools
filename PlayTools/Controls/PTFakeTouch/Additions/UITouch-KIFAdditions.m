//
//  UITouch-KIFAdditions.m
//  KIF
//
//  Created by Eric Firestone on 5/20/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import "UITouch-KIFAdditions.h"
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import "PTFakeMetaTouch.h"

// Never rely on ProcessInfo.isiOSAppOnMac / isMacCatalystApp here: PlayTools spoofs both
// to NO under iPhone / iPhone Duo mode, which would otherwise invoke the nonexistent
// _setIsTapToClick: selector on Mac Catalyst UITouch and crash fake touches.
static inline void pt_configureFakeTouchFlags(UITouch *touch) {
#if TARGET_OS_MACCATALYST
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    if ([touch respondsToSelector:@selector(setIsTap:)]) {
        [touch setIsTap:NO];
    }
#else
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
        if ([touch respondsToSelector:@selector(setIsTap:)]) {
            [touch setIsTap:NO];
        }
    } else if ([touch respondsToSelector:@selector(_setIsTapToClick:)]) {
        [touch _setIsTapToClick:NO];
    }
#endif
}

@implementation UITouch (KIFAdditions)

- (id)initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView*)view;
{
    self = [super init];
    if (self == nil) {
        return nil;
    }
    
    // Create a fake tap touch
    [self setWindow:window]; // Wipes out some values. Needs to be first.
    
    [self _setLocationInWindow:point resetPrevious:YES];
    
    UIView *hitTestView = view;
    
    [self setView:hitTestView];
    [self setPhase:UITouchPhaseBegan];
    pt_configureFakeTouchFlags(self);
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    if ([self respondsToSelector:@selector(setGestureView:)]) {
        [self setGestureView:hitTestView];
    }
    
    [self kif_setHidEvent];
    return self;
}

- (id)initTouch;
{
    //DLog(@"init...touch...");
    self = [super init];
    if (self == nil) {
        return nil;
    }
    NSArray *scenes = [[[UIApplication sharedApplication] connectedScenes] allObjects];
    NSArray *windows = [[scenes objectAtIndex:0] windows];
    UIWindow *window = [windows lastObject];
    CGPoint point = CGPointMake(0, 0);
    [self setWindow:window]; // Wipes out some values.  Needs to be first.
    
    [self _setLocationInWindow:point resetPrevious:YES];
    
    UIView *hitTestView = [window hitTest:point withEvent:nil];
    
    [self setView:hitTestView];
    [self setPhase:UITouchPhaseEnded];
    //DLog(@"init...touch...setPhase 3");
    pt_configureFakeTouchFlags(self);
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    if ([self respondsToSelector:@selector(setGestureView:)]) {
        [self setGestureView:hitTestView];
    }
    
    [self kif_setHidEvent];
    return self;
}

//
// setLocationInWindow:
//
// Setter to allow access to the _locationInWindow member.
//
- (void)setLocationInWindow:(CGPoint)location
{
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    [self _setLocationInWindow:location resetPrevious:NO];
}

- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase
{
    //DLog(@"setPhaseAndUpdateTimestamp : %ld",(long)phase);
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    [self setPhase:phase];
    // Update the IOHIDEvent to match the new phase.
    // Some games validate IOHIDEvent.eventMask against UITouch.phase,
    // so keeping them in sync is critical for fake touch acceptance.
    [self kif_setHidEvent];
}

- (void)kif_setHidEvent {
    IOHIDEventRef event = kif_IOHIDEventWithTouches(@[self]);
    [self _setHidEvent:event];
    CFRelease(event);
}

@end
