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

#if TARGET_OS_MACCATALYST
typedef id (*pt_msc_load_html_fn)(id, SEL, NSString *, NSURL *);
static pt_msc_load_html_fn pt_origMSCLoadHTML = NULL;
static NSString *const kPTMSCMouseTouchMarker = @"__ptMscMouseTouchBridgeInstalled";

static NSString *pt_mscMouseTouchBridgeSource(void) {
    return
        @"(function(){\n"
        @"  if (window.top !== window || location.protocol !== 'mscfile:' || window.__ptMscMouseTouchBridgeInstalled) return;\n"
        @"  window.__ptMscMouseTouchBridgeInstalled = true;\n"
        @"  var active = null;\n"
        @"  var pendingDedup = null;\n"
        @"  var nextId = 1;\n"
        @"  function clearPendingDedup() {\n"
        @"    if (!pendingDedup) return;\n"
        @"    clearTimeout(pendingDedup.timer);\n"
        @"    pendingDedup = null;\n"
        @"  }\n"
        @"  function isMatchingMouseClick(e, dedup) {\n"
        @"    if (!e || !e.isTrusted || !dedup) return false;\n"
        @"    if (e.button !== 0 || !(e.detail > 0)) return false;\n"
        @"    if (e.pointerType !== 'mouse') return false;\n"
        @"    if (typeof e.pointerId !== 'number' || e.pointerId !== dedup.pointerId) return false;\n"
        @"    var dt = dedup.target;\n"
        @"    var et = e.target;\n"
        @"    return et === dt || (dt && dt.contains && dt.contains(et)) || (et && et.contains && et.contains(dt));\n"
        @"  }\n"
        @"  function makeTouch(target, id, src) {\n"
        @"    try {\n"
        @"      return new Touch({\n"
        @"        identifier: id,\n"
        @"        target: target,\n"
        @"        clientX: src.clientX,\n"
        @"        clientY: src.clientY,\n"
        @"        pageX: src.pageX,\n"
        @"        pageY: src.pageY,\n"
        @"        screenX: src.screenX,\n"
        @"        screenY: src.screenY,\n"
        @"        radiusX: 1,\n"
        @"        radiusY: 1,\n"
        @"        force: 1\n"
        @"      });\n"
        @"    } catch (err) {\n"
        @"      return null;\n"
        @"    }\n"
        @"  }\n"
        @"  function dispatchTouch(type, target, activeList, changedTouch) {\n"
        @"    if (!target || !changedTouch) return true;\n"
        @"    try {\n"
        @"      var te = new TouchEvent(type, {\n"
        @"        bubbles: true,\n"
        @"        cancelable: type !== 'touchcancel',\n"
        @"        composed: true,\n"
        @"        view: window,\n"
        @"        touches: activeList,\n"
        @"        targetTouches: activeList,\n"
        @"        changedTouches: [changedTouch]\n"
        @"      });\n"
        @"      return target.dispatchEvent(te);\n"
        @"    } catch (err) {\n"
        @"      return true;\n"
        @"    }\n"
        @"  }\n"
        @"  function cancelActive() {\n"
        @"    clearPendingDedup();\n"
        @"    if (!active) return;\n"
        @"    var cur = active;\n"
        @"    active = null;\n"
        @"    var t = makeTouch(cur.target, cur.identifier, cur);\n"
        @"    dispatchTouch('touchcancel', cur.target, [], t);\n"
        @"  }\n"
        @"  window.addEventListener('pointerdown', function(e) {\n"
        @"    if (!e.isTrusted || e.pointerType !== 'mouse' || e.button !== 0 || (e.buttons & 1) === 0) return;\n"
        @"    cancelActive();\n"
        @"    var target = (e.target && e.target.nodeType === 1) ? e.target : (e.target && e.target.parentElement ? e.target.parentElement : document.body);\n"
        @"    if (!target) return;\n"
        @"    var id = nextId++;\n"
        @"    var t = makeTouch(target, id, e);\n"
        @"    if (!t) return;\n"
        @"    active = {\n"
        @"      pointerId: e.pointerId,\n"
        @"      target: target,\n"
        @"      identifier: id,\n"
        @"      clientX: e.clientX,\n"
        @"      clientY: e.clientY,\n"
        @"      pageX: e.pageX,\n"
        @"      pageY: e.pageY,\n"
        @"      screenX: e.screenX,\n"
        @"      screenY: e.screenY,\n"
        @"      prevented: false\n"
        @"    };\n"
        @"    var allowed = dispatchTouch('touchstart', target, [t], t);\n"
        @"    if (active && active.pointerId === e.pointerId) {\n"
        @"      active.prevented = !allowed;\n"
        @"    }\n"
        @"  }, true);\n"
        @"  window.addEventListener('pointermove', function(e) {\n"
        @"    if (!active || !e.isTrusted || e.pointerType !== 'mouse' || e.pointerId !== active.pointerId) return;\n"
        @"    if ((e.buttons & 1) === 0) { cancelActive(); return; }\n"
        @"    active.clientX = e.clientX; active.clientY = e.clientY;\n"
        @"    active.pageX = e.pageX; active.pageY = e.pageY;\n"
        @"    active.screenX = e.screenX; active.screenY = e.screenY;\n"
        @"    var t = makeTouch(active.target, active.identifier, active);\n"
        @"    dispatchTouch('touchmove', active.target, t ? [t] : [], t);\n"
        @"  }, true);\n"
        @"  window.addEventListener('pointerup', function(e) {\n"
        @"    if (!active || !e.isTrusted || e.pointerType !== 'mouse' || e.pointerId !== active.pointerId) return;\n"
        @"    var cur = active;\n"
        @"    active = null;\n"
        @"    cur.clientX = e.clientX; cur.clientY = e.clientY;\n"
        @"    cur.pageX = e.pageX; cur.pageY = e.pageY;\n"
        @"    cur.screenX = e.screenX; cur.screenY = e.screenY;\n"
        @"    var t = makeTouch(cur.target, cur.identifier, cur);\n"
        @"    var endAllowed = dispatchTouch('touchend', cur.target, [], t);\n"
        @"    if (cur.prevented || !endAllowed) {\n"
        @"      clearPendingDedup();\n"
        @"      pendingDedup = { pointerId: cur.pointerId, target: cur.target, timer: setTimeout(clearPendingDedup, 0) };\n"
        @"    }\n"
        @"  }, true);\n"
        @"  window.addEventListener('click', function(e) {\n"
        @"    if (!isMatchingMouseClick(e, pendingDedup)) return;\n"
        @"    e.preventDefault();\n"
        @"    e.stopPropagation();\n"
        @"    clearPendingDedup();\n"
        @"  }, true);\n"
        @"  window.addEventListener('keydown', clearPendingDedup, true);\n"
        @"  window.addEventListener('pointercancel', function(e) {\n"
        @"    if (active && e.isTrusted && e.pointerType === 'mouse' && e.pointerId === active.pointerId) {\n"
        @"      cancelActive();\n"
        @"    }\n"
        @"  }, true);\n"
        @"  window.addEventListener('blur', cancelActive);\n"
        @"  document.addEventListener('visibilitychange', function() {\n"
        @"    if (document.hidden) cancelActive();\n"
        @"  });\n"
        @"})();";
}

static id pt_mscWebViewLoadHTMLString(id self, SEL _cmd, NSString *html, NSURL *baseURL) {
    if ([baseURL.scheme isEqualToString:@"mscfile"]) {
        Class userScriptCls = NSClassFromString(@"WKUserScript");
        SEL cfgSel = NSSelectorFromString(@"configuration");
        SEL uccSel = NSSelectorFromString(@"userContentController");
        SEL scriptsSel = NSSelectorFromString(@"userScripts");
        SEL sourceSel = NSSelectorFromString(@"source");
        SEL initScriptSel = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
        SEL addScriptSel = NSSelectorFromString(@"addUserScript:");
        if (userScriptCls && [self respondsToSelector:cfgSel]) {
            id cfg = ((id (*)(id, SEL))objc_msgSend)(self, cfgSel);
            id ucc = (cfg && [cfg respondsToSelector:uccSel]) ? ((id (*)(id, SEL))objc_msgSend)(cfg, uccSel) : nil;
            if (ucc && [ucc respondsToSelector:addScriptSel]) {
                BOOL alreadyInstalled = NO;
                if ([ucc respondsToSelector:scriptsSel]) {
                    NSArray *existing = ((id (*)(id, SEL))objc_msgSend)(ucc, scriptsSel);
                    for (id s in existing) {
                        if ([s respondsToSelector:sourceSel]) {
                            NSString *src = ((id (*)(id, SEL))objc_msgSend)(s, sourceSel);
                            if ([src isKindOfClass:[NSString class]] && [src containsString:kPTMSCMouseTouchMarker]) {
                                alreadyInstalled = YES;
                                break;
                            }
                        }
                    }
                }
                if (!alreadyInstalled) {
                    id script = ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
                        [userScriptCls alloc],
                        initScriptSel,
                        pt_mscMouseTouchBridgeSource(),
                        (NSInteger)0,
                        YES);
                    if (script) {
                        ((void (*)(id, SEL, id))objc_msgSend)(ucc, addScriptSel, script);
                    }
                }
            }
        }
    }
    return pt_origMSCLoadHTML ? pt_origMSCLoadHTML(self, _cmd, html, baseURL) : nil;
}

static void pt_installMSCMouseTouchCompatibility(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class mscCls = NSClassFromString(@"MSCWebView");
        Class userScriptCls = NSClassFromString(@"WKUserScript");
        if (!mscCls || !userScriptCls) {
            return;
        }
        SEL sel = NSSelectorFromString(@"loadHTMLString:baseURL:");
        Method m = class_getInstanceMethod(mscCls, sel);
        if (!m) {
            return;
        }
        IMP origImp = method_getImplementation(m);
        if (origImp == (IMP)pt_mscWebViewLoadHTMLString) {
            return;
        }
        pt_origMSCLoadHTML = (pt_msc_load_html_fn)origImp;
        if (!class_addMethod(mscCls, sel, (IMP)pt_mscWebViewLoadHTMLString, method_getTypeEncoding(m))) {
            pt_origMSCLoadHTML = (pt_msc_load_html_fn)method_setImplementation(m, (IMP)pt_mscWebViewLoadHTMLString);
        }
    });
}
#endif

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
#if TARGET_OS_MACCATALYST
    pt_installMSCMouseTouchCompatibility();
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
