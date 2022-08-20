//
//  PTFakeMetaTouch.m
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import "PTFakeMetaTouch.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication-KIFAdditions.h"
#import "UIEvent+KIFAdditions.h"
#include <dlfcn.h>

static NSMutableArray *touchAry;
static NSMutableArray *livingTouchAry;

void disableCursor(boolean_t disable){
       void *handle;
       void (*test)(boolean_t);
       char *error;

       handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics", RTLD_LAZY);
       if (!handle) {
           fprintf(stderr, "%s\n", dlerror());
       }

       dlerror();

       *(void **) (&test) = dlsym(handle, "CGAssociateMouseAndMouseCursorPosition");

       if ((error = dlerror()) != NULL)  {
          
       } else{
           (*test)(disable);
           dlclose(handle);
       }
}

void moveCursorTo(CGPoint point){
       void *handle;
       void (*test)(CGPoint);
       char *error;

       handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics", RTLD_LAZY);
       if (!handle) {
           fprintf(stderr, "%s\n", dlerror());
       }

       dlerror();

       *(void **) (&test) = dlsym(handle, "CGWarpMouseCursorPosition");

       if ((error = dlerror()) != NULL)  {
          
       } else{
           (*test)(point);
           dlclose(handle);
       }
}

@implementation PTFakeMetaTouch

+ (void)load{
    KW_ENABLE_CATEGORY(UITouch_KIFAdditions);
    KW_ENABLE_CATEGORY(UIEvent_KIFAdditions);
    livingTouchAry = [[NSMutableArray alloc] init];
    touchAry = [[NSMutableArray alloc] init];
    for (NSInteger i = 0; i< 100; i++) {
        UITouch *touch = [[UITouch alloc] initTouch];
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
        [touchAry addObject:touch];
    }
}

+ (UITouch* ) touch: (NSInteger) pointId {
    if ([touchAry count] > pointId){
        return [touchAry objectAtIndex:pointId];
    }
    return nil;
}

+ (NSInteger)fakeTouchId:(NSInteger)pointId AtPoint:(CGPoint)point withTouchPhase:(UITouchPhase)phase inWindow:(UIWindow*)window{
    pointId -= 1;
    // ideally should be phase began when this hit
    // but if by any means other phases come... well lets be forgiving
    NSUInteger livingIndex = [livingTouchAry indexOfObjectIdenticalTo:touchAry[pointId]];
    if(livingIndex == NSNotFound) {
        if(phase == UITouchPhaseEnded) return -1;
        UITouch *touch = [[UITouch alloc] initAtPoint:point inWindow:window];
        livingIndex = livingTouchAry.count;
        [livingTouchAry addObject:touch];
        [touchAry setObject:touch atIndexedSubscript:pointId ];
    }
    UITouch *touch = [livingTouchAry objectAtIndex:livingIndex];
    
    [touch setLocationInWindow:point];
    if(touch.phase!=UITouchPhaseBegan){
        [touch setPhaseAndUpdateTimestamp:phase];
    }
    
    UIEvent *event = [self eventWithTouches:livingTouchAry];
    [[UIApplication sharedApplication] sendEvent:event];
    if ((touch.phase==UITouchPhaseBegan)||touch.phase==UITouchPhaseMoved) {
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
    }
    
    if (phase == UITouchPhaseEnded) {
        [livingTouchAry removeObjectAtIndex:livingIndex];
//        [touchAry removeObjectAtIndex:pointId];
    }
    return livingIndex;
}


+ (UIEvent *)eventWithTouches:(NSArray *)touches
{
    // _touchesEvent is a private selector, interface is exposed in UIApplication(KIFAdditionsPrivate)
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];
    [event kif_setEventWithTouches:touches];
    
    for (UITouch *aTouch in touches) {
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }
    
    return event;
}

+ (NSInteger)getAvailablePointId{
    NSInteger availablePointId=0;
    NSMutableArray *availableIds = [[NSMutableArray alloc]init];
    for (NSInteger i=0; i<touchAry.count; i++) {
        UITouch *touch = [touchAry objectAtIndex:i];
        if (touch.phase==UITouchPhaseEnded||touch.phase==UITouchPhaseStationary) {
            [availableIds addObject:@(i+1)];
        }
    }
    availablePointId = availableIds.count==0 ? 0 : [[availableIds objectAtIndex:(arc4random() % availableIds.count)] integerValue];
    return availablePointId;
}
@end
