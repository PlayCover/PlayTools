//
//  PTFakeMetaTouch.h
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface PTFakeMetaTouch : NSObject

+ (void)load;

+ (UITouch* ) touch: (NSInteger) pointId;

/**
 *  Fake a touch event 构造一个触屏基础操作 construct a touchscreen basic operation
 *
 *  @param pointId 触屏操作的序列号 sequence number of touch screen operation
 *  @param point   操作的目的位置 target position of the operation
 *  @param phase   操作的类别 type of the operation
 *  @param window  key window in which touch event is to happen
 *
 *  @return deleted whether the system had deleted a previous touch
 */

+ (NSInteger)fakeTouchId:(NSInteger)pointId AtPoint:(CGPoint)point withTouchPhase:(UITouchPhase)phase inWindow:(UIWindow*)window onView:(UIView*)view;

@end
