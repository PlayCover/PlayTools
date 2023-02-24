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

@implementation PTFakeMetaTouch

+ (void)load {
    livingTouchAry = [[NSMutableArray alloc] init];
}

+ (NSInteger)fakeTouchId: (NSInteger)pointId AtPoint: (CGPoint)point withTouchPhase: (UITouchPhase)phase inWindow: (UIWindow*)window onView:(UIView*)view {
    UITouch* touch = NULL;
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
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
        [livingTouchAry setObject:touch atIndexedSubscript:pointId];
        [event _clearTouches];
        for(UITouch* aTouch in livingTouchAry) {
            [event _addTouch:aTouch forDelayedDelivery:NO];
        }
    } else {
        touch = [livingTouchAry objectAtIndex:pointId];
        [touch setLocationInWindow:point];
        [touch setPhaseAndUpdateTimestamp:phase];
    }
    [[UIApplication sharedApplication] sendEvent:event];

    if(touch.phase == UITouchPhaseBegan) {
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseMoved];
    } else if(phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        // set this bit to 0
        reusageMask |= 1ull<<pointId;
        pointId = -1;
    }
    return pointId;
}
@end
