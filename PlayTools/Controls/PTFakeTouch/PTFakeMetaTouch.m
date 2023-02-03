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

static NSMutableArray *livingTouchAry;
uint64_t reusageMask = 0;
static CFRunLoopSourceRef source;

static UITouch *toStationarify = NULL;
NSLock *lock;

void eventSendCallback(void* info) {
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];
    [lock lock];
    [livingTouchAry enumerateObjectsUsingBlock:^(UITouch *aTouch, NSUInteger idx, BOOL *stop) {
        switch (aTouch.phase) {
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                // set this bit to 0
                reusageMask |= 1ull<<idx;
                break;
            case UITouchPhaseBegan:
                toStationarify = aTouch;
                break;
            default:
                break;
        }
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }];
    [lock unlock];
    [[UIApplication sharedApplication] sendEvent:event];
}

@implementation PTFakeMetaTouch

+ (void)load {
    livingTouchAry = [[NSMutableArray alloc] init];
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof(CFRunLoopSourceContext));
    context.perform = eventSendCallback;
    lock = [[NSLock alloc] init];
    // content of context is copied
    source = CFRunLoopSourceCreate(NULL, -2, &context);
    CFRunLoopRef loop = CFRunLoopGetMain();
    CFRunLoopAddSource(loop, source, kCFRunLoopCommonModes);
}

+ (NSInteger)fakeTouchId: (NSInteger)pointId AtPoint: (CGPoint)point withTouchPhase: (UITouchPhase)phase inWindow: (UIWindow*)window onView:(UIView*)view {
    UITouch* touch = NULL;
    if(toStationarify != NULL) {
        // in case this is changed during the operations
        touch = toStationarify;
        toStationarify = NULL;
        if(touch.phase == UITouchPhaseBegan) {
            [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
        }
    }
    // respect the semantics of touch phase, allocate new touch on touch began.
    if(phase == UITouchPhaseBegan) {
        touch = [[UITouch alloc] initAtPoint:point inWindow:window onView:view];
        if(reusageMask == 0){
            pointId = [livingTouchAry count];
        }else{
            // reuse previous ID
            pointId = 0;
            while( !(reusageMask & (1ull<<pointId)) ){
                pointId++;
            }
            reusageMask &= ~(1ull<<pointId);
        }
        [lock lock];
        [livingTouchAry setObject:touch atIndexedSubscript:pointId];
        [lock unlock];
    } else {
        touch = [livingTouchAry objectAtIndex:pointId];
        if(touch.phase == UITouchPhaseBegan && phase == UITouchPhaseMoved) {
            // previous touch began event not yet captured by runloop. Ignore this move
            return pointId;
        }
        [touch setLocationInWindow:point];
        [touch setPhaseAndUpdateTimestamp:phase];
    }
    CFRunLoopSourceSignal(source);
    if(phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        pointId = -1;
    }
    return pointId;
}
@end
