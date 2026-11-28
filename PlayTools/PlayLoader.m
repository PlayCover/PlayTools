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
#import <sys/stat.h>
#import <unistd.h>

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

static NSURL *(*pt_origContainerURLForGroupIdentifier)(id, SEL, NSString *) = NULL;
static BOOL pt_appGroupHookInstalled = NO;

static BOOL pt_ensureWritableGroupDirectory(NSFileManager *manager, NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] || !url.isFileURL || url.path.length == 0) {
        return NO;
    }

    NSString *path = url.path;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
        [manager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
        [manager fileExistsAtPath:path isDirectory:&isDirectory];
    }
    return isDirectory && access(path.fileSystemRepresentation, W_OK | X_OK) == 0;
}

static BOOL pt_isValidGroupIdentifier(NSString *groupIdentifier) {
    return [groupIdentifier isKindOfClass:[NSString class]] &&
           groupIdentifier.length > 0 &&
           ![groupIdentifier containsString:@"/"] &&
           ![groupIdentifier containsString:@".."] &&
           ![groupIdentifier isEqualToString:@"."] &&
           [groupIdentifier rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static NSURL * _Nullable pt_spaceFreeGroupRootURL(NSFileManager *manager) {
    NSURL *libraryURL = [manager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    if (![libraryURL isKindOfClass:[NSURL class]] || !libraryURL.isFileURL || libraryURL.path.length == 0) {
        return nil;
    }
    return [libraryURL URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES];
}

static void pt_migrateLegacyGroupDirectoryIfUninitialized(NSFileManager *manager, NSURL *legacyURL, NSURL *targetURL) {
    if (!legacyURL || !targetURL) {
        return;
    }
    struct stat targetStat;
    if (lstat(targetURL.path.fileSystemRepresentation, &targetStat) == 0 || errno != ENOENT) {
        return;
    }

    BOOL legacyIsDir = NO;
    if (![manager fileExistsAtPath:legacyURL.path isDirectory:&legacyIsDir] || !legacyIsDir) {
        return;
    }

    NSURL *parentURL = [targetURL URLByDeletingLastPathComponent];
    if (!pt_ensureWritableGroupDirectory(manager, parentURL)) {
        return;
    }

    if (![manager moveItemAtURL:legacyURL toURL:targetURL error:nil]) {
        [manager copyItemAtURL:legacyURL toURL:targetURL error:nil];
    }
}

static NSURL * _Nullable pt_spaceFreeAliasForWritableGroupURL(NSFileManager *manager,
                                                               NSURL *origURL,
                                                               NSString *groupIdentifier) {
    NSURL *rootURL = pt_spaceFreeGroupRootURL(manager);
    NSURL *aliasURL = [rootURL URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    if (!aliasURL || [aliasURL.path containsString:@" "] || !pt_ensureWritableGroupDirectory(manager, rootURL)) {
        return nil;
    }

    NSString *aliasPath = aliasURL.path;
    NSString *destPath = origURL.path;
    struct stat st;
    if (lstat(aliasPath.fileSystemRepresentation, &st) == 0) {
        if (S_ISLNK(st.st_mode)) {
            NSString *existingDest = [manager destinationOfSymbolicLinkAtPath:aliasPath error:nil];
            if (![existingDest isEqualToString:destPath]) {
                [manager removeItemAtPath:aliasPath error:nil];
                [manager createSymbolicLinkAtPath:aliasPath withDestinationPath:destPath error:nil];
            }
        } else if (!S_ISDIR(st.st_mode)) {
            return nil;
        }
    } else if (errno == ENOENT) {
        [manager createSymbolicLinkAtPath:aliasPath withDestinationPath:destPath error:nil];
    } else {
        return nil;
    }

    return access(aliasPath.fileSystemRepresentation, W_OK | X_OK) == 0 ? aliasURL : nil;
}

static NSURL *pt_containerURLForGroupIdentifier(NSFileManager *self, SEL _cmd, NSString *groupIdentifier) {
    NSURL *origURL = pt_origContainerURLForGroupIdentifier ? pt_origContainerURLForGroupIdentifier(self, _cmd, groupIdentifier) : nil;
    if (!pt_isValidGroupIdentifier(groupIdentifier)) {
        return nil;
    }

    // Real iOS App Group containers (/private/var/mobile/Containers/Shared/AppGroup/<UUID>)
    // never contain spaces, so iOS apps frequently strip "file://" from url.absoluteString.
    // Provide a space-free Library/PlayCoverGroupContainers/<group> path to avoid "%20" SQLite failures.
    if (pt_ensureWritableGroupDirectory(self, origURL)) {
        if (![origURL.path containsString:@" "]) {
            return origURL;
        }
        NSURL *aliasURL = pt_spaceFreeAliasForWritableGroupURL(self, origURL, groupIdentifier);
        return aliasURL ?: origURL;
    }

    NSURL *fallbackRoot = pt_spaceFreeGroupRootURL(self);
    NSURL *fallbackURL = [fallbackRoot URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    if (fallbackURL && ![fallbackURL.path containsString:@" "]) {
        NSURL *appSupport = [self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *legacyURL = [[appSupport URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES]
            URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
        pt_migrateLegacyGroupDirectoryIfUninitialized(self, legacyURL, fallbackURL);
        if (pt_ensureWritableGroupDirectory(self, fallbackURL)) {
            return fallbackURL;
        }
    }

    NSURL *appSupport = [self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *legacyURL = [[appSupport URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES]
        URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    return pt_ensureWritableGroupDirectory(self, legacyURL) ? legacyURL : nil;
}

static void pt_installAppGroupContainerGuard(void) {
    if (pt_appGroupHookInstalled) {
        return;
    }
    Class fmClass = objc_getClass("NSFileManager");
    if (!fmClass) {
        return;
    }
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method m = class_getInstanceMethod(fmClass, sel);
    if (!m) {
        return;
    }
    IMP origImp = method_getImplementation(m);
    if (origImp != (IMP)pt_containerURLForGroupIdentifier) {
        pt_origContainerURLForGroupIdentifier = (NSURL *(*)(id, SEL, NSString *))origImp;
        class_replaceMethod(fmClass, sel, (IMP)pt_containerURLForGroupIdentifier, method_getTypeEncoding(m));
    }
    pt_appGroupHookInstalled = YES;
}

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    pt_installAppGroupContainerGuard();
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
