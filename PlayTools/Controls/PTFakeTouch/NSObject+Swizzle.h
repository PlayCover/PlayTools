//
//  NSObject+PrivateSwizzle.h
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void pt_swizzleInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector);
FOUNDATION_EXPORT void pt_swizzleExchangeInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector);
FOUNDATION_EXPORT void pt_swizzleClassMethod(Class _Nullable cls, SEL origSelector, SEL newSelector);

@interface NSObject (Swizzle)

- (void)swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector;

@end

NS_ASSUME_NONNULL_END
