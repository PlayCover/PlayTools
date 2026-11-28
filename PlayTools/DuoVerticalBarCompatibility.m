//
//  DuoVerticalBarCompatibility.m
//  PlayTools
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <os/signpost.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <PlayTools/PlayTools-Swift.h>
#import "PlayLoader.h"
#import "PTFakeMetaTouch.h"

BOOL PTShouldEnableDuoVerticalBar(void) {
    PlaySettings *settings = PlaySettings.shared;
    if (!settings.duoVerticalBar) {
        return NO;
    }
    SEL layoutSel = NSSelectorFromString(@"layoutIdiom");
    if ([settings respondsToSelector:layoutSel]) {
        NSInteger idiom = ((NSInteger (*)(id, SEL))objc_msgSend)(settings, layoutSel);
        return idiom == 3;
    }
    return YES;
}

#if TARGET_OS_MACCATALYST

static BOOL pt_duoIsPowerSavingModeEnabled(void) {
    const char *disable = getenv("PLAYTOOLS_DISABLE_POWER_SAVING");
    if (disable && disable[0] == '1' && disable[1] == '\0') {
        return NO;
    }
    PlaySettings *settings = [PlaySettings shared];
    SEL powerSel = NSSelectorFromString(@"powerSavingMode");
    if ([settings respondsToSelector:powerSel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(settings, powerSel);
    }
    return NO;
}

static UIColor *pt_duoOpaquePillBackgroundColor(BOOL isDark) {
    return isDark
        ? [UIColor colorWithRed:0.16 green:0.16 blue:0.18 alpha:1.0]
        : [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
}

static BOOL pt_duoResolvedColorRGBA(UIColor *color,
                                    UITraitCollection *traits,
                                    CGFloat *outR,
                                    CGFloat *outG,
                                    CGFloat *outB,
                                    CGFloat *outA,
                                    CGFloat *outLuma) {
    if (!color) {
        return NO;
    }
    UIColor *resolved = color;
    if (traits && [resolved respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [resolved resolvedColorWithTraitCollection:traits];
    }
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0.0;
        if (![resolved getWhite:&white alpha:&a]) {
            return NO;
        }
        r = white;
        g = white;
        b = white;
    }
    CGFloat luma = 0.299 * r + 0.587 * g + 0.114 * b;
    if (outR) { *outR = r; }
    if (outG) { *outG = g; }
    if (outB) { *outB = b; }
    if (outA) { *outA = a; }
    if (outLuma) { *outLuma = luma; }
    return YES;
}

static BOOL pt_duoColorIsBrightLight(UIColor *color, UITraitCollection *traits) {
    CGFloat a = 0.0, luma = 0.0;
    if (!pt_duoResolvedColorRGBA(color, traits, NULL, NULL, NULL, &a, &luma)) {
        return NO;
    }
    return (a > 0.5 && luma > 0.72);
}

static UIColor *pt_duoContrastSafeTintForPowerSaving(UIColor *candidateTint,
                                                     UIColor *neutralFG,
                                                     BOOL contextDark,
                                                     UITraitCollection *traits) {
    if (!candidateTint) {
        return neutralFG;
    }
    CGFloat a = 0.0, luma = 0.0;
    if (!pt_duoResolvedColorRGBA(candidateTint, traits, NULL, NULL, NULL, &a, &luma)) {
        return neutralFG;
    }
    if (a < 0.25) {
        return neutralFG;
    }
    if (!contextDark && luma > 0.68) {
        return neutralFG;
    }
    if (contextDark && luma < 0.32) {
        return neutralFG;
    }
    return candidateTint;
}

static const CGFloat kPTDuoVerticalBarWidth = 52.0;
static const CGFloat kPTDuoVerticalBarMinWindowWidth = 600.0;
static const CGFloat kPTDuoVerticalBarMinWindowHeight = 320.0;

// MARK: - PTDuoVerticalBarMath

static inline BOOL PTDuoShouldActivateForGeometry(BOOL settingEnabled,
                                                  CGFloat windowWidth,
                                                  CGFloat windowHeight,
                                                  NSInteger preferredBehavior) {
    // UIVerticalBarBehaviorDisabled == 1
    return settingEnabled
        && isfinite(windowWidth) && isfinite(windowHeight)
        && windowWidth >= kPTDuoVerticalBarMinWindowWidth
        && windowHeight >= kPTDuoVerticalBarMinWindowHeight
        && preferredBehavior != 1;
}

static inline UIRectEdge PTDuoResolvePhysicalBarEdge(BOOL isDirectional,
                                                     UIRectEdge edge,
                                                     NSDirectionalRectEdge directionalEdge,
                                                     UIUserInterfaceLayoutDirection layoutDirection) {
    if (!isDirectional) {
        return edge;
    }
    BOOL isRTL = (layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
    if (directionalEdge == NSDirectionalRectEdgeTrailing) {
        return isRTL ? UIRectEdgeLeft : UIRectEdgeRight;
    }
    if (directionalEdge == NSDirectionalRectEdgeLeading) {
        return isRTL ? UIRectEdgeRight : UIRectEdgeLeft;
    }
    if (directionalEdge == NSDirectionalRectEdgeTop) {
        return UIRectEdgeTop;
    }
    if (directionalEdge == NSDirectionalRectEdgeBottom) {
        return UIRectEdgeBottom;
    }
    return UIRectEdgeNone;
}

static inline CGFloat PTDuoResolveBarExtent(BOOL hasExplicitExtent,
                                            CGFloat requestedExtent,
                                            CGFloat viewWidth) {
    CGFloat extent = (hasExplicitExtent && isfinite(requestedExtent) && requestedExtent > 0.0)
        ? requestedExtent
        : kPTDuoVerticalBarWidth;
    if (isfinite(viewWidth) && viewWidth > 0.0) {
        extent = MIN(extent, viewWidth);
    }
    return extent;
}

static inline BOOL PTDuoRectIsFloatingVerticalRail(CGRect rectInWindow, CGRect windowBounds) {
    CGFloat winW = CGRectGetWidth(windowBounds);
    CGFloat winH = CGRectGetHeight(windowBounds);
    if (winW < kPTDuoVerticalBarMinWindowWidth || winH < kPTDuoVerticalBarMinWindowHeight) {
        return NO;
    }
    CGFloat w = CGRectGetWidth(rectInWindow);
    CGFloat h = CGRectGetHeight(rectInWindow);
    if (!isfinite(w) || !isfinite(h)) {
        return NO;
    }
    if (h < 120.0 || w < 36.0 || w > 64.0 || h < w * 2.0) {
        return NO;
    }
    CGFloat minX = CGRectGetMinX(rectInWindow);
    CGFloat maxX = CGRectGetMaxX(rectInWindow);
    CGFloat maxWinX = CGRectGetMaxX(windowBounds);
    return (minX >= maxWinX - 84.0) && (maxX >= maxWinX - 28.0);
}

static inline BOOL PTDuoRectIsAppSidebarCandidate(CGRect rectInWindow, CGRect windowBounds) {
    CGFloat winW = CGRectGetWidth(windowBounds);
    CGFloat winH = CGRectGetHeight(windowBounds);
    if (winW < kPTDuoVerticalBarMinWindowWidth || winH < kPTDuoVerticalBarMinWindowHeight) {
        return NO;
    }
    CGFloat w = CGRectGetWidth(rectInWindow);
    CGFloat h = CGRectGetHeight(rectInWindow);
    CGFloat detectSpan = MAX(kPTDuoVerticalBarWidth, 60.0);
    if (!isfinite(w) || !isfinite(h) || w < 24.0 || w > (detectSpan + 24.0) || h < 40.0) {
        return NO;
    }
    if (PTDuoRectIsFloatingVerticalRail(rectInWindow, windowBounds)) {
        return YES;
    }
    CGFloat minX = CGRectGetMinX(rectInWindow);
    CGFloat maxX = CGRectGetMaxX(rectInWindow);
    CGFloat stripStart = CGRectGetMaxX(windowBounds) - detectSpan;
    return (minX >= stripStart - 12.0) && (maxX >= CGRectGetMaxX(windowBounds) - 20.0);
}

static inline BOOL PTDuoRectLooksLikeSubstantialSidebar(CGRect rectInWindow,
                                                        CGRect windowBounds,
                                                        BOOL backedByLayoutRegion,
                                                        NSInteger distinctInteractiveCount) {
    if (!PTDuoRectIsAppSidebarCandidate(rectInWindow, windowBounds)) {
        return NO;
    }
    CGFloat w = CGRectGetWidth(rectInWindow);
    CGFloat h = CGRectGetHeight(rectInWindow);
    // Tall vertical rail / multi-widget column (e.g. map widget sidebar)
    if (h >= 84.0) {
        return YES;
    }
    // Multiple vertically stacked interactive controls inside the container
    if (distinctInteractiveCount >= 2) {
        return YES;
    }
    // Compact dedicated right-edge bar explicitly backed by UIViewLayoutRegion
    // (e.g. Amap Route AJXSidebarView {W-60, 30, 60, 48}): must sit flush in the
    // trailing strip rather than a margin-inset corner button (e.g. 44x40 Search button).
    if (backedByLayoutRegion && w >= 44.0) {
        CGFloat minX = CGRectGetMinX(rectInWindow);
        CGFloat maxX = CGRectGetMaxX(rectInWindow);
        CGFloat detectSpan = MAX(kPTDuoVerticalBarWidth, 60.0);
        CGFloat stripStart = CGRectGetMaxX(windowBounds) - detectSpan;
        if (minX >= stripStart - 4.0 && maxX >= CGRectGetMaxX(windowBounds) - 8.0) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL PTDuoShouldAcceptSidebarInCollapsedState(BOOL allowAllSidebars,
                                                            CGRect rectInWindow,
                                                            CGRect windowBounds,
                                                            BOOL backedByLayoutRegion,
                                                            NSInteger distinctInteractiveCount) {
    if (allowAllSidebars) {
        return PTDuoRectLooksLikeSubstantialSidebar(rectInWindow, windowBounds, backedByLayoutRegion, distinctInteractiveCount);
    }
    return PTDuoRectIsFloatingVerticalRail(rectInWindow, windowBounds)
        && PTDuoRectLooksLikeSubstantialSidebar(rectInWindow, windowBounds, backedByLayoutRegion, distinctInteractiveCount);
}

typedef NS_ENUM(NSInteger, PTDuoNavBarSuppressionMode) {
    PTDuoNavBarSuppressionNone = 0,
    PTDuoNavBarSuppressionFull = 1,
    PTDuoNavBarSuppressionItemsOnly = 2,
};

static inline PTDuoNavBarSuppressionMode PTDuoClassifyNavBarSuppression(BOOL navBarVisibleByApp,
                                                                        BOOL mirroredNavBarItemsOrBack,
                                                                        BOOL hasUnmirroredTopBarContent) {
    if (!navBarVisibleByApp || !mirroredNavBarItemsOrBack) {
        return PTDuoNavBarSuppressionNone;
    }
    return hasUnmirroredTopBarContent ? PTDuoNavBarSuppressionItemsOnly : PTDuoNavBarSuppressionFull;
}

static inline BOOL PTDuoShouldSuppressFloatingBarHost(BOOL hasCompactAboveBottomBand,
                                                      BOOL hasBottomChrome) {
    return hasBottomChrome && !hasCompactAboveBottomBand;
}

static inline CGFloat PTDuoAdjustedSuppressedNavBarTopInset(CGFloat originalTopInset,
                                                            BOOL insetsAreAbsolute,
                                                            CGFloat windowTopSafeArea) {
    if (!isfinite(originalTopInset) || originalTopInset <= 0.0) {
        return 0.0;
    }
    if (!insetsAreAbsolute) {
        // Relative delta added solely by the suppressed UINavigationBar above window safe area.
        return 0.0;
    }
    CGFloat baseline = (isfinite(windowTopSafeArea) && windowTopSafeArea > 0.0) ? windowTopSafeArea : 0.0;
    return MIN(originalTopInset, baseline);
}

static inline BOOL PTDuoChildFrameCoversContainer(CGRect childFrame, CGRect containerBounds) {
    CGFloat cw = CGRectGetWidth(containerBounds);
    CGFloat ch = CGRectGetHeight(containerBounds);
    if (!isfinite(cw) || !isfinite(ch) || cw <= 1.0 || ch <= 1.0) {
        return NO;
    }
    CGRect clipped = CGRectIntersection(childFrame, containerBounds);
    if (CGRectIsNull(clipped) || CGRectIsEmpty(clipped)) {
        return NO;
    }
    CGFloat clippedArea = CGRectGetWidth(clipped) * CGRectGetHeight(clipped);
    CGFloat containerArea = cw * ch;
    return isfinite(clippedArea) && containerArea > 0.0 && (clippedArea >= containerArea * 0.50);
}

static inline BOOL PTDuoShouldShowSyntheticBackButton(BOOL hasNavController,
                                                      BOOL navBarHiddenByApp,
                                                      NSUInteger stackCount,
                                                      BOOL hidesBackButtonByApp) {
    return hasNavController && !navBarHiddenByApp && stackCount > 1 && !hidesBackButtonByApp;
}

static inline BOOL PTDuoShouldCollapseEmptyRightInset(BOOL barStateActive,
                                                      BOOL probingRightInset,
                                                      BOOL hostHasVisibleItems,
                                                      BOOL hasAppRenderedSidebar,
                                                      BOOL queriedRightBarRegion) {
    if (!barStateActive || probingRightInset) {
        return NO;
    }
    return !hostHasVisibleItems && !hasAppRenderedSidebar && !queriedRightBarRegion;
}

static inline CGFloat PTDuoResolveOccupiedRightBarWidth(BOOL barStateActive,
                                                        BOOL probingRightInset,
                                                        BOOL hostHasVisibleItems,
                                                        BOOL hasAppRenderedSidebar,
                                                        CGFloat detectedSidebarOccupiedWidth,
                                                        BOOL queriedRightBarRegion,
                                                        CGFloat queriedRightBarExtent) {
    if (!barStateActive) {
        return 0.0;
    }
    if (hostHasVisibleItems) {
        return kPTDuoVerticalBarWidth;
    }
    if (hasAppRenderedSidebar) {
        CGFloat w = (isfinite(detectedSidebarOccupiedWidth) && detectedSidebarOccupiedWidth > 0.0)
            ? detectedSidebarOccupiedWidth
            : kPTDuoVerticalBarWidth;
        return MIN(MAX(w, kPTDuoVerticalBarWidth), 84.0);
    }
    if (queriedRightBarRegion) {
        CGFloat w = (isfinite(queriedRightBarExtent) && queriedRightBarExtent > 0.0)
            ? queriedRightBarExtent
            : kPTDuoVerticalBarWidth;
        return MIN(MAX(w, kPTDuoVerticalBarWidth), 84.0);
    }
    if (probingRightInset) {
        return kPTDuoVerticalBarWidth;
    }
    return 0.0;
}

static inline CGFloat PTDuoEffectiveRightSafeAreaInset(BOOL barStateActive,
                                                       BOOL collapsedEmptyRightInset,
                                                       CGFloat existingRightInset) {
    CGFloat safeExisting = isfinite(existingRightInset) ? existingRightInset : 0.0;
    if (!barStateActive || collapsedEmptyRightInset) {
        return safeExisting;
    }
    return MAX(safeExisting, kPTDuoVerticalBarWidth);
}

static inline CGFloat PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(BOOL barStateActive,
                                                                       CGFloat occupiedBarWidth,
                                                                       CGFloat existingRightInset) {
    CGFloat safeExisting = isfinite(existingRightInset) ? existingRightInset : 0.0;
    if (!barStateActive || !isfinite(occupiedBarWidth) || occupiedBarWidth <= 0.0) {
        return safeExisting;
    }
    return MAX(safeExisting, occupiedBarWidth);
}

static inline UIEdgeInsets PTDuoBarRegionEdgeInsets(UIRectEdge physicalEdge,
                                                    CGFloat viewWidth,
                                                    CGFloat viewHeight,
                                                    CGFloat extent) {
    CGFloat w = (isfinite(viewWidth) && viewWidth > 0.0) ? viewWidth : 0.0;
    CGFloat h = (isfinite(viewHeight) && viewHeight > 0.0) ? viewHeight : 0.0;
    CGFloat e = (isfinite(extent) && extent > 0.0) ? extent : 0.0;
    if (physicalEdge == UIRectEdgeRight) {
        return UIEdgeInsetsMake(0.0, MAX(0.0, w - e), 0.0, 0.0);
    }
    if (physicalEdge == UIRectEdgeLeft) {
        return UIEdgeInsetsMake(0.0, 0.0, 0.0, MAX(0.0, w - e));
    }
    if (physicalEdge == UIRectEdgeBottom) {
        return UIEdgeInsetsMake(MAX(0.0, h - e), 0.0, 0.0, 0.0);
    }
    if (physicalEdge == UIRectEdgeTop) {
        return UIEdgeInsetsMake(0.0, 0.0, MAX(0.0, h - e), 0.0);
    }
    return UIEdgeInsetsZero;
}

static inline NSDirectionalEdgeInsets PTDuoBarRegionDirectionalEdgeInsets(UIRectEdge physicalEdge,
                                                                          UIUserInterfaceLayoutDirection layoutDirection,
                                                                          CGFloat viewWidth,
                                                                          CGFloat viewHeight,
                                                                          CGFloat extent) {
    UIEdgeInsets phys = PTDuoBarRegionEdgeInsets(physicalEdge, viewWidth, viewHeight, extent);
    BOOL isRTL = (layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
    return NSDirectionalEdgeInsetsMake(phys.top,
                                       isRTL ? phys.right : phys.left,
                                       phys.bottom,
                                       isRTL ? phys.left : phys.right);
}

static inline BOOL PTDuoInferRightBarExtentFromEdgeInsets(UIEdgeInsets insets,
                                                          CGFloat viewWidth,
                                                          CGFloat *outExtent) {
    if (!isfinite(viewWidth) || viewWidth < kPTDuoVerticalBarMinWindowWidth) {
        return NO;
    }
    if (!isfinite(insets.top) || !isfinite(insets.left) || !isfinite(insets.bottom) || !isfinite(insets.right)) {
        return NO;
    }
    if (fabs(insets.top) > 0.5 || fabs(insets.bottom) > 0.5 || fabs(insets.right) > 0.5 || insets.left <= 0.5) {
        return NO;
    }
    CGFloat barWidth = viewWidth - insets.left;
    if (barWidth >= 24.0 && barWidth <= 120.0) {
        if (outExtent) { *outExtent = barWidth; }
        return YES;
    }
    return NO;
}

static inline UIEdgeInsets PTDuoAdjustRightBarEdgeInsetsWithTopClearance(UIEdgeInsets origInsets,
                                                                         CGFloat viewWidth,
                                                                         CGFloat viewHeight,
                                                                         CGFloat syntheticRightInset,
                                                                         CGFloat minTopClearance,
                                                                         BOOL *outIsRightBar,
                                                                         CGFloat *outBarExtent) {
    if (outIsRightBar) { *outIsRightBar = NO; }
    if (outBarExtent) { *outBarExtent = 0.0; }
    if (!isfinite(viewWidth) || viewWidth < 120.0
        || !isfinite(origInsets.top) || !isfinite(origInsets.left)
        || !isfinite(origInsets.bottom) || !isfinite(origInsets.right)) {
        return origInsets;
    }
    CGFloat barWidth = viewWidth - origInsets.left - origInsets.right;
    if (!isfinite(barWidth) || barWidth < 20.0 || barWidth > 120.0) {
        return origInsets;
    }
    if (origInsets.left < viewWidth * 0.5) {
        return origInsets;
    }
    if (isfinite(viewHeight) && viewHeight > 80.0
        && (origInsets.top + origInsets.bottom) >= viewHeight - 40.0) {
        return origInsets;
    }
    CGFloat safeSynth = (isfinite(syntheticRightInset) && syntheticRightInset > 0.0) ? syntheticRightInset : 0.0;
    if (origInsets.right + 0.5 < safeSynth) {
        return origInsets;
    }
    if (outIsRightBar) { *outIsRightBar = YES; }
    if (outBarExtent) { *outBarExtent = barWidth; }

    UIEdgeInsets adjusted = origInsets;
    if (safeSynth > 0.001 && origInsets.right > 0.001) {
        CGFloat strip = MIN(origInsets.right, safeSynth);
        adjusted.right = MAX(0.0, origInsets.right - strip);
        adjusted.left = MAX(0.0, viewWidth - adjusted.right - barWidth);
    }
    if (isfinite(minTopClearance) && minTopClearance > 0.5
        && isfinite(viewHeight) && viewHeight > minTopClearance + 40.0) {
        CGFloat clampedTop = MIN(minTopClearance, viewHeight * 0.25);
        if (adjusted.top < clampedTop) {
            adjusted.top = clampedTop;
        }
    }
    return adjusted;
}

static inline UIEdgeInsets PTDuoAdjustRightBarEdgeInsets(UIEdgeInsets origInsets,
                                                         CGFloat viewWidth,
                                                         CGFloat viewHeight,
                                                         CGFloat syntheticRightInset,
                                                         BOOL *outIsRightBar,
                                                         CGFloat *outBarExtent) {
    return PTDuoAdjustRightBarEdgeInsetsWithTopClearance(origInsets,
                                                         viewWidth,
                                                         viewHeight,
                                                         syntheticRightInset,
                                                         0.0,
                                                         outIsRightBar,
                                                         outBarExtent);
}

static inline NSDirectionalEdgeInsets PTDuoAdjustRightBarDirectionalEdgeInsetsWithTopClearance(NSDirectionalEdgeInsets origInsets,
                                                                                           UIUserInterfaceLayoutDirection layoutDirection,
                                                                                           CGFloat viewWidth,
                                                                                           CGFloat viewHeight,
                                                                                           CGFloat syntheticRightInset,
                                                                                           CGFloat minTopClearance,
                                                                                           BOOL *outIsRightBar,
                                                                                           CGFloat *outBarExtent) {
    BOOL isRTL = (layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
    UIEdgeInsets physOrig = UIEdgeInsetsMake(origInsets.top,
                                             isRTL ? origInsets.trailing : origInsets.leading,
                                             origInsets.bottom,
                                             isRTL ? origInsets.leading : origInsets.trailing);
    BOOL isRightBar = NO;
    CGFloat barExtent = 0.0;
    UIEdgeInsets physAdj = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(physOrig,
                                                                         viewWidth,
                                                                         viewHeight,
                                                                         syntheticRightInset,
                                                                         minTopClearance,
                                                                         &isRightBar,
                                                                         &barExtent);
    if (outIsRightBar) { *outIsRightBar = isRightBar; }
    if (outBarExtent) { *outBarExtent = barExtent; }
    if (!isRightBar) {
        return origInsets;
    }
    return NSDirectionalEdgeInsetsMake(physAdj.top,
                                       isRTL ? physAdj.right : physAdj.left,
                                       physAdj.bottom,
                                       isRTL ? physAdj.left : physAdj.right);
}

static inline NSDirectionalEdgeInsets PTDuoAdjustRightBarDirectionalEdgeInsets(NSDirectionalEdgeInsets origInsets,
                                                                           UIUserInterfaceLayoutDirection layoutDirection,
                                                                           CGFloat viewWidth,
                                                                           CGFloat viewHeight,
                                                                           CGFloat syntheticRightInset,
                                                                           BOOL *outIsRightBar,
                                                                           CGFloat *outBarExtent) {
    return PTDuoAdjustRightBarDirectionalEdgeInsetsWithTopClearance(origInsets,
                                                                    layoutDirection,
                                                                    viewWidth,
                                                                    viewHeight,
                                                                    syntheticRightInset,
                                                                    0.0,
                                                                    outIsRightBar,
                                                                    outBarExtent);
}

static inline CGRect PTDuoTopRightOcclusionRectForOccupiedWidth(CGRect windowBounds,
                                                                CGFloat nativeSafeTop,
                                                                CGFloat hostTopPillMaxY,
                                                                CGFloat occupiedRightBarWidth) {
    CGFloat winW = CGRectGetWidth(windowBounds);
    CGFloat winH = CGRectGetHeight(windowBounds);
    if (!isfinite(winW) || !isfinite(winH)
        || winW < kPTDuoVerticalBarMinWindowWidth
        || winH < kPTDuoVerticalBarMinWindowHeight) {
        return CGRectNull;
    }
    CGFloat width = (isfinite(occupiedRightBarWidth) && occupiedRightBarWidth > 0.5)
        ? MIN(MAX(kPTDuoVerticalBarWidth, occupiedRightBarWidth), 84.0)
        : kPTDuoVerticalBarWidth;
    CGFloat safeTop = (isfinite(nativeSafeTop) && nativeSafeTop > 0.0) ? nativeSafeTop : 0.0;
    CGFloat pillMaxY = (isfinite(hostTopPillMaxY) && hostTopPillMaxY > 0.0) ? hostTopPillMaxY : 0.0;
    CGFloat height = MAX(32.0, MIN(winH * 0.25, MAX(safeTop, pillMaxY)));
    return CGRectMake(CGRectGetMaxX(windowBounds) - width,
                      CGRectGetMinY(windowBounds),
                      width,
                      height);
}

static inline CGRect PTDuoTopRightOcclusionRect(CGRect windowBounds,
                                                CGFloat nativeSafeTop,
                                                CGFloat hostTopPillMaxY) {
    return PTDuoTopRightOcclusionRectForOccupiedWidth(windowBounds,
                                                       nativeSafeTop,
                                                       hostTopPillMaxY,
                                                       kPTDuoVerticalBarWidth);
}

static inline BOOL PTDuoNavItemEffectiveHidesBackButton(BOOL explicitHidesBackButton,
                                                        BOOL leftItemsSupplementBackButton,
                                                        BOOL hasVisibleLeadingItems) {
    if (explicitHidesBackButton) {
        return YES;
    }
    return (!leftItemsSupplementBackButton && hasVisibleLeadingItems);
}

static inline BOOL PTDuoShouldNotifySafeAreaChange(CGFloat prevOccupiedWidth,
                                                   CGFloat nowOccupiedWidth,
                                                   CGFloat actualWindowRightInset,
                                                   CGFloat expectedRightInset,
                                                   BOOL epochChanged,
                                                   BOOL hostBecameVisible,
                                                   NSInteger driftRetryCount) {
    CGFloat safePrev = isfinite(prevOccupiedWidth) ? prevOccupiedWidth : 0.0;
    CGFloat safeNow = isfinite(nowOccupiedWidth) ? nowOccupiedWidth : 0.0;
    if (fabs(safePrev - safeNow) > 0.5) {
        return YES;
    }
    CGFloat safeActual = isfinite(actualWindowRightInset) ? actualWindowRightInset : 0.0;
    CGFloat safeExpected = isfinite(expectedRightInset) ? expectedRightInset : 0.0;
    if ((safeExpected > 0.5 || safeActual > 0.5)
        && fabs(safeActual - safeExpected) > 0.5
        && driftRetryCount < 3) {
        return YES;
    }
    if ((epochChanged || hostBecameVisible) && safeNow > 0.5) {
        return YES;
    }
    return NO;
}

static inline BOOL PTDuoShouldSeedInitialTransitionBaseline(CGSize currentBaselineSize,
                                                             CGSize candidateSize) {
    if (!isfinite(candidateSize.width) || !isfinite(candidateSize.height)
        || candidateSize.width < 100.0 || candidateSize.height < 100.0) {
        return NO;
    }
    return !isfinite(currentBaselineSize.width) || !isfinite(currentBaselineSize.height)
        || currentBaselineSize.width < 100.0 || currentBaselineSize.height < 100.0;
}

static inline BOOL PTDuoShouldDispatchViewWillTransitionToSize(CGSize lastDeliveredSize,
                                                              CGSize newBoundsSize,
                                                              BOOL isLiveResizing,
                                                              BOOL isReentering) {
    if (isLiveResizing || isReentering) {
        return NO;
    }
    if (!isfinite(newBoundsSize.width) || !isfinite(newBoundsSize.height)
        || newBoundsSize.width < 100.0 || newBoundsSize.height < 100.0) {
        return NO;
    }
    if (!isfinite(lastDeliveredSize.width) || !isfinite(lastDeliveredSize.height)
        || lastDeliveredSize.width < 100.0 || lastDeliveredSize.height < 100.0) {
        return NO;
    }
    return fabs(lastDeliveredSize.width - newBoundsSize.width) > 1.0
        || fabs(lastDeliveredSize.height - newBoundsSize.height) > 1.0;
}

static inline BOOL PTDuoShouldNotifySafeAreaAfterSettledResize(CGSize lastNotifiedSize,
                                                               CGSize newBoundsSize,
                                                               BOOL isLiveResizing,
                                                               BOOL isDispatching) {
    return PTDuoShouldDispatchViewWillTransitionToSize(lastNotifiedSize,
                                                       newBoundsSize,
                                                       isLiveResizing,
                                                       isDispatching);
}

static const double kPTDuoRecentRightBarQueryWindowSeconds = 0.25;

static inline UIEdgeInsets PTDuoEffectiveSceneSafeAreaInsets(BOOL barStateActive,
                                                             CGFloat occupiedBarWidth,
                                                             CGSize windowSize,
                                                             UIEdgeInsets nativeInsets) {
    UIEdgeInsets result = nativeInsets;
    if (!isfinite(result.top)) { result.top = 0.0; }
    if (!isfinite(result.left)) { result.left = 0.0; }
    if (!isfinite(result.bottom)) { result.bottom = 0.0; }
    if (!isfinite(result.right)) { result.right = 0.0; }

    if (barStateActive) {
        // Real unfolded iPhone Duo (landscape inner display) has 0pt top safe-area inset
        // because the status bar occupies the top-right vertical-bar occlusion region.
        // Mac Catalyst injects macOS titlebar height (~28-32pt) into top while left==0,
        // which triggers iOS 26 landscape safe-area workarounds checking top > left.
        if (isfinite(windowSize.width) && isfinite(windowSize.height)
            && windowSize.width > windowSize.height
            && result.left <= 0.5) {
            result.top = 0.0;
        }
        result.right = PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(
            barStateActive, occupiedBarWidth, result.right);
    }
    return result;
}

static inline CGFloat PTDuoTrafficLightTopClearance(BOOL barStateActive,
                                                    BOOL hideTitleBar,
                                                    CGSize windowSize,
                                                    UIEdgeInsets trueNativeInsets) {
    if (!barStateActive || !hideTitleBar) {
        return 0.0;
    }
    if (!isfinite(windowSize.width) || !isfinite(windowSize.height)
        || windowSize.width <= windowSize.height) {
        return 0.0;
    }
    if (!isfinite(trueNativeInsets.left) || trueNativeInsets.left > 0.5) {
        return 0.0;
    }
    if (!isfinite(trueNativeInsets.top) || trueNativeInsets.top <= 0.5) {
        return 0.0;
    }
    return trueNativeInsets.top;
}

static inline BOOL PTDuoResolveStatusBarHidden(BOOL barStateActive,
                                               BOOL originalHidden,
                                               BOOL activeVCPrefersHidden) {
    if (!barStateActive) {
        return originalHidden;
    }
    return activeVCPrefersHidden;
}

static inline BOOL PTDuoShouldPreserveRecentRightBarQuery(BOOL wasActive,
                                                          BOOL leafVCUnchanged,
                                                          BOOL queriedRightBarRegion,
                                                          double queryAgeSeconds) {
    return wasActive
        && leafVCUnchanged
        && queriedRightBarRegion
        && isfinite(queryAgeSeconds)
        && queryAgeSeconds >= 0.0
        && queryAgeSeconds < kPTDuoRecentRightBarQueryWindowSeconds;
}

static inline BOOL PTDuoViewIsVisualTitleView(BOOL hasTitleView,
                                              BOOL hidden,
                                              CGFloat alpha,
                                              CGRect bounds,
                                              NSUInteger subviewCount) {
    if (!hasTitleView || hidden || !isfinite(alpha) || alpha <= 0.01) {
        return NO;
    }
    if (CGRectIsEmpty(bounds) && subviewCount == 0) {
        return NO;
    }
    return YES;
}

static inline BOOL PTDuoShouldRelocateLeadingBarItemWithRole(BOOL appWantsHidden,
                                                              NSInteger axisBehavior,
                                                              BOOL hasStandardVisualAndAction,
                                                              BOOL isIconOnlyStandardItem,
                                                              BOOL hasCustomView,
                                                              CGSize customViewSize,
                                                              BOOL customViewIsVisibleAndActionable,
                                                              BOOL isLeadingItem,
                                                              BOOL navBarHasHorizontalOnlyChrome,
                                                              BOOL showBack) {
    // UIBarButtonItemAxisBehaviorHorizontalOnly == 1
    if (appWantsHidden || axisBehavior == 1) {
        return NO;
    }
    BOOL eligibleContent = NO;
    if (hasStandardVisualAndAction) {
        eligibleContent = YES;
    } else if (hasCustomView && customViewIsVisibleAndActionable) {
        CGFloat w = isfinite(customViewSize.width) ? customViewSize.width : 0.0;
        CGFloat h = isfinite(customViewSize.height) ? customViewSize.height : 0.0;
        if (w > 0.5 && h > 0.5 && w <= 84.0 && h <= 64.0) {
            eligibleContent = YES;
        }
    }
    if (!eligibleContent) {
        return NO;
    }
    if (isLeadingItem) {
        // UIBarButtonItemAxisBehaviorVerticalPreferred == 2 always relocates;
        // Automatic (0) leading items relocate when top bar has no horizontal-only chrome OR
        // when it is a compact icon-only standard UIBarButtonItem and synthetic '<' back is absent.
        return (axisBehavior == 2)
            || !navBarHasHorizontalOnlyChrome
            || (!showBack && !hasCustomView && isIconOnlyStandardItem);
    }
    return YES;
}

static inline BOOL PTDuoIsStandardIconOnlyBarItem(BOOL hasCustomView, BOOL hasImage) {
    // In UIKit, a standard UIBarButtonItem (customView == nil) with an image displays only the icon
    // in horizontal bars even when `title` is populated for accessibility or menus.
    return (!hasCustomView && hasImage);
}

static inline BOOL PTDuoShouldRelocateBarItem(BOOL appWantsHidden,
                                              NSInteger axisBehavior,
                                              BOOL hasStandardVisualAndAction,
                                              BOOL hasCustomView,
                                              CGSize customViewSize,
                                              BOOL customViewIsVisibleAndActionable,
                                              BOOL isLeadingItem,
                                              BOOL navBarHasHorizontalOnlyChrome) {
    return PTDuoShouldRelocateLeadingBarItemWithRole(appWantsHidden,
                                                      axisBehavior,
                                                      hasStandardVisualAndAction,
                                                      NO,
                                                      hasCustomView,
                                                      customViewSize,
                                                      customViewIsVisibleAndActionable,
                                                      isLeadingItem,
                                                      navBarHasHorizontalOnlyChrome,
                                                      YES);
}

static inline BOOL PTDuoTabSlotOverlayMatchesCenterX(CGFloat candidateMidX,
                                                     NSUInteger slotIndex,
                                                     NSUInteger totalSlots,
                                                     CGFloat tabBarWidth) {
    if (totalSlots < 2 || !isfinite(tabBarWidth) || tabBarWidth <= 1.0
        || slotIndex >= totalSlots || !isfinite(candidateMidX)) {
        return NO;
    }
    CGFloat slotWidth = tabBarWidth / (CGFloat)totalSlots;
    CGFloat slotCenter = ((CGFloat)slotIndex + 0.5) * slotWidth;
    CGFloat tol = MAX(slotWidth * 0.48, 28.0);
    return fabs(candidateMidX - slotCenter) <= tol;
}

static inline BOOL PTDuoShouldPromoteTabOverlayToProminent(BOOL hasExistingProminent,
                                                           BOOL isOpaqueFilledBadge,
                                                           BOOL isSaturatedAccentBadge,
                                                           BOOL hasCircularAccentBg,
                                                           BOOL protrudesAboveBar) {
    if (hasExistingProminent) {
        return NO;
    }
    return (isOpaqueFilledBadge && isSaturatedAccentBadge) || hasCircularAccentBg || protrudesAboveBar;
}

static inline BOOL PTDuoCanSafelyRelocateTabDock(BOOL hasUnknownActionableSlot,
                                                  NSUInteger visualSlotCount) {
    return !hasUnknownActionableSlot && visualSlotCount >= 2;
}

static inline void PTDuoComputeOverflowSplit(NSUInteger totalEligibleCount,
                                             NSUInteger maxVisibleSlots,
                                             NSUInteger *outDirectCount,
                                             BOOL *outNeedsOverflowMenu) {
    NSUInteger direct = 0;
    BOOL needsOverflow = NO;
    if (maxVisibleSlots == 0) {
        direct = 0;
        needsOverflow = NO;
    } else if (totalEligibleCount <= maxVisibleSlots) {
        direct = totalEligibleCount;
        needsOverflow = NO;
    } else {
        direct = (maxVisibleSlots >= 2) ? (maxVisibleSlots - 1) : 0;
        needsOverflow = YES;
    }
    if (outDirectCount) { *outDirectCount = direct; }
    if (outNeedsOverflowMenu) { *outNeedsOverflowMenu = needsOverflow; }
}

typedef NS_ENUM(NSInteger, PTDuoTabSlotActionKind) {
    PTDuoTabSlotActionNone = 0,
    PTDuoTabSlotActionControlOnly = 1,
    PTDuoTabSlotActionSelectTab = 2,
};

static inline PTDuoTabSlotActionKind PTDuoResolveTabOverlayActionKind(BOOL isRealTabSlot,
                                                                      BOOL hasActionControl,
                                                                      BOOL hasVisual) {
    if (!hasVisual && !hasActionControl) {
        return PTDuoTabSlotActionNone;
    }
    if (!isRealTabSlot) {
        return hasActionControl ? PTDuoTabSlotActionControlOnly : PTDuoTabSlotActionNone;
    }
    return PTDuoTabSlotActionSelectTab;
}

static inline BOOL PTDuoShouldRelocateTabBarWithSlots(NSUInteger realTabs,
                                                      NSUInteger blankSlots,
                                                      NSUInteger capturedBlankSlots,
                                                      BOOL isSpacer) {
    if (realTabs < 2) {
        return NO;
    }
    if (blankSlots == 0 || isSpacer) {
        return YES;
    }
    return capturedBlankSlots >= blankSlots;
}

typedef struct {
    BOOL hidden;
    CGFloat alpha;
    BOOL userInteractionEnabled;
} PTDuoSavedViewState;

static inline PTDuoSavedViewState PTDuoRestoreSavedViewState(PTDuoSavedViewState orig,
                                                             BOOL wasSuppressed) {
    if (!wasSuppressed) {
        return orig;
    }
    PTDuoSavedViewState out = {
        .hidden = orig.hidden,
        .alpha = isfinite(orig.alpha) ? orig.alpha : 1.0,
        .userInteractionEnabled = orig.userInteractionEnabled
    };
    return out;
}

static inline BOOL PTDuoShouldRecordRightBarRegionQuery(BOOL hasWindow, BOOL isActiveWindow) {
    return hasWindow && isActiveWindow;
}

static inline BOOL PTDuoShouldRefreshAfterTransition(BOOL wasCancelled, BOOL barStateActive) {
    return wasCancelled || barStateActive;
}

static inline BOOL PTDuoShouldPreserveOuterHeaderNav(BOOL outerNavBarVisible, BOOL innerNavBarVisible) {
    return outerNavBarVisible && !innerNavBarVisible;
}

static inline BOOL PTDuoShouldUseContrastFallbackForAccent(CGFloat fgR, CGFloat fgG, CGFloat fgB,
                                                           CGFloat bgR, CGFloat bgG, CGFloat bgB) {
    CGFloat fgLuma = 0.299 * fgR + 0.587 * fgG + 0.114 * fgB;
    CGFloat bgLuma = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
    CGFloat dr = fgR - bgR;
    CGFloat dg = fgG - bgG;
    CGFloat db = fgB - bgB;
    CGFloat colorDist = sqrt(dr * dr + dg * dg + db * db);
    return (fabs(fgLuma - bgLuma) < 0.25 && colorDist < 0.35);
}

static inline BOOL PTDuoShouldPreferWhiteOnAccentBackground(CGFloat bgR, CGFloat bgG, CGFloat bgB) {
    CGFloat bgLuma = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
    return bgLuma < 0.72;
}

static inline BOOL PTDuoSnapshotHasVisiblePixels(NSInteger visiblePixelCount, NSInteger totalSampled) {
    return totalSampled > 0 && visiblePixelCount > 0;
}

static inline void PTDuoInspectOpaqueBadgeResult(int opaqueInner,
                                                 int accentInner,
                                                 BOOL *outOpaqueFilled,
                                                 BOOL *outSaturatedAccent) {
    if (outOpaqueFilled) { *outOpaqueFilled = (opaqueInner >= 3); }
    if (outSaturatedAccent) { *outSaturatedAccent = (opaqueInner >= 3 && accentInner >= 1); }
}

static inline BOOL PTDuoRectIsEnclosedInnerStroke(CGRect innerRect, CGRect outerRect) {
    CGFloat outerW = CGRectGetWidth(outerRect);
    CGFloat outerH = CGRectGetHeight(outerRect);
    CGFloat innerW = CGRectGetWidth(innerRect);
    CGFloat innerH = CGRectGetHeight(innerRect);
    if (!isfinite(outerW) || !isfinite(outerH) || !isfinite(innerW) || !isfinite(innerH)) {
        return NO;
    }
    if (outerW < 26.0 || outerH < 20.0) {
        return NO;
    }
    if (MIN(innerW, innerH) < 1.5 || innerW > outerW * 0.72 || innerH > outerH * 0.72) {
        return NO;
    }
    CGRect paddedOuter = CGRectInset(outerRect, -2.0, -2.0);
    return CGRectContainsRect(paddedOuter, innerRect);
}

static inline BOOL PTDuoColorsHaveContrast(CGFloat r1, CGFloat g1, CGFloat b1, CGFloat a1,
                                           CGFloat r2, CGFloat g2, CGFloat b2, CGFloat a2) {
    if (!isfinite(a1) || !isfinite(a2) || a1 < 0.5 || a2 < 0.5) {
        return NO;
    }
    CGFloat luma1 = 0.299 * r1 + 0.587 * g1 + 0.114 * b1;
    CGFloat luma2 = 0.299 * r2 + 0.587 * g2 + 0.114 * b2;
    if (fabs(luma1 - luma2) >= 0.25) {
        return YES;
    }
    CGFloat maxChannelDiff = MAX(fabs(r1 - r2), MAX(fabs(g1 - g2), fabs(b1 - b2)));
    return maxChannelDiff >= 0.25;
}

static inline BOOL PTDuoTabItemSlotNeedsOverlay(BOOL isSelected,
                                                BOOL hasSelectedImage,
                                                BOOL selectedImageBlank,
                                                BOOL imageBlank,
                                                BOOL titleBlank) {
    if (!titleBlank) {
        return NO;
    }
    if (isSelected && hasSelectedImage) {
        return selectedImageBlank;
    }
    return imageBlank;
}

static inline BOOL PTDuoAlphaBufferHasVisiblePixels(const uint8_t *alphaBuf, NSUInteger count) {
    if (!alphaBuf || count == 0) {
        return NO;
    }
    for (NSUInteger i = 0; i < count; i++) {
        if (alphaBuf[i] >= 4) {
            return YES;
        }
    }
    return NO;
}

// MARK: - PTDuoGlobalBackMath

static inline NSInteger PTDuoPackGlobalBackStateBitmask(BOOL hasBack,
                                                        BOOL hasSidebarBack,
                                                        BOOL isTextInputActive) {
    NSInteger mask = 0;
    if (hasBack) { mask |= 1; }
    if (hasSidebarBack) { mask |= 2; }
    if (isTextInputActive) { mask |= 4; }
    return mask;
}

static inline BOOL PTDuoShouldShowTitlebarBackButton(BOOL titlebarBackEnabled,
                                                     BOOL onlyWhenNoSidebarBackButton,
                                                     BOOL hasBack,
                                                     BOOL hasSidebarBack) {
    if (!titlebarBackEnabled || !hasBack) {
        return NO;
    }
    if (onlyWhenNoSidebarBackButton && hasSidebarBack) {
        return NO;
    }
    return YES;
}

static inline BOOL PTDuoShouldInspectHorizontalNavItems(BOOL hasHeaderNav,
                                                        BOOL navBarVisibleByApp,
                                                        BOOL hasNavigationItem,
                                                        NSUInteger stackCount,
                                                        BOOL isModalPresented) {
    return hasHeaderNav
        && hasNavigationItem
        && (navBarVisibleByApp || stackCount > 1 || isModalPresented);
}

static inline BOOL PTDuoHostEntryCountsAsSidebarBack(BOOL isOverflowMenu,
                                                     BOOL hasItem,
                                                     BOOL enabled,
                                                     BOOL isLeadingOrNavBarBucket,
                                                     BOOL matchesBackCue,
                                                     BOOL includeTopClose,
                                                     BOOL matchesCloseCue) {
    if (isOverflowMenu || !hasItem || !enabled || !isLeadingOrNavBarBucket) {
        return NO;
    }
    return matchesBackCue || (includeTopClose && matchesCloseCue);
}

static inline BOOL PTDuoShouldPrioritizeCustomViewDispatch(BOOL hasCustomView) {
    // UIBarButtonItem ignores target/action when customView handles its own touch events.
    return hasCustomView;
}

static inline BOOL PTDuoShouldAllowHomeAction(BOOL hasTabBarController,
                                              NSUInteger tabCount,
                                              BOOL isOnHomeTab0,
                                              BOOL hasModal,
                                              NSUInteger activeNavStackCount) {
    if (hasTabBarController && tabCount >= 2) {
        return !isOnHomeTab0 || hasModal || activeNavStackCount > 1;
    }
    return hasModal || activeNavStackCount > 1;
}

static inline BOOL PTDuoShouldShowTitlebarHomeButton(BOOL titlebarHomeEnabled,
                                                     BOOL hasHome) {
    return titlebarHomeEnabled && hasHome;
}

static inline char pt_asciiLower(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

static inline BOOL pt_isAsciiLower(char c) {
    return (c >= 'a' && c <= 'z');
}

static inline BOOL pt_isAsciiUpper(char c) {
    return (c >= 'A' && c <= 'Z');
}

static inline BOOL pt_isAsciiDigit(char c) {
    return (c >= '0' && c <= '9');
}

static inline BOOL PTDuoCStrContainsLiteral(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) {
        return NO;
    }
    size_t nlen = strlen(needle);
    for (const char *p = haystack; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i] && pt_asciiLower(p[i]) == pt_asciiLower(needle[i])) {
            i++;
        }
        if (i == nlen) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL PTDuoCStrContainsIdentifierToken(const char *haystack, const char *token) {
    if (!haystack || !token || !*token) {
        return NO;
    }
    size_t tlen = strlen(token);
    for (const char *p = haystack; *p; p++) {
        size_t i = 0;
        while (i < tlen && p[i] && pt_asciiLower(p[i]) == pt_asciiLower(token[i])) {
            i++;
        }
        if (i != tlen) {
            continue;
        }
        BOOL startOK = (p == haystack)
            || (!pt_isAsciiLower(p[-1]) && !pt_isAsciiUpper(p[-1]) && !pt_isAsciiDigit(p[-1]))
            || (pt_isAsciiLower(p[-1]) && pt_isAsciiUpper(p[0]));
        char next = p[tlen];
        BOOL endOK = (next == '\0')
            || (!pt_isAsciiLower(next) && !pt_isAsciiDigit(next) && !pt_isAsciiUpper(next))
            || pt_isAsciiUpper(next);
        if (startOK && endOK) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL PTDuoCStrMatchesBackCue(const char *s) {
    if (!s || !*s) {
        return NO;
    }
    if (PTDuoCStrContainsLiteral(s, "chevron.backward")
        || PTDuoCStrContainsLiteral(s, "chevron.left")
        || PTDuoCStrContainsLiteral(s, "arrow.backward")
        || PTDuoCStrContainsLiteral(s, "arrow.left")
        || PTDuoCStrContainsLiteral(s, "nav_back")
        || PTDuoCStrContainsLiteral(s, "navbar_back")
        || PTDuoCStrContainsLiteral(s, "goback")
        || PTDuoCStrContainsLiteral(s, "返回")) {
        return YES;
    }
    return PTDuoCStrContainsIdentifierToken(s, "back")
        || PTDuoCStrContainsIdentifierToken(s, "return");
}

static inline BOOL PTDuoCStrMatchesCloseCue(const char *s) {
    if (!s || !*s) {
        return NO;
    }
    if (PTDuoCStrContainsLiteral(s, "xmark")
        || PTDuoCStrContainsLiteral(s, "chevron.down")
        || PTDuoCStrContainsLiteral(s, "chevron.compact.down")
        || PTDuoCStrContainsLiteral(s, "arrow.down.right.and.arrow.up.left")
        || PTDuoCStrContainsLiteral(s, "关闭")
        || PTDuoCStrContainsLiteral(s, "收起")
        || PTDuoCStrContainsLiteral(s, "完成")) {
        return YES;
    }
    return PTDuoCStrContainsIdentifierToken(s, "close")
        || PTDuoCStrContainsIdentifierToken(s, "dismiss")
        || PTDuoCStrContainsIdentifierToken(s, "cancel");
}

static inline BOOL PTDuoShouldInterceptKeyboardBackShortcut(BOOL shortcutEnabled,
                                                             BOOL isRepeat,
                                                             NSUInteger eventFlags,
                                                             NSUInteger targetFlags,
                                                             uint16_t eventKeyCode,
                                                             uint16_t targetKeyCode,
                                                             BOOL isTextInputActive,
                                                             BOOL hasBack) {
    if (!shortcutEnabled || isRepeat || !hasBack) {
        return NO;
    }
    if (eventKeyCode != targetKeyCode || eventFlags != targetFlags) {
        return NO;
    }
    // Unmodified non-Esc keys must pass through while editing text so typing is never hijacked.
    if (isTextInputActive && eventFlags == 0 && eventKeyCode != 53) {
        return NO;
    }
    return YES;
}

static inline BOOL PTDuoShouldInterceptMouseBackShortcut(BOOL shortcutEnabled,
                                                          NSInteger eventButtonNumber,
                                                          NSInteger targetButtonNumber,
                                                          NSUInteger eventFlags,
                                                          NSUInteger targetFlags,
                                                          BOOL inTitlebarArea,
                                                          BOOL inTrafficLightOrBackButton,
                                                          BOOL hasBack) {
    if (!shortcutEnabled || inTrafficLightOrBackButton || !hasBack) {
        return NO;
    }
    if (eventButtonNumber != targetButtonNumber || eventFlags != targetFlags) {
        return NO;
    }
    if (targetButtonNumber == 0 && targetFlags == 0 && inTitlebarArea) {
        return NO;
    }
    return YES;
}

// MARK: - Associated Object Keys & State Types

typedef NS_ENUM(NSInteger, PTDuoBarState) {
    PTDuoBarStateUnset = 0,
    PTDuoBarStateActive = 1,
    PTDuoBarStateBehaviorDisabled = 2,
    PTDuoBarStateInactive = 3,
};

static const void *kPTDuoBarRegionMetaKey = &kPTDuoBarRegionMetaKey;
static const void *kPTDuoViewBarGuidesKey = &kPTDuoViewBarGuidesKey;
static const void *kPTDuoGuideConstraintsKey = &kPTDuoGuideConstraintsKey;
static const void *kPTDuoWindowStateKey = &kPTDuoWindowStateKey;
static const void *kPTDuoWindowTraitStateKey = &kPTDuoWindowTraitStateKey;
static const void *kPTDuoSceneTraitStateKey = &kPTDuoSceneTraitStateKey;
static const void *kPTDuoWindowHostViewKey = &kPTDuoWindowHostViewKey;
static const void *kPTDuoWindowInsetStateKey = &kPTDuoWindowInsetStateKey;
static const void *kPTDuoWindowRefreshScheduledKey = &kPTDuoWindowRefreshScheduledKey;
static const void *kPTDuoWindowLastLayoutSizeKey = &kPTDuoWindowLastLayoutSizeKey;
static const void *kPTDuoTabBarRelocatedKey = &kPTDuoTabBarRelocatedKey;
static const void *kPTDuoTabBarAppHiddenKey = &kPTDuoTabBarAppHiddenKey;
static const void *kPTDuoTabBarAppAlphaKey = &kPTDuoTabBarAppAlphaKey;
static const void *kPTDuoTabBarAppInteractKey = &kPTDuoTabBarAppInteractKey;
static const void *kPTDuoTabChromeRelocatedKey = &kPTDuoTabChromeRelocatedKey;
static const void *kPTDuoTabChromeAppHiddenKey = &kPTDuoTabChromeAppHiddenKey;
static const void *kPTDuoTabChromeAppAlphaKey = &kPTDuoTabChromeAppAlphaKey;
static const void *kPTDuoTabChromeAppInteractKey = &kPTDuoTabChromeAppInteractKey;
static const void *kPTDuoTabChromeLayerSuppressedKey = &kPTDuoTabChromeLayerSuppressedKey;
static const void *kPTDuoTabChromeLayerAppHiddenKey = &kPTDuoTabChromeLayerAppHiddenKey;
static const void *kPTDuoTabChromeLayerAppOpacityKey = &kPTDuoTabChromeLayerAppOpacityKey;
static const void *kPTDuoProminentBgColorKey = &kPTDuoProminentBgColorKey;
static const void *kPTDuoProminentTintColorKey = &kPTDuoProminentTintColorKey;
static const void *kPTDuoNavControllerSuppressionKey = &kPTDuoNavControllerSuppressionKey;
static const void *kPTDuoToolbarControllerSuppressionKey = &kPTDuoToolbarControllerSuppressionKey;
static const void *kPTDuoNavBarSuppressedKey = &kPTDuoNavBarSuppressedKey;
static const void *kPTDuoNavBarAppHiddenKey = &kPTDuoNavBarAppHiddenKey;
static const void *kPTDuoNavBarAppAlphaKey = &kPTDuoNavBarAppAlphaKey;
static const void *kPTDuoNavBarAppInteractKey = &kPTDuoNavBarAppInteractKey;
static const void *kPTDuoToolbarSuppressedKey = &kPTDuoToolbarSuppressedKey;
static const void *kPTDuoToolbarAppHiddenKey = &kPTDuoToolbarAppHiddenKey;
static const void *kPTDuoToolbarAppAlphaKey = &kPTDuoToolbarAppAlphaKey;
static const void *kPTDuoToolbarAppInteractKey = &kPTDuoToolbarAppInteractKey;
static const void *kPTDuoBarItemSuppressedKey = &kPTDuoBarItemSuppressedKey;
static const void *kPTDuoBarItemAppHiddenKey = &kPTDuoBarItemAppHiddenKey;
static const void *kPTDuoBarItemCachedSnapshotKey = &kPTDuoBarItemCachedSnapshotKey;
static const void *kPTDuoCustomViewSuppressedKey = &kPTDuoCustomViewSuppressedKey;
static const void *kPTDuoCustomViewAppHiddenKey = &kPTDuoCustomViewAppHiddenKey;
static const void *kPTDuoCustomViewAppAlphaKey = &kPTDuoCustomViewAppAlphaKey;
static const void *kPTDuoCustomViewAppInteractKey = &kPTDuoCustomViewAppInteractKey;
static const void *kPTDuoTabOverlayCacheKey = &kPTDuoTabOverlayCacheKey;
static const void *kPTDuoNavItemSuppressedBackKey = &kPTDuoNavItemSuppressedBackKey;
static const void *kPTDuoNavItemAppHidesBackKey = &kPTDuoNavItemAppHidesBackKey;
static const void *kPTDuoTabMountEvalKey = &kPTDuoTabMountEvalKey;
static const void *kPTDuoNavMountEvalKey = &kPTDuoNavMountEvalKey;
static const void *kPTDuoLastTransitionSizeKey = &kPTDuoLastTransitionSizeKey;
static const void *kPTDuoLastSettledResizeSafeAreaNotifySizeKey = &kPTDuoLastSettledResizeSafeAreaNotifySizeKey;
static const void *kPTDuoAppliedTopClearanceKey = &kPTDuoAppliedTopClearanceKey;
static const void *kPTDuoTrackedTopClearanceVCsKey = &kPTDuoTrackedTopClearanceVCsKey;
static const void *kPTDuoImagePlaceholderBlankCacheKey = &kPTDuoImagePlaceholderBlankCacheKey;

@interface PTDuoWindowInsetState : NSObject
@property (nonatomic, weak) UIViewController *activeLeafVC;
@property (nonatomic, assign) NSUInteger epoch;
@property (nonatomic, assign) BOOL probingRightInset;
@property (nonatomic, assign) BOOL queriedRightBarRegion;
@property (nonatomic, assign) CGFloat queriedRightBarExtent;
@property (nonatomic, assign) CFTimeInterval queriedRightBarTimestamp;
@property (nonatomic, assign) BOOL collapsedEmptyRightInset;
@property (nonatomic, assign) CGFloat occupiedRightBarWidth;
@property (nonatomic, assign) BOOL forceReprobe;
@property (nonatomic, assign) BOOL postMountRecheckScheduled;
@property (nonatomic, assign) NSInteger safeAreaDriftRetryCount;
@property (nonatomic, assign) NSInteger unknownSlotRetryCount;
@property (nonatomic, assign) const char *lastYieldReason;
@property (nonatomic, assign) const char *lastTakeoverReason;
@property (nonatomic, assign) PTDuoNavBarSuppressionMode lastNavBarSuppressionMode;
@property (nonatomic, assign) PTDuoNavBarSuppressionMode lastToolbarSuppressionMode;
@property (nonatomic, assign) NSInteger lastAutoYieldNodesScanned;
@property (nonatomic, assign) NSInteger lastOverlayNodesScanned;
@property (nonatomic, assign) NSInteger lastOverlayCandidatesScanned;
@property (nonatomic, assign) double lastAutoYieldDurationMs;
@property (nonatomic, assign) double lastSlotCaptureDurationMs;
@property (nonatomic, assign) double lastRebuildDurationMs;
@property (nonatomic, assign) BOOL lastTabDockBlockedByUnknownSlot;
@end

@implementation PTDuoWindowInsetState
@end

static os_log_t pt_duoSignpostLog(void) {
    static os_log_t log = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("PlayTools", "DuoVerticalBar");
    });
    return log;
}

static PTDuoWindowInsetState *pt_insetStateForWindow(UIWindow *window, BOOL createIfNeeded) {
    if (!window) {
        return nil;
    }
    PTDuoWindowInsetState *state = objc_getAssociatedObject(window, kPTDuoWindowInsetStateKey);
    if (!state && createIfNeeded) {
        state = [[PTDuoWindowInsetState alloc] init];
        objc_setAssociatedObject(window, kPTDuoWindowInsetStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL pt_duoVerticalBarInstalled = NO;
static BOOL pt_duoHostLiveResizing = NO;
static const void *kPTDuoPendingLiveResizeRefreshKey = &kPTDuoPendingLiveResizeRefreshKey;
static __thread NSInteger pt_duoRefreshDepth = 0;
static __thread NSInteger pt_duoInternalSafeAreaNotifyDepth = 0;
static __thread NSInteger pt_duoInternalTabBarHiddenDepth = 0;
static __thread NSInteger pt_duoInternalNavBarVisualDepth = 0;
static __thread NSInteger pt_duoInternalToolbarVisualDepth = 0;
static __thread NSInteger pt_duoInternalBarItemHiddenDepth = 0;
static __thread NSInteger pt_duoInternalNavItemBackDepth = 0;

static void pt_scheduleRefreshForWindow(UIWindow *window);
static void pt_refreshDuoVerticalBarForWindow(UIWindow *window);
static BOOL pt_isToolbarFullySuppressed(UINavigationController *nav);
static UIWindow *pt_findActivePrimaryWindow(void);

// MARK: - UIViewLayoutRegion Metadata

@interface PTDuoBarLayoutRegionMeta : NSObject
@property (nonatomic, assign) BOOL isDirectional;
@property (nonatomic, assign) UIRectEdge edge;
@property (nonatomic, assign) NSDirectionalRectEdge directionalEdge;
@property (nonatomic, assign) BOOL hasExplicitExtent;
@property (nonatomic, assign) CGFloat extent;
@end

@implementation PTDuoBarLayoutRegionMeta
@end

static inline BOOL pt_isTaggedPointer(id obj) {
    uintptr_t raw = (uintptr_t)(__bridge void *)obj;
    return (raw == 0) || ((raw & 1u) != 0) || ((raw >> 63) != 0);
}

static void pt_attachBarRegionMeta(id region,
                                   BOOL isDirectional,
                                   UIRectEdge edge,
                                   NSDirectionalRectEdge directionalEdge,
                                   BOOL hasExplicitExtent,
                                   CGFloat extent) {
    if (!region || pt_isTaggedPointer(region)) {
        return;
    }
    PTDuoBarLayoutRegionMeta *meta = [[PTDuoBarLayoutRegionMeta alloc] init];
    meta.isDirectional = isDirectional;
    meta.edge = edge;
    meta.directionalEdge = directionalEdge;
    meta.hasExplicitExtent = hasExplicitExtent;
    meta.extent = extent;
    objc_setAssociatedObject(region, kPTDuoBarRegionMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Window & ViewController State Resolution

static BOOL pt_isWindowStructuralPrimaryCandidate(UIWindow *window) {
    if (!window) {
        return NO;
    }
    if (window.windowLevel != UIWindowLevelNormal) {
        return NO;
    }
    NSString *clsName = NSStringFromClass([window class]);
    if ([clsName hasPrefix:@"_UI"]
        || [clsName containsString:@"Keyboard"]
        || [clsName containsString:@"TextEffects"]
        || [clsName containsString:@"StatusBar"]
        || [clsName containsString:@"Alert"]) {
        return NO;
    }
    return YES;
}

static BOOL pt_isEligiblePrimaryWindow(UIWindow *window) {
    if (!pt_isWindowStructuralPrimaryCandidate(window)) {
        return NO;
    }
    if (window.hidden || window.alpha <= 0.01) {
        return NO;
    }
    if (!window.rootViewController) {
        return NO;
    }
    return YES;
}

static BOOL pt_presentationCoversWindowBounds(UIViewController *presented, CGRect windowBounds) {
    if (!presented || presented.isBeingDismissed) {
        return NO;
    }
    UIModalPresentationStyle style = presented.modalPresentationStyle;
    if (style == UIModalPresentationFullScreen
        || style == UIModalPresentationOverFullScreen
        || style == UIModalPresentationCurrentContext
        || style == UIModalPresentationOverCurrentContext) {
        return YES;
    }
    if (presented.isViewLoaded && CGRectGetWidth(windowBounds) > 1.0) {
        CGRect f = presented.view.frame;
        if (CGRectGetWidth(f) >= CGRectGetWidth(windowBounds) * 0.9
            && CGRectGetHeight(f) >= CGRectGetHeight(windowBounds) * 0.9) {
            return YES;
        }
    }
    return NO;
}

static UIViewController *pt_topPresentedFullscreenController(UIViewController *rootVC, CGRect windowBounds) {
    UIViewController *current = rootVC;
    NSInteger depth = 0;
    while (current.presentedViewController && depth < 16) {
        UIViewController *presented = current.presentedViewController;
        if (!pt_presentationCoversWindowBounds(presented, windowBounds)) {
            break;
        }
        current = presented;
        depth++;
    }
    return current;
}

static NSInteger pt_preferredVerticalBarBehaviorForVC(UIViewController *vc) {
    if (!vc) {
        return 0;
    }
    SEL behaviorSel = sel_registerName("preferredVerticalBarBehavior");
    if ([vc respondsToSelector:behaviorSel]) {
        typedef NSInteger (*pt_behavior_fn)(id, SEL);
        return ((pt_behavior_fn)objc_msgSend)(vc, behaviorSel);
    }
    return 0;
}

// MARK: - iOS 18+/27 UITab / UITabBarController Dynamic Helpers

static NSArray<id> *pt_tabBarControllerTabs(UITabBarController *tabVC) {
    if (!tabVC) {
        return nil;
    }
    SEL sel = sel_registerName("tabs");
    if ([tabVC respondsToSelector:sel]) {
        return ((NSArray<id> *(*)(id, SEL))objc_msgSend)(tabVC, sel);
    }
    return nil;
}

static id pt_tabBarControllerSelectedTab(UITabBarController *tabVC) {
    if (!tabVC) {
        return nil;
    }
    SEL sel = sel_registerName("selectedTab");
    if ([tabVC respondsToSelector:sel]) {
        return ((id (*)(id, SEL))objc_msgSend)(tabVC, sel);
    }
    return nil;
}

static void pt_tabBarControllerSetSelectedTab(UITabBarController *tabVC, id tab) {
    if (!tabVC || !tab) {
        return;
    }
    SEL sel = sel_registerName("setSelectedTab:");
    if ([tabVC respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(tabVC, sel, tab);
    }
}

static NSString *pt_tabBarControllerProminentTabIdentifier(UITabBarController *tabVC) {
    if (!tabVC) {
        return nil;
    }
    SEL sel = sel_registerName("prominentTabIdentifier");
    if ([tabVC respondsToSelector:sel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(tabVC, sel);
    }
    return nil;
}

static BOOL pt_tabBarControllerIsTabBarHidden(UITabBarController *tabVC) {
    if (!tabVC) {
        return NO;
    }
    SEL sel = sel_registerName("isTabBarHidden");
    if ([tabVC respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(tabVC, sel);
    }
    return NO;
}

static BOOL pt_tabIsHidden(id tab) {
    if (!tab) {
        return YES;
    }
    SEL sel = sel_registerName("isHidden");
    if ([tab respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return NO;
}

static BOOL pt_tabIsEnabled(id tab) {
    if (!tab) {
        return NO;
    }
    SEL sel = sel_registerName("isEnabled");
    if ([tab respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return YES;
}

static NSString *pt_tabIdentifier(id tab) {
    if (!tab) {
        return nil;
    }
    SEL sel = sel_registerName("identifier");
    if ([tab respondsToSelector:sel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return nil;
}

static NSString *pt_tabTitle(id tab) {
    if (!tab) {
        return nil;
    }
    SEL sel = sel_registerName("title");
    if ([tab respondsToSelector:sel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return nil;
}

static UIImage *pt_tabImage(id tab) {
    if (!tab) {
        return nil;
    }
    SEL sel = sel_registerName("image");
    if ([tab respondsToSelector:sel]) {
        return ((UIImage *(*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return nil;
}

static UIImage *pt_tabSelectedImage(id tab) {
    if (!tab) {
        return nil;
    }
    SEL sel = sel_registerName("selectedImage");
    if ([tab respondsToSelector:sel]) {
        return ((UIImage *(*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return nil;
}

static NSString *pt_tabBadgeValue(id tab) {
    if (!tab) {
        return nil;
    }
    SEL sel = sel_registerName("badgeValue");
    if ([tab respondsToSelector:sel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return nil;
}

static UIViewController *pt_tabViewController(id tab) {
    if (!tab) {
        return nil;
    }
    SEL sel = sel_registerName("viewController");
    if ([tab respondsToSelector:sel]) {
        return ((UIViewController *(*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return nil;
}

static BOOL pt_tabIsSearchTab(id tab) {
    if (!tab) {
        return NO;
    }
    Class searchTabCls = NSClassFromString(@"UISearchTab");
    return (searchTabCls != Nil && [tab isKindOfClass:searchTabCls]);
}

static BOOL pt_searchTabAutomaticallyActivatesSearch(id tab) {
    if (!tab) {
        return NO;
    }
    SEL sel = sel_registerName("automaticallyActivatesSearch");
    if ([tab respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(tab, sel);
    }
    return YES;
}

static UIViewController *pt_selectedViewControllerForTabBarController(UITabBarController *tabVC) {
    if (!tabVC) {
        return nil;
    }
    id selectedTab = pt_tabBarControllerSelectedTab(tabVC);
    UIViewController *vc = pt_tabViewController(selectedTab);
    return vc ?: tabVC.selectedViewController;
}

static UIViewController *pt_largestVisibleChildViewController(UIViewController *container,
                                                              NSHashTable<UIViewController *> *visited) {
    if (!container || !container.isViewLoaded) {
        return nil;
    }
    NSArray<UIViewController *> *children = container.childViewControllers;
    if (children.count == 0) {
        return nil;
    }
    UIView *containerView = container.view;
    CGRect containerBounds = containerView.bounds;
    if (CGRectGetWidth(containerBounds) <= 1.0 || CGRectGetHeight(containerBounds) <= 1.0) {
        return nil;
    }

    UIViewController *bestChild = nil;
    CGFloat bestArea = 0.0;

    // Reverse order so the topmost visible child in z-order wins ties.
    for (UIViewController *child in [children reverseObjectEnumerator]) {
        if (!child || (visited && [visited containsObject:child])) {
            continue;
        }
        if (!child.isViewLoaded) {
            continue;
        }
        UIView *childView = child.view;
        if (!childView || childView.hidden || childView.alpha <= 0.05 || childView.window == nil) {
            continue;
        }
        BOOL ancestorHidden = NO;
        UIView *v = childView.superview;
        NSInteger hops = 0;
        while (v && v != containerView && hops < 12) {
            if (v.hidden || v.alpha <= 0.05) {
                ancestorHidden = YES;
                break;
            }
            v = v.superview;
            hops++;
        }
        if (ancestorHidden) {
            continue;
        }
        CGRect rectInContainer = [childView convertRect:childView.bounds toView:containerView];
        if (!PTDuoChildFrameCoversContainer(rectInContainer, containerBounds)) {
            continue;
        }
        CGRect clipped = CGRectIntersection(rectInContainer, containerBounds);
        CGFloat area = CGRectGetWidth(clipped) * CGRectGetHeight(clipped);
        if (area > bestArea) {
            bestArea = area;
            bestChild = child;
        }
    }
    return bestChild;
}

static NSInteger pt_resolveVerticalBarBehaviorForWindow(UIWindow *window) {
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC) {
        return 0;
    }
    UIViewController *current = pt_topPresentedFullscreenController(rootVC, window.bounds);
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    SEL childSel = sel_registerName("childViewControllerForPreferredVerticalBarBehavior");

    for (NSInteger depth = 0; depth < 16 && current != nil; depth++) {
        if ([visited containsObject:current]) {
            break;
        }
        [visited addObject:current];

        UIViewController *next = nil;
        if ([current respondsToSelector:childSel]) {
            typedef UIViewController *(*pt_child_fn)(id, SEL);
            next = ((pt_child_fn)objc_msgSend)(current, childSel);
        }
        if (!next) {
            if ([current isKindOfClass:[UINavigationController class]]) {
                next = ((UINavigationController *)current).topViewController;
            } else if ([current isKindOfClass:[UITabBarController class]]) {
                next = pt_selectedViewControllerForTabBarController((UITabBarController *)current);
            } else if ([current isKindOfClass:[UISplitViewController class]]) {
                NSArray<UIViewController *> *vcs = ((UISplitViewController *)current).viewControllers;
                next = vcs.lastObject;
            } else {
                next = pt_largestVisibleChildViewController(current, visited);
            }
        }
        if (!next || next == current) {
            return pt_preferredVerticalBarBehaviorForVC(current);
        }
        // If a container explicitly sets Disabled without delegating to a child via
        // childViewControllerForPreferredVerticalBarBehavior, respect it.
        if (pt_preferredVerticalBarBehaviorForVC(current) == 1) {
            return 1;
        }
        current = next;
    }
    return pt_preferredVerticalBarBehaviorForVC(current);
}

static PTDuoBarState pt_computeDesiredBarStateForWindow(UIWindow *window) {
    if (!PTShouldEnableDuoVerticalBar() || !pt_isEligiblePrimaryWindow(window)) {
        return PTDuoBarStateInactive;
    }
    CGFloat w = CGRectGetWidth(window.bounds);
    CGFloat h = CGRectGetHeight(window.bounds);
    if (!isfinite(w) || !isfinite(h) || w < kPTDuoVerticalBarMinWindowWidth || h < kPTDuoVerticalBarMinWindowHeight) {
        return PTDuoBarStateInactive;
    }
    NSInteger behavior = pt_resolveVerticalBarBehaviorForWindow(window);
    if (!PTDuoShouldActivateForGeometry(YES, w, h, behavior)) {
        return (behavior == 1) ? PTDuoBarStateBehaviorDisabled : PTDuoBarStateInactive;
    }
    return PTDuoBarStateActive;
}

static BOOL pt_isDuoVerticalBarActiveForWindow(UIWindow *window) {
    if (!window || !PTShouldEnableDuoVerticalBar()) {
        return NO;
    }
    NSNumber *cached = objc_getAssociatedObject(window, kPTDuoWindowStateKey);
    if (cached) {
        PTDuoBarState state = (PTDuoBarState)cached.integerValue;
        if (state == PTDuoBarStateActive) {
            return CGRectGetWidth(window.bounds) >= kPTDuoVerticalBarMinWindowWidth;
        }
        return NO;
    }
    return pt_computeDesiredBarStateForWindow(window) == PTDuoBarStateActive;
}

// MARK: - Private Trait Override Application

static void pt_applyVerticalBarTraitsToObject(id target, const void *stateKey, PTDuoBarState state) {
    if (!target || ![target respondsToSelector:@selector(traitOverrides)]) {
        return;
    }
    NSNumber *prev = objc_getAssociatedObject(target, stateKey);
    if (prev && prev.integerValue == state) {
        return;
    }

    Class tSystemAllowed = NSClassFromString(@"_UITraitSystemVerticalBarAllowed");
    Class tSystemEdge = NSClassFromString(@"_UITraitSystemVerticalBarHorizontalEdge");
    Class tAllowed = NSClassFromString(@"_UITraitVerticalBarAllowed");
    if (!tSystemAllowed || !tSystemEdge || !tAllowed) {
        return;
    }

    if (@available(iOS 17.0, *)) {
        id overrides = ((id (*)(id, SEL))objc_msgSend)(target, @selector(traitOverrides));
        if (!overrides) {
            return;
        }
        SEL setIntSel = @selector(setNSIntegerValue:forTrait:);
        SEL removeSel = @selector(removeTrait:);
        if (![overrides respondsToSelector:setIntSel] || ![overrides respondsToSelector:removeSel]) {
            return;
        }
        typedef void (*pt_set_trait_int_fn)(id, SEL, NSInteger, Class);
        typedef void (*pt_remove_trait_fn)(id, SEL, Class);
        pt_set_trait_int_fn setIntFn = (pt_set_trait_int_fn)objc_msgSend;
        pt_remove_trait_fn removeFn = (pt_remove_trait_fn)objc_msgSend;

        if (state == PTDuoBarStateActive) {
            setIntFn(overrides, setIntSel, 1, tSystemAllowed);
            setIntFn(overrides, setIntSel, 2, tSystemEdge);
            setIntFn(overrides, setIntSel, 1, tAllowed);
        } else if (state == PTDuoBarStateBehaviorDisabled) {
            setIntFn(overrides, setIntSel, 1, tSystemAllowed);
            setIntFn(overrides, setIntSel, 2, tSystemEdge);
            setIntFn(overrides, setIntSel, 2, tAllowed);
        } else {
            removeFn(overrides, removeSel, tAllowed);
            removeFn(overrides, removeSel, tSystemEdge);
            removeFn(overrides, removeSel, tSystemAllowed);
        }
        objc_setAssociatedObject(target, stateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// MARK: - App-Rendered Custom Sidebar Auto-Yield Detection

static BOOL pt_isSystemBarOrPrivateChromeView(UIView *view) {
    if ([view isKindOfClass:[UINavigationBar class]]
        || [view isKindOfClass:[UITabBar class]]
        || [view isKindOfClass:[UIToolbar class]]) {
        return YES;
    }
    NSString *clsName = NSStringFromClass([view class]);
    if ([clsName hasPrefix:@"_UI"]
        || [clsName hasPrefix:@"UI"]
        || [clsName hasPrefix:@"PTDuo"]) {
        // Note: Plain UIView / UIControl / UIStackView could be an app's custom sidebar container,
        // so only filter out private _UI* chrome and specific system bar/scroll indicator classes.
        if ([clsName hasPrefix:@"_UI"]
            || [clsName hasPrefix:@"PTDuo"]
            || [clsName isEqualToString:@"UIScrollView"]
            || [clsName isEqualToString:@"UITableView"]
            || [clsName isEqualToString:@"UICollectionView"]
            || [clsName isEqualToString:@"UILayoutContainerView"]
            || [clsName isEqualToString:@"UITransitionView"]
            || [clsName isEqualToString:@"UIViewControllerWrapperView"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_hasVisibleInteractiveDescendant(UIView *view, NSInteger depth, NSInteger *budget) {
    if (!view || depth > 8 || *budget <= 0) {
        return NO;
    }
    for (UIView *sub in view.subviews) {
        (*budget)--;
        if (*budget <= 0) {
            return NO;
        }
        if (sub.hidden || sub.alpha <= 0.05 || !sub.userInteractionEnabled) {
            continue;
        }
        if (CGRectGetWidth(sub.bounds) < 8.0 || CGRectGetHeight(sub.bounds) < 8.0) {
            continue;
        }
        if ([sub isKindOfClass:[UIControl class]] || sub.gestureRecognizers.count > 0) {
            return YES;
        }
        if (pt_hasVisibleInteractiveDescendant(sub, depth + 1, budget)) {
            return YES;
        }
    }
    return NO;
}

static void pt_collectDistinctInteractiveCentersInView(UIView *view,
                                                       UIWindow *window,
                                                       CGRect rightStrip,
                                                       CGFloat *centerYs,
                                                       NSInteger *ioCount,
                                                       NSInteger maxCount,
                                                       NSInteger depth,
                                                       NSInteger *budget) {
    if (!view || depth > 8 || *budget <= 0 || *ioCount >= maxCount) {
        return;
    }
    if (view.hidden || view.alpha <= 0.05 || !view.userInteractionEnabled) {
        return;
    }
    if (pt_isSystemBarOrPrivateChromeView(view)) {
        return;
    }
    (*budget)--;

    BOOL isInteractive = ([view isKindOfClass:[UIControl class]] || view.gestureRecognizers.count > 0);
    if (isInteractive && CGRectGetWidth(view.bounds) >= 16.0 && CGRectGetHeight(view.bounds) >= 16.0) {
        CGRect rectInWin = [view convertRect:view.bounds toView:window];
        if (CGRectIntersectsRect(rectInWin, rightStrip)) {
            CGFloat midY = CGRectGetMidY(rectInWin);
            BOOL duplicate = NO;
            for (NSInteger i = 0; i < *ioCount; i++) {
                if (fabs(centerYs[i] - midY) < 28.0) {
                    duplicate = YES;
                    break;
                }
            }
            if (!duplicate && *ioCount < maxCount) {
                centerYs[*ioCount] = midY;
                (*ioCount)++;
            }
        }
    }

    for (UIView *sub in view.subviews) {
        if (*budget <= 0 || *ioCount >= maxCount) {
            break;
        }
        pt_collectDistinctInteractiveCentersInView(sub, window, rightStrip, centerYs, ioCount, maxCount, depth + 1, budget);
    }
}

static BOOL pt_viewIsInteractiveSidebarCandidate(UIView *view,
                                                 UIWindow *window,
                                                 CGRect windowBounds,
                                                 CGRect rightStrip,
                                                 CGRect *outRectInWin,
                                                 NSInteger *outDistinctCount) {
    if (outRectInWin) { *outRectInWin = CGRectZero; }
    if (outDistinctCount) { *outDistinctCount = 0; }
    if (!view || view.hidden || view.alpha <= 0.05 || !view.userInteractionEnabled) {
        return NO;
    }
    if (pt_isSystemBarOrPrivateChromeView(view)) {
        return NO;
    }
    CGRect rectInWin = [view convertRect:view.bounds toView:window];
    if (!PTDuoRectIsAppSidebarCandidate(rectInWin, windowBounds)) {
        return NO;
    }
    BOOL interactive = ([view isKindOfClass:[UIControl class]] || view.gestureRecognizers.count > 0);
    if (!interactive) {
        NSInteger subBudget = 60;
        interactive = pt_hasVisibleInteractiveDescendant(view, 0, &subBudget);
    }
    if (!interactive) {
        return NO;
    }
    CGFloat centerYs[4] = { 0 };
    NSInteger distinctCount = 0;
    NSInteger countBudget = 80;
    pt_collectDistinctInteractiveCentersInView(view, window, rightStrip, centerYs, &distinctCount, 4, 0, &countBudget);
    if (distinctCount < 1) {
        distinctCount = 1;
    }
    if (outRectInWin) { *outRectInWin = rectInWin; }
    if (outDistinctCount) { *outDistinctCount = distinctCount; }
    return YES;
}

static BOOL pt_scanForAppRenderedSidebar(UIView *node,
                                         UIWindow *window,
                                         UIView *excludedHost,
                                         CGRect windowBounds,
                                         CGRect rightStrip,
                                         BOOL backedByLayoutRegion,
                                         BOOL verticalRailsOnly,
                                         NSInteger depth,
                                         NSInteger *visitBudget,
                                         NSMutableArray<NSValue *> *compactCandidates,
                                         CGFloat *outOccupiedWidth) {
    if (!node || node == excludedHost || node.hidden || node.alpha <= 0.05) {
        return NO;
    }
    if (depth > 24 || *visitBudget <= 0) {
        return NO;
    }
    (*visitBudget)--;

    if ([node isKindOfClass:[UINavigationBar class]]
        || [node isKindOfClass:[UITabBar class]]
        || [node isKindOfClass:[UIToolbar class]]
        || [node isKindOfClass:[UIScrollView class]]) {
        return NO;
    }

    if (depth > 0) {
        CGRect rectInWin = [node convertRect:node.bounds toView:window];
        if (node.clipsToBounds && !CGRectIntersectsRect(rectInWin, rightStrip)) {
            return NO;
        }
        CGRect candidateRect = CGRectZero;
        NSInteger distinctCount = 0;
        if (pt_viewIsInteractiveSidebarCandidate(node, window, windowBounds, rightStrip, &candidateRect, &distinctCount)) {
            if (PTDuoShouldAcceptSidebarInCollapsedState(!verticalRailsOnly,
                                                         candidateRect,
                                                         windowBounds,
                                                         backedByLayoutRegion,
                                                         distinctCount)) {
                if (outOccupiedWidth) {
                    CGFloat stripWidth = CGRectGetMaxX(windowBounds) - CGRectGetMinX(candidateRect);
                    *outOccupiedWidth = isfinite(stripWidth) ? MAX(0.0, stripWidth) : kPTDuoVerticalBarWidth;
                }
                return YES;
            }
            if (!verticalRailsOnly && compactCandidates && compactCandidates.count < 16) {
                [compactCandidates addObject:[NSValue valueWithCGRect:candidateRect]];
            }
        }
    }

    for (UIView *sub in node.subviews) {
        if (*visitBudget <= 0) {
            break;
        }
        if (pt_scanForAppRenderedSidebar(sub,
                                         window,
                                         excludedHost,
                                         windowBounds,
                                         rightStrip,
                                         backedByLayoutRegion,
                                         verticalRailsOnly,
                                         depth + 1,
                                         visitBudget,
                                         compactCandidates,
                                         outOccupiedWidth)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_windowHasAppRenderedRightSidebar(UIWindow *window,
                                                UIView *hostView,
                                                BOOL verticalRailsOnly,
                                                CGFloat *outOccupiedWidth) {
    if (outOccupiedWidth) {
        *outOccupiedWidth = 0.0;
    }
    if (!window) {
        return NO;
    }
    os_log_t spLog = pt_duoSignpostLog();
    os_signpost_id_t spId = os_signpost_id_make_with_pointer(spLog, (__bridge const void *)window);
    os_signpost_interval_begin(spLog, spId, "AutoYieldScan");
    CFTimeInterval t0 = CACurrentMediaTime();

    CGRect winBounds = window.bounds;
    CGFloat detectSpan = MAX(kPTDuoVerticalBarWidth, 60.0);
    CGRect rightStrip = CGRectMake(CGRectGetMaxX(winBounds) - detectSpan - 24.0,
                                   CGRectGetMinY(winBounds),
                                   detectSpan + 24.0,
                                   CGRectGetHeight(winBounds));
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(window, NO);
    BOOL backedByLayoutRegion = (insetState != nil && insetState.queriedRightBarRegion);
    NSMutableArray<NSValue *> *compactCandidates = [NSMutableArray array];
    const NSInteger initialBudget = 500;
    NSInteger budget = initialBudget;
    BOOL detected = NO;
    const char *yieldReason = NULL;

    if (pt_scanForAppRenderedSidebar(window,
                                     window,
                                     hostView,
                                     winBounds,
                                     rightStrip,
                                     backedByLayoutRegion,
                                     verticalRailsOnly,
                                     0,
                                     &budget,
                                     compactCandidates,
                                     outOccupiedWidth)) {
        detected = YES;
        yieldReason = verticalRailsOnly ? "lateFloatingVerticalRail" : "sidebarCandidate";
    }

    // Fallback: two or more distinct, vertically separated interactive buttons directly mounted
    // as siblings in the right strip (not wrapper/child overlap like a single glass search button).
    if (!detected && !verticalRailsOnly && compactCandidates.count >= 2) {
        for (NSUInteger i = 0; i < compactCandidates.count; i++) {
            CGRect a = compactCandidates[i].CGRectValue;
            CGFloat midYA = CGRectGetMidY(a);
            for (NSUInteger j = i + 1; j < compactCandidates.count; j++) {
                CGRect b = compactCandidates[j].CGRectValue;
                CGFloat midYB = CGRectGetMidY(b);
                if (fabs(midYA - midYB) >= 44.0) {
                    if (outOccupiedWidth) {
                        CGFloat minX = MIN(CGRectGetMinX(a), CGRectGetMinX(b));
                        CGFloat stripWidth = CGRectGetMaxX(winBounds) - minX;
                        *outOccupiedWidth = isfinite(stripWidth) ? MAX(0.0, stripWidth) : kPTDuoVerticalBarWidth;
                    }
                    detected = YES;
                    yieldReason = "compactSiblingRail";
                    break;
                }
            }
            if (detected) {
                break;
            }
        }
    }

    if (insetState) {
        insetState.lastAutoYieldNodesScanned = initialBudget - budget;
        insetState.lastAutoYieldDurationMs = (CACurrentMediaTime() - t0) * 1000.0;
        insetState.lastYieldReason = yieldReason;
    }
    os_signpost_interval_end(spLog, spId, "AutoYieldScan", "detected=%d nodes=%ld", detected ? 1 : 0, (long)(initialBudget - budget));
    return detected;
}

// MARK: - Native vs Custom UITabBar Detection & Restoration

static BOOL pt_stringIsEffectivelyBlank(NSString *str) {
    if (!str || str.length == 0) {
        return YES;
    }
    return [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0;
}

static BOOL pt_imageIsPlaceholderBlank(UIImage *img) {
    if (!img) {
        return YES;
    }
    CGFloat scale = (isfinite(img.scale) && img.scale > 0.0) ? img.scale : 1.0;
    CGFloat pxW = img.size.width * scale;
    CGFloat pxH = img.size.height * scale;
    if (!isfinite(pxW) || !isfinite(pxH) || (pxW <= 2.5 && pxH <= 2.5)) {
        return YES;
    }
    if (@available(iOS 13.0, *)) {
        if (img.isSymbolImage) {
            return NO;
        }
    }
    CGImageRef cg = img.CGImage;
    if (!cg || pxW > 256.0 || pxH > 256.0) {
        return NO;
    }
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(cg);
    if (alphaInfo == kCGImageAlphaNone ||
        alphaInfo == kCGImageAlphaNoneSkipLast ||
        alphaInfo == kCGImageAlphaNoneSkipFirst) {
        return NO;
    }
    NSNumber *cached = objc_getAssociatedObject(img, kPTDuoImagePlaceholderBlankCacheKey);
    if (cached != nil) {
        return cached.boolValue;
    }
    uint8_t alphaBuf[16 * 16] = {0};
    CGContextRef ctx = CGBitmapContextCreate(alphaBuf, 16, 16, 8, 16, NULL,
                                             (CGBitmapInfo)kCGImageAlphaOnly);
    if (!ctx) {
        return NO;
    }
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 16.0, 16.0), cg);
    CGContextRelease(ctx);
    BOOL isBlank = !PTDuoAlphaBufferHasVisiblePixels(alphaBuf, 16 * 16);
    objc_setAssociatedObject(img, kPTDuoImagePlaceholderBlankCacheKey,
                             @(isBlank), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return isBlank;
}

static BOOL pt_duoIsSystemTabBarSubviewClassName(NSString *clsName) {
    return [clsName hasPrefix:@"_UI"]
        || [clsName hasPrefix:@"UITabBar"]
        || [clsName hasPrefix:@"UIKit."]
        || [clsName hasPrefix:@"_TtCC5UIKit"]
        || [clsName hasPrefix:@"_TtGC5UIKit"]
        || [clsName hasPrefix:@"_TtC5UIKit"];
}

static BOOL pt_duoTabBarIsCustomReplacement(UITabBar *tabBar) {
    if (!tabBar) {
        return YES;
    }
    NSArray<UITabBarItem *> *items = tabBar.items;
    if (items.count < 2) {
        return YES;
    }
    BOOL allEmpty = YES;
    for (UITabBarItem *item in items) {
        if (!pt_stringIsEffectivelyBlank(item.title)
            || !pt_imageIsPlaceholderBlank(item.image)
            || !pt_imageIsPlaceholderBlank(item.selectedImage)) {
            allEmpty = NO;
            break;
        }
    }
    if (allEmpty) {
        return YES;
    }
    CGFloat width = CGRectGetWidth(tabBar.bounds);
    if (width > 1.0) {
        BOOL hasWideCustomOverlay = NO;
        for (UIView *sub in tabBar.subviews) {
            if (sub.hidden || sub.alpha <= 0.01) {
                continue;
            }
            NSString *clsName = NSStringFromClass([sub class]);
            if (pt_duoIsSystemTabBarSubviewClassName(clsName)) {
                continue;
            }
            if (CGRectGetWidth(sub.frame) >= width * 0.75 && CGRectGetHeight(sub.frame) >= 28.0) {
                hasWideCustomOverlay = YES;
                break;
            }
        }
        // If a wide custom overlay covers the tab bar and most items lack icons, don't hijack.
        if (hasWideCustomOverlay) {
            NSInteger iconCount = 0;
            for (UITabBarItem *item in items) {
                if (!pt_imageIsPlaceholderBlank(item.image) || !pt_imageIsPlaceholderBlank(item.selectedImage)) {
                    iconCount++;
                }
            }
            if (iconCount < 2) {
                return YES;
            }
        }
    }
    return NO;
}

static void pt_applySavedVisualSuppression(UIView *view,
                                           BOOL suppress,
                                           BOOL forceRestore,
                                           const void *flagKey,
                                           const void *hiddenKey,
                                           const void *alphaKey,
                                           const void *interactKey) {
    if (!view) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(view, flagKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            objc_setAssociatedObject(view, hiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, alphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, interactKey, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, flagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!view.hidden) {
            view.hidden = YES;
        }
        if (view.alpha > 0.0) {
            view.alpha = 0.0;
        }
        if (view.userInteractionEnabled) {
            view.userInteractionEnabled = NO;
        }
    } else if (currentlySuppressed || forceRestore) {
        NSNumber *appHidden = objc_getAssociatedObject(view, hiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(view, alphaKey);
        NSNumber *appInteract = objc_getAssociatedObject(view, interactKey);
        objc_setAssociatedObject(view, flagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, hiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, alphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, interactKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = appHidden ? appHidden.boolValue : NO;
        view.alpha = appAlpha ? appAlpha.doubleValue : 1.0;
        view.userInteractionEnabled = appInteract ? appInteract.boolValue : YES;
    }
}

static void pt_setTabBarRelocatedHidden(UITabBar *tabBar, BOOL relocateHidden) {
    if (!tabBar) {
        return;
    }
    pt_duoInternalTabBarHiddenDepth++;
    @try {
        pt_applySavedVisualSuppression(tabBar,
                                       relocateHidden,
                                       NO,
                                       kPTDuoTabBarRelocatedKey,
                                       kPTDuoTabBarAppHiddenKey,
                                       kPTDuoTabBarAppAlphaKey,
                                       kPTDuoTabBarAppInteractKey);
    } @finally {
        pt_duoInternalTabBarHiddenDepth--;
    }
}

static BOOL pt_isDescendantOrSameView(UIView *candidate, UIView *possibleAncestor) {
    UIView *v = candidate;
    NSInteger hops = 0;
    while (v && hops < 32) {
        if (v == possibleAncestor) {
            return YES;
        }
        v = v.superview;
        hops++;
    }
    return NO;
}

static void pt_collectFloatingTabBarChromeInView(UIView *node,
                                                 UIView *rootView,
                                                 UIView *contentView,
                                                 CGFloat rootHeight,
                                                 NSInteger depth,
                                                 NSMutableArray<UIView *> *outViews) {
    if (!node || depth > 5) {
        return;
    }
    if (node == contentView) {
        return;
    }
    if (contentView && pt_isDescendantOrSameView(contentView, node)) {
        for (UIView *sub in node.subviews) {
            pt_collectFloatingTabBarChromeInView(sub, rootView, contentView, rootHeight, depth + 1, outViews);
        }
        return;
    }
    if (depth > 0) {
        NSString *clsName = NSStringFromClass([node class]);
        if ([clsName isEqualToString:@"UITransitionView"]
            || [clsName isEqualToString:@"UIViewControllerWrapperView"]) {
            return;
        }
        BOOL isKnownFloatingChrome = ([clsName containsString:@"_UIBottomTabBarGroupView"]
                                      || [clsName containsString:@"_UITabBarAuxiliaryView"]
                                      || [clsName containsString:@"_UITabBarPlatterView"]
                                      || [clsName containsString:@"_UIFloatingTabBar"]);
        BOOL isCompactTabContainer = NO;
        if (!isKnownFloatingChrome && ([clsName containsString:@"_UITabContainerView"]
                                       || ([clsName containsString:@"TabBar"] && ![clsName isEqualToString:@"UITabBar"]))) {
            CGRect rectInRoot = [node convertRect:node.bounds toView:rootView];
            CGFloat h = CGRectGetHeight(rectInRoot);
            CGFloat maxY = CGRectGetMaxY(rectInRoot);
            if (h > 1.0 && h <= 140.0 && (rootHeight <= 1.0 || (h <= rootHeight * 0.35 && maxY >= rootHeight - 60.0))) {
                isCompactTabContainer = YES;
            }
        }
        if (isKnownFloatingChrome || isCompactTabContainer) {
            [outViews addObject:node];
            return;
        }
    }
    for (UIView *sub in node.subviews) {
        pt_collectFloatingTabBarChromeInView(sub, rootView, contentView, rootHeight, depth + 1, outViews);
    }
}

static NSArray<UIView *> *pt_collectFloatingTabBarChromeViews(UITabBarController *tabVC) {
    if (!tabVC || !tabVC.isViewLoaded) {
        return @[];
    }
    UIView *rootView = tabVC.view;
    UIViewController *selectedVC = pt_selectedViewControllerForTabBarController(tabVC);
    UIView *contentView = (selectedVC && selectedVC.isViewLoaded) ? selectedVC.view : nil;
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    pt_collectFloatingTabBarChromeInView(rootView,
                                         rootView,
                                         contentView,
                                         CGRectGetHeight(rootView.bounds),
                                         0,
                                         result);
    return result;
}

static void pt_setLayerAndStandaloneSublayersSuppressed(CALayer *layer, BOOL suppress, NSInteger depth) {
    if (!layer || depth > 4) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(layer, kPTDuoTabChromeLayerSuppressedKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            objc_setAssociatedObject(layer, kPTDuoTabChromeLayerAppHiddenKey, @(layer.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(layer, kPTDuoTabChromeLayerAppOpacityKey, @(layer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(layer, kPTDuoTabChromeLayerSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!layer.hidden) {
            layer.hidden = YES;
        }
        if (layer.opacity > 0.0f) {
            layer.opacity = 0.0f;
        }
    } else if (currentlySuppressed) {
        NSNumber *origHidden = objc_getAssociatedObject(layer, kPTDuoTabChromeLayerAppHiddenKey);
        NSNumber *origOpacity = objc_getAssociatedObject(layer, kPTDuoTabChromeLayerAppOpacityKey);
        objc_setAssociatedObject(layer, kPTDuoTabChromeLayerSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        layer.hidden = origHidden ? origHidden.boolValue : NO;
        layer.opacity = origOpacity ? origOpacity.floatValue : 1.0f;
    }
    for (CALayer *subL in [layer.sublayers copy]) {
        if (subL.delegate && [subL.delegate isKindOfClass:[UIView class]]) {
            continue;
        }
        pt_setLayerAndStandaloneSublayersSuppressed(subL, suppress, depth + 1);
    }
}

static void pt_setFloatingChromeViewRelocatedHidden(UIView *view, BOOL relocateHidden) {
    if (!view || [view isKindOfClass:[UITabBar class]]) {
        return;
    }
    BOOL currentlyRelocated = [objc_getAssociatedObject(view, kPTDuoTabChromeRelocatedKey) boolValue];
    if (relocateHidden) {
        if (!currentlyRelocated) {
            objc_setAssociatedObject(view, kPTDuoTabChromeAppHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kPTDuoTabChromeAppAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kPTDuoTabChromeAppInteractKey, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kPTDuoTabChromeRelocatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!view.hidden) {
            view.hidden = YES;
        }
        if (view.alpha > 0.0) {
            view.alpha = 0.0;
        }
        if (view.userInteractionEnabled) {
            view.userInteractionEnabled = NO;
        }
        pt_setLayerAndStandaloneSublayersSuppressed(view.layer, YES, 0);
    } else if (currentlyRelocated) {
        NSNumber *appHidden = objc_getAssociatedObject(view, kPTDuoTabChromeAppHiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(view, kPTDuoTabChromeAppAlphaKey);
        NSNumber *appInteract = objc_getAssociatedObject(view, kPTDuoTabChromeAppInteractKey);
        objc_setAssociatedObject(view, kPTDuoTabChromeRelocatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = appHidden ? appHidden.boolValue : NO;
        view.alpha = appAlpha ? appAlpha.doubleValue : 1.0;
        view.userInteractionEnabled = appInteract ? appInteract.boolValue : YES;
        pt_setLayerAndStandaloneSublayersSuppressed(view.layer, NO, 0);
    }
}

static BOOL pt_colorIsSaturatedAccent(UIColor *color) {
    if (!color) {
        return NO;
    }
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        return NO;
    }
    if (a < 0.5) {
        return NO;
    }
    CGFloat maxC = MAX(r, MAX(g, b));
    CGFloat minC = MIN(r, MIN(g, b));
    return (maxC - minC) > 0.15;
}

static void pt_scanAuxiliaryViewStyle(UIView *node,
                                      NSInteger depth,
                                      UIColor * __autoreleasing *outBg,
                                      UIColor * __autoreleasing *outTint) {
    if (!node || depth > 5) {
        return;
    }
    if (!*outBg) {
        UIColor *bg = node.backgroundColor;
        if (!bg && node.layer.backgroundColor) {
            bg = [UIColor colorWithCGColor:node.layer.backgroundColor];
        }
        if (pt_colorIsSaturatedAccent(bg)) {
            *outBg = bg;
        }
    }
    if (!*outTint && ([node isKindOfClass:[UIImageView class]] || [node isKindOfClass:[UIButton class]])) {
        if (node.tintColor) {
            *outTint = node.tintColor;
        }
    }
    for (UIView *sub in node.subviews) {
        pt_scanAuxiliaryViewStyle(sub, depth + 1, outBg, outTint);
    }
}

static void pt_findAuxiliaryViewInSubtree(UIView *node,
                                          NSInteger depth,
                                          UIView * __autoreleasing *outAuxView) {
    if (!node || depth > 6 || *outAuxView) {
        return;
    }
    NSString *clsName = NSStringFromClass([node class]);
    if ([clsName containsString:@"_UITabBarAuxiliaryView"] || [clsName containsString:@"TabBarAuxiliary"]) {
        *outAuxView = node;
        return;
    }
    for (UIView *sub in node.subviews) {
        pt_findAuxiliaryViewInSubtree(sub, depth + 1, outAuxView);
        if (*outAuxView) {
            return;
        }
    }
}

static void pt_extractProminentStyleFromTabBarController(UITabBarController *tabVC,
                                                         UIColor * __autoreleasing *outBgColor,
                                                         UIColor * __autoreleasing *outTintColor) {
    UIColor *cachedBg = tabVC ? objc_getAssociatedObject(tabVC, kPTDuoProminentBgColorKey) : nil;
    UIColor *cachedTint = tabVC ? objc_getAssociatedObject(tabVC, kPTDuoProminentTintColorKey) : nil;
    if (tabVC && tabVC.isViewLoaded && (!cachedBg || !cachedTint)) {
        UIView *auxView = nil;
        pt_findAuxiliaryViewInSubtree(tabVC.view, 0, &auxView);
        if (auxView) {
            UIColor *foundBg = nil;
            UIColor *foundTint = nil;
            pt_scanAuxiliaryViewStyle(auxView, 0, &foundBg, &foundTint);
            if (foundBg && !cachedBg) {
                cachedBg = foundBg;
                objc_setAssociatedObject(tabVC, kPTDuoProminentBgColorKey, cachedBg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (foundTint && !cachedTint) {
                cachedTint = foundTint;
                objc_setAssociatedObject(tabVC, kPTDuoProminentTintColorKey, cachedTint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if (outBgColor) { *outBgColor = cachedBg; }
    if (outTintColor) { *outTintColor = cachedTint; }
}

static void pt_inspectOpaqueFilledBadge(UIImage *image,
                                        BOOL *outOpaqueFilled,
                                        BOOL *outSaturatedAccent) {
    if (outOpaqueFilled) { *outOpaqueFilled = NO; }
    if (outSaturatedAccent) { *outSaturatedAccent = NO; }
    if (!image || image.renderingMode == UIImageRenderingModeAlwaysTemplate) {
        return;
    }
    CGImageRef cg = image.CGImage;
    if (!cg) {
        return;
    }
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    if (w < 12 || h < 12) {
        return;
    }
    unsigned char pixels[4 * 4 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        return;
    }
    CGContextRef ctx = CGBitmapContextCreate(pixels, 4, 4, 8, 4 * 4, cs,
                                             (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return;
    }
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 4.0, 4.0), cg);
    CGContextRelease(ctx);
    int opaqueInner = 0;
    int accentInner = 0;
    const int indices[4] = { 5, 6, 9, 10 };
    for (int k = 0; k < 4; k++) {
        int base = indices[k] * 4;
        unsigned char r = pixels[base + 0];
        unsigned char g = pixels[base + 1];
        unsigned char b = pixels[base + 2];
        unsigned char a = pixels[base + 3];
        if (a >= 200) {
            opaqueInner++;
            unsigned char maxC = MAX(r, MAX(g, b));
            unsigned char minC = MIN(r, MIN(g, b));
            if ((int)maxC - (int)minC >= 38) {
                accentInner++;
            }
        }
    }
    PTDuoInspectOpaqueBadgeResult(opaqueInner, accentInner, outOpaqueFilled, outSaturatedAccent);
}

static BOOL pt_imageIsOpaqueFilledBadge(UIImage *image) {
    BOOL opaqueFilled = NO;
    pt_inspectOpaqueFilledBadge(image, &opaqueFilled, NULL);
    return opaqueFilled;
}

static BOOL pt_duoAnalyzeMonochromeImageLuma(UIImage *image,
                                             BOOL requireAlwaysOriginal,
                                             CGFloat maxOpaqueRatio,
                                             CGFloat *outOpaqueRatio,
                                             CGFloat *outAvgLuma) {
    if (outOpaqueRatio) { *outOpaqueRatio = 0.0; }
    if (outAvgLuma) { *outAvgLuma = 0.0; }
    if (!image) {
        return NO;
    }
    if (requireAlwaysOriginal && image.renderingMode != UIImageRenderingModeAlwaysOriginal) {
        return NO;
    }
    CGImageRef cg = image.CGImage;
    if (!cg) {
        return NO;
    }
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    if (w < 4 || h < 4) {
        return NO;
    }
    unsigned char pixels[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        return NO;
    }
    CGContextRef ctx = CGBitmapContextCreate(pixels, 16, 16, 8, 16 * 4, cs,
                                             (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return NO;
    }
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 16.0, 16.0), cg);
    CGContextRelease(ctx);

    NSInteger visibleCount = 0;
    NSInteger chromaticCount = 0;
    CGFloat lumaSum = 0.0;
    for (int i = 0; i < 256; i++) {
        int base = i * 4;
        unsigned char a = pixels[base + 3];
        if (a < 20) {
            continue;
        }
        // Un-premultiply approximate RGB channels for accurate chroma & luma checks.
        CGFloat alphaF = (CGFloat)a / 255.0;
        CGFloat r = MIN(1.0, ((CGFloat)pixels[base + 0] / 255.0) / alphaF);
        CGFloat g = MIN(1.0, ((CGFloat)pixels[base + 1] / 255.0) / alphaF);
        CGFloat b = MIN(1.0, ((CGFloat)pixels[base + 2] / 255.0) / alphaF);
        CGFloat maxC = MAX(r, MAX(g, b));
        CGFloat minC = MIN(r, MIN(g, b));
        if ((maxC - minC) > 0.16) {
            chromaticCount++;
        }
        lumaSum += (0.299 * r + 0.587 * g + 0.114 * b);
        visibleCount++;
    }
    CGFloat opaqueRatio = (CGFloat)visibleCount / 256.0;
    if (visibleCount == 0 || opaqueRatio >= maxOpaqueRatio || chromaticCount > MAX(1, visibleCount / 8)) {
        return NO;
    }
    if (outOpaqueRatio) { *outOpaqueRatio = opaqueRatio; }
    if (outAvgLuma) { *outAvgLuma = lumaSum / (CGFloat)visibleCount; }
    return YES;
}

static BOOL pt_imageNeedsTemplateTintOnGlass(UIImage *image, BOOL isDarkMode) {
    CGFloat avgLuma = 0.0;
    if (!pt_duoAnalyzeMonochromeImageLuma(image, YES, 0.55, NULL, &avgLuma)) {
        return NO;
    }
    return isDarkMode ? (avgLuma < 0.22) : (avgLuma > 0.78);
}

static BOOL pt_duoImageNeedsTemplateOnOpaquePill(UIImage *image, BOOL contextDark) {
    if (!image || pt_imageIsOpaqueFilledBadge(image)) {
        return NO;
    }
    CGFloat avgLuma = 0.0;
    if (!pt_duoAnalyzeMonochromeImageLuma(image, YES, 0.68, NULL, &avgLuma)) {
        return NO;
    }
    return contextDark ? (avgLuma < 0.32) : (avgLuma > 0.68);
}

static BOOL pt_duoImageHasBrightForegroundOnTransparent(UIImage *image) {
    if (!image || pt_imageIsOpaqueFilledBadge(image)) {
        return NO;
    }
    CGFloat avgLuma = 0.0;
    if (!pt_duoAnalyzeMonochromeImageLuma(image, NO, 0.70, NULL, &avgLuma)) {
        return NO;
    }
    return (avgLuma > 0.72);
}

static void pt_duoResolvePowerSavingVisualContrast(UIImage * __strong *ioImage,
                                                   UIColor * __strong *ioTint,
                                                   UIColor *neutralFG,
                                                   BOOL contextDark,
                                                   UITraitCollection *traits) {
    UIImage *img = ioImage ? *ioImage : nil;
    UIColor *tint = ioTint ? *ioTint : nil;
    if (img && (pt_imageNeedsTemplateTintOnGlass(img, contextDark) || pt_duoImageNeedsTemplateOnOpaquePill(img, contextDark))) {
        if (ioImage) {
            *ioImage = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        tint = neutralFG;
    }
    if (ioTint) {
        *ioTint = pt_duoContrastSafeTintForPowerSaving(tint, neutralFG, contextDark, traits);
    }
}

static BOOL pt_computeImagePixelStats(UIImage *image,
                                      double *outOpaqueRatio,
                                      double *outMinLuma,
                                      double *outMaxLuma) {
    if (outOpaqueRatio) { *outOpaqueRatio = 0.0; }
    if (outMinLuma) { *outMinLuma = 0.0; }
    if (outMaxLuma) { *outMaxLuma = 0.0; }
    if (!image || !image.CGImage) {
        return NO;
    }
    unsigned char pixels[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        return NO;
    }
    CGContextRef ctx = CGBitmapContextCreate(pixels, 16, 16, 8, 16 * 4, cs,
                                             (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return NO;
    }
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 16.0, 16.0), image.CGImage);
    CGContextRelease(ctx);

    NSInteger visibleCount = 0;
    double minLuma = 1.0;
    double maxLuma = 0.0;
    for (int i = 0; i < 256; i++) {
        int base = i * 4;
        unsigned char a = pixels[base + 3];
        if (a < 16) {
            continue;
        }
        double alphaF = (double)a / 255.0;
        double r = MIN(1.0, ((double)pixels[base + 0] / 255.0) / alphaF);
        double g = MIN(1.0, ((double)pixels[base + 1] / 255.0) / alphaF);
        double b = MIN(1.0, ((double)pixels[base + 2] / 255.0) / alphaF);
        double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        minLuma = MIN(minLuma, luma);
        maxLuma = MAX(maxLuma, luma);
        visibleCount++;
    }
    if (!PTDuoSnapshotHasVisiblePixels(visibleCount, 256)) {
        return NO;
    }
    if (outOpaqueRatio) { *outOpaqueRatio = (double)visibleCount / 256.0; }
    if (outMinLuma) { *outMinLuma = minLuma; }
    if (outMaxLuma) { *outMaxLuma = maxLuma; }
    return YES;
}

static UIImage *pt_snapshotViewForVerticalBarWithStats(UIView *view,
                                                       double *outOpaqueRatio,
                                                       double *outMinLuma,
                                                       double *outMaxLuma) {
    if (outOpaqueRatio) { *outOpaqueRatio = 0.0; }
    if (outMinLuma) { *outMinLuma = 0.0; }
    if (outMaxLuma) { *outMaxLuma = 0.0; }
    if (!view || CGRectGetWidth(view.bounds) <= 1.0 || CGRectGetHeight(view.bounds) <= 1.0) {
        return nil;
    }
    BOOL wasSuppressed = [objc_getAssociatedObject(view, kPTDuoCustomViewSuppressedKey) boolValue];
    BOOL prevHidden = view.hidden;
    CGFloat prevAlpha = view.alpha;
    if (wasSuppressed) {
        NSNumber *appHidden = objc_getAssociatedObject(view, kPTDuoCustomViewAppHiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(view, kPTDuoCustomViewAppAlphaKey);
        view.hidden = appHidden ? appHidden.boolValue : NO;
        view.alpha = appAlpha ? appAlpha.doubleValue : 1.0;
    }
    UIImage *snapshot = nil;
    BOOL hasValidStats = NO;
    @try {
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.opaque = NO;
        fmt.scale = 0.0;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size format:fmt];
        snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
            [view.layer renderInContext:rendererContext.CGContext];
        }];
        hasValidStats = (snapshot != nil && pt_computeImagePixelStats(snapshot, outOpaqueRatio, outMinLuma, outMaxLuma));
        if (!hasValidStats
            && view.window != nil && !view.hidden && view.alpha > 0.01) {
            UIImage *hierarchySnap = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
                (void)rendererContext;
                [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
            }];
            if (hierarchySnap) {
                snapshot = hierarchySnap;
                hasValidStats = pt_computeImagePixelStats(snapshot, outOpaqueRatio, outMinLuma, outMaxLuma);
            }
        }
    } @finally {
        if (wasSuppressed) {
            view.hidden = prevHidden;
            view.alpha = prevAlpha;
        }
    }
    if (!snapshot || !hasValidStats) {
        return nil;
    }
    return [snapshot imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *pt_snapshotViewForVerticalBar(UIView *view) {
    return pt_snapshotViewForVerticalBarWithStats(view, NULL, NULL, NULL);
}

static BOOL pt_extractOpaqueViewBgRGBA(UIView *view,
                                       CGFloat *outR,
                                       CGFloat *outG,
                                       CGFloat *outB,
                                       CGFloat *outA) {
    if (!view) {
        return NO;
    }
    UIColor *bg = view.backgroundColor;
    if (!bg && view.layer.backgroundColor != NULL) {
        bg = [UIColor colorWithCGColor:view.layer.backgroundColor];
    }
    if (!bg) {
        return NO;
    }
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if ([bg getRed:&r green:&g blue:&b alpha:&a] && a >= 0.5) {
        if (outR) { *outR = r; }
        if (outG) { *outG = g; }
        if (outB) { *outB = b; }
        if (outA) { *outA = a; }
        return YES;
    }
    CGFloat w = 0.0;
    if ([bg getWhite:&w alpha:&a] && a >= 0.5) {
        if (outR) { *outR = w; }
        if (outG) { *outG = w; }
        if (outB) { *outB = w; }
        if (outA) { *outA = a; }
        return YES;
    }
    return NO;
}

static BOOL pt_viewHasVisibleGradientLayer(UIView *view) {
    if (!view || !view.layer || view.layer.hidden || view.layer.opacity <= 0.05f) {
        return NO;
    }
    if ([view.layer isKindOfClass:[CAGradientLayer class]]) {
        return YES;
    }
    for (CALayer *subL in view.layer.sublayers) {
        if ([subL isKindOfClass:[CAGradientLayer class]] && !subL.hidden && subL.opacity > 0.05f) {
            return YES;
        }
    }
    return NO;
}

static UIImage *pt_findImageInViewHierarchy(UIView *node, NSInteger depth);

static void pt_collectLeafStrokeViewsInNode(UIView *node,
                                            NSInteger depth,
                                            NSMutableArray<UIView *> *outLeaves) {
    if (!node || depth > 3) {
        return;
    }
    if (depth > 0 && (node.hidden || node.alpha <= 0.05)) {
        return;
    }
    if (depth > 0 && node.subviews.count == 0
        && ![node isKindOfClass:[UIImageView class]]
        && ![node isKindOfClass:[UILabel class]]) {
        [outLeaves addObject:node];
        return;
    }
    for (UIView *sub in node.subviews) {
        pt_collectLeafStrokeViewsInNode(sub, depth + 1, outLeaves);
    }
}

static UIImage *pt_snapshotCompositeForegroundGlyphInControl(UIView *control) {
    if (!control || CGRectIsEmpty(control.bounds)) {
        return nil;
    }
    // Preserve full artwork whenever an explicit UIImage / UIImageView exists.
    if (pt_findImageInViewHierarchy(control, 0) != nil) {
        return nil;
    }

    NSMutableArray<UIView *> *allVisibleLeaves = [NSMutableArray array];
    pt_collectLeafStrokeViewsInNode(control, 0, allVisibleLeaves);

    if (allVisibleLeaves.count < 2) {
        return nil;
    }

    UIView *backdropView = nil;
    CGRect backdropRect = CGRectZero;
    BOOL backdropHasSolid = NO;
    CGFloat br = 0.0, bg = 0.0, bb = 0.0, ba = 0.0;
    CGFloat bestBackdropArea = 0.0;

    for (UIView *v in allVisibleLeaves) {
        CGRect r = [v convertRect:v.bounds toView:control];
        CGFloat w = CGRectGetWidth(r);
        CGFloat h = CGRectGetHeight(r);
        if (w < 26.0 || h < 20.0) {
            continue;
        }
        CGFloat r0 = 0.0, g0 = 0.0, b0 = 0.0, a0 = 0.0;
        BOOL hasSolid = pt_extractOpaqueViewBgRGBA(v, &r0, &g0, &b0, &a0);
        BOOL hasGrad = pt_viewHasVisibleGradientLayer(v);
        if (!hasSolid && !hasGrad) {
            continue;
        }
        CGFloat area = w * h;
        // Prefer an explicit solid-color backdrop so contrast against strokes is verified.
        if (!backdropView || (hasSolid && !backdropHasSolid) || (hasSolid == backdropHasSolid && area > bestBackdropArea)) {
            backdropView = v;
            backdropRect = r;
            backdropHasSolid = hasSolid;
            br = r0; bg = g0; bb = b0; ba = a0;
            bestBackdropArea = area;
        }
    }
    if (!backdropView) {
        return nil;
    }

    NSMutableArray<NSDictionary *> *strokes = [NSMutableArray array];
    CGRect unionRect = CGRectNull;
    for (UIView *v in allVisibleLeaves) {
        if (v == backdropView) {
            continue;
        }
        CGRect r = [v convertRect:v.bounds toView:control];
        if (!PTDuoRectIsEnclosedInnerStroke(r, backdropRect)) {
            continue;
        }
        CGFloat sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0;
        if (!pt_extractOpaqueViewBgRGBA(v, &sr, &sg, &sb, &sa)) {
            continue;
        }
        if (backdropHasSolid && !PTDuoColorsHaveContrast(sr, sg, sb, sa, br, bg, bb, ba)) {
            continue;
        }
        [strokes addObject:@{
            @"rect": [NSValue valueWithCGRect:r],
            @"radius": @(v.layer.cornerRadius),
        }];
        unionRect = CGRectIsNull(unionRect) ? r : CGRectUnion(unionRect, r);
    }

    if (strokes.count == 0 || CGRectIsNull(unionRect)) {
        return nil;
    }
    CGFloat uw = CGRectGetWidth(unionRect);
    CGFloat uh = CGRectGetHeight(unionRect);
    if (MAX(uw, uh) < 8.0 || !CGRectContainsRect(CGRectInset(backdropRect, -2.0, -2.0), unionRect)) {
        return nil;
    }

    CGFloat canvasSide = MIN(26.0, MAX(18.0, ceil(MAX(uw, uh)) + 6.0));
    CGFloat dx = (canvasSide - uw) * 0.5 - CGRectGetMinX(unionRect);
    CGFloat dy = (canvasSide - uh) * 0.5 - CGRectGetMinY(unionRect);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale = 0.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(canvasSide, canvasSide) format:fmt];
    UIImage *glyph = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [[UIColor whiteColor] setFill];
        for (NSDictionary *item in strokes) {
            CGRect r = [item[@"rect"] CGRectValue];
            CGRect shifted = CGRectOffset(r, dx, dy);
            CGFloat radius = [item[@"radius"] doubleValue];
            if (radius > 0.5) {
                [[UIBezierPath bezierPathWithRoundedRect:shifted cornerRadius:radius] fill];
            } else {
                [[UIBezierPath bezierPathWithRect:shifted] fill];
            }
        }
    }];
    return glyph ? [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

@interface PTDuoTabSlotOverlay : NSObject
@property (nonatomic, assign) NSUInteger slotIndex;
@property (nonatomic, weak) UIControl *actionControl;
@property (nonatomic, weak) UITapGestureRecognizer *tapGesture;
@property (nonatomic, weak) id tapTarget;
@property (nonatomic, assign) SEL tapAction;
@property (nonatomic, weak) UIView *visualView;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *visualSource;
@property (nonatomic, copy) NSString *actionSource;
@property (nonatomic, assign) CGSize visualSize;
@property (nonatomic, assign) BOOL cachedDarkMode;
@property (nonatomic, assign) BOOL promoteToProminent;
@property (nonatomic, assign) BOOL isSnapshot;
@property (nonatomic, assign) double snapshotOpaqueRatio;
@property (nonatomic, assign) double snapshotMinLuma;
@property (nonatomic, assign) double snapshotMaxLuma;
@property (nonatomic, strong) UIColor *accentBgColor;
@property (nonatomic, strong) UIColor *accentTintColor;
@end

@implementation PTDuoTabSlotOverlay
@end

static BOOL pt_controlHasDispatchableTarget(UIControl *control);

static UIControl *pt_findActionControlInView(UIView *node, NSInteger depth) {
    if (!node || depth > 4) {
        return nil;
    }
    if ([node isKindOfClass:[UIControl class]]) {
        UIControl *ctrl = (UIControl *)node;
        if (pt_controlHasDispatchableTarget(ctrl)) {
            return ctrl;
        }
    }
    for (UIView *sub in node.subviews) {
        UIControl *found = pt_findActionControlInView(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

static BOOL pt_extractVerifiedTapGestureAction(UIView *node,
                                                NSInteger depth,
                                                UITapGestureRecognizer * __autoreleasing *outTapGR,
                                                id __autoreleasing *outTarget,
                                                SEL *outAction) {
    if (outTapGR) { *outTapGR = nil; }
    if (outTarget) { *outTarget = nil; }
    if (outAction) { *outAction = NULL; }
    if (!node || depth > 3) {
        return NO;
    }
    static Ivar targetsIvar = NULL;
    static Ivar recTargetIvar = NULL;
    static Ivar recActionIvar = NULL;
    static ptrdiff_t recActionOffset = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        targetsIvar = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
        Class recTargetCls = NSClassFromString(@"UIGestureRecognizerTarget");
        if (recTargetCls) {
            recTargetIvar = class_getInstanceVariable(recTargetCls, "_target");
            recActionIvar = class_getInstanceVariable(recTargetCls, "_action");
            if (recActionIvar) {
                recActionOffset = ivar_getOffset(recActionIvar);
            }
        }
    });

    if (targetsIvar && recTargetIvar && recActionIvar) {
        for (UIGestureRecognizer *gr in node.gestureRecognizers) {
            if (![gr isKindOfClass:[UITapGestureRecognizer class]] || !gr.enabled) {
                continue;
            }
            UITapGestureRecognizer *tap = (UITapGestureRecognizer *)gr;
            if (tap.numberOfTapsRequired > 1 || tap.numberOfTouchesRequired > 1) {
                continue;
            }
            id targetsObj = object_getIvar(tap, targetsIvar);
            if (![targetsObj isKindOfClass:[NSArray class]]) {
                continue;
            }
            NSArray *targets = (NSArray *)targetsObj;
            if (targets.count != 1) {
                continue;
            }
            id recTarget = targets.firstObject;
            id target = recTarget ? object_getIvar(recTarget, recTargetIvar) : nil;
            SEL action = recTarget ? *(SEL *)((uintptr_t)(__bridge const void *)recTarget + (uintptr_t)recActionOffset) : NULL;
            if (target && action != NULL && [target respondsToSelector:action]) {
                if (outTapGR) { *outTapGR = tap; }
                if (outTarget) { *outTarget = target; }
                if (outAction) { *outAction = action; }
                return YES;
            }
        }
    }
    for (UIView *sub in node.subviews) {
        if (pt_extractVerifiedTapGestureAction(sub, depth + 1, outTapGR, outTarget, outAction)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_viewHasTapGesture(UIView *node, NSInteger depth) {
    return pt_extractVerifiedTapGestureAction(node, depth, NULL, NULL, NULL);
}

static void pt_triggerControlAction(UIControl *control) {
    if (!control || !control.enabled) {
        return;
    }
    UIControlEvents events = [control allControlEvents];
    if ((events & UIControlEventTouchUpInside) != 0) {
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }
    if (@available(iOS 9.0, *)) {
        if ((events & UIControlEventPrimaryActionTriggered) != 0) {
            [control sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
            return;
        }
    }
    if ((events & UIControlEventTouchDown) != 0) {
        [control sendActionsForControlEvents:UIControlEventTouchDown];
        return;
    }
    if (events != 0) {
        [control sendActionsForControlEvents:events];
    }
}

static BOOL pt_dispatchVerifiedTapAction(UITapGestureRecognizer *tapGR, id target, SEL action) {
    if (!target || action == NULL || ![target respondsToSelector:action]) {
        return NO;
    }
    return [[UIApplication sharedApplication] sendAction:action to:target from:(tapGR ?: target) forEvent:nil];
}

static UIImage *pt_findImageInViewHierarchyWithSource(UIView *node,
                                                      NSInteger depth,
                                                      NSString * __autoreleasing *outSource) {
    if (outSource) { *outSource = nil; }
    if (!node || depth > 4) {
        return nil;
    }
    if (depth > 0 && (node.hidden || node.alpha <= 0.01)) {
        return nil;
    }
    if ([node isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)node;
        UIImage *img = b.currentImage ?: [b imageForState:UIControlStateNormal];
        if (img && !pt_imageIsPlaceholderBlank(img)) {
            if (outSource) { *outSource = @"image"; }
            return img;
        }
        if (@available(iOS 15.0, *)) {
            if (b.configuration && b.configuration.image && !pt_imageIsPlaceholderBlank(b.configuration.image)) {
                if (outSource) { *outSource = @"configImage"; }
                return b.configuration.image;
            }
        }
        UIImage *bgImg = b.currentBackgroundImage ?: [b backgroundImageForState:UIControlStateNormal];
        if (bgImg && !pt_imageIsPlaceholderBlank(bgImg)) {
            if (outSource) { *outSource = @"bgImage"; }
            return bgImg;
        }
    } else if ([node isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)node;
        if (iv.image && !pt_imageIsPlaceholderBlank(iv.image)) {
            if (outSource) { *outSource = @"image"; }
            return iv.image;
        }
    }
    for (UIView *sub in node.subviews) {
        UIImage *img = pt_findImageInViewHierarchyWithSource(sub, depth + 1, outSource);
        if (img) {
            return img;
        }
    }
    NSString *clsName = NSStringFromClass([node class]);
    id contents = node.layer.contents;
    if (contents != nil
        && ![clsName hasPrefix:@"_UI"]
        && CGRectGetWidth(node.bounds) >= 12.0 && CGRectGetWidth(node.bounds) <= 104.0
        && CGRectGetHeight(node.bounds) >= 12.0 && CGRectGetHeight(node.bounds) <= 104.0
        && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
        CGFloat scale = node.contentScaleFactor > 0.5 ? node.contentScaleFactor : 2.0;
        UIImage *layerImg = [UIImage imageWithCGImage:(CGImageRef)contents scale:scale orientation:UIImageOrientationUp];
        if (layerImg) {
            if (outSource) { *outSource = @"layerContents"; }
            return layerImg;
        }
    }
    return nil;
}

static UIImage *pt_findImageInViewHierarchy(UIView *node, NSInteger depth) {
    return pt_findImageInViewHierarchyWithSource(node, depth, NULL);
}

static NSString *pt_findLabelTextInViewHierarchy(UIView *node, NSInteger depth) {
    if (!node || depth > 4) {
        return nil;
    }
    if ([node isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)node;
        NSString *t = b.currentTitle ?: [b titleForState:UIControlStateNormal];
        if (t.length > 0) {
            return t;
        }
        if (@available(iOS 15.0, *)) {
            if (b.configuration.title.length > 0) {
                return b.configuration.title;
            }
            if (b.configuration.attributedTitle.string.length > 0) {
                return b.configuration.attributedTitle.string;
            }
        }
    } else if ([node isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)node).text;
        if (t.length > 0) {
            return t;
        }
    }
    for (UIView *sub in node.subviews) {
        NSString *t = pt_findLabelTextInViewHierarchy(sub, depth + 1);
        if (t.length > 0) {
            return t;
        }
    }
    return nil;
}

static BOOL pt_viewNodeIsVisuallyActive(UIView *node, NSInteger depth) {
    if (!node) {
        return NO;
    }
    if (depth == 0 && [objc_getAssociatedObject(node, kPTDuoCustomViewSuppressedKey) boolValue]) {
        NSNumber *appHidden = objc_getAssociatedObject(node, kPTDuoCustomViewAppHiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(node, kPTDuoCustomViewAppAlphaKey);
        BOOL h = appHidden ? appHidden.boolValue : NO;
        CGFloat a = appAlpha ? appAlpha.doubleValue : 1.0;
        return !h && isfinite(a) && a > 0.01;
    }
    return !node.hidden && node.alpha > 0.01;
}

static BOOL pt_layerHasOwnVisualDrawing(CALayer *layer, NSInteger depth) {
    if (!layer || depth > 4 || layer.hidden || layer.opacity <= 0.01f) {
        return NO;
    }
    if (layer.contents != nil || [layer isKindOfClass:[CAGradientLayer class]]) {
        return YES;
    }
    if ([layer isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)layer).path != NULL) {
        return YES;
    }
    if (layer.backgroundColor != NULL && CGColorGetAlpha(layer.backgroundColor) > 0.05) {
        return YES;
    }
    for (CALayer *subL in layer.sublayers) {
        if (pt_layerHasOwnVisualDrawing(subL, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_viewHasOwnVisualDrawing(UIView *node, NSInteger depth) {
    if (!node || depth > 4 || !pt_viewNodeIsVisuallyActive(node, depth)) {
        return NO;
    }
    if ([node isKindOfClass:[UIImageView class]] && ((UIImageView *)node).image != nil) {
        return YES;
    }
    if ([node isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)node;
        if (b.currentImage || [b imageForState:UIControlStateNormal]
            || b.currentBackgroundImage || [b backgroundImageForState:UIControlStateNormal]
            || b.currentTitle.length > 0) {
            return YES;
        }
        if (@available(iOS 15.0, *)) {
            if (b.configuration && (b.configuration.image || b.configuration.title.length > 0 || b.configuration.attributedTitle.length > 0)) {
                return YES;
            }
        }
    }
    if ([node isKindOfClass:[UILabel class]] && ((UILabel *)node).text.length > 0) {
        return YES;
    }
    if (pt_layerHasOwnVisualDrawing(node.layer, 0)) {
        return YES;
    }
    NSString *clsName = NSStringFromClass([node class]);
    if (![clsName hasPrefix:@"UI"] && ![clsName hasPrefix:@"_UI"]
        && [node methodForSelector:@selector(drawRect:)] != [UIView instanceMethodForSelector:@selector(drawRect:)]) {
        return YES;
    }
    UIColor *bg = node.backgroundColor;
    if (bg) {
        CGFloat a = 0.0;
        if ([bg getRed:NULL green:NULL blue:NULL alpha:&a] && a > 0.05) {
            return YES;
        }
    }
    if (node.layer.backgroundColor != NULL && CGColorGetAlpha(node.layer.backgroundColor) > 0.05) {
        return YES;
    }
    for (UIView *sub in node.subviews) {
        if (pt_viewHasOwnVisualDrawing(sub, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_nodeAppVisibleForOverlayScan(UIView *node, BOOL allowHiddenFromRelocation) {
    if (!node) {
        return NO;
    }
    if (allowHiddenFromRelocation) {
        if ([objc_getAssociatedObject(node, kPTDuoTabBarRelocatedKey) boolValue]) {
            NSNumber *appH = objc_getAssociatedObject(node, kPTDuoTabBarAppHiddenKey);
            NSNumber *appA = objc_getAssociatedObject(node, kPTDuoTabBarAppAlphaKey);
            BOOL h = appH ? appH.boolValue : NO;
            CGFloat a = appA ? appA.doubleValue : 1.0;
            return !h && a > 0.01;
        }
        if ([objc_getAssociatedObject(node, kPTDuoTabChromeRelocatedKey) boolValue]) {
            NSNumber *appH = objc_getAssociatedObject(node, kPTDuoTabChromeAppHiddenKey);
            NSNumber *appA = objc_getAssociatedObject(node, kPTDuoTabChromeAppAlphaKey);
            BOOL h = appH ? appH.boolValue : NO;
            CGFloat a = appA ? appA.doubleValue : 1.0;
            return !h && a > 0.01;
        }
    }
    return !node.hidden && node.alpha > 0.01;
}

static void pt_collectCustomOverlayCandidatesInView(UIView *node,
                                                    UITabBar *tabBar,
                                                    NSInteger depth,
                                                    CGFloat maxAllowedWidth,
                                                    CGFloat tabBarWidth,
                                                    BOOL allowHiddenFromRelocation,
                                                    NSInteger *outNodesScanned,
                                                    NSMutableArray<UIView *> *outCandidates) {
    if (!node || !tabBar || depth > 5) {
        return;
    }
    if (outNodesScanned) { (*outNodesScanned)++; }
    if (!pt_nodeAppVisibleForOverlayScan(node, allowHiddenFromRelocation)) {
        return;
    }
    if (depth > 0) {
        NSString *clsName = NSStringFromClass([node class]);
        if ([clsName isEqualToString:@"UITabBarButton"]
            || [clsName isEqualToString:@"_UITabButton"]
            || [clsName containsString:@"UITabBarButtonLabel"]
            || [clsName isEqualToString:@"_UITabBarBackgroundView"]) {
            return;
        }
        BOOL isCustomClass = !pt_duoIsSystemTabBarSubviewClassName(clsName) && ![clsName hasPrefix:@"UI"];
        BOOL isCustomButtonOrControl = ([node isKindOfClass:[UIButton class]] || ([node isKindOfClass:[UIControl class]] && ![clsName hasPrefix:@"UITabBar"]))
            && ![clsName hasPrefix:@"_UI"];
        if (isCustomClass || isCustomButtonOrControl) {
            CGRect rect = [node convertRect:node.bounds toView:tabBar];
            CGFloat w = CGRectGetWidth(rect);
            CGFloat h = CGRectGetHeight(rect);
            if (w >= 12.0 && w <= maxAllowedWidth && w < tabBarWidth * 0.45 && h >= 12.0 && h <= 104.0) {
                [outCandidates addObject:node];
            }
        }
    }
    for (UIView *sub in node.subviews) {
        pt_collectCustomOverlayCandidatesInView(sub, tabBar, depth + 1, maxAllowedWidth, tabBarWidth, allowHiddenFromRelocation, outNodesScanned, outCandidates);
    }
}

static NSArray<NSNumber *> *pt_collectVisibleSystemTabButtonCenters(UITabBar *tabBar,
                                                                   UITabBarController *tabVC,
                                                                   CGFloat *outMinX,
                                                                   CGFloat *outMaxX) {
    if (outMinX) { *outMinX = 0.0; }
    if (outMaxX) { *outMaxX = 0.0; }
    if (!tabBar) {
        return @[];
    }
    NSMutableArray<UIView *> *roots = [NSMutableArray arrayWithObject:tabBar];
    if (tabVC) {
        for (UIView *chrome in pt_collectFloatingTabBarChromeViews(tabVC)) {
            if (![roots containsObject:chrome]) {
                [roots addObject:chrome];
            }
        }
    }
    NSMutableArray<NSNumber *> *centers = [NSMutableArray array];
    __block CGFloat minX = CGFLOAT_MAX;
    __block CGFloat maxX = -CGFLOAT_MAX;
    void (^scanNode)(UIView *, NSInteger) = nil;
    __block void (^weakScan)(UIView *, NSInteger);
    scanNode = ^(UIView *node, NSInteger depth) {
        if (!node || depth > 5) {
            return;
        }
        if (depth > 0 && !pt_nodeAppVisibleForOverlayScan(node, YES)) {
            return;
        }
        NSString *clsName = NSStringFromClass([node class]);
        if ([clsName isEqualToString:@"UITabBarButton"] || [clsName isEqualToString:@"_UITabButton"]) {
            CGRect r = [node convertRect:node.bounds toView:tabBar];
            CGFloat w = CGRectGetWidth(r);
            CGFloat h = CGRectGetHeight(r);
            if (w >= 20.0 && h >= 18.0) {
                minX = MIN(minX, CGRectGetMinX(r));
                maxX = MAX(maxX, CGRectGetMaxX(r));
                [centers addObject:@(CGRectGetMidX(r))];
                return;
            }
        }
        for (UIView *sub in node.subviews) {
            weakScan(sub, depth + 1);
        }
    };
    weakScan = scanNode;
    for (UIView *root in roots) {
        scanNode(root, 0);
    }
    [centers sortUsingSelector:@selector(compare:)];
    if (centers.count >= 2 && isfinite(minX) && isfinite(maxX)) {
        if (outMinX) { *outMinX = minX; }
        if (outMaxX) { *outMaxX = maxX; }
    }
    return centers;
}

static BOOL pt_viewAncestorsInsideBarAreAppVisible(UIView *view, UIView *barRoot) {
    UIView *cur = view;
    NSInteger hops = 0;
    while (cur && hops < 8) {
        if (cur == barRoot || [cur isKindOfClass:[UITabBar class]]) {
            return pt_nodeAppVisibleForOverlayScan(cur, YES);
        }
        if (cur.hidden || cur.alpha <= 0.01) {
            if ([objc_getAssociatedObject(cur, kPTDuoTabChromeRelocatedKey) boolValue]) {
                if (!pt_nodeAppVisibleForOverlayScan(cur, YES)) {
                    return NO;
                }
            } else {
                return NO;
            }
        }
        cur = cur.superview;
        hops++;
    }
    return YES;
}

static PTDuoTabSlotOverlay *pt_buildTabSlotOverlay(NSUInteger slotIndex,
                                                   UITabBar *tabBar,
                                                   UIControl *bestControl,
                                                   UITapGestureRecognizer *bestTapGR,
                                                   id bestTapTarget,
                                                   SEL bestTapAction,
                                                   UIImage *bestImage,
                                                   NSString *bestImageSource,
                                                   UIView *bestVisualView,
                                                   CGRect bestVisualRect,
                                                   PTDuoTabSlotOverlay *cached,
                                                   BOOL tabBarAppWantsHidden,
                                                   BOOL hasExistingProminentTab,
                                                   BOOL isDarkMode,
                                                   BOOL *outUnknownActionable) {
    if (outUnknownActionable) { *outUnknownActionable = NO; }
    if (!bestControl && cached.actionControl) {
        bestControl = cached.actionControl;
    }
    if (!bestControl && !bestTapTarget && cached.tapTarget && cached.tapAction != NULL) {
        bestTapGR = cached.tapGesture;
        bestTapTarget = cached.tapTarget;
        bestTapAction = cached.tapAction;
    }
    if (!bestVisualView && cached.visualView) {
        bestVisualView = cached.visualView;
    }

    CGSize currentVisualSize = bestVisualView ? bestVisualView.bounds.size : CGSizeZero;
    BOOL cacheMatchesIdentity = (cached != nil
                                 && cached.image != nil
                                 && cached.visualView == bestVisualView
                                 && ((bestControl != nil && cached.actionControl == bestControl)
                                     || (bestControl == nil && cached.tapTarget == bestTapTarget && cached.tapAction == bestTapAction))
                                 && fabs(cached.visualSize.width - currentVisualSize.width) <= 0.5
                                 && fabs(cached.visualSize.height - currentVisualSize.height) <= 0.5
                                 && cached.cachedDarkMode == isDarkMode);

    UIImage *finalImg = bestImage;
    NSString *finalVisualSource = bestImageSource;
    BOOL isSnapshot = NO;
    double overlayOpaqueRatio = 0.0;
    double overlayMinLuma = 0.0;
    double overlayMaxLuma = 0.0;
    if (!finalImg && cacheMatchesIdentity) {
        finalImg = cached.image;
        finalVisualSource = cached.visualSource;
        isSnapshot = cached.isSnapshot;
        overlayOpaqueRatio = cached.snapshotOpaqueRatio;
        overlayMinLuma = cached.snapshotMinLuma;
        overlayMaxLuma = cached.snapshotMaxLuma;
    } else if (!finalImg && bestVisualView) {
        BOOL safeToCaptureLive = (!tabBarAppWantsHidden
                                  && pt_viewAncestorsInsideBarAreAppVisible(bestVisualView, tabBar)
                                  && CGRectGetWidth(bestVisualView.bounds) >= 12.0
                                  && CGRectGetHeight(bestVisualView.bounds) >= 12.0);
        if (safeToCaptureLive) {
            double oq = 0.0, mn = 0.0, mx = 0.0;
            finalImg = pt_snapshotViewForVerticalBarWithStats(bestVisualView, &oq, &mn, &mx);
            if (finalImg) {
                isSnapshot = YES;
                finalVisualSource = @"snapshot";
                overlayOpaqueRatio = oq;
                overlayMinLuma = mn;
                overlayMaxLuma = mx;
            }
        }
        if (!finalImg && cached.image) {
            finalImg = cached.image;
            finalVisualSource = cached.visualSource;
            isSnapshot = cached.isSnapshot;
            overlayOpaqueRatio = cached.snapshotOpaqueRatio;
            overlayMinLuma = cached.snapshotMinLuma;
            overlayMaxLuma = cached.snapshotMaxLuma;
        }
    } else if (!finalImg && cached.image) {
        finalImg = cached.image;
        finalVisualSource = cached.visualSource;
        isSnapshot = cached.isSnapshot;
        overlayOpaqueRatio = cached.snapshotOpaqueRatio;
        overlayMinLuma = cached.snapshotMinLuma;
        overlayMaxLuma = cached.snapshotMaxLuma;
    }

    NSString *title = (!finalImg && bestVisualView) ? pt_findLabelTextInViewHierarchy(bestVisualView, 0) : nil;
    if (pt_stringIsEffectivelyBlank(title)) {
        title = nil;
    }
    if (!finalImg && title.length > 0) {
        finalVisualSource = @"title";
    }
    BOOL hasAction = (bestControl != nil || (bestTapTarget != nil && bestTapAction != NULL));
    if (hasAction && !finalImg && title.length == 0) {
        if (outUnknownActionable) { *outUnknownActionable = YES; }
        return nil;
    }
    if (!finalImg && title.length == 0 && !hasAction && !bestVisualView) {
        return nil;
    }

    PTDuoTabSlotOverlay *overlay = [[PTDuoTabSlotOverlay alloc] init];
    overlay.slotIndex = slotIndex;
    overlay.actionControl = bestControl;
    overlay.tapGesture = bestTapGR;
    overlay.tapTarget = bestTapTarget;
    overlay.tapAction = bestTapAction;
    overlay.actionSource = bestControl ? @"control" : ((bestTapTarget && bestTapAction) ? @"tapGesture" : nil);
    overlay.visualView = bestVisualView;
    overlay.visualSize = currentVisualSize;
    overlay.cachedDarkMode = isDarkMode;
    overlay.image = finalImg;
    overlay.visualSource = finalVisualSource;
    overlay.isSnapshot = isSnapshot;
    overlay.snapshotOpaqueRatio = overlayOpaqueRatio;
    overlay.snapshotMinLuma = overlayMinLuma;
    overlay.snapshotMaxLuma = overlayMaxLuma;
    overlay.title = title;

    BOOL opaqueFilled = NO;
    BOOL satAccent = NO;
    pt_inspectOpaqueFilledBadge(finalImg, &opaqueFilled, &satAccent);
    UIColor *bgColor = nil;
    UIColor *tintColor = nil;
    if (bestVisualView) {
        pt_scanAuxiliaryViewStyle(bestVisualView, 0, &bgColor, &tintColor);
    }
    CGFloat minDim = bestVisualView ? MIN(CGRectGetWidth(bestVisualView.bounds), CGRectGetHeight(bestVisualView.bounds)) : 0.0;
    BOOL circularAccent = (bgColor != nil && bestVisualView != nil && bestVisualView.layer.cornerRadius >= minDim * 0.35 && minDim >= 24.0);
    BOOL protrudes = (bestVisualView != nil && CGRectGetMinY(bestVisualRect) < -4.0 && bestVisualView.layer.cornerRadius >= minDim * 0.35);
    overlay.accentBgColor = bgColor;
    overlay.accentTintColor = tintColor;
    overlay.promoteToProminent = PTDuoShouldPromoteTabOverlayToProminent(
        hasExistingProminentTab,
        opaqueFilled,
        satAccent,
        circularAccent,
        protrudes);
    return overlay;
}

static NSArray<UIView *> *pt_collectAllTabBarCustomCandidates(UITabBarController *tabVC,
                                                              UITabBar *tabBar,
                                                              CGFloat maxAllowedWidth,
                                                              CGFloat tabBarWidth,
                                                              BOOL allowHiddenFromRelocation,
                                                              NSInteger *outNodesScanned) {
    NSInteger nodesScanned = 0;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    pt_collectCustomOverlayCandidatesInView(tabBar, tabBar, 0, maxAllowedWidth, tabBarWidth, allowHiddenFromRelocation, &nodesScanned, candidates);

    UIViewController *selectedVC = tabVC ? pt_selectedViewControllerForTabBarController(tabVC) : nil;
    UIView *contentView = (selectedVC && selectedVC.isViewLoaded) ? selectedVC.view : nil;
    NSMutableArray<UIView *> *extraRoots = [NSMutableArray array];
    if (tabBar.superview && tabBar.superview != contentView) {
        [extraRoots addObject:tabBar.superview];
    }
    if (tabVC) {
        for (UIView *chrome in pt_collectFloatingTabBarChromeViews(tabVC)) {
            if (chrome != tabBar && ![extraRoots containsObject:chrome]) {
                [extraRoots addObject:chrome];
            }
        }
    }
    for (UIView *root in extraRoots) {
        for (UIView *sub in root.subviews) {
            nodesScanned++;
            if (sub == tabBar || sub == contentView || (contentView && pt_isDescendantOrSameView(contentView, sub))) {
                continue;
            }
            NSString *clsName = NSStringFromClass([sub class]);
            if ([clsName isEqualToString:@"UITransitionView"] || [clsName isEqualToString:@"UIViewControllerWrapperView"]) {
                continue;
            }
            BOOL rootRelocated = allowHiddenFromRelocation || [objc_getAssociatedObject(root, kPTDuoTabChromeRelocatedKey) boolValue];
            CGRect rInTabBar = [sub convertRect:sub.bounds toView:tabBar];
            CGFloat tabMidY = CGRectGetMidY(tabBar.bounds);
            CGFloat subMidY = CGRectGetMidY(rInTabBar);
            CGFloat bandTol = MAX(CGRectGetHeight(tabBar.bounds), 56.0);
            if (fabs(subMidY - tabMidY) <= bandTol) {
                if (!pt_nodeAppVisibleForOverlayScan(sub, rootRelocated)) {
                    continue;
                }
                CGFloat w = CGRectGetWidth(rInTabBar);
                CGFloat h = CGRectGetHeight(rInTabBar);
                BOOL isCustom = ([sub isKindOfClass:[UIButton class]]
                                 || ([sub isKindOfClass:[UIControl class]] && ![clsName hasPrefix:@"UITabBar"])
                                 || (!pt_duoIsSystemTabBarSubviewClassName(clsName) && ![clsName hasPrefix:@"UI"]));
                if (isCustom && w >= 12.0 && w <= maxAllowedWidth && w < tabBarWidth * 0.45 && h >= 12.0 && h <= 104.0) {
                    if (![candidates containsObject:sub]) {
                        [candidates addObject:sub];
                    }
                }
            }
        }
    }
    if (outNodesScanned) { *outNodesScanned = nodesScanned; }
    return candidates;
}

static NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *pt_discoverBlankSlotOverlaysWithOptions(
    UITabBarController *tabVC,
    UITabBar *tabBar,
    NSUInteger slotCount,
    BOOL (^slotIsBlank)(NSUInteger idx),
    BOOL hasExistingProminentTab,
    BOOL isDarkMode,
    BOOL *outHasUnknownActionableSlot) {
    if (outHasUnknownActionableSlot) {
        *outHasUnknownActionableSlot = NO;
    }
    if (!tabBar || slotCount < 2 || !slotIsBlank) {
        return @{};
    }
    NSMutableIndexSet *blankIndices = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < slotCount; i++) {
        if (slotIsBlank(i)) {
            [blankIndices addIndex:i];
        }
    }
    if (blankIndices.count == 0) {
        return @{};
    }

    CGFloat tabBarWidth = CGRectGetWidth(tabBar.bounds);
    if (tabBarWidth <= 1.0 && tabVC && tabVC.isViewLoaded) {
        tabBarWidth = CGRectGetWidth(tabVC.view.bounds);
    }
    if (tabBarWidth <= 1.0) {
        NSDictionary *cached = objc_getAssociatedObject(tabBar, kPTDuoTabOverlayCacheKey);
        return cached ?: @{};
    }

    os_log_t spLog = pt_duoSignpostLog();
    os_signpost_id_t spId = os_signpost_id_make_with_pointer(spLog, (__bridge const void *)tabBar);
    os_signpost_interval_begin(spLog, spId, "BlankSlotCapture");
    CFTimeInterval t0 = CACurrentMediaTime();

    BOOL isAlreadyRelocated = [objc_getAssociatedObject(tabBar, kPTDuoTabBarRelocatedKey) boolValue];
    NSNumber *appHiddenNum = objc_getAssociatedObject(tabBar, kPTDuoTabBarAppHiddenKey);
    BOOL tabBarAppWantsHidden = isAlreadyRelocated ? (appHiddenNum ? appHiddenNum.boolValue : NO) : tabBar.hidden;
    NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *cachedMap = objc_getAssociatedObject(tabBar, kPTDuoTabOverlayCacheKey);

    CGFloat btnMinX = 0.0;
    CGFloat btnMaxX = 0.0;
    NSArray<NSNumber *> *tabBtnCenters = pt_collectVisibleSystemTabButtonCenters(tabBar, tabVC, &btnMinX, &btnMaxX);
    CGFloat spanOriginX = 0.0;
    CGFloat spanWidth = tabBarWidth;
    if (tabBtnCenters.count >= 2 && (btnMaxX - btnMinX) >= 100.0 && (btnMaxX - btnMinX) < tabBarWidth - 20.0) {
        spanOriginX = btnMinX;
        spanWidth = btnMaxX - btnMinX;
    }
    CGFloat slotWidth = spanWidth / (CGFloat)slotCount;
    CGFloat maxAllowedWidth = MAX(slotWidth * 1.45, 96.0);

    NSInteger nodesScanned = 0;
    NSArray<UIView *> *candidates = pt_collectAllTabBarCustomCandidates(tabVC, tabBar, maxAllowedWidth, tabBarWidth, isAlreadyRelocated, &nodesScanned);

    __block BOOL foundUnknownActionable = NO;
    NSMutableDictionary<NSNumber *, PTDuoTabSlotOverlay *> *result = [NSMutableDictionary dictionary];
    [blankIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop;
        CGFloat slotCenterX = spanOriginX + ((CGFloat)idx + 0.5) * slotWidth;
        UIControl *bestControl = nil;
        CGFloat bestCtrlDist = CGFLOAT_MAX;
        UITapGestureRecognizer *bestTapGR = nil;
        id bestTapTarget = nil;
        SEL bestTapAction = NULL;
        CGFloat bestTapDist = CGFLOAT_MAX;
        UIImage *bestImage = nil;
        NSString *bestImageSource = nil;
        CGFloat bestImgDist = CGFLOAT_MAX;
        UIView *bestVisualView = nil;
        CGFloat bestVisDist = CGFLOAT_MAX;
        CGRect bestVisualRect = CGRectZero;
        NSMutableArray<NSDictionary *> *rankedVisuals = [NSMutableArray array];

        for (UIView *cand in candidates) {
            CGRect r = [cand convertRect:cand.bounds toView:tabBar];
            CGFloat midX = CGRectGetMidX(r);
            if (!PTDuoTabSlotOverlayMatchesCenterX(midX - spanOriginX, idx, slotCount, spanWidth)) {
                continue;
            }
            CGFloat dist = fabs(midX - slotCenterX);
            if ([cand isKindOfClass:[UIControl class]]) {
                UIControl *ctrl = (UIControl *)cand;
                if (ctrl.allTargets.count > 0) {
                    CGFloat score = dist - ([ctrl isKindOfClass:[UIButton class]] ? 4.0 : 0.0);
                    if (score < bestCtrlDist) {
                        bestCtrlDist = score;
                        bestControl = ctrl;
                    }
                }
            } else {
                UIControl *innerCtrl = pt_findActionControlInView(cand, 0);
                if (innerCtrl && dist < bestCtrlDist) {
                    bestCtrlDist = dist;
                    bestControl = innerCtrl;
                } else {
                    UITapGestureRecognizer *tGR = nil;
                    id tTarget = nil;
                    SEL tAct = NULL;
                    if (pt_extractVerifiedTapGestureAction(cand, 0, &tGR, &tTarget, &tAct) && dist < bestTapDist) {
                        bestTapDist = dist;
                        bestTapGR = tGR;
                        bestTapTarget = tTarget;
                        bestTapAction = tAct;
                    }
                }
            }

            NSString *imgSrc = nil;
            UIImage *directImg = pt_findImageInViewHierarchyWithSource(cand, 0, &imgSrc);
            if (directImg && dist < bestImgDist) {
                bestImgDist = dist;
                bestImage = directImg;
                bestImageSource = imgSrc;
                bestVisualView = cand;
                bestVisualRect = r;
            }
            if (pt_viewHasOwnVisualDrawing(cand, 0)) {
                CGFloat visScore = dist + (directImg ? -6.0 : 0.0) + (CGRectGetWidth(r) * 0.05);
                [rankedVisuals addObject:@{
                    @"view": cand,
                    @"score": @(visScore),
                    @"rect": [NSValue valueWithCGRect:r],
                }];
                if (visScore < bestVisDist) {
                    bestVisDist = visScore;
                    bestVisualView = cand;
                    bestVisualRect = r;
                }
            }
        }

        [rankedVisuals sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"score"] compare:b[@"score"]];
        }];
        NSMutableArray<NSDictionary *> *attemptVisuals = [NSMutableArray array];
        if (bestVisualView) {
            [attemptVisuals addObject:@{
                @"view": bestVisualView,
                @"rect": [NSValue valueWithCGRect:bestVisualRect],
            }];
        }
        for (NSDictionary *entry in rankedVisuals) {
            UIView *v = entry[@"view"];
            if (v && v != bestVisualView) {
                [attemptVisuals addObject:entry];
            }
        }
        if (bestControl && bestControl != bestVisualView && pt_viewHasOwnVisualDrawing(bestControl, 0)) {
            BOOL alreadyListed = NO;
            for (NSDictionary *entry in attemptVisuals) {
                if (entry[@"view"] == bestControl) {
                    alreadyListed = YES;
                    break;
                }
            }
            if (!alreadyListed) {
                CGRect cr = [bestControl convertRect:bestControl.bounds toView:tabBar];
                [attemptVisuals addObject:@{
                    @"view": bestControl,
                    @"rect": [NSValue valueWithCGRect:cr],
                }];
            }
        }

        BOOL slotUnknown = NO;
        PTDuoTabSlotOverlay *overlay = nil;
        UIView *fgTarget = bestControl ?: bestVisualView;
        UIImage *fgGlyph = nil;
        if (!bestImage && fgTarget && !tabBarAppWantsHidden && pt_viewAncestorsInsideBarAreAppVisible(fgTarget, tabBar)) {
            fgGlyph = pt_snapshotCompositeForegroundGlyphInControl(fgTarget);
        }
        if (fgGlyph) {
            overlay = pt_buildTabSlotOverlay(idx,
                                             tabBar,
                                             bestControl,
                                             bestTapGR,
                                             bestTapTarget,
                                             bestTapAction,
                                             fgGlyph,
                                             @"foregroundGlyph",
                                             fgTarget,
                                             [fgTarget convertRect:fgTarget.bounds toView:tabBar],
                                             cachedMap[@(idx)],
                                             tabBarAppWantsHidden,
                                             hasExistingProminentTab,
                                             isDarkMode,
                                             &slotUnknown);
        }
        if (!overlay) {
            if (attemptVisuals.count > 0 && !bestImage) {
                for (NSDictionary *entry in attemptVisuals) {
                    BOOL tryUnknown = NO;
                    UIView *tryView = entry[@"view"];
                    CGRect tryRect = [entry[@"rect"] CGRectValue];
                    overlay = pt_buildTabSlotOverlay(idx,
                                                     tabBar,
                                                     bestControl,
                                                     bestTapGR,
                                                     bestTapTarget,
                                                     bestTapAction,
                                                     nil,
                                                     nil,
                                                     tryView,
                                                     tryRect,
                                                     cachedMap[@(idx)],
                                                     tabBarAppWantsHidden,
                                                     hasExistingProminentTab,
                                                     isDarkMode,
                                                     &tryUnknown);
                    if (overlay) {
                        slotUnknown = NO;
                        break;
                    }
                    if (tryUnknown) {
                        slotUnknown = YES;
                    }
                }
            } else {
                overlay = pt_buildTabSlotOverlay(idx,
                                                 tabBar,
                                                 bestControl,
                                                 bestTapGR,
                                                 bestTapTarget,
                                                 bestTapAction,
                                                 bestImage,
                                                 bestImageSource,
                                                 bestVisualView,
                                                 bestVisualRect,
                                                 cachedMap[@(idx)],
                                                 tabBarAppWantsHidden,
                                                 hasExistingProminentTab,
                                                 isDarkMode,
                                                 &slotUnknown);
            }
        }
        if (slotUnknown) {
            foundUnknownActionable = YES;
            return;
        }
        if (overlay) {
            result[@(idx)] = overlay;
        }
    }];

    if (outHasUnknownActionableSlot) {
        *outHasUnknownActionableSlot = foundUnknownActionable;
    }

    UIWindow *win = tabBar.window ?: (tabVC.isViewLoaded ? tabVC.view.window : nil);
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(win, NO);
    if (insetState) {
        insetState.lastOverlayNodesScanned = nodesScanned;
        insetState.lastOverlayCandidatesScanned = (NSInteger)candidates.count;
        insetState.lastSlotCaptureDurationMs = (CACurrentMediaTime() - t0) * 1000.0;
    }

    if (result.count > 0) {
        objc_setAssociatedObject(tabBar, kPTDuoTabOverlayCacheKey, [result copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_signpost_interval_end(spLog, spId, "BlankSlotCapture", "found=%lu unknown=%d", (unsigned long)result.count, foundUnknownActionable ? 1 : 0);
    return result;
}

static PTDuoTabSlotOverlay *pt_discoverPureActionTabOverlay(UITabBarController *tabVC,
                                                            UITabBar *tabBar,
                                                            NSUInteger realSlotCount,
                                                            BOOL hasExistingProminentTab,
                                                            BOOL isDarkMode) {
    if (!tabBar || realSlotCount < 2) {
        return nil;
    }
    CGFloat tabBarWidth = CGRectGetWidth(tabBar.bounds);
    if (tabBarWidth <= 1.0 && tabVC && tabVC.isViewLoaded) {
        tabBarWidth = CGRectGetWidth(tabVC.view.bounds);
    }
    if (tabBarWidth <= 1.0) {
        return nil;
    }
    NSArray<NSNumber *> *tabBtnCenters = pt_collectVisibleSystemTabButtonCenters(tabBar, tabVC, NULL, NULL);
    if (tabBtnCenters.count < 2) {
        return nil;
    }
    BOOL isAlreadyRelocated = [objc_getAssociatedObject(tabBar, kPTDuoTabBarRelocatedKey) boolValue];
    NSNumber *appHiddenNum = objc_getAssociatedObject(tabBar, kPTDuoTabBarAppHiddenKey);
    BOOL tabBarAppWantsHidden = isAlreadyRelocated ? (appHiddenNum ? appHiddenNum.boolValue : NO) : tabBar.hidden;
    CGFloat maxAllowedWidth = MAX((tabBarWidth / (CGFloat)(realSlotCount + 1)) * 1.45, 96.0);
    NSArray<UIView *> *candidates = pt_collectAllTabBarCustomCandidates(tabVC, tabBar, maxAllowedWidth, tabBarWidth, isAlreadyRelocated, NULL);
    NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *cachedMap = objc_getAssociatedObject(tabBar, kPTDuoTabOverlayCacheKey);

    for (UIView *cand in candidates) {
        CGRect r = [cand convertRect:cand.bounds toView:tabBar];
        CGFloat midX = CGRectGetMidX(r);
        BOOL overlapsRealTabButton = NO;
        NSUInteger insertIdx = 0;
        for (NSNumber *btnMidNum in tabBtnCenters) {
            CGFloat btnMid = btnMidNum.doubleValue;
            if (fabs(midX - btnMid) < 20.0) {
                overlapsRealTabButton = YES;
                break;
            }
            if (btnMid < midX) {
                insertIdx++;
            }
        }
        if (overlapsRealTabButton) {
            continue;
        }
        UIControl *ctrl = [cand isKindOfClass:[UIControl class]] && ((UIControl *)cand).allTargets.count > 0
            ? (UIControl *)cand
            : pt_findActionControlInView(cand, 0);
        UITapGestureRecognizer *tapGR = nil;
        id tapTarget = nil;
        SEL tapAction = NULL;
        if (!ctrl) {
            pt_extractVerifiedTapGestureAction(cand, 0, &tapGR, &tapTarget, &tapAction);
        }
        if (!ctrl && !(tapTarget && tapAction != NULL)) {
            continue;
        }
        NSString *imgSrc = nil;
        UIImage *img = pt_findImageInViewHierarchyWithSource(cand, 0, &imgSrc);
        if (!img && !pt_viewHasOwnVisualDrawing(cand, 0)) {
            continue;
        }
        BOOL unknown = NO;
        PTDuoTabSlotOverlay *ov = pt_buildTabSlotOverlay(insertIdx,
                                                         tabBar,
                                                         ctrl,
                                                         tapGR,
                                                         tapTarget,
                                                         tapAction,
                                                         img,
                                                         imgSrc,
                                                         cand,
                                                         r,
                                                         cachedMap[@(1000 + insertIdx)],
                                                         tabBarAppWantsHidden,
                                                         hasExistingProminentTab,
                                                         isDarkMode,
                                                         &unknown);
        if (ov && !unknown) {
            NSMutableDictionary *updatedCache = cachedMap ? [cachedMap mutableCopy] : [NSMutableDictionary dictionary];
            updatedCache[@(1000 + insertIdx)] = ov;
            objc_setAssociatedObject(tabBar, kPTDuoTabOverlayCacheKey, [updatedCache copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return ov;
        }
    }
    return nil;
}

static NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *pt_discoverBlankSlotOverlays(
    UITabBarController *tabVC,
    UITabBar *tabBar,
    NSUInteger slotCount,
    BOOL (^slotIsBlank)(NSUInteger idx),
    BOOL hasExistingProminentTab) {
    BOOL isDark = (tabBar && tabBar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    return pt_discoverBlankSlotOverlaysWithOptions(tabVC, tabBar, slotCount, slotIsBlank, hasExistingProminentTab, isDark, NULL);
}

static NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *pt_discoverModernTabSlotOverlays(
    UITabBarController *tabVC,
    NSArray<id> *tabs,
    BOOL hasExistingProminentTab,
    BOOL isDarkMode,
    BOOL *outHasUnknownActionableSlot) {
    if (outHasUnknownActionableSlot) {
        *outHasUnknownActionableSlot = NO;
    }
    if (!tabVC || tabs.count < 2 || !tabVC.tabBar) {
        return @{};
    }
    id selectedTab = pt_tabBarControllerSelectedTab(tabVC);
    NSString *selectedId = pt_tabIdentifier(selectedTab);
    return pt_discoverBlankSlotOverlaysWithOptions(tabVC, tabVC.tabBar, tabs.count, ^BOOL(NSUInteger idx) {
        id tab = tabs[idx];
        if (!tab || pt_tabIsHidden(tab)) {
            return NO;
        }
        BOOL isSearch = pt_tabIsSearchTab(tab);
        if (isSearch) {
            return NO;
        }
        NSString *tid = pt_tabIdentifier(tab);
        BOOL isSel = (selectedTab == tab)
            || (selectedId.length > 0 && tid.length > 0 && [selectedId isEqualToString:tid]);
        UIImage *baseImg = pt_tabImage(tab);
        UIImage *selImg = pt_tabSelectedImage(tab);
        return PTDuoTabItemSlotNeedsOverlay(isSel,
                                            selImg != nil,
                                            pt_imageIsPlaceholderBlank(selImg),
                                            pt_imageIsPlaceholderBlank(baseImg),
                                            pt_stringIsEffectivelyBlank(pt_tabTitle(tab)));
    }, hasExistingProminentTab, isDarkMode, outHasUnknownActionableSlot);
}

static BOOL pt_collectModernTabsWithOptions(
    UITabBarController *tabVC,
    BOOL isDarkMode,
    NSArray<id> * __autoreleasing *outRegularTabs,
    id __autoreleasing *outProminentTab,
    NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> * __autoreleasing *outOverlayByTabIndex,
    PTDuoTabSlotOverlay * __autoreleasing *outProminentOverlay,
    BOOL *outHasUnknownActionableSlot) {
    if (outRegularTabs) { *outRegularTabs = @[]; }
    if (outProminentTab) { *outProminentTab = nil; }
    if (outOverlayByTabIndex) { *outOverlayByTabIndex = @{}; }
    if (outProminentOverlay) { *outProminentOverlay = nil; }
    if (outHasUnknownActionableSlot) { *outHasUnknownActionableSlot = NO; }
    if (!tabVC) {
        return NO;
    }
    NSArray<id> *tabs = pt_tabBarControllerTabs(tabVC);
    if (tabs.count < 2) {
        return NO;
    }

    NSString *prominentId = pt_tabBarControllerProminentTabIdentifier(tabVC);
    id prominentTab = nil;
    if (prominentId.length > 0) {
        for (id tab in tabs) {
            if (!tab || pt_tabIsHidden(tab)) { continue; }
            NSString *tid = pt_tabIdentifier(tab);
            if (tid.length > 0 && [tid isEqualToString:prominentId]) {
                prominentTab = tab;
                break;
            }
        }
    } else {
        for (id tab in tabs) {
            if (!tab || pt_tabIsHidden(tab)) { continue; }
            if (pt_tabIsSearchTab(tab) && pt_searchTabAutomaticallyActivatesSearch(tab)) {
                prominentTab = tab;
                break;
            }
        }
    }

    BOOL unknownActionable = NO;
    NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *slotOverlays =
        pt_discoverModernTabSlotOverlays(tabVC, tabs, (prominentTab != nil), isDarkMode, &unknownActionable);
    if (outHasUnknownActionableSlot) {
        *outHasUnknownActionableSlot = unknownActionable;
    }
    if (unknownActionable) {
        return NO;
    }

    NSMutableArray<id> *visibleTabs = [NSMutableArray arrayWithCapacity:tabs.count];
    NSMutableDictionary<NSNumber *, PTDuoTabSlotOverlay *> *overlayByRegularIdx = [NSMutableDictionary dictionary];
    PTDuoTabSlotOverlay *promotedOverlay = nil;

    for (NSUInteger i = 0; i < tabs.count; i++) {
        id tab = tabs[i];
        if (!tab || pt_tabIsHidden(tab)) {
            continue;
        }
        PTDuoTabSlotOverlay *ov = slotOverlays[@(i)];
        BOOL isSearch = pt_tabIsSearchTab(tab);
        BOOL hasVisual = (!pt_imageIsPlaceholderBlank(pt_tabImage(tab))
                          || !pt_imageIsPlaceholderBlank(pt_tabSelectedImage(tab))
                          || !pt_stringIsEffectivelyBlank(pt_tabTitle(tab))
                          || isSearch);
        if (!hasVisual && !ov) {
            continue;
        }
        if (!hasVisual && ov && ov.promoteToProminent && !prominentTab && !promotedOverlay) {
            promotedOverlay = ov;
            continue;
        }
        [visibleTabs addObject:tab];
    }
    if (!PTDuoCanSafelyRelocateTabDock(unknownActionable, visibleTabs.count)) {
        return NO;
    }

    NSMutableArray<id> *regularTabs = [NSMutableArray arrayWithCapacity:visibleTabs.count];
    for (id tab in visibleTabs) {
        if (tab == prominentTab) {
            continue;
        }
        NSUInteger origIdx = [tabs indexOfObjectIdenticalTo:tab];
        PTDuoTabSlotOverlay *ov = (origIdx != NSNotFound) ? slotOverlays[@(origIdx)] : nil;
        if (regularTabs.count < 6) {
            if (ov) {
                overlayByRegularIdx[@(regularTabs.count)] = ov;
            }
            [regularTabs addObject:tab];
        }
    }

    if (regularTabs.count == 0 && prominentTab == nil && promotedOverlay == nil) {
        return NO;
    }
    if (outRegularTabs) { *outRegularTabs = regularTabs; }
    if (outProminentTab) { *outProminentTab = prominentTab; }
    if (outOverlayByTabIndex) { *outOverlayByTabIndex = overlayByRegularIdx; }
    if (outProminentOverlay) { *outProminentOverlay = promotedOverlay; }
    return YES;
}

static BOOL pt_collectModernTabs(UITabBarController *tabVC,
                                 NSArray<id> * __autoreleasing *outRegularTabs,
                                 id __autoreleasing *outProminentTab,
                                 NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> * __autoreleasing *outOverlayByTabIndex,
                                 PTDuoTabSlotOverlay * __autoreleasing *outProminentOverlay) {
    BOOL isDark = (tabVC && tabVC.isViewLoaded && tabVC.view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    return pt_collectModernTabsWithOptions(tabVC, isDark, outRegularTabs, outProminentTab, outOverlayByTabIndex, outProminentOverlay, NULL);
}

// MARK: - Active Navigation & TabBar Discovery

static BOOL pt_navBarVisibleByApp(UINavigationController *nav);

static void pt_findActiveNavAndTabControllersEx(UIWindow *window,
                                                UINavigationController * __autoreleasing *outHeaderNav,
                                                UINavigationController * __autoreleasing *outToolbarNav,
                                                UITabBarController * __autoreleasing *outTab,
                                                UIViewController * __autoreleasing *outLeafVC) {
    if (outHeaderNav) { *outHeaderNav = nil; }
    if (outToolbarNav) { *outToolbarNav = nil; }
    if (outTab) { *outTab = nil; }
    if (outLeafVC) { *outLeafVC = nil; }
    UIViewController *root = window.rootViewController;
    if (!root) {
        return;
    }
    UIViewController *topRoot = pt_topPresentedFullscreenController(root, window.bounds);
    BOOL isModalPresented = (topRoot != root);

    UINavigationController *visibleHeaderNav = nil;
    UINavigationController *deepestNav = nil;
    UITabBarController *foundTab = nil;
    UIViewController *leafVC = topRoot;
    UIViewController *cursor = topRoot;
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];

    for (NSInteger depth = 0; depth < 16 && cursor != nil; depth++) {
        if ([visited containsObject:cursor]) {
            break;
        }
        [visited addObject:cursor];
        leafVC = cursor;

        if ([cursor isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)cursor;
            deepestNav = nav;
            if (pt_navBarVisibleByApp(nav) || !visibleHeaderNav) {
                if (!visibleHeaderNav || !PTDuoShouldPreserveOuterHeaderNav(pt_navBarVisibleByApp(visibleHeaderNav), pt_navBarVisibleByApp(nav))) {
                    visibleHeaderNav = nav;
                }
            }
            cursor = nav.topViewController;
        } else if ([cursor isKindOfClass:[UITabBarController class]]) {
            if (!isModalPresented) {
                foundTab = (UITabBarController *)cursor;
            }
            UIViewController *selectedChild = pt_selectedViewControllerForTabBarController((UITabBarController *)cursor);
            if (selectedChild && selectedChild.isViewLoaded
                && (selectedChild.view.hidden || selectedChild.view.alpha <= 0.05 || selectedChild.view.window == nil)) {
                UIViewController *visibleChild = pt_largestVisibleChildViewController(cursor, visited);
                if (visibleChild) {
                    selectedChild = visibleChild;
                }
            }
            cursor = selectedChild;
        } else if ([cursor isKindOfClass:[UISplitViewController class]]) {
            NSArray<UIViewController *> *vcs = ((UISplitViewController *)cursor).viewControllers;
            cursor = vcs.lastObject;
        } else {
            cursor = pt_largestVisibleChildViewController(cursor, visited);
        }
    }

    if (outHeaderNav) { *outHeaderNav = visibleHeaderNav ?: deepestNav; }
    if (outToolbarNav) { *outToolbarNav = deepestNav; }
    if (outTab) { *outTab = foundTab; }
    if (outLeafVC) { *outLeafVC = leafVC; }
}

static void pt_findActiveNavAndTabControllers(UIWindow *window,
                                              UINavigationController * __autoreleasing *outNav,
                                              UITabBarController * __autoreleasing *outTab,
                                              UIViewController * __autoreleasing *outLeafVC) {
    UINavigationController *headerNav = nil;
    UINavigationController *toolbarNav = nil;
    pt_findActiveNavAndTabControllersEx(window, &headerNav, &toolbarNav, outTab, outLeafVC);
    if (outNav) { *outNav = headerNav ?: toolbarNav; }
}

static BOOL pt_navBarVisibleByApp(UINavigationController *nav) {
    if (!nav || !nav.navigationBar || nav.isNavigationBarHidden) {
        return NO;
    }
    BOOL alreadySuppressed = [objc_getAssociatedObject(nav.navigationBar, kPTDuoNavBarSuppressedKey) boolValue];
    NSNumber *appHidden = objc_getAssociatedObject(nav.navigationBar, kPTDuoNavBarAppHiddenKey);
    BOOL appWantsHidden = alreadySuppressed ? (appHidden ? appHidden.boolValue : NO) : nav.navigationBar.hidden;
    return !appWantsHidden;
}

static BOOL pt_barItemAppWantsHidden(UIBarButtonItem *item) {
    if (!item) {
        return YES;
    }
    if ([objc_getAssociatedObject(item, kPTDuoBarItemSuppressedKey) boolValue]) {
        NSNumber *appHidden = objc_getAssociatedObject(item, kPTDuoBarItemAppHiddenKey);
        return appHidden ? appHidden.boolValue : NO;
    }
    if ([item respondsToSelector:@selector(isHidden)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isHidden));
    }
    return NO;
}

static BOOL pt_navItemHasVisibleLeadingItems(UINavigationItem *navItem) {
    if (!navItem) {
        return NO;
    }
    for (UIBarButtonItem *item in navItem.leftBarButtonItems) {
        if (item && !pt_barItemAppWantsHidden(item)
            && (item.customView != nil || item.image != nil || item.title.length > 0)) {
            return YES;
        }
    }
    SEL leadSel = sel_registerName("leadingItemGroups");
    if ([navItem respondsToSelector:leadSel]) {
        typedef NSArray *(*pt_groups_fn)(id, SEL);
        NSArray *groups = ((pt_groups_fn)objc_msgSend)(navItem, leadSel);
        for (id group in groups) {
            if ([group respondsToSelector:@selector(barButtonItems)]) {
                NSArray<UIBarButtonItem *> *items = [group performSelector:@selector(barButtonItems)];
                for (UIBarButtonItem *item in items) {
                    if (item && !pt_barItemAppWantsHidden(item)
                        && (item.customView != nil || item.image != nil || item.title.length > 0)) {
                        return YES;
                    }
                }
            }
        }
    }
    return NO;
}

static BOOL pt_navItemAppWantsHidesBackButton(UINavigationItem *navItem) {
    if (!navItem) {
        return YES;
    }
    BOOL explicitHides = NO;
    if ([objc_getAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey) boolValue]) {
        NSNumber *appHides = objc_getAssociatedObject(navItem, kPTDuoNavItemAppHidesBackKey);
        explicitHides = appHides ? appHides.boolValue : NO;
    } else {
        explicitHides = navItem.hidesBackButton;
    }
    // UIKit semantics: when leftItemsSupplementBackButton is NO (default), any visible
    // left/leading bar button item replaces the automatic system back button.
    return PTDuoNavItemEffectiveHidesBackButton(explicitHides,
                                                navItem.leftItemsSupplementBackButton,
                                                pt_navItemHasVisibleLeadingItems(navItem));
}

static NSInteger pt_barItemAxisBehavior(UIBarButtonItem *item) {
    if (!item) {
        return 0;
    }
    SEL axisSel = sel_registerName("axisBehavior");
    if ([item respondsToSelector:axisSel]) {
        return ((NSInteger (*)(id, SEL))objc_msgSend)(item, axisSel);
    }
    return 0;
}

static BOOL pt_barItemIsHorizontalOnly(UIBarButtonItem *item) {
    return pt_barItemAxisBehavior(item) == 1;
}

static BOOL pt_customViewAppWantsVisible(UIView *customView, CGSize *outSize) {
    if (outSize) { *outSize = CGSizeZero; }
    if (!customView) {
        return NO;
    }
    BOOL appHidden = NO;
    CGFloat appAlpha = customView.alpha;
    if ([objc_getAssociatedObject(customView, kPTDuoCustomViewSuppressedKey) boolValue]) {
        NSNumber *h = objc_getAssociatedObject(customView, kPTDuoCustomViewAppHiddenKey);
        NSNumber *a = objc_getAssociatedObject(customView, kPTDuoCustomViewAppAlphaKey);
        appHidden = h ? h.boolValue : NO;
        appAlpha = a ? a.doubleValue : 1.0;
    } else {
        appHidden = customView.hidden;
    }
    if (appHidden || !isfinite(appAlpha) || appAlpha <= 0.01) {
        return NO;
    }
    CGSize sz = customView.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) {
        sz = [customView sizeThatFits:CGSizeMake(120.0, 64.0)];
    }
    if (sz.width < 1.0 || sz.height < 1.0) {
        sz = [customView systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    }
    if (outSize) { *outSize = sz; }
    return YES;
}

static BOOL pt_canExecuteBarItem(UIBarButtonItem *item,
                                 NSString * __autoreleasing *outActionSource,
                                 UIControl * __autoreleasing *outControl,
                                 UITapGestureRecognizer * __autoreleasing *outTapGR,
                                 id __autoreleasing *outTapTarget,
                                 SEL *outTapAction) {
    if (outActionSource) { *outActionSource = nil; }
    if (outControl) { *outControl = nil; }
    if (outTapGR) { *outTapGR = nil; }
    if (outTapTarget) { *outTapTarget = nil; }
    if (outTapAction) { *outTapAction = NULL; }
    if (!item) {
        return NO;
    }
    if (@available(iOS 14.0, *)) {
        if (item.primaryAction != nil) {
            if (outActionSource) { *outActionSource = @"primaryAction"; }
            return YES;
        }
    }
    if (item.action != NULL) {
        if (outActionSource) { *outActionSource = @"targetAction"; }
        return YES;
    }
    if (@available(iOS 14.0, *)) {
        if (item.menu != nil) {
            if (outActionSource) { *outActionSource = @"menu"; }
            return YES;
        }
    }
    if (item.customView != nil) {
        UIControl *ctrl = pt_findActionControlInView(item.customView, 0);
        if (ctrl != nil) {
            if (outActionSource) { *outActionSource = @"control"; }
            if (outControl) { *outControl = ctrl; }
            return YES;
        }
        UITapGestureRecognizer *tapGR = nil;
        id tapTarget = nil;
        SEL tapAction = NULL;
        if (pt_extractVerifiedTapGestureAction(item.customView, 0, &tapGR, &tapTarget, &tapAction)) {
            if (outActionSource) { *outActionSource = @"tapGesture"; }
            if (outTapGR) { *outTapGR = tapGR; }
            if (outTapTarget) { *outTapTarget = tapTarget; }
            if (outTapAction) { *outTapAction = tapAction; }
            return YES;
        }
    }
    return NO;
}

static BOOL pt_customBarItemVisualAndActionable(UIBarButtonItem *item, CGSize *outSize) {
    if (!item || !item.customView) {
        return NO;
    }
    UIView *cv = item.customView;
    if (!pt_customViewAppWantsVisible(cv, outSize)) {
        return NO;
    }
    if (!pt_canExecuteBarItem(item, NULL, NULL, NULL, NULL, NULL)) {
        return NO;
    }
    BOOL hasVisual = (item.image != nil
                      || item.title.length > 0
                      || pt_findImageInViewHierarchy(cv, 0) != nil
                      || pt_findLabelTextInViewHierarchy(cv, 0).length > 0
                      || pt_viewHasOwnVisualDrawing(cv, 0));
    return hasVisual;
}

static BOOL pt_barItemIsVisibleActionable(UIBarButtonItem *item) {
    if (!item || pt_barItemAppWantsHidden(item)) {
        return NO;
    }
    if (item.customView != nil) {
        if (!pt_customViewAppWantsVisible(item.customView, NULL)) {
            return NO;
        }
        BOOL hasAction = pt_canExecuteBarItem(item, NULL, NULL, NULL, NULL, NULL);
        BOOL hasVisual = (item.image != nil
                          || !pt_stringIsEffectivelyBlank(item.title)
                          || pt_findImageInViewHierarchy(item.customView, 0) != nil
                          || !pt_stringIsEffectivelyBlank(pt_findLabelTextInViewHierarchy(item.customView, 0))
                          || pt_viewHasOwnVisualDrawing(item.customView, 0));
        if (!hasAction && !hasVisual) {
            // Inert layout spacer customView should never block Full suppression or mark unmirrored content.
            return NO;
        }
        return YES;
    }
    return (item.image != nil || item.title.length > 0)
        && (item.action != NULL || item.primaryAction != nil || item.menu != nil);
}

static BOOL pt_navBarHasHorizontalOnlyHeaderChrome(UINavigationItem *topItem) {
    if (!topItem) {
        return NO;
    }
    NSString *trimmedTitle = [topItem.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedTitle.length > 0) {
        return YES;
    }
    NSString *trimmedPrompt = [topItem.prompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedPrompt.length > 0) {
        return YES;
    }
    UIView *tv = topItem.titleView;
    if (PTDuoViewIsVisualTitleView(tv != nil, tv.hidden, tv.alpha, tv ? tv.bounds : CGRectZero, tv ? tv.subviews.count : 0)) {
        return YES;
    }
    if (topItem.searchController != nil) {
        return YES;
    }
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in topItem.centerItemGroups) {
            if (group.hidden) { continue; }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (pt_barItemIsVisibleActionable(item)) {
                    return YES;
                }
            }
        }
    }
    // Check if any visible trailing/right or explicit HorizontalOnly/non-relocatable leading item remains on horizontal bar.
    BOOL (^isNonRelocatableItem)(UIBarButtonItem *, BOOL) = ^BOOL(UIBarButtonItem *item, BOOL isLeading) {
        if (!pt_barItemIsVisibleActionable(item)) {
            return NO;
        }
        if (pt_barItemIsHorizontalOnly(item)) {
            return YES;
        }
        if (item.customView != nil) {
            CGSize sz = CGSizeZero;
            BOOL ok = pt_customBarItemVisualAndActionable(item, &sz);
            if (!ok || sz.width > 84.0 || sz.height > 64.0) {
                return YES;
            }
        }
        if (isLeading && pt_barItemAxisBehavior(item) != 2) {
            // Standard/automatic leading item does not force header visible on its own if nothing else is horizontal-only.
            return NO;
        }
        return NO;
    };
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in topItem.leadingItemGroups) {
            if (group.hidden) { continue; }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (isNonRelocatableItem(item, YES)) { return YES; }
            }
        }
        for (UIBarButtonItemGroup *group in topItem.trailingItemGroups) {
            if (group.hidden) { continue; }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (isNonRelocatableItem(item, NO)) { return YES; }
            }
        }
    }
    for (UIBarButtonItem *item in topItem.leftBarButtonItems) {
        if (isNonRelocatableItem(item, YES)) { return YES; }
    }
    for (UIBarButtonItem *item in topItem.rightBarButtonItems) {
        if (isNonRelocatableItem(item, NO)) { return YES; }
    }
    return NO;
}

static BOOL pt_barItemCanRelocateToVerticalRailWithShowBack(UIBarButtonItem *item,
                                                            BOOL isLeading,
                                                            BOOL navBarHasHorizontalOnlyChrome,
                                                            BOOL showBack) {
    if (!item) {
        return NO;
    }
    BOOL appHidden = pt_barItemAppWantsHidden(item);
    NSInteger axis = pt_barItemAxisBehavior(item);
    BOOL stdOK = (item.customView == nil)
        && (item.image != nil || item.title.length > 0)
        && (item.action != NULL || item.primaryAction != nil || item.menu != nil);
    BOOL isIconOnlyStandard = PTDuoIsStandardIconOnlyBarItem(item.customView != nil, item.image != nil);
    CGSize cvSize = CGSizeZero;
    BOOL cvOK = (item.customView != nil) ? pt_customBarItemVisualAndActionable(item, &cvSize) : NO;
    return PTDuoShouldRelocateLeadingBarItemWithRole(appHidden,
                                                      axis,
                                                      stdOK,
                                                      isIconOnlyStandard,
                                                      item.customView != nil,
                                                      cvSize,
                                                      cvOK,
                                                      isLeading,
                                                      navBarHasHorizontalOnlyChrome,
                                                      showBack);
}

static BOOL pt_barItemCanRelocateToVerticalRail(UIBarButtonItem *item,
                                                BOOL isLeading,
                                                BOOL navBarHasHorizontalOnlyChrome) {
    return pt_barItemCanRelocateToVerticalRailWithShowBack(item, isLeading, navBarHasHorizontalOnlyChrome, YES);
}

static void pt_collectFloatingChromeLeafControlsInNode(UIView *node,
                                                       NSInteger depth,
                                                       NSMutableArray<UIView *> *outViews);

static void pt_collectFloatingToolbarChromeInView(UIView *node,
                                                  UIView *rootView,
                                                  UIView *contentView,
                                                  UIView *navBar,
                                                  UIToolbar *navToolbar,
                                                  NSInteger depth,
                                                  NSMutableArray<UIView *> *outViews) {
    if (!node || depth > 8 || node == contentView || node == navBar) {
        return;
    }
    if (contentView && pt_isDescendantOrSameView(contentView, node)) {
        for (UIView *sub in node.subviews) {
            pt_collectFloatingToolbarChromeInView(sub, rootView, contentView, navBar, navToolbar, depth + 1, outViews);
        }
        return;
    }
    if (depth > 0) {
        NSString *clsName = NSStringFromClass([node class]);
        if ([clsName isEqualToString:@"UINavigationTransitionView"]
            || [clsName isEqualToString:@"UIViewControllerWrapperView"]
            || [clsName isEqualToString:@"PTDuoVerticalBarHostView"]) {
            return;
        }
        BOOL isFloatingContainer = [clsName containsString:@"_UIFloatingBarContainerView"]
            || [clsName containsString:@"FloatingBarHostingView"];
        BOOL isFloatingToolbarChrome = isFloatingContainer
            || [clsName containsString:@"_UIToolbarPlatterView"]
            || [clsName containsString:@"_UIToolbarContentView"]
            || ([node isKindOfClass:[UIToolbar class]] && node != navToolbar);
        if (isFloatingToolbarChrome) {
            if (![outViews containsObject:node]) {
                [outViews addObject:node];
            }
            if (isFloatingContainer) {
                for (UIView *sub in node.subviews) {
                    pt_collectFloatingToolbarChromeInView(sub, rootView, contentView, navBar, navToolbar, depth + 1, outViews);
                }
            }
            return;
        }
    }
    for (UIView *sub in node.subviews) {
        pt_collectFloatingToolbarChromeInView(sub, rootView, contentView, navBar, navToolbar, depth + 1, outViews);
    }
}

static NSArray<UIView *> *pt_collectFloatingToolbarChromeViews(UINavigationController *nav) {
    if (!nav || !nav.isViewLoaded) {
        return @[];
    }
    UIView *rootView = nav.view;
    UIView *contentView = (nav.topViewController && nav.topViewController.isViewLoaded) ? nav.topViewController.view : nil;
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    pt_collectFloatingToolbarChromeInView(rootView, rootView, contentView, nav.navigationBar, nav.toolbar, 0, result);
    return result;
}

static BOOL pt_anyFloatingChromeAppVisible(NSArray<UIView *> *views) {
    for (UIView *v in views) {
        if ([objc_getAssociatedObject(v, kPTDuoTabChromeRelocatedKey) boolValue]) {
            NSNumber *appHidden = objc_getAssociatedObject(v, kPTDuoTabChromeAppHiddenKey);
            NSNumber *appAlpha = objc_getAssociatedObject(v, kPTDuoTabChromeAppAlphaKey);
            BOOL hidden = appHidden ? appHidden.boolValue : NO;
            CGFloat alpha = appAlpha ? appAlpha.doubleValue : 1.0;
            if (!hidden && alpha > 0.01) {
                return YES;
            }
        } else if (!v.hidden && v.alpha > 0.01) {
            return YES;
        }
    }
    return NO;
}

static void pt_setToolbarVisualSuppressed(UINavigationController *nav, BOOL suppress) {
    if (!nav) {
        return;
    }
    UIToolbar *toolbar = nav.toolbar;
    if (!toolbar) {
        return;
    }
    PTDuoNavBarSuppressionMode prevMode = (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey) integerValue];
    BOOL wasSuppressed = (prevMode == PTDuoNavBarSuppressionFull);

    if (suppress) {
        objc_setAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey, @(PTDuoNavBarSuppressionFull), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalToolbarVisualDepth++;
        @try {
            pt_applySavedVisualSuppression(toolbar,
                                           YES,
                                           NO,
                                           kPTDuoToolbarSuppressedKey,
                                           kPTDuoToolbarAppHiddenKey,
                                           kPTDuoToolbarAppAlphaKey,
                                           kPTDuoToolbarAppInteractKey);
        } @finally {
            pt_duoInternalToolbarVisualDepth--;
        }
    } else if ([objc_getAssociatedObject(toolbar, kPTDuoToolbarSuppressedKey) boolValue] || wasSuppressed) {
        objc_setAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey, @(PTDuoNavBarSuppressionNone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalToolbarVisualDepth++;
        @try {
            pt_applySavedVisualSuppression(toolbar,
                                           NO,
                                           wasSuppressed,
                                           kPTDuoToolbarSuppressedKey,
                                           kPTDuoToolbarAppHiddenKey,
                                           kPTDuoToolbarAppAlphaKey,
                                           kPTDuoToolbarAppInteractKey);
        } @finally {
            pt_duoInternalToolbarVisualDepth--;
        }
    }

    if (wasSuppressed != suppress) {
        SEL eagerSel = sel_registerName("_eagerlyUpdateSafeAreaInsets");
        if ([nav respondsToSelector:eagerSel]) {
            ((void (*)(id, SEL))objc_msgSend)(nav, eagerSel);
        }
        [nav.view setNeedsLayout];
        [nav.topViewController.viewIfLoaded setNeedsLayout];
    }
}

static void pt_setNavBarVisualSuppressed(UINavigationController *nav, BOOL suppress) {
    if (!nav) {
        return;
    }
    UINavigationBar *navBar = nav.navigationBar;
    if (!navBar) {
        return;
    }
    PTDuoNavBarSuppressionMode prevMode = (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoNavControllerSuppressionKey) integerValue];
    BOOL wasSuppressed = (prevMode == PTDuoNavBarSuppressionFull);

    if (suppress) {
        objc_setAssociatedObject(nav, kPTDuoNavControllerSuppressionKey, @(PTDuoNavBarSuppressionFull), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalNavBarVisualDepth++;
        @try {
            pt_applySavedVisualSuppression(navBar,
                                           YES,
                                           NO,
                                           kPTDuoNavBarSuppressedKey,
                                           kPTDuoNavBarAppHiddenKey,
                                           kPTDuoNavBarAppAlphaKey,
                                           kPTDuoNavBarAppInteractKey);
        } @finally {
            pt_duoInternalNavBarVisualDepth--;
        }
    } else if ([objc_getAssociatedObject(navBar, kPTDuoNavBarSuppressedKey) boolValue] || wasSuppressed) {
        objc_setAssociatedObject(nav, kPTDuoNavControllerSuppressionKey, @(PTDuoNavBarSuppressionNone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalNavBarVisualDepth++;
        @try {
            pt_applySavedVisualSuppression(navBar,
                                           NO,
                                           wasSuppressed,
                                           kPTDuoNavBarSuppressedKey,
                                           kPTDuoNavBarAppHiddenKey,
                                           kPTDuoNavBarAppAlphaKey,
                                           kPTDuoNavBarAppInteractKey);
        } @finally {
            pt_duoInternalNavBarVisualDepth--;
        }
    }

    if (wasSuppressed != suppress) {
        SEL eagerSel = sel_registerName("_eagerlyUpdateSafeAreaInsets");
        if ([nav respondsToSelector:eagerSel]) {
            ((void (*)(id, SEL))objc_msgSend)(nav, eagerSel);
        }
        [nav.view setNeedsLayout];
        [nav.topViewController.viewIfLoaded setNeedsLayout];
    }
}

static void pt_setCustomViewHorizontalSuppressed(UIView *customView, BOOL suppress) {
    if (!customView) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(customView, kPTDuoCustomViewSuppressedKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            objc_setAssociatedObject(customView, kPTDuoCustomViewAppHiddenKey, @(customView.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(customView, kPTDuoCustomViewAppAlphaKey, @(customView.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(customView, kPTDuoCustomViewAppInteractKey, @(customView.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(customView, kPTDuoCustomViewSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // Visual-only suppression keeps customView.window != nil so app stale-item watchdogs never rebuild-loop.
        if (!customView.hidden) {
            customView.hidden = YES;
        }
        if (customView.alpha > 0.0) {
            customView.alpha = 0.0;
        }
        if (customView.userInteractionEnabled) {
            customView.userInteractionEnabled = NO;
        }
    } else if (currentlySuppressed) {
        NSNumber *appHidden = objc_getAssociatedObject(customView, kPTDuoCustomViewAppHiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(customView, kPTDuoCustomViewAppAlphaKey);
        NSNumber *appInteract = objc_getAssociatedObject(customView, kPTDuoCustomViewAppInteractKey);
        objc_setAssociatedObject(customView, kPTDuoCustomViewSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        customView.hidden = appHidden ? appHidden.boolValue : NO;
        customView.alpha = appAlpha ? appAlpha.doubleValue : 1.0;
        customView.userInteractionEnabled = appInteract ? appInteract.boolValue : YES;
    }
}

static void pt_setBarItemHorizontalSuppressed(UIBarButtonItem *item, BOOL suppress) {
    if (!item || ![item respondsToSelector:@selector(setHidden:)] || ![item respondsToSelector:@selector(isHidden)]) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(item, kPTDuoBarItemSuppressedKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            BOOL origHidden = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isHidden));
            objc_setAssociatedObject(item, kPTDuoBarItemAppHiddenKey, @(origHidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(item, kPTDuoBarItemSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_duoInternalBarItemHiddenDepth++;
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setHidden:), YES);
        } @finally {
            pt_duoInternalBarItemHiddenDepth--;
        }
    } else if (currentlySuppressed) {
        NSNumber *origHidden = objc_getAssociatedObject(item, kPTDuoBarItemAppHiddenKey);
        objc_setAssociatedObject(item, kPTDuoBarItemSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalBarItemHiddenDepth++;
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setHidden:), origHidden ? origHidden.boolValue : NO);
        } @finally {
            pt_duoInternalBarItemHiddenDepth--;
        }
    }
}

static void pt_setNavItemBackButtonSuppressed(UINavigationItem *navItem, BOOL suppress) {
    if (!navItem) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            objc_setAssociatedObject(navItem, kPTDuoNavItemAppHidesBackKey, @(navItem.hidesBackButton), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_duoInternalNavItemBackDepth++;
        @try {
            if (!navItem.hidesBackButton) {
                [navItem setHidesBackButton:YES animated:NO];
            }
        } @finally {
            pt_duoInternalNavItemBackDepth--;
        }
    } else if (currentlySuppressed) {
        NSNumber *origHides = objc_getAssociatedObject(navItem, kPTDuoNavItemAppHidesBackKey);
        objc_setAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalNavItemBackDepth++;
        @try {
            [navItem setHidesBackButton:(origHides ? origHides.boolValue : NO) animated:NO];
        } @finally {
            pt_duoInternalNavItemBackDepth--;
        }
    }
}

@interface PTDuoBarItemEntry : NSObject
@property (nonatomic, strong) UIBarButtonItem *item;
@property (nonatomic, copy) NSString *bucket;
@property (nonatomic, copy) NSString *sourceClass;
@property (nonatomic, assign) NSInteger axisBehavior;
@property (nonatomic, copy) NSString *visualSource;
@property (nonatomic, copy) NSString *actionSource;
@property (nonatomic, strong) UIImage *resolvedImage;
@property (nonatomic, copy) NSString *resolvedTitle;
@property (nonatomic, copy) NSString *badgeText;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, assign) BOOL relocated;
@property (nonatomic, copy) NSString *rejectedReason;
@property (nonatomic, weak) UIControl *actionControl;
@property (nonatomic, weak) UITapGestureRecognizer *tapGesture;
@property (nonatomic, weak) id tapTarget;
@property (nonatomic, assign) SEL tapAction;
@property (nonatomic, assign) double snapshotOpaqueRatio;
@property (nonatomic, assign) double snapshotMinLuma;
@property (nonatomic, assign) double snapshotMaxLuma;
@property (nonatomic, assign) BOOL isOverflowMenu;
@property (nonatomic, strong) NSArray<PTDuoBarItemEntry *> *overflowSubEntries;
@end

@implementation PTDuoBarItemEntry
@end

@interface PTDuoBarItemPlan : NSObject
@property (nonatomic, strong) NSArray<PTDuoBarItemEntry *> *leadingEntries;
@property (nonatomic, strong) NSArray<PTDuoBarItemEntry *> *navBarEntries;
@property (nonatomic, strong) NSArray<PTDuoBarItemEntry *> *toolbarEntries;
@property (nonatomic, strong) NSArray<UIBarButtonItem *> *mirroredLeadingItems;
@property (nonatomic, strong) NSArray<UIBarButtonItem *> *mirroredNavBarItems;
@property (nonatomic, strong) NSArray<UIBarButtonItem *> *mirroredToolbarItems;
@property (nonatomic, strong) NSArray<PTDuoBarItemEntry *> *allCandidateEntries;
@property (nonatomic, assign) BOOL hasUnmirroredNavBarItems;
@property (nonatomic, assign) BOOL hasUnmirroredToolbarItems;
@end

@implementation PTDuoBarItemPlan
@end

static NSString *pt_findShortBadgeTextInView(UIView *node, NSInteger depth) {
    if (!node || depth > 4 || !pt_viewNodeIsVisuallyActive(node, depth)) {
        return nil;
    }
    if ([node isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)node;
        NSString *t = [lbl.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length >= 1 && t.length <= 3
            && CGRectGetWidth(lbl.bounds) <= 30.0 && CGRectGetHeight(lbl.bounds) <= 24.0) {
            return t;
        }
    }
    for (UIView *sub in node.subviews) {
        NSString *found = pt_findShortBadgeTextInView(sub, depth + 1);
        if (found.length > 0) {
            return found;
        }
    }
    return nil;
}

static UIView *pt_horizontalSuppressedViewForCustomBarItemView(UIView *customView) {
    if (!customView) {
        return nil;
    }
    UIView *target = customView;
    for (NSInteger hop = 0; hop < 6; hop++) {
        UIView *parent = target.superview;
        if (!parent
            || [parent isKindOfClass:[UINavigationBar class]]
            || [parent isKindOfClass:[UIToolbar class]]
            || [parent isKindOfClass:[UIWindow class]]) {
            break;
        }
        if (CGRectGetWidth(parent.bounds) > 84.0 || CGRectGetHeight(parent.bounds) > 72.0) {
            break;
        }
        NSString *clsName = NSStringFromClass([parent class]);
        BOOL isContainerBar = ([clsName isEqualToString:@"_UINavigationBarContentView"]
                               || [clsName isEqualToString:@"_UIButtonBarStackView"]
                               || [clsName isEqualToString:@"_UIToolbarContentView"]
                               || ([clsName containsString:@"NavigationButtonBar"] && ![clsName containsString:@"ItemWrapperView"]));
        if (isContainerBar) {
            break;
        }
        BOOL hasSiblingInteractive = NO;
        for (UIView *sub in parent.subviews) {
            if (sub == target || sub.hidden || sub.alpha <= 0.01) {
                continue;
            }
            if ([sub isKindOfClass:[UIControl class]] || pt_findActionControlInView(sub, 0) != nil) {
                hasSiblingInteractive = YES;
                break;
            }
        }
        if (hasSiblingInteractive) {
            break;
        }
        BOOL isWrapperClass = ([clsName containsString:@"_UIButtonBarButton"]
                               || [clsName containsString:@"ItemWrapperView"]
                               || [clsName containsString:@"PlatterRepresentable"]
                               || [clsName containsString:@"_UIInheritedView"]
                               || [clsName containsString:@"Platter"]
                               || parent.subviews.count == 1);
        if (!isWrapperClass) {
            break;
        }
        target = parent;
    }
    return target;
}

static BOOL pt_barItemIsSelected(UIBarButtonItem *item, UIControl *ctrl) {
    if (item && [item respondsToSelector:@selector(isSelected)]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isSelected))) {
            return YES;
        }
    }
    if (ctrl && ctrl.selected) {
        return YES;
    }
    return NO;
}

static BOOL pt_executeBarItemEntry(PTDuoBarItemEntry *entry, UIWindow *hostWindow) {
    if (!entry || entry.isOverflowMenu) {
        return NO;
    }
    UIBarButtonItem *item = entry.item;
    if (!item || !item.enabled) {
        return NO;
    }
    if (@available(iOS 14.0, *)) {
        if (item.primaryAction) {
            SEL performSel = sel_registerName("performWithSender:target:");
            if ([item.primaryAction respondsToSelector:performSel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(item.primaryAction, performSel, item, nil);
                pt_scheduleRefreshForWindow(hostWindow);
                return YES;
            }
        }
    }
    if (item.action != NULL) {
        [[UIApplication sharedApplication] sendAction:item.action to:item.target from:item forEvent:nil];
        pt_scheduleRefreshForWindow(hostWindow);
        return YES;
    }
    if (item.customView) {
        UIControl *ctrl = entry.actionControl ?: pt_findActionControlInView(item.customView, 0);
        if (ctrl) {
            pt_triggerControlAction(ctrl);
            pt_scheduleRefreshForWindow(hostWindow);
            return YES;
        }
        UITapGestureRecognizer *tapGR = entry.tapGesture;
        id tapTarget = entry.tapTarget;
        SEL tapAction = entry.tapAction;
        if (!tapTarget || tapAction == NULL) {
            pt_extractVerifiedTapGestureAction(item.customView, 0, &tapGR, &tapTarget, &tapAction);
        }
        if (pt_dispatchVerifiedTapAction(tapGR, tapTarget, tapAction)) {
            pt_scheduleRefreshForWindow(hostWindow);
            return YES;
        }
    }
    return NO;
}

static NSString *pt_describeRejectionForBarItem(UIBarButtonItem *item, BOOL isLeading, BOOL navBarHorizHeader) {
    if (pt_barItemAppWantsHidden(item)) { return @"appHidden"; }
    if (pt_barItemIsHorizontalOnly(item)) { return @"horizontalOnly"; }
    if (item.customView != nil) {
        CGSize sz = CGSizeZero;
        if (!pt_customViewAppWantsVisible(item.customView, &sz)) { return @"customViewHidden"; }
        if (sz.width > 84.0 || sz.height > 64.0) { return @"customViewOversized"; }
        if (!pt_canExecuteBarItem(item, NULL, NULL, NULL, NULL, NULL)) { return @"nonDispatchableAction"; }
        return @"noCustomVisual";
    }
    if (item.image == nil && item.title.length == 0) { return @"noVisual"; }
    if (!pt_canExecuteBarItem(item, NULL, NULL, NULL, NULL, NULL)) { return @"nonDispatchableAction"; }
    if (isLeading && navBarHorizHeader && pt_barItemAxisBehavior(item) != 2) { return @"leadingDeferredToHorizontalHeader"; }
    return @"excluded";
}

static void pt_finalizeBucketEntries(NSMutableArray<PTDuoBarItemEntry *> *eligibleEntries,
                                     NSUInteger bucketCap,
                                     NSString *bucketName,
                                     NSMutableArray<PTDuoBarItemEntry *> *outRenderEntries,
                                     NSMutableArray<UIBarButtonItem *> *outMirroredItems,
                                     BOOL *outHasUnmirrored) {
    NSUInteger directCount = 0;
    BOOL needsOverflow = NO;
    PTDuoComputeOverflowSplit(eligibleEntries.count, bucketCap, &directCount, &needsOverflow);
    for (NSUInteger i = 0; i < directCount && i < eligibleEntries.count; i++) {
        PTDuoBarItemEntry *entry = eligibleEntries[i];
        entry.relocated = YES;
        [outRenderEntries addObject:entry];
        if (entry.item) {
            [outMirroredItems addObject:entry.item];
        }
    }
    if (needsOverflow && eligibleEntries.count > directCount) {
        NSMutableArray<PTDuoBarItemEntry *> *overflowSub = [NSMutableArray array];
        for (NSUInteger i = directCount; i < eligibleEntries.count; i++) {
            PTDuoBarItemEntry *sub = eligibleEntries[i];
            if (@available(iOS 14.0, *)) {
                sub.relocated = YES;
                [overflowSub addObject:sub];
                if (sub.item) {
                    [outMirroredItems addObject:sub.item];
                }
            } else {
                sub.relocated = NO;
                sub.rejectedReason = @"overflowUnavailable";
                if (outHasUnmirrored) { *outHasUnmirrored = YES; }
            }
        }
        if (overflowSub.count > 0) {
            PTDuoBarItemEntry *overflowEntry = [[PTDuoBarItemEntry alloc] init];
            overflowEntry.bucket = bucketName;
            overflowEntry.sourceClass = @"OverflowMenu";
            overflowEntry.visualSource = @"overflowMenu";
            overflowEntry.actionSource = @"overflowMenu";
            overflowEntry.resolvedTitle = @"More";
            overflowEntry.enabled = YES;
            overflowEntry.relocated = YES;
            overflowEntry.isOverflowMenu = YES;
            overflowEntry.overflowSubEntries = [overflowSub copy];
            [outRenderEntries addObject:overflowEntry];
        }
    }
}

static PTDuoBarItemPlan *pt_buildVerticalBarItemPlanForNavs(UINavigationController *headerNav,
                                                            UINavigationController *toolbarNav,
                                                            BOOL showBack) {
    PTDuoBarItemPlan *plan = [[PTDuoBarItemPlan alloc] init];
    plan.leadingEntries = @[];
    plan.navBarEntries = @[];
    plan.toolbarEntries = @[];
    plan.mirroredLeadingItems = @[];
    plan.mirroredNavBarItems = @[];
    plan.mirroredToolbarItems = @[];
    plan.allCandidateEntries = @[];
    if (!headerNav && !toolbarNav) {
        return plan;
    }

    UIViewController *headerTopVC = headerNav ? headerNav.topViewController : nil;
    UINavigationItem *topItem = headerTopVC ? (headerTopVC.navigationItem ?: headerNav.navigationBar.topItem) : nil;
    BOOL navBarHorizHeader = pt_navBarHasHorizontalOnlyHeaderChrome(topItem);
    UIViewController *toolbarTopVC = toolbarNav ? toolbarNav.topViewController : headerTopVC;
    NSHashTable<UIBarButtonItem *> *seen = [NSHashTable weakObjectsHashTable];
    NSMutableArray<PTDuoBarItemEntry *> *allCandidates = [NSMutableArray array];
    NSMutableArray<PTDuoBarItemEntry *> *eligibleLeading = [NSMutableArray array];
    NSMutableArray<PTDuoBarItemEntry *> *eligibleNav = [NSMutableArray array];
    NSMutableArray<PTDuoBarItemEntry *> *eligibleTool = [NSMutableArray array];
    __block BOOL unmirroredNav = NO;
    __block BOOL unmirroredTool = NO;

    void (^processItem)(UIBarButtonItem *, NSMutableArray<PTDuoBarItemEntry *> *, NSString *, BOOL, BOOL) =
    ^(UIBarButtonItem *item, NSMutableArray<PTDuoBarItemEntry *> *bucket, NSString *bucketName, BOOL isLeading, BOOL isToolbar) {
        if (!item || [seen containsObject:item]) {
            return;
        }
        [seen addObject:item];

        BOOL visibleActionable = pt_barItemIsVisibleActionable(item);
        BOOL canRelocate = pt_barItemCanRelocateToVerticalRailWithShowBack(item, isLeading, navBarHorizHeader, showBack);

        NSString *actionSrc = nil;
        UIControl *ctrl = nil;
        UITapGestureRecognizer *tapGR = nil;
        id tapTarget = nil;
        SEL tapAction = NULL;
        pt_canExecuteBarItem(item, &actionSrc, &ctrl, &tapGR, &tapTarget, &tapAction);

        NSString *visualSrc = nil;
        UIImage *img = item.image;
        if (img) {
            visualSrc = @"image";
        } else if (item.customView) {
            img = pt_findImageInViewHierarchyWithSource(item.customView, 0, &visualSrc);
        }
        NSString *title = item.title;
        if (title.length == 0 && item.customView) {
            title = pt_findLabelTextInViewHierarchy(item.customView, 0);
        }
        double snapOpaque = 0.0, snapMinLuma = 0.0, snapMaxLuma = 0.0;
        if (!img && pt_stringIsEffectivelyBlank(title) && item.customView && canRelocate) {
            img = pt_snapshotViewForVerticalBarWithStats(item.customView, &snapOpaque, &snapMinLuma, &snapMaxLuma);
            if (img) {
                visualSrc = @"customSnapshot";
                objc_setAssociatedObject(item, kPTDuoBarItemCachedSnapshotKey, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                UIImage *cachedSnap = objc_getAssociatedObject(item, kPTDuoBarItemCachedSnapshotKey);
                if (cachedSnap && [objc_getAssociatedObject(item, kPTDuoBarItemSuppressedKey) boolValue]) {
                    img = cachedSnap;
                    visualSrc = @"customSnapshot";
                } else {
                    canRelocate = NO;
                }
            }
        }
        if (!visualSrc) {
            if (title.length > 0) {
                visualSrc = @"title";
            } else if (item.customView) {
                visualSrc = @"noCustomVisual";
            }
        }

        PTDuoBarItemEntry *entry = [[PTDuoBarItemEntry alloc] init];
        entry.item = item;
        entry.bucket = bucketName;
        entry.sourceClass = item.customView ? NSStringFromClass([item.customView class]) : NSStringFromClass([item class]);
        entry.axisBehavior = pt_barItemAxisBehavior(item);
        entry.visualSource = visualSrc;
        entry.actionSource = actionSrc;
        entry.resolvedImage = img;
        entry.resolvedTitle = title;
        if (item.customView) {
            entry.badgeText = pt_findShortBadgeTextInView(item.customView, 0);
        }
        entry.snapshotOpaqueRatio = snapOpaque;
        entry.snapshotMinLuma = snapMinLuma;
        entry.snapshotMaxLuma = snapMaxLuma;
        entry.enabled = ctrl ? (item.enabled && ctrl.enabled) : item.enabled;
        entry.selected = pt_barItemIsSelected(item, ctrl);
        entry.actionControl = ctrl;
        entry.tapGesture = tapGR;
        entry.tapTarget = tapTarget;
        entry.tapAction = tapAction;

        if (allCandidates.count < 24) {
            [allCandidates addObject:entry];
        }

        if (canRelocate) {
            [bucket addObject:entry];
        } else if (visibleActionable) {
            entry.rejectedReason = (!img && pt_stringIsEffectivelyBlank(title) && item.customView)
                ? @"emptySnapshot"
                : pt_describeRejectionForBarItem(item, isLeading, navBarHorizHeader);
            if (isToolbar) {
                unmirroredTool = YES;
            } else {
                unmirroredNav = YES;
            }
        } else {
            entry.rejectedReason = @"inertSpacer";
        }
    };

    if (headerNav && pt_navBarVisibleByApp(headerNav) && topItem) {
        if (@available(iOS 16.0, *)) {
            for (UIBarButtonItemGroup *group in topItem.leadingItemGroups) {
                if (group.hidden) { continue; }
                for (UIBarButtonItem *item in group.barButtonItems) {
                    processItem(item, eligibleLeading, @"leading", YES, NO);
                }
            }
        }
        for (UIBarButtonItem *item in topItem.leftBarButtonItems) {
            processItem(item, eligibleLeading, @"leading", YES, NO);
        }
        if (@available(iOS 16.0, *)) {
            for (UIBarButtonItemGroup *group in topItem.trailingItemGroups) {
                if (group.hidden) { continue; }
                for (UIBarButtonItem *item in group.barButtonItems) {
                    processItem(item, eligibleNav, @"navBar", NO, NO);
                }
            }
        }
        for (UIBarButtonItem *item in topItem.rightBarButtonItems) {
            processItem(item, eligibleNav, @"navBar", NO, NO);
        }
    }

    UINavigationController *effToolbarNav = toolbarNav ?: headerNav;
    if (toolbarTopVC && toolbarTopVC.toolbarItems.count > 0) {
        for (UIBarButtonItem *item in toolbarTopVC.toolbarItems) {
            BOOL verticalPreferred = (pt_barItemAxisBehavior(item) == 2);
            if (!effToolbarNav || !effToolbarNav.isToolbarHidden || verticalPreferred) {
                processItem(item, eligibleTool, @"toolbar", NO, YES);
            }
        }
    }

    NSMutableArray<PTDuoBarItemEntry *> *leadingEntries = [NSMutableArray array];
    NSMutableArray<PTDuoBarItemEntry *> *navEntries = [NSMutableArray array];
    NSMutableArray<PTDuoBarItemEntry *> *toolEntries = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *mirroredLeading = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *mirroredNav = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *mirroredTool = [NSMutableArray array];

    pt_finalizeBucketEntries(eligibleLeading, 4, @"leading", leadingEntries, mirroredLeading, &unmirroredNav);
    pt_finalizeBucketEntries(eligibleNav, 6, @"navBar", navEntries, mirroredNav, &unmirroredNav);
    pt_finalizeBucketEntries(eligibleTool, 6, @"toolbar", toolEntries, mirroredTool, &unmirroredTool);

    plan.leadingEntries = leadingEntries;
    plan.navBarEntries = navEntries;
    plan.toolbarEntries = toolEntries;
    plan.mirroredLeadingItems = mirroredLeading;
    plan.mirroredNavBarItems = mirroredNav;
    plan.mirroredToolbarItems = mirroredTool;
    plan.allCandidateEntries = allCandidates;
    plan.hasUnmirroredNavBarItems = unmirroredNav || navBarHorizHeader;
    plan.hasUnmirroredToolbarItems = unmirroredTool;
    return plan;
}

// MARK: - Synthetic Liquid Glass Vertical Bar Host View

@interface PTDuoBarPillContainerView : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *solidBackgroundView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, assign) BOOL powerSavingMode;
@property (nonatomic, strong) NSNumber *forcedDarkSurface;
- (instancetype)initWithCornerRadius:(CGFloat)radius;
- (void)applyGlassBorderForTraitCollection:(UITraitCollection *)traits;
@end

@implementation PTDuoBarPillContainerView

- (instancetype)initWithCornerRadius:(CGFloat)radius {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor clearColor];
        _powerSavingMode = pt_duoIsPowerSavingModeEnabled();

        UIView *surfaceView = nil;
        UIView *stackHostView = nil;
        if (_powerSavingMode) {
            self.layer.shadowColor = NULL;
            self.layer.shadowOpacity = 0.0;
            self.layer.shadowRadius = 0.0;
            self.layer.shadowOffset = CGSizeZero;

            _solidBackgroundView = [[UIView alloc] initWithFrame:CGRectZero];
            _solidBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
            _solidBackgroundView.opaque = YES;
            _solidBackgroundView.layer.cornerRadius = radius;
            _solidBackgroundView.layer.cornerCurve = kCACornerCurveContinuous;
            _solidBackgroundView.layer.borderWidth = 0.75;
            _solidBackgroundView.clipsToBounds = YES;
            [self addSubview:_solidBackgroundView];
            surfaceView = _solidBackgroundView;
            stackHostView = _solidBackgroundView;
        } else {
            self.layer.shadowColor = [UIColor blackColor].CGColor;
            self.layer.shadowOpacity = 0.14;
            self.layer.shadowRadius = 10.0;
            self.layer.shadowOffset = CGSizeMake(0.0, 3.0);

            UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
            _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            _blurView.translatesAutoresizingMaskIntoConstraints = NO;
            _blurView.layer.cornerRadius = radius;
            _blurView.layer.cornerCurve = kCACornerCurveContinuous;
            _blurView.layer.borderWidth = 0.75;
            _blurView.clipsToBounds = YES;
            [self addSubview:_blurView];
            surfaceView = _blurView;
            stackHostView = _blurView.contentView;
        }

        _stackView = [[UIStackView alloc] init];
        _stackView.translatesAutoresizingMaskIntoConstraints = NO;
        _stackView.axis = UILayoutConstraintAxisVertical;
        _stackView.alignment = UIStackViewAlignmentCenter;
        _stackView.distribution = UIStackViewDistributionEqualSpacing;
        _stackView.spacing = 4.0;
        [stackHostView addSubview:_stackView];

        [NSLayoutConstraint activateConstraints:@[
            [surfaceView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [surfaceView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [surfaceView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [surfaceView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_stackView.leadingAnchor constraintEqualToAnchor:stackHostView.leadingAnchor constant:3.0],
            [_stackView.trailingAnchor constraintEqualToAnchor:stackHostView.trailingAnchor constant:-3.0],
            [_stackView.topAnchor constraintEqualToAnchor:stackHostView.topAnchor constant:4.0],
            [_stackView.bottomAnchor constraintEqualToAnchor:stackHostView.bottomAnchor constant:-4.0],
        ]];
        [self applyGlassBorderForTraitCollection:self.traitCollection];
    }
    return self;
}

- (void)setForcedDarkSurface:(NSNumber *)forcedDarkSurface {
    if ((_forcedDarkSurface == nil && forcedDarkSurface == nil) ||
        (_forcedDarkSurface != nil && forcedDarkSurface != nil && [_forcedDarkSurface isEqualToNumber:forcedDarkSurface])) {
        return;
    }
    _forcedDarkSurface = forcedDarkSurface;
    [self applyGlassBorderForTraitCollection:self.traitCollection];
}

- (void)applyGlassBorderForTraitCollection:(UITraitCollection *)traits {
    BOOL isDark = self.forcedDarkSurface ? self.forcedDarkSurface.boolValue : (traits.userInterfaceStyle == UIUserInterfaceStyleDark);
    CGColorRef borderColor = (isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.18]
        : [UIColor colorWithWhite:0.0 alpha:0.09]).CGColor;
    if (_powerSavingMode) {
        _solidBackgroundView.backgroundColor = pt_duoOpaquePillBackgroundColor(isDark);
        _solidBackgroundView.layer.borderColor = borderColor;
        self.layer.shadowOpacity = 0.0;
    } else {
        _blurView.layer.borderColor = borderColor;
        self.layer.shadowOpacity = isDark ? 0.30 : 0.14;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyGlassBorderForTraitCollection:self.traitCollection];
}

@end

static void pt_configureRailButtonVisual(UIButton *btn,
                                         UIImage *img,
                                         NSString *fallbackTitle,
                                         UIColor *tintColor,
                                         UIEdgeInsets imageInsets,
                                         CGFloat fallbackFontSize,
                                         UIFontWeight fallbackWeight,
                                         BOOL isDarkMode,
                                         BOOL preserveOriginalFill) {
    if (!btn) {
        return;
    }
    btn.tintColor = tintColor ?: [UIColor labelColor];
    if (img) {
        UIImage *renderImg = img;
        if (preserveOriginalFill) {
            renderImg = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        } else if (img.renderingMode == UIImageRenderingModeAutomatic || pt_imageNeedsTemplateTintOnGlass(img, isDarkMode)) {
            renderImg = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        [btn setTitle:nil forState:UIControlStateNormal];
        [btn setImage:renderImg forState:UIControlStateNormal];
        btn.imageView.contentMode = preserveOriginalFill ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
        btn.imageEdgeInsets = preserveOriginalFill ? UIEdgeInsetsZero : imageInsets;
    } else if (fallbackTitle.length > 0) {
        NSString *shortTitle = fallbackTitle.length > 3 ? [fallbackTitle substringToIndex:3] : fallbackTitle;
        [btn setImage:nil forState:UIControlStateNormal];
        [btn setTitle:shortTitle forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:fallbackFontSize weight:fallbackWeight];
    } else {
        [btn setImage:nil forState:UIControlStateNormal];
        [btn setTitle:nil forState:UIControlStateNormal];
    }
}

@interface PTDuoVerticalBarHostView : UIView
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, weak) UINavigationController *activeNavController;
@property (nonatomic, weak) UINavigationController *activeHeaderNavController;
@property (nonatomic, weak) UINavigationController *suppressedNavController;
@property (nonatomic, weak) UINavigationController *suppressedToolbarNavController;
@property (nonatomic, weak) UINavigationItem *suppressedBackNavItem;
@property (nonatomic, strong) NSHashTable<UIBarButtonItem *> *suppressedBarItems;
@property (nonatomic, strong) NSHashTable<UIView *> *suppressedCustomBarViews;
@property (nonatomic, strong) NSHashTable<UIView *> *suppressedToolbarChromeViews;
@property (nonatomic, weak) UITabBarController *activeTabBarController;
@property (nonatomic, weak) UITabBar *relocatedTabBar;
@property (nonatomic, strong) NSHashTable<UIView *> *relocatedTabBarChromeViews;
@property (nonatomic, strong) NSArray<UIBarButtonItem *> *boundBarItems;
@property (nonatomic, strong) NSArray<PTDuoBarItemEntry *> *boundItemEntries;
@property (nonatomic, strong) PTDuoBarItemPlan *lastItemPlan;
@property (nonatomic, strong) NSArray<id> *boundModernTabs;
@property (nonatomic, strong) id boundProminentTab;
@property (nonatomic, strong) NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *boundLegacySlotOverlays;
@property (nonatomic, strong) NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *boundModernSlotOverlays;
@property (nonatomic, strong) PTDuoTabSlotOverlay *boundProminentOverlay;
@property (nonatomic, strong) PTDuoTabSlotOverlay *boundPureActionDockOverlay;
@property (nonatomic, assign) BOOL usingModernTabs;
@property (nonatomic, assign) BOOL hasRelocatedTabBar;
@property (nonatomic, copy) NSString *lastRenderSignature;

@property (nonatomic, strong) UIStackView *topStackView;
@property (nonatomic, strong) PTDuoBarPillContainerView *backPill;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) PTDuoBarPillContainerView *leadingPill;
@property (nonatomic, strong) PTDuoBarPillContainerView *itemsPill;
@property (nonatomic, strong) UIStackView *bottomStackView;
@property (nonatomic, strong) PTDuoBarPillContainerView *toolbarPill;
@property (nonatomic, strong) PTDuoBarPillContainerView *dockPill;
@property (nonatomic, strong) UIView *prominentPill;
@property (nonatomic, strong) UIVisualEffectView *prominentBlurView;
@property (nonatomic, strong) UIView *prominentSolidView;
@property (nonatomic, assign) BOOL powerSavingMode;
@property (nonatomic, strong) NSNumber *forcedDarkSurface;
@property (nonatomic, strong) UIButton *prominentButton;
@end

@implementation PTDuoVerticalBarHostView

- (instancetype)initWithWindow:(UIWindow *)window {
    CGRect frame = CGRectMake(CGRectGetWidth(window.bounds) - kPTDuoVerticalBarWidth,
                              0.0,
                              kPTDuoVerticalBarWidth,
                              CGRectGetHeight(window.bounds));
    self = [super initWithFrame:frame];
    if (self) {
        _hostWindow = window;
        _suppressedBarItems = [NSHashTable weakObjectsHashTable];
        _suppressedCustomBarViews = [NSHashTable weakObjectsHashTable];
        _suppressedToolbarChromeViews = [NSHashTable weakObjectsHashTable];
        _relocatedTabBarChromeViews = [NSHashTable weakObjectsHashTable];
        self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.hidden = YES;
        self.layer.zPosition = 900.0;

        _topStackView = [[UIStackView alloc] init];
        _topStackView.translatesAutoresizingMaskIntoConstraints = NO;
        _topStackView.axis = UILayoutConstraintAxisVertical;
        _topStackView.alignment = UIStackViewAlignmentCenter;
        _topStackView.distribution = UIStackViewDistributionFill;
        _topStackView.spacing = 10.0;
        [self addSubview:_topStackView];

        _backPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _backPill.hidden = YES;
        [_topStackView addArrangedSubview:_backPill];

        _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _backButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0
                                                                                           weight:UIImageSymbolWeightSemibold];
        [_backButton setImage:[UIImage systemImageNamed:@"chevron.backward" withConfiguration:symCfg]
                     forState:UIControlStateNormal];
        _backButton.tintColor = [UIColor labelColor];
        _backButton.accessibilityLabel = @"Back";
        [_backButton addTarget:self action:@selector(handleBackTap:) forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [_backButton.widthAnchor constraintEqualToConstant:38.0],
            [_backButton.heightAnchor constraintEqualToConstant:36.0],
        ]];
        [_backPill.stackView addArrangedSubview:_backButton];

        _leadingPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _leadingPill.hidden = YES;
        [_topStackView addArrangedSubview:_leadingPill];

        _itemsPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _itemsPill.hidden = YES;
        [_topStackView addArrangedSubview:_itemsPill];

        _bottomStackView = [[UIStackView alloc] init];
        _bottomStackView.translatesAutoresizingMaskIntoConstraints = NO;
        _bottomStackView.axis = UILayoutConstraintAxisVertical;
        _bottomStackView.alignment = UIStackViewAlignmentCenter;
        _bottomStackView.distribution = UIStackViewDistributionFill;
        _bottomStackView.spacing = 10.0;
        [self addSubview:_bottomStackView];

        _toolbarPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _toolbarPill.hidden = YES;
        [_bottomStackView addArrangedSubview:_toolbarPill];

        _dockPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _dockPill.hidden = YES;
        [_bottomStackView addArrangedSubview:_dockPill];

        _powerSavingMode = pt_duoIsPowerSavingModeEnabled();

        _prominentPill = [[UIView alloc] initWithFrame:CGRectZero];
        _prominentPill.translatesAutoresizingMaskIntoConstraints = NO;
        _prominentPill.backgroundColor = [UIColor clearColor];
        _prominentPill.hidden = YES;
        if (_powerSavingMode) {
            _prominentPill.layer.shadowColor = NULL;
            _prominentPill.layer.shadowOpacity = 0.0;
            _prominentPill.layer.shadowRadius = 0.0;
            _prominentPill.layer.shadowOffset = CGSizeZero;
        } else {
            _prominentPill.layer.shadowColor = [UIColor blackColor].CGColor;
            _prominentPill.layer.shadowOpacity = 0.16;
            _prominentPill.layer.shadowRadius = 10.0;
            _prominentPill.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        }
        [_bottomStackView addArrangedSubview:_prominentPill];

        UIView *prominentSurface = nil;
        if (_powerSavingMode) {
            _prominentSolidView = [[UIView alloc] initWithFrame:CGRectZero];
            _prominentSolidView.translatesAutoresizingMaskIntoConstraints = NO;
            _prominentSolidView.opaque = YES;
            _prominentSolidView.layer.cornerRadius = 22.0;
            _prominentSolidView.layer.cornerCurve = kCACornerCurveContinuous;
            _prominentSolidView.layer.borderWidth = 0.75;
            _prominentSolidView.clipsToBounds = YES;
            [_prominentPill addSubview:_prominentSolidView];
            prominentSurface = _prominentSolidView;
        } else {
            _prominentBlurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
            _prominentBlurView.translatesAutoresizingMaskIntoConstraints = NO;
            _prominentBlurView.layer.cornerRadius = 22.0;
            _prominentBlurView.layer.cornerCurve = kCACornerCurveContinuous;
            _prominentBlurView.layer.borderWidth = 0.75;
            _prominentBlurView.clipsToBounds = YES;
            [_prominentPill addSubview:_prominentBlurView];
            prominentSurface = _prominentBlurView;
        }

        _prominentButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _prominentButton.translatesAutoresizingMaskIntoConstraints = NO;
        _prominentButton.layer.cornerRadius = 22.0;
        _prominentButton.layer.cornerCurve = kCACornerCurveContinuous;
        _prominentButton.clipsToBounds = YES;
        [_prominentButton addTarget:self action:@selector(handleProminentTabTap:) forControlEvents:UIControlEventTouchUpInside];
        [_prominentPill addSubview:_prominentButton];

        [NSLayoutConstraint activateConstraints:@[
            [_topStackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_topStackView.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:16.0],
            [_backPill.widthAnchor constraintEqualToConstant:44.0],
            [_leadingPill.widthAnchor constraintEqualToConstant:44.0],
            [_itemsPill.widthAnchor constraintEqualToConstant:44.0],

            [_bottomStackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_bottomStackView.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-18.0],
            [_toolbarPill.widthAnchor constraintEqualToConstant:44.0],
            [_dockPill.widthAnchor constraintEqualToConstant:44.0],
            [_prominentPill.widthAnchor constraintEqualToConstant:44.0],
            [_prominentPill.heightAnchor constraintEqualToConstant:44.0],
            [prominentSurface.leadingAnchor constraintEqualToAnchor:_prominentPill.leadingAnchor],
            [prominentSurface.trailingAnchor constraintEqualToAnchor:_prominentPill.trailingAnchor],
            [prominentSurface.topAnchor constraintEqualToAnchor:_prominentPill.topAnchor],
            [prominentSurface.bottomAnchor constraintEqualToAnchor:_prominentPill.bottomAnchor],
            [_prominentButton.leadingAnchor constraintEqualToAnchor:_prominentPill.leadingAnchor],
            [_prominentButton.trailingAnchor constraintEqualToAnchor:_prominentPill.trailingAnchor],
            [_prominentButton.topAnchor constraintEqualToAnchor:_prominentPill.topAnchor],
            [_prominentButton.bottomAnchor constraintEqualToAnchor:_prominentPill.bottomAnchor],
        ]];
        [self applyProminentGlassBorderForTraitCollection:self.traitCollection];
    }
    return self;
}

- (void)setForcedDarkSurface:(NSNumber *)forcedDarkSurface {
    if ((_forcedDarkSurface == nil && forcedDarkSurface == nil) ||
        (_forcedDarkSurface != nil && forcedDarkSurface != nil && [_forcedDarkSurface isEqualToNumber:forcedDarkSurface])) {
        return;
    }
    _forcedDarkSurface = forcedDarkSurface;
    [self applyProminentGlassBorderForTraitCollection:self.traitCollection];
}

- (void)applyProminentGlassBorderForTraitCollection:(UITraitCollection *)traits {
    BOOL isDark = self.forcedDarkSurface ? self.forcedDarkSurface.boolValue : (traits.userInterfaceStyle == UIUserInterfaceStyleDark);
    CGColorRef borderColor = (isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.18]
        : [UIColor colorWithWhite:0.0 alpha:0.09]).CGColor;
    if (self.powerSavingMode) {
        self.prominentSolidView.backgroundColor = pt_duoOpaquePillBackgroundColor(isDark);
        self.prominentSolidView.layer.borderColor = borderColor;
        self.prominentPill.layer.shadowOpacity = 0.0;
    } else {
        self.prominentBlurView.layer.borderColor = borderColor;
        self.prominentPill.layer.shadowOpacity = isDark ? 0.30 : 0.16;
    }
}

- (void)setProminentBackdropHidden:(BOOL)hidden {
    if (self.prominentBlurView) {
        self.prominentBlurView.hidden = hidden;
    }
    if (self.prominentSolidView) {
        self.prominentSolidView.hidden = hidden;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyProminentGlassBorderForTraitCollection:self.traitCollection];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) {
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.topStackView || hit == self.bottomStackView) ? nil : hit;
}

- (void)restoreRelocatedTabBarIfNeeded {
    if (self.relocatedTabBar) {
        pt_setTabBarRelocatedHidden(self.relocatedTabBar, NO);
        self.relocatedTabBar = nil;
    }
    if (self.relocatedTabBarChromeViews.count > 0) {
        for (UIView *chromeView in [self.relocatedTabBarChromeViews allObjects]) {
            pt_setFloatingChromeViewRelocatedHidden(chromeView, NO);
        }
        [self.relocatedTabBarChromeViews removeAllObjects];
    }
    self.hasRelocatedTabBar = NO;
}

- (void)suppressFloatingTabBarChromeForTabVC:(UITabBarController *)tabVC {
    if (!tabVC) {
        return;
    }
    NSArray<UIView *> *chromeViews = pt_collectFloatingTabBarChromeViews(tabVC);
    NSHashTable<UIView *> *desired = [NSHashTable weakObjectsHashTable];
    for (UIView *v in chromeViews) {
        [desired addObject:v];
    }
    for (UIView *prev in [self.relocatedTabBarChromeViews allObjects]) {
        if (![desired containsObject:prev]) {
            pt_setFloatingChromeViewRelocatedHidden(prev, NO);
            [self.relocatedTabBarChromeViews removeObject:prev];
        }
    }
    for (UIView *v in chromeViews) {
        pt_setFloatingChromeViewRelocatedHidden(v, YES);
        [self.relocatedTabBarChromeViews addObject:v];
    }
}

static void pt_collectFloatingChromeLeafControlsInNode(UIView *node,
                                                       NSInteger depth,
                                                       NSMutableArray<UIView *> *outViews) {
    if (!node || depth > 12) {
        return;
    }
    NSString *clsName = NSStringFromClass([node class]);
    if ([node isKindOfClass:[UINavigationBar class]]
        || [node isKindOfClass:[UITabBar class]]
        || [clsName isEqualToString:@"PTDuoVerticalBarHostView"]) {
        return;
    }
    if (depth > 0) {
        if (![outViews containsObject:node]) {
            [outViews addObject:node];
        }
    }
    for (UIView *sub in node.subviews) {
        pt_collectFloatingChromeLeafControlsInNode(sub, depth + 1, outViews);
    }
}

static BOOL pt_floatingBarHostHasCompactAboveBottom(UIView *node,
                                                    UIView *rootView,
                                                    CGFloat rootHeight,
                                                    NSInteger depth,
                                                    BOOL *outFoundBottomChrome) {
    if (!node || depth > 12) {
        return NO;
    }
    if (!pt_nodeAppVisibleForOverlayScan(node, YES)) {
        return NO;
    }
    if (depth > 0) {
        NSString *clsName = NSStringFromClass([node class]);
        CGRect rectInRoot = [node convertRect:node.bounds toView:rootView];
        CGFloat w = CGRectGetWidth(rectInRoot);
        CGFloat h = CGRectGetHeight(rectInRoot);
        CGFloat maxY = CGRectGetMaxY(rectInRoot);
        BOOL isCompactLeafOrControl = ([node isKindOfClass:[UIControl class]]
                                       || [node isKindOfClass:[UIImageView class]]
                                       || [node isKindOfClass:[UILabel class]]
                                       || [clsName containsString:@"UIKitCorePlatformViewHost"]
                                       || [clsName containsString:@"_UIButtonBarButton"]
                                       || (w > 1.0 && w <= 420.0 && h > 1.0 && h <= 120.0));
        if (isCompactLeafOrControl && h > 1.0 && h <= 160.0 && rootHeight > 1.0) {
            if (maxY < rootHeight - 130.0) {
                return YES;
            }
            if (outFoundBottomChrome) {
                *outFoundBottomChrome = YES;
            }
        }
    }
    for (UIView *sub in node.subviews) {
        if (pt_floatingBarHostHasCompactAboveBottom(sub, rootView, rootHeight, depth + 1, outFoundBottomChrome)) {
            return YES;
        }
    }
    return NO;
}

static void pt_collectOrphanBottomToolbarChromeInNode(UIView *node,
                                                      UIView *rootView,
                                                      UIView *excludedViewA,
                                                      UIView *excludedViewB,
                                                      UIView *excludedViewC,
                                                      CGFloat rootWidth,
                                                      CGFloat rootHeight,
                                                      UIView *outerFloatingBarContainer,
                                                      UIView *floatingBarHostView,
                                                      NSInteger depth,
                                                      NSMutableArray<UIView *> *outViews) {
    if (!node || depth > 18 || node == excludedViewA || node == excludedViewB || node == excludedViewC) {
        return;
    }
    NSString *clsName = NSStringFromClass([node class]);
    BOOL isFloatingContainerNode = [clsName containsString:@"_UIFloatingBarContainerView"];
    BOOL isFloatingHostNode = isFloatingContainerNode || [clsName containsString:@"FloatingBarHostingView"];
    UIView *nextOuterContainer = outerFloatingBarContainer ?: (isFloatingContainerNode ? node : nil);
    UIView *nextFloatingBarHost = [clsName containsString:@"FloatingBarHostingView"] ? node : (floatingBarHostView ?: nextOuterContainer);
    if ((excludedViewA && pt_isDescendantOrSameView(excludedViewA, node))
        || (excludedViewB && pt_isDescendantOrSameView(excludedViewB, node))
        || (excludedViewC && pt_isDescendantOrSameView(excludedViewC, node))) {
        for (UIView *sub in node.subviews) {
            pt_collectOrphanBottomToolbarChromeInNode(sub, rootView, excludedViewA, excludedViewB, excludedViewC, rootWidth, rootHeight, nextOuterContainer, nextFloatingBarHost, depth + 1, outViews);
        }
        return;
    }
    if (depth > 0) {
        if ([node isKindOfClass:[UINavigationBar class]]
            || [clsName isEqualToString:@"UITransitionView"]
            || [clsName isEqualToString:@"UIViewControllerWrapperView"]
            || [clsName isEqualToString:@"PTDuoVerticalBarHostView"]) {
            return;
        }
        CGRect rectInRoot = [node convertRect:node.bounds toView:rootView];
        CGFloat w = CGRectGetWidth(rectInRoot);
        CGFloat h = CGRectGetHeight(rectInRoot);
        CGFloat minX = CGRectGetMinX(rectInRoot);
        CGFloat maxY = CGRectGetMaxY(rectInRoot);
        BOOL inBottomBand = (h > 1.0 && h <= 120.0 && rootHeight > 1.0 && maxY >= rootHeight - 90.0);
        if (inBottomBand) {
            BOOL isTabOrFloatingBar = ([node isKindOfClass:[UITabBar class]]
                                       || [clsName containsString:@"TabBar"]
                                       || isFloatingHostNode);
            if (isTabOrFloatingBar) {
                if (![node isKindOfClass:[UITabBar class]]
                    || pt_collectVisibleSystemTabButtonCenters((UITabBar *)node, nil, NULL, NULL).count < 2) {
                    if (![outViews containsObject:node]) {
                        [outViews addObject:node];
                    }
                }
                return;
            }
            CGFloat maxFloatingPlatterWidth = (rootWidth > 1.0) ? MAX(320.0, rootWidth * 0.55) : 420.0;
            BOOL isHostedFloatingBottomChrome = ((outerFloatingBarContainer != nil || floatingBarHostView != nil)
                                                 && w >= 20.0 && w <= maxFloatingPlatterWidth
                                                 && h >= 20.0 && h <= 84.0
                                                 && ([clsName containsString:@"_UIInheritedView"]
                                                     || [clsName containsString:@"Platter"]
                                                     || [clsName containsString:@"_UIButtonBarButton"]
                                                     || [clsName containsString:@"UIKitCorePlatformViewHost"]
                                                     || [node isKindOfClass:[UIButton class]]));
            BOOL isBottomRightActionWrapper = (w >= 20.0 && w <= 84.0 && h >= 20.0 && h <= 84.0
                                               && rootWidth > 1.0 && minX >= rootWidth - 130.0
                                               && ([clsName containsString:@"_UIInheritedView"]
                                                   || [clsName containsString:@"_UIButtonBarButton"]
                                                   || [clsName containsString:@"Platter"]
                                                   || [node isKindOfClass:[UIButton class]]));
            if (isHostedFloatingBottomChrome || isBottomRightActionWrapper) {
                UIView *checkHost = outerFloatingBarContainer ?: floatingBarHostView;
                if (checkHost) {
                    BOOL foundBottomChrome = NO;
                    BOOL hasCompactAbove = pt_floatingBarHostHasCompactAboveBottom(checkHost, rootView, rootHeight, 0, &foundBottomChrome);
                    if (PTDuoShouldSuppressFloatingBarHost(hasCompactAbove, foundBottomChrome)) {
                        if (outerFloatingBarContainer) {
                            if (![outViews containsObject:outerFloatingBarContainer]) {
                                [outViews addObject:outerFloatingBarContainer];
                            }
                            pt_collectFloatingChromeLeafControlsInNode(outerFloatingBarContainer, 0, outViews);
                        }
                        if (floatingBarHostView) {
                            if (![outViews containsObject:floatingBarHostView]) {
                                [outViews addObject:floatingBarHostView];
                            }
                            pt_collectFloatingChromeLeafControlsInNode(floatingBarHostView, 0, outViews);
                        }
                    }
                }
                if (![outViews containsObject:node]) {
                    [outViews addObject:node];
                }
                pt_collectFloatingChromeLeafControlsInNode(node, 0, outViews);
                return;
            }
        }
    }
    for (UIView *sub in node.subviews) {
        pt_collectOrphanBottomToolbarChromeInNode(sub, rootView, excludedViewA, excludedViewB, excludedViewC, rootWidth, rootHeight, nextOuterContainer, nextFloatingBarHost, depth + 1, outViews);
    }
}

static void pt_collectVisibleNavControllersInSubtree(UIViewController *vc,
                                                     NSMutableArray<UINavigationController *> *outNavs,
                                                     NSHashTable<UIViewController *> *visited,
                                                     NSInteger depth) {
    if (!vc || depth > 12 || [visited containsObject:vc]) {
        return;
    }
    [visited addObject:vc];
    if (!vc.isViewLoaded || vc.view.hidden || vc.view.alpha <= 0.01) {
        return;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        [outNavs addObject:(UINavigationController *)vc];
    }
    for (UIViewController *child in vc.childViewControllers) {
        pt_collectVisibleNavControllersInSubtree(child, outNavs, visited, depth + 1);
    }
}

static NSArray<UIView *> *pt_collectAllFloatingToolbarChromeViews(UINavigationController *headerNav,
                                                                  UINavigationController *toolbarNav,
                                                                  UITabBarController *tabVC,
                                                                  UIWindow *window,
                                                                  BOOL includeOrphanBottomContainerChrome) {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    if (toolbarNav) {
        for (UIView *v in pt_collectFloatingToolbarChromeViews(toolbarNav)) {
            if (![result containsObject:v]) {
                [result addObject:v];
            }
            NSString *vCls = NSStringFromClass([v class]);
            if ([vCls containsString:@"_UIFloatingBarContainerView"]
                || [vCls containsString:@"FloatingBarHostingView"]) {
                pt_collectFloatingChromeLeafControlsInNode(v, 0, result);
            }
        }
    }
    if (includeOrphanBottomContainerChrome) {
        // Also inspect sibling/ancestor visible UINavigationControllers (e.g. split-column or root wrappers)
        // gating floating bar hosts by PTShouldSuppressFloatingBarHost (bottom-only chrome).
        NSMutableArray<UINavigationController *> *extraNavs = [NSMutableArray array];
        NSHashTable<UIViewController *> *seenNavVCs = [NSHashTable weakObjectsHashTable];
        if (headerNav && headerNav != toolbarNav) {
            [extraNavs addObject:headerNav];
        }
        if (window && window.rootViewController) {
            pt_collectVisibleNavControllersInSubtree(window.rootViewController, extraNavs, seenNavVCs, 0);
        }
        NSHashTable<UINavigationController *> *checkedNavs = [NSHashTable weakObjectsHashTable];
        for (UINavigationController *candNav in extraNavs) {
            if (!candNav || candNav == toolbarNav || [checkedNavs containsObject:candNav] || !candNav.isViewLoaded) {
                continue;
            }
            [checkedNavs addObject:candNav];
            CGFloat navH = CGRectGetHeight(candNav.view.bounds);
            for (UIView *v in pt_collectFloatingToolbarChromeViews(candNav)) {
                NSString *vCls = NSStringFromClass([v class]);
                if ([vCls containsString:@"_UIFloatingBarContainerView"]
                    || [vCls containsString:@"FloatingBarHostingView"]) {
                    BOOL foundBottom = NO;
                    BOOL hasCompactAbove = pt_floatingBarHostHasCompactAboveBottom(v, candNav.view, navH, 0, &foundBottom);
                    if (!PTDuoShouldSuppressFloatingBarHost(hasCompactAbove, foundBottom)) {
                        continue;
                    }
                }
                if (![result containsObject:v]) {
                    [result addObject:v];
                }
                pt_collectFloatingChromeLeafControlsInNode(v, 0, result);
            }
        }

        UIView *containerRoot = (tabVC && tabVC.isViewLoaded)
            ? tabVC.view
            : ((toolbarNav && toolbarNav.parentViewController && toolbarNav.parentViewController.isViewLoaded)
               ? toolbarNav.parentViewController.view
               : ((window && window.rootViewController && window.rootViewController.isViewLoaded) ? window.rootViewController.view : nil));
        UIView *excludedA = (toolbarNav && toolbarNav.isViewLoaded && toolbarNav.topViewController.isViewLoaded)
            ? toolbarNav.topViewController.view
            : (toolbarNav && toolbarNav.isViewLoaded ? toolbarNav.view : nil);
        UIViewController *selTabChild = tabVC ? pt_selectedViewControllerForTabBarController(tabVC) : nil;
        UIView *excludedB = (selTabChild && selTabChild.isViewLoaded) ? selTabChild.view : nil;
        UIView *excludedC = (headerNav && headerNav.isViewLoaded) ? headerNav.navigationBar : nil;
        if (containerRoot && (!toolbarNav || !toolbarNav.isViewLoaded || containerRoot != toolbarNav.view)) {
            NSMutableArray<UIView *> *orphan = [NSMutableArray array];
            pt_collectOrphanBottomToolbarChromeInNode(containerRoot,
                                                      containerRoot,
                                                      excludedA,
                                                      excludedB,
                                                      excludedC,
                                                      CGRectGetWidth(containerRoot.bounds),
                                                      CGRectGetHeight(containerRoot.bounds),
                                                      nil,
                                                      nil,
                                                      0,
                                                      orphan);
            for (UIView *v in orphan) {
                if (![result containsObject:v]) {
                    [result addObject:v];
                }
            }
        }
        if (window && window != containerRoot) {
            NSMutableArray<UIView *> *windowOrphan = [NSMutableArray array];
            pt_collectOrphanBottomToolbarChromeInNode(window,
                                                      window,
                                                      excludedA,
                                                      excludedB,
                                                      excludedC,
                                                      CGRectGetWidth(window.bounds),
                                                      CGRectGetHeight(window.bounds),
                                                      nil,
                                                      nil,
                                                      0,
                                                      windowOrphan);
            for (UIView *v in windowOrphan) {
                if (![result containsObject:v]) {
                    [result addObject:v];
                }
            }
        }
    }
    return result;
}

- (void)restoreFloatingToolbarChromeIfNeeded {
    if (self.suppressedToolbarChromeViews.count > 0) {
        for (UIView *chromeView in [self.suppressedToolbarChromeViews allObjects]) {
            if ([chromeView isKindOfClass:[UITabBar class]]) {
                pt_setTabBarRelocatedHidden((UITabBar *)chromeView, NO);
            } else {
                pt_setFloatingChromeViewRelocatedHidden(chromeView, NO);
            }
        }
        [self.suppressedToolbarChromeViews removeAllObjects];
    }
}

- (void)suppressFloatingToolbarChromeViews:(NSArray<UIView *> *)chromeViews {
    NSHashTable<UIView *> *desired = [NSHashTable weakObjectsHashTable];
    for (UIView *v in chromeViews) {
        [desired addObject:v];
    }
    for (UIView *prev in [self.suppressedToolbarChromeViews allObjects]) {
        if (![desired containsObject:prev]) {
            if ([prev isKindOfClass:[UITabBar class]]) {
                pt_setTabBarRelocatedHidden((UITabBar *)prev, NO);
            } else {
                pt_setFloatingChromeViewRelocatedHidden(prev, NO);
            }
            [self.suppressedToolbarChromeViews removeObject:prev];
        }
    }
    for (UIView *v in chromeViews) {
        if ([v isKindOfClass:[UITabBar class]]) {
            pt_setTabBarRelocatedHidden((UITabBar *)v, YES);
        } else {
            pt_setFloatingChromeViewRelocatedHidden(v, YES);
        }
        [self.suppressedToolbarChromeViews addObject:v];
    }
}

- (void)suppressFloatingToolbarChromeForNav:(UINavigationController *)nav {
    if (!nav) {
        return;
    }
    [self suppressFloatingToolbarChromeViews:pt_collectFloatingToolbarChromeViews(nav)];
}

- (void)restoreSuppressedNavChromeIfNeeded {
    if (self.suppressedNavController) {
        pt_setNavBarVisualSuppressed(self.suppressedNavController, NO);
        self.suppressedNavController = nil;
    }
    if (self.suppressedToolbarNavController) {
        pt_setToolbarVisualSuppressed(self.suppressedToolbarNavController, NO);
        self.suppressedToolbarNavController = nil;
    }
    [self restoreFloatingToolbarChromeIfNeeded];
    if (self.suppressedBackNavItem) {
        pt_setNavItemBackButtonSuppressed(self.suppressedBackNavItem, NO);
        self.suppressedBackNavItem = nil;
    }
    if (self.suppressedBarItems.count > 0) {
        for (UIBarButtonItem *item in [self.suppressedBarItems allObjects]) {
            pt_setBarItemHorizontalSuppressed(item, NO);
        }
        [self.suppressedBarItems removeAllObjects];
    }
    if (self.suppressedCustomBarViews.count > 0) {
        for (UIView *cv in [self.suppressedCustomBarViews allObjects]) {
            pt_setCustomViewHorizontalSuppressed(cv, NO);
        }
        [self.suppressedCustomBarViews removeAllObjects];
    }
}

static BOOL pt_nodeHasPlatterContainerSubtree(UIView *view, CALayer *layer, NSInteger depth) {
    if (depth > 7) {
        return NO;
    }
    if (view) {
        NSString *cls = NSStringFromClass([view class]);
        if ([cls containsString:@"NavigationBarPlatterContainer"]
            || [cls containsString:@"PlatterContainerHostingView"]
            || [cls containsString:@"NavigationBarPlatterRepresentable"]) {
            return YES;
        }
        for (UIView *sub in view.subviews) {
            if (pt_nodeHasPlatterContainerSubtree(sub, nil, depth + 1)) {
                return YES;
            }
        }
        if (view.layer && pt_nodeHasPlatterContainerSubtree(nil, view.layer, depth)) {
            return YES;
        }
        return NO;
    }
    if (layer) {
        NSString *lcls = NSStringFromClass([layer class]);
        if ([lcls containsString:@"SDFLayer"]) {
            return YES;
        }
        for (CALayer *subL in layer.sublayers) {
            if (pt_nodeHasPlatterContainerSubtree(nil, subL, depth + 1)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL pt_navBarUsesPlatterContainer(UINavigationBar *navBar) {
    if (!navBar) {
        return NO;
    }
    return pt_nodeHasPlatterContainerSubtree(navBar, nil, 0);
}

- (void)syncSuppressedNavChromeForHeaderNav:(UINavigationController *)headerNav
                                 toolbarNav:(UINavigationController *)toolbarNav
                                      tabVC:(UITabBarController *)tabVC
                         includeOrphanDock:(BOOL)includeOrphanDock
                                   showBack:(BOOL)showBack
                                       plan:(PTDuoBarItemPlan *)plan {
    if (self.suppressedNavController && self.suppressedNavController != headerNav) {
        pt_setNavBarVisualSuppressed(self.suppressedNavController, NO);
        self.suppressedNavController = nil;
    }
    if (self.suppressedToolbarNavController && self.suppressedToolbarNavController != toolbarNav) {
        pt_setToolbarVisualSuppressed(self.suppressedToolbarNavController, NO);
        self.suppressedToolbarNavController = nil;
        [self restoreFloatingToolbarChromeIfNeeded];
    }

    NSArray<UIBarButtonItem *> *mirroredLeadingItems = plan ? plan.mirroredLeadingItems : @[];
    NSArray<UIBarButtonItem *> *mirroredNavItems = plan ? plan.mirroredNavBarItems : @[];
    NSArray<UIBarButtonItem *> *mirroredToolItems = plan ? plan.mirroredToolbarItems : @[];

    BOOL navBarVisibleByApp = pt_navBarVisibleByApp(headerNav);
    BOOL mirroredAnyNavBarControl = (showBack || mirroredLeadingItems.count > 0 || mirroredNavItems.count > 0);
    BOOL hasUnmirroredTopContent = (navBarVisibleByApp && plan) ? plan.hasUnmirroredNavBarItems : NO;
    PTDuoNavBarSuppressionMode mode = PTDuoClassifyNavBarSuppression(navBarVisibleByApp,
                                                                     mirroredAnyNavBarControl,
                                                                     hasUnmirroredTopContent);

    if (mode == PTDuoNavBarSuppressionFull && headerNav) {
        // Case 1: UINavigationBar has no title/titleView/search/unrelocated leading/HorizontalOnly items —
        // suppress the entire redundant horizontal bar and its extra top safe-area push cleanly.
        if (self.suppressedBackNavItem) {
            pt_setNavItemBackButtonSuppressed(self.suppressedBackNavItem, NO);
            self.suppressedBackNavItem = nil;
        }
        pt_setNavBarVisualSuppressed(headerNav, YES);
        self.suppressedNavController = headerNav;
    } else {
        if (self.suppressedNavController) {
            pt_setNavBarVisualSuppressed(self.suppressedNavController, NO);
            self.suppressedNavController = nil;
        }
        // Case 2: Keep title/search/HorizontalOnly top bar visible, hiding ONLY relocated back & items.
        UINavigationItem *targetBackNavItem = (mode == PTDuoNavBarSuppressionItemsOnly && showBack && headerNav)
            ? headerNav.topViewController.navigationItem
            : nil;
        if (self.suppressedBackNavItem && self.suppressedBackNavItem != targetBackNavItem) {
            pt_setNavItemBackButtonSuppressed(self.suppressedBackNavItem, NO);
            self.suppressedBackNavItem = nil;
        }
        if (targetBackNavItem) {
            pt_setNavItemBackButtonSuppressed(targetBackNavItem, YES);
            self.suppressedBackNavItem = targetBackNavItem;
        }
    }

    // Symmetrical iOS 27.1 rule for bottom UIToolbar + iOS 26/27 floating bottom toolbar/tabBar-hosted chrome
    NSArray<UIView *> *floatingToolbarViews = pt_collectAllFloatingToolbarChromeViews(headerNav,
                                                                                    toolbarNav,
                                                                                    tabVC,
                                                                                    self.hostWindow,
                                                                                    includeOrphanDock);
    BOOL hasFloatingToolbarChrome = (self.suppressedToolbarChromeViews.count > 0 || floatingToolbarViews.count > 0);
    BOOL toolbarVisibleByApp = NO;
    if (toolbarNav && !toolbarNav.isToolbarHidden) {
        if (toolbarNav.toolbar) {
            BOOL alreadyToolbarSuppressed = [objc_getAssociatedObject(toolbarNav.toolbar, kPTDuoToolbarSuppressedKey) boolValue];
            NSNumber *appHidden = objc_getAssociatedObject(toolbarNav.toolbar, kPTDuoToolbarAppHiddenKey);
            BOOL appWantsHidden = alreadyToolbarSuppressed ? (appHidden ? appHidden.boolValue : NO) : toolbarNav.toolbar.hidden;
            if (!appWantsHidden) {
                toolbarVisibleByApp = YES;
            }
        }
        if (!toolbarVisibleByApp && hasFloatingToolbarChrome && pt_anyFloatingChromeAppVisible(floatingToolbarViews)) {
            toolbarVisibleByApp = YES;
        }
    }
    BOOL hasUnmirroredToolbarContent = (toolbarVisibleByApp && plan) ? plan.hasUnmirroredToolbarItems : NO;
    PTDuoNavBarSuppressionMode toolbarMode = PTDuoClassifyNavBarSuppression(toolbarVisibleByApp,
                                                                            mirroredToolItems.count > 0,
                                                                            hasUnmirroredToolbarContent);
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(self.hostWindow, NO);
    if (insetState) {
        insetState.lastNavBarSuppressionMode = mode;
        insetState.lastToolbarSuppressionMode = toolbarMode;
    }

    if (toolbarMode == PTDuoNavBarSuppressionFull && toolbarNav) {
        pt_setToolbarVisualSuppressed(toolbarNav, YES);
        [self suppressFloatingToolbarChromeViews:floatingToolbarViews];
        self.suppressedToolbarNavController = toolbarNav;
    } else {
        if (self.suppressedToolbarNavController) {
            pt_setToolbarVisualSuppressed(self.suppressedToolbarNavController, NO);
            self.suppressedToolbarNavController = nil;
        }
        [self restoreFloatingToolbarChromeIfNeeded];
    }

    // Determine exact set of UIBarButtonItems (and customViews) that should be hidden in visible horizontal bars
    // (Case 2 nav-bar leading/trailing items + Case 2 toolbar items).
    NSHashTable<UIBarButtonItem *> *desiredBarItems = [NSHashTable weakObjectsHashTable];
    NSHashTable<UIView *> *desiredCustomViews = [NSHashTable weakObjectsHashTable];
    BOOL useBarItemSuppressionForCustom = (headerNav && pt_navBarUsesPlatterContainer(headerNav.navigationBar));
    if (mode == PTDuoNavBarSuppressionItemsOnly) {
        for (UIBarButtonItem *item in mirroredLeadingItems) {
            if (item.customView && !useBarItemSuppressionForCustom) {
                [desiredCustomViews addObject:(pt_horizontalSuppressedViewForCustomBarItemView(item.customView) ?: item.customView)];
            } else {
                [desiredBarItems addObject:item];
            }
        }
        for (UIBarButtonItem *item in mirroredNavItems) {
            if (item.customView && !useBarItemSuppressionForCustom) {
                [desiredCustomViews addObject:(pt_horizontalSuppressedViewForCustomBarItemView(item.customView) ?: item.customView)];
            } else {
                [desiredBarItems addObject:item];
            }
        }
    }
    if (toolbarMode == PTDuoNavBarSuppressionItemsOnly) {
        for (UIBarButtonItem *item in mirroredToolItems) {
            if (item.customView) {
                [desiredCustomViews addObject:(pt_horizontalSuppressedViewForCustomBarItemView(item.customView) ?: item.customView)];
            } else {
                [desiredBarItems addObject:item];
            }
        }
    }

    for (UIBarButtonItem *prevItem in [self.suppressedBarItems allObjects]) {
        if (![desiredBarItems containsObject:prevItem]) {
            pt_setBarItemHorizontalSuppressed(prevItem, NO);
            [self.suppressedBarItems removeObject:prevItem];
        }
    }
    for (UIBarButtonItem *nextItem in [desiredBarItems allObjects]) {
        pt_setBarItemHorizontalSuppressed(nextItem, YES);
        [self.suppressedBarItems addObject:nextItem];
    }

    for (UIView *prevView in [self.suppressedCustomBarViews allObjects]) {
        if (![desiredCustomViews containsObject:prevView]) {
            pt_setCustomViewHorizontalSuppressed(prevView, NO);
            [self.suppressedCustomBarViews removeObject:prevView];
        }
    }
    for (UIView *nextView in [desiredCustomViews allObjects]) {
        pt_setCustomViewHorizontalSuppressed(nextView, YES);
        [self.suppressedCustomBarViews addObject:nextView];
    }
}

- (void)hideAndRestore {
    [self restoreRelocatedTabBarIfNeeded];
    [self restoreSuppressedNavChromeIfNeeded];
    self.hidden = YES;
    self.lastRenderSignature = nil;
}

- (void)handleBackTap:(UIButton *)sender {
    (void)sender;
    UINavigationController *nav = self.activeHeaderNavController ?: self.activeNavController;
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        pt_scheduleRefreshForWindow(self.hostWindow);
    }
}

- (void)handleBarItemTap:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.boundItemEntries.count) {
        return;
    }
    PTDuoBarItemEntry *entry = self.boundItemEntries[(NSUInteger)idx];
    pt_executeBarItemEntry(entry, self.hostWindow);
}

- (void)activateModernTab:(id)tab {
    UITabBarController *tabVC = self.activeTabBarController;
    if (!tabVC || !tab || !pt_tabIsEnabled(tab)) {
        return;
    }
    id<UITabBarControllerDelegate> delegate = tabVC.delegate;
    SEL shouldSelectTabSel = sel_registerName("tabBarController:shouldSelectTab:");
    if (delegate && [delegate respondsToSelector:shouldSelectTabSel]) {
        BOOL allowed = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(delegate, shouldSelectTabSel, tabVC, tab);
        if (!allowed) {
            pt_scheduleRefreshForWindow(self.hostWindow);
            return;
        }
    }

    id previousTab = pt_tabBarControllerSelectedTab(tabVC);
    if (tab == previousTab) {
        UIViewController *selectedVC = pt_tabViewController(tab) ?: tabVC.selectedViewController;
        if ([selectedVC isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)selectedVC;
            if (nav.viewControllers.count > 1) {
                [nav popToRootViewControllerAnimated:YES];
            }
        }
        SEL didSelectTabSel = sel_registerName("tabBarController:didSelectTab:previousTab:");
        if (delegate && [delegate respondsToSelector:didSelectTabSel]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, didSelectTabSel, tabVC, tab, previousTab);
        } else if (delegate && [delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)] && selectedVC) {
            [delegate tabBarController:tabVC didSelectViewController:selectedVC];
        }
    } else {
        // On iOS 18+/27 Catalyst, -[UITabBarController setSelectedTab:] automatically notifies
        // tabBarController:didSelectTab:previousTab: once, so do NOT invoke it a second time.
        pt_tabBarControllerSetSelectedTab(tabVC, tab);
    }
    pt_scheduleRefreshForWindow(self.hostWindow);
}

- (void)handleModernTabTap:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.boundModernTabs.count) {
        return;
    }
    PTDuoTabSlotOverlay *ov = self.boundModernSlotOverlays[@((NSUInteger)idx)];
    if (ov && ov.actionControl) {
        pt_triggerControlAction(ov.actionControl);
        pt_scheduleRefreshForWindow(self.hostWindow);
        return;
    }
    if (ov && ov.tapTarget && ov.tapAction != NULL) {
        pt_dispatchVerifiedTapAction(ov.tapGesture, ov.tapTarget, ov.tapAction);
        pt_scheduleRefreshForWindow(self.hostWindow);
        return;
    }
    [self activateModernTab:self.boundModernTabs[(NSUInteger)idx]];
}

- (void)handleProminentTabTap:(UIButton *)sender {
    (void)sender;
    if (self.boundProminentOverlay) {
        if (self.boundProminentOverlay.actionControl) {
            pt_triggerControlAction(self.boundProminentOverlay.actionControl);
            pt_scheduleRefreshForWindow(self.hostWindow);
            return;
        }
        if (self.boundProminentOverlay.tapTarget && self.boundProminentOverlay.tapAction != NULL) {
            pt_dispatchVerifiedTapAction(self.boundProminentOverlay.tapGesture,
                                         self.boundProminentOverlay.tapTarget,
                                         self.boundProminentOverlay.tapAction);
            pt_scheduleRefreshForWindow(self.hostWindow);
            return;
        }
    }
    if (self.boundProminentTab) {
        [self activateModernTab:self.boundProminentTab];
    }
}

- (void)handleTabItemTap:(UIButton *)sender {
    UITabBarController *tabVC = self.activeTabBarController;
    if (!tabVC) {
        return;
    }
    NSUInteger idx = (NSUInteger)sender.tag;
    PTDuoTabSlotOverlay *ov = self.boundLegacySlotOverlays[@(idx)];
    if (ov && ov.actionControl) {
        pt_triggerControlAction(ov.actionControl);
        pt_scheduleRefreshForWindow(self.hostWindow);
        return;
    }
    if (ov && ov.tapTarget && ov.tapAction != NULL) {
        pt_dispatchVerifiedTapAction(ov.tapGesture, ov.tapTarget, ov.tapAction);
        pt_scheduleRefreshForWindow(self.hostWindow);
        return;
    }
    NSArray<UIViewController *> *vcs = tabVC.viewControllers;
    if (idx >= vcs.count) {
        return;
    }
    UIViewController *targetVC = vcs[idx];
    id<UITabBarControllerDelegate> delegate = tabVC.delegate;
    if (delegate && [delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)]) {
        if (![delegate tabBarController:tabVC shouldSelectViewController:targetVC]) {
            return;
        }
    }
    tabVC.selectedIndex = idx;
    if (delegate && [delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)]) {
        [delegate tabBarController:tabVC didSelectViewController:targetVC];
    }
    pt_scheduleRefreshForWindow(self.hostWindow);
}

- (void)handlePureActionOverlayTap:(UIButton *)sender {
    (void)sender;
    PTDuoTabSlotOverlay *ov = self.boundPureActionDockOverlay;
    if (!ov) {
        return;
    }
    if (ov.actionControl) {
        pt_triggerControlAction(ov.actionControl);
        pt_scheduleRefreshForWindow(self.hostWindow);
        return;
    }
    if (ov.tapTarget && ov.tapAction != NULL) {
        pt_dispatchVerifiedTapAction(ov.tapGesture, ov.tapTarget, ov.tapAction);
        pt_scheduleRefreshForWindow(self.hostWindow);
    }
}

static BOOL pt_duoImageIsBrightForeground(UIImage *img, double snapshotOpaqueRatio, double snapshotMinLuma) {
    if (!img || pt_imageIsOpaqueFilledBadge(img)) {
        return NO;
    }
    if (snapshotOpaqueRatio > 0.0 && snapshotOpaqueRatio < 0.70 && snapshotMinLuma > 0.65) {
        return YES;
    }
    return pt_imageNeedsTemplateTintOnGlass(img, NO) || pt_duoImageHasBrightForegroundOnTransparent(img);
}

static BOOL pt_duoEntryTriggersDarkContext(PTDuoBarItemEntry *entry, UITraitCollection *traits) {
    if (!entry) {
        return NO;
    }
    if (pt_duoColorIsBrightLight(entry.item.tintColor, traits)) {
        return YES;
    }
    if (pt_duoImageIsBrightForeground(entry.resolvedImage, entry.snapshotOpaqueRatio, entry.snapshotMinLuma)) {
        return YES;
    }
    if (entry.isOverflowMenu) {
        for (PTDuoBarItemEntry *sub in entry.overflowSubEntries) {
            if (pt_duoEntryTriggersDarkContext(sub, traits)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL pt_duoOverlayTriggersDarkContext(PTDuoTabSlotOverlay *ov, UITraitCollection *traits) {
    if (!ov || ov.accentBgColor != nil) {
        return NO;
    }
    if (pt_duoColorIsBrightLight(ov.accentTintColor, traits)) {
        return YES;
    }
    return pt_duoImageIsBrightForeground(ov.image, ov.snapshotOpaqueRatio, ov.snapshotMinLuma);
}

- (void)populateBarItemsPill:(PTDuoBarPillContainerView *)pill
                 withEntries:(NSArray<PTDuoBarItemEntry *> *)entries
                 startingTag:(NSInteger)startTag
                  isDarkMode:(BOOL)isDarkMode {
    for (UIView *v in [pill.stackView.arrangedSubviews copy]) {
        [pill.stackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    pill.hidden = (entries.count == 0);
    UIColor *pillNeutralFG = isDarkMode
        ? [UIColor colorWithWhite:0.96 alpha:1.0]
        : [UIColor colorWithWhite:0.10 alpha:1.0];
    for (NSUInteger i = 0; i < entries.count; i++) {
        PTDuoBarItemEntry *entry = entries[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.tag = startTag + (NSInteger)i;
        btn.layer.cornerRadius = 18.0;
        btn.layer.cornerCurve = kCACornerCurveContinuous;

        if (entry.isOverflowMenu) {
            btn.enabled = YES;
            btn.accessibilityLabel = @"More";
            if (@available(iOS 15.0, *)) {
                if ([btn respondsToSelector:@selector(setToolTip:)]) {
                    btn.toolTip = @"More";
                }
            }
            UIImageSymbolConfiguration *moreCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
            UIImage *moreImg = [UIImage systemImageNamed:@"ellipsis" withConfiguration:moreCfg];
            UIColor *moreTint = self.powerSavingMode ? pillNeutralFG : [UIColor labelColor];
            pt_configureRailButtonVisual(btn, moreImg, @"More", moreTint, UIEdgeInsetsMake(7.0, 7.0, 7.0, 7.0), 11.0, UIFontWeightMedium, isDarkMode, NO);
            if (@available(iOS 14.0, *)) {
                NSMutableArray<UIMenuElement *> *menuChildren = [NSMutableArray array];
                __weak PTDuoVerticalBarHostView *weakSelf = self;
                for (NSUInteger subIdx = 0; subIdx < entry.overflowSubEntries.count; subIdx++) {
                    PTDuoBarItemEntry *sub = entry.overflowSubEntries[subIdx];
                    UIBarButtonItem *subItem = sub.item;
                    NSString *subTitle = sub.resolvedTitle.length > 0 ? sub.resolvedTitle : (subItem.accessibilityLabel ?: [NSString stringWithFormat:@"Action %lu", (unsigned long)(subIdx + 1)]);
                    UIImage *subImg = sub.resolvedImage;
                    if (subItem.menu && !subItem.primaryAction && subItem.action == NULL) {
                        UIMenu *subMenu = subItem.menu;
                        if (subMenu.title.length == 0) {
                            subMenu = [UIMenu menuWithTitle:subTitle image:subImg identifier:nil options:0 children:subMenu.children];
                        }
                        [menuChildren addObject:subMenu];
                    } else {
                        UIAction *act = [UIAction actionWithTitle:subTitle image:subImg identifier:nil handler:^(__kindof UIAction *action) {
                            (void)action;
                            PTDuoVerticalBarHostView *strongSelf = weakSelf;
                            pt_executeBarItemEntry(sub, strongSelf ? strongSelf.hostWindow : nil);
                        }];
                        if (!sub.enabled) {
                            act.attributes = UIMenuElementAttributesDisabled;
                        }
                        if (sub.selected) {
                            act.state = UIMenuElementStateOn;
                        }
                        [menuChildren addObject:act];
                    }
                }
                btn.menu = [UIMenu menuWithTitle:@"" children:menuChildren];
                btn.showsMenuAsPrimaryAction = YES;
            }
        } else {
            UIBarButtonItem *item = entry.item;
            btn.enabled = entry.enabled;
            btn.selected = entry.selected;

            UIImage *img = entry.resolvedImage;
            NSString *title = entry.resolvedTitle;
            NSString *a11y = item.accessibilityLabel.length > 0 ? item.accessibilityLabel : (title.length > 0 ? title : @"Action");
            btn.accessibilityLabel = a11y;
            if (@available(iOS 15.0, *)) {
                if ([btn respondsToSelector:@selector(setToolTip:)]) {
                    btn.toolTip = (title.length > 0) ? title : item.accessibilityLabel;
                }
            }
            UIColor *tint = item.tintColor ?: (self.powerSavingMode ? pillNeutralFG : [UIColor labelColor]);
            if (self.powerSavingMode) {
                pt_duoResolvePowerSavingVisualContrast(&img, &tint, pillNeutralFG, isDarkMode, self.traitCollection);
            } else if (img && pt_imageNeedsTemplateTintOnGlass(img, isDarkMode)) {
                tint = [UIColor labelColor];
            }
            btn.backgroundColor = entry.selected ? [tint colorWithAlphaComponent:0.16] : [UIColor clearColor];
            pt_configureRailButtonVisual(btn, img, title, tint, UIEdgeInsetsMake(7.0, 7.0, 7.0, 7.0), 11.0, UIFontWeightMedium, isDarkMode, NO);
            if (img && entry.badgeText.length > 0) {
                UIView *dot = [[UIView alloc] init];
                dot.translatesAutoresizingMaskIntoConstraints = NO;
                dot.backgroundColor = [UIColor systemRedColor];
                dot.layer.cornerRadius = 3.5;
                dot.userInteractionEnabled = NO;
                [btn addSubview:dot];
                [NSLayoutConstraint activateConstraints:@[
                    [dot.widthAnchor constraintEqualToConstant:7.0],
                    [dot.heightAnchor constraintEqualToConstant:7.0],
                    [dot.topAnchor constraintEqualToAnchor:btn.topAnchor constant:6.0],
                    [dot.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:-6.0],
                ]];
            }

            if (@available(iOS 14.0, *)) {
                if (item.menu) {
                    btn.menu = item.menu;
                    btn.showsMenuAsPrimaryAction = (item.primaryAction == nil && item.action == NULL);
                }
            }
            [btn addTarget:self action:@selector(handleBarItemTap:) forControlEvents:UIControlEventTouchUpInside];
        }
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:36.0],
            [btn.heightAnchor constraintEqualToConstant:36.0],
        ]];
        [pill.stackView addArrangedSubview:btn];
    }
}

static UIColor *pt_resolvedContrastTintForAccentBg(UIColor *bgColor,
                                                      UIColor *candidateTint,
                                                      UIImage * __strong *ioImage) {
    UIColor *tint = candidateTint;
    CGFloat bgR = 0.0, bgG = 0.0, bgB = 0.0, bgA = 0.0;
    if (bgColor && [bgColor getRed:&bgR green:&bgG blue:&bgB alpha:&bgA]) {
        BOOL useFallback = (tint == nil);
        if (!useFallback) {
            CGFloat fgR = 0.0, fgG = 0.0, fgB = 0.0, fgA = 0.0;
            if ([tint getRed:&fgR green:&fgG blue:&fgB alpha:&fgA]) {
                useFallback = PTDuoShouldUseContrastFallbackForAccent(fgR, fgG, fgB, bgR, bgG, bgB);
            } else {
                useFallback = YES;
            }
        }
        if (useFallback) {
            tint = PTDuoShouldPreferWhiteOnAccentBackground(bgR, bgG, bgB)
                ? [UIColor whiteColor]
                : [UIColor blackColor];
            if (ioImage && *ioImage && !pt_imageIsOpaqueFilledBadge(*ioImage)) {
                *ioImage = [*ioImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }
        }
    }
    return tint ?: [UIColor whiteColor];
}

- (void)renderProminentOverlay:(PTDuoTabSlotOverlay *)ov isDarkMode:(BOOL)isDarkMode {
    self.prominentPill.hidden = NO;
    self.prominentButton.enabled = ov.actionControl ? ov.actionControl.enabled : YES;
    self.prominentButton.accessibilityLabel = ov.title.length > 0 ? ov.title : @"Action";
    [self.prominentButton setTitle:nil forState:UIControlStateNormal];

    UIImage *pImg = ov.image;
    BOOL filledBadge = (pImg && pt_imageIsOpaqueFilledBadge(pImg));
    if (filledBadge) {
        [self setProminentBackdropHidden:YES];
        self.prominentButton.backgroundColor = [UIColor clearColor];
        pt_configureRailButtonVisual(self.prominentButton, pImg, ov.title, nil, UIEdgeInsetsZero, 13.0, UIFontWeightSemibold, isDarkMode, YES);
    } else if (ov.accentBgColor != nil) {
        [self setProminentBackdropHidden:YES];
        self.prominentButton.backgroundColor = ov.accentBgColor;
        UIColor *tint = pt_resolvedContrastTintForAccentBg(ov.accentBgColor, ov.accentTintColor, &pImg);
        pt_configureRailButtonVisual(self.prominentButton, pImg, ov.title, tint, UIEdgeInsetsMake(9.0, 9.0, 9.0, 9.0), 13.0, UIFontWeightSemibold, isDarkMode, NO);
    } else {
        [self setProminentBackdropHidden:NO];
        self.prominentButton.backgroundColor = [UIColor clearColor];
        UIColor *pillNeutralFG = isDarkMode
            ? [UIColor colorWithWhite:0.96 alpha:1.0]
            : [UIColor colorWithWhite:0.10 alpha:1.0];
        UIColor *tint = ov.accentTintColor ?: (self.powerSavingMode ? pillNeutralFG : [UIColor labelColor]);
        if (self.powerSavingMode) {
            pt_duoResolvePowerSavingVisualContrast(&pImg, &tint, pillNeutralFG, isDarkMode, self.traitCollection);
        }
        pt_configureRailButtonVisual(self.prominentButton, pImg, ov.title, tint, UIEdgeInsetsMake(9.0, 9.0, 9.0, 9.0), 12.0, UIFontWeightSemibold, isDarkMode, NO);
    }
}

- (BOOL)syncWithWindow:(UIWindow *)window
             headerNav:(UINavigationController *)headerNav
            toolbarNav:(UINavigationController *)toolbarNav
                 tabVC:(UITabBarController *)tabVC
     allowSidebarCheck:(BOOL)allowSidebarCheck
      outHasAppSidebar:(BOOL *)outHasAppSidebar
outDetectedSidebarWidth:(CGFloat *)outDetectedSidebarWidth {
    if (outHasAppSidebar) {
        *outHasAppSidebar = NO;
    }
    if (outDetectedSidebarWidth) {
        *outDetectedSidebarWidth = 0.0;
    }
    self.hostWindow = window;
    CGRect targetFrame = CGRectMake(CGRectGetWidth(window.bounds) - kPTDuoVerticalBarWidth,
                                    0.0,
                                    kPTDuoVerticalBarWidth,
                                    CGRectGetHeight(window.bounds));
    if (!CGRectEqualToRect(self.frame, targetFrame)) {
        self.frame = targetFrame;
    }

    // Critical Auto-Yield Rule: if the app renders its own sidebar inside the right strip,
    // yield the synthetic host completely while preserving the right safe-area inset for the app sidebar.
    // Even when collapsed (allowSidebarCheck == NO), still check for late-mounted floating vertical rails
    // so custom floating vertical docks un-collapse cleanly without risking compact-button false positives.
    CGFloat detectedWidth = 0.0;
    if (pt_windowHasAppRenderedRightSidebar(window, self, !allowSidebarCheck, &detectedWidth)) {
        if (outHasAppSidebar) {
            *outHasAppSidebar = YES;
        }
        if (outDetectedSidebarWidth) {
            *outDetectedSidebarWidth = detectedWidth;
        }
        PTDuoWindowInsetState *st = pt_insetStateForWindow(window, NO);
        if (st) {
            st.lastTakeoverReason = "yieldedToAppSidebar";
        }
        [self hideAndRestore];
        return NO;
    }

    UINavigationController *effToolbarNav = toolbarNav ?: headerNav;
    UINavigationController *effHeaderNav = headerNav ?: toolbarNav;
    self.activeHeaderNavController = effHeaderNav;
    self.activeNavController = effToolbarNav;
    self.activeTabBarController = tabVC;

    BOOL navBarVisible = pt_navBarVisibleByApp(effHeaderNav);
    BOOL showBack = PTDuoShouldShowSyntheticBackButton(
        effHeaderNav != nil,
        !navBarVisible,
        effHeaderNav ? effHeaderNav.viewControllers.count : 0,
        pt_navItemAppWantsHidesBackButton(effHeaderNav.topViewController.navigationItem));

    PTDuoBarItemPlan *plan = pt_buildVerticalBarItemPlanForNavs(effHeaderNav, effToolbarNav, showBack);
    NSUInteger plannedEntryCount = plan.leadingEntries.count + plan.navBarEntries.count + plan.toolbarEntries.count;
    BOOL isDarkMode = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    // Check whether UITabBarController is eligible for vertical dock relocation (modern iOS 18+/27 tabs OR legacy tabBar.items)
    UITabBar *eligibleTabBar = nil;
    NSArray<id> *modernRegularTabs = nil;
    id modernProminentTab = nil;
    NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *modernOverlayByTabIdx = nil;
    PTDuoTabSlotOverlay *modernProminentOverlay = nil;
    NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *legacySlotOverlays = nil;
    PTDuoTabSlotOverlay *legacyProminentOverlay = nil;
    PTDuoTabSlotOverlay *pureActionDockOverlay = nil;
    BOOL hasModernRelocatableTabs = NO;
    BOOL hasRelocatableTabDock = NO;
    BOOL blockedByUnknownSlot = NO;

    if (tabVC) {
        BOOL navHidesBottomBar = NO;
        if (effToolbarNav && effToolbarNav.viewControllers.count > 1) {
            for (NSUInteger i = 1; i < effToolbarNav.viewControllers.count; i++) {
                if (effToolbarNav.viewControllers[i].hidesBottomBarWhenPushed) {
                    navHidesBottomBar = YES;
                    break;
                }
            }
        }
        BOOL tabBarHiddenByController = pt_tabBarControllerIsTabBarHidden(tabVC);
        UITabBar *tb = tabVC.tabBar;
        BOOL tabBarAppWantsHidden = NO;
        if (tb) {
            BOOL isAlreadyRelocated = [objc_getAssociatedObject(tb, kPTDuoTabBarRelocatedKey) boolValue];
            NSNumber *appHiddenNum = objc_getAssociatedObject(tb, kPTDuoTabBarAppHiddenKey);
            tabBarAppWantsHidden = isAlreadyRelocated ? (appHiddenNum ? appHiddenNum.boolValue : NO) : tb.hidden;
        }

        if (!navHidesBottomBar && !tabBarHiddenByController) {
            BOOL hasUnknownModernSlot = NO;
            if (pt_collectModernTabsWithOptions(tabVC,
                                                isDarkMode,
                                                &modernRegularTabs,
                                                &modernProminentTab,
                                                &modernOverlayByTabIdx,
                                                &modernProminentOverlay,
                                                &hasUnknownModernSlot)) {
                BOOL hasFloatingChrome = (self.relocatedTabBarChromeViews.count > 0)
                    || (pt_collectFloatingTabBarChromeViews(tabVC).count > 0);
                if (!tabBarAppWantsHidden || hasFloatingChrome) {
                    hasModernRelocatableTabs = YES;
                    hasRelocatableTabDock = YES;
                    eligibleTabBar = tb;
                    if (tb && modernOverlayByTabIdx.count == 0 && !modernProminentOverlay) {
                        PTDuoTabSlotOverlay *extraOv = pt_discoverPureActionTabOverlay(tabVC,
                                                                                        tb,
                                                                                        modernRegularTabs.count + (modernProminentTab ? 1 : 0),
                                                                                        (modernProminentTab != nil),
                                                                                        isDarkMode);
                        if (extraOv) {
                            if (extraOv.promoteToProminent && !modernProminentTab) {
                                modernProminentOverlay = extraOv;
                            } else {
                                pureActionDockOverlay = extraOv;
                            }
                        }
                    }
                }
            } else if (hasUnknownModernSlot) {
                blockedByUnknownSlot = YES;
            } else if (tb && tb.items.count >= 2 && !tabBarAppWantsHidden && !pt_duoTabBarIsCustomReplacement(tb)) {
                NSArray<UITabBarItem *> *legacyItems = tb.items;
                BOOL hasUnknownLegacySlot = NO;
                legacySlotOverlays = pt_discoverBlankSlotOverlaysWithOptions(tabVC, tb, legacyItems.count, ^BOOL(NSUInteger idx) {
                    UITabBarItem *ti = legacyItems[idx];
                    BOOL isSel = (tabVC.selectedIndex == idx);
                    return PTDuoTabItemSlotNeedsOverlay(isSel,
                                                        ti.selectedImage != nil,
                                                        pt_imageIsPlaceholderBlank(ti.selectedImage),
                                                        pt_imageIsPlaceholderBlank(ti.image),
                                                        pt_stringIsEffectivelyBlank(ti.title));
                }, NO, isDarkMode, &hasUnknownLegacySlot);
                if (PTDuoCanSafelyRelocateTabDock(hasUnknownLegacySlot, legacyItems.count)) {
                    hasRelocatableTabDock = YES;
                    eligibleTabBar = tb;
                    for (NSNumber *slotKey in [[legacySlotOverlays allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                        PTDuoTabSlotOverlay *ov = legacySlotOverlays[slotKey];
                        if (ov && ov.promoteToProminent) {
                            legacyProminentOverlay = ov;
                            break;
                        }
                    }
                    if (legacySlotOverlays.count == 0) {
                        PTDuoTabSlotOverlay *extraOv = pt_discoverPureActionTabOverlay(tabVC, tb, legacyItems.count, NO, isDarkMode);
                        if (extraOv) {
                            if (extraOv.promoteToProminent) {
                                legacyProminentOverlay = extraOv;
                            } else {
                                pureActionDockOverlay = extraOv;
                            }
                        }
                    }
                } else if (hasUnknownLegacySlot) {
                    blockedByUnknownSlot = YES;
                }
            }
        }
    }

    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(window, NO);
    if (insetState) {
        insetState.lastTabDockBlockedByUnknownSlot = blockedByUnknownSlot;
        if (hasRelocatableTabDock) {
            insetState.unknownSlotRetryCount = 0;
        } else if (blockedByUnknownSlot && insetState.unknownSlotRetryCount < 2) {
            insetState.unknownSlotRetryCount += 1;
            NSUInteger capturedRetryEpoch = insetState.epoch;
            __weak UIWindow *weakRetryWin = window;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIWindow *strongWin = weakRetryWin;
                if (!strongWin) {
                    return;
                }
                PTDuoWindowInsetState *st = pt_insetStateForWindow(strongWin, NO);
                if (st && st.epoch == capturedRetryEpoch && st.lastTabDockBlockedByUnknownSlot) {
                    pt_refreshDuoVerticalBarForWindow(strongWin);
                }
            });
        }
    }

    BOOL suppressSidebarEmptyTabBarForToolbar = (!hasRelocatableTabDock
                                                 && tabVC != nil
                                                 && tabVC.tabBar != nil
                                                 && plan.toolbarEntries.count > 0
                                                 && !plan.hasUnmirroredToolbarItems
                                                 && pt_collectVisibleSystemTabButtonCenters(tabVC.tabBar, tabVC, NULL, NULL).count == 0);
    UITabBar *tabBarToSuppress = hasRelocatableTabDock ? eligibleTabBar : (suppressSidebarEmptyTabBarForToolbar ? tabVC.tabBar : nil);

    if (!tabBarToSuppress || (self.relocatedTabBar && self.relocatedTabBar != tabBarToSuppress)) {
        [self restoreRelocatedTabBarIfNeeded];
    }

    if (!showBack && plannedEntryCount == 0 && !hasRelocatableTabDock) {
        if (insetState) {
            insetState.lastTakeoverReason = blockedByUnknownSlot ? "keptOriginalDockUnknownSlot" : "noVerticalBarItems";
        }
        self.lastItemPlan = plan;
        [self hideAndRestore];
        return NO;
    }

    [self syncSuppressedNavChromeForHeaderNav:effHeaderNav
                                   toolbarNav:effToolbarNav
                                        tabVC:tabVC
                           includeOrphanDock:!hasRelocatableTabDock
                                     showBack:showBack
                                         plan:plan];

    UIColor *prominentBgColor = nil;
    UIColor *prominentTintColor = nil;
    if (hasRelocatableTabDock || suppressSidebarEmptyTabBarForToolbar) {
        if (hasModernRelocatableTabs && modernProminentTab) {
            // Inspect live _UITabBarAuxiliaryView style before hiding bottom chrome.
            pt_extractProminentStyleFromTabBarController(tabVC, &prominentBgColor, &prominentTintColor);
        }
        if (tabBarToSuppress) {
            pt_setTabBarRelocatedHidden(tabBarToSuppress, YES);
            self.relocatedTabBar = tabBarToSuppress;
        }
        if (hasRelocatableTabDock) {
            [self suppressFloatingTabBarChromeForTabVC:tabVC];
        }
        self.hasRelocatedTabBar = hasRelocatableTabDock;
    }

    PTDuoTabSlotOverlay *effectiveProminentOverlay = hasModernRelocatableTabs ? modernProminentOverlay : legacyProminentOverlay;

    BOOL contextDark = isDarkMode;
    if (!contextDark && self.powerSavingMode) {
        UIViewController *headerTopVC = effHeaderNav.topViewController;
        UIViewController *toolbarTopVC = effToolbarNav.topViewController;
        if (headerTopVC.preferredStatusBarStyle == UIStatusBarStyleLightContent
            || toolbarTopVC.preferredStatusBarStyle == UIStatusBarStyleLightContent
            || effHeaderNav.navigationBar.barStyle == UIBarStyleBlack
            || effToolbarNav.navigationBar.barStyle == UIBarStyleBlack
            || headerTopVC.overrideUserInterfaceStyle == UIUserInterfaceStyleDark
            || toolbarTopVC.overrideUserInterfaceStyle == UIUserInterfaceStyleDark
            || (tabVC && tabVC.overrideUserInterfaceStyle == UIUserInterfaceStyleDark)) {
            contextDark = YES;
        }
        if (!contextDark && (pt_duoColorIsBrightLight(effHeaderNav.navigationBar.tintColor, self.traitCollection)
                             || pt_duoColorIsBrightLight(effToolbarNav.navigationBar.tintColor, self.traitCollection)
                             || pt_duoColorIsBrightLight(prominentTintColor, self.traitCollection)
                             || pt_duoColorIsBrightLight(eligibleTabBar.tintColor, self.traitCollection))) {
            contextDark = YES;
        }
        if (!contextDark) {
            for (PTDuoBarItemEntry *entry in plan.leadingEntries) {
                if (pt_duoEntryTriggersDarkContext(entry, self.traitCollection)) { contextDark = YES; break; }
            }
        }
        if (!contextDark) {
            for (PTDuoBarItemEntry *entry in plan.navBarEntries) {
                if (pt_duoEntryTriggersDarkContext(entry, self.traitCollection)) { contextDark = YES; break; }
            }
        }
        if (!contextDark) {
            for (PTDuoBarItemEntry *entry in plan.toolbarEntries) {
                if (pt_duoEntryTriggersDarkContext(entry, self.traitCollection)) { contextDark = YES; break; }
            }
        }
        if (!contextDark) {
            if (pt_duoOverlayTriggersDarkContext(effectiveProminentOverlay, self.traitCollection)
                || pt_duoOverlayTriggersDarkContext(pureActionDockOverlay, self.traitCollection)) {
                contextDark = YES;
            }
        }
        if (!contextDark) {
            NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *activeOverlays = hasModernRelocatableTabs ? modernOverlayByTabIdx : legacySlotOverlays;
            for (PTDuoTabSlotOverlay *ov in [activeOverlays allValues]) {
                if (pt_duoOverlayTriggersDarkContext(ov, self.traitCollection)) {
                    contextDark = YES;
                    break;
                }
            }
        }
    }

    if (self.powerSavingMode) {
        NSNumber *darkOverride = @(contextDark);
        self.backPill.forcedDarkSurface = darkOverride;
        self.leadingPill.forcedDarkSurface = darkOverride;
        self.itemsPill.forcedDarkSurface = darkOverride;
        self.toolbarPill.forcedDarkSurface = darkOverride;
        self.dockPill.forcedDarkSurface = darkOverride;
        self.forcedDarkSurface = darkOverride;
    } else {
        self.backPill.forcedDarkSurface = nil;
        self.leadingPill.forcedDarkSurface = nil;
        self.itemsPill.forcedDarkSurface = nil;
        self.toolbarPill.forcedDarkSurface = nil;
        self.dockPill.forcedDarkSurface = nil;
        self.forcedDarkSurface = nil;
    }

    // Build compact signature to avoid unnecessary view churn
    NSMutableString *sig = [NSMutableString stringWithFormat:@"d:%d|cd:%d|b:%d|l:", isDarkMode ? 1 : 0, contextDark ? 1 : 0, showBack ? 1 : 0];
    void (^appendEntrySig)(PTDuoBarItemEntry *) = ^(PTDuoBarItemEntry *entry) {
        if (entry.isOverflowMenu) {
            [sig appendFormat:@"ov:%lu[", (unsigned long)entry.overflowSubEntries.count];
            for (PTDuoBarItemEntry *sub in entry.overflowSubEntries) {
                UIBarButtonItem *si = sub.item;
                [sig appendFormat:@"%p:%d:%d:%@:%p:%@:%@:%s:%p:%p:%p:%p:%p:%s,",
                 si,
                 sub.enabled ? 1 : 0,
                 sub.selected ? 1 : 0,
                 sub.resolvedTitle ?: @"",
                 sub.resolvedImage,
                 sub.badgeText ?: @"",
                 si.accessibilityLabel ?: @"",
                 si.action ? sel_getName(si.action) : "",
                 si.target,
                 si.primaryAction,
                 si.menu,
                 sub.actionControl,
                 sub.tapTarget,
                 sub.tapAction ? sel_getName(sub.tapAction) : ""];
            }
            [sig appendString:@"],"];
        } else {
            UIBarButtonItem *item = entry.item;
            UIImage *cvImg = entry.resolvedImage;
            [sig appendFormat:@"%p:%d:%d:%@:%p:%@:%@:%s:%p:%p:%p:%p:%p:%s,",
             item,
             entry.enabled ? 1 : 0,
             entry.selected ? 1 : 0,
             entry.resolvedTitle ?: @"",
             cvImg,
             entry.badgeText ?: @"",
             item.accessibilityLabel ?: @"",
             item.action ? sel_getName(item.action) : "",
             item.target,
             item.primaryAction,
             item.menu,
             entry.actionControl,
             entry.tapTarget,
             entry.tapAction ? sel_getName(entry.tapAction) : ""];
        }
    };
    for (PTDuoBarItemEntry *entry in plan.leadingEntries) { appendEntrySig(entry); }
    [sig appendString:@"|n:"];
    for (PTDuoBarItemEntry *entry in plan.navBarEntries) { appendEntrySig(entry); }
    [sig appendString:@"|tb:"];
    for (PTDuoBarItemEntry *entry in plan.toolbarEntries) { appendEntrySig(entry); }

    if (hasModernRelocatableTabs) {
        id selectedTab = pt_tabBarControllerSelectedTab(tabVC);
        [sig appendFormat:@"|mt:%p:s:%p:%@|r:", tabVC, selectedTab, pt_tabIdentifier(selectedTab) ?: @""];
        for (NSUInteger i = 0; i < modernRegularTabs.count; i++) {
            id tab = modernRegularTabs[i];
            UIImage *tImg = pt_tabImage(tab);
            UIImage *tSelImg = pt_tabSelectedImage(tab);
            PTDuoTabSlotOverlay *ov = modernOverlayByTabIdx[@(i)];
            [sig appendFormat:@"%p:%@:%@:%d:%@:%p:%p:%p:%@:%d:%p:%p:%s,",
             tab,
             pt_tabIdentifier(tab) ?: @"",
             pt_tabTitle(tab) ?: @"",
             pt_tabIsEnabled(tab) ? 1 : 0,
             pt_tabBadgeValue(tab) ?: @"",
             tImg,
             tSelImg,
             ov ? ov.image : nil,
             ov ? (ov.title ?: @"") : @"",
             (ov && ov.isSnapshot) ? 1 : 0,
             ov ? ov.actionControl : nil,
             ov ? ov.tapTarget : nil,
             (ov && ov.tapAction) ? sel_getName(ov.tapAction) : ""];
        }
        if (modernProminentTab) {
            [sig appendFormat:@"|p:%p:%@:%d:%p:%p:%p",
             modernProminentTab,
             pt_tabIdentifier(modernProminentTab) ?: @"",
             pt_tabIsEnabled(modernProminentTab) ? 1 : 0,
             pt_tabImage(modernProminentTab),
             prominentBgColor,
             prominentTintColor];
        } else if (modernProminentOverlay) {
            [sig appendFormat:@"|po:%lu:%p:%@:%d:%p:%p:%p:%p:%s",
             (unsigned long)modernProminentOverlay.slotIndex,
             modernProminentOverlay.image,
             modernProminentOverlay.title ?: @"",
             modernProminentOverlay.isSnapshot ? 1 : 0,
             modernProminentOverlay.accentBgColor,
             modernProminentOverlay.accentTintColor,
             modernProminentOverlay.actionControl,
             modernProminentOverlay.tapTarget,
             modernProminentOverlay.tapAction ? sel_getName(modernProminentOverlay.tapAction) : ""];
        }
    } else if (hasRelocatableTabDock && eligibleTabBar) {
        [sig appendFormat:@"|t:%p:%lu:%lu:", eligibleTabBar,
         (unsigned long)eligibleTabBar.items.count,
         (unsigned long)tabVC.selectedIndex];
        for (NSUInteger i = 0; i < eligibleTabBar.items.count; i++) {
            UITabBarItem *ti = eligibleTabBar.items[i];
            PTDuoTabSlotOverlay *ov = legacySlotOverlays[@(i)];
            [sig appendFormat:@"%@:%p:%p:%p:%@:%d:%p:%p:%s,",
             ti.title ?: @"",
             ti.image,
             ti.selectedImage,
             ov ? ov.image : nil,
             ov ? (ov.title ?: @"") : @"",
             (ov && ov.isSnapshot) ? 1 : 0,
             ov ? ov.actionControl : nil,
             ov ? ov.tapTarget : nil,
             (ov && ov.tapAction) ? sel_getName(ov.tapAction) : ""];
        }
        if (legacyProminentOverlay) {
            [sig appendFormat:@"|lpo:%lu:%p:%@:%d:%p:%p:%p:%p:%s",
             (unsigned long)legacyProminentOverlay.slotIndex,
             legacyProminentOverlay.image,
             legacyProminentOverlay.title ?: @"",
             legacyProminentOverlay.isSnapshot ? 1 : 0,
             legacyProminentOverlay.accentBgColor,
             legacyProminentOverlay.accentTintColor,
             legacyProminentOverlay.actionControl,
             legacyProminentOverlay.tapTarget,
             legacyProminentOverlay.tapAction ? sel_getName(legacyProminentOverlay.tapAction) : ""];
        }
    }
    if (pureActionDockOverlay) {
        [sig appendFormat:@"|pao:%lu:%p:%@:%d:%p:%p:%p:%p:%s",
         (unsigned long)pureActionDockOverlay.slotIndex,
         pureActionDockOverlay.image,
         pureActionDockOverlay.title ?: @"",
         pureActionDockOverlay.isSnapshot ? 1 : 0,
         pureActionDockOverlay.accentBgColor,
         pureActionDockOverlay.accentTintColor,
         pureActionDockOverlay.actionControl,
         pureActionDockOverlay.tapTarget,
         pureActionDockOverlay.tapAction ? sel_getName(pureActionDockOverlay.tapAction) : ""];
    }

    self.lastItemPlan = plan;
    if (![sig isEqualToString:self.lastRenderSignature]) {
        os_log_t spLog = pt_duoSignpostLog();
        os_signpost_id_t spId = os_signpost_id_make_with_pointer(spLog, (__bridge const void *)self);
        os_signpost_interval_begin(spLog, spId, "HostRebuild");
        CFTimeInterval t0 = CACurrentMediaTime();

        self.lastRenderSignature = sig;
        NSMutableArray<UIBarButtonItem *> *combinedBound = [NSMutableArray array];
        [combinedBound addObjectsFromArray:plan.mirroredLeadingItems];
        [combinedBound addObjectsFromArray:plan.mirroredNavBarItems];
        [combinedBound addObjectsFromArray:plan.mirroredToolbarItems];
        self.boundBarItems = combinedBound;
        NSMutableArray<PTDuoBarItemEntry *> *combinedEntries = [NSMutableArray array];
        [combinedEntries addObjectsFromArray:plan.leadingEntries];
        [combinedEntries addObjectsFromArray:plan.navBarEntries];
        [combinedEntries addObjectsFromArray:plan.toolbarEntries];
        self.boundItemEntries = combinedEntries;
        self.boundModernTabs = hasModernRelocatableTabs ? modernRegularTabs : @[];
        self.boundProminentTab = hasModernRelocatableTabs ? modernProminentTab : nil;
        self.boundModernSlotOverlays = hasModernRelocatableTabs ? (modernOverlayByTabIdx ?: @{}) : @{};
        self.boundLegacySlotOverlays = hasModernRelocatableTabs ? @{} : (legacySlotOverlays ?: @{});
        self.boundProminentOverlay = effectiveProminentOverlay;
        self.boundPureActionDockOverlay = pureActionDockOverlay;
        self.usingModernTabs = hasModernRelocatableTabs;
        [self rebuildPillsWithShowBack:showBack
                        leadingEntries:plan.leadingEntries
                         navBarEntries:plan.navBarEntries
                        toolbarEntries:plan.toolbarEntries
                                 tabVC:hasRelocatableTabDock ? tabVC : nil
                                tabBar:eligibleTabBar
                            modernTabs:hasModernRelocatableTabs ? modernRegularTabs : nil
                    modernSlotOverlays:hasModernRelocatableTabs ? modernOverlayByTabIdx : nil
                    legacySlotOverlays:hasModernRelocatableTabs ? nil : legacySlotOverlays
                          prominentTab:hasModernRelocatableTabs ? modernProminentTab : nil
                      prominentOverlay:effectiveProminentOverlay
                 pureActionDockOverlay:pureActionDockOverlay
                      prominentBgColor:prominentBgColor
                    prominentTintColor:prominentTintColor];
        if (insetState) {
            insetState.lastRebuildDurationMs = (CACurrentMediaTime() - t0) * 1000.0;
        }
        os_signpost_interval_end(spLog, spId, "HostRebuild", "items=%lu dock=%d", (unsigned long)combinedEntries.count, hasRelocatableTabDock ? 1 : 0);
    }

    if (insetState) {
        insetState.lastTakeoverReason = hasRelocatableTabDock ? "syntheticRailWithTabDock" : "syntheticNavBarRail";
    }
    self.hidden = NO;
    if (window.subviews.lastObject != self) {
        [window bringSubviewToFront:self];
    }
    return YES;
}

- (UIButton *)makePureActionDockButton:(PTDuoTabSlotOverlay *)ov isDarkMode:(BOOL)isDarkMode {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.enabled = ov.actionControl ? ov.actionControl.enabled : YES;
    btn.layer.cornerRadius = 18.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.backgroundColor = [UIColor clearColor];
    NSString *title = !pt_stringIsEffectivelyBlank(ov.title) ? ov.title : nil;
    btn.accessibilityLabel = title.length > 0 ? title : @"Action";
    UIColor *pillNeutralFG = isDarkMode
        ? [UIColor colorWithWhite:0.96 alpha:1.0]
        : [UIColor colorWithWhite:0.10 alpha:1.0];
    UIImage *img = ov.image;
    UIColor *tint = ov.accentTintColor ?: (self.powerSavingMode ? pillNeutralFG : [UIColor secondaryLabelColor]);
    if (self.powerSavingMode) {
        pt_duoResolvePowerSavingVisualContrast(&img, &tint, pillNeutralFG, isDarkMode, self.traitCollection);
    }
    pt_configureRailButtonVisual(btn, img, title, tint, UIEdgeInsetsMake(6.0, 6.0, 6.0, 6.0), 11.0, UIFontWeightMedium, isDarkMode, NO);
    [btn addTarget:self action:@selector(handlePureActionOverlayTap:) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [btn.widthAnchor constraintEqualToConstant:36.0],
        [btn.heightAnchor constraintEqualToConstant:36.0],
    ]];
    return btn;
}

- (void)rebuildPillsWithShowBack:(BOOL)showBack
                  leadingEntries:(NSArray<PTDuoBarItemEntry *> *)leadingEntries
                   navBarEntries:(NSArray<PTDuoBarItemEntry *> *)navBarEntries
                  toolbarEntries:(NSArray<PTDuoBarItemEntry *> *)toolbarEntries
                           tabVC:(UITabBarController *)tabVC
                          tabBar:(UITabBar *)tabBar
                      modernTabs:(NSArray<id> *)modernTabs
              modernSlotOverlays:(NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *)modernSlotOverlays
              legacySlotOverlays:(NSDictionary<NSNumber *, PTDuoTabSlotOverlay *> *)legacySlotOverlays
                    prominentTab:(id)prominentTab
                prominentOverlay:(PTDuoTabSlotOverlay *)prominentOverlay
           pureActionDockOverlay:(PTDuoTabSlotOverlay *)pureActionDockOverlay
                prominentBgColor:(UIColor *)prominentBgColor
              prominentTintColor:(UIColor *)prominentTintColor {
    self.backPill.hidden = !showBack;
    BOOL isDarkMode = self.powerSavingMode
        ? (self.forcedDarkSurface ? self.forcedDarkSurface.boolValue : (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark))
        : (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIColor *pillNeutralFG = isDarkMode
        ? [UIColor colorWithWhite:0.96 alpha:1.0]
        : [UIColor colorWithWhite:0.10 alpha:1.0];
    self.backButton.tintColor = self.powerSavingMode ? pillNeutralFG : [UIColor labelColor];

    NSInteger tagOffset = 0;
    [self populateBarItemsPill:self.leadingPill withEntries:leadingEntries startingTag:tagOffset isDarkMode:isDarkMode];
    tagOffset += (NSInteger)leadingEntries.count;
    [self populateBarItemsPill:self.itemsPill withEntries:navBarEntries startingTag:tagOffset isDarkMode:isDarkMode];
    tagOffset += (NSInteger)navBarEntries.count;
    [self populateBarItemsPill:self.toolbarPill withEntries:toolbarEntries startingTag:tagOffset isDarkMode:isDarkMode];

    // Rebuild vertical dock pill for UITabBarController (modern UITab[] OR legacy UITabBarItem[])
    for (UIView *v in [self.dockPill.stackView.arrangedSubviews copy]) {
        [self.dockPill.stackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    UIColor *activeTint = (tabBar && tabBar.tintColor) ? tabBar.tintColor : [UIColor labelColor];
    if (tabVC && modernTabs != nil) {
        BOOL showDock = (modernTabs.count > 0);
        self.dockPill.hidden = !showDock;
        id selectedTab = pt_tabBarControllerSelectedTab(tabVC);
        NSString *selectedId = pt_tabIdentifier(selectedTab);

        for (NSUInteger i = 0; i < modernTabs.count; i++) {
            if (pureActionDockOverlay && pureActionDockOverlay.slotIndex == i) {
                [self.dockPill.stackView addArrangedSubview:[self makePureActionDockButton:pureActionDockOverlay isDarkMode:isDarkMode]];
            }
            id tab = modernTabs[i];
            PTDuoTabSlotOverlay *ov = modernSlotOverlays[@(i)];
            NSString *tid = pt_tabIdentifier(tab);
            BOOL isSelected = (selectedTab == tab)
                || (selectedId.length > 0 && tid.length > 0 && [selectedId isEqualToString:tid]);

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.translatesAutoresizingMaskIntoConstraints = NO;
            btn.tag = (NSInteger)i;
            btn.enabled = ov ? (ov.actionControl ? ov.actionControl.enabled : YES) : pt_tabIsEnabled(tab);
            btn.layer.cornerRadius = 18.0;
            btn.layer.cornerCurve = kCACornerCurveContinuous;
            btn.backgroundColor = isSelected ? [activeTint colorWithAlphaComponent:0.14] : [UIColor clearColor];
            UIColor *tint = isSelected ? activeTint : (self.powerSavingMode ? pillNeutralFG : [UIColor secondaryLabelColor]);
            NSString *title = pt_tabTitle(tab);
            if (pt_stringIsEffectivelyBlank(title)) {
                title = (ov && !pt_stringIsEffectivelyBlank(ov.title)) ? ov.title : nil;
            }
            btn.accessibilityLabel = title.length > 0 ? title : (tid.length > 0 ? tid : [NSString stringWithFormat:@"Tab %lu", (unsigned long)(i + 1)]);

            UIImage *selImg = pt_tabSelectedImage(tab);
            UIImage *baseImg = pt_tabImage(tab);
            UIImage *selCandidate = !pt_imageIsPlaceholderBlank(selImg) ? selImg : nil;
            UIImage *baseCandidate = !pt_imageIsPlaceholderBlank(baseImg) ? baseImg : nil;
            UIImage *img = isSelected
                ? (selCandidate ?: ((selImg != nil && ov && ov.image) ? ov.image : (baseCandidate ?: (ov ? ov.image : nil))))
                : (baseCandidate ?: (ov ? ov.image : nil));
            if (!img && pt_tabIsSearchTab(tab)) {
                UIImageSymbolConfiguration *searchCfg = [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightMedium];
                img = [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:searchCfg];
            }
            if (self.powerSavingMode) {
                pt_duoResolvePowerSavingVisualContrast(&img, &tint, pillNeutralFG, isDarkMode, self.traitCollection);
            }
            pt_configureRailButtonVisual(btn, img, title, tint, UIEdgeInsetsMake(6.0, 6.0, 6.0, 6.0), 11.0, isSelected ? UIFontWeightSemibold : UIFontWeightRegular, isDarkMode, NO);

            NSString *badge = pt_tabBadgeValue(tab);
            if (badge.length > 0) {
                UIView *dot = [[UIView alloc] init];
                dot.translatesAutoresizingMaskIntoConstraints = NO;
                dot.backgroundColor = [UIColor systemRedColor];
                dot.layer.cornerRadius = 3.5;
                dot.userInteractionEnabled = NO;
                [btn addSubview:dot];
                [NSLayoutConstraint activateConstraints:@[
                    [dot.widthAnchor constraintEqualToConstant:7.0],
                    [dot.heightAnchor constraintEqualToConstant:7.0],
                    [dot.topAnchor constraintEqualToAnchor:btn.topAnchor constant:6.0],
                    [dot.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:-6.0],
                ]];
            }

            [btn addTarget:self action:@selector(handleModernTabTap:) forControlEvents:UIControlEventTouchUpInside];
            [NSLayoutConstraint activateConstraints:@[
                [btn.widthAnchor constraintEqualToConstant:36.0],
                [btn.heightAnchor constraintEqualToConstant:36.0],
            ]];
            [self.dockPill.stackView addArrangedSubview:btn];
        }
        if (pureActionDockOverlay && pureActionDockOverlay.slotIndex >= modernTabs.count) {
            [self.dockPill.stackView addArrangedSubview:[self makePureActionDockButton:pureActionDockOverlay isDarkMode:isDarkMode]];
        }

        // Separate circular prominent pill directly underneath dockPill (prominentTabIdentifier, UISearchTab, or promoted overlay)
        if (prominentTab) {
            self.prominentPill.hidden = NO;
            NSString *pId = pt_tabIdentifier(prominentTab);
            NSString *pTitle = pt_tabTitle(prominentTab);
            BOOL pSelected = (selectedTab == prominentTab)
                || (selectedId.length > 0 && pId.length > 0 && [selectedId isEqualToString:pId]);

            self.prominentButton.enabled = pt_tabIsEnabled(prominentTab);
            self.prominentButton.accessibilityLabel = pTitle.length > 0 ? pTitle : (pId.length > 0 ? pId : @"Action");
            [self.prominentButton setTitle:nil forState:UIControlStateNormal];

            UIImage *pSelImg = pt_tabSelectedImage(prominentTab);
            UIImage *pImg = (pSelected && pSelImg) ? pSelImg : pt_tabImage(prominentTab);
            if (!pImg && pt_tabIsSearchTab(prominentTab)) {
                UIImageSymbolConfiguration *searchCfg = [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightMedium];
                pImg = [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:searchCfg];
            }

            if (pImg && pt_imageIsOpaqueFilledBadge(pImg)) {
                // Filled circular badge image (e.g. accented circular '+' icon) fills the circular pill cleanly.
                [self setProminentBackdropHidden:YES];
                self.prominentButton.backgroundColor = [UIColor clearColor];
                pt_configureRailButtonVisual(self.prominentButton, pImg, pTitle, nil, UIEdgeInsetsZero, 13.0, UIFontWeightSemibold, isDarkMode, YES);
            } else if (prominentBgColor != nil) {
                // Accent-colored circular button mirroring _UITabBarAuxiliaryView's explicit background.
                [self setProminentBackdropHidden:YES];
                self.prominentButton.backgroundColor = prominentBgColor;
                UIColor *tint = pt_resolvedContrastTintForAccentBg(prominentBgColor, prominentTintColor, &pImg);
                pt_configureRailButtonVisual(self.prominentButton, pImg, pTitle, tint, UIEdgeInsetsMake(9.0, 9.0, 9.0, 9.0), 13.0, UIFontWeightSemibold, isDarkMode, NO);
            } else {
                // Translucent glass circular pill (e.g. UISearchTab or monochrome prominent tab).
                [self setProminentBackdropHidden:NO];
                self.prominentButton.backgroundColor = pSelected ? [activeTint colorWithAlphaComponent:0.16] : [UIColor clearColor];
                UIColor *tint = pSelected ? activeTint : (prominentTintColor ?: (self.powerSavingMode ? pillNeutralFG : [UIColor labelColor]));
                if (self.powerSavingMode) {
                    pt_duoResolvePowerSavingVisualContrast(&pImg, &tint, pillNeutralFG, isDarkMode, self.traitCollection);
                }
                pt_configureRailButtonVisual(self.prominentButton, pImg, pTitle, tint, UIEdgeInsetsMake(9.0, 9.0, 9.0, 9.0), 12.0, UIFontWeightSemibold, isDarkMode, NO);
            }
        } else if (prominentOverlay) {
            [self renderProminentOverlay:prominentOverlay isDarkMode:isDarkMode];
        } else {
            self.prominentPill.hidden = YES;
        }
    } else {
        BOOL showDock = (tabVC != nil && tabBar != nil && tabBar.items.count >= 2);
        self.dockPill.hidden = !showDock;
        if (showDock) {
            NSArray<UITabBarItem *> *items = tabBar.items;
            NSUInteger maxTabs = MIN(items.count, (NSUInteger)6);
            UIColor *legacyTint = tabBar.tintColor ?: [UIColor systemBlueColor];
            for (NSUInteger i = 0; i < maxTabs; i++) {
                if (pureActionDockOverlay && pureActionDockOverlay.slotIndex == i) {
                    [self.dockPill.stackView addArrangedSubview:[self makePureActionDockButton:pureActionDockOverlay isDarkMode:isDarkMode]];
                }
                UITabBarItem *ti = items[i];
                PTDuoTabSlotOverlay *ov = legacySlotOverlays[@(i)];
                if (prominentOverlay && ov == prominentOverlay) {
                    // Promoted circular accent button renders in prominentPill instead of leaving an inline hole.
                    continue;
                }
                BOOL isSelected = (tabVC.selectedIndex == i);

                UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
                btn.translatesAutoresizingMaskIntoConstraints = NO;
                btn.tag = (NSInteger)i;
                btn.enabled = ov ? (ov.actionControl ? ov.actionControl.enabled : YES) : ti.enabled;
                btn.layer.cornerRadius = 18.0;
                btn.layer.cornerCurve = kCACornerCurveContinuous;
                btn.backgroundColor = isSelected ? [legacyTint colorWithAlphaComponent:0.18] : [UIColor clearColor];
                UIColor *tint = isSelected ? legacyTint : (self.powerSavingMode ? pillNeutralFG : [UIColor secondaryLabelColor]);
                NSString *title = !pt_stringIsEffectivelyBlank(ti.title)
                    ? ti.title
                    : (!pt_stringIsEffectivelyBlank(ov.title) ? ov.title : @"");
                btn.accessibilityLabel = title.length > 0 ? title : [NSString stringWithFormat:@"Tab %lu", (unsigned long)(i + 1)];

                UIImage *selCandidate = !pt_imageIsPlaceholderBlank(ti.selectedImage) ? ti.selectedImage : nil;
                UIImage *baseCandidate = !pt_imageIsPlaceholderBlank(ti.image) ? ti.image : nil;
                UIImage *img = isSelected
                    ? (selCandidate ?: ((ti.selectedImage != nil && ov && ov.image) ? ov.image : (baseCandidate ?: (ov ? ov.image : nil))))
                    : (baseCandidate ?: (ov ? ov.image : nil));
                if (self.powerSavingMode) {
                    pt_duoResolvePowerSavingVisualContrast(&img, &tint, pillNeutralFG, isDarkMode, self.traitCollection);
                }
                pt_configureRailButtonVisual(btn, img, title, tint, UIEdgeInsetsMake(6.0, 6.0, 6.0, 6.0), 11.0, isSelected ? UIFontWeightSemibold : UIFontWeightRegular, isDarkMode, NO);

                [btn addTarget:self action:@selector(handleTabItemTap:) forControlEvents:UIControlEventTouchUpInside];
                [NSLayoutConstraint activateConstraints:@[
                    [btn.widthAnchor constraintEqualToConstant:36.0],
                    [btn.heightAnchor constraintEqualToConstant:36.0],
                ]];
                [self.dockPill.stackView addArrangedSubview:btn];
            }
            if (pureActionDockOverlay && pureActionDockOverlay.slotIndex >= maxTabs) {
                [self.dockPill.stackView addArrangedSubview:[self makePureActionDockButton:pureActionDockOverlay isDarkMode:isDarkMode]];
            }
            if (self.dockPill.stackView.arrangedSubviews.count == 0) {
                self.dockPill.hidden = YES;
            }
        }
        if (prominentOverlay) {
            [self renderProminentOverlay:prominentOverlay isDarkMode:isDarkMode];
        } else {
            self.prominentPill.hidden = YES;
        }
    }
}

@end

// MARK: - Window Refresh Orchestrator

static PTDuoVerticalBarHostView *pt_hostViewForWindow(UIWindow *window, BOOL createIfNeeded) {
    if (!window) {
        return nil;
    }
    PTDuoVerticalBarHostView *host = objc_getAssociatedObject(window, kPTDuoWindowHostViewKey);
    if (!host && createIfNeeded) {
        host = [[PTDuoVerticalBarHostView alloc] initWithWindow:window];
        [window addSubview:host];
        objc_setAssociatedObject(window, kPTDuoWindowHostViewKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return host;
}

static CGFloat pt_windowNativeRightSafeAreaInset(UIWindow *window);
static UIEdgeInsets pt_windowSuperSafeAreaInsets(UIWindow *window);
static CGFloat pt_windowTrafficLightTopClearance(UIWindow *window);
static void pt_syncTrafficLightTopClearanceForWindow(UIWindow *window);

static void pt_notifySafeAreaInsetsChanged(UIWindow *window, CGFloat expectedRightInset) {
    if (!window) {
        return;
    }
    SEL safeAreaChangeSel = sel_registerName("_sceneSettingsSafeAreaInsetsDidChange");
    if ([window respondsToSelector:safeAreaChangeSel]) {
        ((void (*)(id, SEL))objc_msgSend)(window, safeAreaChangeSel);
    }
    CGFloat actualRight = pt_windowSuperSafeAreaInsets(window).right;
    if (!isfinite(actualRight)) {
        actualRight = 0.0;
    }
    CGFloat safeExpected = isfinite(expectedRightInset) ? expectedRightInset : 0.0;
    if (fabs(actualRight - safeExpected) > 0.5) {
        SEL updateSafeAreaSel = sel_registerName("_updateSafeAreaInsets");
        if ([window respondsToSelector:updateSafeAreaSel]) {
            ((void (*)(id, SEL))objc_msgSend)(window, updateSafeAreaSel);
        }
        [window setNeedsLayout];
        [window.rootViewController.viewIfLoaded setNeedsLayout];
    }
}

static CGFloat pt_windowOccupiedRightBarWidth(UIWindow *window) {
    if (!pt_isDuoVerticalBarActiveForWindow(window)) {
        return 0.0;
    }
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(window, NO);
    if (!insetState) {
        return kPTDuoVerticalBarWidth;
    }
    if (insetState.collapsedEmptyRightInset) {
        return 0.0;
    }
    return (insetState.occupiedRightBarWidth > 0.0) ? insetState.occupiedRightBarWidth : kPTDuoVerticalBarWidth;
}

static void pt_refreshDuoVerticalBarForWindow(UIWindow *window) {
    if (!window || ![NSThread isMainThread]) {
        return;
    }
    if (pt_duoHostLiveResizing) {
        objc_setAssociatedObject(window, kPTDuoPendingLiveResizeRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (pt_duoRefreshDepth > 0) {
        return;
    }
    if (!pt_isWindowStructuralPrimaryCandidate(window)
        && objc_getAssociatedObject(window, kPTDuoWindowStateKey) == nil
        && pt_hostViewForWindow(window, NO) == nil) {
        return;
    }
    pt_duoRefreshDepth++;
    @try {
        PTDuoBarState prevState = PTDuoBarStateUnset;
        NSNumber *prevNum = objc_getAssociatedObject(window, kPTDuoWindowStateKey);
        if (prevNum) {
            prevState = (PTDuoBarState)prevNum.integerValue;
        }
        PTDuoBarState nextState = pt_computeDesiredBarStateForWindow(window);
        BOOL wasActive = (prevState == PTDuoBarStateActive);
        BOOL isActive = (nextState == PTDuoBarStateActive);

        // Skip state allocation, trait mutation, and safe-area notifications for windows
        // that were never active and remain ineligible/inactive (e.g. hidden popup windows).
        if (!wasActive && !isActive
            && objc_getAssociatedObject(window, kPTDuoWindowInsetStateKey) == nil
            && objc_getAssociatedObject(window, kPTDuoWindowTraitStateKey) == nil
            && pt_hostViewForWindow(window, NO) == nil) {
            objc_setAssociatedObject(window, kPTDuoWindowStateKey, @(nextState), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        PTDuoWindowInsetState *insetState = pt_insetStateForWindow(window, YES);
        CGFloat prevOccupiedWidth = (prevState == PTDuoBarStateActive && !insetState.collapsedEmptyRightInset)
            ? ((insetState.occupiedRightBarWidth > 0.0) ? insetState.occupiedRightBarWidth : kPTDuoVerticalBarWidth)
            : 0.0;

        // Apply traits to window and windowScene using dedicated trait-state keys.
        // Per UIVerticalBarEdge.h, verticalBarEdge remains Trailing whenever active,
        // regardless of whether a vertical bar is currently visible.
        pt_applyVerticalBarTraitsToObject(window, kPTDuoWindowTraitStateKey, nextState);
        if (window.windowScene) {
            pt_applyVerticalBarTraitsToObject(window.windowScene, kPTDuoSceneTraitStateKey, nextState);
        }
        objc_setAssociatedObject(window, kPTDuoWindowStateKey, @(nextState), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        BOOL epochChanged = NO;
        BOOL hostBecameVisible = NO;

        if (isActive) {
            UINavigationController *headerNav = nil;
            UINavigationController *toolbarNav = nil;
            UITabBarController *tabVC = nil;
            UIViewController *leafVC = nil;
            pt_findActiveNavAndTabControllersEx(window, &headerNav, &toolbarNav, &tabVC, &leafVC);

            epochChanged = (!wasActive
                            || insetState.forceReprobe
                            || insetState.activeLeafVC != leafVC);
            if (epochChanged) {
                BOOL leafVCUnchanged = (insetState.activeLeafVC == leafVC);
                CFTimeInterval queryAge = (insetState.queriedRightBarTimestamp > 0.0)
                    ? (CACurrentMediaTime() - insetState.queriedRightBarTimestamp)
                    : -1.0;
                BOOL preserveRecentQuery = PTDuoShouldPreserveRecentRightBarQuery(
                    wasActive,
                    leafVCUnchanged,
                    insetState.queriedRightBarRegion,
                    queryAge);

                insetState.activeLeafVC = leafVC;
                insetState.epoch += 1;
                insetState.probingRightInset = YES;
                if (!preserveRecentQuery) {
                    insetState.queriedRightBarRegion = NO;
                    insetState.queriedRightBarExtent = 0.0;
                    insetState.queriedRightBarTimestamp = 0.0;
                }
                insetState.collapsedEmptyRightInset = NO;
                insetState.occupiedRightBarWidth = kPTDuoVerticalBarWidth;
                insetState.forceReprobe = NO;
                insetState.postMountRecheckScheduled = NO;
                insetState.safeAreaDriftRetryCount = 0;
                insetState.unknownSlotRetryCount = 0;

                NSUInteger capturedEpoch = insetState.epoch;
                BOOL isColdActivation = (prevState == PTDuoBarStateUnset);
                double settleDelay = isColdActivation ? 0.65 : 0.18;

                // Offer 60pt right safe-area inset immediately so custom-sidebar apps (e.g. checking
                // safeAreaInsets.right > 0 before calling UIViewLayoutRegion) can mount cleanly.
                if (prevOccupiedWidth <= 0.5) {
                    CGFloat probeExpectedRight = PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(
                        YES, kPTDuoVerticalBarWidth, pt_windowNativeRightSafeAreaInset(window));
                    pt_notifySafeAreaInsetsChanged(window, probeExpectedRight);
                    prevOccupiedWidth = kPTDuoVerticalBarWidth;
                }

                if (isColdActivation) {
                    __weak UIWindow *weakWinScan = window;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        UIWindow *strongWin = weakWinScan;
                        if (strongWin) {
                            pt_refreshDuoVerticalBarForWindow(strongWin);
                        }
                    });
                }

                __weak UIWindow *weakWin = window;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIWindow *strongWin = weakWin;
                    if (!strongWin) {
                        return;
                    }
                    PTDuoWindowInsetState *st = pt_insetStateForWindow(strongWin, NO);
                    if (st && st.epoch == capturedEpoch && st.probingRightInset) {
                        st.probingRightInset = NO;
                        pt_refreshDuoVerticalBarForWindow(strongWin);
                    }
                });
            }

            PTDuoVerticalBarHostView *existingHost = pt_hostViewForWindow(window, NO);
            BOOL wasHostVisible = (existingHost != nil && !existingHost.hidden);
            PTDuoVerticalBarHostView *host = pt_hostViewForWindow(window, YES);
            BOOL wasCollapsed = insetState.collapsedEmptyRightInset;
            BOOL allowSidebarCheck = !wasCollapsed;
            BOOL hasAppSidebar = NO;
            CGFloat detectedSidebarWidth = 0.0;
            BOOL hostHasVisibleItems = [host syncWithWindow:window
                                                  headerNav:headerNav
                                                 toolbarNav:toolbarNav
                                                      tabVC:tabVC
                                          allowSidebarCheck:allowSidebarCheck
                                           outHasAppSidebar:&hasAppSidebar
                                    outDetectedSidebarWidth:&detectedSidebarWidth];
            BOOL isHostVisible = (host != nil && !host.hidden && hostHasVisibleItems);
            hostBecameVisible = (!wasHostVisible && isHostVisible);
            if (hostBecameVisible) {
                insetState.safeAreaDriftRetryCount = 0;
            }

            CGFloat nextOccupiedWidth = PTDuoResolveOccupiedRightBarWidth(
                isActive,
                insetState.probingRightInset,
                hostHasVisibleItems,
                hasAppSidebar,
                detectedSidebarWidth,
                insetState.queriedRightBarRegion,
                insetState.queriedRightBarExtent);

            if (hostHasVisibleItems || hasAppSidebar || insetState.queriedRightBarRegion) {
                insetState.collapsedEmptyRightInset = NO;
                insetState.occupiedRightBarWidth = nextOccupiedWidth;
                // If we just un-collapsed (0 -> 60pt), let safeAreaInsets propagate before checking sidebars.
                if (wasCollapsed && !hasAppSidebar) {
                    __weak UIWindow *weakWinPostUncollapse = window;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        UIWindow *strongWin = weakWinPostUncollapse;
                        if (strongWin) {
                            pt_scheduleRefreshForWindow(strongWin);
                        }
                    });
                }
            } else if (!insetState.collapsedEmptyRightInset) {
                BOOL shouldCollapse = PTDuoShouldCollapseEmptyRightInset(
                    isActive,
                    insetState.probingRightInset,
                    hostHasVisibleItems,
                    hasAppSidebar,
                    insetState.queriedRightBarRegion);
                if (shouldCollapse) {
                    insetState.collapsedEmptyRightInset = YES;
                    insetState.occupiedRightBarWidth = 0.0;
                } else {
                    insetState.occupiedRightBarWidth = nextOccupiedWidth;
                }
            }

            // Coalesce one delayed post-mount auto-yield check per epoch while the synthetic host
            // is visible, catching lazy-mounted app sidebars without continuous layoutSubviews polling.
            if (host && !host.hidden && !insetState.postMountRecheckScheduled) {
                insetState.postMountRecheckScheduled = YES;
                NSUInteger capturedPostEpoch = insetState.epoch;
                __weak UIWindow *weakWinLazy = window;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIWindow *strongWin = weakWinLazy;
                    if (!strongWin) {
                        return;
                    }
                    PTDuoWindowInsetState *st = pt_insetStateForWindow(strongWin, NO);
                    if (st && st.epoch == capturedPostEpoch) {
                        pt_scheduleRefreshForWindow(strongWin);
                    }
                });
            }
        } else {
            insetState.activeLeafVC = nil;
            insetState.probingRightInset = NO;
            insetState.queriedRightBarRegion = NO;
            insetState.queriedRightBarExtent = 0.0;
            insetState.queriedRightBarTimestamp = 0.0;
            insetState.collapsedEmptyRightInset = NO;
            insetState.occupiedRightBarWidth = 0.0;
            insetState.forceReprobe = NO;
            insetState.postMountRecheckScheduled = NO;
            if (wasActive) {
                insetState.safeAreaDriftRetryCount = 0;
            }
            insetState.unknownSlotRetryCount = 0;

            PTDuoVerticalBarHostView *host = pt_hostViewForWindow(window, NO);
            if (host) {
                [host hideAndRestore];
            }
        }

        pt_syncTrafficLightTopClearanceForWindow(window);

        CGFloat nowOccupiedWidth = (isActive && !insetState.collapsedEmptyRightInset)
            ? insetState.occupiedRightBarWidth
            : 0.0;
        CGFloat nativeWinRight = pt_windowNativeRightSafeAreaInset(window);
        CGFloat rawActualWinRight = pt_windowSuperSafeAreaInsets(window).right;
        CGFloat actualWinRight = isfinite(rawActualWinRight) ? rawActualWinRight : 0.0;
        CGFloat expectedRightInset = PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(
            isActive, nowOccupiedWidth, nativeWinRight);
        if (isActive || wasActive || prevOccupiedWidth > 0.5) {
            if (fabs(actualWinRight - expectedRightInset) <= 0.5) {
                insetState.safeAreaDriftRetryCount = 0;
            }
            if (PTDuoShouldNotifySafeAreaChange(prevOccupiedWidth,
                                                nowOccupiedWidth,
                                                actualWinRight,
                                                expectedRightInset,
                                                epochChanged,
                                                hostBecameVisible,
                                                insetState.safeAreaDriftRetryCount)) {
                if (fabs(actualWinRight - expectedRightInset) > 0.5) {
                    insetState.safeAreaDriftRetryCount += 1;
                }
                pt_duoInternalSafeAreaNotifyDepth++;
                @try {
                    pt_notifySafeAreaInsetsChanged(window, expectedRightInset);
                } @finally {
                    pt_duoInternalSafeAreaNotifyDepth--;
                }
                CGFloat rawPostWinRight = pt_windowSuperSafeAreaInsets(window).right;
                CGFloat postWinRight = isfinite(rawPostWinRight) ? rawPostWinRight : 0.0;
                if (fabs(postWinRight - expectedRightInset) > 0.5 && insetState.safeAreaDriftRetryCount < 3) {
                    pt_scheduleRefreshForWindow(window);
                } else if (fabs(postWinRight - expectedRightInset) <= 0.5) {
                    insetState.safeAreaDriftRetryCount = 0;
                }
            }
        }
    } @finally {
        pt_duoRefreshDepth--;
    }
}

NSDictionary *PTDuoCopyDecisionSnapshotForWindow(UIWindow *window) {
    if (!window) {
        return @{};
    }
    PTDuoBarState desiredState = pt_computeDesiredBarStateForWindow(window);
    BOOL active = pt_isDuoVerticalBarActiveForWindow(window);
    PTDuoWindowInsetState *st = pt_insetStateForWindow(window, NO);
    PTDuoVerticalBarHostView *host = pt_hostViewForWindow(window, NO);

    UINavigationController *headerNav = nil;
    UINavigationController *toolbarNav = nil;
    UITabBarController *tabVC = nil;
    UIViewController *leafVC = nil;
    pt_findActiveNavAndTabControllersEx(window, &headerNav, &toolbarNav, &tabVC, &leafVC);

    NSMutableArray<NSDictionary *> *itemEntriesOut = [NSMutableArray array];
    PTDuoBarItemPlan *plan = host ? host.lastItemPlan : nil;
    if (plan) {
        NSUInteger limit = MIN(plan.allCandidateEntries.count, (NSUInteger)24);
        for (NSUInteger i = 0; i < limit; i++) {
            PTDuoBarItemEntry *e = plan.allCandidateEntries[i];
            [itemEntriesOut addObject:@{
                @"bucket": e.bucket ?: @"",
                @"sourceClass": e.sourceClass ?: @"",
                @"axisBehavior": @(e.axisBehavior),
                @"visualSource": e.visualSource ?: @"",
                @"actionSource": e.actionSource ?: @"",
                @"badgeText": e.badgeText ?: @"",
                @"enabled": @(e.enabled),
                @"selected": @(e.selected),
                @"relocated": @(e.relocated),
                @"rejectedReason": e.rejectedReason ?: @"",
                @"snapshotStats": @{
                    @"opaqueRatio": @(e.snapshotOpaqueRatio),
                    @"minLuma": @(e.snapshotMinLuma),
                    @"maxLuma": @(e.snapshotMaxLuma)
                }
            }];
        }
    }

    NSMutableArray<NSDictionary *> *slotOverlaysOut = [NSMutableArray array];
    void (^appendOverlay)(PTDuoTabSlotOverlay *) = ^(PTDuoTabSlotOverlay *ov) {
        if (!ov || slotOverlaysOut.count >= 12) {
            return;
        }
        [slotOverlaysOut addObject:@{
            @"slotIndex": @(ov.slotIndex),
            @"visualSource": ov.visualSource ?: @"",
            @"actionSource": ov.actionSource ?: @"",
            @"isSnapshot": @(ov.isSnapshot),
            @"promoteToProminent": @(ov.promoteToProminent),
            @"snapshotStats": @{
                @"opaqueRatio": @(ov.snapshotOpaqueRatio),
                @"minLuma": @(ov.snapshotMinLuma),
                @"maxLuma": @(ov.snapshotMaxLuma)
            }
        }];
    };
    if (host) {
        for (NSNumber *k in [[host.boundModernSlotOverlays allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            appendOverlay(host.boundModernSlotOverlays[k]);
        }
        for (NSNumber *k in [[host.boundLegacySlotOverlays allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            appendOverlay(host.boundLegacySlotOverlays[k]);
        }
        appendOverlay(host.boundProminentOverlay);
        appendOverlay(host.boundPureActionDockOverlay);
    }

    CGRect wb = window.bounds;
    return @{
        @"windowClass": NSStringFromClass([window class]) ?: @"",
        @"windowBounds": @{
            @"x": @(wb.origin.x),
            @"y": @(wb.origin.y),
            @"width": @(wb.size.width),
            @"height": @(wb.size.height)
        },
        @"duoEnabled": @(PTShouldEnableDuoVerticalBar()),
        @"activeForWindow": @(active),
        @"barState": @(desiredState),
        @"activeNavClass": headerNav ? (NSStringFromClass([headerNav class]) ?: @"") : @"",
        @"activeHeaderNavClass": headerNav ? (NSStringFromClass([headerNav class]) ?: @"") : @"",
        @"activeToolbarNavClass": toolbarNav ? (NSStringFromClass([toolbarNav class]) ?: @"") : @"",
        @"activeTabBarClass": tabVC ? (NSStringFromClass([tabVC class]) ?: @"") : @"",
        @"activeLeafVCClass": leafVC ? (NSStringFromClass([leafVC class]) ?: @"") : @"",
        @"epoch": @(st ? st.epoch : 0),
        @"probingRightInset": @(st ? st.probingRightInset : NO),
        @"collapsedEmptyRightInset": @(st ? st.collapsedEmptyRightInset : NO),
        @"occupiedRightBarWidth": @(pt_windowOccupiedRightBarWidth(window)),
        @"queriedRightBarRegion": @(st ? st.queriedRightBarRegion : NO),
        @"queriedRightBarExtent": @(st ? st.queriedRightBarExtent : 0.0),
        @"tabDockBlockedByUnknownSlot": @(st ? st.lastTabDockBlockedByUnknownSlot : NO),
        @"yieldReason": (st && st.lastYieldReason) ? [NSString stringWithUTF8String:st.lastYieldReason] : @"",
        @"takeoverReason": (st && st.lastTakeoverReason) ? [NSString stringWithUTF8String:st.lastTakeoverReason] : @"",
        @"navBarSuppressionMode": @(st ? st.lastNavBarSuppressionMode : PTDuoNavBarSuppressionNone),
        @"toolbarSuppressionMode": @(st ? st.lastToolbarSuppressionMode : PTDuoNavBarSuppressionNone),
        @"host": @{
            @"present": @(host != nil),
            @"visible": @(host != nil && !host.hidden),
            @"backPillVisible": @(host != nil && !host.backPill.hidden),
            @"leadingCount": @(host ? host.leadingPill.stackView.arrangedSubviews.count : 0),
            @"navBarItemCount": @(host ? host.itemsPill.stackView.arrangedSubviews.count : 0),
            @"toolbarItemCount": @(host ? host.toolbarPill.stackView.arrangedSubviews.count : 0),
            @"dockTabCount": @(host ? host.dockPill.stackView.arrangedSubviews.count : 0),
            @"prominentVisible": @(host != nil && !host.prominentPill.hidden),
            @"usingModernTabs": @(host ? host.usingModernTabs : NO),
            @"hasRelocatedTabBar": @(host ? host.hasRelocatedTabBar : NO)
        },
        @"barItemPlan": itemEntriesOut,
        @"slotOverlays": slotOverlaysOut,
        @"telemetry": @{
            @"autoYieldNodesScanned": @(st ? st.lastAutoYieldNodesScanned : 0),
            @"overlayNodesScanned": @(st ? st.lastOverlayNodesScanned : 0),
            @"overlayCandidatesScanned": @(st ? st.lastOverlayCandidatesScanned : 0),
            @"autoYieldDurationMs": @(st ? st.lastAutoYieldDurationMs : 0.0),
            @"slotCaptureDurationMs": @(st ? st.lastSlotCaptureDurationMs : 0.0),
            @"rebuildDurationMs": @(st ? st.lastRebuildDurationMs : 0.0)
        }
    };
}

static void (^pt_globalBackRefreshHandler)(void) = nil;
static BOOL pt_globalBackRefreshScheduled = NO;
static BOOL pt_globalBackHooksInstalled = NO;

void PTDuoSetGlobalBackRefreshHandler(void (^ _Nullable handler)(void)) {
    pt_globalBackRefreshHandler = [handler copy];
    if (pt_globalBackRefreshHandler) {
        if ([NSThread isMainThread]) {
            pt_globalBackRefreshHandler();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (pt_globalBackRefreshHandler) {
                    pt_globalBackRefreshHandler();
                }
            });
        }
    }
}

static void pt_scheduleGlobalBackRefresh(void) {
    if (!pt_globalBackRefreshHandler) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            pt_scheduleGlobalBackRefresh();
        });
        return;
    }
    if (pt_globalBackRefreshScheduled) {
        return;
    }
    pt_globalBackRefreshScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pt_globalBackRefreshScheduled = NO;
        if (pt_globalBackRefreshHandler) {
            pt_globalBackRefreshHandler();
        }
    });
}

@interface PTDuoGlobalBackControlHit : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, assign) CGRect rectInWindow;
@property (nonatomic, strong) UIControl *control;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, weak) id tapTarget;
@property (nonatomic, assign) SEL tapAction;
@property (nonatomic, copy) NSString *cue;
@end

@implementation PTDuoGlobalBackControlHit
@end

static NSString *pt_imageCueString(UIImage *image) {
    if (!image) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (image.accessibilityIdentifier.length > 0) {
        [parts addObject:image.accessibilityIdentifier];
    }
    if (image.accessibilityLabel.length > 0) {
        [parts addObject:image.accessibilityLabel];
    }
    NSString *desc = [image description];
    if (desc.length > 0) {
        [parts addObject:desc];
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *pt_controlActionsCueString(UIControl *control) {
    if (!control) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIControlEvents events[] = {
        UIControlEventTouchUpInside,
        UIControlEventPrimaryActionTriggered,
        UIControlEventTouchUpOutside
    };
    for (id target in control.allTargets) {
        if (!target || target == [NSNull null]) {
            continue;
        }
        for (size_t i = 0; i < sizeof(events) / sizeof(events[0]); i++) {
            NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:events[i]];
            if (actions.count > 0) {
                [parts addObjectsFromArray:actions];
            }
        }
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *pt_viewCueString(UIView *view, NSInteger depth) {
    if (!view || depth > 2) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (view.accessibilityLabel.length > 0) {
        [parts addObject:view.accessibilityLabel];
    }
    if (view.accessibilityIdentifier.length > 0) {
        [parts addObject:view.accessibilityIdentifier];
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *title = btn.currentTitle ?: btn.currentAttributedTitle.string ?: btn.titleLabel.text;
        if (title.length > 0) {
            [parts addObject:title];
        }
        NSString *imgCue = pt_imageCueString(btn.currentImage ?: btn.imageView.image);
        if (imgCue.length > 0) {
            [parts addObject:imgCue];
        }
    } else if ([view isKindOfClass:[UILabel class]]) {
        NSString *txt = ((UILabel *)view).text;
        if (txt.length > 0) {
            [parts addObject:txt];
        }
    } else if ([view isKindOfClass:[UIImageView class]]) {
        NSString *imgCue = pt_imageCueString(((UIImageView *)view).image);
        if (imgCue.length > 0) {
            [parts addObject:imgCue];
        }
    }
    if ([view isKindOfClass:[UIControl class]]) {
        NSString *actCue = pt_controlActionsCueString((UIControl *)view);
        if (actCue.length > 0) {
            [parts addObject:actCue];
        }
    }
    UITapGestureRecognizer *tapGR = nil;
    id tapTarget = nil;
    SEL tapAction = NULL;
    if (pt_extractVerifiedTapGestureAction(view, 0, &tapGR, &tapTarget, &tapAction) && tapAction != NULL) {
        NSString *selName = NSStringFromSelector(tapAction);
        if (selName.length > 0) {
            [parts addObject:selName];
        }
    }
    NSUInteger subCount = 0;
    for (UIView *sub in view.subviews) {
        if (subCount >= 8) {
            break;
        }
        if (sub.hidden || sub.alpha <= 0.05) {
            continue;
        }
        subCount++;
        NSString *subCue = pt_viewCueString(sub, depth + 1);
        if (subCue.length > 0) {
            [parts addObject:subCue];
        }
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *pt_barItemCueString(UIBarButtonItem *item, PTDuoBarItemEntry *entry) {
    if (!item) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (entry.resolvedTitle.length > 0) {
        [parts addObject:entry.resolvedTitle];
    }
    if (item.title.length > 0) {
        [parts addObject:item.title];
    }
    if (item.accessibilityLabel.length > 0) {
        [parts addObject:item.accessibilityLabel];
    }
    if (item.accessibilityIdentifier.length > 0) {
        [parts addObject:item.accessibilityIdentifier];
    }
    if (item.action != NULL) {
        NSString *selName = NSStringFromSelector(item.action);
        if (selName.length > 0) {
            [parts addObject:selName];
        }
    }
    NSString *imgCue = pt_imageCueString(entry.resolvedImage ?: item.image);
    if (imgCue.length > 0) {
        [parts addObject:imgCue];
    }
    if (item.customView) {
        NSString *cvCue = pt_viewCueString(item.customView, 0);
        if (cvCue.length > 0) {
            [parts addObject:cvCue];
        }
    }
    return [parts componentsJoinedByString:@" "];
}

static BOOL pt_dispatchSyntheticTapOnView(UIView *view, UIWindow *hostWindow) {
    if (!view || !hostWindow || view.window != hostWindow || view.hidden
        || !isfinite(view.alpha) || view.alpha <= 0.05) {
        return NO;
    }
    CGPoint centerInWin = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                      toView:hostWindow];
    if (!isfinite(centerInWin.x) || !isfinite(centerInWin.y)
        || !CGRectContainsPoint(hostWindow.bounds, centerInWin)) {
        return NO;
    }
    UIView *hitView = [hostWindow hitTest:centerInWin withEvent:nil];
    if (!hitView || ![hitView isDescendantOfView:view]) {
        hitView = view;
    }
    NSInteger tid = [PTFakeMetaTouch fakeTouchId:-1
                                         AtPoint:centerInWin
                                  withTouchPhase:UITouchPhaseBegan
                                        inWindow:hostWindow
                                          onView:hitView];
    if (tid < 0) {
        return NO;
    }
    __weak UIWindow *weakWin = hostWindow;
    __weak UIView *weakView = hitView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *strongWin = weakWin;
        UIView *strongView = weakView;
        if (strongWin && strongView) {
            [PTFakeMetaTouch fakeTouchId:tid
                                 AtPoint:centerInWin
                          withTouchPhase:UITouchPhaseEnded
                                inWindow:strongWin
                                  onView:strongView];
            pt_scheduleRefreshForWindow(strongWin);
        }
    });
    return YES;
}

static BOOL pt_executeStandaloneBarButtonItem(UIBarButtonItem *item, UIWindow *hostWindow) {
    if (!item || !item.enabled) {
        return NO;
    }
    if (@available(iOS 14.0, *)) {
        if (item.primaryAction) {
            SEL performSel = sel_registerName("performWithSender:target:");
            if ([item.primaryAction respondsToSelector:performSel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(item.primaryAction, performSel, item, nil);
                pt_scheduleRefreshForWindow(hostWindow);
                return YES;
            }
        }
    }
    if (PTDuoShouldPrioritizeCustomViewDispatch(item.customView != nil)) {
        UIControl *ctrl = pt_findActionControlInView(item.customView, 0);
        if (ctrl) {
            pt_triggerControlAction(ctrl);
            pt_scheduleRefreshForWindow(hostWindow);
            return YES;
        }
        UITapGestureRecognizer *tapGR = nil;
        id tapTarget = nil;
        SEL tapAction = NULL;
        if (pt_extractVerifiedTapGestureAction(item.customView, 0, &tapGR, &tapTarget, &tapAction)
            && pt_dispatchVerifiedTapAction(tapGR, tapTarget, tapAction)) {
            pt_scheduleRefreshForWindow(hostWindow);
            return YES;
        }
        if (pt_dispatchSyntheticTapOnView(item.customView, hostWindow)) {
            pt_scheduleRefreshForWindow(hostWindow);
            return YES;
        }
    }
    if (item.action != NULL) {
        BOOL sent = [[UIApplication sharedApplication] sendAction:item.action
                                                               to:item.target
                                                             from:item
                                                         forEvent:nil];
        if (sent) {
            pt_scheduleRefreshForWindow(hostWindow);
            return YES;
        }
    }
    return NO;
}

static BOOL pt_executeGlobalBackControlHit(PTDuoGlobalBackControlHit *hit, UIWindow *window) {
    if (!hit) {
        return NO;
    }
    if (hit.control) {
        pt_triggerControlAction(hit.control);
        pt_scheduleRefreshForWindow(window);
        return YES;
    }
    if (hit.tapTarget && hit.tapAction != NULL
        && pt_dispatchVerifiedTapAction(hit.tapGesture, hit.tapTarget, hit.tapAction)) {
        pt_scheduleRefreshForWindow(window);
        return YES;
    }
    return NO;
}

static BOOL pt_controlHasDispatchableTarget(UIControl *control) {
    if (!control || !control.enabled || !control.userInteractionEnabled) {
        return NO;
    }
    if (control.allTargets.count > 0) {
        return YES;
    }
    SEL enumSel = sel_registerName("enumerateEventHandlers:");
    if ([control respondsToSelector:enumSel]) {
        __block BOOL foundHandler = NO;
        void (^visitor)(id, id, SEL, UIControlEvents, BOOL *) = ^(id uiAction, id target, SEL action, UIControlEvents events, BOOL *stop) {
            (void)events;
            if (uiAction != nil || (target != nil && action != NULL)) {
                foundHandler = YES;
                if (stop) {
                    *stop = YES;
                }
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(control, enumSel, visitor);
        if (foundHandler) {
            return YES;
        }
    }
    return NO;
}

static void pt_collectTopControlsInView(UIView *rootView,
                                        UIWindow *window,
                                        UIView *skipHostView,
                                        CGFloat maxBottomY,
                                        CGFloat minOriginX,
                                        CGFloat maxWidth,
                                        CGFloat maxHeight,
                                        NSMutableArray<PTDuoGlobalBackControlHit *> *outHits,
                                        NSInteger *budget) {
    if (!rootView || !window || !budget || *budget <= 0) {
        return;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
    for (NSUInteger i = 0; i < queue.count && *budget > 0; i++) {
        UIView *view = queue[i];
        (*budget)--;
        if (view == skipHostView) {
            continue;
        }
        if (view.hidden || !isfinite(view.alpha) || view.alpha <= 0.05) {
            continue;
        }
        NSString *clsName = NSStringFromClass([view class]);
        if ([view isKindOfClass:[UITabBar class]] || [clsName isEqualToString:@"_UIBottomTabBarGroupView"]) {
            continue;
        }
        if (CGRectIsEmpty(view.bounds)) {
            if (view.clipsToBounds) {
                continue;
            }
            for (UIView *sub in view.subviews) {
                [queue addObject:sub];
            }
            continue;
        }
        UIControl *ctrl = [view isKindOfClass:[UIControl class]] ? (UIControl *)view : nil;
        BOOL canCtrl = (ctrl && pt_controlHasDispatchableTarget(ctrl));
        UITapGestureRecognizer *tapGR = nil;
        id tapTarget = nil;
        SEL tapAction = NULL;
        BOOL canTap = (!canCtrl && view.userInteractionEnabled
                       && view.gestureRecognizers.count > 0
                       && pt_extractVerifiedTapGestureAction(view, 0, &tapGR, &tapTarget, &tapAction));
        if (canCtrl || canTap || view.clipsToBounds) {
            CGRect winRect = [view convertRect:view.bounds toView:window];
            if (!CGRectIsNull(winRect) && !CGRectIsEmpty(winRect)) {
                if (view.clipsToBounds
                    && (CGRectGetMinY(winRect) > maxBottomY || CGRectGetMaxY(winRect) < -4.0)) {
                    continue;
                }
                if (canCtrl || canTap) {
                    CGFloat w = CGRectGetWidth(winRect);
                    CGFloat h = CGRectGetHeight(winRect);
                    if (CGRectGetMinY(winRect) >= -4.0
                        && CGRectGetMaxY(winRect) <= maxBottomY
                        && CGRectGetMinX(winRect) >= minOriginX
                        && w >= 16.0 && w <= maxWidth
                        && h >= 16.0 && h <= maxHeight) {
                        PTDuoGlobalBackControlHit *hit = [[PTDuoGlobalBackControlHit alloc] init];
                        hit.view = view;
                        hit.rectInWindow = winRect;
                        hit.control = canCtrl ? ctrl : nil;
                        hit.tapGesture = tapGR;
                        hit.tapTarget = tapTarget;
                        hit.tapAction = tapAction;
                        hit.cue = pt_viewCueString(view, 0);
                        [outHits addObject:hit];
                    }
                }
            }
        }
        for (UIView *sub in view.subviews) {
            [queue addObject:sub];
        }
    }
}

static NSArray<UIBarButtonItem *> *pt_leftNavItemsForItem(UINavigationItem *navItem) {
    if (!navItem) {
        return @[];
    }
    NSMutableArray<UIBarButtonItem *> *result = [NSMutableArray array];
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in navItem.leadingItemGroups) {
            if (group.hidden) {
                continue;
            }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (item && ![result containsObject:item]) {
                    [result addObject:item];
                }
            }
        }
    }
    for (UIBarButtonItem *item in navItem.leftBarButtonItems) {
        if (item && ![result containsObject:item]) {
            [result addObject:item];
        }
    }
    return result;
}

static BOOL pt_barButtonItemIsEnabledAndVisible(UIBarButtonItem *item) {
    if (!item || !item.enabled || pt_barItemAppWantsHidden(item)) {
        return NO;
    }
    if (item.customView) {
        UIView *cv = item.customView;
        BOOL suppressed = [objc_getAssociatedObject(cv, kPTDuoCustomViewSuppressedKey) boolValue];
        NSNumber *appHidden = objc_getAssociatedObject(cv, kPTDuoCustomViewAppHiddenKey);
        BOOL hidden = suppressed ? (appHidden ? appHidden.boolValue : NO) : cv.hidden;
        if (hidden || CGRectIsEmpty(cv.bounds)) {
            return NO;
        }
    }
    return YES;
}

static BOOL pt_hostHasRelocatedSidebarBackItem(PTDuoVerticalBarHostView *host, BOOL includeTopClose) {
    if (!host || host.hidden || host.boundItemEntries.count == 0) {
        return NO;
    }
    for (PTDuoBarItemEntry *entry in host.boundItemEntries) {
        if (!entry) {
            continue;
        }
        BOOL isLeadingOrNav = [entry.bucket isEqualToString:@"leading"] || [entry.bucket isEqualToString:@"navBar"];
        const char *cue = pt_barItemCueString(entry.item, entry).UTF8String;
        if (PTDuoHostEntryCountsAsSidebarBack(entry.isOverflowMenu,
                                              entry.item != nil,
                                              entry.enabled,
                                              isLeadingOrNav,
                                              PTDuoCStrMatchesBackCue(cue),
                                              includeTopClose,
                                              PTDuoCStrMatchesCloseCue(cue))) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_resolveGlobalBackForWindow(UIWindow *window,
                                          BOOL includeTopClose,
                                          BOOL executeAction,
                                          BOOL *outHasSidebarBack) {
    if (outHasSidebarBack) {
        *outHasSidebarBack = NO;
    }
    UIWindow *win = window ?: pt_findActivePrimaryWindow();
    if (!win || !pt_isEligiblePrimaryWindow(win)) {
        return NO;
    }

    PTDuoVerticalBarHostView *host = pt_hostViewForWindow(win, NO);
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(win, NO);
    UINavigationController *headerNav = nil;
    UINavigationController *toolbarNav = nil;
    UITabBarController *tabVC = nil;
    UIViewController *leafVC = nil;
    pt_findActiveNavAndTabControllersEx(win, &headerNav, &toolbarNav, &tabVC, &leafVC);

    UINavigationController *effHeaderNav = headerNav ?: toolbarNav;
    UIViewController *root = win.rootViewController;
    UIViewController *topRoot = root ? pt_topPresentedFullscreenController(root, win.bounds) : nil;
    BOOL isModalPresented = (topRoot != nil && topRoot != root);

    // Priority 1: Synthetic Duo vertical bar `<` back pill visible
    if (host && !host.hidden && host.backPill && !host.backPill.hidden
        && effHeaderNav && effHeaderNav.viewControllers.count > 1) {
        if (outHasSidebarBack) {
            *outHasSidebarBack = YES;
        }
        if (executeAction) {
            [host handleBackTap:nil];
        }
        return YES;
    }

    // Priority 2: Yielded Native App Duo Sidebar right-strip back button
    BOOL duoActive = pt_isDuoVerticalBarActiveForWindow(win);
    if (duoActive) {
        BOOL yieldedSidebar = (insetState && insetState.lastYieldReason != NULL)
            || pt_windowHasAppRenderedRightSidebar(win, host, NO, NULL);
        if (yieldedSidebar) {
            CGFloat stripMinX = MAX(0.0, CGRectGetWidth(win.bounds) - kPTDuoVerticalBarWidth - 24.0);
            NSMutableArray<PTDuoGlobalBackControlHit *> *rightHits = [NSMutableArray array];
            NSInteger budget = 350;
            pt_collectTopControlsInView(win, win, host, 120.0, stripMinX, 84.0, 72.0, rightHits, &budget);
            [rightHits sortUsingComparator:^NSComparisonResult(PTDuoGlobalBackControlHit *a, PTDuoGlobalBackControlHit *b) {
                if (a.rectInWindow.origin.y < b.rectInWindow.origin.y) { return NSOrderedAscending; }
                if (a.rectInWindow.origin.y > b.rectInWindow.origin.y) { return NSOrderedDescending; }
                return NSOrderedSame;
            }];
            BOOL backedByLayoutRegion = (insetState && insetState.queriedRightBarRegion);
            PTDuoGlobalBackControlHit *matchedSidebarHit = nil;
            for (PTDuoGlobalBackControlHit *hit in rightHits) {
                const char *cue = hit.cue.UTF8String;
                if (PTDuoCStrMatchesBackCue(cue)) {
                    matchedSidebarHit = hit;
                    break;
                }
            }
            if (!matchedSidebarHit && backedByLayoutRegion) {
                for (PTDuoGlobalBackControlHit *hit in rightHits) {
                    if (CGRectGetMaxY(hit.rectInWindow) <= 110.0
                        && CGRectGetWidth(hit.rectInWindow) <= 64.0
                        && CGRectGetHeight(hit.rectInWindow) <= 64.0) {
                        matchedSidebarHit = hit;
                        break;
                    }
                }
            }
            if (matchedSidebarHit) {
                if (outHasSidebarBack) {
                    *outHasSidebarBack = YES;
                }
                if (executeAction) {
                    return pt_executeGlobalBackControlHit(matchedSidebarHit, win);
                }
                return YES;
            }
        }
    }

    // Priority 3: Active UINavigationController stack pop (when app has not hidden back button)
    // Also detect whether the synthetic Duo sidebar already holds a relocated Back/Close button
    // (e.g. CoolApk post detail relocating custom `<` into leadingPill/itemsPill while stackCount > 1).
    BOOL hostHasRelocatedBack = pt_hostHasRelocatedSidebarBackItem(host, includeTopClose);
    BOOL appHidesBack = effHeaderNav
        ? pt_navItemAppWantsHidesBackButton(effHeaderNav.topViewController.navigationItem)
        : NO;
    if (effHeaderNav && effHeaderNav.viewControllers.count > 1 && !appHidesBack) {
        if (outHasSidebarBack && hostHasRelocatedBack) {
            *outHasSidebarBack = YES;
        }
        if (executeAction) {
            [effHeaderNav popViewControllerAnimated:YES];
            pt_scheduleRefreshForWindow(win);
        }
        return YES;
    }

    // Priority 4a: Relocated Duo host leading / navBar items matching Back or Close/Collapse
    if (host && !host.hidden && host.boundItemEntries.count > 0) {
        PTDuoBarItemEntry *firstLeadingCandidate = nil;
        for (PTDuoBarItemEntry *entry in host.boundItemEntries) {
            if (!entry || entry.isOverflowMenu || !entry.item || !entry.enabled) {
                continue;
            }
            BOOL isLeadingBucket = [entry.bucket isEqualToString:@"leading"];
            if (isLeadingBucket && !firstLeadingCandidate && entry.item.image != nil) {
                firstLeadingCandidate = entry;
            }
            const char *cue = pt_barItemCueString(entry.item, entry).UTF8String;
            if (PTDuoCStrMatchesBackCue(cue) || (includeTopClose && PTDuoCStrMatchesCloseCue(cue))) {
                if (outHasSidebarBack) {
                    *outHasSidebarBack = YES;
                }
                if (executeAction) {
                    return pt_executeBarItemEntry(entry, win);
                }
                return YES;
            }
        }
        if (includeTopClose && firstLeadingCandidate
            && (isModalPresented || (effHeaderNav && effHeaderNav.viewControllers.count > 1))) {
            if (outHasSidebarBack) {
                *outHasSidebarBack = YES;
            }
            if (executeAction) {
                return pt_executeBarItemEntry(firstLeadingCandidate, win);
            }
            return YES;
        }
    }

    // Priority 4b: Horizontal navigationItem leftBarButtonItems / leadingItemGroups
    // Skip hidden-navBar root non-modal VCs (base VCs may pre-populate stale leftBarButtonItem back actions),
    // while keeping pushed (stackCount > 1) and modal VCs eligible even if outer nav hides navigationBar.
    if (PTDuoShouldInspectHorizontalNavItems(effHeaderNav != nil,
                                             pt_navBarVisibleByApp(effHeaderNav),
                                             effHeaderNav.topViewController.navigationItem != nil,
                                             effHeaderNav ? effHeaderNav.viewControllers.count : 0,
                                             isModalPresented)) {
        NSArray<UIBarButtonItem *> *leftItems = pt_leftNavItemsForItem(effHeaderNav.topViewController.navigationItem);
        UIBarButtonItem *firstLeftIconItem = nil;
        for (UIBarButtonItem *item in leftItems) {
            if (!pt_barButtonItemIsEnabledAndVisible(item)) {
                continue;
            }
            if (!firstLeftIconItem && ((item.customView == nil && item.image != nil)
                                       || (item.customView != nil
                                           && CGRectGetWidth(item.customView.bounds) <= 64.0
                                           && CGRectGetHeight(item.customView.bounds) <= 64.0))) {
                firstLeftIconItem = item;
            }
            const char *cue = pt_barItemCueString(item, nil).UTF8String;
            if (PTDuoCStrMatchesBackCue(cue) || (includeTopClose && PTDuoCStrMatchesCloseCue(cue))) {
                if (executeAction) {
                    return pt_executeStandaloneBarButtonItem(item, win);
                }
                return YES;
            }
        }
        if (includeTopClose && firstLeftIconItem
            && (isModalPresented || effHeaderNav.viewControllers.count > 1)) {
            if (executeAction) {
                return pt_executeStandaloneBarButtonItem(firstLeftIconItem, win);
            }
            return YES;
        }
    }

    // Priority 4c & 5: Top header page controls (y <= 120pt) + modal container top dismiss buttons
    UIView *scanRoot = (isModalPresented && topRoot.presentationController.containerView)
        ? topRoot.presentationController.containerView
        : (topRoot.viewIfLoaded ?: win);
    NSMutableArray<PTDuoGlobalBackControlHit *> *topHits = [NSMutableArray array];
    NSInteger budget = 450;
    pt_collectTopControlsInView(scanRoot, win, host, 124.0, -4.0, 104.0, 72.0, topHits, &budget);
    [topHits sortUsingComparator:^NSComparisonResult(PTDuoGlobalBackControlHit *a, PTDuoGlobalBackControlHit *b) {
        if (a.rectInWindow.origin.y < b.rectInWindow.origin.y - 8.0) { return NSOrderedAscending; }
        if (a.rectInWindow.origin.y > b.rectInWindow.origin.y + 8.0) { return NSOrderedDescending; }
        if (a.rectInWindow.origin.x < b.rectInWindow.origin.x) { return NSOrderedAscending; }
        if (a.rectInWindow.origin.x > b.rectInWindow.origin.x) { return NSOrderedDescending; }
        return NSOrderedSame;
    }];

    for (PTDuoGlobalBackControlHit *hit in topHits) {
        if (PTDuoCStrMatchesBackCue(hit.cue.UTF8String)) {
            if (executeAction) {
                return pt_executeGlobalBackControlHit(hit, win);
            }
            return YES;
        }
    }
    if (includeTopClose) {
        for (PTDuoGlobalBackControlHit *hit in topHits) {
            if (PTDuoCStrMatchesCloseCue(hit.cue.UTF8String)) {
                if (executeAction) {
                    return pt_executeGlobalBackControlHit(hit, win);
                }
                return YES;
            }
        }
    }

    return NO;
}

BOOL PTDuoQueryGlobalBackStateForWindow(UIWindow * _Nullable window,
                                        BOOL includeTopClose,
                                        BOOL * _Nullable outHasSidebarBackButton) {
    return pt_resolveGlobalBackForWindow(window, includeTopClose, NO, outHasSidebarBackButton);
}

BOOL PTDuoPerformGlobalBackActionForWindow(UIWindow * _Nullable window, BOOL includeTopClose) {
    return pt_resolveGlobalBackForWindow(window, includeTopClose, YES, NULL);
}

static UITabBarController *pt_findPrimaryTabBarController(UIWindow *window) {
    UIViewController *root = window.rootViewController;
    if (!root) {
        return nil;
    }
    NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:root];
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    NSInteger budget = 32;
    for (NSUInteger i = 0; i < queue.count && budget > 0; i++) {
        UIViewController *vc = queue[i];
        if (!vc || [visited containsObject:vc]) {
            continue;
        }
        [visited addObject:vc];
        budget--;
        if ([vc isKindOfClass:[UITabBarController class]]) {
            return (UITabBarController *)vc;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
                if (child && ![visited containsObject:child]) {
                    [queue addObject:child];
                }
            }
        } else if ([vc isKindOfClass:[UISplitViewController class]]) {
            for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) {
                if (child && ![visited containsObject:child]) {
                    [queue addObject:child];
                }
            }
        } else {
            UIViewController *preferred = pt_largestVisibleChildViewController(vc, visited);
            if (preferred) {
                [queue addObject:preferred];
            }
            for (UIViewController *child in vc.childViewControllers) {
                if (child && child != preferred && ![visited containsObject:child]) {
                    [queue addObject:child];
                }
            }
        }
    }
    return nil;
}

static UINavigationController *pt_findNavInSubtree(UIViewController *rootVC) {
    if (!rootVC) {
        return nil;
    }
    UIViewController *cursor = rootVC;
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    for (NSInteger depth = 0; depth < 8 && cursor != nil; depth++) {
        if ([visited containsObject:cursor]) {
            break;
        }
        [visited addObject:cursor];
        if ([cursor isKindOfClass:[UINavigationController class]]) {
            return (UINavigationController *)cursor;
        }
        if ([cursor isKindOfClass:[UISplitViewController class]]) {
            cursor = ((UISplitViewController *)cursor).viewControllers.lastObject;
        } else {
            cursor = pt_largestVisibleChildViewController(cursor, visited) ?: cursor.childViewControllers.firstObject;
        }
    }
    return nil;
}

static BOOL pt_resolveGlobalHomeForWindow(UIWindow *window, BOOL executeAction) {
    UIWindow *win = window ?: pt_findActivePrimaryWindow();
    if (!win || !pt_isEligiblePrimaryWindow(win)) {
        return NO;
    }
    UIViewController *root = win.rootViewController;
    if (!root) {
        return NO;
    }

    UIViewController *topRoot = pt_topPresentedFullscreenController(root, win.bounds);
    BOOL hasModal = (topRoot != nil && topRoot != root) || (root.presentedViewController != nil);

    UINavigationController *headerNav = nil;
    UINavigationController *toolbarNav = nil;
    UITabBarController *activeTabVC = nil;
    UIViewController *leafVC = nil;
    pt_findActiveNavAndTabControllersEx(win, &headerNav, &toolbarNav, &activeTabVC, &leafVC);
    UINavigationController *effHeaderNav = headerNav ?: toolbarNav;

    UITabBarController *tabVC = pt_findPrimaryTabBarController(win) ?: activeTabVC;
    NSArray<id> *modernRegularTabs = nil;
    id firstModernTab = nil;
    NSUInteger tabCount = 0;
    BOOL isOnHomeTab0 = YES;
    UIViewController *tab0VC = nil;

    if (tabVC) {
        if (pt_collectModernTabs(tabVC, &modernRegularTabs, NULL, NULL, NULL) && modernRegularTabs.count >= 2) {
            tabCount = modernRegularTabs.count;
            firstModernTab = modernRegularTabs.firstObject;
            id selectedTab = pt_tabBarControllerSelectedTab(tabVC);
            isOnHomeTab0 = (selectedTab == firstModernTab);
            tab0VC = pt_tabViewController(firstModernTab);
        } else {
            NSUInteger vcCount = tabVC.viewControllers.count;
            NSUInteger itemCount = tabVC.tabBar ? tabVC.tabBar.items.count : 0;
            tabCount = MAX(vcCount, itemCount);
            isOnHomeTab0 = (tabVC.selectedIndex == 0 || tabVC.selectedIndex == NSNotFound);
            tab0VC = (vcCount > 0) ? tabVC.viewControllers.firstObject : nil;
        }
    }

    UINavigationController *tab0Nav = pt_findNavInSubtree(tab0VC);
    UINavigationController *outerTabNav = tabVC.navigationController;
    NSUInteger maxNavStack = 0;
    for (UINavigationController *nav in @[
        effHeaderNav ?: [NSNull null],
        toolbarNav ?: [NSNull null],
        outerTabNav ?: [NSNull null],
        tab0Nav ?: [NSNull null]
    ]) {
        if ([nav isKindOfClass:[UINavigationController class]]) {
            maxNavStack = MAX(maxNavStack, nav.viewControllers.count);
        }
    }

    if (!PTDuoShouldAllowHomeAction(tabVC != nil, tabCount, isOnHomeTab0, hasModal, maxNavStack)) {
        return NO;
    }
    if (!executeAction) {
        return YES;
    }

    // 1. Dismiss presented modals over root cleanly
    if (hasModal && root.presentedViewController != nil) {
        [root dismissViewControllerAnimated:NO completion:nil];
    }

    // 2. Pop active/tab navigation stacks to root
    BOOL popAnimated = (!hasModal && isOnHomeTab0);
    NSMutableArray<UINavigationController *> *navsToPop = [NSMutableArray array];
    for (id candidate in @[
        effHeaderNav ?: [NSNull null],
        toolbarNav ?: [NSNull null],
        outerTabNav ?: [NSNull null],
        tab0Nav ?: [NSNull null]
    ]) {
        if ([candidate isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)candidate;
            if (nav.viewControllers.count > 1 && ![navsToPop containsObject:nav]) {
                [navsToPop addObject:nav];
            }
        }
    }
    for (UINavigationController *nav in navsToPop) {
        [nav popToRootViewControllerAnimated:popAnimated];
    }

    // 3. Switch UITabBarController back to Tab 0 respecting UITabBarControllerDelegate
    if (tabVC && tabCount >= 2 && !isOnHomeTab0) {
        id<UITabBarControllerDelegate> delegate = tabVC.delegate;
        if (firstModernTab) {
            SEL shouldSelectTabSel = sel_registerName("tabBarController:shouldSelectTab:");
            BOOL allowed = YES;
            if (delegate && [delegate respondsToSelector:shouldSelectTabSel]) {
                allowed = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(delegate, shouldSelectTabSel, tabVC, firstModernTab);
            }
            if (allowed) {
                pt_tabBarControllerSetSelectedTab(tabVC, firstModernTab);
            }
        } else if (tabVC.viewControllers.count > 0) {
            UIViewController *targetVC = tabVC.viewControllers.firstObject;
            BOOL allowed = YES;
            if (delegate && [delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)]) {
                allowed = [delegate tabBarController:tabVC shouldSelectViewController:targetVC];
            }
            if (allowed) {
                tabVC.selectedIndex = 0;
                if (delegate && [delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)]) {
                    [delegate tabBarController:tabVC didSelectViewController:targetVC];
                }
            }
        }
    }

    pt_scheduleRefreshForWindow(win);
    __weak UIWindow *weakWin = win;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *strongWin = weakWin;
        if (strongWin) {
            pt_scheduleRefreshForWindow(strongWin);
        }
    });
    return YES;
}

BOOL PTDuoQueryGlobalHomeStateForWindow(UIWindow * _Nullable window) {
    return pt_resolveGlobalHomeForWindow(window, NO);
}

BOOL PTDuoPerformGlobalHomeActionForWindow(UIWindow * _Nullable window) {
    return pt_resolveGlobalHomeForWindow(window, YES);
}

static UIResponder *pt_findFirstResponderInWindow(UIWindow *window) {
    if (!window) {
        return nil;
    }
    SEL firstRespSel = sel_registerName("firstResponder");
    if ([window respondsToSelector:firstRespSel]) {
        id r = ((id (*)(id, SEL))objc_msgSend)(window, firstRespSel);
        if ([r isKindOfClass:[UIResponder class]]) {
            return (UIResponder *)r;
        }
    }
    if ([window isFirstResponder]) {
        return window;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSInteger budget = 400;
    for (NSUInteger idx = 0; idx < queue.count && budget > 0; idx++) {
        UIView *v = queue[idx];
        budget--;
        if ([v isFirstResponder]) {
            return v;
        }
        for (UIView *sub in v.subviews) {
            [queue addObject:sub];
        }
    }
    return nil;
}

BOOL PTDuoWindowHasActiveTextInput(UIWindow * _Nullable window) {
    UIWindow *win = window ?: pt_findActivePrimaryWindow();
    UIResponder *first = pt_findFirstResponderInWindow(win);
    if (!first) {
        return NO;
    }
    if ([first isKindOfClass:[UITextField class]]) {
        return ((UITextField *)first).isEditing || [first isFirstResponder];
    }
    if ([first isKindOfClass:[UITextView class]]) {
        return ((UITextView *)first).isEditable;
    }
    if ([first isKindOfClass:[UISearchBar class]]) {
        return YES;
    }
    if ([first conformsToProtocol:@protocol(UITextInput)]) {
        NSString *cls = NSStringFromClass([first class]);
        if ([cls containsString:@"WKContent"] || [cls containsString:@"Web"]) {
            SEL editableSel = sel_registerName("isEditable");
            if ([first respondsToSelector:editableSel]) {
                return ((BOOL (*)(id, SEL))objc_msgSend)(first, editableSel);
            }
            @try {
                id val = [first valueForKey:@"isEditable"];
                if ([val isKindOfClass:[NSNumber class]]) {
                    return [val boolValue];
                }
            } @catch (NSException *ex) {
                (void)ex;
            }
            return NO;
        }
        return YES;
    }
    return NO;
}

static void pt_scheduleRefreshForWindow(UIWindow *window) {
    if (window
        && !pt_isWindowStructuralPrimaryCandidate(window)
        && objc_getAssociatedObject(window, kPTDuoWindowStateKey) == nil
        && pt_hostViewForWindow(window, NO) == nil) {
        return;
    }
    if (!window || !PTShouldEnableDuoVerticalBar()) {
        if (pt_duoHostLiveResizing) {
            if (window) {
                objc_setAssociatedObject(window, kPTDuoPendingLiveResizeRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return;
        }
        if (!window || pt_isEligiblePrimaryWindow(window)) {
            pt_scheduleGlobalBackRefresh();
        }
        return;
    }
    if (pt_duoHostLiveResizing) {
        objc_setAssociatedObject(window, kPTDuoPendingLiveResizeRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (![NSThread isMainThread]) {
        __weak UIWindow *weakWin = window;
        dispatch_async(dispatch_get_main_queue(), ^{
            pt_scheduleRefreshForWindow(weakWin);
        });
        return;
    }
    if ([objc_getAssociatedObject(window, kPTDuoWindowRefreshScheduledKey) boolValue]) {
        return;
    }
    objc_setAssociatedObject(window, kPTDuoWindowRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIWindow *weakWin = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *strongWin = weakWin;
        if (!strongWin) {
            return;
        }
        objc_setAssociatedObject(strongWin, kPTDuoWindowRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_refreshDuoVerticalBarForWindow(strongWin);
        if (pt_isEligiblePrimaryWindow(strongWin)) {
            pt_scheduleGlobalBackRefresh();
        }
    });
}

static UIWindow *pt_findActivePrimaryWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && pt_isEligiblePrimaryWindow(w)) {
                return w;
            }
        }
        for (UIWindow *w in ws.windows) {
            if (pt_isEligiblePrimaryWindow(w)) {
                return w;
            }
        }
    }
    return nil;
}

// MARK: - Swizzled UIKit Hooks

static UIEdgeInsets (*pt_origWindowSceneSafeArea)(UIWindow *, SEL, BOOL) = NULL;
static __thread NSInteger pt_duoBypassSceneSafeAreaHookDepth = 0;

static UIEdgeInsets pt_windowSceneSafeArea(UIWindow *self, SEL _cmd, BOOL includingStatusBar) {
    UIEdgeInsets insets = pt_origWindowSceneSafeArea
        ? pt_origWindowSceneSafeArea(self, _cmd, includingStatusBar)
        : UIEdgeInsetsZero;
    if (pt_duoBypassSceneSafeAreaHookDepth > 0) {
        return insets;
    }
    BOOL barActive = pt_isDuoVerticalBarActiveForWindow(self);
    CGFloat occupiedWidth = pt_windowOccupiedRightBarWidth(self);
    return PTDuoEffectiveSceneSafeAreaInsets(barActive, occupiedWidth, self.bounds.size, insets);
}

static UIEdgeInsets pt_adjustedSceneSafeAreaInsets(UIWindowScene *scene, UIEdgeInsets insets) {
    if (pt_duoBypassSceneSafeAreaHookDepth > 0) {
        return insets;
    }
    if (PTShouldEnableDuoVerticalBar()) {
        for (UIWindow *w in scene.windows) {
            if (pt_isEligiblePrimaryWindow(w)) {
                BOOL barActive = pt_isDuoVerticalBarActiveForWindow(w);
                CGFloat occupiedWidth = pt_windowOccupiedRightBarWidth(w);
                return PTDuoEffectiveSceneSafeAreaInsets(barActive, occupiedWidth, w.bounds.size, insets);
            }
        }
    }
    return insets;
}

static UIEdgeInsets (*pt_origSceneSafeAreaForOrientation)(UIWindowScene *, SEL, UIInterfaceOrientation, BOOL) = NULL;
static UIEdgeInsets pt_sceneSafeAreaForOrientation(UIWindowScene *self,
                                                   SEL _cmd,
                                                   UIInterfaceOrientation orientation,
                                                   BOOL statusBarHidden) {
    UIEdgeInsets insets = pt_origSceneSafeAreaForOrientation
        ? pt_origSceneSafeAreaForOrientation(self, _cmd, orientation, statusBarHidden)
        : UIEdgeInsetsZero;
    return pt_adjustedSceneSafeAreaInsets(self, insets);
}

static UIEdgeInsets (*pt_origSceneSafeAreaForOrientationOnly)(UIWindowScene *, SEL, UIInterfaceOrientation) = NULL;
static UIEdgeInsets pt_sceneSafeAreaForOrientationOnly(UIWindowScene *self,
                                                       SEL _cmd,
                                                       UIInterfaceOrientation orientation) {
    UIEdgeInsets insets = pt_origSceneSafeAreaForOrientationOnly
        ? pt_origSceneSafeAreaForOrientationOnly(self, _cmd, orientation)
        : UIEdgeInsetsZero;
    return pt_adjustedSceneSafeAreaInsets(self, insets);
}

// UIViewLayoutRegion factory/init hooks
static id (*pt_origRegionBarEdgeExtent)(id, SEL, UIRectEdge, CGFloat) = NULL;
static id pt_regionBarEdgeExtent(id self, SEL _cmd, UIRectEdge edge, CGFloat extent) {
    id r = pt_origRegionBarEdgeExtent ? pt_origRegionBarEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, YES, extent);
    return r;
}

static id (*pt_origRegionBarDirEdgeExtent)(id, SEL, NSDirectionalRectEdge, CGFloat) = NULL;
static id pt_regionBarDirEdgeExtent(id self, SEL _cmd, NSDirectionalRectEdge edge, CGFloat extent) {
    id r = pt_origRegionBarDirEdgeExtent ? pt_origRegionBarDirEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, YES, extent);
    return r;
}

static id (*pt_origRegionBarEdgeDefault)(id, SEL, UIRectEdge) = NULL;
static id pt_regionBarEdgeDefault(id self, SEL _cmd, UIRectEdge edge) {
    id r = pt_origRegionBarEdgeDefault ? pt_origRegionBarEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, NO, kPTDuoVerticalBarWidth);
    return r;
}

static id (*pt_origRegionBarDirEdgeDefault)(id, SEL, NSDirectionalRectEdge) = NULL;
static id pt_regionBarDirEdgeDefault(id self, SEL _cmd, NSDirectionalRectEdge edge) {
    id r = pt_origRegionBarDirEdgeDefault ? pt_origRegionBarDirEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, NO, kPTDuoVerticalBarWidth);
    return r;
}

static id (*pt_origInitBarEdgeExtent)(id, SEL, UIRectEdge, CGFloat) = NULL;
static id pt_initBarEdgeExtent(id self, SEL _cmd, UIRectEdge edge, CGFloat extent) {
    id r = pt_origInitBarEdgeExtent ? pt_origInitBarEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, YES, extent);
    return r;
}

static id (*pt_origInitBarDirEdgeExtent)(id, SEL, NSDirectionalRectEdge, CGFloat) = NULL;
static id pt_initBarDirEdgeExtent(id self, SEL _cmd, NSDirectionalRectEdge edge, CGFloat extent) {
    id r = pt_origInitBarDirEdgeExtent ? pt_origInitBarDirEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, YES, extent);
    return r;
}

static id (*pt_origInitBarEdgeDefault)(id, SEL, UIRectEdge) = NULL;
static id pt_initBarEdgeDefault(id self, SEL _cmd, UIRectEdge edge) {
    id r = pt_origInitBarEdgeDefault ? pt_origInitBarEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, NO, kPTDuoVerticalBarWidth);
    return r;
}

static id (*pt_origInitBarDirEdgeDefault)(id, SEL, NSDirectionalRectEdge) = NULL;
static id pt_initBarDirEdgeDefault(id self, SEL _cmd, NSDirectionalRectEdge edge) {
    id r = pt_origInitBarDirEdgeDefault ? pt_origInitBarDirEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, NO, kPTDuoVerticalBarWidth);
    return r;
}

// UIView layoutGuideForLayoutRegion: / edgeInsetsForLayoutRegion: / directionalEdgeInsetsForLayoutRegion:
static UIWindow *pt_windowForView(UIView *view) {
    if ([view isKindOfClass:[UIWindow class]]) {
        return (UIWindow *)view;
    }
    return view.window;
}

static void pt_markRightBarRegionQueriedCoalesced(UIView *view, CGFloat barExtent) {
    UIWindow *win = pt_windowForView(view);
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return;
    }
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(win, YES);
    CGFloat safeExtent = (isfinite(barExtent) && barExtent > 0.0) ? barExtent : kPTDuoVerticalBarWidth;
    BOOL changed = (!insetState.queriedRightBarRegion
                    || insetState.collapsedEmptyRightInset
                    || fabs(insetState.queriedRightBarExtent - safeExtent) > 0.5);
    insetState.queriedRightBarRegion = YES;
    insetState.queriedRightBarExtent = safeExtent;
    insetState.queriedRightBarTimestamp = CACurrentMediaTime();
    if (insetState.collapsedEmptyRightInset) {
        insetState.collapsedEmptyRightInset = NO;
    }
    // Coalesce onto next runloop pass only — never fire safe-area change notifications
    // synchronously inside a layout-region getter (avoids layout re-entrancy).
    if (changed) {
        pt_scheduleRefreshForWindow(win);
    }
}

static BOOL pt_matchActiveBarRegionMeta(UIView *view,
                                        id layoutRegion,
                                        UIRectEdge *outPhysicalEdge,
                                        CGFloat *outExtent) {
    if (!view || !layoutRegion || pt_isTaggedPointer(layoutRegion)) {
        return NO;
    }
    PTDuoBarLayoutRegionMeta *meta = objc_getAssociatedObject(layoutRegion, kPTDuoBarRegionMetaKey);
    if (!meta) {
        return NO;
    }
    UIWindow *win = pt_windowForView(view) ?: pt_findActivePrimaryWindow();
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return NO;
    }
    UIRectEdge physicalEdge = PTDuoResolvePhysicalBarEdge(meta.isDirectional,
                                                          meta.edge,
                                                          meta.directionalEdge,
                                                          view.effectiveUserInterfaceLayoutDirection);
    if (physicalEdge == UIRectEdgeNone) {
        return NO;
    }
    CGFloat viewSpan = (physicalEdge == UIRectEdgeTop || physicalEdge == UIRectEdgeBottom)
        ? CGRectGetHeight(view.bounds)
        : CGRectGetWidth(view.bounds);
    CGFloat extent = PTDuoResolveBarExtent(meta.hasExplicitExtent, meta.extent, viewSpan);
    if (outPhysicalEdge) { *outPhysicalEdge = physicalEdge; }
    if (outExtent) { *outExtent = extent; }
    if (physicalEdge == UIRectEdgeRight) {
        pt_markRightBarRegionQueriedCoalesced(view, extent);
    }
    return YES;
}

static UIEdgeInsets (*pt_origEdgeInsetsForLayoutRegion)(UIView *, SEL, id) = NULL;
static NSDirectionalEdgeInsets (*pt_origDirectionalEdgeInsetsForLayoutRegion)(UIView *, SEL, id) = NULL;
static UIEdgeInsets (*pt_origWindowSceneSafeArea)(UIWindow *, SEL, BOOL);

static UIEdgeInsets pt_windowSuperSafeAreaInsets(UIWindow *window) {
    if (!window) {
        return UIEdgeInsetsZero;
    }
    static Method sUIWindowSafeAreaMethod = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class uiWinCls = [UIWindow class];
        if (uiWinCls) {
            sUIWindowSafeAreaMethod = class_getInstanceMethod(uiWinCls, @selector(safeAreaInsets));
        }
    });
    if (sUIWindowSafeAreaMethod) {
        IMP imp = method_getImplementation(sUIWindowSafeAreaMethod);
        if (imp) {
            typedef UIEdgeInsets (*pt_safe_area_fn)(id, SEL);
            return ((pt_safe_area_fn)imp)(window, @selector(safeAreaInsets));
        }
    }
    return window.safeAreaInsets;
}

static UIEdgeInsets pt_windowNativeSafeAreaInsets(UIWindow *window) {
    if (!window) {
        return UIEdgeInsetsZero;
    }
    // Bypass our UIWindowScene safe-area hooks so _sceneSafeAreaInsetsIncludingStatusBar:
    // returns true OS native insets rather than our synthetic 60pt augmentation.
    if (pt_origWindowSceneSafeArea) {
        pt_duoBypassSceneSafeAreaHookDepth++;
        @try {
            return pt_origWindowSceneSafeArea(window, sel_registerName("_sceneSafeAreaInsetsIncludingStatusBar:"), YES);
        } @finally {
            pt_duoBypassSceneSafeAreaHookDepth--;
        }
    }
    SEL sceneSASel = sel_registerName("_sceneSafeAreaInsetsIncludingStatusBar:");
    if ([window respondsToSelector:sceneSASel]) {
        pt_duoBypassSceneSafeAreaHookDepth++;
        @try {
            typedef UIEdgeInsets (*pt_scene_sa_fn)(id, SEL, BOOL);
            return ((pt_scene_sa_fn)objc_msgSend)(window, sceneSASel, YES);
        } @finally {
            pt_duoBypassSceneSafeAreaHookDepth--;
        }
    }
    return UIEdgeInsetsZero;
}

UIEdgeInsets pt_duoDiagnosticWindowSuperSafeAreaInsets(UIWindow *window) {
    return pt_windowSuperSafeAreaInsets(window);
}

UIEdgeInsets pt_duoDiagnosticWindowTrueNativeSafeAreaInsets(UIWindow *window) {
    return pt_windowNativeSafeAreaInsets(window);
}

static CGFloat pt_windowTrafficLightTopClearance(UIWindow *window) {
    if (!window) {
        return 0.0;
    }
    BOOL barActive = pt_isDuoVerticalBarActiveForWindow(window);
    BOOL hideTitleBar = PlaySettings.shared.hideTitleBar;
    UIEdgeInsets trueNative = pt_windowNativeSafeAreaInsets(window);
    return PTDuoTrafficLightTopClearance(barActive, hideTitleBar, window.bounds.size, trueNative);
}

static CGFloat pt_viewTrafficLightTopClearance(UIView *view, UIWindow *win) {
    if (!view || !win) {
        return 0.0;
    }
    CGFloat winClearance = pt_windowTrafficLightTopClearance(win);
    if (winClearance <= 0.5) {
        return 0.0;
    }
    CGRect viewInWin = (view == win) ? win.bounds : [view convertRect:view.bounds toView:win];
    if (!isfinite(viewInWin.origin.y) || !isfinite(viewInWin.size.height) || viewInWin.size.height <= winClearance + 40.0) {
        return 0.0;
    }
    CGFloat minY = MAX(0.0, CGRectGetMinY(viewInWin));
    CGFloat remaining = MAX(0.0, winClearance - minY);
    return MIN(remaining, CGRectGetHeight(view.bounds) * 0.25);
}

static CGFloat pt_windowNativeRightSafeAreaInset(UIWindow *window) {
    UIEdgeInsets native = pt_windowNativeSafeAreaInsets(window);
    return (isfinite(native.right) && native.right > 0.0) ? native.right : 0.0;
}

static CGFloat pt_syntheticRightSafeAreaDeltaForView(UIView *view, UIWindow *win) {
    if (!view || !win) {
        return 0.0;
    }
    CGFloat winRight = pt_windowSuperSafeAreaInsets(win).right;
    CGFloat nativeWinRight = pt_windowNativeRightSafeAreaInset(win);
    CGFloat winDelta = (isfinite(winRight) && winRight > nativeWinRight) ? (winRight - nativeWinRight) : 0.0;
    if (winDelta <= 0.5) {
        return 0.0;
    }
    CGFloat viewRight = ([view isKindOfClass:[UIWindow class]] && view == win)
        ? winRight
        : view.safeAreaInsets.right;
    if (!isfinite(viewRight) || viewRight <= 0.5) {
        return 0.0;
    }
    return MIN(viewRight, winDelta);
}

static UILayoutGuide *pt_barLayoutGuideForView(UIView *view,
                                               UIRectEdge physicalEdge,
                                               UIEdgeInsets edgeInsets,
                                               CGFloat extent) {
    if (!view || (physicalEdge != UIRectEdgeRight && physicalEdge != UIRectEdgeLeft)) {
        return nil;
    }
    NSMutableDictionary<NSString *, UILayoutGuide *> *guides =
        objc_getAssociatedObject(view, kPTDuoViewBarGuidesKey);
    if (!guides) {
        guides = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(view, kPTDuoViewBarGuidesKey, guides, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *key = [NSString stringWithFormat:@"%lu.%.1f", (unsigned long)physicalEdge, extent];
    UILayoutGuide *guide = guides[key];
    CGFloat topC = isfinite(edgeInsets.top) ? edgeInsets.top : 0.0;
    CGFloat bottomC = isfinite(edgeInsets.bottom) ? edgeInsets.bottom : 0.0;
    CGFloat sideC = (physicalEdge == UIRectEdgeRight)
        ? (isfinite(edgeInsets.right) ? edgeInsets.right : 0.0)
        : (isfinite(edgeInsets.left) ? edgeInsets.left : 0.0);

    if (!guide || guide.owningView != view) {
        guide = [[UILayoutGuide alloc] init];
        guide.identifier = [NSString stringWithFormat:@"PTDuoVerticalBarRegionGuide.%@", key];
        [view addLayoutGuide:guide];

        NSLayoutConstraint *topConstraint = [guide.topAnchor constraintEqualToAnchor:view.topAnchor constant:topC];
        NSLayoutConstraint *bottomConstraint = [guide.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-bottomC];
        NSLayoutConstraint *sideConstraint = (physicalEdge == UIRectEdgeRight)
            ? [guide.rightAnchor constraintEqualToAnchor:view.rightAnchor constant:-sideC]
            : [guide.leftAnchor constraintEqualToAnchor:view.leftAnchor constant:sideC];
        NSLayoutConstraint *widthConstraint = [guide.widthAnchor constraintEqualToConstant:extent];
        widthConstraint.priority = UILayoutPriorityRequired - 1;

        [NSLayoutConstraint activateConstraints:@[
            topConstraint,
            bottomConstraint,
            sideConstraint,
            widthConstraint,
        ]];
        objc_setAssociatedObject(guide, kPTDuoGuideConstraintsKey,
                                 @[topConstraint, bottomConstraint, sideConstraint, widthConstraint],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        guides[key] = guide;
    } else {
        NSArray<NSLayoutConstraint *> *cs = objc_getAssociatedObject(guide, kPTDuoGuideConstraintsKey);
        if (cs.count == 4) {
            cs[0].constant = topC;
            cs[1].constant = -bottomC;
            cs[2].constant = (physicalEdge == UIRectEdgeRight) ? -sideC : sideC;
            cs[3].constant = extent;
        }
    }
    return guide;
}

static UILayoutGuide *(*pt_origLayoutGuideForLayoutRegion)(UIView *, SEL, id) = NULL;
static UILayoutGuide *pt_layoutGuideForLayoutRegion(UIView *self, SEL _cmd, id layoutRegion) {
    UIRectEdge physicalEdge = UIRectEdgeNone;
    CGFloat extent = 0.0;
    BOOL matchedMeta = pt_matchActiveBarRegionMeta(self, layoutRegion, &physicalEdge, &extent);

    // Native-first: prefer UIKit's native bar layout guide whenever available.
    UILayoutGuide *nativeGuide = pt_origLayoutGuideForLayoutRegion
        ? pt_origLayoutGuideForLayoutRegion(self, _cmd, layoutRegion)
        : nil;

    UIWindow *win = pt_windowForView(self);
    if (win && pt_isDuoVerticalBarActiveForWindow(win) && layoutRegion && pt_origEdgeInsetsForLayoutRegion) {
        UIEdgeInsets probeInsets = pt_origEdgeInsetsForLayoutRegion(self, @selector(edgeInsetsForLayoutRegion:), layoutRegion);
        CGFloat synthRight = pt_syntheticRightSafeAreaDeltaForView(self, win);
        CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
        BOOL isRightBar = NO;
        CGFloat inferredExtent = 0.0;
        UIEdgeInsets adjustedInsets = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(probeInsets,
                                                                                    CGRectGetWidth(self.bounds),
                                                                                    CGRectGetHeight(self.bounds),
                                                                                    synthRight,
                                                                                    topClearance,
                                                                                    &isRightBar,
                                                                                    &inferredExtent);
        if (isRightBar) {
            pt_markRightBarRegionQueriedCoalesced(self, inferredExtent);
            BOOL topAdjusted = (adjustedInsets.top > probeInsets.top + 0.5);
            if (synthRight > 0.5 || topAdjusted || !nativeGuide) {
                return pt_barLayoutGuideForView(self, UIRectEdgeRight, adjustedInsets, inferredExtent);
            }
        }
    }

    if (nativeGuide) {
        return nativeGuide;
    }

    if (matchedMeta && (physicalEdge == UIRectEdgeRight || physicalEdge == UIRectEdgeLeft)) {
        return pt_barLayoutGuideForView(self, physicalEdge, UIEdgeInsetsZero, extent);
    }
    return nil;
}

static UIEdgeInsets pt_edgeInsetsForLayoutRegion(UIView *self, SEL _cmd, id layoutRegion) {
    UIRectEdge physicalEdge = UIRectEdgeNone;
    CGFloat extent = 0.0;
    BOOL matchedMeta = pt_matchActiveBarRegionMeta(self, layoutRegion, &physicalEdge, &extent);

    // Native-first: prefer UIKit's native edgeInsetsForLayoutRegion: whenever it returns a valid result.
    UIEdgeInsets nativeInsets = pt_origEdgeInsetsForLayoutRegion
        ? pt_origEdgeInsetsForLayoutRegion(self, _cmd, layoutRegion)
        : UIEdgeInsetsZero;

    CGFloat viewW = CGRectGetWidth(self.bounds);
    CGFloat viewH = CGRectGetHeight(self.bounds);
    UIWindow *win = pt_windowForView(self);
    BOOL barActive = (win && pt_isDuoVerticalBarActiveForWindow(win));

    if (barActive) {
        CGFloat synthRight = pt_syntheticRightSafeAreaDeltaForView(self, win);
        CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
        BOOL isRightBar = NO;
        CGFloat inferredExtent = 0.0;
        UIEdgeInsets adjusted = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(nativeInsets, viewW, viewH, synthRight, topClearance, &isRightBar, &inferredExtent);
        if (isRightBar) {
            pt_markRightBarRegionQueriedCoalesced(self, inferredExtent);
            return adjusted;
        }
    }

    if (!matchedMeta) {
        return nativeInsets;
    }

    BOOL nativeFinite = isfinite(nativeInsets.top) && isfinite(nativeInsets.left)
        && isfinite(nativeInsets.bottom) && isfinite(nativeInsets.right);
    BOOL nativeNonZero = (fabs(nativeInsets.top) > 0.001 || fabs(nativeInsets.left) > 0.001
                          || fabs(nativeInsets.bottom) > 0.001 || fabs(nativeInsets.right) > 0.001);
    CGFloat span = (physicalEdge == UIRectEdgeTop || physicalEdge == UIRectEdgeBottom) ? viewH : viewW;
    if (nativeFinite && (nativeNonZero || span <= extent)) {
        return nativeInsets;
    }

    // Fallback computed from the exact bar-strip rect (matching native UIKit 27.1/27.2 semantics).
    UIEdgeInsets fallback = PTDuoBarRegionEdgeInsets(physicalEdge, viewW, viewH, extent);
    if (barActive && (physicalEdge == UIRectEdgeRight || physicalEdge == UIRectEdgeLeft)) {
        CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
        if (fallback.top < topClearance) {
            fallback.top = topClearance;
        }
    }
    return fallback;
}

static NSDirectionalEdgeInsets pt_directionalEdgeInsetsForLayoutRegion(UIView *self, SEL _cmd, id layoutRegion) {
    UIRectEdge physicalEdge = UIRectEdgeNone;
    CGFloat extent = 0.0;
    BOOL matchedMeta = pt_matchActiveBarRegionMeta(self, layoutRegion, &physicalEdge, &extent);

    // Native-first: prefer UIKit's native directionalEdgeInsetsForLayoutRegion: whenever valid.
    NSDirectionalEdgeInsets nativeDir = pt_origDirectionalEdgeInsetsForLayoutRegion
        ? pt_origDirectionalEdgeInsetsForLayoutRegion(self, _cmd, layoutRegion)
        : NSDirectionalEdgeInsetsZero;

    CGFloat viewW = CGRectGetWidth(self.bounds);
    CGFloat viewH = CGRectGetHeight(self.bounds);
    UIWindow *win = pt_windowForView(self);
    BOOL barActive = (win && pt_isDuoVerticalBarActiveForWindow(win));

    if (barActive) {
        CGFloat synthRight = pt_syntheticRightSafeAreaDeltaForView(self, win);
        CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
        BOOL isRightBar = NO;
        CGFloat inferredExtent = 0.0;
        NSDirectionalEdgeInsets adjusted = PTDuoAdjustRightBarDirectionalEdgeInsetsWithTopClearance(
            nativeDir,
            self.effectiveUserInterfaceLayoutDirection,
            viewW,
            viewH,
            synthRight,
            topClearance,
            &isRightBar,
            &inferredExtent);
        if (isRightBar) {
            pt_markRightBarRegionQueriedCoalesced(self, inferredExtent);
            return adjusted;
        }
    }

    if (!matchedMeta) {
        return nativeDir;
    }

    BOOL nativeFinite = isfinite(nativeDir.top) && isfinite(nativeDir.leading)
        && isfinite(nativeDir.bottom) && isfinite(nativeDir.trailing);
    BOOL nativeNonZero = (fabs(nativeDir.top) > 0.001 || fabs(nativeDir.leading) > 0.001
                          || fabs(nativeDir.bottom) > 0.001 || fabs(nativeDir.trailing) > 0.001);
    CGFloat span = (physicalEdge == UIRectEdgeTop || physicalEdge == UIRectEdgeBottom) ? viewH : viewW;
    if (nativeFinite && (nativeNonZero || span <= extent)) {
        return nativeDir;
    }

    // Fallback computed from the exact bar-strip rect mapped via effectiveUserInterfaceLayoutDirection.
    NSDirectionalEdgeInsets fallback = PTDuoBarRegionDirectionalEdgeInsets(physicalEdge,
                                                                           self.effectiveUserInterfaceLayoutDirection,
                                                                           viewW,
                                                                           viewH,
                                                                           extent);
    if (barActive && (physicalEdge == UIRectEdgeRight || physicalEdge == UIRectEdgeLeft)) {
        CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
        if (fallback.top < topClearance) {
            fallback.top = topClearance;
        }
    }
    return fallback;
}

// MARK: - Swift UIView.LayoutRegion Interposes (iOS 26+/27.1 UIKitCore Swift entry points)
// Swift callers of UIView.edgeInsets(for:) / directionalEdgeInsets(for:) / layoutGuide(for:)
// call UIKitCore's exported Swift methods directly, bypassing ObjC UIView selectors.

extern UIEdgeInsets pt_swift_UIView_edgeInsetsForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self)
    __attribute__((swiftcall, weak_import))
    __asm__("_$sSo6UIViewC5UIKitE10edgeInsets3forSo06UIEdgeD0VAbCE12LayoutRegionV_tF");

extern NSDirectionalEdgeInsets pt_swift_UIView_directionalEdgeInsetsForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self)
    __attribute__((swiftcall, weak_import))
    __asm__("_$sSo6UIViewC5UIKitE21directionalEdgeInsets3forSo013NSDirectionaldE0VAbCE12LayoutRegionV_tF");

extern UILayoutGuide *pt_swift_UIView_layoutGuideForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self)
    __attribute__((swiftcall, weak_import))
    __asm__("_$sSo6UIViewC5UIKitE11layoutGuide3forSo08UILayoutD0CAbCE12LayoutRegionV_tF");

typedef UIEdgeInsets (*pt_swift_edgeInsets_fn)(const void *, __attribute__((swift_context)) UIView *) __attribute__((swiftcall));
typedef NSDirectionalEdgeInsets (*pt_swift_dirEdgeInsets_fn)(const void *, __attribute__((swift_context)) UIView *) __attribute__((swiftcall));
typedef UILayoutGuide *(*pt_swift_layoutGuide_fn)(const void *, __attribute__((swift_context)) UIView *) __attribute__((swiftcall));

__attribute__((swiftcall))
static UIEdgeInsets pt_hook_swift_edgeInsetsForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self);
__attribute__((swiftcall))
static NSDirectionalEdgeInsets pt_hook_swift_directionalEdgeInsetsForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self);
__attribute__((swiftcall))
static UILayoutGuide *pt_hook_swift_layoutGuideForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self);

DYLD_INTERPOSE(pt_hook_swift_edgeInsetsForLayoutRegion, pt_swift_UIView_edgeInsetsForLayoutRegion)
DYLD_INTERPOSE(pt_hook_swift_directionalEdgeInsetsForLayoutRegion, pt_swift_UIView_directionalEdgeInsetsForLayoutRegion)
DYLD_INTERPOSE(pt_hook_swift_layoutGuideForLayoutRegion, pt_swift_UIView_layoutGuideForLayoutRegion)

__attribute__((swiftcall))
static UIEdgeInsets pt_hook_swift_edgeInsetsForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self) {
    UIEdgeInsets orig = DYLD_INTERPOSE_ORIG(pt_swift_edgeInsets_fn, pt_swift_UIView_edgeInsetsForLayoutRegion)(region, self);
    if (!pt_duoVerticalBarInstalled || !self || ![NSThread isMainThread] || !PTShouldEnableDuoVerticalBar()) {
        return orig;
    }
    UIWindow *win = pt_windowForView(self);
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return orig;
    }
    CGFloat synthRight = pt_syntheticRightSafeAreaDeltaForView(self, win);
    CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
    BOOL isRightBar = NO;
    CGFloat barExtent = 0.0;
    UIEdgeInsets adjusted = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(orig,
                                                                          CGRectGetWidth(self.bounds),
                                                                          CGRectGetHeight(self.bounds),
                                                                          synthRight,
                                                                          topClearance,
                                                                          &isRightBar,
                                                                          &barExtent);
    if (isRightBar) {
        pt_markRightBarRegionQueriedCoalesced(self, barExtent);
        return adjusted;
    }
    return orig;
}

__attribute__((swiftcall))
static NSDirectionalEdgeInsets pt_hook_swift_directionalEdgeInsetsForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self) {
    NSDirectionalEdgeInsets orig = DYLD_INTERPOSE_ORIG(pt_swift_dirEdgeInsets_fn, pt_swift_UIView_directionalEdgeInsetsForLayoutRegion)(region, self);
    if (!pt_duoVerticalBarInstalled || !self || ![NSThread isMainThread] || !PTShouldEnableDuoVerticalBar()) {
        return orig;
    }
    UIWindow *win = pt_windowForView(self);
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return orig;
    }
    CGFloat synthRight = pt_syntheticRightSafeAreaDeltaForView(self, win);
    CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
    BOOL isRightBar = NO;
    CGFloat barExtent = 0.0;
    NSDirectionalEdgeInsets adjusted = PTDuoAdjustRightBarDirectionalEdgeInsetsWithTopClearance(
        orig,
        self.effectiveUserInterfaceLayoutDirection,
        CGRectGetWidth(self.bounds),
        CGRectGetHeight(self.bounds),
        synthRight,
        topClearance,
        &isRightBar,
        &barExtent);
    if (isRightBar) {
        pt_markRightBarRegionQueriedCoalesced(self, barExtent);
        return adjusted;
    }
    return orig;
}

__attribute__((swiftcall))
static UILayoutGuide *pt_hook_swift_layoutGuideForLayoutRegion(const void *region, __attribute__((swift_context)) UIView *self) {
    if (pt_duoVerticalBarInstalled && self && [NSThread isMainThread] && PTShouldEnableDuoVerticalBar()) {
        UIWindow *win = pt_windowForView(self);
        pt_swift_edgeInsets_fn origEdgeFn = DYLD_INTERPOSE_ORIG(pt_swift_edgeInsets_fn, pt_swift_UIView_edgeInsetsForLayoutRegion);
        if (win && pt_isDuoVerticalBarActiveForWindow(win) && origEdgeFn != NULL) {
            UIEdgeInsets origInsets = origEdgeFn(region, self);
            CGFloat synthRight = pt_syntheticRightSafeAreaDeltaForView(self, win);
            CGFloat topClearance = pt_viewTrafficLightTopClearance(self, win);
            BOOL isRightBar = NO;
            CGFloat barExtent = 0.0;
            UIEdgeInsets adjustedInsets = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(origInsets,
                                                                                        CGRectGetWidth(self.bounds),
                                                                                        CGRectGetHeight(self.bounds),
                                                                                        synthRight,
                                                                                        topClearance,
                                                                                        &isRightBar,
                                                                                        &barExtent);
            if (isRightBar) {
                pt_markRightBarRegionQueriedCoalesced(self, barExtent);
                BOOL topAdjusted = (adjustedInsets.top > origInsets.top + 0.5);
                if (synthRight > 0.5 || topAdjusted) {
                    return pt_barLayoutGuideForView(self, UIRectEdgeRight, adjustedInsets, barExtent);
                }
            }
        }
    }
    return DYLD_INTERPOSE_ORIG(pt_swift_layoutGuide_fn, pt_swift_UIView_layoutGuideForLayoutRegion)(region, self);
}

static CGFloat pt_windowNativeTopSafeAreaInset(UIWindow *window) {
    if (!window) {
        return 0.0;
    }
    UIEdgeInsets native = pt_windowNativeSafeAreaInsets(window);
    if (isfinite(native.top) && native.top > 0.0) {
        return native.top;
    }
    CGFloat safeTop = pt_windowSuperSafeAreaInsets(window).top;
    return (isfinite(safeTop) && safeTop > 0.0) ? safeTop : 0.0;
}

static BOOL pt_resolvePrefersStatusBarHiddenForWindow(UIWindow *window) {
    if (!window || !window.rootViewController) {
        return NO;
    }
    UIViewController *current = pt_topPresentedFullscreenController(window.rootViewController, window.bounds);
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    for (NSInteger depth = 0; depth < 16 && current != nil; depth++) {
        if ([visited containsObject:current]) {
            break;
        }
        [visited addObject:current];

        UIViewController *next = current.childViewControllerForStatusBarHidden;
        BOOL explicitChild = (next != nil);
        if (!explicitChild && current.prefersStatusBarHidden) {
            return YES;
        }
        if (!next) {
            if ([current isKindOfClass:[UINavigationController class]]) {
                next = ((UINavigationController *)current).topViewController;
            } else if ([current isKindOfClass:[UITabBarController class]]) {
                next = pt_selectedViewControllerForTabBarController((UITabBarController *)current);
            } else if ([current isKindOfClass:[UISplitViewController class]]) {
                next = ((UISplitViewController *)current).viewControllers.lastObject;
            } else {
                next = pt_largestVisibleChildViewController(current, visited);
            }
        }
        if (!next || next == current) {
            return current.prefersStatusBarHidden;
        }
        current = next;
    }
    return current ? current.prefersStatusBarHidden : NO;
}

static BOOL pt_resolvedStatusBarHiddenForManager(id manager, BOOL originalHidden) {
    if (!pt_duoVerticalBarInstalled || !manager || ![NSThread isMainThread] || !PTShouldEnableDuoVerticalBar()) {
        return originalHidden;
    }
    UIWindowScene *scene = [manager respondsToSelector:@selector(windowScene)]
        ? ((UIWindowScene *(*)(id, SEL))objc_msgSend)(manager, @selector(windowScene))
        : nil;
    UIWindow *win = nil;
    if (scene) {
        for (UIWindow *w in scene.windows) {
            if (w.isKeyWindow && pt_isEligiblePrimaryWindow(w)) {
                win = w;
                break;
            }
        }
        if (!win) {
            for (UIWindow *w in scene.windows) {
                if (pt_isEligiblePrimaryWindow(w)) {
                    win = w;
                    break;
                }
            }
        }
    }
    if (!win) {
        win = pt_findActivePrimaryWindow();
    }
    BOOL barActive = (win != nil && pt_isDuoVerticalBarActiveForWindow(win));
    BOOL vcPrefersHidden = barActive ? pt_resolvePrefersStatusBarHiddenForWindow(win) : originalHidden;
    return PTDuoResolveStatusBarHidden(barActive, originalHidden, vcPrefersHidden);
}

static BOOL (*pt_origStatusBarManagerIsHidden)(id, SEL) = NULL;
static BOOL pt_statusBarManagerIsHidden(id self, SEL _cmd) {
    BOOL orig = pt_origStatusBarManagerIsHidden ? pt_origStatusBarManagerIsHidden(self, _cmd) : YES;
    return pt_resolvedStatusBarHiddenForManager(self, orig);
}

static BOOL (*pt_origStatusBarManagerStatusBarHidden)(id, SEL) = NULL;
static BOOL pt_statusBarManagerStatusBarHidden(id self, SEL _cmd) {
    BOOL orig = pt_origStatusBarManagerStatusBarHidden ? pt_origStatusBarManagerStatusBarHidden(self, _cmd) : YES;
    return pt_resolvedStatusBarHiddenForManager(self, orig);
}

static NSArray *(*pt_origViewSceneRegionsWithTypes)(UIView *, SEL, unsigned char) = NULL;
static NSArray *pt_viewSceneRegionsWithTypes(UIView *self, SEL _cmd, unsigned char types) {
    NSArray *orig = pt_origViewSceneRegionsWithTypes
        ? pt_origViewSceneRegionsWithTypes(self, _cmd, types)
        : @[];
    // Option bit (1 << 1) corresponds to UIViewReservedRegionKind.occlusion (type = 1).
    if (!pt_duoVerticalBarInstalled
        || !self
        || ![NSThread isMainThread]
        || !PTShouldEnableDuoVerticalBar()
        || (types & (1 << 1)) == 0
        || orig.count > 0) {
        return orig;
    }
    UIWindow *win = pt_windowForView(self);
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return orig;
    }
    CGFloat nativeSafeTop = pt_windowNativeTopSafeAreaInset(win);
    CGFloat hostTopPillMaxY = 0.0;
    PTDuoVerticalBarHostView *host = pt_hostViewForWindow(win, NO);
    if (host && !host.hidden && host.topStackView && !host.topStackView.hidden) {
        if (host.backPill && !host.backPill.hidden && CGRectGetHeight(host.backPill.bounds) > 1.0) {
            CGRect r = [host.backPill convertRect:host.backPill.bounds toView:win];
            if (isfinite(CGRectGetMaxY(r))) {
                hostTopPillMaxY = MAX(hostTopPillMaxY, CGRectGetMaxY(r));
            }
        }
        if (host.leadingPill && !host.leadingPill.hidden && CGRectGetHeight(host.leadingPill.bounds) > 1.0) {
            CGRect r = [host.leadingPill convertRect:host.leadingPill.bounds toView:win];
            if (isfinite(CGRectGetMaxY(r))) {
                hostTopPillMaxY = MAX(hostTopPillMaxY, CGRectGetMaxY(r));
            }
        }
        if (host.itemsPill && !host.itemsPill.hidden && CGRectGetHeight(host.itemsPill.bounds) > 1.0) {
            CGRect r = [host.itemsPill convertRect:host.itemsPill.bounds toView:win];
            if (isfinite(CGRectGetMaxY(r))) {
                hostTopPillMaxY = MAX(hostTopPillMaxY, CGRectGetMaxY(r));
            }
        }
    }
    CGFloat occupiedRightWidth = pt_windowOccupiedRightBarWidth(win);
    CGRect refFrame = PTDuoTopRightOcclusionRectForOccupiedWidth(win.bounds,
                                                                 nativeSafeTop,
                                                                 hostTopPillMaxY,
                                                                 occupiedRightWidth);
    if (CGRectIsNull(refFrame) || CGRectIsEmpty(refFrame)) {
        return orig;
    }
    Class srCls = NSClassFromString(@"_UISceneRegion");
    SEL initSel = sel_registerName("_initWithIdentifier:referenceFrame:type:active:margins:motionBodyIdentifier:");
    if (!srCls || ![srCls instancesRespondToSelector:initSel]) {
        return orig;
    }
    typedef id (*pt_alloc_fn)(Class, SEL);
    typedef id (*pt_sr_init_fn)(id, SEL, NSString *, CGRect, NSUInteger, BOOL, UIEdgeInsets, id);
    id obj = ((pt_alloc_fn)objc_msgSend)(srCls, @selector(alloc));
    id region = ((pt_sr_init_fn)objc_msgSend)(obj,
                                              initSel,
                                              @"PTDuoTopRightOcclusion",
                                              refFrame,
                                              1, // _UISceneRegionType occlusion
                                              YES,
                                              UIEdgeInsetsZero,
                                              nil);
    if (!region) {
        return orig;
    }
    return @[region];
}

// Lifecycle & Configuration Refresh Hooks
static void (*pt_origWindowMakeKeyAndVisible)(UIWindow *, SEL) = NULL;
static void pt_windowMakeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (pt_origWindowMakeKeyAndVisible) {
        pt_origWindowMakeKeyAndVisible(self, _cmd);
    }
    pt_scheduleRefreshForWindow(self);
}

static void (*pt_origWindowSetRootVC)(UIWindow *, SEL, UIViewController *) = NULL;
static void pt_windowSetRootVC(UIWindow *self, SEL _cmd, UIViewController *vc) {
    if (pt_origWindowSetRootVC) {
        pt_origWindowSetRootVC(self, _cmd, vc);
    }
    pt_scheduleRefreshForWindow(self);
}

static void (*pt_origWindowLayoutSubviews)(UIWindow *, SEL) = NULL;
static void pt_windowLayoutSubviews(UIWindow *self, SEL _cmd) {
    if (pt_origWindowLayoutSubviews) {
        pt_origWindowLayoutSubviews(self, _cmd);
    }
    if (!pt_isEligiblePrimaryWindow(self)) {
        return;
    }
    CGSize currentSize = self.bounds.size;
    NSValue *lastSizeVal = objc_getAssociatedObject(self, kPTDuoWindowLastLayoutSizeKey);
    BOOL sizeChanged = (!lastSizeVal
                        || fabs(lastSizeVal.CGSizeValue.width - currentSize.width) > 0.5
                        || fabs(lastSizeVal.CGSizeValue.height - currentSize.height) > 0.5);
    if (sizeChanged) {
        CGSize baselineSize = lastSizeVal ? lastSizeVal.CGSizeValue : currentSize;
        if (!pt_duoHostLiveResizing || objc_getAssociatedObject(self, kPTDuoLastTransitionSizeKey) == nil) {
            pt_seedWindowTransitionSizeBaselineIfNeeded(self, baselineSize);
        }
        objc_setAssociatedObject(self,
                                 kPTDuoWindowLastLayoutSizeKey,
                                 [NSValue valueWithCGSize:currentSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (pt_duoHostLiveResizing) {
            objc_setAssociatedObject(self, kPTDuoPendingLiveResizeRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            PTDuoVerticalBarHostView *host = pt_hostViewForWindow(self, NO);
            if (host && !host.hidden) {
                if (currentSize.width >= kPTDuoVerticalBarMinWindowWidth
                    && currentSize.height >= kPTDuoVerticalBarMinWindowHeight) {
                    CGRect targetFrame = CGRectMake(currentSize.width - kPTDuoVerticalBarWidth,
                                                    0.0,
                                                    kPTDuoVerticalBarWidth,
                                                    currentSize.height);
                    if (!CGRectEqualToRect(host.frame, targetFrame)) {
                        host.frame = targetFrame;
                    }
                } else {
                    [host hideAndRestore];
                }
            }
            return;
        }
        PTDuoWindowInsetState *insetState = pt_insetStateForWindow(self, NO);
        if (insetState) {
            insetState.forceReprobe = YES;
        }
        pt_scheduleRefreshForWindow(self);
        return;
    }
}

static void (*pt_origVCSetNeedsUpdateVerticalBar)(UIViewController *, SEL) = NULL;
static void pt_vcSetNeedsUpdateVerticalBar(UIViewController *self, SEL _cmd) {
    if (pt_origVCSetNeedsUpdateVerticalBar) {
        pt_origVCSetNeedsUpdateVerticalBar(self, _cmd);
    }
    if (pt_duoRefreshDepth > 0 || pt_duoInternalSafeAreaNotifyDepth > 0) {
        return;
    }
    UIWindow *win = self.viewIfLoaded.window;
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void pt_beginProbeOnTransitionIfNeeded(UIWindow *win, UIViewController *targetVC) {
    if (!win || ![NSThread isMainThread] || pt_duoRefreshDepth > 0) {
        return;
    }
    if (!pt_isEligiblePrimaryWindow(win) || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return;
    }
    if (targetVC && pt_preferredVerticalBarBehaviorForVC(targetVC) == 1) {
        return;
    }
    PTDuoWindowInsetState *insetState = pt_insetStateForWindow(win, YES);
    if (insetState.collapsedEmptyRightInset || insetState.occupiedRightBarWidth <= 0.5) {
        insetState.collapsedEmptyRightInset = NO;
        insetState.probingRightInset = YES;
        insetState.queriedRightBarRegion = NO;
        insetState.queriedRightBarExtent = 0.0;
        insetState.queriedRightBarTimestamp = 0.0;
        insetState.occupiedRightBarWidth = kPTDuoVerticalBarWidth;
        insetState.forceReprobe = YES;
        CGFloat probeExpectedRight = PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(
            YES, kPTDuoVerticalBarWidth, pt_windowNativeRightSafeAreaInset(win));
        pt_notifySafeAreaInsetsChanged(win, probeExpectedRight);
    }
}

static void (*pt_origVCViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void pt_vcViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (pt_origVCViewDidAppear) {
        pt_origVCViewDidAppear(self, _cmd, animated);
    }
    UIWindow *win = self.viewIfLoaded.window;
    if (win && pt_isEligiblePrimaryWindow(win)) {
        if (self == win.rootViewController
            || (self.parentViewController == nil && self.presentingViewController != nil)) {
            if (!objc_getAssociatedObject(self, kPTDuoLastTransitionSizeKey)) {
                CGSize candidateSize = self.viewIfLoaded ? self.viewIfLoaded.bounds.size : CGSizeZero;
                if (!PTDuoShouldSeedInitialTransitionBaseline(CGSizeZero, candidateSize)) {
                    candidateSize = win.bounds.size;
                }
                if (PTDuoShouldSeedInitialTransitionBaseline(CGSizeZero, candidateSize)) {
                    objc_setAssociatedObject(self,
                                             kPTDuoLastTransitionSizeKey,
                                             [NSValue valueWithCGSize:candidateSize],
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        }
        pt_syncTrafficLightTopClearanceForWindow(win);
        pt_scheduleRefreshForWindow(win);
    }
}

static void pt_scheduleRefreshAcrossTransition(UIViewController *controller, UIWindow *win, BOOL animated) {
    if (!win || !pt_isEligiblePrimaryWindow(win)) {
        return;
    }
    pt_scheduleRefreshForWindow(win);
    if (animated && controller && [controller respondsToSelector:@selector(transitionCoordinator)]) {
        id<UIViewControllerTransitionCoordinator> coord = controller.transitionCoordinator;
        if (coord) {
            __weak UIWindow *weakWin = win;
            [coord animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
                UIWindow *strongWin = weakWin;
                if (strongWin && pt_isEligiblePrimaryWindow(strongWin)) {
                    if (ctx && ctx.isCancelled) {
                        PTDuoWindowInsetState *st = pt_insetStateForWindow(strongWin, NO);
                        if (st) {
                            st.forceReprobe = YES;
                        }
                        pt_refreshDuoVerticalBarForWindow(strongWin);
                    }
                    pt_scheduleRefreshForWindow(strongWin);
                }
            }];
            return;
        }
    }
    if (animated) {
        __weak UIWindow *weakWin = win;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.38 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *strongWin = weakWin;
            if (strongWin && pt_isEligiblePrimaryWindow(strongWin)) {
                pt_scheduleRefreshForWindow(strongWin);
            }
        });
    }
}

static void (*pt_origVCPresentVC)(UIViewController *, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;
static void pt_vcPresentVC(UIViewController *self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && vcToPresent) {
        pt_beginProbeOnTransitionIfNeeded(win, vcToPresent);
    }
    if (pt_origVCPresentVC) {
        pt_origVCPresentVC(self, _cmd, vcToPresent, flag, completion);
    }
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_syncTrafficLightTopClearanceForWindow(win);
        pt_scheduleRefreshAcrossTransition(vcToPresent ?: self, win, flag);
    }
}

static void (*pt_origVCDismissVC)(UIViewController *, SEL, BOOL, void (^)(void)) = NULL;
static void pt_vcDismissVC(UIViewController *self, SEL _cmd, BOOL flag, void (^completion)(void)) {
    UIWindow *win = self.viewIfLoaded.window
        ?: self.presentingViewController.viewIfLoaded.window
        ?: pt_findActivePrimaryWindow();
    UIViewController *presenting = self.presentingViewController;
    if (win && presenting) {
        pt_beginProbeOnTransitionIfNeeded(win, presenting);
    }
    if (pt_origVCDismissVC) {
        pt_origVCDismissVC(self, _cmd, flag, completion);
    }
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_syncTrafficLightTopClearanceForWindow(win);
        pt_scheduleRefreshAcrossTransition(presenting ?: self, win, flag);
    }
}

static void (*pt_origTabBarControllerSetSelectedIndex)(UITabBarController *, SEL, NSUInteger) = NULL;
static void pt_tabBarControllerSetSelectedIndex(UITabBarController *self, SEL _cmd, NSUInteger index) {
    NSUInteger prevIndex = self.selectedIndex;
    if (pt_origTabBarControllerSetSelectedIndex) {
        pt_origTabBarControllerSetSelectedIndex(self, _cmd, index);
    }
    if (prevIndex != self.selectedIndex) {
        UIWindow *win = self.viewIfLoaded.window;
        if (win && pt_isEligiblePrimaryWindow(win)) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origTabBarControllerSetSelectedTab)(UITabBarController *, SEL, id) = NULL;
static void pt_hookTabBarControllerSetSelectedTab(UITabBarController *self, SEL _cmd, id tab) {
    if (pt_origTabBarControllerSetSelectedTab) {
        pt_origTabBarControllerSetSelectedTab(self, _cmd, tab);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static BOOL pt_tabBarControllerHasRelocatableDock(UITabBarController *tabVC) {
    if (!tabVC) {
        return NO;
    }
    NSArray<id> *modernRegular = nil;
    id modernProminent = nil;
    if (pt_collectModernTabs(tabVC, &modernRegular, &modernProminent, NULL, NULL)) {
        return YES;
    }
    UITabBar *tb = tabVC.tabBar;
    return (tb && tb.items.count >= 2 && !pt_duoTabBarIsCustomReplacement(tb));
}

static void (*pt_origTabBarControllerSetTabs)(UITabBarController *, SEL, NSArray *) = NULL;
static void pt_tabBarControllerSetTabs(UITabBarController *self, SEL _cmd, NSArray *tabs) {
    if (pt_origTabBarControllerSetTabs) {
        pt_origTabBarControllerSetTabs(self, _cmd, tabs);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerSetTabsAnimated)(UITabBarController *, SEL, NSArray *, BOOL) = NULL;
static void pt_tabBarControllerSetTabsAnimated(UITabBarController *self, SEL _cmd, NSArray *tabs, BOOL animated) {
    if (pt_origTabBarControllerSetTabsAnimated) {
        pt_origTabBarControllerSetTabsAnimated(self, _cmd, tabs, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerSetVCs)(UITabBarController *, SEL, NSArray<UIViewController *> *) = NULL;
static void pt_tabBarControllerSetVCs(UITabBarController *self, SEL _cmd, NSArray<UIViewController *> *vcs) {
    if (pt_origTabBarControllerSetVCs) {
        pt_origTabBarControllerSetVCs(self, _cmd, vcs);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerSetVCsAnimated)(UITabBarController *, SEL, NSArray<UIViewController *> *, BOOL) = NULL;
static void pt_tabBarControllerSetVCsAnimated(UITabBarController *self, SEL _cmd, NSArray<UIViewController *> *vcs, BOOL animated) {
    if (pt_origTabBarControllerSetVCsAnimated) {
        pt_origTabBarControllerSetVCsAnimated(self, _cmd, vcs, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerSetProminentIdAnimated)(UITabBarController *, SEL, NSString *, BOOL) = NULL;
static void pt_tabBarControllerSetProminentIdAnimated(UITabBarController *self, SEL _cmd, NSString *identifier, BOOL animated) {
    if (pt_origTabBarControllerSetProminentIdAnimated) {
        pt_origTabBarControllerSetProminentIdAnimated(self, _cmd, identifier, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerSetTabBarHiddenAnimated)(UITabBarController *, SEL, BOOL, BOOL) = NULL;
static void pt_tabBarControllerSetTabBarHiddenAnimated(UITabBarController *self, SEL _cmd, BOOL hidden, BOOL animated) {
    if (pt_origTabBarControllerSetTabBarHiddenAnimated) {
        pt_origTabBarControllerSetTabBarHiddenAnimated(self, _cmd, hidden, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerViewDidLayoutSubviews)(UITabBarController *, SEL) = NULL;
static void pt_tabBarControllerViewDidLayoutSubviews(UITabBarController *self, SEL _cmd) {
    if (pt_origTabBarControllerViewDidLayoutSubviews) {
        pt_origTabBarControllerViewDidLayoutSubviews(self, _cmd);
    }
    UIWindow *win = self.viewIfLoaded.window;
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return;
    }
    PTDuoVerticalBarHostView *host = pt_hostViewForWindow(win, NO);
    if (host && !host.hidden && host.hasRelocatedTabBar && host.activeTabBarController == self) {
        // Re-suppress any floating _UIBottomTabBarGroupView / _UITabBarAuxiliaryView that UIKit
        // un-hid or re-created during tab bar layout.
        [host suppressFloatingTabBarChromeForTabVC:self];
        return;
    }
    // Recover from a stale hideAndRestore / post-pop un-relocated state once native tabs or tabBar items
    // finish mounting or become visible again, coalesced per mount-signature so it never loops.
    if ((!host || host.hidden || (!host.hasRelocatedTabBar && self.tabBar && !self.tabBar.hidden))
        && !pt_tabBarControllerIsTabBarHidden(self)
        && pt_tabBarControllerHasRelocatableDock(self)) {
        PTDuoWindowInsetState *insetState = pt_insetStateForWindow(win, NO);
        NSUInteger epoch = insetState ? insetState.epoch : 0;
        NSUInteger legacyCount = self.tabBar ? self.tabBar.items.count : 0;
        NSUInteger modernCount = 0;
        SEL tabsSel = sel_registerName("tabs");
        if ([self respondsToSelector:tabsSel]) {
            typedef NSArray *(*pt_tabs_fn)(id, SEL);
            modernCount = ((pt_tabs_fn)objc_msgSend)(self, tabsSel).count;
        }
        NSString *evalSig = [NSString stringWithFormat:@"%lu|%lu|%lu|%d|%d",
                             (unsigned long)epoch,
                             (unsigned long)modernCount,
                             (unsigned long)legacyCount,
                             (int)self.selectedIndex,
                             (self.tabBar && !self.tabBar.hidden) ? 1 : 0];
        NSString *prevSig = objc_getAssociatedObject(self, kPTDuoTabMountEvalKey);
        if (![evalSig isEqualToString:prevSig]) {
            objc_setAssociatedObject(self, kPTDuoTabMountEvalKey, evalSig, OBJC_ASSOCIATION_COPY_NONATOMIC);
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavViewDidLayoutSubviews)(UINavigationController *, SEL) = NULL;
static void pt_navViewDidLayoutSubviews(UINavigationController *self, SEL _cmd) {
    if (pt_origNavViewDidLayoutSubviews) {
        pt_origNavViewDidLayoutSubviews(self, _cmd);
    }
    UIWindow *win = self.viewIfLoaded.window;
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return;
    }
    PTDuoVerticalBarHostView *host = pt_hostViewForWindow(win, NO);
    if (host && !host.hidden && host.activeNavController == self && pt_isToolbarFullySuppressed(self)) {
        // Re-suppress any _UIFloatingBarContainerView / FloatingBarHostingView recreated during nav layout.
        [host suppressFloatingToolbarChromeForNav:self];
    }
    if (!host || host.hidden) {
        PTDuoWindowInsetState *insetState = pt_insetStateForWindow(win, NO);
        NSUInteger epoch = insetState ? insetState.epoch : 0;
        NSString *evalSig = [NSString stringWithFormat:@"%lu|%lu|%d",
                             (unsigned long)epoch,
                             (unsigned long)self.viewControllers.count,
                             (int)self.isNavigationBarHidden];
        NSString *prevSig = objc_getAssociatedObject(self, kPTDuoNavMountEvalKey);
        if (![evalSig isEqualToString:prevSig]) {
            objc_setAssociatedObject(self, kPTDuoNavMountEvalKey, evalSig, OBJC_ASSOCIATION_COPY_NONATOMIC);
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavPushVCAnimated)(UINavigationController *, SEL, UIViewController *, BOOL) = NULL;
static void pt_navPushVCAnimated(UINavigationController *self, SEL _cmd, UIViewController *vc, BOOL animated) {
    UIWindow *preWin = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (preWin && vc) {
        pt_beginProbeOnTransitionIfNeeded(preWin, vc);
    }
    if (pt_origNavPushVCAnimated) {
        pt_origNavPushVCAnimated(self, _cmd, vc, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: preWin ?: pt_findActivePrimaryWindow();
    pt_scheduleRefreshAcrossTransition(self, win, animated);
}

static UIViewController *(*pt_origNavPopVCAnimated)(UINavigationController *, SEL, BOOL) = NULL;
static UIViewController *pt_navPopVCAnimated(UINavigationController *self, SEL _cmd, BOOL animated) {
    UIViewController *popped = pt_origNavPopVCAnimated ? pt_origNavPopVCAnimated(self, _cmd, animated) : nil;
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    pt_scheduleRefreshAcrossTransition(self, win, animated);
    return popped;
}

static NSArray<UIViewController *> *(*pt_origNavPopToVCAnimated)(UINavigationController *, SEL, UIViewController *, BOOL) = NULL;
static NSArray<UIViewController *> *pt_navPopToVCAnimated(UINavigationController *self, SEL _cmd, UIViewController *vc, BOOL animated) {
    NSArray<UIViewController *> *popped = pt_origNavPopToVCAnimated ? pt_origNavPopToVCAnimated(self, _cmd, vc, animated) : nil;
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    pt_scheduleRefreshAcrossTransition(self, win, animated);
    return popped;
}

static NSArray<UIViewController *> *(*pt_origNavPopToRootAnimated)(UINavigationController *, SEL, BOOL) = NULL;
static NSArray<UIViewController *> *pt_navPopToRootAnimated(UINavigationController *self, SEL _cmd, BOOL animated) {
    NSArray<UIViewController *> *popped = pt_origNavPopToRootAnimated ? pt_origNavPopToRootAnimated(self, _cmd, animated) : nil;
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    pt_scheduleRefreshAcrossTransition(self, win, animated);
    return popped;
}

static void (*pt_origNavSetViewControllersAnimated)(UINavigationController *, SEL, NSArray<UIViewController *> *, BOOL) = NULL;
static void pt_navSetViewControllersAnimated(UINavigationController *self, SEL _cmd, NSArray<UIViewController *> *vcs, BOOL animated) {
    if (pt_origNavSetViewControllersAnimated) {
        pt_origNavSetViewControllersAnimated(self, _cmd, vcs, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    pt_scheduleRefreshAcrossTransition(self, win, animated);
}

static void (*pt_origTabBarSetHidden)(UITabBar *, SEL, BOOL) = NULL;
static void pt_tabBarSetHidden(UITabBar *self, SEL _cmd, BOOL hidden) {
    BOOL handledByRelocated = NO;
    if (pt_duoInternalTabBarHiddenDepth == 0) {
        BOOL relocated = [objc_getAssociatedObject(self, kPTDuoTabBarRelocatedKey) boolValue];
        if (relocated) {
            handledByRelocated = YES;
            objc_setAssociatedObject(self, kPTDuoTabBarAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!hidden) {
                // Keep bottom bar hidden while relocated onto the vertical rail; refresh to re-verify.
                if (self.window) {
                    pt_scheduleRefreshForWindow(self.window);
                }
                return;
            }
            // App explicitly hid the tab bar (e.g. hidesBottomBarWhenPushed); refresh so dock hides too.
            if (self.window) {
                pt_scheduleRefreshForWindow(self.window);
            }
        }
    }
    if (pt_origTabBarSetHidden) {
        pt_origTabBarSetHidden(self, _cmd, hidden);
    }
    if (!handledByRelocated && pt_duoInternalTabBarHiddenDepth == 0 && !hidden) {
        // When UIKit unhides an un-relocated UITabBar (e.g. after popping a hidesBottomBarWhenPushed VC),
        // immediately schedule a refresh so the dock re-relocates to the vertical rail.
        UIWindow *win = self.window ?: pt_findActivePrimaryWindow();
        if (win && pt_isEligiblePrimaryWindow(win)) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void pt_scheduleRefreshForActiveDuoWindows(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            pt_scheduleRefreshForActiveDuoWindows();
        });
        return;
    }
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (pt_isEligiblePrimaryWindow(w) && pt_isDuoVerticalBarActiveForWindow(w)) {
                pt_scheduleRefreshForWindow(w);
            }
        }
    }
}

static void (*pt_origTabBarSetItemsAnimated)(UITabBar *, SEL, NSArray<UITabBarItem *> *, BOOL) = NULL;
static void pt_tabBarSetItemsAnimated(UITabBar *self, SEL _cmd, NSArray<UITabBarItem *> *items, BOOL animated) {
    if (pt_origTabBarSetItemsAnimated) {
        pt_origTabBarSetItemsAnimated(self, _cmd, items, animated);
    }
    UIWindow *win = self.window ?: pt_findActivePrimaryWindow();
    if (win && pt_isEligiblePrimaryWindow(win) && pt_isDuoVerticalBarActiveForWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarItemSetImage)(UITabBarItem *, SEL, UIImage *) = NULL;
static void pt_tabBarItemSetImage(UITabBarItem *self, SEL _cmd, UIImage *image) {
    UIImage *prev = self.image;
    if (pt_origTabBarItemSetImage) {
        pt_origTabBarItemSetImage(self, _cmd, image);
    }
    if (prev != image) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static void (*pt_origTabBarItemSetSelectedImage)(UITabBarItem *, SEL, UIImage *) = NULL;
static void pt_tabBarItemSetSelectedImage(UITabBarItem *self, SEL _cmd, UIImage *selectedImage) {
    UIImage *prev = self.selectedImage;
    if (pt_origTabBarItemSetSelectedImage) {
        pt_origTabBarItemSetSelectedImage(self, _cmd, selectedImage);
    }
    if (prev != selectedImage) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static void (*pt_origTabBarItemSetTitle)(UITabBarItem *, SEL, NSString *) = NULL;
static void pt_tabBarItemSetTitle(UITabBarItem *self, SEL _cmd, NSString *title) {
    NSString *prev = self.title;
    if (pt_origTabBarItemSetTitle) {
        pt_origTabBarItemSetTitle(self, _cmd, title);
    }
    if (prev != title && !(prev && title && [prev isEqualToString:title])) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static void (*pt_origTabBarItemSetBadgeValue)(UITabBarItem *, SEL, NSString *) = NULL;
static void pt_tabBarItemSetBadgeValue(UITabBarItem *self, SEL _cmd, NSString *badgeValue) {
    NSString *prev = self.badgeValue;
    if (pt_origTabBarItemSetBadgeValue) {
        pt_origTabBarItemSetBadgeValue(self, _cmd, badgeValue);
    }
    if (prev != badgeValue && !(prev && badgeValue && [prev isEqualToString:badgeValue])) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static void (*pt_origModernTabSetImage)(id, SEL, UIImage *) = NULL;
static void pt_modernTabSetImage(id self, SEL _cmd, UIImage *image) {
    UIImage *prev = pt_tabImage(self);
    if (pt_origModernTabSetImage) {
        pt_origModernTabSetImage(self, _cmd, image);
    }
    if (prev != image) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static void (*pt_origModernTabSetSelectedImage)(id, SEL, UIImage *) = NULL;
static void pt_modernTabSetSelectedImage(id self, SEL _cmd, UIImage *selectedImage) {
    UIImage *prev = pt_tabSelectedImage(self);
    if (pt_origModernTabSetSelectedImage) {
        pt_origModernTabSetSelectedImage(self, _cmd, selectedImage);
    }
    if (prev != selectedImage) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static void (*pt_origModernTabSetTitle)(id, SEL, NSString *) = NULL;
static void pt_modernTabSetTitle(id self, SEL _cmd, NSString *title) {
    NSString *prev = pt_tabTitle(self);
    if (pt_origModernTabSetTitle) {
        pt_origModernTabSetTitle(self, _cmd, title);
    }
    if (prev != title && !(prev && title && [prev isEqualToString:title])) {
        pt_scheduleRefreshForActiveDuoWindows();
    }
}

static BOOL pt_barItemArrayEqual(NSArray *a, NSArray *b) {
    if (a == b) {
        return YES;
    }
    if (a.count == 0 && b.count == 0) {
        return YES;
    }
    return (a != nil && b != nil && [a isEqualToArray:b]);
}

static void (*pt_origNavItemSetRightItems)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void pt_navItemSetRightItems(UINavigationItem *self, SEL _cmd, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    NSArray<UIBarButtonItem *> *prev = self.rightBarButtonItems;
    BOOL unchanged = pt_barItemArrayEqual(prev, items);
    if (pt_origNavItemSetRightItems) {
        pt_origNavItemSetRightItems(self, _cmd, items, animated);
    }
    if (!unchanged) {
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavItemSetTrailingGroups)(UINavigationItem *, SEL, NSArray *) = NULL;
static void pt_navItemSetTrailingGroups(UINavigationItem *self, SEL _cmd, NSArray *groups) {
    NSArray *prev = [self respondsToSelector:@selector(trailingItemGroups)] ? self.trailingItemGroups : nil;
    BOOL unchanged = [self respondsToSelector:@selector(trailingItemGroups)] && pt_barItemArrayEqual(prev, groups);
    if (pt_origNavItemSetTrailingGroups) {
        pt_origNavItemSetTrailingGroups(self, _cmd, groups);
    }
    if (!unchanged) {
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavItemSetLeftItems)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void pt_navItemSetLeftItems(UINavigationItem *self, SEL _cmd, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    NSArray<UIBarButtonItem *> *prev = self.leftBarButtonItems;
    BOOL unchanged = pt_barItemArrayEqual(prev, items);
    if (pt_origNavItemSetLeftItems) {
        pt_origNavItemSetLeftItems(self, _cmd, items, animated);
    }
    if (!unchanged) {
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavItemSetLeadingGroups)(UINavigationItem *, SEL, NSArray *) = NULL;
static void pt_navItemSetLeadingGroups(UINavigationItem *self, SEL _cmd, NSArray *groups) {
    NSArray *prev = [self respondsToSelector:@selector(leadingItemGroups)] ? self.leadingItemGroups : nil;
    BOOL unchanged = [self respondsToSelector:@selector(leadingItemGroups)] && pt_barItemArrayEqual(prev, groups);
    if (pt_origNavItemSetLeadingGroups) {
        pt_origNavItemSetLeadingGroups(self, _cmd, groups);
    }
    if (!unchanged) {
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavItemSetLeftItemsSupplementBack)(UINavigationItem *, SEL, BOOL) = NULL;
static void pt_navItemSetLeftItemsSupplementBack(UINavigationItem *self, SEL _cmd, BOOL supplement) {
    BOOL unchanged = (self.leftItemsSupplementBackButton == supplement);
    if (pt_origNavItemSetLeftItemsSupplementBack) {
        pt_origNavItemSetLeftItemsSupplementBack(self, _cmd, supplement);
    }
    if (!unchanged) {
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origVCSetToolbarItems)(UIViewController *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void pt_vcSetToolbarItems(UIViewController *self, SEL _cmd, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    if (pt_origVCSetToolbarItems) {
        pt_origVCSetToolbarItems(self, _cmd, items, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

// Horizontal UINavigationBar / UIToolbar / UIBarButtonItem / UINavigationItem dedup & inset hooks
static void (*pt_origNavBarSetHidden)(UINavigationBar *, SEL, BOOL) = NULL;
static void pt_navBarSetHidden(UINavigationBar *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalNavBarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoNavBarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoNavBarAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (self.window) {
            pt_scheduleRefreshForWindow(self.window);
        }
        if (!hidden) {
            return;
        }
    }
    if (pt_origNavBarSetHidden) {
        pt_origNavBarSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origNavBarSetAlpha)(UINavigationBar *, SEL, CGFloat) = NULL;
static void pt_navBarSetAlpha(UINavigationBar *self, SEL _cmd, CGFloat alpha) {
    if (pt_duoInternalNavBarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoNavBarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoNavBarAppAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (alpha > 0.0) {
            return;
        }
    }
    if (pt_origNavBarSetAlpha) {
        pt_origNavBarSetAlpha(self, _cmd, alpha);
    }
}

static void (*pt_origToolbarSetHidden)(UIToolbar *, SEL, BOOL) = NULL;
static void pt_toolbarSetHidden(UIToolbar *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalToolbarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoToolbarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoToolbarAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (self.window) {
            pt_scheduleRefreshForWindow(self.window);
        }
        if (!hidden) {
            return;
        }
    }
    if (pt_origToolbarSetHidden) {
        pt_origToolbarSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origToolbarSetAlpha)(UIToolbar *, SEL, CGFloat) = NULL;
static void pt_toolbarSetAlpha(UIToolbar *self, SEL _cmd, CGFloat alpha) {
    if (pt_duoInternalToolbarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoToolbarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoToolbarAppAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (alpha > 0.0) {
            return;
        }
    }
    if (pt_origToolbarSetAlpha) {
        pt_origToolbarSetAlpha(self, _cmd, alpha);
    }
}

static void (*pt_origBarItemSetHidden)(UIBarButtonItem *, SEL, BOOL) = NULL;
static void pt_barItemSetHidden(UIBarButtonItem *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalBarItemHiddenDepth == 0 && [objc_getAssociatedObject(self, kPTDuoBarItemSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoBarItemAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
        if (!hidden) {
            return;
        }
    }
    if (pt_origBarItemSetHidden) {
        pt_origBarItemSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origNavItemSetHidesBack)(UINavigationItem *, SEL, BOOL) = NULL;
static void (*pt_origNavItemSetHidesBackAnimated)(UINavigationItem *, SEL, BOOL, BOOL) = NULL;

static void pt_handleNavItemSetHidesBack(UINavigationItem *self,
                                         SEL _cmd,
                                         BOOL hides,
                                         BOOL hasAnimated,
                                         BOOL animated) {
    BOOL suppressed = (pt_duoInternalNavItemBackDepth == 0
                       && [objc_getAssociatedObject(self, kPTDuoNavItemSuppressedBackKey) boolValue]);
    NSNumber *prevAppHides = suppressed ? objc_getAssociatedObject(self, kPTDuoNavItemAppHidesBackKey) : nil;
    BOOL prevHides = prevAppHides ? prevAppHides.boolValue : self.hidesBackButton;
    BOOL changed = (prevHides != hides);
    if (suppressed) {
        objc_setAssociatedObject(self, kPTDuoNavItemAppHidesBackKey, @(hides), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (changed) {
            UIWindow *win = pt_findActivePrimaryWindow();
            if (win) {
                pt_scheduleRefreshForWindow(win);
            }
        }
        if (!hides) {
            return;
        }
    }
    if (hasAnimated) {
        if (pt_origNavItemSetHidesBackAnimated) {
            pt_origNavItemSetHidesBackAnimated(self, _cmd, hides, animated);
        }
    } else if (pt_origNavItemSetHidesBack) {
        pt_origNavItemSetHidesBack(self, _cmd, hides);
    }
    if (!suppressed && pt_duoInternalNavItemBackDepth == 0 && changed) {
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        } else {
            pt_scheduleGlobalBackRefresh();
        }
    }
}

static void pt_navItemSetHidesBack(UINavigationItem *self, SEL _cmd, BOOL hides) {
    pt_handleNavItemSetHidesBack(self, _cmd, hides, NO, NO);
}

static void pt_navItemSetHidesBackAnimated(UINavigationItem *self, SEL _cmd, BOOL hides, BOOL animated) {
    pt_handleNavItemSetHidesBack(self, _cmd, hides, YES, animated);
}

static BOOL pt_isNavBarFullySuppressed(UINavigationController *nav) {
    return nav != nil
        && (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoNavControllerSuppressionKey) integerValue] == PTDuoNavBarSuppressionFull;
}

static BOOL pt_isToolbarFullySuppressed(UINavigationController *nav) {
    return nav != nil
        && (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey) integerValue] == PTDuoNavBarSuppressionFull;
}

static BOOL (*pt_origNavShouldInsetVC)(UINavigationController *, SEL, UIViewController *) = NULL;
static BOOL pt_navShouldInsetVC(UINavigationController *self, SEL _cmd, UIViewController *vc) {
    if (pt_isNavBarFullySuppressed(self)) {
        return NO;
    }
    return pt_origNavShouldInsetVC ? pt_origNavShouldInsetVC(self, _cmd, vc) : YES;
}

static BOOL (*pt_origNavShouldInsetVCOrOverlay)(UINavigationController *, SEL, UIViewController *, BOOL *) = NULL;
static BOOL pt_navShouldInsetVCOrOverlay(UINavigationController *self, SEL _cmd, UIViewController *vc, BOOL *overlay) {
    if (pt_isNavBarFullySuppressed(self)) {
        if (overlay) {
            *overlay = NO;
        }
        return NO;
    }
    return pt_origNavShouldInsetVCOrOverlay ? pt_origNavShouldInsetVCOrOverlay(self, _cmd, vc, overlay) : YES;
}

static BOOL (*pt_origToolbarShouldInsetVC)(UINavigationController *, SEL, UIToolbar *, UIViewController *) = NULL;
static BOOL pt_toolbarShouldInsetVC(UINavigationController *self, SEL _cmd, UIToolbar *tb, UIViewController *vc) {
    if (pt_isToolbarFullySuppressed(self)) {
        return NO;
    }
    return pt_origToolbarShouldInsetVC ? pt_origToolbarShouldInsetVC(self, _cmd, tb, vc) : YES;
}

static BOOL (*pt_origToolbarShouldInsetVCOrOverlay)(UINavigationController *, SEL, UIToolbar *, UIViewController *, BOOL *) = NULL;
static BOOL pt_toolbarShouldInsetVCOrOverlay(UINavigationController *self, SEL _cmd, UIToolbar *tb, UIViewController *vc, BOOL *overlay) {
    if (pt_isToolbarFullySuppressed(self)) {
        if (overlay) {
            *overlay = NO;
        }
        return NO;
    }
    return pt_origToolbarShouldInsetVCOrOverlay ? pt_origToolbarShouldInsetVCOrOverlay(self, _cmd, tb, vc, overlay) : YES;
}

static UIEdgeInsets (*pt_origNavEdgeInsetsForChild)(UINavigationController *, SEL, UIViewController *, BOOL *) = NULL;
static UIEdgeInsets pt_navEdgeInsetsForChild(UINavigationController *self, SEL _cmd, UIViewController *vc, BOOL *insetsAreAbsolute) {
    UIEdgeInsets insets = pt_origNavEdgeInsetsForChild
        ? pt_origNavEdgeInsetsForChild(self, _cmd, vc, insetsAreAbsolute)
        : UIEdgeInsetsZero;
    BOOL isAbs = (insetsAreAbsolute != NULL) ? *insetsAreAbsolute : NO;
    if (pt_isNavBarFullySuppressed(self)) {
        UIWindow *win = self.viewIfLoaded.window;
        CGFloat winTop = win ? MAX(pt_windowSuperSafeAreaInsets(win).top, pt_windowTrafficLightTopClearance(win)) : 0.0;
        insets.top = PTDuoAdjustedSuppressedNavBarTopInset(insets.top, isAbs, winTop);
    }
    if (pt_isToolbarFullySuppressed(self)) {
        CGFloat winBottom = self.viewIfLoaded.window ? pt_windowSuperSafeAreaInsets(self.viewIfLoaded.window).bottom : 0.0;
        insets.bottom = PTDuoAdjustedSuppressedNavBarTopInset(insets.bottom, isAbs, winBottom);
    }
    return insets;
}

static void (*pt_origNavSetNavBarHiddenAnimated)(UINavigationController *, SEL, BOOL, BOOL) = NULL;
static void pt_navSetNavBarHiddenAnimated(UINavigationController *self, SEL _cmd, BOOL hidden, BOOL animated) {
    BOOL prevHidden = self.isNavigationBarHidden;
    if (pt_origNavSetNavBarHiddenAnimated) {
        pt_origNavSetNavBarHiddenAnimated(self, _cmd, hidden, animated);
    }
    if (prevHidden != self.isNavigationBarHidden) {
        UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

static void (*pt_origNavSetToolbarHiddenAnimated)(UINavigationController *, SEL, BOOL, BOOL) = NULL;
static void pt_navSetToolbarHiddenAnimated(UINavigationController *self, SEL _cmd, BOOL hidden, BOOL animated) {
    BOOL prevHidden = self.isToolbarHidden;
    if (pt_origNavSetToolbarHiddenAnimated) {
        pt_origNavSetToolbarHiddenAnimated(self, _cmd, hidden, animated);
    }
    if (prevHidden != self.isToolbarHidden) {
        UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
    }
}

// MARK: - Swizzle Helper & Installer

static void pt_replaceInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls || !sel || !replacement) {
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    if (orig == replacement) {
        return;
    }
    if (outOriginal) {
        *outOriginal = orig;
    }
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(m));
}

static void pt_replaceClassMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls || !sel || !replacement) {
        return;
    }
    Class meta = object_getClass(cls);
    Method m = class_getClassMethod(cls, sel);
    if (!meta || !m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    if (orig == replacement) {
        return;
    }
    if (outOriginal) {
        *outOriginal = orig;
    }
    class_replaceMethod(meta, sel, replacement, method_getTypeEncoding(m));
}

static void pt_installGlobalBackNavigationObservers(void) {
    if (pt_globalBackHooksInstalled) {
        return;
    }
    pt_globalBackHooksInstalled = YES;

    Class uiWindow = objc_getClass("UIWindow");
    Class uiVC = objc_getClass("UIViewController");
    Class uiTabBarController = objc_getClass("UITabBarController");
    Class uiNavController = objc_getClass("UINavigationController");
    Class uiNavItem = objc_getClass("UINavigationItem");

    pt_replaceInstanceMethod(uiWindow,
                             @selector(makeKeyAndVisible),
                             (IMP)pt_windowMakeKeyAndVisible,
                             (IMP *)&pt_origWindowMakeKeyAndVisible);
    pt_replaceInstanceMethod(uiWindow,
                             @selector(setRootViewController:),
                             (IMP)pt_windowSetRootVC,
                             (IMP *)&pt_origWindowSetRootVC);
    pt_replaceInstanceMethod(uiVC,
                             @selector(viewDidAppear:),
                             (IMP)pt_vcViewDidAppear,
                             (IMP *)&pt_origVCViewDidAppear);
    pt_replaceInstanceMethod(uiVC,
                             @selector(presentViewController:animated:completion:),
                             (IMP)pt_vcPresentVC,
                             (IMP *)&pt_origVCPresentVC);
    pt_replaceInstanceMethod(uiVC,
                             @selector(dismissViewControllerAnimated:completion:),
                             (IMP)pt_vcDismissVC,
                             (IMP *)&pt_origVCDismissVC);
    pt_replaceInstanceMethod(uiTabBarController,
                             @selector(setSelectedIndex:),
                             (IMP)pt_tabBarControllerSetSelectedIndex,
                             (IMP *)&pt_origTabBarControllerSetSelectedIndex);
    pt_replaceInstanceMethod(uiTabBarController,
                             sel_registerName("setSelectedTab:"),
                             (IMP)pt_hookTabBarControllerSetSelectedTab,
                             (IMP *)&pt_origTabBarControllerSetSelectedTab);
    pt_replaceInstanceMethod(uiTabBarController,
                             @selector(setViewControllers:),
                             (IMP)pt_tabBarControllerSetVCs,
                             (IMP *)&pt_origTabBarControllerSetVCs);
    pt_replaceInstanceMethod(uiTabBarController,
                             @selector(setViewControllers:animated:),
                             (IMP)pt_tabBarControllerSetVCsAnimated,
                             (IMP *)&pt_origTabBarControllerSetVCsAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(pushViewController:animated:),
                             (IMP)pt_navPushVCAnimated,
                             (IMP *)&pt_origNavPushVCAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(popViewControllerAnimated:),
                             (IMP)pt_navPopVCAnimated,
                             (IMP *)&pt_origNavPopVCAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(popToViewController:animated:),
                             (IMP)pt_navPopToVCAnimated,
                             (IMP *)&pt_origNavPopToVCAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(popToRootViewControllerAnimated:),
                             (IMP)pt_navPopToRootAnimated,
                             (IMP *)&pt_origNavPopToRootAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(setViewControllers:animated:),
                             (IMP)pt_navSetViewControllersAnimated,
                             (IMP *)&pt_origNavSetViewControllersAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(setNavigationBarHidden:animated:),
                             (IMP)pt_navSetNavBarHiddenAnimated,
                             (IMP *)&pt_origNavSetNavBarHiddenAnimated);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setRightBarButtonItems:animated:),
                             (IMP)pt_navItemSetRightItems,
                             (IMP *)&pt_origNavItemSetRightItems);
    pt_replaceInstanceMethod(uiNavItem,
                             sel_registerName("setTrailingItemGroups:"),
                             (IMP)pt_navItemSetTrailingGroups,
                             (IMP *)&pt_origNavItemSetTrailingGroups);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setLeftBarButtonItems:animated:),
                             (IMP)pt_navItemSetLeftItems,
                             (IMP *)&pt_origNavItemSetLeftItems);
    pt_replaceInstanceMethod(uiNavItem,
                             sel_registerName("setLeadingItemGroups:"),
                             (IMP)pt_navItemSetLeadingGroups,
                             (IMP *)&pt_origNavItemSetLeadingGroups);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setLeftItemsSupplementBackButton:),
                             (IMP)pt_navItemSetLeftItemsSupplementBack,
                             (IMP *)&pt_origNavItemSetLeftItemsSupplementBack);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setHidesBackButton:),
                             (IMP)pt_navItemSetHidesBack,
                             (IMP *)&pt_origNavItemSetHidesBack);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setHidesBackButton:animated:),
                             (IMP)pt_navItemSetHidesBackAnimated,
                             (IMP *)&pt_origNavItemSetHidesBackAnimated);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        UIWindow *w = [note.object isKindOfClass:[UIWindow class]] ? (UIWindow *)note.object : nil;
        if (w) {
            pt_scheduleRefreshForWindow(w);
        }
    }];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    BOOL (^isMainAppNSWin)(id) = ^BOOL(id nsWin) {
        if (!nsWin) {
            return YES;
        }
        NSString *clsName = NSStringFromClass([nsWin class]);
        if ([clsName containsString:@"Menu"] ||
            [clsName containsString:@"StatusBar"] ||
            [clsName containsString:@"Tooltip"] ||
            [clsName containsString:@"Popover"]) {
            return NO;
        }
        SEL isSheetSel = NSSelectorFromString(@"isSheet");
        if (isSheetSel && [nsWin respondsToSelector:isSheetSel] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(nsWin, isSheetSel)) {
            return NO;
        }
        return YES;
    };
    [nc addObserverForName:@"NSWindowWillStartLiveResizeNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (!isMainAppNSWin(note.object)) {
            return;
        }
        pt_duoHostLiveResizing = YES;
    }];
    [nc addObserverForName:@"NSWindowDidEndLiveResizeNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (!isMainAppNSWin(note.object)) {
            return;
        }
        if (!pt_duoHostLiveResizing) {
            return;
        }
        pt_duoHostLiveResizing = NO;
        BOOL scheduledAny = NO;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!pt_isEligiblePrimaryWindow(w)) {
                    continue;
                }
                if ([objc_getAssociatedObject(w, kPTDuoPendingLiveResizeRefreshKey) boolValue]) {
                    objc_setAssociatedObject(w, kPTDuoPendingLiveResizeRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (PTShouldEnableDuoVerticalBar()) {
                        PTDuoWindowInsetState *st = pt_insetStateForWindow(w, NO);
                        if (st) {
                            st.forceReprobe = YES;
                        }
                        pt_scheduleRefreshForWindow(w);
                        scheduledAny = YES;
                    }
                }
            }
        }
        if (!scheduledAny && !PTShouldEnableDuoVerticalBar()) {
            pt_scheduleGlobalBackRefresh();
        }
    }];
}

__attribute__((visibility("hidden")))
void pt_installDuoVerticalBarCompatibility(void) {
    // Always observe navigation/modal transitions so global titlebar back & shortcut stay synced
    // even when Duo Vertical Bar is disabled or the window is narrow.
    pt_installGlobalBackNavigationObservers();

    if (pt_duoVerticalBarInstalled) {
        return;
    }
    // Strict per-app opt-in: zero hooks installed when duoVerticalBar is OFF or layoutIdiom != 3.
    if (!PTShouldEnableDuoVerticalBar()) {
        return;
    }
    pt_duoVerticalBarInstalled = YES;

    Class uiWindow = objc_getClass("UIWindow");
    Class uiWindowScene = objc_getClass("UIWindowScene");
    Class uiView = objc_getClass("UIView");
    Class uiVC = objc_getClass("UIViewController");
    Class uiTabBar = objc_getClass("UITabBar");
    Class uiTabBarController = objc_getClass("UITabBarController");
    Class uiNavController = objc_getClass("UINavigationController");
    Class uiNavBar = objc_getClass("UINavigationBar");
    Class uiToolbar = objc_getClass("UIToolbar");
    Class uiBarButtonItem = objc_getClass("UIBarButtonItem");
    Class uiNavItem = objc_getClass("UINavigationItem");
    Class uiLayoutRegion = objc_getClass("UIViewLayoutRegion");
    Class uiStatusBarManager = objc_getClass("UIStatusBarManager");

    // 1. Trailing safe area hooks & status bar visibility hook
    if (uiStatusBarManager) {
        pt_replaceInstanceMethod(uiStatusBarManager,
                                 sel_registerName("isStatusBarHidden"),
                                 (IMP)pt_statusBarManagerIsHidden,
                                 (IMP *)&pt_origStatusBarManagerIsHidden);
        pt_replaceInstanceMethod(uiStatusBarManager,
                                 sel_registerName("statusBarHidden"),
                                 (IMP)pt_statusBarManagerStatusBarHidden,
                                 (IMP *)&pt_origStatusBarManagerStatusBarHidden);
    }
    pt_replaceInstanceMethod(uiWindow,
                             sel_registerName("_sceneSafeAreaInsetsIncludingStatusBar:"),
                             (IMP)pt_windowSceneSafeArea,
                             (IMP *)&pt_origWindowSceneSafeArea);
    pt_replaceInstanceMethod(uiWindowScene,
                             sel_registerName("_safeAreaInsetsForInterfaceOrientation:statusBarHidden:"),
                             (IMP)pt_sceneSafeAreaForOrientation,
                             (IMP *)&pt_origSceneSafeAreaForOrientation);
    pt_replaceInstanceMethod(uiWindowScene,
                             sel_registerName("_safeAreaInsetsForInterfaceOrientation:"),
                             (IMP)pt_sceneSafeAreaForOrientationOnly,
                             (IMP *)&pt_origSceneSafeAreaForOrientationOnly);

    // 2. UIViewLayoutRegion factory/init & UIView layout region backing
    if (uiLayoutRegion) {
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnEdge:extent:"),
                              (IMP)pt_regionBarEdgeExtent,
                              (IMP *)&pt_origRegionBarEdgeExtent);
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnDirectionalEdge:extent:"),
                              (IMP)pt_regionBarDirEdgeExtent,
                              (IMP *)&pt_origRegionBarDirEdgeExtent);
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnEdge:"),
                              (IMP)pt_regionBarEdgeDefault,
                              (IMP *)&pt_origRegionBarEdgeDefault);
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnDirectionalEdge:"),
                              (IMP)pt_regionBarDirEdgeDefault,
                              (IMP *)&pt_origRegionBarDirEdgeDefault);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnEdge:extent:"),
                                 (IMP)pt_initBarEdgeExtent,
                                 (IMP *)&pt_origInitBarEdgeExtent);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnDirectionalEdge:extent:"),
                                 (IMP)pt_initBarDirEdgeExtent,
                                 (IMP *)&pt_origInitBarDirEdgeExtent);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnEdge:"),
                                 (IMP)pt_initBarEdgeDefault,
                                 (IMP *)&pt_origInitBarEdgeDefault);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnDirectionalEdge:"),
                                 (IMP)pt_initBarDirEdgeDefault,
                                 (IMP *)&pt_origInitBarDirEdgeDefault);
    }

    pt_replaceInstanceMethod(uiView,
                             sel_registerName("layoutGuideForLayoutRegion:"),
                             (IMP)pt_layoutGuideForLayoutRegion,
                             (IMP *)&pt_origLayoutGuideForLayoutRegion);
    pt_replaceInstanceMethod(uiView,
                             sel_registerName("edgeInsetsForLayoutRegion:"),
                             (IMP)pt_edgeInsetsForLayoutRegion,
                             (IMP *)&pt_origEdgeInsetsForLayoutRegion);
    pt_replaceInstanceMethod(uiView,
                             sel_registerName("directionalEdgeInsetsForLayoutRegion:"),
                             (IMP)pt_directionalEdgeInsetsForLayoutRegion,
                             (IMP *)&pt_origDirectionalEdgeInsetsForLayoutRegion);
    pt_replaceInstanceMethod(uiView,
                             sel_registerName("_sceneRegionsWithTypes:"),
                             (IMP)pt_viewSceneRegionsWithTypes,
                             (IMP *)&pt_origViewSceneRegionsWithTypes);

    // 3. Window/VC lifecycle & vertical bar configuration update hooks
    //    (Navigation/modal/tab-selection/key-window hooks are always installed via pt_installGlobalBackNavigationObservers)
    pt_replaceInstanceMethod(uiWindow,
                             @selector(layoutSubviews),
                             (IMP)pt_windowLayoutSubviews,
                             (IMP *)&pt_origWindowLayoutSubviews);
    pt_replaceInstanceMethod(uiVC,
                             sel_registerName("setNeedsUpdateOfVerticalBarConfiguration"),
                             (IMP)pt_vcSetNeedsUpdateVerticalBar,
                             (IMP *)&pt_origVCSetNeedsUpdateVerticalBar);
    pt_replaceInstanceMethod(uiTabBarController,
                             sel_registerName("setTabs:"),
                             (IMP)pt_tabBarControllerSetTabs,
                             (IMP *)&pt_origTabBarControllerSetTabs);
    pt_replaceInstanceMethod(uiTabBarController,
                             sel_registerName("setTabs:animated:"),
                             (IMP)pt_tabBarControllerSetTabsAnimated,
                             (IMP *)&pt_origTabBarControllerSetTabsAnimated);
    pt_replaceInstanceMethod(uiTabBarController,
                             sel_registerName("setProminentTabIdentifier:animated:"),
                             (IMP)pt_tabBarControllerSetProminentIdAnimated,
                             (IMP *)&pt_origTabBarControllerSetProminentIdAnimated);
    pt_replaceInstanceMethod(uiTabBarController,
                             sel_registerName("setTabBarHidden:animated:"),
                             (IMP)pt_tabBarControllerSetTabBarHiddenAnimated,
                             (IMP *)&pt_origTabBarControllerSetTabBarHiddenAnimated);
    pt_replaceInstanceMethod(uiTabBarController,
                             @selector(viewDidLayoutSubviews),
                             (IMP)pt_tabBarControllerViewDidLayoutSubviews,
                             (IMP *)&pt_origTabBarControllerViewDidLayoutSubviews);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(viewDidLayoutSubviews),
                             (IMP)pt_navViewDidLayoutSubviews,
                             (IMP *)&pt_origNavViewDidLayoutSubviews);
    pt_replaceInstanceMethod(uiTabBar,
                             @selector(setHidden:),
                             (IMP)pt_tabBarSetHidden,
                             (IMP *)&pt_origTabBarSetHidden);
    pt_replaceInstanceMethod(uiTabBar,
                             @selector(setItems:animated:),
                             (IMP)pt_tabBarSetItemsAnimated,
                             (IMP *)&pt_origTabBarSetItemsAnimated);
    Class uiTabBarItem = objc_getClass("UITabBarItem");
    if (uiTabBarItem) {
        pt_replaceInstanceMethod(uiTabBarItem,
                                 @selector(setImage:),
                                 (IMP)pt_tabBarItemSetImage,
                                 (IMP *)&pt_origTabBarItemSetImage);
        pt_replaceInstanceMethod(uiTabBarItem,
                                 @selector(setSelectedImage:),
                                 (IMP)pt_tabBarItemSetSelectedImage,
                                 (IMP *)&pt_origTabBarItemSetSelectedImage);
        pt_replaceInstanceMethod(uiTabBarItem,
                                 @selector(setTitle:),
                                 (IMP)pt_tabBarItemSetTitle,
                                 (IMP *)&pt_origTabBarItemSetTitle);
        pt_replaceInstanceMethod(uiTabBarItem,
                                 @selector(setBadgeValue:),
                                 (IMP)pt_tabBarItemSetBadgeValue,
                                 (IMP *)&pt_origTabBarItemSetBadgeValue);
    }
    Class uiTab = objc_getClass("UITab");
    if (uiTab) {
        pt_replaceInstanceMethod(uiTab,
                                 @selector(setImage:),
                                 (IMP)pt_modernTabSetImage,
                                 (IMP *)&pt_origModernTabSetImage);
        pt_replaceInstanceMethod(uiTab,
                                 sel_registerName("setSelectedImage:"),
                                 (IMP)pt_modernTabSetSelectedImage,
                                 (IMP *)&pt_origModernTabSetSelectedImage);
        pt_replaceInstanceMethod(uiTab,
                                 @selector(setTitle:),
                                 (IMP)pt_modernTabSetTitle,
                                 (IMP *)&pt_origModernTabSetTitle);
    }
    pt_replaceInstanceMethod(uiVC,
                             @selector(setToolbarItems:animated:),
                             (IMP)pt_vcSetToolbarItems,
                             (IMP *)&pt_origVCSetToolbarItems);

    // 4. Horizontal UINavigationBar / UIToolbar deduplication & redundant safe-area push removal
    pt_replaceInstanceMethod(uiNavBar,
                             @selector(setHidden:),
                             (IMP)pt_navBarSetHidden,
                             (IMP *)&pt_origNavBarSetHidden);
    pt_replaceInstanceMethod(uiNavBar,
                             @selector(setAlpha:),
                             (IMP)pt_navBarSetAlpha,
                             (IMP *)&pt_origNavBarSetAlpha);
    pt_replaceInstanceMethod(uiToolbar,
                             @selector(setHidden:),
                             (IMP)pt_toolbarSetHidden,
                             (IMP *)&pt_origToolbarSetHidden);
    pt_replaceInstanceMethod(uiToolbar,
                             @selector(setAlpha:),
                             (IMP)pt_toolbarSetAlpha,
                             (IMP *)&pt_origToolbarSetAlpha);
    pt_replaceInstanceMethod(uiBarButtonItem,
                             sel_registerName("setHidden:"),
                             (IMP)pt_barItemSetHidden,
                             (IMP *)&pt_origBarItemSetHidden);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldNavigationBarInsetViewController:"),
                             (IMP)pt_navShouldInsetVC,
                             (IMP *)&pt_origNavShouldInsetVC);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldNavigationBarInsetViewController:orOverlayContent:"),
                             (IMP)pt_navShouldInsetVCOrOverlay,
                             (IMP *)&pt_origNavShouldInsetVCOrOverlay);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldToolBar:insetViewController:"),
                             (IMP)pt_toolbarShouldInsetVC,
                             (IMP *)&pt_origToolbarShouldInsetVC);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldToolBar:insetViewController:orOverlayContent:"),
                             (IMP)pt_toolbarShouldInsetVCOrOverlay,
                             (IMP *)&pt_origToolbarShouldInsetVCOrOverlay);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_edgeInsetsForChildViewController:insetsAreAbsolute:"),
                             (IMP)pt_navEdgeInsetsForChild,
                             (IMP *)&pt_origNavEdgeInsetsForChild);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(setToolbarHidden:animated:),
                             (IMP)pt_navSetToolbarHiddenAnimated,
                             (IMP *)&pt_origNavSetToolbarHiddenAnimated);
}

// MARK: - Settled Window-Resize Transition Coordinator & Dispatcher

@interface PTWindowResizeTransitionCoordinator : NSObject <UIViewControllerTransitionCoordinator>
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) NSMutableArray<void (^)(id<UIViewControllerTransitionCoordinatorContext>)> *alongsideAnimations;
@property (nonatomic, strong) NSMutableArray<void (^)(id<UIViewControllerTransitionCoordinatorContext>)> *completions;
- (instancetype)initWithContainerView:(UIView *)containerView;
- (void)completeWithWindow:(UIWindow *)window;
@end

@implementation PTWindowResizeTransitionCoordinator

- (instancetype)initWithContainerView:(UIView *)containerView {
    self = [super init];
    if (self) {
        _containerView = containerView;
        _alongsideAnimations = [NSMutableArray array];
        _completions = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isAnimated { return NO; }
- (UIModalPresentationStyle)presentationStyle { return UIModalPresentationNone; }
- (BOOL)initiallyInteractive { return NO; }
- (BOOL)isInterruptible { return NO; }
- (BOOL)isInteractive { return NO; }
- (BOOL)isCancelled { return NO; }
- (NSTimeInterval)transitionDuration { return 0.0; }
- (CGFloat)percentComplete { return 1.0; }
- (CGFloat)completionVelocity { return 1.0; }
- (UIViewAnimationCurve)completionCurve { return UIViewAnimationCurveLinear; }
- (CGAffineTransform)targetTransform { return CGAffineTransformIdentity; }

- (__kindof UIViewController *)viewControllerForKey:(UITransitionContextViewControllerKey)key {
    (void)key;
    return nil;
}

- (__kindof UIView *)viewForKey:(UITransitionContextViewKey)key {
    (void)key;
    return nil;
}

- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                        completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion {
    if (animation) {
        [self.alongsideAnimations addObject:[animation copy]];
    }
    if (completion) {
        [self.completions addObject:[completion copy]];
    }
    return YES;
}

- (BOOL)animateAlongsideTransitionInView:(UIView *)view
                               animation:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                              completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion {
    (void)view;
    return [self animateAlongsideTransition:animation completion:completion];
}

- (void)notifyWhenInteractionEndsUsingBlock:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))handler {
    (void)handler;
}

- (void)notifyWhenInteractionChangesUsingBlock:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))handler {
    (void)handler;
}

- (void)completeWithWindow:(UIWindow *)window {
    NSArray *animations = [self.alongsideAnimations copy];
    NSArray *completions = [self.completions copy];
    [self.alongsideAnimations removeAllObjects];
    [self.completions removeAllObjects];

    if (animations.count > 0) {
        [UIView performWithoutAnimation:^{
            for (void (^block)(id<UIViewControllerTransitionCoordinatorContext>) in animations) {
                block(self);
            }
        }];
    }
    [window setNeedsLayout];
    [window layoutIfNeeded];
    for (void (^block)(id<UIViewControllerTransitionCoordinatorContext>) in completions) {
        block(self);
    }
}

@end

static __thread BOOL pt_duoDispatchingSizeTransition = NO;

static NSArray<UIViewController *> *pt_topLevelTransitionVCsForWindow(UIWindow *window, CGRect referenceBounds) {
    if (!window || !window.rootViewController) {
        return @[];
    }
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    UIViewController *cur = window.rootViewController;
    for (NSInteger depth = 0; depth < 16 && cur != nil; depth++) {
        if ([visited containsObject:cur]) {
            break;
        }
        [visited addObject:cur];

        if (cur.isViewLoaded && !cur.isBeingDismissed) {
            if (cur == window.rootViewController || pt_presentationCoversWindowBounds(cur, referenceBounds)) {
                [result addObject:cur];
            }
        }
        UIViewController *presented = cur.presentedViewController;
        if (!presented || presented.isBeingDismissed) {
            break;
        }
        cur = presented;
    }
    return result;
}

static void pt_syncTrafficLightTopClearanceForWindow(UIWindow *window) {
    if (!window || ![window isKindOfClass:[UIWindow class]] || ![NSThread isMainThread]) {
        return;
    }
    CGFloat desired = pt_windowTrafficLightTopClearance(window);
    NSHashTable<UIViewController *> *tracked = objc_getAssociatedObject(window, kPTDuoTrackedTopClearanceVCsKey);
    if (!tracked && desired <= 0.5) {
        return;
    }
    if (!tracked) {
        tracked = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(window, kPTDuoTrackedTopClearanceVCsKey, tracked, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSHashTable<UIViewController *> *activeTargets = [NSHashTable weakObjectsHashTable];
    if (desired > 0.5 && window.rootViewController) {
        NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
        UIViewController *cur = window.rootViewController;
        for (NSInteger depth = 0; depth < 16 && cur != nil; depth++) {
            if ([visited containsObject:cur]) {
                break;
            }
            [visited addObject:cur];
            if (!cur.isBeingDismissed
                && (cur == window.rootViewController || pt_presentationCoversWindowBounds(cur, window.bounds))) {
                [activeTargets addObject:cur];
                [tracked addObject:cur];
            }
            UIViewController *presented = cur.presentedViewController;
            if (!presented || presented.isBeingDismissed) {
                break;
            }
            cur = presented;
        }
    }

    BOOL didChangeAny = NO;
    for (UIViewController *vc in [tracked allObjects]) {
        CGFloat prevApplied = [objc_getAssociatedObject(vc, kPTDuoAppliedTopClearanceKey) doubleValue];
        if (!isfinite(prevApplied)) {
            prevApplied = 0.0;
        }
        CGFloat targetApplied = [activeTargets containsObject:vc] ? desired : 0.0;
        CGFloat delta = targetApplied - prevApplied;
        if (fabs(delta) > 0.25) {
            UIEdgeInsets addInsets = vc.additionalSafeAreaInsets;
            if (!isfinite(addInsets.top)) {
                addInsets.top = 0.0;
            }
            addInsets.top = MAX(0.0, addInsets.top + delta);
            vc.additionalSafeAreaInsets = addInsets;
            objc_setAssociatedObject(vc,
                                     kPTDuoAppliedTopClearanceKey,
                                     (targetApplied > 0.25) ? @(targetApplied) : nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (vc.isViewLoaded) {
                [vc.view setNeedsLayout];
            }
            didChangeAny = YES;
        }
        if (targetApplied <= 0.25) {
            [tracked removeObject:vc];
        }
    }
    if (didChangeAny) {
        [window setNeedsLayout];
    }
}

static void pt_notifyVisibleVCTreeSafeAreaDidChange(UIViewController *vc,
                                                    UIWindow *window,
                                                    NSHashTable<UIViewController *> *visited,
                                                    NSInteger depth) {
    if (!vc || !window || depth >= 16 || [visited containsObject:vc] || vc.isBeingDismissed) {
        return;
    }
    [visited addObject:vc];
    if (!vc.isViewLoaded) {
        return;
    }
    UIView *v = vc.view;
    if (!v || v.window != window || v.hidden || v.alpha <= 0.05) {
        return;
    }
    CGRect frameInWin = [v convertRect:v.bounds toView:window];
    if (!CGRectIntersectsRect(frameInWin, window.bounds)) {
        return;
    }

    [vc viewSafeAreaInsetsDidChange];

    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        UIViewController *topVC = nav.topViewController;
        UIViewController *visVC = nav.visibleViewController;
        if (topVC) {
            pt_notifyVisibleVCTreeSafeAreaDidChange(topVC, window, visited, depth + 1);
        }
        if (visVC && visVC != topVC) {
            pt_notifyVisibleVCTreeSafeAreaDidChange(visVC, window, visited, depth + 1);
        }
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabVC = (UITabBarController *)vc;
        UIViewController *activeTabVC = pt_selectedViewControllerForTabBarController(tabVC);
        if (activeTabVC) {
            pt_notifyVisibleVCTreeSafeAreaDidChange(activeTabVC, window, visited, depth + 1);
        }
    } else {
        for (UIViewController *child in vc.childViewControllers) {
            pt_notifyVisibleVCTreeSafeAreaDidChange(child, window, visited, depth + 1);
        }
    }
}

static void pt_notifyVisibleControllersSafeAreaDidChange(UIWindow *window,
                                                         NSArray<UIViewController *> *topLevelVCs) {
    if (!window || topLevelVCs.count == 0) {
        return;
    }
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    for (UIViewController *vc in topLevelVCs) {
        pt_notifyVisibleVCTreeSafeAreaDidChange(vc, window, visited, 0);
    }
}

void pt_seedWindowTransitionSizeBaselineIfNeeded(UIWindow *window, CGSize baselineSize) {
    if (!window
        || ![window isKindOfClass:[UIWindow class]]
        || ![NSThread isMainThread]) {
        return;
    }
    NSValue *existingVal = objc_getAssociatedObject(window, kPTDuoLastTransitionSizeKey);
    CGSize currentBaseline = existingVal ? existingVal.CGSizeValue : CGSizeZero;
    if (PTDuoShouldSeedInitialTransitionBaseline(currentBaseline, baselineSize)) {
        NSValue *seedVal = [NSValue valueWithCGSize:baselineSize];
        objc_setAssociatedObject(window,
                                 kPTDuoLastTransitionSizeKey,
                                 seedVal,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSValue *existingSAVal = objc_getAssociatedObject(window, kPTDuoLastSettledResizeSafeAreaNotifySizeKey);
        CGSize saBaseline = existingSAVal ? existingSAVal.CGSizeValue : CGSizeZero;
        if (PTDuoShouldSeedInitialTransitionBaseline(saBaseline, baselineSize)) {
            objc_setAssociatedObject(window,
                                     kPTDuoLastSettledResizeSafeAreaNotifySizeKey,
                                     seedVal,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    CGRect refBounds = CGRectMake(0.0, 0.0, baselineSize.width, baselineSize.height);
    for (UIViewController *vc in pt_topLevelTransitionVCsForWindow(window, refBounds)) {
        NSValue *vcVal = objc_getAssociatedObject(vc, kPTDuoLastTransitionSizeKey);
        CGSize vcBaseline = vcVal ? vcVal.CGSizeValue : CGSizeZero;
        if (PTDuoShouldSeedInitialTransitionBaseline(vcBaseline, baselineSize)) {
            objc_setAssociatedObject(vc,
                                     kPTDuoLastTransitionSizeKey,
                                     [NSValue valueWithCGSize:baselineSize],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void pt_recordRootViewControllerSizeTransition(UIViewController *viewController, CGSize size) {
    if (!viewController
        || ![viewController isKindOfClass:[UIViewController class]]
        || ![NSThread isMainThread]
        || !isfinite(size.width)
        || !isfinite(size.height)
        || size.width < 100.0
        || size.height < 100.0) {
        return;
    }
    UIWindow *win = viewController.viewIfLoaded.window;
    BOOL isRootVC = (win && win.rootViewController == viewController);
    BOOL isPresentationRoot = (viewController.parentViewController == nil && viewController.presentingViewController != nil);
    NSValue *sizeVal = [NSValue valueWithCGSize:size];
    if (isRootVC || isPresentationRoot || viewController.parentViewController == nil) {
        objc_setAssociatedObject(viewController,
                                 kPTDuoLastTransitionSizeKey,
                                 sizeVal,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (isRootVC) {
        objc_setAssociatedObject(win,
                                 kPTDuoLastTransitionSizeKey,
                                 sizeVal,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSValue *existingSAVal = objc_getAssociatedObject(win, kPTDuoLastSettledResizeSafeAreaNotifySizeKey);
        CGSize saBaseline = existingSAVal ? existingSAVal.CGSizeValue : CGSizeZero;
        if (PTDuoShouldSeedInitialTransitionBaseline(saBaseline, size)) {
            objc_setAssociatedObject(win,
                                     kPTDuoLastSettledResizeSafeAreaNotifySizeKey,
                                     sizeVal,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void pt_dispatchWindowResizeTransitionIfNeeded(UIWindow *window, CGSize newSize, BOOL isLiveResizing) {
    if (!window
        || ![window isKindOfClass:[UIWindow class]]
        || ![NSThread isMainThread]
        || isLiveResizing) {
        return;
    }
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC || !rootVC.isViewLoaded) {
        return;
    }
    if (!isfinite(newSize.width) || !isfinite(newSize.height)
        || newSize.width < 100.0 || newSize.height < 100.0) {
        return;
    }

    NSValue *lastWinVal = objc_getAssociatedObject(window, kPTDuoLastTransitionSizeKey);
    NSArray<UIViewController *> *topLevelVCs = pt_topLevelTransitionVCsForWindow(window, window.bounds);
    BOOL anyVCSeeded = NO;
    for (UIViewController *vc in topLevelVCs) {
        if (objc_getAssociatedObject(vc, kPTDuoLastTransitionSizeKey) != nil) {
            anyVCSeeded = YES;
            break;
        }
    }

    if (!lastWinVal && !anyVCSeeded) {
        // Seed initial settled size baseline without firing a spurious cold-launch transition.
        NSValue *seedVal = [NSValue valueWithCGSize:newSize];
        objc_setAssociatedObject(window, kPTDuoLastTransitionSizeKey, seedVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(window, kPTDuoLastSettledResizeSafeAreaNotifySizeKey, seedVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIViewController *vc in topLevelVCs) {
            objc_setAssociatedObject(vc, kPTDuoLastTransitionSizeKey, seedVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    NSMutableArray<UIViewController *> *pendingTargets = [NSMutableArray array];
    for (UIViewController *vc in topLevelVCs) {
        NSValue *vcLastVal = objc_getAssociatedObject(vc, kPTDuoLastTransitionSizeKey) ?: lastWinVal;
        CGSize vcLastSize = vcLastVal ? vcLastVal.CGSizeValue : CGSizeZero;
        if (PTDuoShouldDispatchViewWillTransitionToSize(vcLastSize,
                                                         newSize,
                                                         isLiveResizing,
                                                         pt_duoDispatchingSizeTransition)) {
            [pendingTargets addObject:vc];
        }
    }

    NSValue *newVal = [NSValue valueWithCGSize:newSize];
    objc_setAssociatedObject(window, kPTDuoLastTransitionSizeKey, newVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (pendingTargets.count > 0) {
        for (UIViewController *vc in pendingTargets) {
            objc_setAssociatedObject(vc, kPTDuoLastTransitionSizeKey, newVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        pt_duoDispatchingSizeTransition = YES;
        @try {
            UIView *container = pendingTargets.lastObject.viewIfLoaded ?: rootVC.viewIfLoaded ?: window;
            PTWindowResizeTransitionCoordinator *coord =
                [[PTWindowResizeTransitionCoordinator alloc] initWithContainerView:container];
            for (UIViewController *vc in pendingTargets) {
                [vc viewWillTransitionToSize:newSize withTransitionCoordinator:coord];
            }
            [coord completeWithWindow:window];
        } @finally {
            pt_duoDispatchingSizeTransition = NO;
        }
    }

    NSValue *lastSAVal = objc_getAssociatedObject(window, kPTDuoLastSettledResizeSafeAreaNotifySizeKey) ?: lastWinVal;
    CGSize lastSASize = lastSAVal ? lastSAVal.CGSizeValue : CGSizeZero;
    if (PTShouldEnableDuoVerticalBar()
        && PTDuoShouldNotifySafeAreaAfterSettledResize(lastSASize,
                                                       newSize,
                                                       isLiveResizing,
                                                       pt_duoDispatchingSizeTransition)) {
        objc_setAssociatedObject(window,
                                 kPTDuoLastSettledResizeSafeAreaNotifySizeKey,
                                 newVal,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_refreshDuoVerticalBarForWindow(window);
        pt_syncTrafficLightTopClearanceForWindow(window);
        pt_duoDispatchingSizeTransition = YES;
        @try {
            [window setNeedsLayout];
            [window layoutIfNeeded];
            pt_notifyVisibleControllersSafeAreaDidChange(window, topLevelVCs);
            [window setNeedsLayout];
            [window layoutIfNeeded];
        } @finally {
            pt_duoDispatchingSizeTransition = NO;
        }
    }
}

#else

void pt_seedWindowTransitionSizeBaselineIfNeeded(UIWindow *window, CGSize baselineSize) {
    (void)window;
    (void)baselineSize;
}

void pt_recordRootViewControllerSizeTransition(UIViewController *viewController, CGSize size) {
    (void)viewController;
    (void)size;
}

void pt_dispatchWindowResizeTransitionIfNeeded(UIWindow *window, CGSize newSize, BOOL isLiveResizing) {
    (void)window;
    (void)newSize;
    (void)isLiveResizing;
}

UIEdgeInsets pt_duoDiagnosticWindowSuperSafeAreaInsets(UIWindow *window) {
    return window ? window.safeAreaInsets : UIEdgeInsetsZero;
}

UIEdgeInsets pt_duoDiagnosticWindowTrueNativeSafeAreaInsets(UIWindow *window) {
    return window ? window.safeAreaInsets : UIEdgeInsetsZero;
}

NSDictionary *PTDuoCopyDecisionSnapshotForWindow(UIWindow *window) {
    (void)window;
    return @{};
}

void PTDuoSetGlobalBackRefreshHandler(void (^ _Nullable handler)(void)) {
    (void)handler;
}

BOOL PTDuoQueryGlobalBackStateForWindow(UIWindow * _Nullable window,
                                        BOOL includeTopClose,
                                        BOOL * _Nullable outHasSidebarBackButton) {
    (void)window;
    (void)includeTopClose;
    if (outHasSidebarBackButton) {
        *outHasSidebarBackButton = NO;
    }
    return NO;
}

BOOL PTDuoPerformGlobalBackActionForWindow(UIWindow * _Nullable window, BOOL includeTopClose) {
    (void)window;
    (void)includeTopClose;
    return NO;
}

BOOL PTDuoWindowHasActiveTextInput(UIWindow * _Nullable window) {
    (void)window;
    return NO;
}

BOOL PTDuoQueryGlobalHomeStateForWindow(UIWindow * _Nullable window) {
    (void)window;
    return NO;
}

BOOL PTDuoPerformGlobalHomeActionForWindow(UIWindow * _Nullable window) {
    (void)window;
    return NO;
}

#endif
