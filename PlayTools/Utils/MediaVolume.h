//
//  MediaVolume.h
//  PlayTools
//
//  Created by Undefined on 2025/12/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSObject (SwizzleVolume)

- (void)swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector;

@end

NS_ASSUME_NONNULL_END
