#!/usr/bin/env python3
"""Contract and math unit test for iPhone Duo Vertical Bar emulation in PlayTools."""

import re
import subprocess
import sys
import tempfile
from pathlib import Path


def read_text(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def check_source_contract(pt_root: Path) -> list[str]:
    pt_dir = pt_root / "PlayTools"
    settings = read_text(pt_dir / "PlaySettings.swift")
    loader_h = read_text(pt_dir / "PlayLoader.h")
    loader_m = read_text(pt_dir / "PlayLoader.m")
    duo = read_text(pt_dir / "DuoVerticalBarCompatibility.m")
    pbxproj = read_text(pt_root / "PlayTools.xcodeproj" / "project.pbxproj")

    failures: list[str] = []

    required = [
        ("PlaySettings:duoVerticalBarDecode", settings, "var duoVerticalBar: Bool?"),
        ("PlaySettings:duoVerticalBarProperty", settings, "lazy var duoVerticalBar = settingsData.duoVerticalBar ?? false"),
        ("PlayLoaderH:enableDecl", loader_h, "BOOL PTShouldEnableDuoVerticalBar(void);"),
        ("PlayLoaderM:installCall", loader_m, "pt_installDuoVerticalBarCompatibility();"),
        ("Duo:enableImpl", duo, "PTShouldEnableDuoVerticalBar(void)"),
        ("Duo:optInEarlyReturn", duo, "if (!PTShouldEnableDuoVerticalBar())"),
        ("Duo:traitSystemAllowed", duo, '"_UITraitSystemVerticalBarAllowed"'),
        ("Duo:traitSystemEdge", duo, '"_UITraitSystemVerticalBarHorizontalEdge"'),
        ("Duo:traitAllowed", duo, '"_UITraitVerticalBarAllowed"'),
        ("Duo:traitSetInt", duo, "setNSIntegerValue:forTrait:"),
        ("Duo:traitRemove", duo, "removeTrait:"),
        ("Duo:preferredBehavior", duo, '"preferredVerticalBarBehavior"'),
        ("Duo:childPreferredBehavior", duo, '"childViewControllerForPreferredVerticalBarBehavior"'),
        ("Duo:needsUpdateConfig", duo, '"setNeedsUpdateOfVerticalBarConfiguration"'),
        ("Duo:sceneSafeAreaHook", duo, '"_sceneSafeAreaInsetsIncludingStatusBar:"'),
        ("Duo:sceneSafeAreaOrientHook", duo, '"_safeAreaInsetsForInterfaceOrientation:"'),
        ("Duo:nativeSafeAreaBypassGuard", duo, "pt_duoBypassSceneSafeAreaHookDepth"),
        ("Duo:sceneSafeAreaDidChange", duo, '"_sceneSettingsSafeAreaInsetsDidChange"'),
        ("Duo:windowUpdateSafeArea", duo, '"_updateSafeAreaInsets"'),
        ("Duo:notifySafeAreaChangeMath", duo, "PTDuoShouldNotifySafeAreaChange"),
        ("Duo:dispatchResizeTransitionMath", duo, "PTDuoShouldDispatchViewWillTransitionToSize"),
        ("Duo:seedTransitionBaselineMath", duo, "PTDuoShouldSeedInitialTransitionBaseline"),
        ("Duo:seedTransitionBaselineFn", duo, "pt_seedWindowTransitionSizeBaselineIfNeeded"),
        ("Duo:resizeTransitionCoordinator", duo, "@implementation PTWindowResizeTransitionCoordinator"),
        ("Duo:resizeTransitionDispatcher", duo, "pt_dispatchWindowResizeTransitionIfNeeded"),
        ("Duo:resizeTransitionRecorder", duo, "pt_recordRootViewControllerSizeTransition"),
        ("Duo:regionEdgeExtent", duo, '"layoutRegionForBarOnEdge:extent:"'),
        ("Duo:regionDirEdgeExtent", duo, '"layoutRegionForBarOnDirectionalEdge:extent:"'),
        ("Duo:viewLayoutGuide", duo, '"layoutGuideForLayoutRegion:"'),
        ("Duo:viewEdgeInsets", duo, '"edgeInsetsForLayoutRegion:"'),
        ("Duo:viewDirEdgeInsets", duo, '"directionalEdgeInsetsForLayoutRegion:"'),
        ("Duo:autoYieldCheck", duo, "pt_windowHasAppRenderedRightSidebar"),
        ("Duo:substantialSidebarMath", duo, "PTDuoRectLooksLikeSubstantialSidebar"),
        ("Duo:tabBarRelocatableCheck", duo, "pt_tabBarControllerHasRelocatableDock"),
        ("Duo:tabSetTabsHook", duo, "pt_tabBarControllerSetTabs"),
        ("Duo:tabSetViewControllersHook", duo, "pt_tabBarControllerSetVCsAnimated"),
        ("Duo:hostViewClass", duo, "@implementation PTDuoVerticalBarHostView"),
        ("Duo:backButtonSymbol", duo, '"chevron.backward"'),
        ("Duo:axisBehaviorCheck", duo, '"axisBehavior"'),
        ("Duo:tabDelegateShouldSelect", duo, "tabBarController:shouldSelectViewController:"),
        ("Duo:modernTabDelegateShouldSelect", duo, '"tabBarController:shouldSelectTab:"'),
        ("Duo:modernTabDelegateDidSelect", duo, '"tabBarController:didSelectTab:previousTab:"'),
        ("Duo:modernTabProminentId", duo, '"prominentTabIdentifier"'),
        ("Duo:modernTabSearchTab", duo, '@"UISearchTab"'),
        ("Duo:modernTabCollect", duo, "pt_collectModernTabs"),
        ("Duo:modernTabProminentPill", duo, "prominentPill"),
        ("Duo:floatingTabBarGroupHide", duo, '"_UIBottomTabBarGroupView"'),
        ("Duo:floatingTabBarAuxStyle", duo, '"_UITabBarAuxiliaryView"'),
        ("Duo:recursiveChildDescent", duo, "pt_largestVisibleChildViewController"),
        ("Duo:childCoversContainerMath", duo, "PTDuoChildFrameCoversContainer"),
        ("Duo:navBarHiddenBackGuard", duo, "PTDuoShouldShowSyntheticBackButton"),
        ("Duo:navBarVisibleByApp", duo, "pt_navBarVisibleByApp"),
        ("Duo:emptyInsetCollapseMath", duo, "PTDuoShouldCollapseEmptyRightInset"),
        ("Duo:occupiedBarWidthMath", duo, "PTDuoResolveOccupiedRightBarWidth"),
        ("Duo:effectiveRightInsetMath", duo, "PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth"),
        ("Duo:barRegionEdgeInsetsMath", duo, "PTDuoBarRegionEdgeInsets"),
        ("Duo:barRegionDirEdgeInsetsMath", duo, "PTDuoBarRegionDirectionalEdgeInsets"),
        ("Duo:adjustRightBarMath", duo, "PTDuoAdjustRightBarEdgeInsets"),
        ("Duo:adjustRightBarDirMath", duo, "PTDuoAdjustRightBarDirectionalEdgeInsets"),
        ("Duo:topRightOcclusionRectMath", duo, "PTDuoTopRightOcclusionRect"),
        ("Duo:effectiveHidesBackMath", duo, "PTDuoNavItemEffectiveHidesBackButton"),
        ("Duo:visibleLeadingItemsCheck", duo, "pt_navItemHasVisibleLeadingItems"),
        ("Duo:sceneRegionsHook", duo, '"_sceneRegionsWithTypes:"'),
        ("Duo:sceneRegionClass", duo, '@"_UISceneRegion"'),
        ("Duo:navItemLeftItemsHook", duo, "setLeftBarButtonItems:animated:"),
        ("Duo:navItemLeftSupplementHook", duo, "setLeftItemsSupplementBackButton:"),
        ("Duo:swiftEdgeInsetsInterpose", duo, "_$sSo6UIViewC5UIKitE10edgeInsets3forSo06UIEdgeD0VAbCE12LayoutRegionV_tF"),
        ("Duo:swiftDirEdgeInsetsInterpose", duo, "_$sSo6UIViewC5UIKitE21directionalEdgeInsets3forSo013NSDirectionaldE0VAbCE12LayoutRegionV_tF"),
        ("Duo:swiftLayoutGuideInterpose", duo, "_$sSo6UIViewC5UIKitE11layoutGuide3forSo08UILayoutD0CAbCE12LayoutRegionV_tF"),
        ("Duo:inferRightBarFromInsets", duo, "PTDuoInferRightBarExtentFromEdgeInsets"),
        ("Duo:coalescedRegionQuery", duo, "pt_markRightBarRegionQueriedCoalesced"),
        ("Duo:insetStateClass", duo, "@implementation PTDuoWindowInsetState"),
        ("Duo:queriedRightBarRegion", duo, "queriedRightBarRegion"),
        ("Duo:collapsedEmptyRightInset", duo, "collapsedEmptyRightInset"),
        ("Duo:tabBarRelocate", duo, "pt_setTabBarRelocatedHidden"),
        ("Duo:customTabBarGuard", duo, "pt_duoTabBarIsCustomReplacement"),
        ("Duo:navBarClassify", duo, "PTDuoClassifyNavBarSuppression"),
        ("Duo:navBarTopInsetAdjust", duo, "PTDuoAdjustedSuppressedNavBarTopInset"),
        ("Duo:navBarVisualSuppress", duo, "pt_setNavBarVisualSuppressed"),
        ("Duo:toolbarVisualSuppress", duo, "pt_setToolbarVisualSuppressed"),
        ("Duo:barItemHorizontalSuppress", duo, "pt_setBarItemHorizontalSuppressed"),
        ("Duo:navItemBackSuppress", duo, "pt_setNavItemBackButtonSuppressed"),
        ("Duo:navShouldInsetHook", duo, '"_shouldNavigationBarInsetViewController:"'),
        ("Duo:navEdgeInsetsHook", duo, '"_edgeInsetsForChildViewController:insetsAreAbsolute:"'),
        ("Duo:toolbarShouldInsetHook", duo, '"_shouldToolBar:insetViewController:"'),
        ("Duo:horizontalOnlyCheck", duo, "pt_barItemIsHorizontalOnly"),
        ("Duo:hitTestPassthrough", duo, "- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event"),
        ("Duo:landscapeSceneSafeAreaMath", duo, "PTDuoEffectiveSceneSafeAreaInsets"),
        ("Duo:windowSuperSafeAreaHelper", duo, "pt_windowSuperSafeAreaInsets"),
        ("Duo:visualTitleViewMath", duo, "PTDuoViewIsVisualTitleView"),
        ("Duo:shouldRelocateBarItemMath", duo, "PTDuoShouldRelocateBarItem"),
        ("Duo:tabOverlayMatchesCenterXMath", duo, "PTDuoTabSlotOverlayMatchesCenterX"),
        ("Duo:promoteTabOverlayMath", duo, "PTDuoShouldPromoteTabOverlayToProminent"),
        ("Duo:leadingPillProp", duo, "leadingPill"),
        ("Duo:toolbarPillProp", duo, "toolbarPill"),
        ("Duo:floatingToolbarContainer", duo, '"_UIFloatingBarContainerView"'),
        ("Duo:customViewWindowSafeSuppress", duo, "pt_setCustomViewHorizontalSuppressed"),
        ("Duo:popToVCAnimatedHook", duo, "popToViewController:animated:"),
        ("Duo:dismissVCHook", duo, "dismissViewControllerAnimated:completion:"),
        ("Duo:templateTintOnGlass", duo, "pt_imageNeedsTemplateTintOnGlass"),
        ("Duo:blankSlotOverlayDiscovery", duo, "pt_discoverBlankSlotOverlays"),
        ("Duo:floatingVerticalRailMath", duo, "PTDuoRectIsFloatingVerticalRail"),
        ("Duo:collapsedSidebarGateMath", duo, "PTDuoShouldAcceptSidebarInCollapsedState"),
        ("Duo:topRightOcclusionOccupiedWidth", duo, "PTDuoTopRightOcclusionRectForOccupiedWidth"),
        ("Duo:statusBarHiddenMath", duo, "PTDuoResolveStatusBarHidden"),
        ("Duo:statusBarManagerHook", duo, '"UIStatusBarManager"'),
        ("Duo:resolveVCStatusBarHidden", duo, "pt_resolvePrefersStatusBarHiddenForWindow"),
        ("Duo:preserveRecentBarQueryMath", duo, "PTDuoShouldPreserveRecentRightBarQuery"),
        ("Duo:probeOnTransition", duo, "pt_beginProbeOnTransitionIfNeeded"),
        ("Duo:vcPresentHook", duo, "pt_vcPresentVC"),
        ("Duo:topLevelTransitionVCs", duo, "pt_topLevelTransitionVCsForWindow"),
        ("Duo:trafficLightClearanceMath", duo, "PTDuoTrafficLightTopClearance"),
        ("Duo:syncTrafficLightTopClearance", duo, "pt_syncTrafficLightTopClearanceForWindow"),
        ("Duo:appliedTopClearanceKey", duo, "kPTDuoAppliedTopClearanceKey"),
        ("Duo:standardIconOnlyBarItemMath", duo, "PTDuoIsStandardIconOnlyBarItem"),
        ("Duo:layerVisualDrawingHelper", duo, "pt_layerHasOwnVisualDrawing"),
        ("Duo:floatingBarHostOrphanTraverse", duo, "isHostedFloatingBottomChrome"),
        ("Duo:suppressFloatingBarHostMath", duo, "PTDuoShouldSuppressFloatingBarHost"),
        ("Duo:floatingChromeLeafControls", duo, "pt_collectFloatingChromeLeafControlsInNode"),
        ("Duo:visibleNavSubtreeScan", duo, "pt_collectVisibleNavControllersInSubtree"),
        ("Duo:layerStandaloneSublayerSuppress", duo, "pt_setLayerAndStandaloneSublayersSuppressed"),
        ("Duo:compositeForegroundGlyph", duo, "pt_snapshotCompositeForegroundGlyphInControl"),
        ("Duo:rectEnclosedInnerStrokeMath", duo, "PTDuoRectIsEnclosedInnerStroke"),
        ("Duo:colorsHaveContrastMath", duo, "PTDuoColorsHaveContrast"),
        ("Duo:settledResizeSafeAreaMath", duo, "PTDuoShouldNotifySafeAreaAfterSettledResize"),
        ("Duo:settledResizeSafeAreaSizeKey", duo, "kPTDuoLastSettledResizeSafeAreaNotifySizeKey"),
        ("Duo:notifyVisibleSafeArea", duo, "pt_notifyVisibleControllersSafeAreaDidChange"),
        ("Duo:adjustRightBarTopClearanceMath", duo, "PTDuoAdjustRightBarEdgeInsetsWithTopClearance"),
        ("Duo:signpostHelper", duo, "pt_duoSignpostLog"),
        ("Duo:decisionSnapshotExport", duo, "PTDuoCopyDecisionSnapshotForWindow"),
        ("Duo:playLoaderSnapshotDecl", loader_h, "PTDuoCopyDecisionSnapshotForWindow"),
        ("Duo:sharedVisualSuppressionSaveRestore", duo, "pt_applySavedVisualSuppression"),
        ("Duo:verifiedTapGestureExtractor", duo, "pt_extractVerifiedTapGestureAction"),
        ("Duo:canonicalBarItemPlan", duo, "pt_buildVerticalBarItemPlanForNav"),
        ("Duo:overflowSplitMath", duo, "PTDuoComputeOverflowSplit"),
        ("Duo:safeTabDockRelocateMath", duo, "PTDuoCanSafelyRelocateTabDock"),
        ("Duo:blankStringTrimHelper", duo, "pt_stringIsEffectivelyBlank"),
        ("Duo:placeholderImageBlankHelper", duo, "pt_imageIsPlaceholderBlank"),
        ("Duo:pureActionTabOverlayHelper", duo, "pt_discoverPureActionTabOverlay"),
        ("Duo:customBarWrapperSuppressHelper", duo, "pt_horizontalSuppressedViewForCustomBarItemView"),
        ("Duo:itemWrapperViewSuppress", duo, '"ItemWrapperView"'),
        ("Duo:multiNavDiscoveryEx", duo, "pt_findActiveNavAndTabControllersEx"),
        ("Duo:preserveOuterHeaderNavMath", duo, "PTDuoShouldPreserveOuterHeaderNav"),
        ("Duo:accentContrastFallbackMath", duo, "PTDuoShouldUseContrastFallbackForAccent"),
        ("Duo:snapshotStatsPixelCheck", duo, "pt_snapshotViewForVerticalBarWithStats"),
        ("Duo:platterNavBarCheck", duo, "pt_navBarUsesPlatterContainer"),
        ("Duo:leadingIconRoleRelocateMath", duo, "PTDuoShouldRelocateLeadingBarItemWithRole"),
        ("Duo:inspectOpaqueBadgeMath", duo, "PTDuoInspectOpaqueBadgeResult"),
        ("Duo:tabSlotActionKindMath", duo, "PTDuoResolveTabOverlayActionKind"),
        ("Duo:savedViewStateRestoreMath", duo, "PTDuoRestoreSavedViewState"),
        ("Duo:tabSlotNeedsOverlayMath", duo, "PTDuoTabItemSlotNeedsOverlay"),
        ("Duo:alphaBufferVisibleMath", duo, "PTDuoAlphaBufferHasVisiblePixels"),
        ("Duo:tabBarItemSetSelectedImageHook", duo, "pt_tabBarItemSetSelectedImage"),
        ("Duo:tabBarItemSetImageHook", duo, "pt_tabBarItemSetImage"),
        ("pbxproj:DuoVerticalBarCompatibility", pbxproj, "DuoVerticalBarCompatibility.m"),
    ]
    for label, text, needle in required:
        if needle not in text:
            failures.append(f"MISSING {label}: '{needle}'")

    # Forbidden patterns: zero bundleIdentifier hardcodes, no AJX guard hack, no fake status bar chrome
    forbidden = [
        ("Duo:noBundleIdentifier", duo, "bundleIdentifier"),
        ("Duo:noAmapBundleId", duo, "com.autonavi.amap"),
        ("Duo:noBiliBundleId", duo, "tv.danmaku.bilianime"),
        ("Duo:noXhsBundleId", duo, "com.xingin.discover"),
        ("Duo:noWeWorkBundleId", duo, "com.tencent.ww"),
        ("Duo:noReservedRegionsHook", duo, "reservedRegionsOfKind:"),
        ("Duo:noFakeBatteryIcon", duo, "battery.100"),
        ("Duo:noFakeWifiIcon", duo, "wifi"),
        ("Duo:noFakeSignalIcon", duo, "cellularbars"),
        ("PlayLoaderM:noAJXSidebarDuoGuard", loader_m, "pt_installAJXSidebarDuoGuard"),
    ]
    for label, text, needle in forbidden:
        if needle in text:
            failures.append(f"FORBIDDEN {label}: found '{needle}'")

    # Ensure no hardcoded bundle IDs matching common reverse-DNS app prefixes in DuoVerticalBarCompatibility.m
    if re.search(r'"(com|cn|tv|org|net|io)\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_.-]+"', duo):
        failures.append("FORBIDDEN Duo:reverseDnsStringLiteral detected in DuoVerticalBarCompatibility.m")

    return failures


def run_math_unit_tests(pt_root: Path) -> list[str]:
    duo_path = pt_root / "PlayTools" / "DuoVerticalBarCompatibility.m"
    src = read_text(duo_path)
    start_marker = "// MARK: - PTDuoVerticalBarMath"
    end_marker = "// MARK: - Associated Object Keys & State Types"
    if start_marker not in src or end_marker not in src:
        return ["Math markers not found in DuoVerticalBarCompatibility.m"]

    math_block = src[src.index(start_marker):src.index(end_marker)]

    harness = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>
#import <math.h>
#import <stdio.h>

typedef NS_OPTIONS(NSUInteger, UIRectEdge) {
    UIRectEdgeNone   = 0,
    UIRectEdgeTop    = 1 << 0,
    UIRectEdgeLeft   = 1 << 1,
    UIRectEdgeBottom = 1 << 2,
    UIRectEdgeRight  = 1 << 3,
    UIRectEdgeAll    = UIRectEdgeTop | UIRectEdgeLeft | UIRectEdgeBottom | UIRectEdgeRight
};

typedef NS_OPTIONS(NSUInteger, NSDirectionalRectEdge) {
    NSDirectionalRectEdgeNone     = 0,
    NSDirectionalRectEdgeTop      = 1 << 0,
    NSDirectionalRectEdgeLeading  = 1 << 1,
    NSDirectionalRectEdgeBottom   = 1 << 2,
    NSDirectionalRectEdgeTrailing = 1 << 3,
    NSDirectionalRectEdgeAll      = NSDirectionalRectEdgeTop | NSDirectionalRectEdgeLeading | NSDirectionalRectEdgeBottom | NSDirectionalRectEdgeTrailing
};

typedef NS_ENUM(NSInteger, UIUserInterfaceLayoutDirection) {
    UIUserInterfaceLayoutDirectionLeftToRight,
    UIUserInterfaceLayoutDirectionRightToLeft,
};

typedef struct UIEdgeInsets {
    CGFloat top, left, bottom, right;
} UIEdgeInsets;

static inline UIEdgeInsets UIEdgeInsetsMake(CGFloat top, CGFloat left, CGFloat bottom, CGFloat right) {
    UIEdgeInsets i = { top, left, bottom, right };
    return i;
}
static const UIEdgeInsets UIEdgeInsetsZero = { 0, 0, 0, 0 };

typedef struct NSDirectionalEdgeInsets {
    CGFloat top, leading, bottom, trailing;
} NSDirectionalEdgeInsets;

static inline NSDirectionalEdgeInsets NSDirectionalEdgeInsetsMake(CGFloat top, CGFloat leading, CGFloat bottom, CGFloat trailing) {
    NSDirectionalEdgeInsets i = { top, leading, bottom, trailing };
    return i;
}

static const CGFloat kPTDuoVerticalBarWidth = 52.0;
static const CGFloat kPTDuoVerticalBarMinWindowWidth = 600.0;
static const CGFloat kPTDuoVerticalBarMinWindowHeight = 320.0;

''' + math_block + r'''

int main(void) {
    // 1. Activation gate & preferredVerticalBarBehavior opt-out
    assert(PTDuoShouldActivateForGeometry(YES, 900.0, 700.0, 0) == YES);
    assert(PTDuoShouldActivateForGeometry(YES, 600.0, 320.0, 0) == YES);
    assert(PTDuoShouldActivateForGeometry(NO, 900.0, 700.0, 0) == NO);
    assert(PTDuoShouldActivateForGeometry(YES, 599.0, 700.0, 0) == NO);
    assert(PTDuoShouldActivateForGeometry(YES, 900.0, 319.0, 0) == NO);
    assert(PTDuoShouldActivateForGeometry(YES, 900.0, 700.0, 1) == NO); // UIVerticalBarBehaviorDisabled
    assert(PTDuoShouldActivateForGeometry(YES, NAN, 700.0, 0) == NO);

    // 2. Physical & directional edge resolution
    assert(PTDuoResolvePhysicalBarEdge(NO, UIRectEdgeRight, NSDirectionalRectEdgeNone, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeRight);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeTrailing, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeRight);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeTrailing, UIUserInterfaceLayoutDirectionRightToLeft) == UIRectEdgeLeft);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeLeading, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeLeft);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeLeading, UIUserInterfaceLayoutDirectionRightToLeft) == UIRectEdgeRight);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeTop, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeTop);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeBottom, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeBottom);

    // 3. Extent resolution & clamping
    assert(fabs(PTDuoResolveBarExtent(YES, 48.0, 900.0) - 48.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(NO, 0.0, 900.0) - 52.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(YES, -5.0, 900.0) - 52.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(YES, NAN, 900.0) - 52.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(YES, 52.0, 40.0) - 40.0) < 0.001);

    // 4. App-rendered custom sidebar auto-yield geometry candidate checks
    CGRect win = CGRectMake(0, 0, 900, 700);
    // Custom 48pt sidebar (e.g. AJXSidebarView) pinned inside right 60pt strip -> candidate YES
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(846, 20, 48, 660), win) == YES);
    // Compact right-edge floating action column (36x120) -> candidate YES
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(852, 80, 36, 120), win) == YES);
    // Full-window map/content container -> NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(0, 0, 900, 700), win) == NO);
    // Wide panel (200pt) -> NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(700, 0, 200, 700), win) == NO);
    // Left-edge sidebar -> NOT a right-strip sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(6, 20, 48, 660), win) == NO);
    // Scrollbar indicator (6pt wide) -> too narrow, NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(892, 40, 6, 180), win) == NO);
    // Tiny badge (30x24) -> too short, NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(860, 40, 30, 24), win) == NO);
    // Narrow window (<600pt) -> NO
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(446, 20, 48, 660), CGRectMake(0, 0, 500, 700)) == NO);
    // Floating vertical rail capsule inset 24pt from trailing edge (e.g. AMDuoVerticalTabBar {W-72, y, 48, 240}) -> YES
    assert(PTDuoRectIsFloatingVerticalRail(CGRectMake(828, 240, 48, 240), win) == YES);
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(828, 240, 48, 240), win) == YES);
    // Compact button at same 24pt trailing inset ({W-72, y, 48, 44}) -> NOT a vertical rail or sidebar candidate
    assert(PTDuoRectIsFloatingVerticalRail(CGRectMake(828, 40, 48, 44), win) == NO);
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(828, 40, 48, 44), win) == NO);
    // Wide panel at trailing edge ({W-140, y, 120, 240}) -> NO
    assert(PTDuoRectIsFloatingVerticalRail(CGRectMake(760, 200, 120, 240), win) == NO);
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(760, 200, 120, 240), win) == NO);

    // Substantial sidebar gate: rejects single small top-right search button, preserves real sidebars
    CGRect win1000 = CGRectMake(0, 0, 1000, 720);
    // Single 44x40 top-right Search button -> NOT an app-rendered vertical sidebar
    assert(PTDuoRectLooksLikeSubstantialSidebar(CGRectMake(956, 42, 44, 40), win1000, NO, 1) == NO);
    // Margin-inset 44x44 corner glass button (maxX=984 < 992) -> rejected even if window queried layoutRegion
    assert(PTDuoRectLooksLikeSubstantialSidebar(CGRectMake(940, 32, 44, 44), win1000, YES, 1) == NO);
    // Compact right-edge bar flush at trailing edge backed by layoutRegion (e.g. AJXSidebarView {W-60, 30, 60, 48}) -> YES
    assert(PTDuoRectLooksLikeSubstantialSidebar(CGRectMake(940, 30, 60, 48), win1000, YES, 1) == YES);
    // Unbacked 60x48 single control -> NO
    assert(PTDuoRectLooksLikeSubstantialSidebar(CGRectMake(940, 30, 60, 48), win1000, NO, 1) == NO);
    // Tall vertical rail (h >= 84) -> YES even without layoutRegion
    assert(PTDuoRectLooksLikeSubstantialSidebar(CGRectMake(946, 80, 48, 180), win1000, NO, 1) == YES);
    // Multiple vertically stacked controls inside container (distinctCount >= 2) -> YES
    assert(PTDuoRectLooksLikeSubstantialSidebar(CGRectMake(946, 30, 48, 72), win1000, NO, 2) == YES);
    // Collapsed-state gate: accepts floating vertical rail (48x240 at W-72), rejects compact right-edge bar/button
    assert(PTDuoShouldAcceptSidebarInCollapsedState(NO, CGRectMake(928, 240, 48, 240), win1000, NO, 1) == YES);
    assert(PTDuoShouldAcceptSidebarInCollapsedState(NO, CGRectMake(940, 30, 60, 48), win1000, YES, 1) == NO);
    assert(PTDuoShouldAcceptSidebarInCollapsedState(NO, CGRectMake(946, 30, 48, 72), win1000, NO, 2) == NO);
    assert(PTDuoShouldAcceptSidebarInCollapsedState(YES, CGRectMake(940, 30, 60, 48), win1000, YES, 1) == YES);

    // 5. Horizontal UINavigationBar / UIToolbar deduplication classification & top-inset collapse
    // Case 1: bar visible, items relocated, no title/titleView/search/leading/HorizontalOnly -> Full suppression
    assert(PTDuoClassifyNavBarSuppression(YES, YES, NO) == PTDuoNavBarSuppressionFull);
    // Case 2: bar visible, items relocated, has title/search/HorizontalOnly content -> ItemsOnly suppression
    assert(PTDuoClassifyNavBarSuppression(YES, YES, YES) == PTDuoNavBarSuppressionItemsOnly);
    // App already hid bar OR nothing relocated -> None
    assert(PTDuoClassifyNavBarSuppression(NO, YES, NO) == PTDuoNavBarSuppressionNone);
    assert(PTDuoClassifyNavBarSuppression(YES, NO, NO) == PTDuoNavBarSuppressionNone);
    assert(PTDuoClassifyNavBarSuppression(YES, NO, YES) == PTDuoNavBarSuppressionNone);

    // Top-inset collapse preserves window safe area (e.g. 32pt traffic lights) while removing 54pt navBar push
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(86.0, YES, 32.0) - 32.0) < 0.001);
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(28.0, YES, 32.0) - 28.0) < 0.001);
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(54.0, NO, 32.0) - 0.0) < 0.001);
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(NAN, YES, 32.0) - 0.0) < 0.001);

    // 6. Recursive visible-child VC coverage math (>= 50% of container area)
    CGRect container = CGRectMake(0, 0, 900, 700);
    assert(PTDuoChildFrameCoversContainer(CGRectMake(0, 0, 900, 700), container) == YES);
    assert(PTDuoChildFrameCoversContainer(CGRectMake(0, 0, 450, 700), container) == YES); // exact 50%
    assert(PTDuoChildFrameCoversContainer(CGRectMake(0, 0, 440, 700), container) == NO);  // < 50%
    assert(PTDuoChildFrameCoversContainer(CGRectMake(840, 0, 60, 700), container) == NO); // sidebar strip only
    assert(PTDuoChildFrameCoversContainer(CGRectMake(-500, 0, 900, 700), container) == NO); // mostly offscreen (< 50% clipped)
    assert(PTDuoChildFrameCoversContainer(CGRectMake(0, 0, 900, 700), CGRectZero) == NO);

    // 7. Synthetic back button respects nav.isNavigationBarHidden
    assert(PTDuoShouldShowSyntheticBackButton(YES, NO, 2, NO) == YES);
    assert(PTDuoShouldShowSyntheticBackButton(YES, YES, 2, NO) == NO); // app hid UINavigationBar -> no duplicate '<'
    assert(PTDuoShouldShowSyntheticBackButton(YES, NO, 1, NO) == NO);  // root VC
    assert(PTDuoShouldShowSyntheticBackButton(YES, NO, 2, YES) == NO); // hidesBackButton == YES
    assert(PTDuoShouldShowSyntheticBackButton(NO, NO, 2, NO) == NO);

    // 8. Two-phase empty 60pt right safe-area inset collapse (preserves custom-sidebar apps)
    // While probing -> never collapse (offers 60pt immediately to custom-sidebar apps)
    assert(PTDuoShouldCollapseEmptyRightInset(YES, YES, NO, NO, NO) == NO);
    // Settled & completely empty (no synthetic host items, no app sidebar, no right UIViewLayoutRegion query) -> collapse!
    assert(PTDuoShouldCollapseEmptyRightInset(YES, NO, NO, NO, NO) == YES);
    // Settled with synthetic host items (e.g. relocated tab bar / back / nav items) -> keep 60pt
    assert(PTDuoShouldCollapseEmptyRightInset(YES, NO, YES, NO, NO) == NO);
    // Settled with app-rendered custom right sidebar -> keep 60pt
    assert(PTDuoShouldCollapseEmptyRightInset(YES, NO, NO, YES, NO) == NO);
    // Settled with right UIViewLayoutRegion query -> keep 60pt
    assert(PTDuoShouldCollapseEmptyRightInset(YES, NO, NO, NO, YES) == NO);
    // Inactive -> NO (already not injecting)
    assert(PTDuoShouldCollapseEmptyRightInset(NO, NO, NO, NO, NO) == NO);

    // Effective right safe-area inset calculation
    assert(fabs(PTDuoEffectiveRightSafeAreaInset(YES, NO, 0.0) - 52.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInset(YES, NO, 72.0) - 72.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInset(YES, YES, 0.0) - 0.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInset(YES, YES, 12.0) - 12.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInset(NO, NO, 0.0) - 0.0) < 0.001);

    // 9. Native-aligned UIViewLayoutRegion strip-rect edgeInsets & directionalEdgeInsets (LTR & RTL)
    // On 1000x720 view, right 60pt bar -> rect (940, 0, 60, 720) -> insets (t=0, l=940, b=0, r=0)
    UIEdgeInsets r60 = PTDuoBarRegionEdgeInsets(UIRectEdgeRight, 1000.0, 720.0, 60.0);
    assert(fabs(r60.top) < 0.001 && fabs(r60.left - 940.0) < 0.001 && fabs(r60.bottom) < 0.001 && fabs(r60.right) < 0.001);
    NSDirectionalEdgeInsets dr60_ltr = PTDuoBarRegionDirectionalEdgeInsets(UIRectEdgeRight, UIUserInterfaceLayoutDirectionLeftToRight, 1000.0, 720.0, 60.0);
    assert(fabs(dr60_ltr.leading - 940.0) < 0.001 && fabs(dr60_ltr.trailing) < 0.001);
    NSDirectionalEdgeInsets dr60_rtl = PTDuoBarRegionDirectionalEdgeInsets(UIRectEdgeRight, UIUserInterfaceLayoutDirectionRightToLeft, 1000.0, 720.0, 60.0);
    assert(fabs(dr60_rtl.leading) < 0.001 && fabs(dr60_rtl.trailing - 940.0) < 0.001);
    // In RTL, trailing bar resolves to physical UIRectEdgeLeft -> physical right=940, directional leading=940
    UIEdgeInsets l60 = PTDuoBarRegionEdgeInsets(UIRectEdgeLeft, 1000.0, 720.0, 60.0);
    assert(fabs(l60.left) < 0.001 && fabs(l60.right - 940.0) < 0.001);
    NSDirectionalEdgeInsets dl60_rtl = PTDuoBarRegionDirectionalEdgeInsets(UIRectEdgeLeft, UIUserInterfaceLayoutDirectionRightToLeft, 1000.0, 720.0, 60.0);
    assert(fabs(dl60_rtl.leading - 940.0) < 0.001 && fabs(dl60_rtl.trailing) < 0.001);

    // Inferring Swift-constructed right bar extent from native edgeInsets
    CGFloat inferred = 0.0;
    assert(PTDuoInferRightBarExtentFromEdgeInsets(UIEdgeInsetsMake(0, 932, 0, 0), 1000.0, &inferred) == YES);
    assert(fabs(inferred - 68.0) < 0.001);
    assert(PTDuoInferRightBarExtentFromEdgeInsets(UIEdgeInsetsMake(0, 0, 0, 68), 1000.0, &inferred) == NO);
    assert(PTDuoInferRightBarExtentFromEdgeInsets(UIEdgeInsetsMake(44, 0, 0, 0), 1000.0, &inferred) == NO);

    // 10. Occupied right bar width & safeAreaInsets.right separation
    assert(fabs(PTDuoResolveOccupiedRightBarWidth(YES, NO, YES, NO, 0.0, NO, 0.0) - 52.0) < 0.001);
    assert(fabs(PTDuoResolveOccupiedRightBarWidth(YES, NO, NO, YES, 48.0, NO, 0.0) - 52.0) < 0.001);
    assert(fabs(PTDuoResolveOccupiedRightBarWidth(YES, NO, NO, YES, 68.0, NO, 0.0) - 68.0) < 0.001);
    assert(fabs(PTDuoResolveOccupiedRightBarWidth(YES, NO, NO, NO, 0.0, YES, 68.0) - 68.0) < 0.001);
    assert(fabs(PTDuoResolveOccupiedRightBarWidth(YES, NO, NO, NO, 0.0, NO, 0.0) - 0.0) < 0.001);
    assert(fabs(PTDuoResolveOccupiedRightBarWidth(YES, YES, NO, NO, 0.0, NO, 0.0) - 52.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(YES, 68.0, 0.0) - 68.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(YES, 68.0, 80.0) - 80.0) < 0.001);
    assert(fabs(PTDuoEffectiveRightSafeAreaInsetForOccupiedWidth(YES, 0.0, 0.0) - 0.0) < 0.001);

    // 11. Top-right occlusion region rect for UIView.reservedRegions(kind: .occlusion)
    CGRect occDefault = PTDuoTopRightOcclusionRect(CGRectMake(0, 0, 1000, 720), 32.0, 0.0);
    assert(fabs(occDefault.origin.x - 948.0) < 0.001 && fabs(occDefault.origin.y - 0.0) < 0.001
           && fabs(occDefault.size.width - 52.0) < 0.001 && fabs(occDefault.size.height - 32.0) < 0.001);
    // Downstream trailing-rail view positioned via maxY+12, midX-6 (48x106) -> {944, 44, 48, 106}
    CGRect vfRect = CGRectMake(CGRectGetMidX(occDefault) - 6.0 - 24.0, CGRectGetMaxY(occDefault) + 12.0, 48.0, 106.0);
    assert(fabs(vfRect.origin.x - 944.0) < 0.001 && fabs(vfRect.origin.y - 44.0) < 0.001);
    assert(PTDuoRectLooksLikeSubstantialSidebar(vfRect, CGRectMake(0, 0, 1000, 720), NO, 2) == YES);
    // With visible top pill reaching y=56 -> occlusion expands to 56pt
    CGRect occPill = PTDuoTopRightOcclusionRect(CGRectMake(0, 0, 1000, 720), 32.0, 56.0);
    assert(fabs(occPill.size.height - 56.0) < 0.001);
    // Narrow window -> CGRectNull
    assert(CGRectIsNull(PTDuoTopRightOcclusionRect(CGRectMake(0, 0, 500, 720), 32.0, 0.0)));
    // Width sync with occupiedRightBarWidth: 72pt floating rail -> 72pt occlusion; 0pt collapsed -> stays 52pt
    CGRect occ72 = PTDuoTopRightOcclusionRectForOccupiedWidth(CGRectMake(0, 0, 1000, 720), 32.0, 0.0, 72.0);
    assert(fabs(occ72.origin.x - 928.0) < 0.001 && fabs(occ72.size.width - 72.0) < 0.001 && fabs(occ72.size.height - 32.0) < 0.001);
    CGRect occ0 = PTDuoTopRightOcclusionRectForOccupiedWidth(CGRectMake(0, 0, 1000, 720), 32.0, 0.0, 0.0);
    assert(fabs(occ0.origin.x - 948.0) < 0.001 && fabs(occ0.size.width - 52.0) < 0.001 && fabs(occ0.size.height - 32.0) < 0.001);
    CGRect occClamped = PTDuoTopRightOcclusionRectForOccupiedWidth(CGRectMake(0, 0, 1000, 720), 32.0, 0.0, 110.0);
    assert(fabs(occClamped.origin.x - 916.0) < 0.001 && fabs(occClamped.size.width - 84.0) < 0.001);

    // 12. Effective hidesBackButton semantics (leftBarButtonItem replaces back button when !leftItemsSupplementBackButton)
    assert(PTDuoNavItemEffectiveHidesBackButton(YES, NO, NO) == YES);
    assert(PTDuoNavItemEffectiveHidesBackButton(YES, YES, YES) == YES);
    assert(PTDuoNavItemEffectiveHidesBackButton(NO, NO, YES) == YES);  // custom leftBarButtonItem suppresses system back
    assert(PTDuoNavItemEffectiveHidesBackButton(NO, YES, YES) == NO);  // leftItemsSupplementBackButton=YES keeps system back
    assert(PTDuoNavItemEffectiveHidesBackButton(NO, NO, NO) == NO);    // standard push with no left items keeps system back

    // 13. Safe-area drift reconciliation & post-mount notification rules
    // Occupied width change triggers notification
    assert(PTDuoShouldNotifySafeAreaChange(0.0, 52.0, 0.0, 52.0, NO, NO, 0) == YES);
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 0.0, 52.0, 0.0, NO, NO, 0) == YES);
    // Steady occupied width (52 -> 52) with actual window inset drifted to 0 triggers reconciliation up to 3 retries
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 52.0, 0.0, 52.0, NO, NO, 0) == YES);
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 52.0, 0.0, 52.0, NO, NO, 2) == YES);
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 52.0, 0.0, 52.0, NO, NO, 3) == NO);
    // Post-mount host visibility or epoch transition while occupied > 0 triggers notification even at retry cap
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 52.0, 52.0, 52.0, NO, YES, 3) == YES);
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 52.0, 52.0, 52.0, YES, NO, 3) == YES);
    // Steady state with matching actual inset and no mount/epoch edge -> NO churn
    assert(PTDuoShouldNotifySafeAreaChange(52.0, 52.0, 52.0, 52.0, NO, NO, 0) == NO);
    assert(PTDuoShouldNotifySafeAreaChange(0.0, 0.0, 0.0, 0.0, YES, NO, 0) == NO);

    // 14. Settled window-resize viewWillTransitionToSize:withTransitionCoordinator: dispatch rules
    // Same-size-class width changes (840 <-> 1000) outside live drag trigger dispatch once
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeMake(840.0, 720.0), CGSizeMake(1000.0, 720.0), NO, NO) == YES);
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeMake(1000.0, 720.0), CGSizeMake(840.0, 720.0), NO, NO) == YES);
    // Live drag or re-entrant dispatch -> suppressed
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeMake(840.0, 720.0), CGSizeMake(1000.0, 720.0), YES, NO) == NO);
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeMake(840.0, 720.0), CGSizeMake(1000.0, 720.0), NO, YES) == NO);
    // Unchanged / sub-1pt delta -> suppressed (already delivered by UIKit or settled)
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeMake(1000.0, 720.0), CGSizeMake(1000.5, 720.0), NO, NO) == NO);
    // Unseeded baseline (< 100pt) or invalid size -> suppressed
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeZero, CGSizeMake(1000.0, 720.0), NO, NO) == NO);
    assert(PTDuoShouldDispatchViewWillTransitionToSize(CGSizeMake(1000.0, 720.0), CGSizeMake(50.0, 720.0), NO, NO) == NO);
    // Seeding baseline from initial laid-out window bounds enables very first post-launch resize (1000 -> 840)
    CGSize seeded = CGSizeZero;
    assert(PTDuoShouldSeedInitialTransitionBaseline(seeded, CGSizeMake(1000.0, 720.0)) == YES);
    seeded = CGSizeMake(1000.0, 720.0);
    assert(PTDuoShouldSeedInitialTransitionBaseline(seeded, CGSizeMake(840.0, 720.0)) == NO); // already seeded
    assert(PTDuoShouldSeedInitialTransitionBaseline(CGSizeZero, CGSizeMake(50.0, 50.0)) == NO);
    assert(PTDuoShouldDispatchViewWillTransitionToSize(seeded, CGSizeMake(840.0, 720.0), NO, NO) == YES);

    // 15. True Duo landscape scene safe-area normalization (w > h && left <= 0.5 -> top = 0.0)
    UIEdgeInsets nativeCatalystLand = UIEdgeInsetsMake(32.0, 0.0, 0.0, 0.0);
    UIEdgeInsets effDuoLand = PTDuoEffectiveSceneSafeAreaInsets(YES, 60.0, CGSizeMake(1000.0, 720.0), nativeCatalystLand);
    assert(fabs(effDuoLand.top - 0.0) < 0.001 && fabs(effDuoLand.left - 0.0) < 0.001
           && fabs(effDuoLand.bottom - 0.0) < 0.001 && fabs(effDuoLand.right - 60.0) < 0.001);
    // Collapsed empty right strip in landscape still normalizes top = 0.0 while keeping right = 0.0
    UIEdgeInsets effDuoCollapsed = PTDuoEffectiveSceneSafeAreaInsets(YES, 0.0, CGSizeMake(1000.0, 720.0), nativeCatalystLand);
    assert(fabs(effDuoCollapsed.top - 0.0) < 0.001 && fabs(effDuoCollapsed.right - 0.0) < 0.001);
    // Left notch present (left > 0.5) -> top preserved
    UIEdgeInsets effWithLeftNotch = PTDuoEffectiveSceneSafeAreaInsets(YES, 60.0, CGSizeMake(1000.0, 720.0), UIEdgeInsetsMake(32.0, 20.0, 0.0, 0.0));
    assert(fabs(effWithLeftNotch.top - 32.0) < 0.001 && fabs(effWithLeftNotch.right - 60.0) < 0.001);
    // Portrait (w <= h) -> top preserved
    UIEdgeInsets effPortrait = PTDuoEffectiveSceneSafeAreaInsets(YES, 60.0, CGSizeMake(720.0, 1000.0), nativeCatalystLand);
    assert(fabs(effPortrait.top - 32.0) < 0.001 && fabs(effPortrait.right - 60.0) < 0.001);
    // Inactive (Duo OFF / Disabled) -> all native insets untouched
    UIEdgeInsets effInactive = PTDuoEffectiveSceneSafeAreaInsets(NO, 60.0, CGSizeMake(1000.0, 720.0), nativeCatalystLand);
    assert(fabs(effInactive.top - 32.0) < 0.001 && fabs(effInactive.right - 0.0) < 0.001);

    // 16. UIStatusBarManager.isStatusBarHidden generic Duo resolution
    assert(PTDuoResolveStatusBarHidden(NO, YES, NO) == YES);
    assert(PTDuoResolveStatusBarHidden(NO, NO, YES) == NO);
    assert(PTDuoResolveStatusBarHidden(YES, YES, NO) == NO);
    assert(PTDuoResolveStatusBarHidden(YES, YES, YES) == YES);

    // 17. forceReprobe vs recent UIViewLayoutRegion(.bar) query race guard
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, YES, YES, 0.01) == YES);
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, YES, YES, 0.24) == YES);
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, YES, YES, 0.26) == NO);
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, NO, YES, 0.01) == NO);  // activeLeafVC changed
    assert(PTDuoShouldPreserveRecentRightBarQuery(NO, YES, YES, 0.01) == NO);  // cold activation
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, YES, NO, 0.01) == NO);  // not queried
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, YES, YES, -0.01) == NO);
    assert(PTDuoShouldPreserveRecentRightBarQuery(YES, YES, YES, NAN) == NO);

    // 18. Traffic-light top clearance (VC additionalSafeAreaInsets.top + .bar LayoutRegion top inset)
    assert(fabs(PTDuoTrafficLightTopClearance(YES, YES, CGSizeMake(1000.0, 720.0), nativeCatalystLand) - 32.0) < 0.001);
    assert(fabs(PTDuoTrafficLightTopClearance(NO, YES, CGSizeMake(1000.0, 720.0), nativeCatalystLand) - 0.0) < 0.001);   // Duo inactive
    assert(fabs(PTDuoTrafficLightTopClearance(YES, NO, CGSizeMake(1000.0, 720.0), nativeCatalystLand) - 0.0) < 0.001);   // Titlebar shown
    assert(fabs(PTDuoTrafficLightTopClearance(YES, YES, CGSizeMake(720.0, 1000.0), nativeCatalystLand) - 0.0) < 0.001);  // Portrait
    assert(fabs(PTDuoTrafficLightTopClearance(YES, YES, CGSizeMake(1000.0, 720.0), UIEdgeInsetsMake(32.0, 20.0, 0.0, 0.0)) - 0.0) < 0.001); // Left notch present
    assert(fabs(PTDuoTrafficLightTopClearance(YES, YES, CGSizeMake(1000.0, 720.0), UIEdgeInsetsZero) - 0.0) < 0.001);
    // .bar(onEdge: .right) adjustment preserves/restores minTopClearance without double-adding
    BOOL isRightBarClr = NO;
    CGFloat barExtentClr = 0.0;
    UIEdgeInsets adjClr = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(
        UIEdgeInsetsMake(0.0, 892.0, 0.0, 60.0), 1000.0, 720.0, 60.0, 32.0, &isRightBarClr, &barExtentClr);
    assert(isRightBarClr == YES && fabs(barExtentClr - 48.0) < 0.001);
    assert(fabs(adjClr.top - 32.0) < 0.001 && fabs(adjClr.left - 952.0) < 0.001 && fabs(adjClr.right - 0.0) < 0.001);
    // Already 32pt native top -> no double addition
    UIEdgeInsets adjAlready32 = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(
        UIEdgeInsetsMake(32.0, 892.0, 0.0, 60.0), 1000.0, 720.0, 60.0, 32.0, &isRightBarClr, &barExtentClr);
    assert(fabs(adjAlready32.top - 32.0) < 0.001);
    // SynthRight == 0 (e.g. collapsed/window strip already stripped) still applies top clearance on right bar
    UIEdgeInsets adjNoSynth = PTDuoAdjustRightBarEdgeInsetsWithTopClearance(
        UIEdgeInsetsMake(0.0, 952.0, 0.0, 0.0), 1000.0, 720.0, 0.0, 32.0, &isRightBarClr, &barExtentClr);
    assert(isRightBarClr == YES && fabs(adjNoSynth.top - 32.0) < 0.001 && fabs(adjNoSynth.left - 952.0) < 0.001);

    // 19. Settled-resize viewSafeAreaInsetsDidChange delivery gate
    assert(PTDuoShouldNotifySafeAreaAfterSettledResize(CGSizeMake(1000.0, 720.0), CGSizeMake(840.0, 720.0), NO, NO) == YES);
    assert(PTDuoShouldNotifySafeAreaAfterSettledResize(CGSizeMake(840.0, 720.0), CGSizeMake(1000.0, 720.0), NO, NO) == YES);
    assert(PTDuoShouldNotifySafeAreaAfterSettledResize(CGSizeMake(840.0, 720.0), CGSizeMake(840.5, 720.0), NO, NO) == NO);
    assert(PTDuoShouldNotifySafeAreaAfterSettledResize(CGSizeMake(1000.0, 720.0), CGSizeMake(840.0, 720.0), YES, NO) == NO);
    assert(PTDuoShouldNotifySafeAreaAfterSettledResize(CGSizeMake(1000.0, 720.0), CGSizeMake(840.0, 720.0), NO, YES) == NO);
    assert(PTDuoShouldNotifySafeAreaAfterSettledResize(CGSizeZero, CGSizeMake(840.0, 720.0), NO, NO) == NO);

    // 20. Empty/hidden titleView guard (PTDuoViewIsVisualTitleView)
    assert(PTDuoViewIsVisualTitleView(NO, NO, 1.0, CGRectMake(0.0, 0.0, 120.0, 32.0), 1) == NO);
    assert(PTDuoViewIsVisualTitleView(YES, YES, 1.0, CGRectMake(0.0, 0.0, 120.0, 32.0), 1) == NO);
    assert(PTDuoViewIsVisualTitleView(YES, NO, 0.0, CGRectMake(0.0, 0.0, 120.0, 32.0), 1) == NO);
    assert(PTDuoViewIsVisualTitleView(YES, NO, 1.0, CGRectZero, 0) == NO); // QQMusic 0x0 foldStyleEmptyTitleView
    assert(PTDuoViewIsVisualTitleView(YES, NO, 1.0, CGRectMake(0.0, 0.0, 120.0, 32.0), 0) == YES);
    assert(PTDuoViewIsVisualTitleView(YES, NO, 1.0, CGRectZero, 2) == YES);

    // 21. CustomView / leading UIBarButtonItem vertical relocation gate (PTDuoShouldRelocateBarItem)
    // AxisBehavior: 0=Automatic, 1=HorizontalOnly, 2=VerticalPreferred
    assert(PTDuoShouldRelocateBarItem(YES, 2, YES, NO, CGSizeZero, NO, NO, NO) == NO); // appWantsHidden
    assert(PTDuoShouldRelocateBarItem(NO, 1, YES, NO, CGSizeZero, NO, NO, NO) == NO);  // HorizontalOnly never relocates
    assert(PTDuoShouldRelocateBarItem(NO, 0, NO, YES, CGSizeMake(30.0, 30.0), YES, NO, NO) == YES); // Actionable customView trailing item
    assert(PTDuoShouldRelocateBarItem(NO, 2, NO, YES, CGSizeMake(44.0, 44.0), YES, NO, NO) == YES); // VerticalPreferred customView (JD)
    assert(PTDuoShouldRelocateBarItem(NO, 2, NO, YES, CGSizeMake(140.0, 32.0), YES, NO, NO) == NO); // Wide label/search customView stays horizontal
    assert(PTDuoShouldRelocateBarItem(NO, 2, NO, YES, CGSizeMake(32.0, 32.0), NO, NO, NO) == NO);   // Non-actionable customView stays horizontal
    assert(PTDuoShouldRelocateBarItem(NO, 0, YES, NO, CGSizeZero, NO, YES, NO) == YES); // QQMusic leading [v] when no horizontal-only chrome
    assert(PTDuoShouldRelocateBarItem(NO, 0, YES, NO, CGSizeZero, NO, YES, YES) == NO); // Automatic leading stays when search/title bar is horizontal
    assert(PTDuoShouldRelocateBarItem(NO, 2, YES, NO, CGSizeZero, NO, YES, YES) == YES); // Explicit VerticalPreferred leading relocates even with horizontal chrome

    // 22. Blank tab slot center-X overlay matcher (PTDuoTabSlotOverlayMatchesCenterX)
    // 5 slots across 400pt tabBar -> slotWidth=80, slot 2 center=200
    assert(PTDuoTabSlotOverlayMatchesCenterX(200.0, 2, 5, 400.0) == YES);
    assert(PTDuoTabSlotOverlayMatchesCenterX(185.0, 2, 5, 400.0) == YES);
    assert(PTDuoTabSlotOverlayMatchesCenterX(40.0, 2, 5, 400.0) == NO);
    assert(PTDuoTabSlotOverlayMatchesCenterX(200.0, 5, 5, 400.0) == NO);
    assert(PTDuoTabSlotOverlayMatchesCenterX(200.0, 0, 1, 400.0) == NO);

    // 23. Promoted circular accent prominent tab overlay rule (PTDuoShouldPromoteTabOverlayToProminent)
    assert(PTDuoShouldPromoteTabOverlayToProminent(NO, YES, YES, NO, NO) == YES); // CamScanner opaque green circular badge
    assert(PTDuoShouldPromoteTabOverlayToProminent(NO, NO, NO, YES, NO) == YES);  // Solid circular accent background
    assert(PTDuoShouldPromoteTabOverlayToProminent(NO, NO, NO, NO, YES) == YES);  // Protrudes above tabBar
    assert(PTDuoShouldPromoteTabOverlayToProminent(NO, NO, NO, NO, NO) == NO);   // CoolApk monochrome inline '+' vector stays in dockPill
    assert(PTDuoShouldPromoteTabOverlayToProminent(NO, YES, NO, NO, NO) == NO);  // Monochrome opaque badge without accent stays inline
    assert(PTDuoShouldPromoteTabOverlayToProminent(YES, YES, YES, YES, YES) == NO); // Never override existing prominentTab

    // 24. Unknown actionable blank-slot fallback guard (PTDuoCanSafelyRelocateTabDock)
    assert(PTDuoCanSafelyRelocateTabDock(NO, 4) == YES);
    assert(PTDuoCanSafelyRelocateTabDock(YES, 4) == NO);  // Actionable blank slot without visual/title must keep horizontal dock
    assert(PTDuoCanSafelyRelocateTabDock(NO, 1) == NO);

    // 25. Overflow completeness split (PTDuoComputeOverflowSplit)
    NSUInteger directCount = 0;
    BOOL needsOverflow = NO;
    PTDuoComputeOverflowSplit(4, 6, &directCount, &needsOverflow);
    assert(directCount == 4 && needsOverflow == NO);
    PTDuoComputeOverflowSplit(6, 6, &directCount, &needsOverflow);
    assert(directCount == 6 && needsOverflow == NO);
    PTDuoComputeOverflowSplit(7, 6, &directCount, &needsOverflow);
    assert(directCount == 5 && needsOverflow == YES); // 5 direct + 1 '...' menu holding 2 items
    PTDuoComputeOverflowSplit(5, 4, &directCount, &needsOverflow);
    assert(directCount == 3 && needsOverflow == YES);

    // 26. Pure-action overlay vs real-tab slot semantics & blank slot guard
    assert(PTDuoResolveTabOverlayActionKind(NO, YES, YES) == PTDuoTabSlotActionControlOnly);
    assert(PTDuoResolveTabOverlayActionKind(YES, YES, YES) == PTDuoTabSlotActionSelectTab);
    assert(PTDuoResolveTabOverlayActionKind(NO, NO, NO) == PTDuoTabSlotActionNone);
    assert(PTDuoShouldRelocateTabBarWithSlots(4, 1, 0, NO) == NO);
    assert(PTDuoShouldRelocateTabBarWithSlots(4, 1, 1, NO) == YES);
    assert(PTDuoShouldRelocateTabBarWithSlots(4, 1, 0, YES) == YES);

    // 27. Source bar hidden / alpha / userInteractionEnabled exact restoration
    PTDuoSavedViewState orig = { .hidden = NO, .alpha = 0.85, .userInteractionEnabled = NO };
    PTDuoSavedViewState restored = PTDuoRestoreSavedViewState(orig, YES);
    assert(restored.hidden == NO && fabs(restored.alpha - 0.85) < 0.001 && restored.userInteractionEnabled == NO);
    PTDuoSavedViewState origHidden = { .hidden = YES, .alpha = 0.40, .userInteractionEnabled = YES };
    PTDuoSavedViewState restoredHidden = PTDuoRestoreSavedViewState(origHidden, YES);
    assert(restoredHidden.hidden == YES && fabs(restoredHidden.alpha - 0.40) < 0.001 && restoredHidden.userInteractionEnabled == YES);

    // 28. Detached-view guard & narrow<->wide / cancelled pop refresh semantics
    assert(PTDuoShouldRecordRightBarRegionQuery(NO, NO) == NO);
    assert(PTDuoShouldRecordRightBarRegionQuery(YES, NO) == NO);
    assert(PTDuoShouldRecordRightBarRegionQuery(YES, YES) == YES);
    assert(PTDuoShouldRefreshAfterTransition(YES, NO) == YES);
    assert(PTDuoShouldRefreshAfterTransition(NO, YES) == YES);
    assert(PTDuoShouldRefreshAfterTransition(NO, NO) == NO);

    // 29. Multi-nav outer header preservation, accent glyph contrast fallback & snapshot pixel validation
    assert(PTDuoShouldPreserveOuterHeaderNav(YES, NO) == YES); // Outer visible navBar preserved when inner nav hides navBar
    assert(PTDuoShouldPreserveOuterHeaderNav(YES, YES) == NO); // Inner visible navBar wins when visible
    assert(PTDuoShouldPreserveOuterHeaderNav(NO, NO) == NO);
    // Teal-on-teal (CamScanner camera glyph) triggers contrast fallback to crisp white
    assert(PTDuoShouldUseContrastFallbackForAccent(0.10, 0.70, 0.55, 0.12, 0.72, 0.56) == YES);
    assert(PTDuoShouldUseContrastFallbackForAccent(1.00, 1.00, 1.00, 0.12, 0.72, 0.56) == NO);
    assert(PTDuoShouldPreferWhiteOnAccentBackground(0.12, 0.72, 0.56) == YES);
    assert(PTDuoShouldPreferWhiteOnAccentBackground(0.95, 0.95, 0.90) == NO);
    assert(PTDuoSnapshotHasVisiblePixels(0, 256) == NO);
    assert(PTDuoSnapshotHasVisiblePixels(12, 256) == YES);

    // 30. Composite opaque badge (UIImageRenderingModeAutomatic) & leading icon-only relocation when !showBack
    BOOL opq = NO, sat = NO;
    PTDuoInspectOpaqueBadgeResult(3, 1, &opq, &sat);
    assert(opq == YES && sat == YES); // CamScanner 60x60 composite green+white camera
    PTDuoInspectOpaqueBadgeResult(4, 0, &opq, &sat);
    assert(opq == YES && sat == NO);  // Monochrome opaque badge without accent
    PTDuoInspectOpaqueBadgeResult(2, 2, &opq, &sat);
    assert(opq == NO && sat == NO);
    // Standard icon-only leading item relocates when !showBack even if navBarHorizHeader==YES (WPS [🔍, 📱])
    assert(PTDuoShouldRelocateLeadingBarItemWithRole(NO, 0, YES, YES, NO, CGSizeZero, NO, YES, YES, NO) == YES);
    // Text-only leading item (Weibo '登录') or customView (CoolApk avatar) stays horizontal when navBarHorizHeader==YES
    assert(PTDuoShouldRelocateLeadingBarItemWithRole(NO, 0, YES, NO, NO, CGSizeZero, NO, YES, YES, NO) == NO);
    assert(PTDuoShouldRelocateLeadingBarItemWithRole(NO, 0, NO, NO, YES, CGSizeMake(32.0, 32.0), YES, YES, YES, NO) == NO);
    // When showBack == YES, automatic icon-only leading item defers to horizontal bar if header is horizontal
    assert(PTDuoShouldRelocateLeadingBarItemWithRole(NO, 0, YES, YES, NO, CGSizeZero, NO, YES, YES, YES) == NO);
    // Standard UIBarButtonItem with image ignores accessibility/menu title visually and qualifies as icon-only
    assert(PTDuoIsStandardIconOnlyBarItem(NO, YES) == YES);
    assert(PTDuoIsStandardIconOnlyBarItem(NO, NO) == NO);
    assert(PTDuoIsStandardIconOnlyBarItem(YES, YES) == NO);
    assert(PTDuoShouldSuppressFloatingBarHost(NO, YES) == YES);
    assert(PTDuoShouldSuppressFloatingBarHost(YES, YES) == NO);
    assert(PTDuoShouldSuppressFloatingBarHost(NO, NO) == NO);
    // Composite capsule + foreground geometric stroke extraction math (CoolApk PlusButton)
    CGRect capsule = CGRectMake(8.5, 0.5, 49.0, 35.0);
    assert(PTDuoRectIsEnclosedInnerStroke(CGRectMake(25.5, 16.5, 15.0, 3.0), capsule) == YES);
    assert(PTDuoRectIsEnclosedInnerStroke(CGRectMake(31.5, 10.5, 3.0, 15.0), capsule) == YES);
    assert(PTDuoRectIsEnclosedInnerStroke(capsule, capsule) == NO); // same-size overlay is backdrop, not stroke
    assert(PTDuoRectIsEnclosedInnerStroke(CGRectMake(32.0, 17.0, 1.0, 1.0), capsule) == NO); // sub-1.5pt speck
    assert(PTDuoColorsHaveContrast(1.0, 1.0, 1.0, 1.0, 0.06, 0.62, 0.35, 1.0) == YES); // white '+' on green pill
    assert(PTDuoColorsHaveContrast(0.06, 0.62, 0.35, 1.0, 0.07, 0.61, 0.36, 1.0) == NO); // no contrast
    assert(PTDuoColorsHaveContrast(1.0, 1.0, 1.0, 0.0, 0.06, 0.62, 0.35, 1.0) == NO); // transparent

    // 31. Selected-tab blank placeholder & transparent-alpha placeholder helpers
    assert(PTDuoTabItemSlotNeedsOverlay(YES, YES, YES, NO, YES) == YES);  // Selected tab uses blank selectedImage even if unselected image exists
    assert(PTDuoTabItemSlotNeedsOverlay(YES, YES, NO, YES, YES) == NO);   // Selected tab has real selectedImage
    assert(PTDuoTabItemSlotNeedsOverlay(YES, NO, YES, YES, YES) == YES);  // Selected tab falls back to blank image
    assert(PTDuoTabItemSlotNeedsOverlay(NO, YES, YES, NO, YES) == NO);    // Unselected tab uses real image
    assert(PTDuoTabItemSlotNeedsOverlay(YES, YES, YES, YES, NO) == NO);   // Non-blank title does not need blank-slot overlay
    uint8_t emptyAlpha[16] = {0};
    assert(PTDuoAlphaBufferHasVisiblePixels(emptyAlpha, 16) == NO);
    uint8_t visibleAlpha[16] = {0};
    visibleAlpha[7] = 12;
    assert(PTDuoAlphaBufferHasVisiblePixels(visibleAlpha, 16) == YES);

    printf("ALL_MATH_CHECKS_PASSED\n");
    return 0;
}
'''

    with tempfile.TemporaryDirectory() as tmp:
        src_file = Path(tmp) / "test_duo_math.m"
        bin_file = Path(tmp) / "test_duo_math"
        src_file.write_text(harness, encoding="utf-8")
        cc = subprocess.run(
            [
                "xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                "-framework", "Foundation", "-framework", "CoreGraphics",
                str(src_file), "-o", str(bin_file),
            ],
            capture_output=True, text=True, check=False,
        )
        if cc.returncode != 0:
            return [f"Math harness compile failed:\n{cc.stderr}"]
        run = subprocess.run([str(bin_file)], capture_output=True, text=True, check=False)
        if run.returncode != 0 or "ALL_MATH_CHECKS_PASSED" not in run.stdout:
            return [f"Math harness failed (rc={run.returncode}): {run.stdout} {run.stderr}"]
    return []


def main() -> int:
    pt_root = Path(__file__).resolve().parents[1]
    failures = check_source_contract(pt_root) + run_math_unit_tests(pt_root)
    if failures:
        print(f"Duo Vertical Bar contract test FAILED ({len(failures)} issues):")
        for f in failures:
            print(f"  FAIL: {f}")
        return 1
    print("PASS: Duo Vertical Bar contract and geometry tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
