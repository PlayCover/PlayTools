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

#pragma mark - CloudKit Compatibility Guard

static Class pt_CKContainerClass = Nil;
static Class pt_CKDatabaseClass = Nil;
static id (*pt_origCKDefaultContainer)(id, SEL) = NULL;
static id (*pt_origCKContainerWithIdentifier)(id, SEL, NSString *) = NULL;
static BOOL pt_cloudKitHooksInstalled = NO;

static NSError *pt_cloudKitMissingEntitlementError(void) {
    return [NSError errorWithDomain:@"CKErrorDomain"
                               code:8 /* CKErrorMissingEntitlement */
                           userInfo:@{NSLocalizedDescriptionKey: @"Missing CloudKit entitlement"}];
}

@interface PTStubCKDatabase : NSObject
@property (nonatomic, assign) NSInteger databaseScope;
@end

@implementation PTStubCKDatabase

- (BOOL)isKindOfClass:(Class)aClass {
    return [super isKindOfClass:aClass] || (pt_CKDatabaseClass && [pt_CKDatabaseClass isSubclassOfClass:aClass]);
}

- (void)pt_failCompletion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    if (!completion) {
        return;
    }
    NSError *err = pt_cloudKitMissingEntitlementError();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completion(nil, err);
    });
}

- (void)fetchRecordWithID:(id)recordID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)saveRecord:(id)record completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)deleteRecordWithID:(id)recordID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)performQuery:(id)query inZoneWithID:(id)zoneID completionHandler:(void (^)(NSArray * _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:(void (^)(id, NSError *))completionHandler];
}

- (void)fetchAllRecordZonesWithCompletionHandler:(void (^)(NSArray * _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:(void (^)(id, NSError *))completionHandler];
}

- (void)fetchRecordZoneWithID:(id)zoneID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)saveRecordZone:(id)zone completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)deleteRecordZoneWithID:(id)zoneID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)fetchAllSubscriptionsWithCompletionHandler:(void (^)(NSArray * _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:(void (^)(id, NSError *))completionHandler];
}

- (void)addOperation:(id)operation {
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (!sig && pt_CKDatabaseClass) {
        sig = [pt_CKDatabaseClass instanceMethodSignatureForSelector:aSelector];
    }
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    // Zero-initialize any return buffer so callers receive nil/0/NO cleanly.
    NSUInteger retLen = anInvocation.methodSignature.methodReturnLength;
    if (retLen > 0) {
        uint8_t *zeroBuf = calloc(1, retLen);
        if (zeroBuf) {
            [anInvocation setReturnValue:zeroBuf];
            free(zeroBuf);
        }
    }
}

@end

@interface PTStubCKContainer : NSObject
@property (nonatomic, copy) NSString *containerIdentifier;
@property (nonatomic, strong) PTStubCKDatabase *privateCloudDatabase;
@property (nonatomic, strong) PTStubCKDatabase *publicCloudDatabase;
@property (nonatomic, strong) PTStubCKDatabase *sharedCloudDatabase;
@end

@implementation PTStubCKContainer

- (instancetype)initWithIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) {
        _containerIdentifier = [identifier copy];
        _privateCloudDatabase = [[PTStubCKDatabase alloc] init];
        _privateCloudDatabase.databaseScope = 2;
        _publicCloudDatabase = [[PTStubCKDatabase alloc] init];
        _publicCloudDatabase.databaseScope = 1;
        _sharedCloudDatabase = [[PTStubCKDatabase alloc] init];
        _sharedCloudDatabase.databaseScope = 3;
    }
    return self;
}

- (BOOL)isKindOfClass:(Class)aClass {
    return [super isKindOfClass:aClass] || (pt_CKContainerClass && [pt_CKContainerClass isSubclassOfClass:aClass]);
}

- (id)databaseWithDatabaseScope:(NSInteger)scope {
    if (scope == 1) {
        return self.publicCloudDatabase;
    }
    if (scope == 3) {
        return self.sharedCloudDatabase;
    }
    return self.privateCloudDatabase;
}

- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger, NSError * _Nullable))completionHandler {
    if (!completionHandler) {
        return;
    }
    NSError *err = pt_cloudKitMissingEntitlementError();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(0 /* CKAccountStatusCouldNotDetermine */, err);
    });
}

- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    if (!completionHandler) {
        return;
    }
    NSError *err = pt_cloudKitMissingEntitlementError();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(nil, err);
    });
}

- (void)requestApplicationPermission:(NSUInteger)applicationPermission
                   completionHandler:(void (^)(NSInteger, NSError * _Nullable))completionHandler {
    if (!completionHandler) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(2 /* CKApplicationPermissionStatusDenied */, nil);
    });
}

- (void)statusForApplicationPermission:(NSUInteger)applicationPermission
                     completionHandler:(void (^)(NSInteger, NSError * _Nullable))completionHandler {
    if (!completionHandler) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(2 /* CKApplicationPermissionStatusDenied */, nil);
    });
}

- (void)addOperation:(id)operation {
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (!sig && pt_CKContainerClass) {
        sig = [pt_CKContainerClass instanceMethodSignatureForSelector:aSelector];
    }
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    NSUInteger retLen = anInvocation.methodSignature.methodReturnLength;
    if (retLen > 0) {
        uint8_t *zeroBuf = calloc(1, retLen);
        if (zeroBuf) {
            [anInvocation setReturnValue:zeroBuf];
            free(zeroBuf);
        }
    }
}

@end

static BOOL pt_hasCloudKitEntitlementForContainer(NSString * _Nullable containerID) {
    typedef CFTypeRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*SecTaskCopyValueForEntitlementFn)(CFTypeRef, CFStringRef, CFErrorRef *);
    static SecTaskCreateFromSelfFn createSelfFn = NULL;
    static SecTaskCopyValueForEntitlementFn copyEntitlementFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createSelfFn = (SecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        copyEntitlementFn = (SecTaskCopyValueForEntitlementFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    });
    if (!createSelfFn || !copyEntitlementFn) {
        return NO;
    }
    CFTypeRef task = createSelfFn(kCFAllocatorDefault);
    if (!task) {
        return NO;
    }

    BOOL hasService = NO;
    CFTypeRef services = copyEntitlementFn(task, CFSTR("com.apple.developer.icloud-services"), NULL);
    if (services) {
        if (CFGetTypeID(services) == CFArrayGetTypeID()) {
            for (id entry in (__bridge NSArray *)services) {
                if ([entry isKindOfClass:[NSString class]] &&
                    [(NSString *)entry caseInsensitiveCompare:@"CloudKit"] == NSOrderedSame) {
                    hasService = YES;
                    break;
                }
            }
        }
        CFRelease(services);
    }

    BOOL hasContainer = NO;
    if (hasService) {
        CFTypeRef containers = copyEntitlementFn(task, CFSTR("com.apple.developer.icloud-container-identifiers"), NULL);
        if (containers) {
            if (CFGetTypeID(containers) == CFArrayGetTypeID()) {
                NSArray *arr = (__bridge NSArray *)containers;
                if (containerID.length > 0) {
                    hasContainer = [arr containsObject:containerID] || [arr containsObject:@"*"];
                } else {
                    hasContainer = arr.count > 0;
                }
            }
            CFRelease(containers);
        }
    }

    CFRelease(task);
    return hasService && hasContainer;
}

static id pt_stubContainerForIdentifier(NSString * _Nullable identifier) {
    static NSMutableDictionary<NSString *, PTStubCKContainer *> *stubCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stubCache = [NSMutableDictionary dictionary];
    });
    NSString *key = identifier.length > 0
        ? identifier
        : ([[NSBundle mainBundle] bundleIdentifier] ?: @"iCloud.playcover.stub");
    @synchronized (stubCache) {
        PTStubCKContainer *stub = stubCache[key];
        if (!stub) {
            NSLog(@"[PC] Using CloudKit missing-entitlement stub container for %@", key);
            stub = [[PTStubCKContainer alloc] initWithIdentifier:key];
            stubCache[key] = stub;
        }
        return stub;
    }
}

static id pt_ckDefaultContainer(id self, SEL _cmd) {
    if (pt_hasCloudKitEntitlementForContainer(nil) && pt_origCKDefaultContainer) {
        return pt_origCKDefaultContainer(self, _cmd);
    }
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSString *fallbackID = bid.length > 0 ? [@"iCloud." stringByAppendingString:bid] : @"iCloud.playcover.stub";
    return pt_stubContainerForIdentifier(fallbackID);
}

static id pt_ckContainerWithIdentifier(id self, SEL _cmd, NSString *identifier) {
    if (identifier.length > 0 && pt_hasCloudKitEntitlementForContainer(identifier) && pt_origCKContainerWithIdentifier) {
        return pt_origCKContainerWithIdentifier(self, _cmd, identifier);
    }
    return pt_stubContainerForIdentifier(identifier);
}

static void pt_tryInstallCloudKitHooksNow(void) {
    if (pt_cloudKitHooksInstalled) {
        return;
    }
    Class ckContainer = objc_getClass("CKContainer");
    if (!ckContainer) {
        return;
    }
    pt_CKContainerClass = ckContainer;
    pt_CKDatabaseClass = objc_getClass("CKDatabase");
    Class ckMeta = object_getClass(ckContainer);
    if (!ckMeta) {
        return;
    }

    SEL defaultSel = sel_registerName("defaultContainer");
    Method defaultM = class_getClassMethod(ckContainer, defaultSel);
    if (defaultM) {
        pt_origCKDefaultContainer = (id (*)(id, SEL))method_getImplementation(defaultM);
        class_replaceMethod(ckMeta, defaultSel, (IMP)pt_ckDefaultContainer, method_getTypeEncoding(defaultM));
    }

    SEL withIdSel = sel_registerName("containerWithIdentifier:");
    Method withIdM = class_getClassMethod(ckContainer, withIdSel);
    if (withIdM) {
        pt_origCKContainerWithIdentifier = (id (*)(id, SEL, NSString *))method_getImplementation(withIdM);
        class_replaceMethod(ckMeta, withIdSel, (IMP)pt_ckContainerWithIdentifier, method_getTypeEncoding(withIdM));
    }

    pt_cloudKitHooksInstalled = YES;
}

static void pt_installCloudKitCompatibilityHooks(void) {
    pt_tryInstallCloudKitHooksNow();
    if (!pt_cloudKitHooksInstalled) {
        [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallCloudKitHooksNow();
        }];
    }
}

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    // Install CloudKit entitlement guard synchronously before any background startup queue runs.
    pt_installCloudKitCompatibilityHooks();
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
