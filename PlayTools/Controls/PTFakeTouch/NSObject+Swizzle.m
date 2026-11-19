//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/lock.h>
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

- (void) swizzleExchangeMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    Class cls = [self class];
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

+ (void) swizzleClassMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    Class cls = object_getClass((id)self);
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod(cls, newSelector);

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

typedef CGSize (*PTLayoutContentSizeIMP)(id, SEL);
typedef void (*PTLayoutPrepareIMP)(id, SEL);

static os_unfair_lock sCustomLayoutHookLock = OS_UNFAIR_LOCK_INIT;
static Method sBaseLayoutPrepareMethod = NULL;
static Method sBaseLayoutContentSizeMethod = NULL;

static NSMutableSet<NSValue *> *PTCheckedLayoutClasses(void) {
    static NSMutableSet<NSValue *> *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static NSMutableSet<NSValue *> *PTHookedCustomLayoutClasses(void) {
    static NSMutableSet<NSValue *> *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static NSMutableSet<NSValue *> *PTHookedLayoutMethods(void) {
    static NSMutableSet<NSValue *> *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static NSHashTable *PTPreparedLayouts(void) {
    static NSHashTable *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSHashTable *PTCurrentlyPreparingLayouts(void) {
    static NSHashTable *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSMapTable<UICollectionViewLayout *, NSValue *> *PTPrimedLayoutBounds(void) {
    static NSMapTable<UICollectionViewLayout *, NSValue *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMapTable weakToStrongObjectsMapTable];
    });
    return map;
}

static NSMapTable<UICollectionViewLayout *, NSValue *> *PTLayoutSubviewsInvalidatedBounds(void) {
    static NSMapTable<UICollectionViewLayout *, NSValue *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMapTable weakToStrongObjectsMapTable];
    });
    return map;
}

static NSMutableSet<NSValue *> *PTActiveLazyLayoutCalculations(void) {
    static NSMutableSet<NSValue *> *active = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        active = [NSMutableSet set];
    });
    return active;
}

static BOOL PTCollectionViewHasAnyItems(UICollectionView *cv) {
    NSInteger sections = [cv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        if ([cv numberOfItemsInSection:s] > 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL PTShouldPrimeLayoutAtSize(UICollectionViewLayout *layout, CGSize size) {
    NSValue *primedVal = [PTPrimedLayoutBounds() objectForKey:layout];
    if (!primedVal) {
        return YES;
    }
    CGSize prev = [primedVal CGSizeValue];
    return (fabs(prev.width - size.width) > 0.5 || fabs(prev.height - size.height) > 0.5);
}

static BOOL PTShouldInvalidateInLayoutSubviews(UICollectionViewLayout *layout, CGSize size) {
    NSValue *prevVal = [PTLayoutSubviewsInvalidatedBounds() objectForKey:layout];
    if (!prevVal) {
        return YES;
    }
    CGSize prev = [prevVal CGSizeValue];
    return (fabs(prev.width - size.width) > 0.5 || fabs(prev.height - size.height) > 0.5);
}

static BOOL PTIsSystemOrPlayToolsIMP(IMP imp) {
    if (!imp) {
        return YES;
    }
    Dl_info info;
    if (dladdr((const void *)imp, &info) == 0 || !info.dli_fname) {
        return YES;
    }
    static const void *sSelfBase = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info selfInfo;
        if (dladdr((const void *)&PTIsSystemOrPlayToolsIMP, &selfInfo) != 0) {
            sSelfBase = selfInfo.dli_fbase;
        }
    });
    if (sSelfBase && info.dli_fbase == sSelfBase) {
        return YES;
    }
    NSString *fname = [NSString stringWithUTF8String:info.dli_fname];
    if ([fname hasPrefix:@"/System/"] ||
        [fname hasPrefix:@"/usr/lib/"] ||
        [fname hasPrefix:@"/Library/Apple/"]) {
        return YES;
    }
    return NO;
}

static BOOL PTIsHookedCustomLayout(UICollectionViewLayout *layout) {
    if (!layout) {
        return NO;
    }
    Class cls = [layout class];
    if (!cls) {
        return NO;
    }
    NSValue *clsKey = [NSValue valueWithPointer:(__bridge const void *)cls];
    os_unfair_lock_lock(&sCustomLayoutHookLock);
    BOOL hooked = [PTHookedCustomLayoutClasses() containsObject:clsKey];
    os_unfair_lock_unlock(&sCustomLayoutHookLock);
    return hooked;
}

static void PTEnsureCustomCollectionViewLayoutHooked(UICollectionViewLayout *layout) {
    if (!layout || ![layout isKindOfClass:[UICollectionViewLayout class]]) {
        return;
    }
    Class cls = [layout class];
    if (!cls) {
        return;
    }
    NSValue *clsKey = [NSValue valueWithPointer:(__bridge const void *)cls];
    os_unfair_lock_lock(&sCustomLayoutHookLock);
    if ([PTCheckedLayoutClasses() containsObject:clsKey]) {
        os_unfair_lock_unlock(&sCustomLayoutHookLock);
        return;
    }

    SEL csSel = @selector(collectionViewContentSize);
    Method csMethod = class_getInstanceMethod(cls, csSel);
    if (!csMethod || csMethod == sBaseLayoutContentSizeMethod) {
        [PTCheckedLayoutClasses() addObject:clsKey];
        os_unfair_lock_unlock(&sCustomLayoutHookLock);
        return;
    }

    NSValue *csMethodKey = [NSValue valueWithPointer:(const void *)csMethod];
    BOOL hasCustomCS = [PTHookedLayoutMethods() containsObject:csMethodKey];
    if (!hasCustomCS) {
        IMP csImp = method_getImplementation(csMethod);
        if (PTIsSystemOrPlayToolsIMP(csImp)) {
            [PTCheckedLayoutClasses() addObject:clsKey];
            os_unfair_lock_unlock(&sCustomLayoutHookLock);
            return;
        }
        PTLayoutContentSizeIMP origContentSize = (PTLayoutContentSizeIMP)csImp;
        IMP wrappedCS = imp_implementationWithBlock(^CGSize(UICollectionViewLayout *selfLayout) {
            CGSize cs = origContentSize(selfLayout, csSel);
            if (cs.width > 0.5 && cs.height > 0.5) {
                return cs;
            }
            if (![NSThread isMainThread] || !selfLayout) {
                return cs;
            }
            if (![PTPreparedLayouts() containsObject:selfLayout] ||
                [PTCurrentlyPreparingLayouts() containsObject:selfLayout]) {
                return cs;
            }
            NSValue *instanceKey = [NSValue valueWithPointer:(__bridge const void *)selfLayout];
            NSMutableSet<NSValue *> *active = PTActiveLazyLayoutCalculations();
            if ([active containsObject:instanceKey]) {
                return cs;
            }
            UICollectionView *cv = selfLayout.collectionView;
            if (!cv || cv.bounds.size.width <= 1.0 || cv.bounds.size.height <= 1.0) {
                return cs;
            }
            CGSize boundsSize = cv.bounds.size;
            if (!PTShouldPrimeLayoutAtSize(selfLayout, boundsSize)) {
                return cs;
            }
            if (!PTCollectionViewHasAnyItems(cv)) {
                return cs;
            }
            [PTPrimedLayoutBounds() setObject:[NSValue valueWithCGSize:boundsSize] forKey:selfLayout];
            [active addObject:instanceKey];
            @try {
                CGRect queryRect = CGRectMake(cv.bounds.origin.x,
                                              cv.bounds.origin.y,
                                              MAX(boundsSize.width, 1.0),
                                              MAX(boundsSize.height, 1.0));
                [selfLayout layoutAttributesForElementsInRect:queryRect];
            } @finally {
                [active removeObject:instanceKey];
            }
            cs = origContentSize(selfLayout, csSel);
            return cs;
        });
        method_setImplementation(csMethod, wrappedCS);
        [PTHookedLayoutMethods() addObject:csMethodKey];
        hasCustomCS = YES;
    }

    if (!hasCustomCS) {
        [PTCheckedLayoutClasses() addObject:clsKey];
        os_unfair_lock_unlock(&sCustomLayoutHookLock);
        return;
    }

    SEL prepSel = @selector(prepareLayout);
    Method prepMethod = class_getInstanceMethod(cls, prepSel);
    if (prepMethod && prepMethod != sBaseLayoutPrepareMethod) {
        NSValue *prepMethodKey = [NSValue valueWithPointer:(const void *)prepMethod];
        if (![PTHookedLayoutMethods() containsObject:prepMethodKey]) {
            IMP prepImp = method_getImplementation(prepMethod);
            if (!PTIsSystemOrPlayToolsIMP(prepImp)) {
                PTLayoutPrepareIMP origPrepare = (PTLayoutPrepareIMP)prepImp;
                IMP wrappedPrep = imp_implementationWithBlock(^void(UICollectionViewLayout *selfLayout) {
                    BOOL onMain = [NSThread isMainThread] && selfLayout != nil;
                    if (onMain) {
                        [PTCurrentlyPreparingLayouts() addObject:selfLayout];
                    }
                    @try {
                        origPrepare(selfLayout, prepSel);
                    } @finally {
                        if (onMain) {
                            [PTCurrentlyPreparingLayouts() removeObject:selfLayout];
                            [PTPreparedLayouts() addObject:selfLayout];
                        }
                    }
                });
                method_setImplementation(prepMethod, wrappedPrep);
                [PTHookedLayoutMethods() addObject:prepMethodKey];
            }
        }
    }

    [PTHookedCustomLayoutClasses() addObject:clsKey];
    [PTCheckedLayoutClasses() addObject:clsKey];
    os_unfair_lock_unlock(&sCustomLayoutHookLock);
}

- (void) hook_uicollectionviewlayout_prepareLayout {
    [self hook_uicollectionviewlayout_prepareLayout];
    if ([NSThread isMainThread] && [self isKindOfClass:[UICollectionViewLayout class]]) {
        [PTPreparedLayouts() addObject:self];
    }
}

- (void) hook_uicollectionviewlayout_invalidateLayoutWithContext:(UICollectionViewLayoutInvalidationContext *)context {
    if ([NSThread isMainThread] && [self isKindOfClass:[UICollectionViewLayout class]]) {
        UICollectionViewLayout *layout = (UICollectionViewLayout *)self;
        NSValue *instanceKey = [NSValue valueWithPointer:(__bridge const void *)layout];
        [PTPreparedLayouts() removeObject:layout];
        if (![PTActiveLazyLayoutCalculations() containsObject:instanceKey] &&
            ![PTCurrentlyPreparingLayouts() containsObject:layout]) {
            [PTPrimedLayoutBounds() removeObjectForKey:layout];
        }
    }
    [self hook_uicollectionviewlayout_invalidateLayoutWithContext:context];
}

- (instancetype) hook_uicollectionview_initWithFrame:(CGRect)frame
                                collectionViewLayout:(UICollectionViewLayout *)layout {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    return [self hook_uicollectionview_initWithFrame:frame collectionViewLayout:layout];
}

- (void) hook_uicollectionview_setCollectionViewLayout:(UICollectionViewLayout *)layout {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self hook_uicollectionview_setCollectionViewLayout:layout];
}

- (void) hook_uicollectionview_setCollectionViewLayout:(UICollectionViewLayout *)layout
                                              animated:(BOOL)animated {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self hook_uicollectionview_setCollectionViewLayout:layout animated:animated];
}

- (void) hook_uicollectionview_setCollectionViewLayout:(UICollectionViewLayout *)layout
                                              animated:(BOOL)animated
                                            completion:(void (^)(BOOL finished))completion {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self hook_uicollectionview_setCollectionViewLayout:layout animated:animated completion:completion];
}

- (void) hook_uicollectionview_layoutSubviews {
    UICollectionView *cv = nil;
    if ([self isKindOfClass:[UICollectionView class]]) {
        cv = (UICollectionView *)self;
        if (cv.collectionViewLayout) {
            PTEnsureCustomCollectionViewLayoutHooked(cv.collectionViewLayout);
        }
    }
    [self hook_uicollectionview_layoutSubviews];
    if (cv && [NSThread isMainThread]) {
        UICollectionViewLayout *layout = cv.collectionViewLayout;
        CGSize boundsSize = cv.bounds.size;
        if (layout &&
            PTIsHookedCustomLayout(layout) &&
            boundsSize.width > 1.0 && boundsSize.height > 1.0 &&
            (cv.contentSize.width <= 0.5 || cv.contentSize.height <= 0.5) &&
            ![PTCurrentlyPreparingLayouts() containsObject:layout] &&
            PTShouldPrimeLayoutAtSize(layout, boundsSize) &&
            PTShouldInvalidateInLayoutSubviews(layout, boundsSize) &&
            PTCollectionViewHasAnyItems(cv)) {
            [PTLayoutSubviewsInvalidatedBounds() setObject:[NSValue valueWithCGSize:boundsSize]
                                                    forKey:layout];
            [layout invalidateLayout];
        }
    }
}

- (void) hook_setCurrentSubscription:(VSSubscription *)currentSubscription {
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
            [objc_getClass("_UIApplicationInfoParser") swizzleInstanceMethod:NSSelectorFromString(@"requiresFullScreen") withMethod:@selector(hook_requiresFullScreen)];
            [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_boundsResizable)];
            [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
            [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
            Class baseLayoutCls = objc_getClass("UICollectionViewLayout");
            sBaseLayoutPrepareMethod = class_getInstanceMethod(baseLayoutCls, @selector(prepareLayout));
            sBaseLayoutContentSizeMethod = class_getInstanceMethod(baseLayoutCls, @selector(collectionViewContentSize));
            [baseLayoutCls swizzleInstanceMethod:@selector(prepareLayout)
                                      withMethod:@selector(hook_uicollectionviewlayout_prepareLayout)];
            [baseLayoutCls swizzleInstanceMethod:@selector(invalidateLayoutWithContext:)
                                      withMethod:@selector(hook_uicollectionviewlayout_invalidateLayoutWithContext:)];
            Class cvCls = objc_getClass("UICollectionView");
            [cvCls swizzleInstanceMethod:@selector(initWithFrame:collectionViewLayout:)
                              withMethod:@selector(hook_uicollectionview_initWithFrame:collectionViewLayout:)];
            [cvCls swizzleInstanceMethod:@selector(setCollectionViewLayout:)
                              withMethod:@selector(hook_uicollectionview_setCollectionViewLayout:)];
            [cvCls swizzleInstanceMethod:@selector(setCollectionViewLayout:animated:)
                              withMethod:@selector(hook_uicollectionview_setCollectionViewLayout:animated:)];
            [cvCls swizzleInstanceMethod:@selector(setCollectionViewLayout:animated:completion:)
                              withMethod:@selector(hook_uicollectionview_setCollectionViewLayout:animated:completion:)];
            [cvCls swizzleInstanceMethod:@selector(layoutSubviews)
                              withMethod:@selector(hook_uicollectionview_layoutSubviews)];
        }
        else if ([[PlaySettings shared] adaptiveDisplay]) {
            // This is an experimental fix
            if ([[PlaySettings shared] inverseScreenValues]) {
                // This lines set External Scene settings and other IOS10 Runtime services by swizzling
                // In Sonoma 14.1 betas, frame method seems to be moved to FBSSceneSettingsCore
                if(@available(iOS 17.1, *))
                    [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                else
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_boundsDefault)];
                [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_sizeDelfault)];
                
                // Fixes Apple mess at MacOS 13.2
                [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBoundsDefault)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
            } else {
                // This acutally runs when adaptiveDisplay is normally triggered
                if(@available(iOS 17.1, *))
                    [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frame)];
                else
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frame)];
                [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_bounds)];
                [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_size)];
                
                [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBounds)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];   
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
                        [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                    else
                        [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_boundsDefault)];
                    [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_sizeDelfault)];
                }
                [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBoundsDefault)];
                
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
            }
        }
    } 
    else {
        if ([[PlaySettings shared] adaptiveDisplay]) {
                if(@available(iOS 17.1, *))
                    [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frame)];
                else
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frame)];
                [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_bounds)];
                [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_size)];
            }
    }
    
    [objc_getClass("_UIMenuBuilder") swizzleInstanceMethod:sel_getUid("initWithRootMenu:") withMethod:@selector(initWithRootMenuHook:)];
    [objc_getClass("IOSViewController") swizzleInstanceMethod:@selector(prefersPointerLocked) withMethod:@selector(hook_prefersPointerLocked)];
    // Set idiom to iPad
    // [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(userInterfaceIdiom) withMethod:@selector(hook_userInterfaceIdiom)];
    // [objc_getClass("UITraitCollection") swizzleInstanceMethod:@selector(userInterfaceIdiom) withMethod:@selector(hook_userInterfaceIdiom)];

    [objc_getClass("VSSubscriptionRegistrationCenter") swizzleInstanceMethod:@selector(setCurrentSubscription:) withMethod:@selector(hook_setCurrentSubscription:)];

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            SEL newSelector = @selector(hook_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:);
            [objc_getClass("NSString") swizzleInstanceMethod:origSelector withMethod:newSelector];
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        [objc_getClass("AVAudioSession") swizzleInstanceMethod:@selector(requestRecordPermission:) withMethod:@selector(hook_requestRecordPermission:)];
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        [objc_getClass("CMMotionManager") swizzleInstanceMethod:@selector(init) withMethod:@selector(hook_CMMotionManager_init)];
    }

    if (([[PlaySettings shared] disableBuiltinMouse])) {
        [objc_getClass("GCMouse") swizzleClassMethod:@selector(current) withMethod:@selector(hook_GCMouse_current)];
        [objc_getClass("GCMouse") swizzleClassMethod:@selector(mice) withMethod:@selector(hook_GCMouse_mice)];
    }

    // Delay a frame to wait for some frameworks (such as UnityFramework) to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.01 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
            [objc_getClass("KeyboardDelegate") swizzleClassMethod:NSSelectorFromString(@"Initialize") withMethod:@selector(hook_Unity_KeyboardDelegate_Initialize)];
        }
    });
}

@end
