//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <math.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>

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


static id (*pt_origVisualEffectInitWithEffect)(id, SEL, id) = NULL;
static void (*pt_origVisualEffectSetEffect)(id, SEL, id) = NULL;
static void (*pt_origVisualEffectTraitCollectionDidChange)(id, SEL, UITraitCollection *) = NULL;
static void (*pt_origVisualEffectLayoutSubviews)(id, SEL) = NULL;
static void (*pt_origVisualEffectDidMoveToWindow)(id, SEL) = NULL;
static void (*pt_origVisualEffectSetCornerConfiguration)(id, SEL, id) = NULL;
static Class pt_glassEffectClass = Nil;
static BOOL pt_glassEffectGuardInstalled = NO;
static BOOL pt_powerSavingMaterialEnabled = NO;
static const void *kPTAppliedGlassEffectKey = &kPTAppliedGlassEffectKey;
static const void *kPTAppliedPowerSaveBlurEffectKey = &kPTAppliedPowerSaveBlurEffectKey;
static const void *kPTAppliedGlassOverlayKey = &kPTAppliedGlassOverlayKey;
static const void *kPTAppliedPowerSaveSolidBgKey = &kPTAppliedPowerSaveSolidBgKey;
static const void *kPTAppliedPowerSaveOrigOpaqueKey = &kPTAppliedPowerSaveOrigOpaqueKey;
static const void *kPTAppliedPowerSaveIsDarkKey = &kPTAppliedPowerSaveIsDarkKey;
static const void *kPTAppliedGlassCornersKey = &kPTAppliedGlassCornersKey;
static const void *kPTAppliedGlassBorderKey = &kPTAppliedGlassBorderKey;
static const void *kPTAppliedGlassStateKey = &kPTAppliedGlassStateKey;

typedef struct {
    CGFloat w;
    CGFloat h;
    CGFloat maxR;
    CACornerMask mask;
    BOOL isDark;
} PTGlassLayoutState;

static BOOL pt_isPowerSavingModeEnabled(void) {
    const char *disable = getenv("PLAYTOOLS_DISABLE_POWER_SAVING");
    if (disable && disable[0] == '1' && disable[1] == '\0') {
        return NO;
    }
    return [[PlaySettings shared] powerSavingMode];
}

static BOOL pt_isBlurEffectDark(UIBlurEffect *blurEffect, UITraitCollection *traitCollection) {
    UITraitCollection *effectiveTraits = traitCollection ?: [UITraitCollection currentTraitCollection];
    BOOL isDark = (effectiveTraits != nil && effectiveTraits.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (!blurEffect) {
        return isDark;
    }
    SEL styleSel = sel_registerName("_style");
    if ([blurEffect respondsToSelector:styleSel]) {
        NSInteger style = ((NSInteger (*)(id, SEL))objc_msgSend)(blurEffect, styleSel);
        switch (style) {
            case UIBlurEffectStyleExtraLight:
            case UIBlurEffectStyleLight:
            case UIBlurEffectStyleSystemUltraThinMaterialLight:
            case UIBlurEffectStyleSystemThinMaterialLight:
            case UIBlurEffectStyleSystemMaterialLight:
            case UIBlurEffectStyleSystemThickMaterialLight:
            case UIBlurEffectStyleSystemChromeMaterialLight:
                return NO;
            case UIBlurEffectStyleDark:
            case UIBlurEffectStyleSystemUltraThinMaterialDark:
            case UIBlurEffectStyleSystemThinMaterialDark:
            case UIBlurEffectStyleSystemMaterialDark:
            case UIBlurEffectStyleSystemThickMaterialDark:
            case UIBlurEffectStyleSystemChromeMaterialDark:
                return YES;
            default:
                break;
        }
    }
    return isDark;
}

static BOOL pt_resolveColorRGBA(UIColor *color,
                                UITraitCollection *traits,
                                CGFloat *outR,
                                CGFloat *outG,
                                CGFloat *outB,
                                CGFloat *outA,
                                CGFloat *outLuma) {
    if (!color) {
        return NO;
    }
    UIColor *resolved = color;
    if (traits && [resolved respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [resolved resolvedColorWithTraitCollection:traits];
    }
    CGFloat r = 0.0, g = 0.0, b = 0.0, alpha = 0.0;
    if (![resolved getRed:&r green:&g blue:&b alpha:&alpha]) {
        CGFloat white = 0.0;
        if ([resolved getWhite:&white alpha:&alpha]) {
            r = white;
            g = white;
            b = white;
        } else {
            return NO;
        }
    }
    CGFloat luma = 0.299 * r + 0.587 * g + 0.114 * b;
    if (outR) { *outR = r; }
    if (outG) { *outG = g; }
    if (outB) { *outB = b; }
    if (outA) { *outA = alpha; }
    if (outLuma) { *outLuma = luma; }
    return YES;
}

static BOOL pt_colorIsBrightLight(UIColor *color, UITraitCollection *traits) {
    CGFloat alpha = 0.0, luma = 0.0;
    if (!pt_resolveColorRGBA(color, traits, NULL, NULL, NULL, &alpha, &luma)) {
        return NO;
    }
    return (alpha > 0.5 && luma > 0.72);
}

static BOOL pt_imageHasBrightForegroundOnTransparent(UIImage *image) {
    if (!image || !image.CGImage) {
        return NO;
    }
    if (image.renderingMode == UIImageRenderingModeAlwaysTemplate || image.isSymbolImage) {
        return NO;
    }
    CGImageRef cg = image.CGImage;
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    if (w < 4 || h < 4) {
        return NO;
    }
    unsigned char pixels[8 * 8 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        return NO;
    }
    CGContextRef ctx = CGBitmapContextCreate(pixels, 8, 8, 8, 8 * 4, cs,
                                             (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return NO;
    }
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 8.0, 8.0), cg);
    CGContextRelease(ctx);

    NSInteger visibleCount = 0;
    NSInteger chromaticCount = 0;
    CGFloat lumaSum = 0.0;
    for (int i = 0; i < 64; i++) {
        int base = i * 4;
        unsigned char a = pixels[base + 3];
        if (a < 20) {
            continue;
        }
        CGFloat alphaF = (CGFloat)a / 255.0;
        CGFloat r = MIN(1.0, ((CGFloat)pixels[base + 0] / 255.0) / alphaF);
        CGFloat g = MIN(1.0, ((CGFloat)pixels[base + 1] / 255.0) / alphaF);
        CGFloat b = MIN(1.0, ((CGFloat)pixels[base + 2] / 255.0) / alphaF);
        CGFloat maxC = MAX(r, MAX(g, b));
        CGFloat minC = MIN(r, MIN(g, b));
        if ((maxC - minC) > 0.16) {
            chromaticCount++;
        }
        lumaSum += (0.299 * r + 0.587 * g + 0.114 * b);
        visibleCount++;
    }
    CGFloat opaqueRatio = (CGFloat)visibleCount / 64.0;
    if (visibleCount == 0 || opaqueRatio >= 0.70 || chromaticCount > MAX(1, visibleCount / 8)) {
        return NO;
    }
    CGFloat avgLuma = lumaSum / (CGFloat)visibleCount;
    return (avgLuma > 0.72);
}

static BOOL pt_subtreeHasBrightForeground(UIView *node,
                                          UITraitCollection *traits,
                                          NSInteger depth,
                                          NSInteger maxDepth,
                                          UIVisualEffectView *originEffectView,
                                          BOOL requireOverlapWithOrigin) {
    if (!node || depth > maxDepth || node.hidden || node.alpha <= 0.01) {
        return NO;
    }
    if (depth > 0 && [node isKindOfClass:[UIVisualEffectView class]]) {
        return NO;
    }
    if (requireOverlapWithOrigin && depth > 0 && originEffectView && originEffectView.superview) {
        CGRect rectInSuper = [node convertRect:node.bounds toView:originEffectView.superview];
        if (!CGRectIntersectsRect(originEffectView.frame, rectInSuper)) {
            return NO;
        }
    }
    if ([node isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)node;
        if (label.text.length > 0 || label.attributedText.length > 0) {
            if (pt_colorIsBrightLight(label.textColor, traits)) {
                return YES;
            }
        }
    } else if ([node isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)node;
        if (iv.image) {
            if (pt_colorIsBrightLight(iv.tintColor, traits)) {
                return YES;
            }
            if (pt_imageHasBrightForegroundOnTransparent(iv.image)) {
                return YES;
            }
        }
    }
    for (UIView *sub in node.subviews) {
        if (sub == originEffectView) {
            continue;
        }
        if (pt_subtreeHasBrightForeground(sub, traits, depth + 1, maxDepth, originEffectView, requireOverlapWithOrigin)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_hasDarkOpaqueAncestorOrLightStatusBar(UIView *view, UITraitCollection *traits) {
    UIView *ancestor = view.superview;
    for (NSInteger depth = 0; ancestor && depth < 6; depth++, ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UIWindow class]]) {
            break;
        }
        id nextResp = ancestor.nextResponder;
        if ([nextResp isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)nextResp;
            if (vc.preferredStatusBarStyle == UIStatusBarStyleLightContent ||
                vc.overrideUserInterfaceStyle == UIUserInterfaceStyleDark) {
                return YES;
            }
        }
        UIColor *bg = ancestor.backgroundColor;
        if (!bg && ancestor.layer.backgroundColor != NULL) {
            bg = [UIColor colorWithCGColor:ancestor.layer.backgroundColor];
        }
        CGFloat alpha = 0.0, luma = 0.0;
        if (pt_resolveColorRGBA(bg, traits, NULL, NULL, NULL, &alpha, &luma)) {
            if (alpha >= 0.65 && luma > 0.65) {
                return NO;
            }
            if (alpha >= 0.55 && luma < 0.22) {
                return YES;
            }
        }
    }
    return NO;
}

static void pt_resolveGlassEffectTint(id glassEffect,
                                      UITraitCollection *traitCollection,
                                      NSInteger *outGlassStyle,
                                      BOOL *outUseDarkMaterial,
                                      UIColor * __autoreleasing *outResolvedTint,
                                      CGFloat *outAlpha,
                                      CGFloat *outLuminance) {
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

    CGFloat alpha = 0.0, luminance = 0.0;
    if (!pt_resolveColorRGBA(resolved, effectiveTraits, NULL, NULL, NULL, &alpha, &luminance)) {
        alpha = 0.0;
        luminance = 0.0;
    }

    BOOL isDarkMode = (effectiveTraits != nil && effectiveTraits.userInterfaceStyle == UIUserInterfaceStyleDark);
    BOOL useDarkMaterial = isDarkMode;
    if (!isDarkMode && alpha >= 0.55 && luminance < 0.35) {
        useDarkMaterial = YES;
    } else if (isDarkMode && alpha >= 0.55 && luminance > 0.65) {
        useDarkMaterial = NO;
    }

    if (outGlassStyle) { *outGlassStyle = glassStyle; }
    if (outUseDarkMaterial) { *outUseDarkMaterial = useDarkMaterial; }
    if (outResolvedTint) { *outResolvedTint = resolved; }
    if (outAlpha) { *outAlpha = alpha; }
    if (outLuminance) { *outLuminance = luminance; }
}

static BOOL pt_powerSavingContextNeedsDarkSurface(UIVisualEffectView *view,
                                                  id effect,
                                                  BOOL isGlass,
                                                  UITraitCollection *traits) {
    UITraitCollection *effectiveTraits = traits ?: [UITraitCollection currentTraitCollection];
    BOOL useDark = (effectiveTraits != nil && effectiveTraits.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (isGlass) {
        BOOL glassDark = NO;
        CGFloat alpha = 0.0, luminance = 0.0;
        pt_resolveGlassEffectTint(effect, effectiveTraits, NULL, &glassDark, NULL, &alpha, &luminance);
        useDark = glassDark || (alpha >= 0.12 && luminance < 0.25);
    } else {
        useDark = pt_isBlurEffectDark((UIBlurEffect *)effect, effectiveTraits);
    }
    if (useDark) {
        return YES;
    }
    if (view && (view.window != nil || view.superview != nil)) {
        if (pt_subtreeHasBrightForeground(view.contentView, effectiveTraits, 0, 5, nil, NO)) {
            return YES;
        }
        if (view.superview && pt_subtreeHasBrightForeground(view.superview, effectiveTraits, 0, 3, view, YES)) {
            return YES;
        }
        if (pt_hasDarkOpaqueAncestorOrLightStatusBar(view, effectiveTraits)) {
            return YES;
        }
    }
    return NO;
}

static UIColor *pt_solidOpaqueColorForEffect(id effect,
                                             BOOL isGlass,
                                             UITraitCollection *traitCollection,
                                             BOOL useDark) {
    if (isGlass) {
        UIColor *resolved = nil;
        CGFloat alpha = 0.0;
        pt_resolveGlassEffectTint(effect, traitCollection, NULL, NULL, &resolved, &alpha, NULL);
        CGFloat baseR = useDark ? 0.15 : 0.94;
        CGFloat baseG = useDark ? 0.15 : 0.94;
        CGFloat baseB = useDark ? 0.17 : 0.96;
        if (resolved && alpha > 0.05) {
            CGFloat tr = 0.0, tg = 0.0, tb = 0.0, ta = 0.0;
            if (pt_resolveColorRGBA(resolved, traitCollection, &tr, &tg, &tb, &ta, NULL)) {
                CGFloat blend = MIN(alpha * 0.24, 0.22);
                baseR = baseR * (1.0 - blend) + tr * blend;
                baseG = baseG * (1.0 - blend) + tg * blend;
                baseB = baseB * (1.0 - blend) + tb * blend;
            }
        }
        return [UIColor colorWithRed:baseR green:baseG blue:baseB alpha:1.0];
    }

    return useDark
        ? [UIColor colorWithRed:0.14 green:0.14 blue:0.16 alpha:1.0]
        : [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
}

static void pt_clearGlassOverlayIfNeeded(UIVisualEffectView *view) {
    if (objc_getAssociatedObject(view, kPTAppliedGlassOverlayKey) != nil) {
        view.contentView.backgroundColor = nil;
        objc_setAssociatedObject(view, kPTAppliedGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void pt_applyPowerSavingSolidBackground(UIVisualEffectView *view,
                                               id effect,
                                               BOOL isGlass,
                                               UITraitCollection *traitCollection) {
    pt_clearGlassOverlayIfNeeded(view);
    if (objc_getAssociatedObject(view, kPTAppliedPowerSaveSolidBgKey) == nil) {
        objc_setAssociatedObject(view, kPTAppliedPowerSaveOrigOpaqueKey, @(view.opaque), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kPTAppliedPowerSaveSolidBgKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL useDark = pt_powerSavingContextNeedsDarkSurface(view, effect, isGlass, traitCollection);
    NSNumber *prevDark = objc_getAssociatedObject(view, kPTAppliedPowerSaveIsDarkKey);
    if (prevDark != nil && prevDark.boolValue == useDark && view.backgroundColor != nil && view.opaque) {
        return;
    }
    objc_setAssociatedObject(view, kPTAppliedPowerSaveIsDarkKey, @(useDark), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.backgroundColor = pt_solidOpaqueColorForEffect(effect, isGlass, traitCollection, useDark);
    view.opaque = YES;
}

static void pt_clearPowerSavingSolidBackgroundIfNeeded(UIVisualEffectView *view) {
    if (objc_getAssociatedObject(view, kPTAppliedPowerSaveSolidBgKey) != nil) {
        NSNumber *origOpaque = objc_getAssociatedObject(view, kPTAppliedPowerSaveOrigOpaqueKey);
        view.backgroundColor = nil;
        view.opaque = origOpaque ? origOpaque.boolValue : NO;
        objc_setAssociatedObject(view, kPTAppliedPowerSaveSolidBgKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kPTAppliedPowerSaveOrigOpaqueKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kPTAppliedPowerSaveIsDarkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIBlurEffect *pt_fallbackBlurEffectForGlassEffect(id glassEffect,
                                                          UITraitCollection *traitCollection,
                                                          UIColor * __autoreleasing *outTintOverlay) {
    NSInteger glassStyle = 0;
    BOOL useDarkMaterial = NO;
    UIColor *resolved = nil;
    CGFloat alpha = 0.0;
    CGFloat luminance = 0.0;
    pt_resolveGlassEffectTint(glassEffect, traitCollection, &glassStyle, &useDarkMaterial, &resolved, &alpha, &luminance);

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
    objc_setAssociatedObject(view, kPTAppliedGlassStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

    NSNumber *powerSaveDark = (pt_powerSavingMaterialEnabled && objc_getAssociatedObject(view, kPTAppliedPowerSaveSolidBgKey) != nil)
        ? objc_getAssociatedObject(view, kPTAppliedPowerSaveIsDarkKey)
        : nil;
    BOOL isDark = powerSaveDark ? powerSaveDark.boolValue : (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSValue *prevVal = objc_getAssociatedObject(view, kPTAppliedGlassStateKey);
    if (prevVal) {
        PTGlassLayoutState prev;
        [prevVal getValue:&prev];
        if (fabs(prev.w - bounds.size.width) <= 0.1 &&
            fabs(prev.h - bounds.size.height) <= 0.1 &&
            fabs(prev.maxR - maxR) <= 0.1 &&
            prev.mask == mask &&
            prev.isDark == isDark) {
            return;
        }
    }
    PTGlassLayoutState current = { bounds.size.width, bounds.size.height, maxR, mask, isDark };
    objc_setAssociatedObject(view, kPTAppliedGlassStateKey,
                             [NSValue valueWithBytes:&current objCType:@encode(PTGlassLayoutState)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
    BOOL isBlur = (!isGlass && effect != nil && [effect isKindOfClass:[UIBlurEffect class]] && ![effect isKindOfClass:[UIVibrancyEffect class]]);
    if (!isGlass && (!pt_powerSavingMaterialEnabled || !isBlur)) {
        return pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, effect) : nil;
    }
    UITraitCollection *currentTraits = [UITraitCollection currentTraitCollection];
    if (pt_powerSavingMaterialEnabled) {
        id instance = pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, nil) : nil;
        if (instance) {
            UIVisualEffectView *effectView = (UIVisualEffectView *)instance;
            UITraitCollection *effectiveTraits = effectView.traitCollection ?: currentTraits;
            if (isGlass) {
                objc_setAssociatedObject(effectView, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(effectView, kPTAppliedPowerSaveBlurEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                pt_applyPowerSavingSolidBackground(effectView, effect, YES, effectiveTraits);
                pt_updateGlassGeometryAndRim(effectView);
            } else {
                objc_setAssociatedObject(effectView, kPTAppliedPowerSaveBlurEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(effectView, kPTAppliedGlassEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                pt_applyPowerSavingSolidBackground(effectView, effect, NO, effectiveTraits);
            }
        }
        return instance;
    }

    UIColor *overlay = nil;
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(effect, currentTraits, &overlay);
    id instance = pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, fallback) : nil;
    if (instance) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)instance;
        objc_setAssociatedObject(effectView, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor *effectiveOverlay = overlay;
        if (effectView.traitCollection.userInterfaceStyle != currentTraits.userInterfaceStyle) {
            UIColor *resolvedOverlay = nil;
            UIBlurEffect *resolvedFallback = pt_fallbackBlurEffectForGlassEffect(effect, effectView.traitCollection, &resolvedOverlay);
            if (pt_origVisualEffectSetEffect) {
                pt_origVisualEffectSetEffect(effectView, @selector(setEffect:), resolvedFallback);
            }
            effectiveOverlay = resolvedOverlay ?: overlay;
        }
        pt_applyGlassFallbackAppearance(effectView, effectiveOverlay);
        pt_updateGlassGeometryAndRim(effectView);
    }
    return instance;
}

static void pt_visualEffectSetEffect(UIVisualEffectView *self, SEL _cmd, id effect) {
    BOOL isGlass = (pt_glassEffectClass != Nil && effect != nil && [effect isKindOfClass:pt_glassEffectClass]);
    BOOL isBlur = (!isGlass && effect != nil && [effect isKindOfClass:[UIBlurEffect class]] && ![effect isKindOfClass:[UIVibrancyEffect class]]);
    if (!isGlass && (!pt_powerSavingMaterialEnabled || !isBlur)) {
        objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kPTAppliedPowerSaveBlurEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_clearGlassOverlayIfNeeded(self);
        pt_clearPowerSavingSolidBackgroundIfNeeded(self);
        pt_removeGlassDecorationLayers(self);
        if (pt_origVisualEffectSetEffect) {
            pt_origVisualEffectSetEffect(self, _cmd, effect);
        }
        return;
    }
    if (pt_powerSavingMaterialEnabled) {
        objc_setAssociatedObject(self, kPTAppliedPowerSaveIsDarkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isGlass) {
            objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kPTAppliedPowerSaveBlurEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (pt_origVisualEffectSetEffect) {
                pt_origVisualEffectSetEffect(self, _cmd, nil);
            }
            pt_applyPowerSavingSolidBackground(self, effect, YES, self.traitCollection);
            pt_updateGlassGeometryAndRim(self);
        } else {
            objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pt_removeGlassDecorationLayers(self);
            objc_setAssociatedObject(self, kPTAppliedPowerSaveBlurEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (pt_origVisualEffectSetEffect) {
                pt_origVisualEffectSetEffect(self, _cmd, nil);
            }
            pt_applyPowerSavingSolidBackground(self, effect, NO, self.traitCollection);
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
    id blurEffect = objc_getAssociatedObject(self, kPTAppliedPowerSaveBlurEffectKey);
    if (!glassEffect && !blurEffect) {
        return;
    }
    if (previousTraitCollection &&
        previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) {
        return;
    }
    if (pt_powerSavingMaterialEnabled) {
        objc_setAssociatedObject(self, kPTAppliedPowerSaveIsDarkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (glassEffect) {
            pt_applyPowerSavingSolidBackground(self, glassEffect, YES, self.traitCollection);
            pt_updateGlassGeometryAndRim(self);
        } else if (blurEffect) {
            pt_applyPowerSavingSolidBackground(self, blurEffect, NO, self.traitCollection);
        }
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

static void pt_refreshPowerSavingVisualEffectAppearanceIfNeeded(UIVisualEffectView *view) {
    if (!pt_powerSavingMaterialEnabled || !view || (!view.window && !view.superview)) {
        return;
    }
    if (objc_getAssociatedObject(view, kPTAppliedPowerSaveSolidBgKey) == nil) {
        return;
    }
    id glassEffect = objc_getAssociatedObject(view, kPTAppliedGlassEffectKey);
    id blurEffect = objc_getAssociatedObject(view, kPTAppliedPowerSaveBlurEffectKey);
    if (glassEffect) {
        pt_applyPowerSavingSolidBackground(view, glassEffect, YES, view.traitCollection);
        pt_updateGlassGeometryAndRim(view);
    } else if (blurEffect) {
        pt_applyPowerSavingSolidBackground(view, blurEffect, NO, view.traitCollection);
    }
}

static void pt_visualEffectLayoutSubviews(UIVisualEffectView *self, SEL _cmd) {
    if (pt_origVisualEffectLayoutSubviews) {
        pt_origVisualEffectLayoutSubviews(self, _cmd);
    }
    pt_refreshPowerSavingVisualEffectAppearanceIfNeeded(self);
    if (objc_getAssociatedObject(self, kPTAppliedGlassEffectKey) != nil) {
        pt_updateGlassGeometryAndRim(self);
    }
}

static void pt_visualEffectDidMoveToWindow(UIVisualEffectView *self, SEL _cmd) {
    if (pt_origVisualEffectDidMoveToWindow) {
        pt_origVisualEffectDidMoveToWindow(self, _cmd);
    }
    pt_refreshPowerSavingVisualEffectAppearanceIfNeeded(self);
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
    pt_powerSavingMaterialEnabled = pt_isPowerSavingModeEnabled();

    // On Mac Catalyst, UIGlassEffect views can fail to create backdrop sublayers and fall back to
    // an opaque white fill. Map UIGlassEffect to native UIBlurEffect materials preserving tint polarity,
    // continuous corner configuration radii, and a lightweight specular rim/sheen.
    // When Power Saving Mode is active, downgrade both UIGlassEffect and UIBlurEffect to opaque solid colors.
    pt_glassEffectClass = NSClassFromString(@"UIGlassEffect");
    Class effectViewCls = objc_getClass("UIVisualEffectView");
    if (!effectViewCls || (!pt_glassEffectClass && !pt_powerSavingMaterialEnabled)) {
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

    Method moveWinM = class_getInstanceMethod(effectViewCls, @selector(didMoveToWindow));
    if (moveWinM) {
        IMP origImp = method_getImplementation(moveWinM);
        if (origImp != (IMP)pt_visualEffectDidMoveToWindow) {
            pt_origVisualEffectDidMoveToWindow = (void (*)(id, SEL))origImp;
            class_replaceMethod(effectViewCls, @selector(didMoveToWindow),
                                (IMP)pt_visualEffectDidMoveToWindow, method_getTypeEncoding(moveWinM));
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
static id (*pt_origWindowInitWithFrame)(UIWindow *, SEL, CGRect) = NULL;
static id (*pt_origWindowInitWithWindowScene)(UIWindow *, SEL, UIWindowScene *) = NULL;
static void (*pt_origWindowBecomeKeyWindow)(UIWindow *, SEL) = NULL;
static UIUserInterfaceStyle pt_forcedWindowUIStyle = UIUserInterfaceStyleUnspecified;
static BOOL pt_appearanceReentrancyGuardInstalled = NO;

static UIUserInterfaceStyle pt_configuredOverrideUserInterfaceStyle(void) {
    const char *disable = getenv("PT_DISABLE_APPEARANCE_OVERRIDE");
    if (disable && disable[0] == '1' && disable[1] == '\0') {
        return UIUserInterfaceStyleUnspecified;
    }
    NSInteger style = [[PlaySettings shared] appearanceStyle];
    if (style == 1) {
        return UIUserInterfaceStyleLight;
    }
    if (style == 2) {
        return UIUserInterfaceStyleDark;
    }
    return UIUserInterfaceStyleUnspecified;
}

static void pt_applyForcedAppearanceToWindowIfNeeded(UIWindow *window) {
    if (pt_forcedWindowUIStyle == UIUserInterfaceStyleUnspecified || !window) {
        return;
    }
    if (window.overrideUserInterfaceStyle != pt_forcedWindowUIStyle) {
        if (pt_origWindowSetOverrideUserInterfaceStyle) {
            pt_origWindowSetOverrideUserInterfaceStyle(window, @selector(setOverrideUserInterfaceStyle:), pt_forcedWindowUIStyle);
        } else {
            window.overrideUserInterfaceStyle = pt_forcedWindowUIStyle;
        }
    }
}

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
    UIUserInterfaceStyle targetStyle = (pt_forcedWindowUIStyle != UIUserInterfaceStyleUnspecified)
        ? pt_forcedWindowUIStyle
        : style;
    if (pt_systemAppearanceUpdateDepth > 0 && [NSThread isMainThread]) {
        if (self.overrideUserInterfaceStyle == targetStyle) {
            return;
        }
        __weak UIWindow *weakWin = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = weakWin;
            if (win && win.overrideUserInterfaceStyle != targetStyle && pt_origWindowSetOverrideUserInterfaceStyle) {
                pt_origWindowSetOverrideUserInterfaceStyle(win, _cmd, targetStyle);
            }
        });
        return;
    }
    if (pt_origWindowSetOverrideUserInterfaceStyle) {
        pt_origWindowSetOverrideUserInterfaceStyle(self, _cmd, targetStyle);
    }
}

static id pt_windowInitWithFrame(UIWindow *self, SEL _cmd, CGRect frame) {
    id instance = pt_origWindowInitWithFrame ? pt_origWindowInitWithFrame(self, _cmd, frame) : nil;
    if (instance) {
        pt_applyForcedAppearanceToWindowIfNeeded((UIWindow *)instance);
    }
    return instance;
}

static id pt_windowInitWithWindowScene(UIWindow *self, SEL _cmd, UIWindowScene *windowScene) {
    id instance = pt_origWindowInitWithWindowScene ? pt_origWindowInitWithWindowScene(self, _cmd, windowScene) : nil;
    if (instance) {
        pt_applyForcedAppearanceToWindowIfNeeded((UIWindow *)instance);
    }
    return instance;
}

static void pt_windowBecomeKeyWindow(UIWindow *self, SEL _cmd) {
    pt_applyForcedAppearanceToWindowIfNeeded(self);
    if (pt_origWindowBecomeKeyWindow) {
        pt_origWindowBecomeKeyWindow(self, _cmd);
    }
}

static void pt_installWindowAppearanceReentrancyGuard(void) {
    if (pt_appearanceReentrancyGuardInstalled) {
        return;
    }
    pt_appearanceReentrancyGuardInstalled = YES;
    pt_forcedWindowUIStyle = pt_configuredOverrideUserInterfaceStyle();

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

    if (uiWin && pt_forcedWindowUIStyle != UIUserInterfaceStyleUnspecified) {
        Method initFrameM = class_getInstanceMethod(uiWin, @selector(initWithFrame:));
        if (initFrameM) {
            IMP origImp = method_getImplementation(initFrameM);
            if (origImp != (IMP)pt_windowInitWithFrame) {
                pt_origWindowInitWithFrame = (id (*)(UIWindow *, SEL, CGRect))origImp;
                class_replaceMethod(uiWin, @selector(initWithFrame:), (IMP)pt_windowInitWithFrame, method_getTypeEncoding(initFrameM));
            }
        }
        Method initSceneM = class_getInstanceMethod(uiWin, @selector(initWithWindowScene:));
        if (initSceneM) {
            IMP origImp = method_getImplementation(initSceneM);
            if (origImp != (IMP)pt_windowInitWithWindowScene) {
                pt_origWindowInitWithWindowScene = (id (*)(UIWindow *, SEL, UIWindowScene *))origImp;
                class_replaceMethod(uiWin, @selector(initWithWindowScene:), (IMP)pt_windowInitWithWindowScene, method_getTypeEncoding(initSceneM));
            }
        }
        Method becomeKeyM = class_getInstanceMethod(uiWin, @selector(becomeKeyWindow));
        if (becomeKeyM) {
            IMP origImp = method_getImplementation(becomeKeyM);
            if (origImp != (IMP)pt_windowBecomeKeyWindow) {
                pt_origWindowBecomeKeyWindow = (void (*)(UIWindow *, SEL))origImp;
                class_replaceMethod(uiWin, @selector(becomeKeyWindow), (IMP)pt_windowBecomeKeyWindow, method_getTypeEncoding(becomeKeyM));
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            for (UIScene *scene in app.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                        pt_applyForcedAppearanceToWindowIfNeeded(win);
                    }
                }
            }
            for (UIWindow *win in app.windows) {
                pt_applyForcedAppearanceToWindowIfNeeded(win);
            }
        });
    }
}
#endif

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    pt_installGlassEffectCompatibilityGuard();
    Class efficiencyHooksCls = NSClassFromString(@"PTEfficiencyHooks");
    SEL efficiencyInstallSel = NSSelectorFromString(@"installIfNeeded");
    if (efficiencyHooksCls && [efficiencyHooksCls respondsToSelector:efficiencyInstallSel]) {
        ((void (*)(id, SEL))objc_msgSend)(efficiencyHooksCls, efficiencyInstallSel);
    }
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
