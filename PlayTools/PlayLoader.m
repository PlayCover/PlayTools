//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

@import MachO;

// Get device model from playcover .plist
// With a null terminator
#define DEVICE_MODEL [[[PlaySettings shared] deviceModel] cStringUsingEncoding:NSUTF8StringEncoding]
#define OEM_ID [[[PlaySettings shared] oemID] cStringUsingEncoding:NSUTF8StringEncoding]
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int pt_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL) + 1) {
                strcpy(buf, DEVICE_MODEL);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        if (NULL == buf) {
            *size = strlen(OEM_ID) + 1;
        } else {
            if (*size > strlen(OEM_ID) + 1) {
                strcpy(buf, OEM_ID);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        }
        else if (oldp != NULL) {
            if (*oldlenp < strlen(DEVICE_MODEL) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, DEVICE_MODEL);
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else if (oldp != NULL) {
            if (*oldlenp < strlen(OEM_ID) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, OEM_ID);
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(pt_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if ([[PlaySettings shared] playChain]) {
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

static uint8_t ue_status = 0;

static char const* ue_fix_filename(char const* filename) {
    static char UE_PATTERN[1024] = "//Users/";
    getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    
    char const* p = filename;
    if (ue_status == 2) {
        char const* last_p = p;
        while ((p = strstr(p, UE_PATTERN))) {
            last_p = ++p;
        }
        
        return last_p;
    }

    return p;
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);

    if (oflag == O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return open(filename, O_CREAT, mod);
    }

    return open(filename, oflag);
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return stat(ue_fix_filename(path), buf);
}

static int pt_access(char const* path, int mode) {
    return access(ue_fix_filename(path), mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    return rename(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

static int pt_unlink(char const* path) {
    return unlink(ue_fix_filename(path));
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int pt_usleep(useconds_t time) {
    dispatch_once(&thread_sleep_once, ^{
        thread_sleep_counters = [NSMutableDictionary dictionary];
        last_sleep_attempts = [NSMutableDictionary dictionary];
        thread_sleep_lock = [[NSLock alloc] init];
        [thread_sleep_lock lock];
    });
    
    if ([[PlaySettings shared] blockSleepSpamming]) {
        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);

        BOOL exceeded_sleep_limit = NO;
        @synchronized (thread_sleep_counters) {
            int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
            int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];

            if (time == 100000) {
                int timestamp = (int)[[NSDate date] timeIntervalSince1970];
                // If it sleeps too fast, increase counter
                if (timestamp - last_sleep_attempt < 2) {
                    thread_sleep_counter++;
                } else {
                    thread_sleep_counter = 1;
                }
                last_sleep_attempt = timestamp;
                thread_sleep_counters[threadKey] = @(thread_sleep_counter);
                last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            }

            exceeded_sleep_limit = thread_sleep_counter > 100;
        }

        if (exceeded_sleep_limit) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return usleep(time);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

static void (*pt_origNavViewWillAppear)(id, SEL, BOOL) = NULL;
static BOOL pt_navAppearanceGuardInstalled = NO;

static void pt_navViewWillAppear(UINavigationController *self, SEL _cmd, BOOL animated) {
    // On Mac Catalyst initial root presentation (including empty-scene window recovery),
    // UIPresentationController can invoke viewWillAppear: with animated=YES while no
    // transitionCoordinator exists and the view is not yet in a window. UINavigationController
    // forwards animated=YES to navigationController:willShowViewController:animated:, whereas
    // viewDidAppear: later skips pairing it with didShowViewController:animated:, leaving apps
    // that lock UI during animated navigation transitions permanently non-interactive.
    BOOL effectiveAnimated = animated;
    if (effectiveAnimated &&
        self.transitionCoordinator == nil &&
        self.viewIfLoaded.window == nil) {
        effectiveAnimated = NO;
    }
    if (pt_origNavViewWillAppear) {
        pt_origNavViewWillAppear(self, _cmd, effectiveAnimated);
    }
}

static void pt_installNavigationAppearanceBalanceGuard(void) {
    if (pt_navAppearanceGuardInstalled) {
        return;
    }
    pt_navAppearanceGuardInstalled = YES;

    Class navCls = objc_getClass("UINavigationController");
    if (!navCls) {
        return;
    }
    Method m = class_getInstanceMethod(navCls, @selector(viewWillAppear:));
    if (m) {
        IMP origImp = method_getImplementation(m);
        if (origImp != (IMP)pt_navViewWillAppear) {
            pt_origNavViewWillAppear = (void (*)(id, SEL, BOOL))origImp;
            class_replaceMethod(navCls, @selector(viewWillAppear:),
                                (IMP)pt_navViewWillAppear, method_getTypeEncoding(m));
        }
    }
}

static id (*pt_origVisualEffectInitWithEffect)(id, SEL, id) = NULL;
static void (*pt_origVisualEffectSetEffect)(id, SEL, id) = NULL;
static void (*pt_origVisualEffectTraitCollectionDidChange)(id, SEL, UITraitCollection *) = NULL;
static void (*pt_origVisualEffectLayoutSubviews)(id, SEL) = NULL;
static void (*pt_origVisualEffectSetCornerConfiguration)(id, SEL, id) = NULL;
static Class pt_glassEffectClass = Nil;
static BOOL pt_glassEffectGuardInstalled = NO;
static const void *kPTAppliedGlassEffectKey = &kPTAppliedGlassEffectKey;
static const void *kPTAppliedGlassOverlayKey = &kPTAppliedGlassOverlayKey;
static const void *kPTAppliedGlassCornersKey = &kPTAppliedGlassCornersKey;
static const void *kPTAppliedGlassBorderKey = &kPTAppliedGlassBorderKey;

static UIBlurEffect *pt_fallbackBlurEffectForGlassEffect(id glassEffect,
                                                          UITraitCollection *traitCollection,
                                                          UIColor * __autoreleasing *outTintOverlay) {
    NSInteger glassStyle = 0; // 0 = Regular, 1 = Clear
    SEL styleSel = sel_registerName("style");
    if ([glassEffect respondsToSelector:styleSel]) {
        glassStyle = ((NSInteger (*)(id, SEL))objc_msgSend)(glassEffect, styleSel);
    }

    UIColor *tintColor = nil;
    SEL tintSel = sel_registerName("tintColor");
    if ([glassEffect respondsToSelector:tintSel]) {
        tintColor = ((id (*)(id, SEL))objc_msgSend)(glassEffect, tintSel);
    }

    UITraitCollection *effectiveTraits = traitCollection ?: [UITraitCollection currentTraitCollection];
    UIColor *resolved = tintColor;
    if (resolved && effectiveTraits &&
        [resolved respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [resolved resolvedColorWithTraitCollection:effectiveTraits];
    }

    CGFloat r = 0.0, g = 0.0, b = 0.0, alpha = 0.0;
    if (resolved) {
        if (![resolved getRed:&r green:&g blue:&b alpha:&alpha]) {
            CGFloat white = 0.0;
            if ([resolved getWhite:&white alpha:&alpha]) {
                r = white;
                g = white;
                b = white;
            } else {
                alpha = 0.0;
            }
        }
    }

    BOOL isDarkMode = (effectiveTraits != nil && effectiveTraits.userInterfaceStyle == UIUserInterfaceStyleDark);
    CGFloat luminance = 0.299 * r + 0.587 * g + 0.114 * b;
    BOOL useDarkMaterial = isDarkMode;
    if (!isDarkMode && alpha >= 0.55 && luminance < 0.35) {
        useDarkMaterial = YES;
    } else if (isDarkMode && alpha >= 0.55 && luminance > 0.65) {
        useDarkMaterial = NO;
    }

    UIBlurEffectStyle style;
    UIColor *overlay = nil;
    if (glassStyle == 1) {
        // Clear glass style: stay airier with UltraThinMaterial.
        if (@available(iOS 13.0, *)) {
            style = useDarkMaterial ? UIBlurEffectStyleSystemUltraThinMaterialDark
                                    : UIBlurEffectStyleSystemUltraThinMaterialLight;
        } else {
            style = useDarkMaterial ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;
        }
        if (alpha > 0.05) {
            if (!useDarkMaterial && luminance < 0.45) {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.10, 0.05)];
            } else {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.20, 0.14)];
            }
        }
    } else {
        if (@available(iOS 13.0, *)) {
            style = useDarkMaterial ? UIBlurEffectStyleSystemThinMaterialDark
                                    : UIBlurEffectStyleSystemThinMaterialLight;
        } else {
            style = useDarkMaterial ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;
        }
        if (alpha > 0.05) {
            if (!useDarkMaterial && luminance < 0.45) {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.10, 0.05)];
            } else if (useDarkMaterial) {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.28, 0.20)];
            } else {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.20, 0.14)];
            }
        }
    }

    if (outTintOverlay) {
        *outTintOverlay = overlay;
    }
    return [UIBlurEffect effectWithStyle:style];
}

static void pt_applyGlassFallbackAppearance(UIVisualEffectView *view, UIColor *overlay) {
    view.backgroundColor = [UIColor clearColor];
    if (overlay) {
        view.contentView.backgroundColor = overlay;
        objc_setAssociatedObject(view, kPTAppliedGlassOverlayKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(view, kPTAppliedGlassOverlayKey) != nil) {
        view.contentView.backgroundColor = nil;
        objc_setAssociatedObject(view, kPTAppliedGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void pt_queryViewCornerRadii(UIView *target,
                                    CGSize boundsSize,
                                    CGFloat *outTL,
                                    CGFloat *outTR,
                                    CGFloat *outBL,
                                    CGFloat *outBR) {
    CGFloat maxPossible = MIN(boundsSize.width, boundsSize.height) * 0.5;
    if (maxPossible <= 0.0) {
        *outTL = *outTR = *outBL = *outBR = 0.0;
        return;
    }

    CGFloat tl = 0.0, tr = 0.0, bl = 0.0, br = 0.0;
    SEL effSel = sel_registerName("effectiveRadiusForCorner:");
    if ([target respondsToSelector:effSel]) {
        CGFloat (*effImp)(id, SEL, UIRectCorner) = (CGFloat (*)(id, SEL, UIRectCorner))objc_msgSend;
        tl = effImp(target, effSel, UIRectCornerTopLeft);
        tr = effImp(target, effSel, UIRectCornerTopRight);
        bl = effImp(target, effSel, UIRectCornerBottomLeft);
        br = effImp(target, effSel, UIRectCornerBottomRight);
        tl = isfinite(tl) ? MAX(0.0, MIN(tl, maxPossible)) : 0.0;
        tr = isfinite(tr) ? MAX(0.0, MIN(tr, maxPossible)) : 0.0;
        bl = isfinite(bl) ? MAX(0.0, MIN(bl, maxPossible)) : 0.0;
        br = isfinite(br) ? MAX(0.0, MIN(br, maxPossible)) : 0.0;
    }

    if (tl <= 0.01 && tr <= 0.01 && bl <= 0.01 && br <= 0.01) {
        CGFloat layerR = target.layer.cornerRadius;
        if (isfinite(layerR) && layerR > 0.01) {
            CGFloat clamped = MIN(layerR, maxPossible);
            CACornerMask masked = target.layer.maskedCorners;
            if (masked & kCALayerMinXMinYCorner) { tl = clamped; }
            if (masked & kCALayerMaxXMinYCorner) { tr = clamped; }
            if (masked & kCALayerMinXMaxYCorner) { bl = clamped; }
            if (masked & kCALayerMaxXMaxYCorner) { br = clamped; }
        }
    }

    *outTL = tl;
    *outTR = tr;
    *outBL = bl;
    *outBR = br;
}

static void pt_resolveGlassCornerRadii(UIView *view,
                                       CGFloat *outTL,
                                       CGFloat *outTR,
                                       CGFloat *outBL,
                                       CGFloat *outBR) {
    CGFloat tl = 0.0, tr = 0.0, bl = 0.0, br = 0.0;
    pt_queryViewCornerRadii(view, view.bounds.size, &tl, &tr, &bl, &br);

    if (tl <= 0.01 && tr <= 0.01 && bl <= 0.01 && br <= 0.01 && view.superview != nil) {
        CGRect f = view.frame;
        CGRect sb = view.superview.bounds;
        if (fabs(f.origin.x - sb.origin.x) <= 1.0 &&
            fabs(f.origin.y - sb.origin.y) <= 1.0 &&
            fabs(f.size.width - sb.size.width) <= 1.0 &&
            fabs(f.size.height - sb.size.height) <= 1.0) {
            pt_queryViewCornerRadii(view.superview, view.bounds.size, &tl, &tr, &bl, &br);
        }
    }

    if (outTL) { *outTL = tl; }
    if (outTR) { *outTR = tr; }
    if (outBL) { *outBL = bl; }
    if (outBR) { *outBR = br; }
}

static void pt_removeGlassDecorationLayers(UIVisualEffectView *view) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (objc_getAssociatedObject(view, kPTAppliedGlassBorderKey) != nil) {
        view.layer.borderWidth = 0.0;
        view.layer.borderColor = NULL;
        objc_setAssociatedObject(view, kPTAppliedGlassBorderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(view, kPTAppliedGlassCornersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction commit];
}

static void pt_updateGlassGeometryAndRim(UIVisualEffectView *view) {
    if (objc_getAssociatedObject(view, kPTAppliedGlassEffectKey) == nil) {
        return;
    }
    CGRect bounds = view.bounds;
    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) {
        return;
    }

    CGFloat tl = 0.0, tr = 0.0, bl = 0.0, br = 0.0;
    pt_resolveGlassCornerRadii(view, &tl, &tr, &bl, &br);
    CGFloat maxR = MAX(MAX(tl, tr), MAX(bl, br));

    CACornerMask mask = 0;
    if (tl > 0.5) { mask |= kCALayerMinXMinYCorner; }
    if (tr > 0.5) { mask |= kCALayerMaxXMinYCorner; }
    if (bl > 0.5) { mask |= kCALayerMinXMaxYCorner; }
    if (br > 0.5) { mask |= kCALayerMaxXMaxYCorner; }

    BOOL isDark = (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (maxR > 0.5) {
        view.layer.cornerRadius = maxR;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.layer.maskedCorners = mask;
        view.clipsToBounds = YES;
        objc_setAssociatedObject(view, kPTAppliedGlassCornersKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    view.layer.borderWidth = 0.75;
    view.layer.borderColor = (isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.16]
        : [UIColor colorWithWhite:0.0 alpha:0.08]).CGColor;
    objc_setAssociatedObject(view, kPTAppliedGlassBorderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction commit];
}

static id pt_visualEffectInitWithEffect(UIVisualEffectView *self, SEL _cmd, id effect) {
    BOOL isGlass = (pt_glassEffectClass != Nil && effect != nil && [effect isKindOfClass:pt_glassEffectClass]);
    if (!isGlass) {
        return pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, effect) : nil;
    }
    UIColor *overlay = nil;
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(effect, nil, &overlay);
    id instance = pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, fallback) : nil;
    if (instance) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)instance;
        objc_setAssociatedObject(effectView, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor *resolvedOverlay = nil;
        UIBlurEffect *resolvedFallback = pt_fallbackBlurEffectForGlassEffect(effect, effectView.traitCollection, &resolvedOverlay);
        if (pt_origVisualEffectSetEffect) {
            pt_origVisualEffectSetEffect(effectView, @selector(setEffect:), resolvedFallback);
        }
        pt_applyGlassFallbackAppearance(effectView, resolvedOverlay ?: overlay);
        pt_updateGlassGeometryAndRim(effectView);
    }
    return instance;
}

static void pt_visualEffectSetEffect(UIVisualEffectView *self, SEL _cmd, id effect) {
    BOOL isGlass = (pt_glassEffectClass != Nil && effect != nil && [effect isKindOfClass:pt_glassEffectClass]);
    if (!isGlass) {
        objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (objc_getAssociatedObject(self, kPTAppliedGlassOverlayKey) != nil) {
            self.contentView.backgroundColor = nil;
            objc_setAssociatedObject(self, kPTAppliedGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_removeGlassDecorationLayers(self);
        if (pt_origVisualEffectSetEffect) {
            pt_origVisualEffectSetEffect(self, _cmd, effect);
        }
        return;
    }
    objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *overlay = nil;
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(effect, self.traitCollection, &overlay);
    if (pt_origVisualEffectSetEffect) {
        pt_origVisualEffectSetEffect(self, _cmd, fallback);
    }
    pt_applyGlassFallbackAppearance(self, overlay);
    pt_updateGlassGeometryAndRim(self);
}

static void pt_visualEffectTraitCollectionDidChange(UIVisualEffectView *self,
                                                    SEL _cmd,
                                                    UITraitCollection *previousTraitCollection) {
    if (pt_origVisualEffectTraitCollectionDidChange) {
        pt_origVisualEffectTraitCollectionDidChange(self, _cmd, previousTraitCollection);
    }
    id glassEffect = objc_getAssociatedObject(self, kPTAppliedGlassEffectKey);
    if (!glassEffect) {
        return;
    }
    if (previousTraitCollection &&
        previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) {
        return;
    }
    UIColor *overlay = nil;
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(glassEffect, self.traitCollection, &overlay);
    if (pt_origVisualEffectSetEffect) {
        pt_origVisualEffectSetEffect(self, @selector(setEffect:), fallback);
    }
    pt_applyGlassFallbackAppearance(self, overlay);
    pt_updateGlassGeometryAndRim(self);
}

static void pt_visualEffectLayoutSubviews(UIVisualEffectView *self, SEL _cmd) {
    if (pt_origVisualEffectLayoutSubviews) {
        pt_origVisualEffectLayoutSubviews(self, _cmd);
    }
    if (objc_getAssociatedObject(self, kPTAppliedGlassEffectKey) != nil) {
        pt_updateGlassGeometryAndRim(self);
    }
}

static void pt_visualEffectSetCornerConfiguration(UIVisualEffectView *self, SEL _cmd, id cornerConfiguration) {
    if (pt_origVisualEffectSetCornerConfiguration) {
        pt_origVisualEffectSetCornerConfiguration(self, _cmd, cornerConfiguration);
    }
    if (objc_getAssociatedObject(self, kPTAppliedGlassEffectKey) != nil) {
        pt_updateGlassGeometryAndRim(self);
    }
}

static void pt_installGlassEffectCompatibilityGuard(void) {
    if (pt_glassEffectGuardInstalled) {
        return;
    }
    pt_glassEffectGuardInstalled = YES;

    // On Mac Catalyst, UIGlassEffect views can fail to create backdrop sublayers and fall back to
    // an opaque white fill. Map UIGlassEffect to native UIBlurEffect materials preserving tint polarity,
    // continuous corner configuration radii, and a lightweight specular rim/sheen.
    pt_glassEffectClass = NSClassFromString(@"UIGlassEffect");
    Class effectViewCls = objc_getClass("UIVisualEffectView");
    if (!pt_glassEffectClass || !effectViewCls) {
        return;
    }

    Method initM = class_getInstanceMethod(effectViewCls, @selector(initWithEffect:));
    if (initM) {
        IMP origImp = method_getImplementation(initM);
        if (origImp != (IMP)pt_visualEffectInitWithEffect) {
            pt_origVisualEffectInitWithEffect = (id (*)(id, SEL, id))origImp;
            class_replaceMethod(effectViewCls, @selector(initWithEffect:),
                                (IMP)pt_visualEffectInitWithEffect, method_getTypeEncoding(initM));
        }
    }

    Method setM = class_getInstanceMethod(effectViewCls, @selector(setEffect:));
    if (setM) {
        IMP origImp = method_getImplementation(setM);
        if (origImp != (IMP)pt_visualEffectSetEffect) {
            pt_origVisualEffectSetEffect = (void (*)(id, SEL, id))origImp;
            class_replaceMethod(effectViewCls, @selector(setEffect:),
                                (IMP)pt_visualEffectSetEffect, method_getTypeEncoding(setM));
        }
    }

    Method traitM = class_getInstanceMethod(effectViewCls, @selector(traitCollectionDidChange:));
    if (traitM) {
        IMP origImp = method_getImplementation(traitM);
        if (origImp != (IMP)pt_visualEffectTraitCollectionDidChange) {
            pt_origVisualEffectTraitCollectionDidChange = (void (*)(id, SEL, UITraitCollection *))origImp;
            class_replaceMethod(effectViewCls, @selector(traitCollectionDidChange:),
                                (IMP)pt_visualEffectTraitCollectionDidChange, method_getTypeEncoding(traitM));
        }
    }

    Method layoutM = class_getInstanceMethod(effectViewCls, @selector(layoutSubviews));
    if (layoutM) {
        IMP origImp = method_getImplementation(layoutM);
        if (origImp != (IMP)pt_visualEffectLayoutSubviews) {
            pt_origVisualEffectLayoutSubviews = (void (*)(id, SEL))origImp;
            class_replaceMethod(effectViewCls, @selector(layoutSubviews),
                                (IMP)pt_visualEffectLayoutSubviews, method_getTypeEncoding(layoutM));
        }
    }

    SEL setCornerSel = sel_registerName("setCornerConfiguration:");
    Method cornerM = class_getInstanceMethod(effectViewCls, setCornerSel);
    if (cornerM) {
        IMP origImp = method_getImplementation(cornerM);
        if (origImp != (IMP)pt_visualEffectSetCornerConfiguration) {
            pt_origVisualEffectSetCornerConfiguration = (void (*)(id, SEL, id))origImp;
            class_replaceMethod(effectViewCls, setCornerSel,
                                (IMP)pt_visualEffectSetCornerConfiguration, method_getTypeEncoding(cornerM));
        }
    }
}



#if TARGET_OS_MACCATALYST
static NSInteger pt_systemAppearanceUpdateDepth = 0;
static void (*pt_origUpdateFromSystemAppearance)(id, SEL, id) = NULL;
static void (*pt_origWindowSetOverrideUserInterfaceStyle)(UIWindow *, SEL, UIUserInterfaceStyle) = NULL;
static BOOL pt_appearanceReentrancyGuardInstalled = NO;

static void pt_updateFromSystemAppearance(id self, SEL _cmd, id sender) {
    pt_systemAppearanceUpdateDepth++;
    @try {
        if (pt_origUpdateFromSystemAppearance) {
            pt_origUpdateFromSystemAppearance(self, _cmd, sender);
        }
    } @finally {
        pt_systemAppearanceUpdateDepth--;
    }
}

static void pt_windowSetOverrideUserInterfaceStyle(UIWindow *self, SEL _cmd, UIUserInterfaceStyle style) {
    if (pt_systemAppearanceUpdateDepth > 0 && [NSThread isMainThread]) {
        if (self.overrideUserInterfaceStyle == style) {
            return;
        }
        __weak UIWindow *weakWin = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = weakWin;
            if (win && win.overrideUserInterfaceStyle != style && pt_origWindowSetOverrideUserInterfaceStyle) {
                pt_origWindowSetOverrideUserInterfaceStyle(win, _cmd, style);
            }
        });
        return;
    }
    if (pt_origWindowSetOverrideUserInterfaceStyle) {
        pt_origWindowSetOverrideUserInterfaceStyle(self, _cmd, style);
    }
}

static void pt_installWindowAppearanceReentrancyGuard(void) {
    if (pt_appearanceReentrancyGuardInstalled) {
        return;
    }
    pt_appearanceReentrancyGuardInstalled = YES;

    Class uiApp = objc_getClass("UIApplication");
    SEL updateSel = sel_registerName("_updateFromSystemAppearance:");
    Method updateM = uiApp ? class_getInstanceMethod(uiApp, updateSel) : NULL;
    if (updateM) {
        IMP origImp = method_getImplementation(updateM);
        if (origImp != (IMP)pt_updateFromSystemAppearance) {
            pt_origUpdateFromSystemAppearance = (void (*)(id, SEL, id))origImp;
            class_replaceMethod(uiApp, updateSel, (IMP)pt_updateFromSystemAppearance, method_getTypeEncoding(updateM));
        }
    }

    Class uiWin = objc_getClass("UIWindow");
    SEL styleSel = @selector(setOverrideUserInterfaceStyle:);
    Method styleM = uiWin ? class_getInstanceMethod(uiWin, styleSel) : NULL;
    if (styleM) {
        IMP origImp = method_getImplementation(styleM);
        if (origImp != (IMP)pt_windowSetOverrideUserInterfaceStyle) {
            pt_origWindowSetOverrideUserInterfaceStyle = (void (*)(UIWindow *, SEL, UIUserInterfaceStyle))origImp;
            class_replaceMethod(uiWin, styleSel, (IMP)pt_windowSetOverrideUserInterfaceStyle, method_getTypeEncoding(styleM));
        }
    }
}
#endif

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    pt_installNavigationAppearanceBalanceGuard();
    pt_installGlassEffectCompatibilityGuard();
#if TARGET_OS_MACCATALYST
    pt_installWindowAppearanceReentrancyGuard();
#endif
    [PlayCover launch];
    
    if (ue_status == 0) {
        if (PlayInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[PlaySettings shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
