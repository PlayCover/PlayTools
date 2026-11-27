//
//  PlayEfficiencyHooks.m
//  PlayTools
//

#import "PlayEfficiencyHooks.h"
#import "PlayLoader.h"

#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

#import <PlayTools/PlayTools-Swift.h>

#ifndef DYLD_INTERPOSE_ORIG
#define DYLD_INTERPOSE_ORIG(_type, _replacee) \
    (*(_type const volatile *)&_interpose_##_replacee.replacee)
#endif

static void pt_eff_swizzleInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
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
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void pt_eff_swizzleClassMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
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
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

#define pt_swizzleInstanceMethod pt_eff_swizzleInstanceMethod
#define pt_swizzleClassMethod pt_eff_swizzleClassMethod

static NSString *const kPTWindowVisibilityDidChangeNotification = @"PTWindowVisibilityDidChangeNotification";

static const NSUInteger kPTDefaultNSCacheCostLimit = 64u * 1024u * 1024u;
static const NSUInteger kPTMaxURLCacheMemoryCapacity = 8u * 1024u * 1024u;
static const NSInteger kPTOccludedLowFPS = 5;
static const NSInteger kPTOccludedAdaptiveDeepFPS = 1;
static const NSTimeInterval kPTOcclusionDelaySeconds = 10.0;
static const double kPTMaxAVPeakBitRate = 3000000.0;
static const NSTimeInterval kPTMaxAVForwardBufferDuration = 8.0;

static const NSInteger kPTAdaptiveActiveFPS = 60;
static const NSInteger kPTAdaptiveIdleLightFPS = 10;
static const NSInteger kPTAdaptiveIdleDeepFPS = 1;
static const NSInteger kPTAdaptiveMediaFloorFPS = 30;
static const NSTimeInterval kPTDefaultAdaptiveIdleLightSeconds = 3.0;
static const NSTimeInterval kPTDefaultAdaptiveIdleDeepSeconds = 12.0;
static const NSTimeInterval kPTAdaptiveInputCoalesceSeconds = 0.25;
static const NSTimeInterval kPTAdaptiveMotionWindowSeconds = 1.0;
static const NSTimeInterval kPTAdaptiveMotionHoldGraceSeconds = 1.0;
static const NSTimeInterval kPTAdaptiveMotionReevalIntervalSeconds = 0.5;
static const float kPTHighFPSVideoThreshold = 35.0f;
enum { kPTMotionRingCapacity = 128 };

typedef NS_ENUM(NSInteger, PTAdaptiveFPSStage) {
    PTAdaptiveFPSStageActive = 0,
    PTAdaptiveFPSStageIdleLight = 1,
    PTAdaptiveFPSStageIdleDeep = 2,
};

static BOOL pt_powerSavingMode = NO;
static BOOL pt_memorySavingMode = NO;
static BOOL pt_metalMemorySaver = NO;
static BOOL pt_avMediaSaver = NO;
static BOOL pt_fpsOverlay = NO;
static NSInteger pt_configuredFrameRateCap = 0;

static NSTimeInterval pt_adaptiveIdleLightSeconds = kPTDefaultAdaptiveIdleLightSeconds;
static NSTimeInterval pt_adaptiveIdleDeepSeconds = kPTDefaultAdaptiveIdleDeepSeconds;

static _Atomic BOOL pt_forceReduceAccessibility = false;
static _Atomic BOOL pt_occludedLowFPSActive = false;
static _Atomic NSInteger pt_adaptiveStage = PTAdaptiveFPSStageActive;
static _Atomic BOOL pt_cachedMediaPlaying = false;
static _Atomic BOOL pt_cachedHighFPSVideo = false;
static _Atomic BOOL pt_cachedMotionDemand = false;
static _Atomic BOOL pt_adaptiveMotionHold = false;
static _Atomic uint64_t pt_metalDrawableFrameCount = 0;
static _Atomic uint64_t pt_lastMotionBucket = 0;
static _Atomic double pt_lastSampleBufferEnqueueTime = 0.0;
static _Atomic BOOL pt_pendingMotionReevalScheduled = false;
static BOOL pt_lastKnownWindowVisible = YES;
static CFTimeInterval pt_lastAdaptiveScheduleTime = 0.0;
static CFTimeInterval pt_lastMotionActiveTime = 0.0;
static CFTimeInterval pt_ceilingEffectiveSince = 0.0;

static __thread BOOL pt_tlsSuppressMotionRecording = NO;
static __weak CALayer *pt_overlayPillLayer = nil;
static Class pt_avPlayerLayerClass = Nil;
static Class pt_avSampleBufferDisplayLayerClass = Nil;
static Class pt_caMetalLayerClass = Nil;

static os_unfair_lock pt_motionLock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval pt_motionFrameTimes[kPTMotionRingCapacity];
static NSUInteger pt_motionFrameHead = 0;
static CFTimeInterval pt_metalDrawableTimes[kPTMotionRingCapacity];
static NSUInteger pt_metalDrawableHead = 0;
static CFTimeInterval pt_sampleBufferTimes[kPTMotionRingCapacity];
static NSUInteger pt_sampleBufferHead = 0;
static NSHashTable<CALayer *> *pt_activeAnimatedLayers = nil;

static os_unfair_lock pt_nsCacheLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<NSCache *> *pt_registeredNSCaches = nil;

static os_unfair_lock pt_mtkViewLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<MTKView *> *pt_trackedMTKViews = nil;

static os_unfair_lock pt_displayLinkLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<CADisplayLink *> *pt_trackedDisplayLinks = nil;

static os_unfair_lock pt_webViewLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<WKWebView *> *pt_trackedWKWebViews = nil;

static os_unfair_lock pt_avPlayerLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<AVPlayer *> *pt_trackedAVPlayers = nil;

static __weak id pt_cachedAKPlugin = nil;
static dispatch_block_t pt_pendingOcclusionWorkItem = nil;
static dispatch_block_t pt_pendingAdaptiveLightWorkItem = nil;
static dispatch_block_t pt_pendingAdaptiveDeepWorkItem = nil;
static dispatch_block_t pt_pendingMotionHoldTimer = nil;

static const void *const kPTWebViewMediaSuspendedKey = &kPTWebViewMediaSuspendedKey;
static const void *const kPTDisplayLinkRateStateKey = &kPTDisplayLinkRateStateKey;
static const void *const kPTMTKViewRequestedFPSKey = &kPTMTKViewRequestedFPSKey;
static const void *const kPTLayerAnimExpiryKey = &kPTLayerAnimExpiryKey;
static const void *const kPTPlayerItemVideoFPSKey = &kPTPlayerItemVideoFPSKey;
static const void *const kPTPlayerItemFPSLoadingKey = &kPTPlayerItemFPSLoadingKey;

#pragma mark - Settings Helpers

static BOOL pt_settingsBool(id _Nullable settingsObj, SEL sel) {
    if (!settingsObj || !sel || ![settingsObj respondsToSelector:sel]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(settingsObj, sel);
}

static NSInteger pt_settingsInteger(id _Nullable settingsObj, SEL sel) {
    if (!settingsObj || !sel || ![settingsObj respondsToSelector:sel]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(settingsObj, sel);
}

#pragma mark - Accessibility Interpose & Class Hook

typedef BOOL (*pt_accessibility_bool_fn)(void);

static BOOL pt_hook_UIAccessibilityIsReduceTransparencyEnabled(void);
static BOOL pt_hook_UIAccessibilityIsReduceMotionEnabled(void);

DYLD_INTERPOSE(pt_hook_UIAccessibilityIsReduceTransparencyEnabled, UIAccessibilityIsReduceTransparencyEnabled)
DYLD_INTERPOSE(pt_hook_UIAccessibilityIsReduceMotionEnabled, UIAccessibilityIsReduceMotionEnabled)

static BOOL pt_hook_UIAccessibilityIsReduceTransparencyEnabled(void) {
    if (atomic_load_explicit(&pt_forceReduceAccessibility, memory_order_acquire)) {
        return YES;
    }
    return DYLD_INTERPOSE_ORIG(pt_accessibility_bool_fn, UIAccessibilityIsReduceTransparencyEnabled)();
}

static BOOL pt_hook_UIAccessibilityIsReduceMotionEnabled(void) {
    if (atomic_load_explicit(&pt_forceReduceAccessibility, memory_order_acquire)) {
        return YES;
    }
    return DYLD_INTERPOSE_ORIG(pt_accessibility_bool_fn, UIAccessibilityIsReduceMotionEnabled)();
}

static BOOL pt_accessibilityClassReturnYES(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static void pt_installAccessibilityHooks(void) {
    atomic_store_explicit(&pt_forceReduceAccessibility, true, memory_order_release);

    Class accCls = objc_getClass("UIAccessibility");
    Class accMeta = accCls ? object_getClass((id)accCls) : Nil;
    if (!accMeta) {
        return;
    }
    SEL selectors[2] = {
        NSSelectorFromString(@"isReduceTransparencyEnabled"),
        NSSelectorFromString(@"isReduceMotionEnabled")
    };
    for (size_t i = 0; i < 2; i++) {
        Method m = class_getClassMethod(accCls, selectors[i]);
        if (m) {
            class_replaceMethod(accMeta, selectors[i], (IMP)pt_accessibilityClassReturnYES, method_getTypeEncoding(m));
        }
    }
}

#pragma mark - NSCache & NSURLCache Governance

static void pt_registerNSCache(NSCache * _Nullable cache) {
    if (!cache) {
        return;
    }
    os_unfair_lock_lock(&pt_nsCacheLock);
    if (!pt_registeredNSCaches) {
        pt_registeredNSCaches = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_registeredNSCaches addObject:cache];
    os_unfair_lock_unlock(&pt_nsCacheLock);
}

static NSUInteger pt_clampedURLCacheMemoryCapacity(NSUInteger memoryCapacity) {
    return (memoryCapacity > kPTMaxURLCacheMemoryCapacity) ? kPTMaxURLCacheMemoryCapacity : memoryCapacity;
}

@interface NSCache (PTEfficiencyHooks)
- (instancetype)pt_eff_init __attribute__((objc_method_family(init)));
- (void)pt_eff_setTotalCostLimit:(NSUInteger)lim;
- (void)pt_eff_setCountLimit:(NSUInteger)lim;
@end

@implementation NSCache (PTEfficiencyHooks)

- (instancetype)pt_eff_init {
    NSCache *instance = [self pt_eff_init];
    if (instance) {
        pt_registerNSCache(instance);
        if (instance.totalCostLimit == 0 && instance.countLimit == 0) {
            [instance pt_eff_setTotalCostLimit:kPTDefaultNSCacheCostLimit];
        }
    }
    return instance;
}

- (void)pt_eff_setTotalCostLimit:(NSUInteger)lim {
    pt_registerNSCache(self);
    NSUInteger effectiveLim = (lim == 0 && self.countLimit == 0) ? kPTDefaultNSCacheCostLimit : lim;
    [self pt_eff_setTotalCostLimit:effectiveLim];
}

- (void)pt_eff_setCountLimit:(NSUInteger)lim {
    pt_registerNSCache(self);
    [self pt_eff_setCountLimit:lim];
    if (lim == 0 && self.totalCostLimit == 0) {
        [self pt_eff_setTotalCostLimit:kPTDefaultNSCacheCostLimit];
    }
}

@end

@interface NSURLCache (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithMemoryCapacity:(NSUInteger)memoryCapacity
                                diskCapacity:(NSUInteger)diskCapacity
                                directoryURL:(nullable NSURL *)directoryURL __attribute__((objc_method_family(init)));
- (void)pt_eff_setMemoryCapacity:(NSUInteger)memoryCapacity;
@end

@implementation NSURLCache (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithMemoryCapacity:(NSUInteger)memoryCapacity
                                diskCapacity:(NSUInteger)diskCapacity
                                directoryURL:(nullable NSURL *)directoryURL {
    return [self pt_eff_initWithMemoryCapacity:pt_clampedURLCacheMemoryCapacity(memoryCapacity)
                                  diskCapacity:diskCapacity
                                  directoryURL:directoryURL];
}

- (void)pt_eff_setMemoryCapacity:(NSUInteger)memoryCapacity {
    [self pt_eff_setMemoryCapacity:pt_clampedURLCacheMemoryCapacity(memoryCapacity)];
}

@end

static void pt_installCacheGovernanceHooks(void) {
    Class nsCacheCls = [NSCache class];
    pt_swizzleInstanceMethod(nsCacheCls, @selector(init), @selector(pt_eff_init));
    pt_swizzleInstanceMethod(nsCacheCls, @selector(setTotalCostLimit:), @selector(pt_eff_setTotalCostLimit:));
    pt_swizzleInstanceMethod(nsCacheCls, @selector(setCountLimit:), @selector(pt_eff_setCountLimit:));

    Class urlCacheCls = [NSURLCache class];
    pt_swizzleInstanceMethod(urlCacheCls,
                             @selector(initWithMemoryCapacity:diskCapacity:directoryURL:),
                             @selector(pt_eff_initWithMemoryCapacity:diskCapacity:directoryURL:));
    pt_swizzleInstanceMethod(urlCacheCls, @selector(setMemoryCapacity:), @selector(pt_eff_setMemoryCapacity:));

    NSURLCache *sharedCache = [NSURLCache sharedURLCache];
    if (sharedCache.memoryCapacity > kPTMaxURLCacheMemoryCapacity) {
        sharedCache.memoryCapacity = kPTMaxURLCacheMemoryCapacity;
    }
}

#pragma mark - Metal & Backing Store Hooks

static void (*pt_origMetalLayerSetWantsEDR)(id, SEL, BOOL) = NULL;

static void pt_hook_metalLayerSetWantsEDR(id self, SEL _cmd, BOOL wantsEDR) {
    (void)wantsEDR;
    if (pt_origMetalLayerSetWantsEDR) {
        pt_origMetalLayerSetWantsEDR(self, _cmd, NO);
    }
}

@interface CAMetalLayer (PTEfficiencyHooks)
- (instancetype)pt_eff_metalLayerInit __attribute__((objc_method_family(init)));
- (void)pt_eff_setMaximumDrawableCount:(NSUInteger)count;
@end

@implementation CAMetalLayer (PTEfficiencyHooks)

- (instancetype)pt_eff_metalLayerInit {
    CAMetalLayer *layer = [self pt_eff_metalLayerInit];
    if (layer) {
        if (layer.maximumDrawableCount > 2) {
            layer.maximumDrawableCount = 2;
        }
        SEL setEdrSel = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
        if (setEdrSel && [layer respondsToSelector:setEdrSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setEdrSel, NO);
        }
    }
    return layer;
}

- (void)pt_eff_setMaximumDrawableCount:(NSUInteger)count {
    NSUInteger clamped = (count > 2) ? 2 : count;
    [self pt_eff_setMaximumDrawableCount:clamped];
}

@end

@interface CALayer (PTEfficiencyHooks)
- (void)pt_eff_setContentsFormat:(CALayerContentsFormat)contentsFormat;
@end

@implementation CALayer (PTEfficiencyHooks)

- (void)pt_eff_setContentsFormat:(CALayerContentsFormat)contentsFormat {
    (void)contentsFormat;
    [self pt_eff_setContentsFormat:kCAContentsFormatRGBA8Uint];
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@interface UIGraphicsImageRendererFormat (PTEfficiencyHooks)
- (BOOL)pt_eff_prefersExtendedRange;
- (void)pt_eff_setPrefersExtendedRange:(BOOL)prefersExtendedRange;
- (UIGraphicsImageRendererFormatRange)pt_eff_preferredRange;
- (void)pt_eff_setPreferredRange:(UIGraphicsImageRendererFormatRange)preferredRange;
@end

@implementation UIGraphicsImageRendererFormat (PTEfficiencyHooks)

- (BOOL)pt_eff_prefersExtendedRange {
    return NO;
}

- (void)pt_eff_setPrefersExtendedRange:(BOOL)prefersExtendedRange {
    (void)prefersExtendedRange;
    [self pt_eff_setPrefersExtendedRange:NO];
}

- (UIGraphicsImageRendererFormatRange)pt_eff_preferredRange {
    UIGraphicsImageRendererFormatRange orig = [self pt_eff_preferredRange];
    if (orig == UIGraphicsImageRendererFormatRangeExtended ||
        orig == UIGraphicsImageRendererFormatRangeAutomatic) {
        return UIGraphicsImageRendererFormatRangeStandard;
    }
    return orig;
}

- (void)pt_eff_setPreferredRange:(UIGraphicsImageRendererFormatRange)preferredRange {
    UIGraphicsImageRendererFormatRange clamped = preferredRange;
    if (clamped == UIGraphicsImageRendererFormatRangeExtended ||
        clamped == UIGraphicsImageRendererFormatRangeAutomatic) {
        clamped = UIGraphicsImageRendererFormatRangeStandard;
    }
    [self pt_eff_setPreferredRange:clamped];
}

@end

#pragma clang diagnostic pop

static void pt_installMetalAndBackingStoreHooks(void) {
    Class metalLayerCls = [CAMetalLayer class];
    pt_swizzleInstanceMethod(metalLayerCls, @selector(init), @selector(pt_eff_metalLayerInit));
    pt_swizzleInstanceMethod(metalLayerCls,
                             @selector(setMaximumDrawableCount:),
                             @selector(pt_eff_setMaximumDrawableCount:));

    SEL setEdrSel = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    Method edrMethod = setEdrSel ? class_getInstanceMethod(metalLayerCls, setEdrSel) : NULL;
    if (edrMethod) {
        IMP origImp = method_getImplementation(edrMethod);
        if (origImp != (IMP)pt_hook_metalLayerSetWantsEDR) {
            pt_origMetalLayerSetWantsEDR = (void (*)(id, SEL, BOOL))origImp;
            class_replaceMethod(metalLayerCls,
                                setEdrSel,
                                (IMP)pt_hook_metalLayerSetWantsEDR,
                                method_getTypeEncoding(edrMethod));
        }
    }

    pt_swizzleInstanceMethod([CALayer class],
                             @selector(setContentsFormat:),
                             @selector(pt_eff_setContentsFormat:));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Class fmtCls = [UIGraphicsImageRendererFormat class];
    pt_swizzleInstanceMethod(fmtCls, @selector(prefersExtendedRange), @selector(pt_eff_prefersExtendedRange));
    pt_swizzleInstanceMethod(fmtCls, @selector(setPrefersExtendedRange:), @selector(pt_eff_setPrefersExtendedRange:));
    pt_swizzleInstanceMethod(fmtCls, @selector(preferredRange), @selector(pt_eff_preferredRange));
    pt_swizzleInstanceMethod(fmtCls, @selector(setPreferredRange:), @selector(pt_eff_setPreferredRange:));
#pragma clang diagnostic pop
}

#pragma mark - Frame Rate Ceiling & MTKView Tracking

typedef NS_ENUM(NSInteger, PTDisplayLinkRateMode) {
    PTDisplayLinkRateModeDefault = 0,
    PTDisplayLinkRateModeRange = 1,
    PTDisplayLinkRateModeFPS = 2,
    PTDisplayLinkRateModeInterval = 3,
};

@interface PTDisplayLinkRateState : NSObject
@property (nonatomic, assign) PTDisplayLinkRateMode mode;
@property (nonatomic, assign) CAFrameRateRange requestedRange;
@property (nonatomic, assign) NSInteger requestedFPS;
@property (nonatomic, assign) NSInteger requestedInterval;
@end

@implementation PTDisplayLinkRateState
@end

static void pt_reapplyActiveFPSCeilingToAllTracked(void);
static void pt_notifyOverlayCeilingDidChange(NSInteger ceiling);
static void pt_scheduleAdaptiveMotionReevalIfNeeded(void);

static NSUInteger pt_countRecentRingEvents(const CFTimeInterval *ring, NSUInteger capacity, CFTimeInterval cutoff) {
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < capacity; i++) {
        CFTimeInterval t = ring[i];
        if (t > cutoff) {
            count++;
        }
    }
    return count;
}

static void pt_recordRingTimestamp(CFTimeInterval *ring, NSUInteger *head, CFTimeInterval now) {
    os_unfair_lock_lock(&pt_motionLock);
    ring[*head & (kPTMotionRingCapacity - 1)] = now;
    *head += 1;
    os_unfair_lock_unlock(&pt_motionLock);
}

static void pt_probeVideoFPSForPlayerItem(AVPlayerItem * _Nullable item, float *outFPS) {
    if (!item || item.status != AVPlayerItemStatusReadyToPlay) {
        return;
    }

    float bestFPS = 0.0f;
    for (AVPlayerItemTrack *itemTrack in item.tracks) {
        if (!itemTrack.isEnabled) {
            continue;
        }
        float currentRate = itemTrack.currentVideoFrameRate;
        if (currentRate > bestFPS) {
            bestFPS = currentRate;
        }
    }
    if (bestFPS > 0.0f) {
        *outFPS = MAX(*outFPS, bestFPS);
        return;
    }

    NSNumber *cachedFPS = objc_getAssociatedObject(item, kPTPlayerItemVideoFPSKey);
    if ([cachedFPS isKindOfClass:[NSNumber class]]) {
        *outFPS = MAX(*outFPS, [cachedFPS floatValue]);
        return;
    }

    AVAsset *asset = item.asset;
    if (!asset) {
        return;
    }

    NSError *err = nil;
    if ([asset statusOfValueForKey:@"tracks" error:&err] == AVKeyValueStatusLoaded) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        float assetFPS = 0.0f;
        for (AVAssetTrack *track in videoTracks) {
            if ([track statusOfValueForKey:@"nominalFrameRate" error:nil] == AVKeyValueStatusLoaded) {
                assetFPS = MAX(assetFPS, track.nominalFrameRate);
            }
        }
#pragma clang diagnostic pop
        if (assetFPS > 0.0f) {
            objc_setAssociatedObject(item, kPTPlayerItemVideoFPSKey, @(assetFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            *outFPS = MAX(*outFPS, assetFPS);
            return;
        }
    }

    if (!objc_getAssociatedObject(item, kPTPlayerItemFPSLoadingKey)) {
        objc_setAssociatedObject(item, kPTPlayerItemFPSLoadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak AVPlayerItem *weakItem = item;
        [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
            AVPlayerItem *strongItem = weakItem;
            if (!strongItem) {
                return;
            }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSArray<AVAssetTrack *> *videoTracks = [strongItem.asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
            float loadedFPS = 0.0f;
            for (AVAssetTrack *track in videoTracks) {
                loadedFPS = MAX(loadedFPS, track.nominalFrameRate);
            }
            if (loadedFPS > 0.0f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    objc_setAssociatedObject(strongItem, kPTPlayerItemVideoFPSKey, @(loadedFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    pt_scheduleAdaptiveMotionReevalIfNeeded();
                });
            }
        }];
    }
}

static BOOL pt_isAnyMediaActivelyPlaying(void) {
    if (![NSThread isMainThread]) {
        return atomic_load_explicit(&pt_cachedMediaPlaying, memory_order_acquire);
    }

    CFTimeInterval now = CACurrentMediaTime();
    BOOL playing = [[AVAudioSession sharedInstance] isOtherAudioPlaying];
    float maxVideoFPS = 0.0f;

    os_unfair_lock_lock(&pt_avPlayerLock);
    NSArray<AVPlayer *> *players = pt_trackedAVPlayers ? [pt_trackedAVPlayers allObjects] : @[];
    os_unfair_lock_unlock(&pt_avPlayerLock);

    for (AVPlayer *player in players) {
        if (player.timeControlStatus == AVPlayerTimeControlStatusPlaying ||
            fabsf(player.rate) > 0.01f) {
            playing = YES;
            pt_probeVideoFPSForPlayerItem(player.currentItem, &maxVideoFPS);
        }
    }

    double lastSampleTime = atomic_load_explicit(&pt_lastSampleBufferEnqueueTime, memory_order_acquire);
    if (!playing && lastSampleTime > 0.0 && (now - lastSampleTime) < 1.5) {
        playing = YES;
    }

    os_unfair_lock_lock(&pt_motionLock);
    NSUInteger sampleRate = pt_countRecentRingEvents(pt_sampleBufferTimes, kPTMotionRingCapacity, now - 1.0);
    NSUInteger metalRate = pt_countRecentRingEvents(pt_metalDrawableTimes, kPTMotionRingCapacity, now - 1.0);
    os_unfair_lock_unlock(&pt_motionLock);

    if (!playing && metalRate >= 12) {
        playing = YES;
    }

    BOOL highFPSVideo = (maxVideoFPS > kPTHighFPSVideoThreshold) || (sampleRate >= (NSUInteger)kPTHighFPSVideoThreshold);
    atomic_store_explicit(&pt_cachedMediaPlaying, playing, memory_order_release);
    atomic_store_explicit(&pt_cachedHighFPSVideo, highFPSVideo, memory_order_release);
    return playing;
}

static BOOL pt_isLayerTreeVisible(CALayer * _Nullable layer) {
    CALayer *cur = layer;
    NSInteger depth = 0;
    while (cur && depth < 32) {
        if (cur.isHidden || cur.opacity <= 0.01f) {
            return NO;
        }
        id delegate = cur.delegate;
        if ([delegate isKindOfClass:[UIWindow class]]) {
            UIWindow *win = (UIWindow *)delegate;
            return !win.isHidden && win.alpha > 0.01;
        }
        cur = cur.superlayer;
        depth++;
    }
    return NO;
}

static BOOL pt_hasActiveSpatialCAAnimationOnMainThread(CFTimeInterval now) {
    os_unfair_lock_lock(&pt_motionLock);
    NSArray<CALayer *> *layers = pt_activeAnimatedLayers ? [pt_activeAnimatedLayers allObjects] : @[];
    os_unfair_lock_unlock(&pt_motionLock);

    if (layers.count == 0) {
        return NO;
    }

    BOOL foundActive = NO;
    NSMutableArray<CALayer *> *staleLayers = nil;
    for (CALayer *layer in layers) {
        NSNumber *expiryNum = objc_getAssociatedObject(layer, kPTLayerAnimExpiryKey);
        CFTimeInterval expiry = expiryNum ? [expiryNum doubleValue] : 0.0;
        BOOL stillLive = (now <= expiry &&
                          layer.animationKeys.count > 0 &&
                          pt_isLayerTreeVisible(layer));
        if (stillLive) {
            foundActive = YES;
        } else {
            if (!staleLayers) {
                staleLayers = [NSMutableArray array];
            }
            [staleLayers addObject:layer];
        }
    }

    if (staleLayers.count > 0) {
        os_unfair_lock_lock(&pt_motionLock);
        for (CALayer *stale in staleLayers) {
            objc_setAssociatedObject(stale, kPTLayerAnimExpiryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [pt_activeAnimatedLayers removeObject:stale];
        }
        os_unfair_lock_unlock(&pt_motionLock);
    }

    return foundActive;
}

static BOOL pt_evaluateMotionDemandOnMainThread(NSInteger currentCeiling) {
    if (!pt_lastKnownWindowVisible) {
        atomic_store_explicit(&pt_cachedMotionDemand, false, memory_order_release);
        return NO;
    }

    CFTimeInterval now = CACurrentMediaTime();
    BOOL highFPSVideo = atomic_load_explicit(&pt_cachedHighFPSVideo, memory_order_acquire);
    BOOL caAnimActive = pt_hasActiveSpatialCAAnimationOnMainThread(now);

    BOOL throttled = (currentCeiling > 0 && currentCeiling < 45);
    CFTimeInterval cutoff1s = now - kPTAdaptiveMotionWindowSeconds;
    CFTimeInterval cutoffDeep = now - 2.2;
    if (throttled && pt_ceilingEffectiveSince > 0.0) {
        if (cutoff1s < pt_ceilingEffectiveSince) {
            cutoff1s = pt_ceilingEffectiveSince;
        }
        if (cutoffDeep < pt_ceilingEffectiveSince) {
            cutoffDeep = pt_ceilingEffectiveSince;
        }
    }

    os_unfair_lock_lock(&pt_motionLock);
    NSUInteger ui1s = pt_countRecentRingEvents(pt_motionFrameTimes, kPTMotionRingCapacity, cutoff1s);
    NSUInteger uiDeepWindow = pt_countRecentRingEvents(pt_motionFrameTimes, kPTMotionRingCapacity, cutoffDeep);
    NSUInteger metal1s = pt_countRecentRingEvents(pt_metalDrawableTimes, kPTMotionRingCapacity, cutoff1s);
    os_unfair_lock_unlock(&pt_motionLock);

    BOOL rawDemand = (highFPSVideo || caAnimActive);
    if (!rawDemand) {
        if (metal1s >= (NSUInteger)kPTHighFPSVideoThreshold) {
            rawDemand = YES;
        } else if (!throttled) {
            rawDemand = (ui1s >= 14);
        } else if (currentCeiling >= 25) {
            rawDemand = (ui1s >= 12) || (metal1s >= 27);
        } else if (currentCeiling >= 8) {
            rawDemand = (ui1s >= 4) || (metal1s >= 8);
        } else {
            rawDemand = (uiDeepWindow >= 2) || (metal1s >= 2);
        }
    }

    BOOL demand = rawDemand;
    if (rawDemand) {
        pt_lastMotionActiveTime = now;
    } else if (!throttled && pt_lastMotionActiveTime > 0.0 && (now - pt_lastMotionActiveTime) < kPTAdaptiveMotionHoldGraceSeconds) {
        demand = YES;
    }

    atomic_store_explicit(&pt_cachedMotionDemand, demand, memory_order_release);
    return demand;
}

static _Atomic NSInteger pt_lastEvaluatedAdaptiveCeiling = kPTAdaptiveActiveFPS;

static NSInteger pt_activeFPSCeiling(void) {
    BOOL mediaPlaying = pt_isAnyMediaActivelyPlaying();
    BOOL lowFPS = atomic_load_explicit(&pt_occludedLowFPSActive, memory_order_acquire);
    if (lowFPS && !mediaPlaying) {
        if (pt_configuredFrameRateCap == -1) {
            atomic_store_explicit(&pt_adaptiveMotionHold, false, memory_order_release);
            return kPTOccludedAdaptiveDeepFPS;
        }
        if (pt_powerSavingMode) {
            if (pt_configuredFrameRateCap > 0) {
                return MIN(pt_configuredFrameRateCap, kPTOccludedLowFPS);
            }
            return kPTOccludedLowFPS;
        }
    }

    if (pt_configuredFrameRateCap == -1) {
        PTAdaptiveFPSStage stage = (PTAdaptiveFPSStage)atomic_load_explicit(&pt_adaptiveStage, memory_order_acquire);
        if (stage == PTAdaptiveFPSStageActive) {
            NSInteger prev = atomic_exchange_explicit(&pt_lastEvaluatedAdaptiveCeiling, kPTAdaptiveActiveFPS, memory_order_acq_rel);
            if ([NSThread isMainThread] && prev != kPTAdaptiveActiveFPS) {
                pt_ceilingEffectiveSince = CACurrentMediaTime();
            }
            atomic_store_explicit(&pt_adaptiveMotionHold, false, memory_order_release);
            return kPTAdaptiveActiveFPS;
        }

        NSInteger prevCeiling = atomic_load_explicit(&pt_lastEvaluatedAdaptiveCeiling, memory_order_acquire);
        BOOL motionDemand = [NSThread isMainThread]
            ? pt_evaluateMotionDemandOnMainThread(prevCeiling)
            : atomic_load_explicit(&pt_cachedMotionDemand, memory_order_acquire);

        NSInteger ceiling = kPTAdaptiveActiveFPS;
        if (motionDemand) {
            atomic_store_explicit(&pt_adaptiveMotionHold, true, memory_order_release);
            ceiling = kPTAdaptiveActiveFPS;
        } else {
            atomic_store_explicit(&pt_adaptiveMotionHold, false, memory_order_release);
            switch (stage) {
                case PTAdaptiveFPSStageActive:
                    ceiling = kPTAdaptiveActiveFPS;
                    break;
                case PTAdaptiveFPSStageIdleLight:
                    ceiling = kPTAdaptiveIdleLightFPS;
                    break;
                case PTAdaptiveFPSStageIdleDeep:
                    ceiling = kPTAdaptiveIdleDeepFPS;
                    break;
            }
            if (mediaPlaying) {
                ceiling = MAX(ceiling, kPTAdaptiveMediaFloorFPS);
            }
        }
        NSInteger oldCeiling = atomic_exchange_explicit(&pt_lastEvaluatedAdaptiveCeiling, ceiling, memory_order_acq_rel);
        if ([NSThread isMainThread] && oldCeiling != ceiling) {
            pt_ceilingEffectiveSince = CACurrentMediaTime();
        }
        return ceiling;
    }

    return (pt_configuredFrameRateCap > 0) ? pt_configuredFrameRateCap : 0;
}

static CAFrameRateRange pt_clampFrameRateRange(CAFrameRateRange range, NSInteger ceiling) {
    if (ceiling <= 0) {
        return range;
    }
    float cap = (float)ceiling;
    if (range.minimum <= 0.0f && range.maximum <= 0.0f && range.preferred <= 0.0f) {
        return CAFrameRateRangeMake(cap, cap, cap);
    }
    float maxFPS = (range.maximum > 0.0f) ? MIN(range.maximum, cap) : cap;
    float minFPS = (range.minimum > 0.0f) ? MIN(range.minimum, maxFPS) : 0.0f;
    float prefFPS = (range.preferred > 0.0f) ? MIN(range.preferred, maxFPS) : maxFPS;
    if (prefFPS < minFPS) {
        prefFPS = minFPS;
    }
    return CAFrameRateRangeMake(minFPS, maxFPS, prefFPS);
}

static NSInteger pt_clampDisplayLinkFPS(NSInteger fps, NSInteger ceiling) {
    if (ceiling <= 0) {
        return fps;
    }
    if (fps <= 0) {
        return ceiling;
    }
    return MIN(fps, ceiling);
}

static NSInteger pt_clampDisplayLinkInterval(NSInteger interval, NSInteger ceiling) {
    NSInteger baseInterval = MAX(1, interval);
    if (ceiling <= 0) {
        return interval;
    }
    NSInteger minInterval = MAX(1, (NSInteger)ceil(60.0 / (double)ceiling));
    return MAX(baseInterval, minInterval);
}

static NSInteger pt_clampMTKViewFPS(NSInteger fps, NSInteger ceiling) {
    if (ceiling <= 0 || fps <= 0) {
        return fps;
    }
    return MIN(fps, ceiling);
}

static void pt_registerDisplayLink(CADisplayLink * _Nullable link) {
    if (!link) {
        return;
    }
    os_unfair_lock_lock(&pt_displayLinkLock);
    if (!pt_trackedDisplayLinks) {
        pt_trackedDisplayLinks = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedDisplayLinks addObject:link];
    os_unfair_lock_unlock(&pt_displayLinkLock);
}

static PTDisplayLinkRateState *pt_stateForDisplayLink(CADisplayLink *link) {
    @synchronized (link) {
        PTDisplayLinkRateState *state = objc_getAssociatedObject(link, kPTDisplayLinkRateStateKey);
        if (!state) {
            state = [[PTDisplayLinkRateState alloc] init];
            state.mode = PTDisplayLinkRateModeDefault;
            state.requestedRange = CAFrameRateRangeDefault;
            state.requestedFPS = 0;
            state.requestedInterval = 1;
            objc_setAssociatedObject(link, kPTDisplayLinkRateStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return state;
    }
}

static void pt_registerMTKView(MTKView * _Nullable view) {
    if (!view) {
        return;
    }
    os_unfair_lock_lock(&pt_mtkViewLock);
    if (!pt_trackedMTKViews) {
        pt_trackedMTKViews = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedMTKViews addObject:view];
    os_unfair_lock_unlock(&pt_mtkViewLock);
}

@interface CADisplayLink (PTEfficiencyHooks)
+ (CADisplayLink *)pt_eff_displayLinkWithTarget:(id)target selector:(SEL)sel;
- (CAFrameRateRange)pt_eff_preferredFrameRateRange;
- (void)pt_eff_setPreferredFrameRateRange:(CAFrameRateRange)range;
- (void)pt_eff_setPreferredFramesPerSecond:(NSInteger)fps;
- (void)pt_eff_setFrameInterval:(NSInteger)interval;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@implementation CADisplayLink (PTEfficiencyHooks)

+ (CADisplayLink *)pt_eff_displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = [self pt_eff_displayLinkWithTarget:target selector:sel];
    if (link) {
        pt_registerDisplayLink(link);
        NSInteger ceiling = pt_activeFPSCeiling();
        if (ceiling > 0) {
            [link pt_eff_setPreferredFrameRateRange:pt_clampFrameRateRange(CAFrameRateRangeDefault, ceiling)];
        }
    }
    return link;
}

- (CAFrameRateRange)pt_eff_preferredFrameRateRange {
    pt_registerDisplayLink(self);
    CAFrameRateRange current = [self pt_eff_preferredFrameRateRange];
    return pt_clampFrameRateRange(current, pt_activeFPSCeiling());
}

- (void)pt_eff_setPreferredFrameRateRange:(CAFrameRateRange)range {
    pt_registerDisplayLink(self);
    PTDisplayLinkRateState *state = pt_stateForDisplayLink(self);
    @synchronized (self) {
        state.mode = PTDisplayLinkRateModeRange;
        state.requestedRange = range;
    }
    CAFrameRateRange clamped = pt_clampFrameRateRange(range, pt_activeFPSCeiling());
    [self pt_eff_setPreferredFrameRateRange:clamped];
}

- (void)pt_eff_setPreferredFramesPerSecond:(NSInteger)fps {
    pt_registerDisplayLink(self);
    PTDisplayLinkRateState *state = pt_stateForDisplayLink(self);
    @synchronized (self) {
        state.mode = PTDisplayLinkRateModeFPS;
        state.requestedFPS = fps;
    }
    NSInteger clamped = pt_clampDisplayLinkFPS(fps, pt_activeFPSCeiling());
    [self pt_eff_setPreferredFramesPerSecond:clamped];
}

- (void)pt_eff_setFrameInterval:(NSInteger)interval {
    pt_registerDisplayLink(self);
    PTDisplayLinkRateState *state = pt_stateForDisplayLink(self);
    @synchronized (self) {
        state.mode = PTDisplayLinkRateModeInterval;
        state.requestedInterval = interval;
    }
    NSInteger clamped = pt_clampDisplayLinkInterval(interval, pt_activeFPSCeiling());
    [self pt_eff_setFrameInterval:clamped];
}

@end

#pragma clang diagnostic pop

static BOOL pt_shouldTrackMTKView(void) {
    return pt_memorySavingMode || pt_metalMemorySaver || pt_powerSavingMode || pt_configuredFrameRateCap != 0;
}

static BOOL pt_shouldClampFPS(void) {
    return pt_powerSavingMode || pt_configuredFrameRateCap != 0;
}

@interface MTKView (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device __attribute__((objc_method_family(init)));
- (nullable instancetype)pt_eff_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
- (void)pt_eff_mtk_setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond;
@end

@implementation MTKView (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device {
    MTKView *view = [self pt_eff_initWithFrame:frameRect device:device];
    if (view && pt_shouldTrackMTKView()) {
        pt_registerMTKView(view);
        if (pt_shouldClampFPS()) {
            NSInteger initialFPS = view.preferredFramesPerSecond;
            objc_setAssociatedObject(view, kPTMTKViewRequestedFPSKey, @(initialFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSInteger ceiling = pt_activeFPSCeiling();
            if (ceiling > 0) {
                [view pt_eff_mtk_setPreferredFramesPerSecond:pt_clampMTKViewFPS(initialFPS, ceiling)];
            }
        }
    }
    return view;
}

- (nullable instancetype)pt_eff_initWithCoder:(NSCoder *)coder {
    MTKView *view = [self pt_eff_initWithCoder:coder];
    if (view && pt_shouldTrackMTKView()) {
        pt_registerMTKView(view);
        if (pt_shouldClampFPS()) {
            NSInteger initialFPS = view.preferredFramesPerSecond;
            objc_setAssociatedObject(view, kPTMTKViewRequestedFPSKey, @(initialFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSInteger ceiling = pt_activeFPSCeiling();
            if (ceiling > 0) {
                [view pt_eff_mtk_setPreferredFramesPerSecond:pt_clampMTKViewFPS(initialFPS, ceiling)];
            }
        }
    }
    return view;
}

- (void)pt_eff_mtk_setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond {
    pt_registerMTKView(self);
    objc_setAssociatedObject(self, kPTMTKViewRequestedFPSKey, @(preferredFramesPerSecond), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSInteger clamped = pt_clampMTKViewFPS(preferredFramesPerSecond, pt_activeFPSCeiling());
    [self pt_eff_mtk_setPreferredFramesPerSecond:clamped];
}

@end

static void pt_reapplyActiveFPSCeilingToAllTracked(void) {
    NSInteger ceiling = pt_activeFPSCeiling();

    os_unfair_lock_lock(&pt_displayLinkLock);
    NSArray<CADisplayLink *> *links = [pt_trackedDisplayLinks allObjects];
    os_unfair_lock_unlock(&pt_displayLinkLock);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (CADisplayLink *link in links) {
        PTDisplayLinkRateMode mode = PTDisplayLinkRateModeDefault;
        CAFrameRateRange reqRange = CAFrameRateRangeDefault;
        NSInteger reqFPS = 0;
        NSInteger reqInterval = 1;
        @synchronized (link) {
            PTDisplayLinkRateState *state = objc_getAssociatedObject(link, kPTDisplayLinkRateStateKey);
            if (state) {
                mode = state.mode;
                reqRange = state.requestedRange;
                reqFPS = state.requestedFPS;
                reqInterval = state.requestedInterval;
            }
        }
        switch (mode) {
            case PTDisplayLinkRateModeRange:
                [link pt_eff_setPreferredFrameRateRange:pt_clampFrameRateRange(reqRange, ceiling)];
                break;
            case PTDisplayLinkRateModeFPS:
                [link pt_eff_setPreferredFramesPerSecond:pt_clampDisplayLinkFPS(reqFPS, ceiling)];
                break;
            case PTDisplayLinkRateModeInterval:
                [link pt_eff_setFrameInterval:pt_clampDisplayLinkInterval(reqInterval, ceiling)];
                break;
            case PTDisplayLinkRateModeDefault:
                if (ceiling > 0) {
                    [link pt_eff_setPreferredFrameRateRange:pt_clampFrameRateRange(CAFrameRateRangeDefault, ceiling)];
                } else {
                    [link pt_eff_setPreferredFrameRateRange:CAFrameRateRangeDefault];
                }
                break;
        }
    }
#pragma clang diagnostic pop

    os_unfair_lock_lock(&pt_mtkViewLock);
    NSArray<MTKView *> *views = [pt_trackedMTKViews allObjects];
    os_unfair_lock_unlock(&pt_mtkViewLock);

    for (MTKView *view in views) {
        NSNumber *savedNum = objc_getAssociatedObject(view, kPTMTKViewRequestedFPSKey);
        NSInteger reqFPS = savedNum ? [savedNum integerValue] : view.preferredFramesPerSecond;
        if (!savedNum) {
            objc_setAssociatedObject(view, kPTMTKViewRequestedFPSKey, @(reqFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [view pt_eff_mtk_setPreferredFramesPerSecond:pt_clampMTKViewFPS(reqFPS, ceiling)];
    }

    pt_notifyOverlayCeilingDidChange(ceiling);
}

static void pt_installFrameRateHooks(void) {
    Class displayLinkCls = [CADisplayLink class];
    pt_swizzleClassMethod(displayLinkCls,
                          @selector(displayLinkWithTarget:selector:),
                          @selector(pt_eff_displayLinkWithTarget:selector:));
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(preferredFrameRateRange),
                             @selector(pt_eff_preferredFrameRateRange));
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(setPreferredFrameRateRange:),
                             @selector(pt_eff_setPreferredFrameRateRange:));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(setPreferredFramesPerSecond:),
                             @selector(pt_eff_setPreferredFramesPerSecond:));
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(setFrameInterval:),
                             @selector(pt_eff_setFrameInterval:));
#pragma clang diagnostic pop

    pt_swizzleInstanceMethod([MTKView class],
                             @selector(setPreferredFramesPerSecond:),
                             @selector(pt_eff_mtk_setPreferredFramesPerSecond:));
}

static void pt_installMTKViewInitHooks(void) {
    Class mtkViewCls = [MTKView class];
    pt_swizzleInstanceMethod(mtkViewCls,
                             @selector(initWithFrame:device:),
                             @selector(pt_eff_initWithFrame:device:));
    pt_swizzleInstanceMethod(mtkViewCls,
                             @selector(initWithCoder:),
                             @selector(pt_eff_initWithCoder:));
}

#pragma mark - Adaptive FPS (Input Wake, Idle Timers & AVPlayer Tracking)

static NSTimeInterval pt_parseAdaptiveDelayEnv(NSString *key, NSTimeInterval defaultVal, NSTimeInterval minVal) {
    NSString *raw = [[NSProcessInfo processInfo] environment][key];
    if (raw.length == 0) {
        return defaultVal;
    }
    char *endPtr = NULL;
    double parsed = strtod(raw.UTF8String, &endPtr);
    if (endPtr == raw.UTF8String || !isfinite(parsed) || parsed <= 0.0) {
        return defaultVal;
    }
    return MAX(minVal, parsed);
}

static void pt_cancelAdaptiveMotionHoldTimer(void) {
    if (pt_pendingMotionHoldTimer) {
        dispatch_block_cancel(pt_pendingMotionHoldTimer);
        pt_pendingMotionHoldTimer = nil;
    }
}

static void pt_scheduleAdaptiveMotionHoldTimer(void);

static void pt_refreshAdaptiveCeilingOnMainThread(BOOL forceNotifyOverlay) {
    if (pt_configuredFrameRateCap != -1) {
        return;
    }
    NSInteger beforeCeiling = atomic_load_explicit(&pt_lastEvaluatedAdaptiveCeiling, memory_order_acquire);
    BOOL beforeHold = atomic_load_explicit(&pt_adaptiveMotionHold, memory_order_acquire);

    NSInteger afterCeiling = pt_activeFPSCeiling();
    BOOL afterHold = atomic_load_explicit(&pt_adaptiveMotionHold, memory_order_acquire);
    BOOL mediaActive = atomic_load_explicit(&pt_cachedMediaPlaying, memory_order_acquire);

    if (afterHold || (mediaActive && afterCeiling >= kPTAdaptiveMediaFloorFPS && afterCeiling < kPTAdaptiveActiveFPS)) {
        pt_scheduleAdaptiveMotionHoldTimer();
    } else {
        pt_cancelAdaptiveMotionHoldTimer();
    }

    if (forceNotifyOverlay || beforeCeiling != afterCeiling || beforeHold != afterHold) {
        pt_reapplyActiveFPSCeilingToAllTracked();
    }
}

static void pt_scheduleAdaptiveMotionHoldTimer(void) {
    if (pt_configuredFrameRateCap != -1 || pt_pendingMotionHoldTimer) {
        return;
    }
    dispatch_block_t work = dispatch_block_create(0, ^{
        pt_pendingMotionHoldTimer = nil;
        pt_refreshAdaptiveCeilingOnMainThread(NO);
    });
    pt_pendingMotionHoldTimer = work;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPTAdaptiveMotionReevalIntervalSeconds * (double)NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   work);
}

static void pt_scheduleAdaptiveMotionReevalIfNeeded(void) {
    if (pt_configuredFrameRateCap != -1) {
        return;
    }
    if (atomic_load_explicit(&pt_adaptiveStage, memory_order_acquire) == PTAdaptiveFPSStageActive) {
        return;
    }
    if (atomic_load_explicit(&pt_adaptiveMotionHold, memory_order_acquire)) {
        return;
    }
    if (atomic_exchange_explicit(&pt_pendingMotionReevalScheduled, true, memory_order_acq_rel)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(&pt_pendingMotionReevalScheduled, false, memory_order_release);
        pt_refreshAdaptiveCeilingOnMainThread(NO);
    });
}

static inline BOOL pt_shouldRecordLayerMotion(CALayer *layer) {
    if (pt_tlsSuppressMotionRecording || !pt_lastKnownWindowVisible) {
        return NO;
    }
    if (pt_configuredFrameRateCap != -1 || ![NSThread isMainThread]) {
        return NO;
    }
    if (!layer || layer == pt_overlayPillLayer || layer.superlayer == pt_overlayPillLayer) {
        return NO;
    }
    if (layer.isHidden || layer.opacity <= 0.01f || !layer.superlayer) {
        return NO;
    }
    if ((pt_avPlayerLayerClass && [layer isKindOfClass:pt_avPlayerLayerClass]) ||
        (pt_avSampleBufferDisplayLayerClass && [layer isKindOfClass:pt_avSampleBufferDisplayLayerClass]) ||
        (pt_caMetalLayerClass && [layer isKindOfClass:pt_caMetalLayerClass])) {
        return NO;
    }
    return YES;
}

static inline void pt_recordVisualMotionTickForLayer(CALayer *layer) {
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t bucket = (uint64_t)(now * 70.0);
    if (atomic_load_explicit(&pt_lastMotionBucket, memory_order_relaxed) == bucket) {
        return;
    }
    if (!pt_isLayerTreeVisible(layer)) {
        return;
    }
    if (atomic_exchange_explicit(&pt_lastMotionBucket, bucket, memory_order_acq_rel) != bucket) {
        pt_recordRingTimestamp(pt_motionFrameTimes, &pt_motionFrameHead, now);
        pt_scheduleAdaptiveMotionReevalIfNeeded();
    }
}

static BOOL pt_isSpatialCAAnimationOnLayer(CALayer *layer, CAAnimation *anim) {
    if (!anim) {
        return NO;
    }
    BOOL highFPSHint = (anim.preferredFrameRateRange.preferred >= 45.0f ||
                        anim.preferredFrameRateRange.maximum >= 45.0f);
    CGSize sz = layer.bounds.size;
    BOOL tinyLayer = (sz.width <= 48.0 && sz.height <= 48.0);
    if (anim.repeatCount >= 1000.0f && tinyLayer && !highFPSHint) {
        return NO;
    }
    if (anim.duration < 0.08 && !highFPSHint) {
        return NO;
    }
    if ([anim isKindOfClass:[CAPropertyAnimation class]]) {
        NSString *keyPath = ((CAPropertyAnimation *)anim).keyPath;
        if (!highFPSHint &&
            ([keyPath isEqualToString:@"opacity"] ||
             [keyPath isEqualToString:@"backgroundColor"] ||
             [keyPath isEqualToString:@"borderColor"] ||
             [keyPath isEqualToString:@"shadowOpacity"] ||
             [keyPath isEqualToString:@"shadowColor"] ||
             [keyPath isEqualToString:@"strokeEnd"] ||
             [keyPath isEqualToString:@"strokeStart"])) {
            return NO;
        }
        return (sz.width >= 16.0 && sz.height >= 12.0) || highFPSHint;
    }
    return (sz.width >= 20.0 && sz.height >= 14.0) || highFPSHint;
}

@interface CALayer (PTAdaptiveMotionHooks)
- (void)pt_eff_layerSetPosition:(CGPoint)position;
- (void)pt_eff_layerSetBounds:(CGRect)bounds;
- (void)pt_eff_layerSetTransform:(CATransform3D)transform;
- (void)pt_eff_layerSetNeedsDisplay;
- (void)pt_eff_layerSetNeedsDisplayInRect:(CGRect)r;
- (void)pt_eff_layerSetContents:(nullable id)contents;
- (void)pt_eff_layerAddAnimation:(CAAnimation *)anim forKey:(nullable NSString *)key;
@end

@implementation CALayer (PTAdaptiveMotionHooks)

- (void)pt_eff_layerSetPosition:(CGPoint)position {
    BOOL record = NO;
    if (pt_shouldRecordLayerMotion(self)) {
        CGSize sz = self.bounds.size;
        if (sz.width >= 16.0 && sz.height >= 12.0) {
            CGPoint oldPos = self.position;
            double delta = fabs((double)(position.x - oldPos.x)) + fabs((double)(position.y - oldPos.y));
            if (delta >= 0.4) {
                record = YES;
            }
        }
    }
    [self pt_eff_layerSetPosition:position];
    if (record) {
        pt_recordVisualMotionTickForLayer(self);
    }
}

- (void)pt_eff_layerSetBounds:(CGRect)bounds {
    BOOL record = NO;
    if (pt_shouldRecordLayerMotion(self)) {
        if (bounds.size.width >= 16.0 && bounds.size.height >= 12.0) {
            CGRect oldBounds = self.bounds;
            double delta = fabs((double)(bounds.origin.x - oldBounds.origin.x))
                         + fabs((double)(bounds.origin.y - oldBounds.origin.y))
                         + fabs((double)(bounds.size.width - oldBounds.size.width))
                         + fabs((double)(bounds.size.height - oldBounds.size.height));
            if (delta >= 0.5) {
                record = YES;
            }
        }
    }
    [self pt_eff_layerSetBounds:bounds];
    if (record) {
        pt_recordVisualMotionTickForLayer(self);
    }
}

- (void)pt_eff_layerSetTransform:(CATransform3D)transform {
    BOOL record = NO;
    if (pt_shouldRecordLayerMotion(self)) {
        CGSize sz = self.bounds.size;
        if (sz.width >= 16.0 && sz.height >= 12.0 && !CATransform3DEqualToTransform(self.transform, transform)) {
            record = YES;
        }
    }
    [self pt_eff_layerSetTransform:transform];
    if (record) {
        pt_recordVisualMotionTickForLayer(self);
    }
}

- (void)pt_eff_layerSetNeedsDisplay {
    BOOL record = NO;
    if (pt_shouldRecordLayerMotion(self)) {
        CGSize sz = self.bounds.size;
        if (sz.width >= 100.0 && sz.height >= 60.0) {
            record = YES;
        }
    }
    [self pt_eff_layerSetNeedsDisplay];
    if (record) {
        pt_recordVisualMotionTickForLayer(self);
    }
}

- (void)pt_eff_layerSetNeedsDisplayInRect:(CGRect)r {
    BOOL record = NO;
    if (pt_shouldRecordLayerMotion(self)) {
        CGSize sz = self.bounds.size;
        if (sz.width >= 100.0 && sz.height >= 60.0 && r.size.width >= 16.0 && r.size.height >= 12.0) {
            record = YES;
        }
    }
    [self pt_eff_layerSetNeedsDisplayInRect:r];
    if (record) {
        pt_recordVisualMotionTickForLayer(self);
    }
}

- (void)pt_eff_layerSetContents:(nullable id)contents {
    BOOL record = NO;
    if (contents && pt_shouldRecordLayerMotion(self)) {
        CGSize sz = self.bounds.size;
        if (sz.width >= 100.0 && sz.height >= 60.0) {
            record = YES;
        }
    }
    [self pt_eff_layerSetContents:contents];
    if (record) {
        pt_recordVisualMotionTickForLayer(self);
    }
}

- (void)pt_eff_layerAddAnimation:(CAAnimation *)anim forKey:(nullable NSString *)key {
    [self pt_eff_layerAddAnimation:anim forKey:key];
    if (pt_shouldRecordLayerMotion(self) && pt_isSpatialCAAnimationOnLayer(self, anim)) {
        CFTimeInterval repeat = (anim.repeatCount > 0.0f && isfinite(anim.repeatCount)) ? (CFTimeInterval)anim.repeatCount : 1.0;
        CFTimeInterval span = MIN(MAX(anim.duration * repeat, 0.25), 15.0);
        CFTimeInterval newExpiry = CACurrentMediaTime() + span;
        NSNumber *existing = objc_getAssociatedObject(self, kPTLayerAnimExpiryKey);
        if (!existing || newExpiry > [existing doubleValue]) {
            objc_setAssociatedObject(self, kPTLayerAnimExpiryKey, @(newExpiry), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        os_unfair_lock_lock(&pt_motionLock);
        if (!pt_activeAnimatedLayers) {
            pt_activeAnimatedLayers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
        }
        [pt_activeAnimatedLayers addObject:self];
        os_unfair_lock_unlock(&pt_motionLock);
        pt_scheduleAdaptiveMotionReevalIfNeeded();
    }
}

@end

static void pt_installAdaptiveMotionHooks(void) {
    pt_avPlayerLayerClass = [AVPlayerLayer class];
    pt_avSampleBufferDisplayLayerClass = [AVSampleBufferDisplayLayer class];
    pt_caMetalLayerClass = [CAMetalLayer class];

    Class layerCls = [CALayer class];
    pt_swizzleInstanceMethod(layerCls, @selector(setPosition:), @selector(pt_eff_layerSetPosition:));
    pt_swizzleInstanceMethod(layerCls, @selector(setBounds:), @selector(pt_eff_layerSetBounds:));
    pt_swizzleInstanceMethod(layerCls, @selector(setTransform:), @selector(pt_eff_layerSetTransform:));
    pt_swizzleInstanceMethod(layerCls, @selector(setNeedsDisplay), @selector(pt_eff_layerSetNeedsDisplay));
    pt_swizzleInstanceMethod(layerCls, @selector(setNeedsDisplayInRect:), @selector(pt_eff_layerSetNeedsDisplayInRect:));
    pt_swizzleInstanceMethod(layerCls, @selector(setContents:), @selector(pt_eff_layerSetContents:));
    pt_swizzleInstanceMethod(layerCls, @selector(addAnimation:forKey:), @selector(pt_eff_layerAddAnimation:forKey:));
}

static void pt_cancelAdaptiveIdleTimers(void) {
    if (pt_pendingAdaptiveLightWorkItem) {
        dispatch_block_cancel(pt_pendingAdaptiveLightWorkItem);
        pt_pendingAdaptiveLightWorkItem = nil;
    }
    if (pt_pendingAdaptiveDeepWorkItem) {
        dispatch_block_cancel(pt_pendingAdaptiveDeepWorkItem);
        pt_pendingAdaptiveDeepWorkItem = nil;
    }
}

static void pt_rescheduleAdaptiveIdleTimers(void) {
    pt_cancelAdaptiveIdleTimers();
    if (pt_configuredFrameRateCap != -1) {
        return;
    }

    dispatch_block_t lightWork = dispatch_block_create(0, ^{
        pt_pendingAdaptiveLightWorkItem = nil;
        if (atomic_load_explicit(&pt_adaptiveStage, memory_order_acquire) == PTAdaptiveFPSStageActive) {
            atomic_store_explicit(&pt_adaptiveStage, PTAdaptiveFPSStageIdleLight, memory_order_release);
            pt_refreshAdaptiveCeilingOnMainThread(YES);
        }
    });
    pt_pendingAdaptiveLightWorkItem = lightWork;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pt_adaptiveIdleLightSeconds * (double)NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   lightWork);

    NSTimeInterval deepDelay = MAX(pt_adaptiveIdleDeepSeconds, pt_adaptiveIdleLightSeconds);
    dispatch_block_t deepWork = dispatch_block_create(0, ^{
        pt_pendingAdaptiveDeepWorkItem = nil;
        PTAdaptiveFPSStage current = (PTAdaptiveFPSStage)atomic_load_explicit(&pt_adaptiveStage, memory_order_acquire);
        if (current != PTAdaptiveFPSStageIdleDeep) {
            atomic_store_explicit(&pt_adaptiveStage, PTAdaptiveFPSStageIdleDeep, memory_order_release);
            pt_refreshAdaptiveCeilingOnMainThread(NO);
        }
    });
    pt_pendingAdaptiveDeepWorkItem = deepWork;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deepDelay * (double)NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   deepWork);
}

static void pt_noteAdaptiveUserInput(void) {
    if (pt_configuredFrameRateCap != -1) {
        return;
    }
    pt_cancelAdaptiveMotionHoldTimer();
    PTAdaptiveFPSStage prev = (PTAdaptiveFPSStage)atomic_exchange_explicit(&pt_adaptiveStage,
                                                                         PTAdaptiveFPSStageActive,
                                                                         memory_order_acq_rel);
    BOOL prevMotionHold = atomic_exchange_explicit(&pt_adaptiveMotionHold, false, memory_order_acq_rel);
    CFTimeInterval now = CACurrentMediaTime();
    if (prev != PTAdaptiveFPSStageActive || prevMotionHold) {
        pt_reapplyActiveFPSCeilingToAllTracked();
        pt_lastAdaptiveScheduleTime = now;
        pt_rescheduleAdaptiveIdleTimers();
        return;
    }

    NSTimeInterval coalesce = MIN(kPTAdaptiveInputCoalesceSeconds, pt_adaptiveIdleLightSeconds * 0.5);
    if ((now - pt_lastAdaptiveScheduleTime) >= coalesce || !pt_pendingAdaptiveLightWorkItem) {
        pt_lastAdaptiveScheduleTime = now;
        pt_rescheduleAdaptiveIdleTimers();
    }
}

static void pt_registerAVPlayer(AVPlayer * _Nullable player) {
    if (!player) {
        return;
    }
    os_unfair_lock_lock(&pt_avPlayerLock);
    if (!pt_trackedAVPlayers) {
        pt_trackedAVPlayers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedAVPlayers addObject:player];
    os_unfair_lock_unlock(&pt_avPlayerLock);
}

static void pt_notifyAVPlayerStateChanged(void) {
    if (pt_configuredFrameRateCap != -1 && !pt_powerSavingMode) {
        return;
    }
    void (^refresh)(void) = ^{
        (void)pt_isAnyMediaActivelyPlaying();
        if ((pt_configuredFrameRateCap == -1 &&
             atomic_load_explicit(&pt_adaptiveStage, memory_order_acquire) != PTAdaptiveFPSStageActive) ||
            atomic_load_explicit(&pt_occludedLowFPSActive, memory_order_acquire)) {
            pt_reapplyActiveFPSCeilingToAllTracked();
        }
    };
    if ([NSThread isMainThread]) {
        refresh();
    } else {
        dispatch_async(dispatch_get_main_queue(), refresh);
    }
}

@interface AVPlayer (PTEfficiencyHooks)
- (instancetype)pt_eff_avPlayer_init __attribute__((objc_method_family(init)));
- (instancetype)pt_eff_avPlayer_initWithURL:(NSURL *)URL __attribute__((objc_method_family(init)));
- (instancetype)pt_eff_avPlayer_initWithPlayerItem:(nullable AVPlayerItem *)item __attribute__((objc_method_family(init)));
- (void)pt_eff_avPlayer_play;
- (void)pt_eff_avPlayer_playImmediatelyAtRate:(float)rate;
- (void)pt_eff_avPlayer_pause;
- (void)pt_eff_avPlayer_setRate:(float)rate;
@end

@implementation AVPlayer (PTEfficiencyHooks)

- (instancetype)pt_eff_avPlayer_init {
    AVPlayer *player = [self pt_eff_avPlayer_init];
    if (player) {
        pt_registerAVPlayer(player);
    }
    return player;
}

- (instancetype)pt_eff_avPlayer_initWithURL:(NSURL *)URL {
    AVPlayer *player = [self pt_eff_avPlayer_initWithURL:URL];
    if (player) {
        pt_registerAVPlayer(player);
    }
    return player;
}

- (instancetype)pt_eff_avPlayer_initWithPlayerItem:(nullable AVPlayerItem *)item {
    AVPlayer *player = [self pt_eff_avPlayer_initWithPlayerItem:item];
    if (player) {
        pt_registerAVPlayer(player);
    }
    return player;
}

- (void)pt_eff_avPlayer_play {
    pt_registerAVPlayer(self);
    [self pt_eff_avPlayer_play];
    pt_notifyAVPlayerStateChanged();
}

- (void)pt_eff_avPlayer_playImmediatelyAtRate:(float)rate {
    pt_registerAVPlayer(self);
    [self pt_eff_avPlayer_playImmediatelyAtRate:rate];
    pt_notifyAVPlayerStateChanged();
}

- (void)pt_eff_avPlayer_pause {
    pt_registerAVPlayer(self);
    [self pt_eff_avPlayer_pause];
    pt_notifyAVPlayerStateChanged();
}

- (void)pt_eff_avPlayer_setRate:(float)rate {
    pt_registerAVPlayer(self);
    [self pt_eff_avPlayer_setRate:rate];
    pt_notifyAVPlayerStateChanged();
}

@end

@interface UIApplication (PTEfficiencyHooks)
- (void)pt_eff_sendEvent:(UIEvent *)event;
@end

@implementation UIApplication (PTEfficiencyHooks)

- (void)pt_eff_sendEvent:(UIEvent *)event {
    UIEventType type = event.type;
    if (type == UIEventTypeTouches ||
        type == UIEventTypePresses ||
        type == UIEventTypeScroll ||
        type == UIEventTypeHover) {
        pt_noteAdaptiveUserInput();
    }
    [self pt_eff_sendEvent:event];
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface AVSampleBufferDisplayLayer (PTAdaptiveMediaHooks)
- (void)pt_eff_sbDisplayLayerEnqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@implementation AVSampleBufferDisplayLayer (PTAdaptiveMediaHooks)

- (void)pt_eff_sbDisplayLayerEnqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self pt_eff_sbDisplayLayerEnqueueSampleBuffer:sampleBuffer];
    CFTimeInterval now = CACurrentMediaTime();
    atomic_store_explicit(&pt_lastSampleBufferEnqueueTime, now, memory_order_release);
    pt_recordRingTimestamp(pt_sampleBufferTimes, &pt_sampleBufferHead, now);
    pt_scheduleAdaptiveMotionReevalIfNeeded();
}

@end

#pragma clang diagnostic pop

static void (*pt_origVideoRendererEnqueueSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;

static void pt_hook_videoRendererEnqueueSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    if (pt_origVideoRendererEnqueueSampleBuffer) {
        pt_origVideoRendererEnqueueSampleBuffer(self, _cmd, sampleBuffer);
    }
    CFTimeInterval now = CACurrentMediaTime();
    atomic_store_explicit(&pt_lastSampleBufferEnqueueTime, now, memory_order_release);
    pt_recordRingTimestamp(pt_sampleBufferTimes, &pt_sampleBufferHead, now);
    pt_scheduleAdaptiveMotionReevalIfNeeded();
}

static void pt_installAVPlayerTrackingHooks(void) {
    Class playerCls = [AVPlayer class];
    pt_swizzleInstanceMethod(playerCls, @selector(init), @selector(pt_eff_avPlayer_init));
    pt_swizzleInstanceMethod(playerCls, @selector(initWithURL:), @selector(pt_eff_avPlayer_initWithURL:));
    pt_swizzleInstanceMethod(playerCls, @selector(initWithPlayerItem:), @selector(pt_eff_avPlayer_initWithPlayerItem:));
    pt_swizzleInstanceMethod(playerCls, @selector(play), @selector(pt_eff_avPlayer_play));
    pt_swizzleInstanceMethod(playerCls, @selector(playImmediatelyAtRate:), @selector(pt_eff_avPlayer_playImmediatelyAtRate:));
    pt_swizzleInstanceMethod(playerCls, @selector(pause), @selector(pt_eff_avPlayer_pause));
    pt_swizzleInstanceMethod(playerCls, @selector(setRate:), @selector(pt_eff_avPlayer_setRate:));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Class sbDisplayCls = NSClassFromString(@"AVSampleBufferDisplayLayer");
    if (sbDisplayCls && [sbDisplayCls instancesRespondToSelector:@selector(enqueueSampleBuffer:)]) {
        pt_swizzleInstanceMethod(sbDisplayCls,
                                 @selector(enqueueSampleBuffer:),
                                 @selector(pt_eff_sbDisplayLayerEnqueueSampleBuffer:));
    }
#pragma clang diagnostic pop

    Class videoRendererCls = NSClassFromString(@"AVSampleBufferVideoRenderer");
    SEL enqueueSel = NSSelectorFromString(@"enqueueSampleBuffer:");
    Method enqueueMethod = videoRendererCls ? class_getInstanceMethod(videoRendererCls, enqueueSel) : NULL;
    if (enqueueMethod) {
        IMP origImp = method_getImplementation(enqueueMethod);
        if (origImp != (IMP)pt_hook_videoRendererEnqueueSampleBuffer) {
            pt_origVideoRendererEnqueueSampleBuffer = (void (*)(id, SEL, CMSampleBufferRef))origImp;
            class_replaceMethod(videoRendererCls,
                                enqueueSel,
                                (IMP)pt_hook_videoRendererEnqueueSampleBuffer,
                                method_getTypeEncoding(enqueueMethod));
        }
    }
}

static void pt_installAdaptiveFPSHooks(void) {
    pt_adaptiveIdleLightSeconds = pt_parseAdaptiveDelayEnv(@"PLAYTOOLS_ADAPTIVE_IDLE_LIGHT_SECONDS",
                                                           kPTDefaultAdaptiveIdleLightSeconds,
                                                           0.2);
    pt_adaptiveIdleDeepSeconds = pt_parseAdaptiveDelayEnv(@"PLAYTOOLS_ADAPTIVE_IDLE_DEEP_SECONDS",
                                                          kPTDefaultAdaptiveIdleDeepSeconds,
                                                          0.4);
    if (pt_adaptiveIdleDeepSeconds < pt_adaptiveIdleLightSeconds) {
        pt_adaptiveIdleDeepSeconds = pt_adaptiveIdleLightSeconds;
    }

    pt_installAdaptiveMotionHooks();

    pt_swizzleInstanceMethod([UIApplication class],
                             @selector(sendEvent:),
                             @selector(pt_eff_sendEvent:));

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        pt_noteAdaptiveUserInput();
    }];

    atomic_store_explicit(&pt_adaptiveStage, PTAdaptiveFPSStageActive, memory_order_release);
    pt_lastAdaptiveScheduleTime = CACurrentMediaTime();
    dispatch_async(dispatch_get_main_queue(), ^{
        pt_rescheduleAdaptiveIdleTimers();
    });
}

#pragma mark - WKWebView Tracking & Media Suspension

static void pt_registerWKWebView(WKWebView * _Nullable webView) {
    if (!webView) {
        return;
    }
    os_unfair_lock_lock(&pt_webViewLock);
    if (!pt_trackedWKWebViews) {
        pt_trackedWKWebViews = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedWKWebViews addObject:webView];
    os_unfair_lock_unlock(&pt_webViewLock);
}

static void pt_updateTrackedWKWebViewsMediaSuspended(BOOL suspended) {
    os_unfair_lock_lock(&pt_webViewLock);
    NSArray<WKWebView *> *webViews = [pt_trackedWKWebViews allObjects];
    os_unfair_lock_unlock(&pt_webViewLock);

    for (WKWebView *webView in webViews) {
        BOOL wasSuspended = [objc_getAssociatedObject(webView, kPTWebViewMediaSuspendedKey) boolValue];
        if (wasSuspended == suspended) {
            continue;
        }
        objc_setAssociatedObject(webView,
                                 kPTWebViewMediaSuspendedKey,
                                 suspended ? @YES : nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([webView respondsToSelector:@selector(setAllMediaPlaybackSuspended:completionHandler:)]) {
            [webView setAllMediaPlaybackSuspended:suspended completionHandler:nil];
        }
    }
}

@interface WKWebView (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithFrame:(CGRect)frame
                       configuration:(WKWebViewConfiguration *)configuration __attribute__((objc_method_family(init)));
@end

@implementation WKWebView (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebView *webView = [self pt_eff_initWithFrame:frame configuration:configuration];
    if (webView) {
        pt_registerWKWebView(webView);
        if (!pt_lastKnownWindowVisible) {
            objc_setAssociatedObject(webView,
                                     kPTWebViewMediaSuspendedKey,
                                     @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if ([webView respondsToSelector:@selector(setAllMediaPlaybackSuspended:completionHandler:)]) {
                [webView setAllMediaPlaybackSuspended:YES completionHandler:nil];
            }
        }
    }
    return webView;
}

@end

static void pt_installWKWebViewHooks(void) {
    pt_swizzleInstanceMethod([WKWebView class],
                             @selector(initWithFrame:configuration:),
                             @selector(pt_eff_initWithFrame:configuration:));
}

#pragma mark - AVPlayerItem Saver

static CGSize pt_maxAVResolution(void) {
    return pt_powerSavingMode ? CGSizeMake(1280.0, 720.0) : CGSizeMake(1920.0, 1080.0);
}

static CGSize pt_clampAVResolution(CGSize size) {
    CGSize cap = pt_maxAVResolution();
    if (size.width <= 0.0 || size.height <= 0.0) {
        return cap;
    }
    return CGSizeMake(MIN(size.width, cap.width), MIN(size.height, cap.height));
}

static double pt_clampAVPeakBitRate(double bitRate) {
    if (bitRate <= 0.0) {
        return kPTMaxAVPeakBitRate;
    }
    return MIN(bitRate, kPTMaxAVPeakBitRate);
}

static NSTimeInterval pt_clampAVForwardBufferDuration(NSTimeInterval duration) {
    if (duration <= 0.0) {
        return kPTMaxAVForwardBufferDuration;
    }
    return MIN(duration, kPTMaxAVForwardBufferDuration);
}

@interface AVPlayerItem (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithAsset:(AVAsset *)asset
        automaticallyLoadedAssetKeys:(nullable NSArray<NSString *> *)automaticallyLoadedAssetKeys __attribute__((objc_method_family(init)));
- (void)pt_eff_setPreferredMaximumResolution:(CGSize)preferredMaximumResolution;
- (void)pt_eff_setPreferredPeakBitRate:(double)preferredPeakBitRate;
- (void)pt_eff_setPreferredForwardBufferDuration:(NSTimeInterval)preferredForwardBufferDuration;
- (void)pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)canUse;
@end

@implementation AVPlayerItem (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithAsset:(AVAsset *)asset
        automaticallyLoadedAssetKeys:(nullable NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    AVPlayerItem *item = [self pt_eff_initWithAsset:asset
                       automaticallyLoadedAssetKeys:automaticallyLoadedAssetKeys];
    if (item) {
        [item pt_eff_setPreferredMaximumResolution:pt_maxAVResolution()];
        [item pt_eff_setPreferredPeakBitRate:kPTMaxAVPeakBitRate];
        [item pt_eff_setPreferredForwardBufferDuration:kPTMaxAVForwardBufferDuration];
        [item pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:NO];
    }
    return item;
}

- (void)pt_eff_setPreferredMaximumResolution:(CGSize)preferredMaximumResolution {
    [self pt_eff_setPreferredMaximumResolution:pt_clampAVResolution(preferredMaximumResolution)];
}

- (void)pt_eff_setPreferredPeakBitRate:(double)preferredPeakBitRate {
    [self pt_eff_setPreferredPeakBitRate:pt_clampAVPeakBitRate(preferredPeakBitRate)];
}

- (void)pt_eff_setPreferredForwardBufferDuration:(NSTimeInterval)preferredForwardBufferDuration {
    [self pt_eff_setPreferredForwardBufferDuration:pt_clampAVForwardBufferDuration(preferredForwardBufferDuration)];
}

- (void)pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)canUse {
    (void)canUse;
    [self pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:NO];
}

@end

static void pt_installAVPlayerItemHooks(void) {
    Class itemCls = [AVPlayerItem class];
    pt_swizzleInstanceMethod(itemCls,
                             @selector(initWithAsset:automaticallyLoadedAssetKeys:),
                             @selector(pt_eff_initWithAsset:automaticallyLoadedAssetKeys:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setPreferredMaximumResolution:),
                             @selector(pt_eff_setPreferredMaximumResolution:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setPreferredPeakBitRate:),
                             @selector(pt_eff_setPreferredPeakBitRate:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setPreferredForwardBufferDuration:),
                             @selector(pt_eff_setPreferredForwardBufferDuration:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setCanUseNetworkResourcesForLiveStreamingWhilePaused:),
                             @selector(pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:));
}

#pragma mark - Window Visibility & Occlusion Handling

static BOOL pt_isMainAppNSWindow(id win) {
    if (!win) {
        return NO;
    }
    NSString *className = NSStringFromClass([win class]);
    if ([className containsString:@"Menu"] ||
        [className containsString:@"StatusBar"] ||
        [className containsString:@"Tooltip"]) {
        return NO;
    }
    SEL canMainSel = NSSelectorFromString(@"canBecomeMainWindow");
    SEL isSheetSel = NSSelectorFromString(@"isSheet");
    BOOL canBecomeMain = canMainSel && [win respondsToSelector:canMainSel]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(win, canMainSel)
        : YES;
    BOOL isSheet = isSheetSel && [win respondsToSelector:isSheetSel]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(win, isSheetSel)
        : NO;
    return canBecomeMain && !isSheet;
}

static BOOL pt_queryWindowUnoccludedVisible(NSNotification * _Nullable notif) {
    SEL unoccludedSel = NSSelectorFromString(@"hasUnoccludedVisibleWindow");
    if (notif.object && [notif.object respondsToSelector:unoccludedSel]) {
        pt_cachedAKPlugin = notif.object;
        return ((BOOL (*)(id, SEL))objc_msgSend)(notif.object, unoccludedSel);
    }

    id cachedPlugin = pt_cachedAKPlugin;
    if (cachedPlugin && [cachedPlugin respondsToSelector:unoccludedSel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(cachedPlugin, unoccludedSel);
    }

    NSNumber *userInfoVal = notif.userInfo[@"hasUnoccludedVisibleWindow"];
    if ([userInfoVal isKindOfClass:[NSNumber class]]) {
        return [userInfoVal boolValue];
    }

    Class nsAppCls = NSClassFromString(@"NSApplication");
    SEL sharedAppSel = NSSelectorFromString(@"sharedApplication");
    SEL windowsSel = NSSelectorFromString(@"windows");
    if (nsAppCls && sharedAppSel && windowsSel && [nsAppCls respondsToSelector:sharedAppSel]) {
        id nsApp = ((id (*)(id, SEL))objc_msgSend)(nsAppCls, sharedAppSel);
        if (nsApp && [nsApp respondsToSelector:windowsSel]) {
            NSArray *windows = ((NSArray *(*)(id, SEL))objc_msgSend)(nsApp, windowsSel);
            BOOL sawMainWindow = NO;
            SEL visibleSel = NSSelectorFromString(@"isVisible");
            SEL miniSel = NSSelectorFromString(@"isMiniaturized");
            SEL occlusionSel = NSSelectorFromString(@"occlusionState");
            for (id win in windows) {
                if (!pt_isMainAppNSWindow(win)) {
                    continue;
                }
                sawMainWindow = YES;
                BOOL isVisible = visibleSel && [win respondsToSelector:visibleSel]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(win, visibleSel)
                    : YES;
                BOOL isMini = miniSel && [win respondsToSelector:miniSel]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(win, miniSel)
                    : NO;
                NSUInteger occlusion = occlusionSel && [win respondsToSelector:occlusionSel]
                    ? ((NSUInteger (*)(id, SEL))objc_msgSend)(win, occlusionSel)
                    : (1UL << 1);
                if (isVisible && !isMini && ((occlusion & (1UL << 1)) != 0)) {
                    return YES;
                }
            }
            if (sawMainWindow) {
                return NO;
            }
        }
    }

    return YES;
}

static void pt_cancelPendingOcclusionTimer(void) {
    if (pt_pendingOcclusionWorkItem) {
        dispatch_block_cancel(pt_pendingOcclusionWorkItem);
        pt_pendingOcclusionWorkItem = nil;
    }
}

static void pt_releaseTrackedMTKViewDrawables(void) {
    os_unfair_lock_lock(&pt_mtkViewLock);
    NSArray<MTKView *> *views = [pt_trackedMTKViews allObjects];
    os_unfair_lock_unlock(&pt_mtkViewLock);

    for (MTKView *view in views) {
        [view releaseDrawables];
    }
}

static void pt_scheduleOcclusionActionsIfNeeded(void) {
    BOOL needMTKRelease = (pt_memorySavingMode || pt_metalMemorySaver);
    BOOL needLowFPS = pt_powerSavingMode;
    if (!needMTKRelease && !needLowFPS) {
        return;
    }
    if (pt_pendingOcclusionWorkItem) {
        return;
    }

    dispatch_block_t work = dispatch_block_create(0, ^{
        pt_pendingOcclusionWorkItem = nil;
        if (pt_queryWindowUnoccludedVisible(nil)) {
            return;
        }
        if (needMTKRelease) {
            pt_releaseTrackedMTKViewDrawables();
        }
        if (needLowFPS) {
            if (!pt_isAnyMediaActivelyPlaying()) {
                atomic_store_explicit(&pt_occludedLowFPSActive, true, memory_order_release);
                pt_reapplyActiveFPSCeilingToAllTracked();
            }
        }
    });
    pt_pendingOcclusionWorkItem = work;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPTOcclusionDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   work);
}

static void pt_handleWindowVisibilityDidChange(NSNotification * _Nullable notif) {
    BOOL isVisible = pt_queryWindowUnoccludedVisible(notif);
    pt_lastKnownWindowVisible = isVisible;

    if (isVisible) {
        pt_cancelPendingOcclusionTimer();
        if (pt_powerSavingMode) {
            pt_updateTrackedWKWebViewsMediaSuspended(NO);
            if (atomic_exchange_explicit(&pt_occludedLowFPSActive, false, memory_order_acq_rel)) {
                pt_reapplyActiveFPSCeilingToAllTracked();
            }
        }
        if (pt_configuredFrameRateCap == -1) {
            pt_noteAdaptiveUserInput();
        }
    } else {
        if (pt_powerSavingMode) {
            pt_updateTrackedWKWebViewsMediaSuspended(YES);
        }
        pt_scheduleOcclusionActionsIfNeeded();
    }

    if (pt_fpsOverlay) {
        SEL pauseSel = NSSelectorFromString(@"setOverlayPaused:");
        id overlayCtrl = objc_getAssociatedObject([PTEfficiencyHooks class], "pt_fpsOverlayController");
        if (overlayCtrl && [overlayCtrl respondsToSelector:pauseSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(overlayCtrl, pauseSel, !isVisible);
        }
    }
}

static void pt_installVisibilityObserverIfNeeded(void) {
    if (!pt_powerSavingMode && !pt_memorySavingMode && !pt_metalMemorySaver && !pt_fpsOverlay && pt_configuredFrameRateCap != -1) {
        return;
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:kPTWindowVisibilityDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        pt_handleWindowVisibilityDidChange(note);
    }];
}

#pragma mark - FPS Overlay (when fpsOverlay == YES)

@interface CAMetalLayer (PTFPSOverlayHooks)
- (nullable id<CAMetalDrawable>)pt_eff_nextDrawable;
@end

@implementation CAMetalLayer (PTFPSOverlayHooks)

- (nullable id<CAMetalDrawable>)pt_eff_nextDrawable {
    id<CAMetalDrawable> drawable = [self pt_eff_nextDrawable];
    if (drawable) {
        if (pt_fpsOverlay) {
            atomic_fetch_add_explicit(&pt_metalDrawableFrameCount, 1, memory_order_relaxed);
        }
        if (pt_configuredFrameRateCap == -1 && pt_lastKnownWindowVisible) {
            pt_recordRingTimestamp(pt_metalDrawableTimes, &pt_metalDrawableHead, CACurrentMediaTime());
            pt_scheduleAdaptiveMotionReevalIfNeeded();
        }
    }
    return drawable;
}

@end

static BOOL pt_metalDrawableHookInstalled = NO;

static void pt_installMetalDrawableCounterIfNeeded(void) {
    if (pt_metalDrawableHookInstalled) {
        return;
    }
    pt_metalDrawableHookInstalled = YES;
    pt_swizzleInstanceMethod([CAMetalLayer class],
                             @selector(nextDrawable),
                             @selector(pt_eff_nextDrawable));
}

@interface PTFPSOverlayController : NSObject
@property (nonatomic, strong) UIView *pillView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, weak, nullable) UIWindow *attachedWindow;
@property (nonatomic, assign) CFTimeInterval lastSampleTime;
@property (nonatomic, assign) NSUInteger displayLinkFrames;
@property (nonatomic, assign) double lastMeasuredDisplayFPS;
@property (nonatomic, assign) double lastMeasuredMetalFPS;
@property (nonatomic, assign) UIEdgeInsets lastSafeInsets;
@property (nonatomic, assign) BOOL started;
+ (instancetype)shared;
- (void)start;
- (void)setOverlayPaused:(BOOL)paused;
- (void)handleCeilingDidChange:(NSInteger)ceiling;
@end

@implementation PTFPSOverlayController

+ (instancetype)shared {
    static PTFPSOverlayController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PTFPSOverlayController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastMeasuredDisplayFPS = 60.0;
        _lastMeasuredMetalFPS = 0.0;

        UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(14.0, 42.0, 72.0, 24.0)];
        pill.userInteractionEnabled = NO;
        pill.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.82];
        pill.layer.zPosition = 99999.0;
        pill.layer.cornerRadius = 11.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.borderWidth = 0.5;
        pill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        pill.accessibilityIdentifier = @"PTFPSOverlayPill";

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectZero];
        lbl.userInteractionEnabled = NO;
        lbl.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.numberOfLines = 1;
        lbl.text = @"60 FPS";
        [pill addSubview:lbl];

        _pillView = pill;
        _label = lbl;
        pt_overlayPillLayer = pill.layer;
    }
    return self;
}

- (nullable UIWindow *)findPrimaryNormalWindow {
    UIWindow *fallback = nil;
    NSInteger bestRank = -1;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *winScene = (UIWindowScene *)scene;
        NSInteger sceneRank = 0;
        if (winScene.activationState == UISceneActivationStateForegroundActive) {
            sceneRank = 2;
        } else if (winScene.activationState == UISceneActivationStateForegroundInactive) {
            sceneRank = 1;
        }
        for (UIWindow *win in winScene.windows) {
            if (win.windowLevel != UIWindowLevelNormal || win.isHidden || win.alpha <= 0.01) {
                continue;
            }
            if (win.bounds.size.width <= 100.0 || win.bounds.size.height <= 100.0) {
                continue;
            }
            if (win.isKeyWindow && sceneRank >= 1) {
                return win;
            }
            NSInteger rank = sceneRank * 2 + (win.isKeyWindow ? 1 : 0);
            if (!fallback || rank > bestRank) {
                fallback = win;
                bestRank = rank;
            }
        }
    }
    return fallback;
}

- (void)layoutPillInWindow:(UIWindow *)window {
    if (!window) {
        return;
    }
    BOOL prevSuppress = pt_tlsSuppressMotionRecording;
    pt_tlsSuppressMotionRecording = YES;
    [self.label sizeToFit];
    CGSize textSize = self.label.bounds.size;
    CGFloat textW = ceil(textSize.width);
    CGFloat textH = ceil(textSize.height);
    CGFloat pillW = MAX(56.0, textW + 20.0);
    CGFloat pillH = MAX(22.0, textH + 8.0);

    UIEdgeInsets safe = window.safeAreaInsets;
    self.lastSafeInsets = safe;
    CGFloat x = MAX(14.0, safe.left + 14.0);
    CGFloat y = MAX(42.0, safe.top + 10.0);
    self.pillView.frame = CGRectMake(x, y, pillW, pillH);
    self.label.frame = CGRectMake(10.0, (pillH - textH) * 0.5, textW, textH);
    pt_tlsSuppressMotionRecording = prevSuppress;
}

- (void)attachToBestWindowIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachToBestWindowIfNeeded];
        });
        return;
    }
    UIWindow *target = [self findPrimaryNormalWindow];
    if (!target) {
        return;
    }
    BOOL prevSuppress = pt_tlsSuppressMotionRecording;
    pt_tlsSuppressMotionRecording = YES;
    if (self.pillView.superview != target) {
        self.attachedWindow = target;
        [target addSubview:self.pillView];
        [self layoutPillInWindow:target];
        [target bringSubviewToFront:self.pillView];
    } else {
        if (!UIEdgeInsetsEqualToEdgeInsets(self.lastSafeInsets, target.safeAreaInsets)) {
            [self layoutPillInWindow:target];
        }
        if (target.subviews.lastObject != self.pillView) {
            [target bringSubviewToFront:self.pillView];
        }
    }
    pt_tlsSuppressMotionRecording = prevSuppress;
}

- (void)updateLabelWithDisplayFPS:(double)displayFPS metalFPS:(double)metalFPS {
    self.lastMeasuredDisplayFPS = displayFPS;
    self.lastMeasuredMetalFPS = metalFPS;

    NSInteger roundedFPS = MAX(0, (NSInteger)llround(displayFPS));
    NSMutableString *text = [NSMutableString stringWithFormat:@"%ld FPS", (long)roundedFPS];

    BOOL mediaFloorActive = NO;
    BOOL motionHoldActive = NO;
    BOOL idleActive = NO;
    if (pt_configuredFrameRateCap == -1) {
        PTAdaptiveFPSStage stage = (PTAdaptiveFPSStage)atomic_load_explicit(&pt_adaptiveStage, memory_order_acquire);
        if (stage != PTAdaptiveFPSStageActive) {
            if (atomic_load_explicit(&pt_adaptiveMotionHold, memory_order_acquire)) {
                motionHoldActive = YES;
                [text appendString:@" · 动效"];
            } else if (pt_isAnyMediaActivelyPlaying()) {
                mediaFloorActive = YES;
                [text appendString:@" · 媒体"];
            } else {
                idleActive = YES;
                [text appendString:@" · 静止"];
            }
        }
    } else if (atomic_load_explicit(&pt_occludedLowFPSActive, memory_order_acquire)) {
        idleActive = YES;
        [text appendString:@" · 省电"];
    }

    NSInteger roundedMetalFPS = MAX(0, (NSInteger)llround(metalFPS));
    if (metalFPS >= 1.0 && llabs(roundedFPS - roundedMetalFPS) >= 5) {
        [text appendFormat:@" · Metal %ld", (long)roundedMetalFPS];
    }

    BOOL prevSuppress = pt_tlsSuppressMotionRecording;
    pt_tlsSuppressMotionRecording = YES;
    if (motionHoldActive) {
        self.label.textColor = [UIColor colorWithRed:0.38 green:0.92 blue:0.86 alpha:1.0];
    } else if (mediaFloorActive) {
        self.label.textColor = [UIColor colorWithRed:0.40 green:0.85 blue:1.0 alpha:1.0];
    } else if (idleActive && roundedFPS <= 2) {
        self.label.textColor = [UIColor colorWithRed:0.45 green:0.90 blue:0.55 alpha:1.0];
    } else if (idleActive) {
        self.label.textColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.35 alpha:1.0];
    } else {
        self.label.textColor = [UIColor whiteColor];
    }

    if (![self.label.text isEqualToString:text]) {
        self.label.text = text;
        UIWindow *win = (UIWindow *)self.pillView.superview;
        if ([win isKindOfClass:[UIWindow class]]) {
            [self layoutPillInWindow:win];
        }
    }
    pt_tlsSuppressMotionRecording = prevSuppress;
}

- (void)onDisplayLinkTick:(CADisplayLink *)link {
    (void)link;
    [self attachToBestWindowIfNeeded];

    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastSampleTime <= 0.0) {
        self.lastSampleTime = now;
        self.displayLinkFrames = 0;
        atomic_store_explicit(&pt_metalDrawableFrameCount, 0, memory_order_release);
        NSInteger ceiling = pt_activeFPSCeiling();
        [self updateLabelWithDisplayFPS:(ceiling > 0 ? (double)ceiling : 60.0) metalFPS:0.0];
        return;
    }

    self.displayLinkFrames += 1;
    CFTimeInterval elapsed = now - self.lastSampleTime;
    if (elapsed >= 0.75) {
        double displayFPS = (double)self.displayLinkFrames / elapsed;
        uint64_t metalFrames = atomic_exchange_explicit(&pt_metalDrawableFrameCount, 0, memory_order_acq_rel);
        double metalFPS = (double)metalFrames / elapsed;
        self.displayLinkFrames = 0;
        self.lastSampleTime = now;
        [self updateLabelWithDisplayFPS:displayFPS metalFPS:metalFPS];
    }
}

- (void)handleCeilingDidChange:(NSInteger)ceiling {
    if (!self.started) {
        return;
    }
    void (^update)(void) = ^{
        self.displayLinkFrames = 0;
        self.lastSampleTime = CACurrentMediaTime();
        atomic_store_explicit(&pt_metalDrawableFrameCount, 0, memory_order_release);
        double shownFPS = (ceiling > 0) ? (double)ceiling : self.lastMeasuredDisplayFPS;
        [self updateLabelWithDisplayFPS:shownFPS metalFPS:0.0];
    };
    if ([NSThread isMainThread]) {
        update();
    } else {
        dispatch_async(dispatch_get_main_queue(), update);
    }
}

- (void)setOverlayPaused:(BOOL)paused {
    if (!self.started || !self.displayLink) {
        return;
    }
    self.displayLink.paused = paused;
    if (!paused) {
        self.displayLinkFrames = 0;
        self.lastSampleTime = CACurrentMediaTime();
        atomic_store_explicit(&pt_metalDrawableFrameCount, 0, memory_order_release);
    }
}

- (void)start {
    if (self.started) {
        [self attachToBestWindowIfNeeded];
        return;
    }
    self.started = YES;
    self.lastSampleTime = CACurrentMediaTime();
    self.displayLinkFrames = 0;
    atomic_store_explicit(&pt_metalDrawableFrameCount, 0, memory_order_release);

    NSInteger ceiling = pt_activeFPSCeiling();
    [self updateLabelWithDisplayFPS:(ceiling > 0 ? (double)ceiling : 60.0) metalFPS:0.0];

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLinkTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    if (!pt_lastKnownWindowVisible) {
        link.paused = YES;
    }
    self.displayLink = link;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in @[
        UIWindowDidBecomeKeyNotification,
        UIWindowDidBecomeVisibleNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationDidFinishLaunchingNotification
    ]) {
        [nc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            [self attachToBestWindowIfNeeded];
        }];
    }

    [self attachToBestWindowIfNeeded];
}

@end

static BOOL pt_fpsOverlayInstalled = NO;

static void pt_notifyOverlayCeilingDidChange(NSInteger ceiling) {
    if (!pt_fpsOverlay || !pt_fpsOverlayInstalled) {
        return;
    }
    [[PTFPSOverlayController shared] handleCeilingDidChange:ceiling];
}

static void pt_installFPSOverlay(void) {
    if (pt_fpsOverlayInstalled) {
        return;
    }
    pt_fpsOverlayInstalled = YES;
    pt_installMetalDrawableCounterIfNeeded();
    PTFPSOverlayController *controller = [PTFPSOverlayController shared];
    objc_setAssociatedObject([PTEfficiencyHooks class],
                             "pt_fpsOverlayController",
                             controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller start];
    });
}

#pragma mark - PTEfficiencyHooks

@implementation PTEfficiencyHooks

+ (void)installIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];
        if ([env[@"PLAYTOOLS_DISABLE_EFFICIENCY_HOOKS"] isEqualToString:@"1"]) {
            return;
        }

        id settings = [PlaySettings shared];
        pt_powerSavingMode = pt_settingsBool(settings, NSSelectorFromString(@"powerSavingMode"));
        pt_memorySavingMode = pt_settingsBool(settings, NSSelectorFromString(@"memorySavingMode"));
        pt_configuredFrameRateCap = pt_settingsInteger(settings, NSSelectorFromString(@"frameRateCap"));
        pt_metalMemorySaver = pt_settingsBool(settings, NSSelectorFromString(@"metalMemorySaver"));
        pt_avMediaSaver = pt_settingsBool(settings, NSSelectorFromString(@"avMediaSaver"));
        pt_fpsOverlay = pt_settingsBool(settings, NSSelectorFromString(@"fpsOverlay"));

        if (!pt_powerSavingMode &&
            !pt_memorySavingMode &&
            pt_configuredFrameRateCap == 0 &&
            !pt_metalMemorySaver &&
            !pt_avMediaSaver &&
            !pt_fpsOverlay) {
            return;
        }

        if (pt_powerSavingMode) {
            pt_installAccessibilityHooks();
            pt_installWKWebViewHooks();
        }
        if (pt_memorySavingMode) {
            pt_installCacheGovernanceHooks();
        }
        if (pt_memorySavingMode || pt_metalMemorySaver) {
            pt_installMetalAndBackingStoreHooks();
        }
        if (pt_shouldTrackMTKView()) {
            pt_installMTKViewInitHooks();
        }
        if (pt_shouldClampFPS()) {
            pt_installFrameRateHooks();
        }
        if (pt_configuredFrameRateCap == -1 || pt_powerSavingMode) {
            pt_installAVPlayerTrackingHooks();
        }
        if (pt_configuredFrameRateCap == -1) {
            pt_installMetalDrawableCounterIfNeeded();
            pt_installAdaptiveFPSHooks();
        }
        if (pt_avMediaSaver) {
            pt_installAVPlayerItemHooks();
        }
        if (pt_fpsOverlay) {
            pt_installFPSOverlay();
        }

        pt_installVisibilityObserverIfNeeded();
    });
}

+ (void)trimRegisteredNSCaches {
    os_unfair_lock_lock(&pt_nsCacheLock);
    NSArray<NSCache *> *caches = pt_registeredNSCaches ? [pt_registeredNSCaches allObjects] : @[];
    os_unfair_lock_unlock(&pt_nsCacheLock);

    for (NSCache *cache in caches) {
        [cache removeAllObjects];
    }
}

+ (NSInteger)currentEffectiveFPSCeiling {
    return pt_activeFPSCeiling();
}

+ (BOOL)isFPSOverlayInstalled {
    return pt_fpsOverlayInstalled;
}

+ (BOOL)isAdaptiveMotionHoldActive {
    return atomic_load_explicit(&pt_adaptiveMotionHold, memory_order_acquire) ? YES : NO;
}

@end
