//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import <objc/runtime.h>
#import "CoreGraphics/CoreGraphics.h"
#import "UIKit/UIKit.h"
#import <PlayTools/PlayTools-Swift.h>
#import "PTFakeMetaTouch.h"

__attribute__((visibility("hidden")))
@interface PTSwizzleLoader : NSObject
@end

@implementation NSObject (Swizzle)

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

- (BOOL) hook_prefersPointerLocked {
    return false;
}

- (NSString*) hook_systemName {
    return @"iPadOS";
}

- (long long) hook_orientation {
    return 0;
}

- (CGRect) hook_frame {
    return CGRectMake(0, 0, 1920, 1080);
}

- (CGRect) hook_bounds {
    return CGRectMake(0, 0, 1920, 1080);
}

- (CGRect) hook_nativeBounds {
    return CGRectMake(0, 0, 1920 * 2, 1080 * 2);
}

- (double) hook_nativeScale {
    return 2.0;
}

- (double) hook_scale {
    return 2.0;
}

bool menuWasCreated = false;
- (id) initWithRootMenuHook:(id)rootMenu {
    self = [self initWithRootMenuHook:rootMenu];
    if (!menuWasCreated) {
        [PlayCover initMenuWithMenu: self];
        menuWasCreated = TRUE;
    }
    return self;
}

@end

/*
 This class only exists to apply swizzles from the +load of a class that won't have any categories/extensions. The reason
 for not doing this in a C module initializer is that obj-c initialization happens before any __attribute__((constructor))
 is called. This way we can guarantee the hooks will be applied before [PlayCover launch] is called (in PlayLoader.m).
 
 Side note:
 While adding method replacements to NSObject does work, I'm not certain this doesn't (or won't) have any side effects. The
 way Apple does method swizzling internally is by creating a category of the swizzled class and adding the replacements there.
 This keeps all those replacements "local" to that class. Example:
 
 '''
 @interface FBSSceneSettings (Swizzle)
 -(CGRect) hook_frame {
    ...
 }
 @end
 
 Somewhere else:
 swizzle(FBSSceneSettings.class, @selector(frame), @selector(hook_frame);
 '''
 
 However, doing this would require generating @interface declarations (either with class-dump or by hand) which would add a lot
 of code and complexity. I'm not sure this trade-off is "worth it", at least at the time of writing.
 */
@implementation PTSwizzleLoader
+ (void)load {
    if ([[PlaySettings shared] adaptiveDisplay]) {
        [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(systemName) withMethod:@selector(hook_systemName)];
        [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
        [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_bounds)];
        [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frame)];
        [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBounds)];
        [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
        [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
    }

    [objc_getClass("_UIMenuBuilder") swizzleInstanceMethod:sel_getUid("initWithRootMenu:") withMethod:@selector(initWithRootMenuHook:)];
    [objc_getClass("IOSViewController") swizzleInstanceMethod:@selector(prefersPointerLocked) withMethod:@selector(hook_prefersPointerLocked)];
}

@end
