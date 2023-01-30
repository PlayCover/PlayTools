//
//  PTFakeMetaTouch.m
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import "PTFakeMetaTouch.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication+Private.h"
#import "UIEvent+Private.h"
#import "CoreFoundation/CFRunLoop.h"
#include <dlfcn.h>
#include <string.h>

static NSMutableArray *touchAry;
static NSMutableArray *livingTouchAry;
static CFRunLoopSourceRef source;

static UITouch* toRemove = NULL, *toStationarify = NULL;
NSArray *safeTouchAry;

void eventSendCallback(void* info) {
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    // to retain objects from being released
    [event _clearTouches];
    NSArray *myAry = safeTouchAry;
    for (UITouch *aTouch in myAry) {
        switch (aTouch.phase) {
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                toRemove = aTouch;
                break;
            case UITouchPhaseBegan:
                toStationarify = aTouch;
                break;
            default:
                break;
        }
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }
    [[UIApplication sharedApplication] sendEvent:event];
}

@implementation PTFakeMetaTouch

+ (void)load {
    livingTouchAry = [[NSMutableArray alloc] init];
    touchAry = [[NSMutableArray alloc] init];
    for (NSInteger i = 0; i< 100; i++) {
        UITouch *touch = [[UITouch alloc] initTouch];
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
        [touchAry addObject:touch];
    }
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof(CFRunLoopSourceContext));
    context.perform = eventSendCallback;
    // content of context is copied
    source = CFRunLoopSourceCreate(NULL, -2, &context);
    CFRunLoopRef loop = CFRunLoopGetMain();
    CFRunLoopAddSource(loop, source, kCFRunLoopCommonModes);
}

+ (UITouch*)touch: (NSInteger) pointId {
    if ([touchAry count] > pointId){
        return [touchAry objectAtIndex:pointId];
    }
    return nil;
}

+ (NSInteger)fakeTouchId: (NSInteger)pointId AtPoint: (CGPoint)point withTouchPhase: (UITouchPhase)phase inWindow: (UIWindow*)window onView:(UIView*)view {
    bool deleted = false;
    UITouch* touch = NULL;
    bool needsCopy = false;
    if(toRemove != NULL) {
        touch = toRemove;
        toRemove = NULL;
        [livingTouchAry removeObjectIdenticalTo:touch];
        deleted = true;
        needsCopy = true;
    }
    if(toStationarify != NULL) {
        // in case this is changed during the operations
        touch = toStationarify;
        toStationarify = NULL;
        if(touch.phase == UITouchPhaseBegan) {
            [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
        }
    }
    pointId -= 1;
    // ideally should be phase began when this hit
    // but if by any means other phases come... well lets be forgiving
    touch = touchAry[pointId];
    bool old = [livingTouchAry containsObject:touch];
    bool new = !old;
    if(new) {
        if(phase == UITouchPhaseEnded) return deleted;
        touch = [[UITouch alloc] initAtPoint:point inWindow:window onView:view];
        [livingTouchAry addObject:touch];
        [touchAry setObject:touch atIndexedSubscript:pointId ];
        needsCopy = true;
    } else {
        if(touch.phase == UITouchPhaseBegan && phase == UITouchPhaseMoved) {
            return deleted;
        }
        [touch setLocationInWindow:point];
    }
    [touch setPhaseAndUpdateTimestamp:phase];
    if(needsCopy) {
        CFTypeRef delayRelease = CFBridgingRetain(safeTouchAry);
        safeTouchAry = [[NSArray alloc] initWithArray:livingTouchAry copyItems:NO];
        CFBridgingRelease(delayRelease);
    }
    CFRunLoopSourceSignal(source);
    return deleted;
}
@end
