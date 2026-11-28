#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

#if TARGET_OS_MACCATALYST

static void (*pt_nativeHideSplashScreen)(id, SEL);
static void (*pt_nativeSceneWindowDidConnect)(id, SEL, id);
static char pt_oneNotePendingRootKey;

static BOOL pt_hasMethodSignature(Method method, unsigned int expectedArgs, char expectedReturn, char thirdArgType) {
    if (!method || method_getNumberOfArguments(method) != expectedArgs) {
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] != expectedReturn) {
        return NO;
    }
    if (thirdArgType != '\0') {
        char argType[32] = {0};
        method_getArgumentType(method, 2, argType, sizeof(argType));
        if (argType[0] != thirdArgType) {
            return NO;
        }
    }
    return YES;
}

static BOOL pt_isSplashRootViewController(UIViewController * _Nullable controller) {
    Class splashClass = NSClassFromString(@"ONISplashScreenViewController");
    return splashClass != Nil && [controller isKindOfClass:splashClass];
}

static UIViewController * _Nullable pt_getPostLaunchRoot(id appDelegate) {
    SEL getter = NSSelectorFromString(@"postLaunchRootViewController");
    if (!getter || ![appDelegate respondsToSelector:getter]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(appDelegate, getter);
}

static void pt_setPostLaunchRoot(id appDelegate, UIViewController * _Nullable root) {
    SEL setter = NSSelectorFromString(@"setPostLaunchRootViewController:");
    if (!setter || ![appDelegate respondsToSelector:setter]) {
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(appDelegate, setter, root);
}

static UIWindow * _Nullable pt_windowInScene(UIWindowScene *scene) {
    UIWindow *fallback = nil;
    for (UIWindow *window in scene.windows) {
        if (!window.rootViewController) {
            continue;
        }
        if (window.isKeyWindow || pt_isSplashRootViewController(window.rootViewController)) {
            return window;
        }
        if (!fallback) {
            fallback = window;
        }
    }
    return fallback;
}

static UIWindow * _Nullable pt_resolveConnectedSceneWindow(id _Nullable connection) {
    if ([connection isKindOfClass:UIWindow.class]) {
        UIWindow *window = (UIWindow *)connection;
        if (window.rootViewController) {
            return window;
        }
        if (window.windowScene) {
            UIWindow *sceneMatch = pt_windowInScene(window.windowScene);
            if (sceneMatch) {
                return sceneMatch;
            }
        }
    } else if ([connection isKindOfClass:UIWindowScene.class]) {
        UIWindow *sceneMatch = pt_windowInScene((UIWindowScene *)connection);
        if (sceneMatch) {
            return sceneMatch;
        }
    }

    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindow *candidate = pt_windowInScene((UIWindowScene *)scene);
        if (!candidate) {
            continue;
        }
        if (pt_isSplashRootViewController(candidate.rootViewController)) {
            return candidate;
        }
        if (!fallback) {
            fallback = candidate;
        }
    }
    return fallback;
}

static void pt_oneNoteHideSplashScreen(id self, SEL _cmd) {
    UIViewController *root = pt_getPostLaunchRoot(self);
    if (NSThread.isMainThread &&
        [root isKindOfClass:UIViewController.class] &&
        !pt_isSplashRootViewController(root) &&
        !pt_resolveConnectedSceneWindow(nil)) {
        objc_setAssociatedObject(self, &pt_oneNotePendingRootKey, root, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    objc_setAssociatedObject(self, &pt_oneNotePendingRootKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (pt_nativeHideSplashScreen) {
        pt_nativeHideSplashScreen(self, _cmd);
    }
}

static void pt_oneNoteSceneWindowDidConnect(id self, SEL _cmd, id connection) {
    if (pt_nativeSceneWindowDidConnect) {
        pt_nativeSceneWindowDidConnect(self, _cmd, connection);
    }

    if (!objc_getAssociatedObject(self, &pt_oneNotePendingRootKey)) {
        return;
    }

    __weak id weakConnection = connection;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *pendingRoot = objc_getAssociatedObject(self, &pt_oneNotePendingRootKey);
        if (![pendingRoot isKindOfClass:UIViewController.class]) {
            return;
        }
        objc_setAssociatedObject(self, &pt_oneNotePendingRootKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIWindow *window = pt_resolveConnectedSceneWindow(weakConnection);
        if (!window || !pt_isSplashRootViewController(window.rootViewController)) {
            return;
        }

        if (!pt_getPostLaunchRoot(self)) {
            pt_setPostLaunchRoot(self, pendingRoot);
        }
        SEL hideSel = NSSelectorFromString(@"hideSplashScreen");
        if (pt_nativeHideSplashScreen && hideSel) {
            pt_nativeHideSplashScreen(self, hideSel);
        }
    });
}

__attribute__((constructor))
static void pt_installOneNoteSceneCompatibility(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.microsoft.onenote"]) {
            return;
        }

        Class delegateClass = NSClassFromString(@"ONAppDelegate");
        if (!delegateClass) {
            return;
        }

        SEL hideSel = NSSelectorFromString(@"hideSplashScreen");
        SEL sceneSel = NSSelectorFromString(@"sceneWindowDidConnect:");
        SEL getRootSel = NSSelectorFromString(@"postLaunchRootViewController");
        SEL setRootSel = NSSelectorFromString(@"setPostLaunchRootViewController:");
        Method hideMethod = class_getInstanceMethod(delegateClass, hideSel);
        Method sceneMethod = class_getInstanceMethod(delegateClass, sceneSel);
        Method getRootMethod = class_getInstanceMethod(delegateClass, getRootSel);
        Method setRootMethod = class_getInstanceMethod(delegateClass, setRootSel);

        if (!pt_hasMethodSignature(hideMethod, 2, 'v', '\0') ||
            !pt_hasMethodSignature(sceneMethod, 3, 'v', '@') ||
            !pt_hasMethodSignature(getRootMethod, 2, '@', '\0') ||
            !pt_hasMethodSignature(setRootMethod, 3, 'v', '@')) {
            return;
        }

        pt_nativeHideSplashScreen = (void (*)(id, SEL))method_setImplementation(hideMethod, (IMP)pt_oneNoteHideSplashScreen);
        pt_nativeSceneWindowDidConnect = (void (*)(id, SEL, id))method_setImplementation(sceneMethod, (IMP)pt_oneNoteSceneWindowDidConnect);
        os_log(OS_LOG_DEFAULT, "PC_ONFIX installed ONAppDelegate scene splash guard");
    }
}

#endif
