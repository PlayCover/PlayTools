//
//  ControllerFocus.m
//  PlayTools
//
//  Created by Edoardo C. on 23/02/26.
//

#import <Foundation/Foundation.h>
#import <GameController/GCController.h>
#import <objc/runtime.h>
#import <PlayTools/PlayTools-Swift.h>

__attribute__((visibility("hidden")))
@interface BackgroundControllerLoader : NSObject
@end

@implementation BackgroundControllerLoader
+ (void)load {
    [GCController setShouldMonitorBackgroundEvents:YES];
}
@end
