//
//  PTFakeMetaTouch.h
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

void disableCursor(boolean_t disable);
void moveCursorTo(CGPoint point);

typedef struct {
     unsigned char r, g, b;
} RGB;

double ColourDistance(RGB e1, RGB e2);

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
 *  @return pointId 返回操作的序列号 returns sequence number of the operation
 */

+ (NSInteger)fakeTouchId:(NSInteger)pointId AtPoint:(CGPoint)point withTouchPhase:(UITouchPhase)phase inWindow:(UIWindow*)window;
/**
 *  Get a not used pointId 获取一个没有使用过的触屏序列号 obtain a never used touch screen sequence number
 *
 *  @return pointId 返回序列号 returns sequence number
 */
+ (NSInteger)getAvailablePointId;

@end
