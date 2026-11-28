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
#import <VideoSubscriberAccount/VideoSubscriberAccount.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>

__attribute__((visibility("hidden")))
@interface PTSwizzleLoader : NSObject
@end

@implementation NSObject (Swizzle)

- (void) swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    pt_swizzleInstanceMethod([self class], origSelector, newSelector);
}

- (void) swizzleExchangeMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    pt_swizzleExchangeInstanceMethod([self class], origSelector, newSelector);
}

+ (void) swizzleClassMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    pt_swizzleClassMethod(self, origSelector, newSelector);
}

void pt_swizzleInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
    if (!cls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod))) {
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

void pt_swizzleExchangeInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
    if (!cls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    method_exchangeImplementations(originalMethod, swizzledMethod);
}

void pt_swizzleClassMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
    if (!cls) {
        return;
    }
    Class meta = object_getClass((id)cls);
    if (!meta) {
        return;
    }
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod(cls, newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    if (class_addMethod(meta,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod))) {
        class_replaceMethod(meta,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        class_replaceMethod(meta,
                            newSelector,
                            class_replaceMethod(meta,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

- (BOOL) hook_prefersPointerLocked {
    return false;
}

- (CGRect) hook_frameDefault {
    return [PlayScreen frameDefault:[self hook_frameDefault]];
}

- (CGRect) hook_boundsDefault {
    return [PlayScreen boundsDefault:[self hook_boundsDefault]];
}

- (CGRect) hook_nativeBoundsDefault {
    return [PlayScreen nativeBoundsDefault:[self hook_nativeBoundsDefault]];
}

- (CGSize) hook_sizeDelfault {
    return [PlayScreen sizeAspectRatioDefault:[self hook_sizeDelfault]];
}


- (CGRect) hook_frame {
    return [PlayScreen frame:[self hook_frame]];
}

- (CGRect) hook_bounds {
    return [PlayScreen bounds:[self hook_bounds]];
}

- (CGRect) hook_nativeBounds {
    return [PlayScreen nativeBounds:[self hook_nativeBounds]];
}

- (CGSize) hook_size {
    return [PlayScreen sizeAspectRatio:[self hook_size]];
}



- (long long) hook_orientation {
    return 0;
}

- (double) hook_nativeScale {
    return [[PlaySettings shared] customScaler];
}

- (double) hook_scale {
    // Return rounded value of [[PlaySettings shared] customScaler]
    // Even though it is a double return, this will only accept .0 value or apps will crash
    return round([[PlaySettings shared] customScaler]);
}

- (double) get_default_height {
    return [[UIScreen mainScreen] bounds].size.height;
    
}
- (double) get_default_width {
    return [[UIScreen mainScreen] bounds].size.width;
    
}

- (CGRect) hook_boundsResizable {
    return [PlayScreen boundsResizable:[self hook_boundsResizable]];
}

- (BOOL) hook_requiresFullScreen {
    return NO;
}

- (void) hook_setCurrentSubscription:(id)currentSubscription {
    // do nothing
}

- (NSString *)hook_stringByReplacingOccurrencesOfRegularExpressionPattern:(NSString *)pattern
                                                             withTemplate:(NSString *)template
                                                                  options:(NSRegularExpressionOptions)options
                                                                    range:(NSRange)range {
    // If the string is empty, return immediately to prevent a range out-of-bounds error.
    if ([(NSString*)self isEqualToString:@""]) {
        return @"";
    }
    return [self hook_stringByReplacingOccurrencesOfRegularExpressionPattern:pattern
                                                                withTemplate:template
                                                                     options:options
                                                                       range:range];
}

- (void)hook_requestRecordPermission:(void (^)(BOOL))response {
    BOOL granted = [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
    if (granted) {
        response(granted);
    } else {
        [self hook_requestRecordPermission:response];
    }
}

- (instancetype)hook_CMMotionManager_init {
    CMMotionManager *motionManager = (CMMotionManager *)[self hook_CMMotionManager_init];
    // The default update interval is 0, which may lead to excessive CPU usage
    motionManager.accelerometerUpdateInterval = 0.01;
    motionManager.deviceMotionUpdateInterval = 0.01;
    motionManager.gyroUpdateInterval = 0.01;
    return motionManager;
}

+ (GCMouse *)hook_GCMouse_current {
    return nil;
}

+ (NSArray *)hook_GCMouse_mice {
    return @[];
}

+ (void)hook_Unity_KeyboardDelegate_Initialize {
    @try {
        [self hook_Unity_KeyboardDelegate_Initialize];
    }
    @catch (NSException *exception) {
        NSLog(@"Caught exception: %@, reason: %@", exception.name, exception.reason);
    }
}

// Hook for UIUserInterfaceIdiom

// - (long long) hook_userInterfaceIdiom {
//     return UIUserInterfaceIdiomPad;
// }

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
    // This might need refactor soon
    if(@available(iOS 16.3, *)) {
        if ([[PlaySettings shared] resizableWindow]) {
            pt_swizzleInstanceMethod(objc_getClass("_UIApplicationInfoParser"), NSSelectorFromString(@"requiresFullScreen"), @selector(hook_requiresFullScreen));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(bounds), @selector(hook_boundsResizable));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));
        }
        else if ([[PlaySettings shared] adaptiveDisplay]) {
            // This is an experimental fix
            if ([[PlaySettings shared] inverseScreenValues]) {
                // This lines set External Scene settings and other IOS10 Runtime services by swizzling
                // In Sonoma 14.1 betas, frame method seems to be moved to FBSSceneSettingsCore
                if(@available(iOS 17.1, *))
                    pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frameDefault));
                else
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frameDefault));
                pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_boundsDefault));
                pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_sizeDelfault));
                
                // Fixes Apple mess at MacOS 13.2
                pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(orientation), @selector(hook_orientation));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBoundsDefault));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));
            } else {
                // This acutally runs when adaptiveDisplay is normally triggered
                if(@available(iOS 17.1, *))
                    pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frame));
                else
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frame));
                pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_bounds));
                pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_size));
                
                pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(orientation), @selector(hook_orientation));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBounds));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));   
            }
        }
        else {
            if ([[PlaySettings shared] windowFixMethod] == 1) {
                // do nothing:tm:
            }
            else {
                CGFloat newValueW = (CGFloat) [self get_default_width];
                [[PlaySettings shared] setValue:@(newValueW) forKey:@"windowSizeWidth"];
                
                CGFloat newValueH = (CGFloat)[self get_default_height];
                [[PlaySettings shared] setValue:@(newValueH) forKey:@"windowSizeHeight"];
                if (![[PlaySettings shared] inverseScreenValues]) {
                    if(@available(iOS 17.1, *))
                        pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frameDefault));
                    else
                        pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frameDefault));
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_boundsDefault));
                    pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_sizeDelfault));
                }
                pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(orientation), @selector(hook_orientation));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBoundsDefault));
                
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));
            }
        }
    } 
    else {
        if ([[PlaySettings shared] adaptiveDisplay]) {
                if(@available(iOS 17.1, *))
                    pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frame));
                else
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frame));
                pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_bounds));
                pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_size));
            }
    }
    
    pt_swizzleInstanceMethod(objc_getClass("_UIMenuBuilder"), sel_getUid("initWithRootMenu:"), @selector(initWithRootMenuHook:));
    pt_swizzleInstanceMethod(objc_getClass("IOSViewController"), @selector(prefersPointerLocked), @selector(hook_prefersPointerLocked));
    // Set idiom to iPad
    // [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(userInterfaceIdiom) withMethod:@selector(hook_userInterfaceIdiom)];
    // [objc_getClass("UITraitCollection") swizzleInstanceMethod:@selector(userInterfaceIdiom) withMethod:@selector(hook_userInterfaceIdiom)];

    pt_swizzleInstanceMethod(objc_getClass("VSSubscriptionRegistrationCenter"), @selector(setCurrentSubscription:), @selector(hook_setCurrentSubscription:));

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            SEL newSelector = @selector(hook_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:);
            pt_swizzleInstanceMethod(objc_getClass("NSString"), origSelector, newSelector);
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        pt_swizzleInstanceMethod(objc_getClass("AVAudioSession"), @selector(requestRecordPermission:), @selector(hook_requestRecordPermission:));
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        pt_swizzleInstanceMethod(objc_getClass("CMMotionManager"), @selector(init), @selector(hook_CMMotionManager_init));
    }

    if (([[PlaySettings shared] disableBuiltinMouse])) {
        pt_swizzleClassMethod(objc_getClass("GCMouse"), @selector(current), @selector(hook_GCMouse_current));
        pt_swizzleClassMethod(objc_getClass("GCMouse"), @selector(mice), @selector(hook_GCMouse_mice));
    }

    // Delay a frame to wait for some frameworks (such as UnityFramework) to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.01 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
            pt_swizzleClassMethod(objc_getClass("KeyboardDelegate"), NSSelectorFromString(@"Initialize"), @selector(hook_Unity_KeyboardDelegate_Initialize));
        }
    });
}

@end
