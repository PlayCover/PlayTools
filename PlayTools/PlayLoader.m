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

DYLD_INTERPOSE(my_csops, csops)
DYLD_INTERPOSE(my_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(my_dyld_get_base_platform, dyld_get_base_platform)
DYLD_INTERPOSE(my_uname, uname)
DYLD_INTERPOSE(my_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(my_sysctl, sysctl)

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
  NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
  isGenshin =
      [bundleId isEqual:@"com.miHoYo.GenshinImpact"] || [bundleId isEqual:@"com.miHoYo.Yuanshen"];
  [PlayCover launch];
}

@end
