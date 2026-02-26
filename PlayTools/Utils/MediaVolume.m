//
//  MediaVolume.m
//  PlayTools
//
//  Created by Undefined on 2025/12/20.
//

#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <PlayTools/PlayTools-Swift.h>
#import "MediaVolume.h"

__attribute__((visibility("hidden")))
@interface MediaVolumeLoader : NSObject
@end

@implementation NSObject (SwizzleVolume)

- (void)swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    Class cls = [self class];
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    
    // Add selector if it doesn't exist, implement append with method
    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod))) {
        // Replace class instance method, added if selector not exist
        // For class cluster, it always adds new selector here
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        // SwizzleMethod maybe belongs to super
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

- (float)pm_get_volume {
    return 0.3f;
}

- (void)pm_set_volume:(float)value {
    return;
}

- (void)pm_set_volume:(float)value animated:(BOOL)animated {
    return;
}

@end

@implementation MediaVolumeLoader

+ (void)load {
    [objc_getClass("AVAudioSession") swizzleInstanceMethod:@selector(outputVolume) withMethod:@selector(pm_get_volume)];
    
    [objc_getClass("MPVolumeSlider") swizzleInstanceMethod:@selector(value) withMethod:@selector(pm_get_volume)];
    [objc_getClass("MPVolumeSlider") swizzleInstanceMethod:@selector(setValue:) withMethod:@selector(pm_set_volume:)];
    [objc_getClass("MPVolumeSlider") swizzleInstanceMethod:@selector(setValue:animated:) withMethod:@selector(pm_set_volume:animated:)];
    
    [objc_getClass("MPMusicPlayerController") swizzleInstanceMethod:@selector(volume) withMethod:@selector(pm_get_volume)];
    [objc_getClass("MPMusicPlayerController") swizzleInstanceMethod:@selector(setVolume:) withMethod:@selector(pm_set_volume:)];
}

@end
