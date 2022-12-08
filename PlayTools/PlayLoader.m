//
//  PlayLoader.m
//  PlayTools
//

#include <errno.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"

// Get device model from playcover .plist
#define DEVICE_MODEL ([[[PlaySettings shared] deviceModel] UTF8String])
#define OEM_ID ([[[PlaySettings shared] oemID] UTF8String])
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int pt_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, strlen(DEVICE_MODEL) + 1);
    return 0;
}

// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL)) {
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
            if (*size > strlen(OEM_ID)) {
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
        if (oldp != NULL) {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            const char *machine = DEVICE_MODEL;
            strncpy((char *)oldp, machine, strlen(machine));
            *oldlenp = strlen(machine);
            return ret;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp != NULL) {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            const char *machine = OEM_ID;
            strncpy((char *)oldp, machine, strlen(machine));
            *oldlenp = strlen(machine);
            return ret;
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
    
    struct dyld_interpose_tuple {
    const void* replacement;
    const void* replacee;
};

extern const struct mach_header __dso_handle;
extern void dyld_dynamic_interpose(const struct mach_header* mh, const struct dyld_interpose_tuple array[], size_t count);

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

extern Boolean SecKeyVerifySignature(SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef signedData, CFDataRef signature, CFErrorRef  _Nullable *error);

extern OSStatus SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result);

int my_csops(pid_t pid, uint32_t ops, user_addr_t useraddr, user_size_t usersize){
    if (ops == CS_OPS_STATUS || ops == CS_OPS_IDENTITY) {
            printf("Hooked CSOPS %d \n", ops);
            return 0;
    }
    return csops(pid, ops, useraddr, usersize);
}

OSStatus my_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result){
    OSStatus ret = SecTrustEvaluate(trust, result);
        // Actually, this certificate chain is trusted
    *result = kSecTrustResultUnspecified;
    return ret;
}

Boolean my_SecKeyVerifySignature(SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef signedData, CFDataRef signature, CFErrorRef  _Nullable *error){
    return TRUE;
}

extern OSStatus SSLSetSessionOption (SSLContextRef context, SSLSessionOption option, Boolean value);

OSStatus my_SSLSetSessionOption (SSLContextRef context, SSLSessionOption option, Boolean value) {
    if (option == kSSLSessionOptionBreakOnServerAuth)
           return noErr;
       else
           return SSLSetSessionOption(context, option, value);
}

extern SSLContextRef SSLCreateContext (CFAllocatorRef alloc, SSLProtocolSide protocolSide, SSLConnectionType connectionType);

SSLContextRef my_SSLCreateContext (CFAllocatorRef alloc, SSLProtocolSide protocolSide, SSLConnectionType connectionType){
    SSLContextRef sslContext = SSLCreateContext(alloc, protocolSide, connectionType);
    SSLSetSessionOption(sslContext, kSSLSessionOptionBreakOnServerAuth, true);
    return sslContext;
}

extern OSStatus SSLHandshake (SSLContextRef context);

OSStatus my_SSLHandshake (SSLContextRef context) {
    OSStatus result = SSLHandshake(context);

        // Hijack the flow when breaking on server authentication
        if (result == errSSLServerAuthCompleted)
        {
            // Do not check the cert and call SSLHandshake() again
            return SSLHandshake(context);
        }
        else
            return result;
}

extern bool SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef  _Nullable *error);

bool my_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef  _Nullable *error) {
    return TRUE;
}

extern long SSL_get_verify_result (const void *ssl);

long my_SSL_get_verify_result (const void *ssl) {
    printf("Call");
    return 0;
}

extern OSStatus tls_helper_create_peer_trust(void *hdsk, bool server, SecTrustRef *trustRef);

static OSStatus my_tls_helper_create_peer_trust(void *hdsk, bool server, SecTrustRef *trustRef)
{
    // Do not actually set the trustRef
    return errSecSuccess;
}

extern const char *SSL_get_psk_identity(const void *ssl);

const char *my_SSL_get_psk_identity(const void *ssl) {
    return "Apple";
}

enum ssl_verify_result_t {
    ssl_verify_ok = 0,
    ssl_verify_invalid,
    ssl_verify_retry,
};

#define SSL_VERIFY_NONE 0

static int custom_verify_callback_that_does_not_validate(void *ssl, uint8_t *out_alert)
{
    // Yes this certificate is 100% valid...
    return ssl_verify_ok;
}

extern void SSL_set_custom_verify(void *ssl, int mode, int (*callback)(void *ssl, uint8_t *out_alert));

void my_SSL_set_custom_verify(void *ssl, int mode, int (*callback)(void *ssl, uint8_t *out_alert)){
    SSL_set_custom_verify(ssl, SSL_VERIFY_NONE, custom_verify_callback_that_does_not_validate);
    return;
}

DYLD_INTERPOSE(my_SSL_set_custom_verify, SSL_set_custom_verify)

DYLD_INTERPOSE(my_SSL_get_psk_identity, SSL_get_psk_identity)

//DYLD_INTERPOSE(my_tls_helper_create_peer_trust, tls_helper_create_peer_trust)

DYLD_INTERPOSE(my_csops, csops)

DYLD_INTERPOSE(my_SSLSetSessionOption, SSLSetSessionOption)

DYLD_INTERPOSE(my_SSLHandshake, SSLHandshake)

DYLD_INTERPOSE(my_SecKeyVerifySignature, SecKeyVerifySignature)

DYLD_INTERPOSE(my_SSLCreateContext, SSLCreateContext)

DYLD_INTERPOSE(my_SecTrustEvaluate, SecTrustEvaluate)

DYLD_INTERPOSE(my_SecTrustEvaluateWithError, SecTrustEvaluateWithError)

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    [PlayCover launch];
}

@end
