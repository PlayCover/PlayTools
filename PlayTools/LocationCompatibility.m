//
//  LocationCompatibility.m
//  PlayTools
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <PlayTools/PlayTools-Swift.h>

#if TARGET_OS_MACCATALYST

static const void *kPTLocationTimerKey = &kPTLocationTimerKey;
static const void *kPTLocationDelegateKey = &kPTLocationDelegateKey;
static NSHashTable *pt_activeManagers = nil;
static NSLock *pt_managersLock = nil;
static void (*pt_origSetDelegate)(id, SEL, id) = NULL;

@interface PTWeakDelegateBox : NSObject
@property (nonatomic, weak) id<CLLocationManagerDelegate> delegate;
@property (nonatomic, assign) BOOL authDelivered;
@end

@implementation PTWeakDelegateBox
@end

@interface PTLocationTimerBox : NSObject
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation PTLocationTimerBox
- (void)invalidate {
    @synchronized(self) {
        if (_timer) {
            dispatch_source_cancel(_timer);
            _timer = nil;
        }
    }
}
- (void)dealloc {
    [self invalidate];
}
@end

static CLLocation *pt_currentMockLocation(void) {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(
        PlaySettings.shared.mockLocationLatitude,
        PlaySettings.shared.mockLocationLongitude
    );
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:30.0
                               horizontalAccuracy:5.0
                                 verticalAccuracy:5.0
                                           course:-1.0
                                            speed:0.0
                                        timestamp:[NSDate date]];
}

static id<CLLocationManagerDelegate> pt_delegateForManager(CLLocationManager *manager) {
    if (!manager) { return nil; }
    [pt_managersLock lock];
    PTWeakDelegateBox *box = objc_getAssociatedObject(manager, kPTLocationDelegateKey);
    id<CLLocationManagerDelegate> del = box ? box.delegate : nil;
    [pt_managersLock unlock];
    return del;
}

static void pt_clSetDelegate(CLLocationManager *self, SEL _cmd, id<CLLocationManagerDelegate> delegate) {
    [pt_managersLock lock];
    if (delegate) {
        PTWeakDelegateBox *box = objc_getAssociatedObject(self, kPTLocationDelegateKey);
        if (!box) {
            box = [[PTWeakDelegateBox alloc] init];
            objc_setAssociatedObject(self, kPTLocationDelegateKey, box, OBJC_ASSOCIATION_RETAIN);
        }
        if (box.delegate != delegate) {
            box.delegate = delegate;
            box.authDelivered = NO;
        }
    } else {
        objc_setAssociatedObject(self, kPTLocationDelegateKey, nil, OBJC_ASSOCIATION_RETAIN);
    }
    [pt_managersLock unlock];
    if (pt_origSetDelegate) {
        pt_origSetDelegate(self, _cmd, delegate);
    }
}

static BOOL pt_claimInitialAuthDeliveryForManager(CLLocationManager *manager) {
    if (!manager) { return NO; }
    [pt_managersLock lock];
    PTWeakDelegateBox *box = objc_getAssociatedObject(manager, kPTLocationDelegateKey);
    BOOL shouldSchedule = (box && box.delegate && !box.authDelivered);
    if (shouldSchedule) {
        box.authDelivered = YES;
    }
    [pt_managersLock unlock];
    return shouldSchedule;
}

static void pt_deliverLocationToManager(CLLocationManager *manager) {
    if (!manager) { return; }
    id<CLLocationManagerDelegate> delegate = pt_delegateForManager(manager);
    if (!delegate) { return; }
    CLLocation *loc = pt_currentMockLocation();
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:manager didUpdateLocations:@[loc]];
    } else {
        SEL legacySel = NSSelectorFromString(@"locationManager:didUpdateToLocation:fromLocation:");
        if ([delegate respondsToSelector:legacySel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            typedef void (*pt_legacy_loc_fn)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *);
            ((pt_legacy_loc_fn)[(NSObject *)delegate methodForSelector:legacySel])(delegate, legacySel, manager, loc, loc);
#pragma clang diagnostic pop
        }
    }
}

static void pt_deliverAuthorizedToManager(CLLocationManager *manager, BOOL onlyIfUndelivered) {
    if (!manager) { return; }
    [pt_managersLock lock];
    PTWeakDelegateBox *box = objc_getAssociatedObject(manager, kPTLocationDelegateKey);
    id<CLLocationManagerDelegate> delegate = box ? box.delegate : nil;
    if (!delegate || (onlyIfUndelivered && box.authDelivered)) {
        [pt_managersLock unlock];
        return;
    }
    box.authDelivered = YES;
    [pt_managersLock unlock];
    if (@available(iOS 14.0, *)) {
        if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [delegate locationManagerDidChangeAuthorization:manager];
            return;
        }
    }
    if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [delegate locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
#pragma clang diagnostic pop
    }
}

static void pt_scheduleAuthorizedDelivery(CLLocationManager *manager, BOOL onlyIfUndelivered) {
    __weak CLLocationManager *weakSelf = manager;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *strongSelf = weakSelf;
        if (!strongSelf) { return; }
        pt_deliverAuthorizedToManager(strongSelf, onlyIfUndelivered);
    });
}

static BOOL pt_clLocationServicesEnabled(id self, SEL _cmd) {
    return YES;
}

static CLAuthorizationStatus pt_clClassAuthStatus(id self, SEL _cmd) {
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAuthorizationStatus pt_clInstanceAuthStatus(CLLocationManager *self, SEL _cmd) {
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAccuracyAuthorization pt_clAccuracyAuth(CLLocationManager *self, SEL _cmd) {
    return CLAccuracyAuthorizationFullAccuracy;
}

static CLLocation *pt_clLocation(CLLocationManager *self, SEL _cmd) {
    return pt_currentMockLocation();
}

static void pt_clRequestAuth(CLLocationManager *self, SEL _cmd) {
    if (pt_claimInitialAuthDeliveryForManager(self)) {
        pt_scheduleAuthorizedDelivery(self, NO);
        return;
    }
    // If delegate has not been set yet, defer the undelivered check until the block runs.
    if (!pt_delegateForManager(self)) {
        pt_scheduleAuthorizedDelivery(self, YES);
    }
}

static void pt_clRequestLocation(CLLocationManager *self, SEL _cmd) {
    BOOL shouldDeliverAuth = pt_claimInitialAuthDeliveryForManager(self);
    __weak CLLocationManager *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *strongSelf = weakSelf;
        if (!strongSelf) { return; }
        if (shouldDeliverAuth) {
            pt_deliverAuthorizedToManager(strongSelf, NO);
        }
        pt_deliverLocationToManager(strongSelf);
    });
}

static void pt_clStartUpdatingLocation(CLLocationManager *self, SEL _cmd) {
    __weak CLLocationManager *weakSelf = self;

    [pt_managersLock lock];
    [pt_activeManagers addObject:self];
    PTLocationTimerBox *existing = objc_getAssociatedObject(self, kPTLocationTimerKey);
    if (!existing) {
        PTLocationTimerBox *box = [[PTLocationTimerBox alloc] init];
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                                  3 * NSEC_PER_SEC,
                                  250 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            CLLocationManager *strongSelf = weakSelf;
            if (!strongSelf) { return; }
            pt_deliverLocationToManager(strongSelf);
        });
        box.timer = timer;
        objc_setAssociatedObject(self, kPTLocationTimerKey, box, OBJC_ASSOCIATION_RETAIN);
        dispatch_resume(timer);
    }
    [pt_managersLock unlock];

    // Deliver the initial authorization state once per (manager, delegate);
    // re-invoking startUpdatingLocation inside the delegate callback must not
    // re-trigger authorization delivery or reset the active location timer.
    if (pt_claimInitialAuthDeliveryForManager(self)) {
        pt_scheduleAuthorizedDelivery(self, NO);
    }
}

static void pt_clStopUpdatingLocation(CLLocationManager *self, SEL _cmd) {
    [pt_managersLock lock];
    [pt_activeManagers removeObject:self];
    PTLocationTimerBox *box = objc_getAssociatedObject(self, kPTLocationTimerKey);
    objc_setAssociatedObject(self, kPTLocationTimerKey, nil, OBJC_ASSOCIATION_RETAIN);
    [pt_managersLock unlock];
    [box invalidate];
}

static void pt_replaceInstanceMethod(Class cls, SEL sel, IMP imp, const char *fallbackTypes) {
    Method m = class_getInstanceMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : fallbackTypes;
    class_replaceMethod(cls, sel, imp, types);
}

static void pt_replaceClassMethod(Class cls, SEL sel, IMP imp, const char *fallbackTypes) {
    Class meta = object_getClass(cls);
    Method m = class_getClassMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : fallbackTypes;
    class_replaceMethod(meta, sel, imp, types);
}

__attribute__((visibility("hidden")))
void pt_installLocationCompatibility(void) {
    if (!PlaySettings.shared.mockLocationEnabled) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_activeManagers = [NSHashTable weakObjectsHashTable];
        pt_managersLock = [[NSLock alloc] init];

        Class cls = [CLLocationManager class];
        if (!cls) { return; }

        Method setDelM = class_getInstanceMethod(cls, @selector(setDelegate:));
        if (setDelM) {
            IMP origImp = method_getImplementation(setDelM);
            if (origImp != (IMP)pt_clSetDelegate) {
                pt_origSetDelegate = (void (*)(id, SEL, id))origImp;
                class_replaceMethod(cls, @selector(setDelegate:), (IMP)pt_clSetDelegate, method_getTypeEncoding(setDelM));
            }
        }

        pt_replaceClassMethod(cls, @selector(locationServicesEnabled), (IMP)pt_clLocationServicesEnabled, "B@:");
        pt_replaceClassMethod(cls, @selector(authorizationStatus), (IMP)pt_clClassAuthStatus, "i@:");
        pt_replaceInstanceMethod(cls, @selector(authorizationStatus), (IMP)pt_clInstanceAuthStatus, "i@:");
        pt_replaceInstanceMethod(cls, @selector(accuracyAuthorization), (IMP)pt_clAccuracyAuth, "q@:");
        pt_replaceInstanceMethod(cls, @selector(location), (IMP)pt_clLocation, "@@:");
        pt_replaceInstanceMethod(cls, @selector(requestWhenInUseAuthorization), (IMP)pt_clRequestAuth, "v@:");
        pt_replaceInstanceMethod(cls, @selector(requestAlwaysAuthorization), (IMP)pt_clRequestAuth, "v@:");
        pt_replaceInstanceMethod(cls, @selector(requestLocation), (IMP)pt_clRequestLocation, "v@:");
        pt_replaceInstanceMethod(cls, @selector(startUpdatingLocation), (IMP)pt_clStartUpdatingLocation, "v@:");
        pt_replaceInstanceMethod(cls, @selector(stopUpdatingLocation), (IMP)pt_clStopUpdatingLocation, "v@:");
    });
}

#endif
