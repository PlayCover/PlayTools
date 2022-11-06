//
//  UIView-KIFAdditions.m
//  KIF
//
//  Created by Eric Firestone on 5/20/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import "UIView-KIFAdditions.h"
#import "CGGeometry-KIFAdditions.h"
#import "UIApplication-KIFAdditions.h"
#import "UITouch-KIFAdditions.h"
#import <objc/runtime.h>
#import "UIEvent+KIFAdditions.h"

double KIFDegreesToRadians(double deg) {
    return (deg) / 180.0 * M_PI;
}

double KIFRadiansToDegrees(double rad) {
    return ((rad) * (180.0 / M_PI));
}

static CGFloat const kTwoFingerConstantWidth = 40;


@interface NSObject (UIWebDocumentViewInternal)

- (void)tapInteractionWithLocation:(CGPoint)point;

@end

// On iOS 6 the accessibility label may contain line breaks, so when trying to find the
// element, these line breaks are necessary. But on iOS 7 the system replaces them with
// spaces. So the same test breaks on either iOS 6 or iOS 7. iOS8 befuddles this again by
//limiting replacement to spaces in between strings. To work around this replace
// the line breaks in both and try again.
NS_INLINE BOOL StringsMatchExceptLineBreaks(NSString *expected, NSString *actual) {
    if (expected == actual) {
        return YES;
    }
    
    if (expected.length != actual.length) {
        return NO;
    }
    
    if ([expected isEqualToString:actual]) {
        return YES;
    }
    
    if ([expected rangeOfString:@"\n"].location == NSNotFound &&
        [actual rangeOfString:@"\n"].location == NSNotFound) {
        return NO;
    }
    
    for (NSUInteger i = 0; i < expected.length; i ++) {
        unichar expectedChar = [expected characterAtIndex:i];
        unichar actualChar = [actual characterAtIndex:i];
        if (expectedChar != actualChar &&
           !(expectedChar == '\n' && actualChar == ' ') &&
           !(expectedChar == ' '  && actualChar == '\n')) {
            return NO;
        }
    }
    
    return YES;
}


@implementation UIView (KIFAdditions)

+ (NSSet *)classesToSkipAccessibilitySearchRecursion
{
    static NSSet *classesToSkip;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // UIDatePicker contains hundreds of thousands of placeholder accessibility elements that aren't useful to KIF,
        // so don't recurse into a date picker when searching for matching accessibility elements
        classesToSkip = [[NSSet alloc] initWithObjects:[UIDatePicker class], nil];
    });
    
    return classesToSkip;
}

- (UIView *)subviewWithClassNamePrefix:(NSString *)prefix;
{
    NSArray *subviews = [self subviewsWithClassNamePrefix:prefix];
    if ([subviews count] == 0) {
        return nil;
    }
    
    return subviews[0];
}

- (NSArray *)subviewsWithClassNamePrefix:(NSString *)prefix;
{
    NSMutableArray *result = [NSMutableArray array];
    
    // Breadth-first population of matching subviews
    // First traverse the next level of subviews, adding matches.
    for (UIView *view in self.subviews) {
        if ([NSStringFromClass([view class]) hasPrefix:prefix]) {
            [result addObject:view];
        }
    }
    
    // Now traverse the subviews of the subviews, adding matches.
    for (UIView *view in self.subviews) {
        NSArray *matchingSubviews = [view subviewsWithClassNamePrefix:prefix];
        [result addObjectsFromArray:matchingSubviews];
    }

    return result;
}

- (UIView *)subviewWithClassNameOrSuperClassNamePrefix:(NSString *)prefix;
{
    NSArray *subviews = [self subviewsWithClassNameOrSuperClassNamePrefix:prefix];
    if ([subviews count] == 0) {
        return nil;
    }
    
    return subviews[0];
}

- (NSArray *)subviewsWithClassNameOrSuperClassNamePrefix:(NSString *)prefix;
{
    NSMutableArray * result = [NSMutableArray array];
    
    // Breadth-first population of matching subviews
    // First traverse the next level of subviews, adding matches
    for (UIView *view in self.subviews) {
        Class klass = [view class];
        while (klass) {
            if ([NSStringFromClass(klass) hasPrefix:prefix]) {
                [result addObject:view];
                break;
            }
            
            klass = [klass superclass];
        }
    }
    
    // Now traverse the subviews of the subviews, adding matches
    for (UIView *view in self.subviews) {
        NSArray * matchingSubviews = [view subviewsWithClassNameOrSuperClassNamePrefix:prefix];
        [result addObjectsFromArray:matchingSubviews];
    }

    return result;
}


- (BOOL)isDescendantOfFirstResponder;
{
    if ([self isFirstResponder]) {
        return YES;
    }
    return [self.superview isDescendantOfFirstResponder];
}

- (void)flash;
{
	UIColor *originalBackgroundColor = self.backgroundColor;
    for (NSUInteger i = 0; i < 5; i++) {
        self.backgroundColor = [UIColor yellowColor];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .05, false);
        self.backgroundColor = [UIColor blueColor];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .05, false);
    }
    self.backgroundColor = originalBackgroundColor;
}

- (void)tap;
{
    CGPoint centerPoint = CGPointMake(self.frame.size.width * 0.5f, self.frame.size.height * 0.5f);
    
    [self tapAtPoint:centerPoint];
}

- (void)tapAtPoint:(CGPoint)point;
{

    // Handle touches in the normal way for other views
    UITouch *touch = [[UITouch alloc] initAtPoint:point inView:self];
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseBegan];
    
    UIEvent *event = [self eventWithTouch:touch];

    [[UIApplication sharedApplication] sendEvent:event];
    
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    [[UIApplication sharedApplication] sendEvent:event];

    // Dispatching the event doesn't actually update the first responder, so fake it
    if ([touch.view isDescendantOfView:self] && [self canBecomeFirstResponder]) {
        [self becomeFirstResponder];
    }

}

- (void)twoFingerTapAtPoint:(CGPoint)point {
    CGPoint finger1 = CGPointMake(point.x - kTwoFingerConstantWidth, point.y - kTwoFingerConstantWidth);
    CGPoint finger2 = CGPointMake(point.x + kTwoFingerConstantWidth, point.y + kTwoFingerConstantWidth);
    UITouch *touch1 = [[UITouch alloc] initAtPoint:finger1 inView:self];
    UITouch *touch2 = [[UITouch alloc] initAtPoint:finger2 inView:self];
    [touch1 setPhaseAndUpdateTimestamp:UITouchPhaseBegan];
    [touch2 setPhaseAndUpdateTimestamp:UITouchPhaseBegan];

    UIEvent *event = [self eventWithTouches:@[touch1, touch2]];
    [[UIApplication sharedApplication] sendEvent:event];

    [touch1 setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    [touch2 setPhaseAndUpdateTimestamp:UITouchPhaseEnded];

    [[UIApplication sharedApplication] sendEvent:event];
}

#define DRAG_TOUCH_DELAY 0.01

- (void)longPressAtPoint:(CGPoint)point duration:(NSTimeInterval)duration
{
    UITouch *touch = [[UITouch alloc] initAtPoint:point inView:self];
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseBegan];
    
    UIEvent *eventDown = [self eventWithTouch:touch];
    [[UIApplication sharedApplication] sendEvent:eventDown];
    
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, DRAG_TOUCH_DELAY, false);
    
    for (NSTimeInterval timeSpent = DRAG_TOUCH_DELAY; timeSpent < duration; timeSpent += DRAG_TOUCH_DELAY)
    {
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
        
        UIEvent *eventStillDown = [self eventWithTouch:touch];
        [[UIApplication sharedApplication] sendEvent:eventStillDown];
        
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, DRAG_TOUCH_DELAY, false);
    }
    
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    UIEvent *eventUp = [self eventWithTouch:touch];
    [[UIApplication sharedApplication] sendEvent:eventUp];
    
    // Dispatching the event doesn't actually update the first responder, so fake it
    if ([touch.view isDescendantOfView:self] && [self canBecomeFirstResponder]) {
        [self becomeFirstResponder];
    }
    
}

- (void)dragFromPoint:(CGPoint)startPoint toPoint:(CGPoint)endPoint;
{
    [self dragFromPoint:startPoint toPoint:endPoint steps:3];
}


- (void)dragFromPoint:(CGPoint)startPoint toPoint:(CGPoint)endPoint steps:(NSUInteger)stepCount;
{
    KIFDisplacement displacement = CGPointMake(endPoint.x - startPoint.x, endPoint.y - startPoint.y);
    [self dragFromPoint:startPoint displacement:displacement steps:stepCount];
}

- (void)dragFromPoint:(CGPoint)startPoint displacement:(KIFDisplacement)displacement steps:(NSUInteger)stepCount;
{
    CGPoint endPoint = CGPointMake(startPoint.x + displacement.x, startPoint.y + displacement.y);
    NSArray *path = [self pointsFromStartPoint:startPoint toPoint:endPoint steps:stepCount];
    [self dragPointsAlongPaths:@[path]];
}

- (void)dragAlongPathWithPoints:(CGPoint *)points count:(NSInteger)count;
{
    // convert point array into NSArray with NSValue
    NSMutableArray *array = [NSMutableArray array];
    for (int i = 0; i < count; i++)
    {
        [array addObject:[NSValue valueWithCGPoint:points[i]]];
    }
    [self dragPointsAlongPaths:@[[array copy]]];
}

- (void)dragPointsAlongPaths:(NSArray *)arrayOfPaths {
    // must have at least one path, and each path must have the same number of points
    if (arrayOfPaths.count == 0)
    {
        return;
    }

    // all paths must have similar number of points
    NSUInteger pointsInPath = [arrayOfPaths[0] count];
    for (NSArray *path in arrayOfPaths)
    {
        if (path.count != pointsInPath)
        {
            return;
        }
    }

    NSMutableArray *touches = [NSMutableArray array];

    for (NSUInteger pointIndex = 0; pointIndex < pointsInPath; pointIndex++) {
        // create initial touch event and send touch down event
        if (pointIndex == 0)
        {
            for (NSArray *path in arrayOfPaths)
            {
                CGPoint point = [path[pointIndex] CGPointValue];
                UITouch *touch = [[UITouch alloc] initAtPoint:point inView:self];
                [touch setPhaseAndUpdateTimestamp:UITouchPhaseBegan];
                [touches addObject:touch];
            }
            UIEvent *eventDown = [self eventWithTouches:[NSArray arrayWithArray:touches]];
            [[UIApplication sharedApplication] sendEvent:eventDown];
            
            CFRunLoopRunInMode(UIApplicationCurrentRunMode, DRAG_TOUCH_DELAY, false);
        }
        else
        {
            UITouch *touch;
            for (NSUInteger pathIndex = 0; pathIndex < arrayOfPaths.count; pathIndex++)
            {
                NSArray *path = arrayOfPaths[pathIndex];
                CGPoint point = [path[pointIndex] CGPointValue];
                touch = touches[pathIndex];
                [touch setLocationInWindow:[self.window convertPoint:point fromView:self]];
                [touch setPhaseAndUpdateTimestamp:UITouchPhaseMoved];
            }
            UIEvent *event = [self eventWithTouches:[NSArray arrayWithArray:touches]];
            [[UIApplication sharedApplication] sendEvent:event];

            CFRunLoopRunInMode(UIApplicationCurrentRunMode, DRAG_TOUCH_DELAY, false);

            // The last point needs to also send a phase ended touch.
            if (pointIndex == pointsInPath - 1) {
                for (UITouch * touch in touches) {
                    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
                    UIEvent *eventUp = [self eventWithTouch:touch];
                    [[UIApplication sharedApplication] sendEvent:eventUp];
                    
                }

            }
        }
    }

    // Dispatching the event doesn't actually update the first responder, so fake it
    if ([touches[0] view] == self && [self canBecomeFirstResponder]) {
        [self becomeFirstResponder];
    }

    while (UIApplicationCurrentRunMode != kCFRunLoopDefaultMode) {
        CFRunLoopRunInMode(UIApplicationCurrentRunMode, 0.1, false);
    }
}

- (void)twoFingerPanFromPoint:(CGPoint)startPoint toPoint:(CGPoint)toPoint steps:(NSUInteger)stepCount {
    //estimate the first finger to be diagonally up and left from the center
    CGPoint finger1Start = CGPointMake(startPoint.x - kTwoFingerConstantWidth,
                                       startPoint.y - kTwoFingerConstantWidth);
    CGPoint finger1End = CGPointMake(toPoint.x - kTwoFingerConstantWidth,
                                     toPoint.y - kTwoFingerConstantWidth);
    //estimate the second finger to be diagonally down and right from the center
    CGPoint finger2Start = CGPointMake(startPoint.x + kTwoFingerConstantWidth,
                                       startPoint.y + kTwoFingerConstantWidth);
    CGPoint finger2End = CGPointMake(toPoint.x + kTwoFingerConstantWidth,
                                     toPoint.y + kTwoFingerConstantWidth);
    NSArray *finger1Path = [self pointsFromStartPoint:finger1Start toPoint:finger1End steps:stepCount];
    NSArray *finger2Path = [self pointsFromStartPoint:finger2Start toPoint:finger2End steps:stepCount];
    NSArray *paths = @[finger1Path, finger2Path];

    [self dragPointsAlongPaths:paths];
}

- (void)pinchAtPoint:(CGPoint)centerPoint distance:(CGFloat)distance steps:(NSUInteger)stepCount {
    //estimate the first finger to be on the left
    CGPoint finger1Start = CGPointMake(centerPoint.x - kTwoFingerConstantWidth - distance, centerPoint.y);
    CGPoint finger1End = CGPointMake(centerPoint.x - kTwoFingerConstantWidth, centerPoint.y);
    //estimate the second finger to be on the right
    CGPoint finger2Start = CGPointMake(centerPoint.x + kTwoFingerConstantWidth + distance, centerPoint.y);
    CGPoint finger2End = CGPointMake(centerPoint.x + kTwoFingerConstantWidth, centerPoint.y);
    NSArray *finger1Path = [self pointsFromStartPoint:finger1Start toPoint:finger1End steps:stepCount];
    NSArray *finger2Path = [self pointsFromStartPoint:finger2Start toPoint:finger2End steps:stepCount];
    NSArray *paths = @[finger1Path, finger2Path];

    [self dragPointsAlongPaths:paths];
}

- (void)zoomAtPoint:(CGPoint)centerPoint distance:(CGFloat)distance steps:(NSUInteger)stepCount {
    //estimate the first finger to be on the left
    CGPoint finger1Start = CGPointMake(centerPoint.x - kTwoFingerConstantWidth, centerPoint.y);
    CGPoint finger1End = CGPointMake(centerPoint.x - kTwoFingerConstantWidth - distance, centerPoint.y);
    //estimate the second finger to be on the right
    CGPoint finger2Start = CGPointMake(centerPoint.x + kTwoFingerConstantWidth, centerPoint.y);
    CGPoint finger2End = CGPointMake(centerPoint.x + kTwoFingerConstantWidth + distance, centerPoint.y);
    NSArray *finger1Path = [self pointsFromStartPoint:finger1Start toPoint:finger1End steps:stepCount];
    NSArray *finger2Path = [self pointsFromStartPoint:finger2Start toPoint:finger2End steps:stepCount];
    NSArray *paths = @[finger1Path, finger2Path];

    [self dragPointsAlongPaths:paths];
}

- (void)twoFingerRotateAtPoint:(CGPoint)centerPoint angle:(CGFloat)angleInDegrees {
    NSInteger stepCount = ABS(angleInDegrees)/2; // very rough approximation. 90deg = ~45 steps, 360 deg = ~180 steps
    CGFloat radius = kTwoFingerConstantWidth*2;
    double angleInRadians = KIFDegreesToRadians(angleInDegrees);

    NSMutableArray *finger1Path = [NSMutableArray array];
    NSMutableArray *finger2Path = [NSMutableArray array];
    for (NSUInteger i = 0; i < stepCount; i++) {
        double currentAngle = 0;
        if (i == stepCount - 1) {
            currentAngle = angleInRadians; // do not interpolate for the last step for maximum accuracy
        }
        else {
            double interpolation = i/(double)stepCount;
            currentAngle = interpolation * angleInRadians;
        }
        // interpolate betwen 0 and the target rotation
        CGPoint offset1 = CGPointMake(radius * cos(currentAngle), radius * sin(currentAngle));
        CGPoint offset2 = CGPointMake(-offset1.x, -offset1.y); // second finger is just opposite of the first

        CGPoint finger1 = CGPointMake(centerPoint.x + offset1.x, centerPoint.y + offset1.y);
        CGPoint finger2 = CGPointMake(centerPoint.x + offset2.x, centerPoint.y + offset2.y);

        [finger1Path addObject:[NSValue valueWithCGPoint:finger1]];
        [finger2Path addObject:[NSValue valueWithCGPoint:finger2]];
    }
    [self dragPointsAlongPaths:@[[finger1Path copy], [finger2Path copy]]];
}

- (NSArray *)pointsFromStartPoint:(CGPoint)startPoint toPoint:(CGPoint)toPoint steps:(NSUInteger)stepCount {

    CGPoint displacement = CGPointMake(toPoint.x - startPoint.x, toPoint.y - startPoint.y);
    NSMutableArray *points = [NSMutableArray array];

    for (NSUInteger i = 0; i < stepCount; i++) {
        CGFloat progress = ((CGFloat)i)/(stepCount - 1);
        CGPoint point = CGPointMake(startPoint.x + (progress * displacement.x),
                                    startPoint.y + (progress * displacement.y));
        [points addObject:[NSValue valueWithCGPoint:point]];
    }
    return [NSArray arrayWithArray:points];
}

- (UIEvent *)eventWithTouches:(NSArray *)touches
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

- (UIEvent *)eventWithTouch:(UITouch *)touch;
{
    NSArray *touches = touch ? @[touch] : nil;
    return [self eventWithTouches:touches];
}

- (BOOL)isUserInteractionActuallyEnabled;
{
    BOOL isUserInteractionEnabled = self.userInteractionEnabled;
    
    // Navigation item views don't have user interaction enabled, but their parent nav bar does and will forward the event
    if (!isUserInteractionEnabled && [self isNavigationItemView]) {
        // If this view is inside a nav bar, and the nav bar is enabled, then consider it enabled
        UIView *navBar = [self superview];
        while (navBar && ![navBar isKindOfClass:[UINavigationBar class]]) {
            navBar = [navBar superview];
        }
        if (navBar && navBar.userInteractionEnabled) {
            isUserInteractionEnabled = YES;
        }
    }
    
    // UIActionsheet Buttons have UIButtonLabels with userInteractionEnabled=NO inside,
    // grab the superview UINavigationButton instead.
    if (!isUserInteractionEnabled && [self isKindOfClass:NSClassFromString(@"UIButtonLabel")]) {
        UIView *button = [self superview];
        while (button && ![button isKindOfClass:NSClassFromString(@"UINavigationButton")]) {
            button = [button superview];
        }
        if (button && button.userInteractionEnabled) {
            isUserInteractionEnabled = YES;
        }
    }
    
    // Somtimes views are inside a UIControl and don't have user interaction enabled.
    // Walk up the hierarchary evaluating the parent UIControl subclass and use that instead.
    if (!isUserInteractionEnabled && [self.superview isKindOfClass:[UIControl class]]) {
        // If this view is inside a UIControl, and it is enabled, then consider the view enabled
        UIControl *control = (UIControl *)[self superview];
        while (control && [control isKindOfClass:[UIControl class]]) {
            if (control.isUserInteractionEnabled) {
                isUserInteractionEnabled = YES;
                break;
            }
            control = (UIControl *)[control superview];
        }
    }
    
    return isUserInteractionEnabled;
}

- (BOOL)isNavigationItemView;
{
    return [self isKindOfClass:NSClassFromString(@"UINavigationItemView")] || [self isKindOfClass:NSClassFromString(@"_UINavigationBarBackIndicatorView")];
}

- (UIWindow *)windowOrIdentityWindow
{
    if (CGAffineTransformIsIdentity(self.window.transform)) {
        return self.window;
    }
    
    for (UIWindow *window in [[UIApplication sharedApplication] windowsWithKeyWindow]) {
        if (CGAffineTransformIsIdentity(window.transform)) {
            return window;
        }
    }
    
    return nil;
}

- (BOOL)isVisibleInViewHierarchy
{
    __block BOOL result = YES;
    [self performBlockOnAscendentViews:^(UIView *view, BOOL *stop) {
        if (view.isHidden) {
            result = NO;
            if (stop != NULL) {
                *stop = YES;
            }
        }
    }];
    return result;
}

- (void)performBlockOnDescendentViews:(void (^)(UIView *view, BOOL *stop))block
{
    BOOL stop = NO;
    [self performBlockOnDescendentViews:block stop:&stop];
}

- (void)performBlockOnDescendentViews:(void (^)(UIView *view, BOOL *stop))block stop:(BOOL *)stop
{
    block(self, stop);
    if (*stop) {
        return;
    }
    
    for (UIView *view in self.subviews) {
        [view performBlockOnDescendentViews:block stop:stop];
        if (*stop) {
            return;
        }
    }
}

- (void)performBlockOnAscendentViews:(void (^)(UIView *view, BOOL *stop))block
{
    BOOL stop = NO;
    UIView *checkedView = self;
    while(checkedView && stop == NO) {
        block(checkedView, &stop);
        checkedView = checkedView.superview;
    }
}


@end
