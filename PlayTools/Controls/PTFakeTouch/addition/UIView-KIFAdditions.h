//
//  UIView-KIFAdditions.h
//  KIF
//
//  Created by Eric Firestone on 5/20/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import <UIKit/UIKit.h>

extern double KIFDegreesToRadians(double deg);
extern double KIFRadiansToDegrees(double rad);

typedef CGPoint KIFDisplacement;

@interface UIView (KIFAdditions)

- (BOOL)isDescendantOfFirstResponder;

- (UIView *)subviewWithClassNamePrefix:(NSString *)prefix __deprecated;
- (NSArray *)subviewsWithClassNamePrefix:(NSString *)prefix;
- (UIView *)subviewWithClassNameOrSuperClassNamePrefix:(NSString *)prefix __deprecated;
- (NSArray *)subviewsWithClassNameOrSuperClassNamePrefix:(NSString *)prefix;

- (void)flash;
- (void)tap;
- (void)tapAtPoint:(CGPoint)point;
- (void)twoFingerTapAtPoint:(CGPoint)point;
- (void)longPressAtPoint:(CGPoint)point duration:(NSTimeInterval)duration;

/*!
 @method dragFromPoint:toPoint:
 @abstract Simulates dragging a finger on the screen between the given points.
 @discussion Causes the application to dispatch a sequence of touch events which simulate dragging a finger from startPoint to endPoint.
 @param startPoint The point at which to start the drag, in the coordinate system of the receiver.
 @param endPoint The point at which to end the drag, in the coordinate system of the receiver.
 */
- (void)dragFromPoint:(CGPoint)startPoint toPoint:(CGPoint)endPoint;
- (void)dragFromPoint:(CGPoint)startPoint toPoint:(CGPoint)endPoint steps:(NSUInteger)stepCount;
- (void)dragFromPoint:(CGPoint)startPoint displacement:(KIFDisplacement)displacement steps:(NSUInteger)stepCount;
- (void)dragAlongPathWithPoints:(CGPoint *)points count:(NSInteger)count;
- (void)twoFingerPanFromPoint:(CGPoint)startPoint toPoint:(CGPoint)toPoint steps:(NSUInteger)stepCount;
- (void)pinchAtPoint:(CGPoint)centerPoint distance:(CGFloat)distance steps:(NSUInteger)stepCount;
- (void)zoomAtPoint:(CGPoint)centerPoint distance:(CGFloat)distance steps:(NSUInteger)stepCount;
- (void)twoFingerRotateAtPoint:(CGPoint)centerPoint angle:(CGFloat)angleInDegrees;

- (UIEvent *)eventWithTouch:(UITouch *)touch;

/*!
 @abstract Evaluates if user interaction is enabled including edge cases.
 */
- (BOOL)isUserInteractionActuallyEnabled;

/*!
 @abstract Evaluates if the view and all its superviews are visible.
 */
- (BOOL)isVisibleInViewHierarchy;

/*!
 @method performBlockOnDescendentViews:
 @abstract Calls a block on the view itself and on all its descendent views.
 @param block The block that will be called on the views. Stop the traversation of the views by assigning YES to the stop-parameter of the block.
 */
- (void)performBlockOnDescendentViews:(void (^)(UIView *view, BOOL *stop))block;

/*!
 @method performBlockOnAscendentViews:
 @abstract Calls a block on the view itself and on all its superviews.
 @param block The block that will be called on the views. Stop the traversation of the views by assigning YES to the stop-parameter of the block.
 */
- (void)performBlockOnAscendentViews:(void (^)(UIView *view, BOOL *stop))block;

/*!
 @abstract Returns either the current window or another window if a transform is applied.  Returns `nil` if all windows in the application have transforms.
 */
@property (nonatomic, readonly) UIWindow *windowOrIdentityWindow;

@end
