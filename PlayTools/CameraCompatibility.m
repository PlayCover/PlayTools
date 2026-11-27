#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

#if TARGET_OS_MACCATALYST
#import <PlayTools/PlayTools-Swift.h>

static BOOL (*pt_nativePickerAvailability)(id, SEL, UIImagePickerControllerCameraDevice);
static void (*pt_nativeSetPickerCameraDevice)(UIImagePickerController *, SEL, UIImagePickerControllerCameraDevice);
static AVCaptureDevice *(*pt_nativeTypedCamera)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition);
static AVCaptureDeviceDiscoverySession *(*pt_nativeCameraDiscovery)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition);
static NSArray<AVCaptureDevice *> *(*pt_nativeDiscoveryDevices)(AVCaptureDeviceDiscoverySession *, SEL);
static id (*pt_nativeInitDeviceInput)(AVCaptureDeviceInput *, SEL, AVCaptureDevice *, NSError **);
static void (*pt_nativeCameraOrientation)(AVCaptureConnection *, SEL, AVCaptureVideoOrientation);
static void (*pt_nativeCameraAngle)(AVCaptureConnection *, SEL, CGFloat);
static void (*pt_nativeSetVideoMirrored)(AVCaptureConnection *, SEL, BOOL);
static void (*pt_nativeSetAutoMirroring)(AVCaptureConnection *, SEL, BOOL);
static void (*pt_nativeStartCameraSession)(AVCaptureSession *, SEL);
static void (*pt_nativeCommitCameraConfiguration)(AVCaptureSession *, SEL);
static id (*pt_nativePreviewInitWithSession)(AVCaptureVideoPreviewLayer *, SEL, AVCaptureSession *);
static void (*pt_nativePreviewSetSession)(AVCaptureVideoPreviewLayer *, SEL, AVCaptureSession *);
static CGFloat (*pt_nativeHorizonPreviewAngle)(AVCaptureDeviceRotationCoordinator *, SEL) API_AVAILABLE(macCatalyst(17.0));
static CGFloat (*pt_nativeHorizonCaptureAngle)(AVCaptureDeviceRotationCoordinator *, SEL) API_AVAILABLE(macCatalyst(17.0));
static __thread NSUInteger pt_nativePickerCheckDepth;
static __thread BOOL pt_applyingCameraAngle;
static __thread BOOL pt_applyingCameraMirror;
static const void *pt_devicePendingRoleKey = &pt_devicePendingRoleKey;
static const void *pt_discoveryRoleKey = &pt_discoveryRoleKey;
static const void *pt_inputRoleKey = &pt_inputRoleKey;

// The settings are shared with PlayCover. An explicit angle overrides the app's orientation.
static const NSInteger pt_automaticCameraRotation = -1;
static const NSInteger pt_automaticCameraMirror = -1;

static void pt_recordPendingRole(AVCaptureDevice *device, AVCaptureDevicePosition position) {
    if (!device) { return; }
    if (position == AVCaptureDevicePositionBack || position == AVCaptureDevicePositionFront) {
        objc_setAssociatedObject(device, pt_devicePendingRoleKey, @(position), OBJC_ASSOCIATION_RETAIN);
    } else {
        objc_setAssociatedObject(device, pt_devicePendingRoleKey, nil, OBJC_ASSOCIATION_RETAIN);
    }
}

static BOOL pt_callNativePicker(id self, SEL command, UIImagePickerControllerCameraDevice device) {
    pt_nativePickerCheckDepth++;
    @try {
        return pt_nativePickerAvailability(self, command, device);
    } @finally {
        pt_nativePickerCheckDepth--;
    }
}

static BOOL pt_cameraAccessCanBeRequested(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return status == AVAuthorizationStatusAuthorized || status == AVAuthorizationStatusNotDetermined;
}

static BOOL pt_usableCamera(AVCaptureDevice *device) {
    return device.isConnected && !device.isSuspended;
}

static BOOL pt_isLocalBuiltInMacCamera(AVCaptureDevice *device) {
    if (!device || ![device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
        return NO;
    }
    if (@available(macCatalyst 16.0, *)) {
        if (device.isContinuityCamera) { return NO; }
    }
    return YES;
}

static BOOL pt_localFrontCamera(AVCaptureDevice *device) {
    return pt_usableCamera(device) &&
           device.position == AVCaptureDevicePositionFront &&
           pt_isLocalBuiltInMacCamera(device);
}

static AVCaptureDevice *pt_findLocalFrontCamera(void) {
    if (!pt_cameraAccessCanBeRequested()) { return nil; }

    AVCaptureDevice *device = pt_nativeTypedCamera(AVCaptureDevice.class,
        @selector(defaultDeviceWithDeviceType:mediaType:position:), AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVMediaTypeVideo, AVCaptureDevicePositionFront);
    return pt_localFrontCamera(device) ? device : nil;
}

static BOOL pt_hasNativeRearCamera(void) {
    if (!pt_nativePickerAvailability) { return NO; }
    return pt_callNativePicker(UIImagePickerController.class, @selector(isCameraDeviceAvailable:),
                               UIImagePickerControllerCameraDeviceRear);
}

static BOOL pt_pickerCameraAvailability(id self, SEL command, UIImagePickerControllerCameraDevice device) {
    BOOL topLevel = (pt_nativePickerCheckDepth == 0);
    BOOL available = pt_callNativePicker(self, command, device);
    return available || (topLevel && device == UIImagePickerControllerCameraDeviceRear &&
                         pt_findLocalFrontCamera() != nil);
}

static void pt_setPickerCameraDevice(UIImagePickerController *self, SEL command,
                                     UIImagePickerControllerCameraDevice device) {
    if (device == UIImagePickerControllerCameraDeviceRear &&
        !pt_hasNativeRearCamera() &&
        pt_nativePickerAvailability &&
        pt_callNativePicker(UIImagePickerController.class, @selector(isCameraDeviceAvailable:),
                            UIImagePickerControllerCameraDeviceFront)) {
        device = UIImagePickerControllerCameraDeviceFront;
    }
    pt_nativeSetPickerCameraDevice(self, command, device);
}

static AVCaptureDevice *pt_selectCamera(id self, SEL command, AVCaptureDeviceType type,
                                       AVMediaType media, AVCaptureDevicePosition position) {
    AVCaptureDevice *requested = pt_nativeTypedCamera(self, command, type, media, position);
    AVCaptureDevice *chosen = requested;
    if (!(pt_nativePickerCheckDepth > 0 || position != AVCaptureDevicePositionBack ||
          ![media isEqualToString:AVMediaTypeVideo] || ![type isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera] ||
          (pt_usableCamera(requested) && pt_hasNativeRearCamera()))) {
        AVCaptureDevice *front = pt_findLocalFrontCamera();
        if (front) { chosen = front; }
    }
    if (pt_nativePickerCheckDepth == 0 && [media isEqualToString:AVMediaTypeVideo]) {
        pt_recordPendingRole(chosen, position);
    }
    return chosen;
}

static AVCaptureDeviceDiscoverySession *pt_discoverCameras(id self, SEL command, NSArray *types, AVMediaType media,
                                                          AVCaptureDevicePosition position) {
    AVCaptureDeviceDiscoverySession *requested = pt_nativeCameraDiscovery(self, command, types, media, position);
    AVCaptureDeviceDiscoverySession *result = requested;
    if (!(pt_nativePickerCheckDepth > 0 || position != AVCaptureDevicePositionBack || ![media isEqualToString:AVMediaTypeVideo] ||
          ![types containsObject:AVCaptureDeviceTypeBuiltInWideAngleCamera])) {
        BOOL keepRequested = NO;
        if (pt_hasNativeRearCamera()) {
            for (AVCaptureDevice *device in requested.devices) {
                if (pt_usableCamera(device)) {
                    keepRequested = YES;
                    break;
                }
            }
        }
        if (!keepRequested && pt_cameraAccessCanBeRequested()) {
            AVCaptureDeviceDiscoverySession *front = pt_nativeCameraDiscovery(self, command,
                @[AVCaptureDeviceTypeBuiltInWideAngleCamera], media, AVCaptureDevicePositionFront);
            BOOL hasFront = NO;
            for (AVCaptureDevice *device in front.devices) {
                if (pt_localFrontCamera(device)) {
                    hasFront = YES;
                }
            }
            if (hasFront) {
                // Report the actual front-facing device, including its true position and capabilities.
                result = front;
            }
        }
    }
    if (pt_nativePickerCheckDepth == 0 && [media isEqualToString:AVMediaTypeVideo] && result) {
        id roleValue = (position == AVCaptureDevicePositionBack || position == AVCaptureDevicePositionFront)
            ? @(position) : nil;
        objc_setAssociatedObject(result, pt_discoveryRoleKey, roleValue, OBJC_ASSOCIATION_RETAIN);
        for (AVCaptureDevice *device in pt_nativeDiscoveryDevices ? pt_nativeDiscoveryDevices(result, @selector(devices)) : result.devices) {
            pt_recordPendingRole(device, position);
        }
    }
    return result;
}

static NSArray<AVCaptureDevice *> *pt_discoveryDevices(AVCaptureDeviceDiscoverySession *self, SEL command) {
    NSArray<AVCaptureDevice *> *devices = pt_nativeDiscoveryDevices(self, command);
    NSNumber *roleNum = objc_getAssociatedObject(self, pt_discoveryRoleKey);
    if (roleNum) {
        AVCaptureDevicePosition role = (AVCaptureDevicePosition)roleNum.integerValue;
        if (role == AVCaptureDevicePositionBack || role == AVCaptureDevicePositionFront) {
            for (AVCaptureDevice *device in devices) {
                pt_recordPendingRole(device, role);
            }
        }
    }
    return devices;
}

static id pt_initDeviceInput(AVCaptureDeviceInput *self, SEL command, AVCaptureDevice *device, NSError **error) {
    id input = pt_nativeInitDeviceInput(self, command, device, error);
    if (input && [device hasMediaType:AVMediaTypeVideo]) {
        NSNumber *roleNum = objc_getAssociatedObject(device, pt_devicePendingRoleKey);
        objc_setAssociatedObject(device, pt_devicePendingRoleKey, nil, OBJC_ASSOCIATION_RETAIN);
        AVCaptureDevicePosition role = roleNum ? (AVCaptureDevicePosition)roleNum.integerValue : device.position;
        if (role == AVCaptureDevicePositionBack || role == AVCaptureDevicePositionFront) {
            objc_setAssociatedObject(input, pt_inputRoleKey, @(role), OBJC_ASSOCIATION_RETAIN);
        }
    }
    return input;
}

static AVCaptureDevice *pt_videoDeviceForConnection(AVCaptureConnection *connection) {
    for (AVCaptureInputPort *port in connection.inputPorts) {
        if ([port.mediaType isEqualToString:AVMediaTypeVideo] && [port.input isKindOfClass:AVCaptureDeviceInput.class]) {
            return ((AVCaptureDeviceInput *)port.input).device;
        }
    }
    return nil;
}

static AVCaptureDevicePosition pt_requestedCameraRoleForConnection(AVCaptureConnection *connection) {
    for (AVCaptureInputPort *port in connection.inputPorts) {
        if ([port.mediaType isEqualToString:AVMediaTypeVideo] && [port.input isKindOfClass:AVCaptureDeviceInput.class]) {
            AVCaptureDeviceInput *input = (AVCaptureDeviceInput *)port.input;
            NSNumber *roleNum = objc_getAssociatedObject(input, pt_inputRoleKey);
            return roleNum ? (AVCaptureDevicePosition)roleNum.integerValue : input.device.position;
        }
    }
    return AVCaptureDevicePositionUnspecified;
}

API_AVAILABLE(macCatalyst(17.0))
static BOOL pt_cameraUsesNativePlatform(PlaySettings *settings) {
    SEL sel = NSSelectorFromString(@"useNativePlatform");
    return [settings respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(settings, sel);
}

API_AVAILABLE(macCatalyst(17.0))
static CGFloat pt_alignedHorizonAngle(AVCaptureDeviceRotationCoordinator *coordinator, CGFloat angle) {
    // Under PlayCover's default iOS platform (!useNativePlatform), AVCaptureConnection uses
    // portrait sensor coordinates (90 deg = upright) whereas Catalyst's
    // AVCaptureDeviceRotationCoordinator reports 0 deg for landscape built-in Mac cameras.
    PlaySettings *settings = PlaySettings.shared;
    if (settings.cameraRotation == pt_automaticCameraRotation &&
        !pt_cameraUsesNativePlatform(settings) &&
        pt_isLocalBuiltInMacCamera(coordinator.device)) {
        return fmod(angle + 90.0, 360.0);
    }
    return angle;
}

API_AVAILABLE(macCatalyst(17.0))
static CGFloat pt_horizonPreviewAngle(AVCaptureDeviceRotationCoordinator *self, SEL command) {
    CGFloat angle = pt_nativeHorizonPreviewAngle(self, command);
    return pt_alignedHorizonAngle(self, angle);
}

API_AVAILABLE(macCatalyst(17.0))
static CGFloat pt_horizonCaptureAngle(AVCaptureDeviceRotationCoordinator *self, SEL command) {
    CGFloat angle = pt_nativeHorizonCaptureAngle(self, command);
    return pt_alignedHorizonAngle(self, angle);
}

static BOOL pt_applyCameraRotation(AVCaptureConnection *connection) {
    if (pt_applyingCameraAngle || !pt_nativeCameraAngle || !connection) { return NO; }
    if (@available(macCatalyst 17.0, *)) {
        NSInteger setting = PlaySettings.shared.cameraRotation;
        if (setting != 0 && setting != 90 && setting != 180 && setting != 270) { return NO; }
        AVCaptureDevice *device = pt_videoDeviceForConnection(connection);
        if (!device) { return NO; }

        CGFloat angle = (CGFloat)setting;
        if (![connection isVideoRotationAngleSupported:angle]) { return NO; }
        if (connection.videoRotationAngle != angle) {
            pt_applyingCameraAngle = YES;
            @try {
                pt_nativeCameraAngle(connection, @selector(setVideoRotationAngle:), angle);
            } @finally {
                pt_applyingCameraAngle = NO;
            }
        }
        return YES;
    }
    return NO;
}

static BOOL pt_applyCameraMirroring(AVCaptureConnection *connection) {
    if (pt_applyingCameraMirror || !pt_nativeSetVideoMirrored || !connection) { return NO; }
    if (!connection.videoPreviewLayer) { return NO; }
    AVCaptureDevicePosition role = pt_requestedCameraRoleForConnection(connection);
    NSInteger setting = pt_automaticCameraMirror;
    if (role == AVCaptureDevicePositionFront) {
        setting = PlaySettings.shared.cameraFrontMirror;
    } else if (role == AVCaptureDevicePositionBack) {
        setting = PlaySettings.shared.cameraBackMirror;
    }
    if (setting != 0 && setting != 1) { return NO; }
    if (![connection isVideoMirroringSupported]) { return NO; }

    BOOL wantMirrored = (setting == 1);
    pt_applyingCameraMirror = YES;
    @try {
        if (pt_nativeSetAutoMirroring && connection.automaticallyAdjustsVideoMirroring) {
            pt_nativeSetAutoMirroring(connection, @selector(setAutomaticallyAdjustsVideoMirroring:), NO);
        }
        if (connection.isVideoMirrored != wantMirrored) {
            pt_nativeSetVideoMirrored(connection, @selector(setVideoMirrored:), wantMirrored);
        }
    } @finally {
        pt_applyingCameraMirror = NO;
    }
    return YES;
}

static void pt_setCameraOrientation(AVCaptureConnection *connection, SEL command, AVCaptureVideoOrientation requested) {
    if (!pt_applyCameraRotation(connection)) { pt_nativeCameraOrientation(connection, command, requested); }
}

static void pt_setCameraAngle(AVCaptureConnection *connection, SEL command, CGFloat requested) {
    if (!pt_applyCameraRotation(connection)) { pt_nativeCameraAngle(connection, command, requested); }
}

static void pt_setCameraMirrored(AVCaptureConnection *connection, SEL command, BOOL mirrored) {
    if (!pt_applyCameraMirroring(connection)) { pt_nativeSetVideoMirrored(connection, command, mirrored); }
}

static void pt_setCameraAutoMirroring(AVCaptureConnection *connection, SEL command, BOOL autoAdjusts) {
    if (!pt_applyCameraMirroring(connection) && pt_nativeSetAutoMirroring) {
        pt_nativeSetAutoMirroring(connection, command, autoAdjusts);
    }
}

static void pt_applySessionRotations(AVCaptureSession *session) {
    for (AVCaptureConnection *connection in session.connections) {
        pt_applyCameraRotation(connection);
        pt_applyCameraMirroring(connection);
    }
}

static void pt_startCameraSession(AVCaptureSession *session, SEL command) {
    pt_applySessionRotations(session);
    pt_nativeStartCameraSession(session, command);
}

static void pt_commitCameraConfiguration(AVCaptureSession *session, SEL command) {
    pt_nativeCommitCameraConfiguration(session, command);
    pt_applySessionRotations(session);
}

static id pt_previewInitWithSession(AVCaptureVideoPreviewLayer *layer, SEL command, AVCaptureSession *session) {
    id result = pt_nativePreviewInitWithSession(layer, command, session);
    if ([result isKindOfClass:AVCaptureVideoPreviewLayer.class]) {
        AVCaptureConnection *conn = ((AVCaptureVideoPreviewLayer *)result).connection;
        pt_applyCameraRotation(conn);
        pt_applyCameraMirroring(conn);
    }
    return result;
}

static void pt_previewSetSession(AVCaptureVideoPreviewLayer *layer, SEL command, AVCaptureSession *session) {
    pt_nativePreviewSetSession(layer, command, session);
    AVCaptureConnection *conn = layer.connection;
    pt_applyCameraRotation(conn);
    pt_applyCameraMirroring(conn);
}

__attribute__((constructor))
static void pt_installCameraCompatibility(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle objectForInfoDictionaryKey:@"NSCameraUsageDescription"]) { return; }

        #define PT_CAMERA_HOOK(c, which, selectorName, original, hook) do { \
            Method method = class_get##which##Method(c.class, @selector(selectorName)); \
            if (method) original = (__typeof__(original))method_setImplementation(method, (IMP)hook); \
        } while (0)
        PT_CAMERA_HOOK(AVCaptureDevice, Class, defaultDeviceWithDeviceType:mediaType:position:,
                       pt_nativeTypedCamera, pt_selectCamera);
        PT_CAMERA_HOOK(AVCaptureDeviceDiscoverySession, Class, discoverySessionWithDeviceTypes:mediaType:position:,
                       pt_nativeCameraDiscovery, pt_discoverCameras);
        PT_CAMERA_HOOK(AVCaptureDeviceDiscoverySession, Instance, devices,
                       pt_nativeDiscoveryDevices, pt_discoveryDevices);
        PT_CAMERA_HOOK(AVCaptureDeviceInput, Instance, initWithDevice:error:,
                       pt_nativeInitDeviceInput, pt_initDeviceInput);
        PT_CAMERA_HOOK(AVCaptureConnection, Instance, setVideoMirrored:,
                       pt_nativeSetVideoMirrored, pt_setCameraMirrored);
        PT_CAMERA_HOOK(AVCaptureConnection, Instance, setAutomaticallyAdjustsVideoMirroring:,
                       pt_nativeSetAutoMirroring, pt_setCameraAutoMirroring);
        PT_CAMERA_HOOK(AVCaptureSession, Instance, startRunning, pt_nativeStartCameraSession, pt_startCameraSession);
        PT_CAMERA_HOOK(AVCaptureSession, Instance, commitConfiguration,
                       pt_nativeCommitCameraConfiguration, pt_commitCameraConfiguration);
        PT_CAMERA_HOOK(AVCaptureVideoPreviewLayer, Instance, initWithSession:,
                       pt_nativePreviewInitWithSession, pt_previewInitWithSession);
        PT_CAMERA_HOOK(AVCaptureVideoPreviewLayer, Instance, setSession:,
                       pt_nativePreviewSetSession, pt_previewSetSession);
        if (@available(macCatalyst 17.0, *)) {
            PT_CAMERA_HOOK(AVCaptureDeviceRotationCoordinator, Instance, videoRotationAngleForHorizonLevelPreview,
                           pt_nativeHorizonPreviewAngle, pt_horizonPreviewAngle);
            PT_CAMERA_HOOK(AVCaptureDeviceRotationCoordinator, Instance, videoRotationAngleForHorizonLevelCapture,
                           pt_nativeHorizonCaptureAngle, pt_horizonCaptureAngle);
            PT_CAMERA_HOOK(AVCaptureConnection, Instance, setVideoRotationAngle:, pt_nativeCameraAngle, pt_setCameraAngle);
            PT_CAMERA_HOOK(AVCaptureConnection, Instance, setVideoOrientation:,
                           pt_nativeCameraOrientation, pt_setCameraOrientation);
        }
        if (pt_nativeTypedCamera) {
            PT_CAMERA_HOOK(UIImagePickerController, Class, isCameraDeviceAvailable:,
                           pt_nativePickerAvailability, pt_pickerCameraAvailability);
            PT_CAMERA_HOOK(UIImagePickerController, Instance, setCameraDevice:,
                           pt_nativeSetPickerCameraDevice, pt_setPickerCameraDevice);
        }
        #undef PT_CAMERA_HOOK
    }
}
#endif
