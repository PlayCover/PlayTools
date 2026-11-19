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

static int (* volatile pt_orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int (*orig_fn)(const char *, void *, size_t *, void *, size_t) = pt_orig_sysctlbyname ? pt_orig_sysctlbyname : &sysctlbyname;
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
            int ret = orig_fn(name, oldp, oldlenp, newp, newlen);
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
            int ret = orig_fn(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return orig_fn(name, oldp, oldlenp, newp, newlen);
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
static char UE_PATTERN[1024] = "//Users/";
static BOOL ue_pattern_ready = NO;

static void init_ue_pattern(void) {
    if (ue_pattern_ready) {
        return;
    }
    if (getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8) == 0 && UE_PATTERN[8] != '\0') {
        ue_pattern_ready = YES;
    }
}

static char const* ue_fix_filename(char const* filename) {
    // Cache getlogin_r once instead of querying libsystem_c on hot I/O paths where crash
    // reporters may suspend threads while invoking open/rename, preventing mutex deadlocks.
    if (ue_status != 2 || !ue_pattern_ready || !filename) {
        return filename;
    }

    char const* p = filename;
    char const* last_p = p;
    while ((p = strstr(p, UE_PATTERN))) {
        last_p = ++p;
    }
    return last_p;
}

// Snapshot libc pointers at constructor time into writable globals so runtime fishhook /
// rebind_symbols hooks installed by third-party SDKs cannot cause mutual recursion cycles.
static int (* volatile pt_orig_open)(char const* restrict, int, ...) = NULL;
static int (* volatile pt_orig_stat)(char const* restrict, struct stat* restrict) = NULL;
static int (* volatile pt_orig_access)(char const*, int) = NULL;
static int (* volatile pt_orig_rename)(char const* restrict, char const* restrict) = NULL;
static int (* volatile pt_orig_unlink)(char const*) = NULL;
static int (* volatile pt_orig_usleep)(useconds_t) = NULL;

__attribute__((constructor(101))) static void pt_snapshot_libc_originals(void) {
    pt_orig_sysctlbyname = &sysctlbyname;
    pt_orig_open = &open;
    pt_orig_stat = &stat;
    pt_orig_access = &access;
    pt_orig_rename = &rename;
    pt_orig_unlink = &unlink;
    pt_orig_usleep = &usleep;
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);
    int (*orig_fn)(char const* restrict, int, ...) = pt_orig_open ? pt_orig_open : &open;

    if (oflag & O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return orig_fn(filename, oflag, mod);
    }

    return orig_fn(filename, oflag);
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    int (*orig_fn)(char const* restrict, struct stat* restrict) = pt_orig_stat ? pt_orig_stat : &stat;
    return orig_fn(ue_fix_filename(path), buf);
}

static int pt_access(char const* path, int mode) {
    int (*orig_fn)(char const*, int) = pt_orig_access ? pt_orig_access : &access;
    return orig_fn(ue_fix_filename(path), mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    int (*orig_fn)(char const* restrict, char const* restrict) = pt_orig_rename ? pt_orig_rename : &rename;
    return orig_fn(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

static int pt_unlink(char const* path) {
    int (*orig_fn)(char const*) = pt_orig_unlink ? pt_orig_unlink : &unlink;
    return orig_fn(ue_fix_filename(path));
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
    
    int (*orig_fn)(useconds_t) = pt_orig_usleep ? pt_orig_usleep : &usleep;
    return orig_fn(time);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

static void (*pt_origLetBackgroundTasksCompleteWithTimeout)(id, SEL, double) = NULL;
static BOOL pt_terminationHookInstalled = NO;

static void pt_letBackgroundTasksCompleteWithTimeout(id self, SEL _cmd, double timeout) {
    // Cap UIKitMacHelper's post-Cmd+Q background-task grace window (default 35s) so SDK
    // tasks opened during applicationDidEnterBackground cannot leave exited apps in a
    // zombie state.
    double cappedTimeout = (timeout > 0.35) ? 0.35 : timeout;
    if (pt_origLetBackgroundTasksCompleteWithTimeout) {
        pt_origLetBackgroundTasksCompleteWithTimeout(self, _cmd, cappedTimeout);
    }
}

static void pt_tryInstallTerminationTimeoutHookNow(void) {
    if (pt_terminationHookInstalled) {
        return;
    }
    Class termCtrl = objc_getClass("UINSUIKitTerminationController");
    if (!termCtrl) {
        return;
    }
    SEL sel = sel_registerName("letBackgroundTasksCompleteWithTimeout:");
    Method m = class_getInstanceMethod(termCtrl, sel);
    if (m) {
        pt_origLetBackgroundTasksCompleteWithTimeout = (void (*)(id, SEL, double))method_getImplementation(m);
        class_replaceMethod(termCtrl, sel, (IMP)pt_letBackgroundTasksCompleteWithTimeout, method_getTypeEncoding(m));
        pt_terminationHookInstalled = YES;
    }
}

static void pt_installTerminationTimeoutHooks(void) {
    pt_tryInstallTerminationTimeoutHookNow();
    if (!pt_terminationHookInstalled) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallTerminationTimeoutHookNow();
        }];
    }
}

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    // Prevent AppKit's "unexpectedly quit while reopening windows" modal from blocking Catalyst launch.
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ApplePersistenceIgnoreState"];
    dispatch_async(dispatch_get_main_queue(), ^{
        pt_installTerminationTimeoutHooks();
    });
    [PlayCover launch];
    
    if (ue_status == 0) {
        if (PlayInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        init_ue_pattern();
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
