//
//  PlayLoader.m
//  PlayTools
//
#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#import <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#import <sys/utsname.h>
#include <unistd.h>
#import "NSObject+Swizzle.h"
#include "sandbox.h"

#define SYSTEM_INFO_PATH "/System/Library/CoreServices/SystemVersion.plist"
#define IOS_SYSTEM_INFO_PATH "/System/Library/CoreServices/iOSSystemVersion.plist"

#define CS_OPS_STATUS 0            /* return status */
#define CS_OPS_ENTITLEMENTS_BLOB 7 /* get entitlements blob */
#define CS_OPS_IDENTITY 11         /* get codesign identity */

int dyld_get_active_platform(void);

int my_dyld_get_active_platform(void) { return 2; }

extern uint64_t dyld_get_base_platform(void *platform);

uint64_t my_dyld_get_base_platform(void *platform) { return 2; }

// #define DEVICE_MODEL ("iPad13,8")
//#define DEVICE_MODEL ("iPad8,6")

// find Mac by using sysctl of HW_TARGET
// #define OEM_ID ("J522AP")
// #define OEM_ID ("J320xAP")

// get device model from playcover .plist
#define DEVICE_MODEL ([[[PlaySettings shared] deviceModel] UTF8String])
#define OEM_ID ([[[PlaySettings shared] oemID] UTF8String])

static int my_uname(struct utsname *uts) {
  int result = 0;
  NSString *nickname = @"ipad";
  if (nickname.length == 0)
    result = uname(uts);
  else {
    strncpy(uts->nodename, [nickname UTF8String], nickname.length + 1);
    strncpy(uts->machine, DEVICE_MODEL, strlen(DEVICE_MODEL) + 1);
  }
  return result;
}

static int my_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
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

static int my_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp,
                           size_t newlen) {
  if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) ||
      (strcmp(name, "hw.model") == 0)) {
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

// Useful for debugging:
// static int my_open(const char *path, int flags, mode_t mode) {
//   mode = 0644;
//   int value = open(path, flags, mode);
//   if (value == -1) {
//     printf("[Lucas] open (%s): %s\n", strerror(errno), path);
//   }

//   return value;
// }

// static int my_create(const char *path, mode_t mode) {
//   int value = creat(path, mode);
//   if (value == -1) {
//     printf("[Lucas] create (%s): %s\n", strerror(errno), path);
//   }
//   return value;
// }

// static int my_mkdir(const char *path, mode_t mode) {
//   int value = mkdir(path, mode);
//   if (value == -1) {
//     printf("[Lucas] mkdir (%s): %s\n", strerror(errno), path);
//   }
//   return value;
// }

// static int my_lstat(const char *restrict path, void *restrict buf) {
//   int value = lstat(path, buf);
//   if (value == -1) {
//     printf("[Lucas] lstat (%s): %s\n", strerror(errno), path);
//   }
//   return value;
// }

static bool isGenshin = false;

extern int csops(pid_t pid, unsigned int ops, user_addr_t useraddr, size_t usersize);

int my_csops(pid_t pid, uint32_t ops, user_addr_t useraddr, user_size_t usersize) {
  if (isGenshin) {
    if (ops == CS_OPS_STATUS || ops == CS_OPS_IDENTITY) {
      printf("Hooking %s: %s wrapper \n", DEVICE_MODEL, OEM_ID);
      printf("Hooked CSOPS %d \n", ops);
      return 0;
    }
  }

  return csops(pid, ops, useraddr, usersize);
}

enum ssl_verify_result_t {
  ssl_verify_ok = 0,
  ssl_verify_invalid,
  ssl_verify_retry,
};

static void (*SSL_CTX_set_custom_verify)(void *ctx, int mode, int (*callback)(void *ssl, uint8_t *out_alert));
static void (*SSL_get_psk_identity)(void *ssl);

char *my_SSL_get_psk_identity(void *ssl) {
    return "\x47\x44\x39\x39\x39\x39\x41\x0\x42\x12\x42\x42\x42\x42\x11\x42\x43\x43\x13\x42\x43\x43\x43\x77\x44\x44\x44\x31\x44\x59\x44\x44\x45\x45\x45\x45\x45\x88\x6c\x7c\x04\x01\x00";
}

static int custom_verify_callback(void *ssl, uint8_t *out_alert) {
    return ssl_verify_ok;
}

void my_SSL_CTX_set_custom_verify(void *ctx, int mode, int (callback)(void *ssl, uint8_t *out_alert)) {
    void (*ogFunction)(void *ctx, int mode, int (callback)(void *ssl, uint8_t *out_alert));
    void* boringSSLHandle = dlopen("/usr/lib/libboringssl.dylib", RTLD_NOW);
    *(void **) (&ogFunction) = dlsym(boringSSLHandle, "SSL_CTX_set_custom_verify");
    (*ogFunction)(ctx, 0x00, custom_verify_callback);
    return;
}

DYLD_INTERPOSE(my_SSL_CTX_set_custom_verify, SSL_CTX_set_custom_verify)
DYLD_INTERPOSE(my_SSL_get_psk_identity, SSL_get_psk_identity)

DYLD_INTERPOSE(my_csops, csops)

DYLD_INTERPOSE(my_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(my_dyld_get_base_platform, dyld_get_base_platform)
DYLD_INTERPOSE(my_uname, uname)
DYLD_INTERPOSE(my_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(my_sysctl, sysctl)
// DYLD_INTERPOSE(my_open, open)
// DYLD_INTERPOSE(my_mkdir, mkdir)
// DYLD_INTERPOSE(my_create, creat)
// DYLD_INTERPOSE(my_lstat, lstat)

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
  NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
  isGenshin =
      [bundleId isEqual:@"com.miHoYo.GenshinImpact"] || [bundleId isEqual:@"com.miHoYo.Yuanshen"];
  [PlayCover launch];
}

@end
