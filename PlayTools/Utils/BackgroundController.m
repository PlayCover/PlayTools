//
//  BackgroundController.m
//  PlayTools
//
//  Created by Edoardo C. on 21/02/26.
//

#import <Foundation/Foundation.h>
#import <GameController/GCController.h>
#import <objc/runtime.h>
#import <PlayTools/PlayTools-Swift.h>
#import "BackgroundController.h"

__attribute__((visibility("hidden")))
@interface BackgroundControllerLoader : NSObject
@end

@implementation NSObject (SwizzleBackgroundController)

- (void) swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    Class cls = [self class];
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    
    // Add selector if it doesn't exist, implement append with method
    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod)) ) {
        // Replace class instance method, added if selector not exist
        // For class cluster, it always adds new selector here
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
        
    } else {
        // SwizzleMethod maybe belongs to super
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

- (bool) pm_return_true {
    return true;
}

@end

@implementation BackgroundControllerLoader
+ (void)load {
    [objc_getClass("GCController") swizzleInstanceMethod:@selector(shouldMonitorBackgroundEvents) withMethod:@selector(pm_return_true)];
}
@end
