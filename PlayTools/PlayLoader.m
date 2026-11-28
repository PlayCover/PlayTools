//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
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

static void (*pt_origTabBarLayoutSubviews)(id, SEL) = NULL;
static void (*pt_origTabBarSetSelectedItem)(id, SEL, UITabBarItem *) = NULL;
static BOOL pt_customTabBarPlatterGuardInstalled = NO;
static const void *kPTCustomTabBarHiddenPlattersKey = &kPTCustomTabBarHiddenPlattersKey;
static const void *kPTCustomTabBarPlatterDeferredKey = &kPTCustomTabBarPlatterDeferredKey;

static BOOL pt_isSystemTabBarSubviewClassName(NSString *clsName) {
    if (clsName.length == 0) {
        return YES;
    }
    if ([clsName hasPrefix:@"_Tt"]) {
        return [clsName containsString:@"UIKit"] || [clsName containsString:@"SwiftUI"];
    }
    return [clsName hasPrefix:@"UI"] ||
           [clsName hasPrefix:@"_UI"] ||
           [clsName hasPrefix:@"NS"] ||
           [clsName hasPrefix:@"CA"];
}

static BOOL pt_isTabBarPlatterClassName(NSString *clsName) {
    if (clsName.length == 0) {
        return NO;
    }
    return [clsName containsString:@"_UITabBarItemPlatterView"] ||
           [clsName containsString:@"_UITabBarPlatterView"] ||
           [clsName containsString:@"_UILiquidLensView"];
}

static BOOL pt_isVisuallyEmptyTabBarImage(UIImage *image) {
    if (!image) {
        return YES;
    }
    CGSize size = image.size;
    if (!isfinite(size.width) || !isfinite(size.height)) {
        return YES;
    }
    return size.width <= 2.0 && size.height <= 2.0;
}

static BOOL pt_tabBarItemsAreEmpty(UITabBar *tabBar) {
    NSArray<UITabBarItem *> *items = tabBar.items;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (UITabBarItem *item in items) {
        if ([item.title stringByTrimmingCharactersInSet:ws].length > 0) {
            return NO;
        }
        if (!pt_isVisuallyEmptyTabBarImage(item.image) ||
            !pt_isVisuallyEmptyTabBarImage(item.selectedImage)) {
            return NO;
        }
    }
    return YES;
}

typedef struct {
    CGFloat x0;
    CGFloat x1;
} PTCustomTabBarSpan;

static BOOL pt_tabBarHasCustomReplacementSubviews(UITabBar *tabBar) {
    CGFloat width = CGRectGetWidth(tabBar.bounds);
    if (width <= 1.0) {
        return NO;
    }

    enum { kPTMaxCustomTabSpans = 32 };
    PTCustomTabBarSpan spans[kPTMaxCustomTabSpans];
    NSUInteger spanCount = 0;
    NSUInteger customCount = 0;
    CGFloat minX = width;
    CGFloat maxX = 0.0;

    for (UIView *subview in tabBar.subviews) {
        if (subview.hidden || subview.alpha <= 0.01) {
            continue;
        }
        NSString *clsName = NSStringFromClass([subview class]);
        if (pt_isSystemTabBarSubviewClassName(clsName) ||
            pt_isTabBarPlatterClassName(clsName)) {
            continue;
        }
        CGRect frame = subview.frame;
        if (CGRectGetHeight(frame) < 28.0) {
            continue;
        }
        CGFloat x0 = MAX(0.0, CGRectGetMinX(frame));
        CGFloat x1 = MIN(width, CGRectGetMaxX(frame));
        CGFloat clampedW = x1 - x0;
        if (clampedW >= width * 0.75) {
            return YES;
        }
        if (clampedW >= 20.0) {
            customCount++;
            if (x0 < minX) {
                minX = x0;
            }
            if (x1 > maxX) {
                maxX = x1;
            }
            if (spanCount < kPTMaxCustomTabSpans) {
                spans[spanCount++] = (PTCustomTabBarSpan){ x0, x1 };
            }
        }
    }

    if (customCount < 2 || spanCount == 0) {
        return NO;
    }

    for (NSUInteger i = 1; i < spanCount; i++) {
        PTCustomTabBarSpan key = spans[i];
        NSUInteger j = i;
        while (j > 0 && spans[j - 1].x0 > key.x0) {
            spans[j] = spans[j - 1];
            j--;
        }
        spans[j] = key;
    }

    CGFloat coveredWidth = 0.0;
    CGFloat curStart = spans[0].x0;
    CGFloat curEnd = spans[0].x1;
    for (NSUInteger i = 1; i < spanCount; i++) {
        if (spans[i].x0 <= curEnd) {
            if (spans[i].x1 > curEnd) {
                curEnd = spans[i].x1;
            }
        } else {
            coveredWidth += (curEnd - curStart);
            curStart = spans[i].x0;
            curEnd = spans[i].x1;
        }
    }
    coveredWidth += (curEnd - curStart);

    return coveredWidth >= width * 0.50 ||
           (customCount >= 3 && (maxX - minX) >= width * 0.55);
}

// On modern iOS / Mac Catalyst, _UITabBarVisualProvider_Floating still installs a floating
// _UITabBarItemPlatterView/_UILiquidLensView selection pill even when an app replaces
// UITabBar with a full-width custom subview (or multiple per-item custom buttons)
// and leaves all native UITabBarItems empty.
static void pt_updateCustomTabBarPlatterVisibilityInternal(UITabBar *tabBar, BOOL allowDeferred) {
    CGFloat width = CGRectGetWidth(tabBar.bounds);
    CGFloat height = CGRectGetHeight(tabBar.bounds);
    if (width <= 1.0 || height <= 1.0) {
        return;
    }

    BOOL itemsEmpty = pt_tabBarItemsAreEmpty(tabBar);
    BOOL shouldHidePlatter = itemsEmpty && pt_tabBarHasCustomReplacementSubviews(tabBar);
    NSHashTable<UIView *> *hiddenPlatters = objc_getAssociatedObject(tabBar, kPTCustomTabBarHiddenPlattersKey);

    if (shouldHidePlatter) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (UIView *subview in tabBar.subviews) {
            NSString *clsName = NSStringFromClass([subview class]);
            if (pt_isTabBarPlatterClassName(clsName)) {
                if (!subview.hidden) {
                    subview.hidden = YES;
                }
                if (!hiddenPlatters) {
                    hiddenPlatters = [NSHashTable weakObjectsHashTable];
                    objc_setAssociatedObject(tabBar, kPTCustomTabBarHiddenPlattersKey,
                                             hiddenPlatters, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                [hiddenPlatters addObject:subview];
            }
        }
        [CATransaction commit];
    } else {
        if (hiddenPlatters.count > 0) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            for (UIView *platter in hiddenPlatters) {
                if (platter.superview == tabBar && platter.hidden) {
                    platter.hidden = NO;
                }
            }
            objc_setAssociatedObject(tabBar, kPTCustomTabBarHiddenPlattersKey,
                                     nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [CATransaction commit];
        }
        if (allowDeferred && itemsEmpty &&
            objc_getAssociatedObject(tabBar, kPTCustomTabBarPlatterDeferredKey) == nil) {
            BOOL hasVisiblePlatter = NO;
            for (UIView *subview in tabBar.subviews) {
                if (!subview.hidden && pt_isTabBarPlatterClassName(NSStringFromClass([subview class]))) {
                    hasVisiblePlatter = YES;
                    break;
                }
            }
            if (hasVisiblePlatter) {
                objc_setAssociatedObject(tabBar, kPTCustomTabBarPlatterDeferredKey,
                                         @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UITabBar *weakTabBar = tabBar;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UITabBar *strongTabBar = weakTabBar;
                    if (!strongTabBar) {
                        return;
                    }
                    objc_setAssociatedObject(strongTabBar, kPTCustomTabBarPlatterDeferredKey,
                                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    pt_updateCustomTabBarPlatterVisibilityInternal(strongTabBar, NO);
                });
            }
        }
    }
}

static void pt_updateCustomTabBarPlatterVisibility(UITabBar *tabBar) {
    pt_updateCustomTabBarPlatterVisibilityInternal(tabBar, YES);
}

static void pt_tabBarLayoutSubviews(UITabBar *self, SEL _cmd) {
    if (pt_origTabBarLayoutSubviews) {
        pt_origTabBarLayoutSubviews(self, _cmd);
    }
    pt_updateCustomTabBarPlatterVisibility(self);
}

static void pt_tabBarSetSelectedItem(UITabBar *self, SEL _cmd, UITabBarItem *item) {
    if (pt_origTabBarSetSelectedItem) {
        pt_origTabBarSetSelectedItem(self, _cmd, item);
    }
    pt_updateCustomTabBarPlatterVisibility(self);
}

static void pt_installCustomTabBarPlatterGuard(void) {
    if (pt_customTabBarPlatterGuardInstalled) {
        return;
    }
    pt_customTabBarPlatterGuardInstalled = YES;

    Class tabBarCls = objc_getClass("UITabBar");
    if (!tabBarCls) {
        return;
    }

    Method layoutM = class_getInstanceMethod(tabBarCls, @selector(layoutSubviews));
    if (layoutM) {
        IMP origImp = method_getImplementation(layoutM);
        if (origImp != (IMP)pt_tabBarLayoutSubviews) {
            pt_origTabBarLayoutSubviews = (void (*)(id, SEL))origImp;
            class_replaceMethod(tabBarCls, @selector(layoutSubviews),
                                (IMP)pt_tabBarLayoutSubviews, method_getTypeEncoding(layoutM));
        }
    }

    Method selectedItemM = class_getInstanceMethod(tabBarCls, @selector(setSelectedItem:));
    if (selectedItemM) {
        IMP origImp = method_getImplementation(selectedItemM);
        if (origImp != (IMP)pt_tabBarSetSelectedItem) {
            pt_origTabBarSetSelectedItem = (void (*)(id, SEL, UITabBarItem *))origImp;
            class_replaceMethod(tabBarCls, @selector(setSelectedItem:),
                                (IMP)pt_tabBarSetSelectedItem, method_getTypeEncoding(selectedItemM));
        }
    }
}

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    pt_installCustomTabBarPlatterGuard();
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
