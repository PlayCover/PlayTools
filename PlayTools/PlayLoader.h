//
//  PlayLoader.h
//  PlayTools
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "CoreGraphics/CoreGraphics.h"

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

#define DYLD_INTERPOSE_ORIG(_type,_replacee) \
   (*(_type const volatile *)&_interpose_##_replacee.replacee)

BOOL PTShouldEnableDuoVerticalBar(void);
void pt_seedWindowTransitionSizeBaselineIfNeeded(UIWindow *window, CGSize baselineSize);
void pt_recordRootViewControllerSizeTransition(UIViewController *viewController, CGSize size);
void pt_dispatchWindowResizeTransitionIfNeeded(UIWindow *window, CGSize newSize, BOOL isLiveResizing);
UIEdgeInsets pt_duoDiagnosticWindowSuperSafeAreaInsets(UIWindow *window);
UIEdgeInsets pt_duoDiagnosticWindowTrueNativeSafeAreaInsets(UIWindow *window);
NSDictionary *PTDuoCopyDecisionSnapshotForWindow(UIWindow *window);
void PTDuoSetGlobalBackRefreshHandler(void (^ _Nullable handler)(void));
BOOL PTDuoQueryGlobalBackStateForWindow(UIWindow * _Nullable window,
                                        BOOL includeTopClose,
                                        BOOL * _Nullable outHasSidebarBackButton);
BOOL PTDuoPerformGlobalBackActionForWindow(UIWindow * _Nullable window, BOOL includeTopClose);
BOOL PTDuoWindowHasActiveTextInput(UIWindow * _Nullable window);
BOOL PTDuoQueryGlobalHomeStateForWindow(UIWindow * _Nullable window);
BOOL PTDuoPerformGlobalHomeActionForWindow(UIWindow * _Nullable window);

@interface PlayLoader : NSObject

@end

