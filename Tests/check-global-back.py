#!/usr/bin/env python3
"""Contract and pure-C unit tests for Global Window Titlebar Back Button & Global Back Shortcut."""

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

    loader_h = read_text(pt_dir / "PlayLoader.h")
    plugin_swift = read_text(pt_root / "Plugin.swift")
    ak_plugin = read_text(pt_root / "AKPlugin.swift")
    playcover_swift = read_text(pt_dir / "PlayCover.swift")
    duo = read_text(pt_dir / "DuoVerticalBarCompatibility.m")

    failures: list[str] = []

    required = [
        ("PlayLoaderH:refreshHandler", loader_h, "PTDuoSetGlobalBackRefreshHandler"),
        ("PlayLoaderH:queryState", loader_h, "PTDuoQueryGlobalBackStateForWindow"),
        ("PlayLoaderH:performAction", loader_h, "PTDuoPerformGlobalBackActionForWindow"),
        ("PlayLoaderH:textInput", loader_h, "PTDuoWindowHasActiveTextInput"),
        ("PlayLoaderH:queryHome", loader_h, "PTDuoQueryGlobalHomeStateForWindow"),
        ("PlayLoaderH:performHome", loader_h, "PTDuoPerformGlobalHomeActionForWindow"),
        ("Plugin:setupGlobalBack", plugin_swift, "setupGlobalBackIntegration("),
        ("Plugin:setupGlobalHome", plugin_swift, "setupGlobalHomeIntegration("),
        ("Plugin:refreshGlobalBack", plugin_swift, "refreshGlobalBackUI()"),
        ("PlayCover:initGlobalBack", playcover_swift, "initializeGlobalBackIntegration()"),
        ("PlayCover:initGlobalHome", playcover_swift, "setupGlobalHomeIntegration?"),
        ("Duo:alwaysOnObservers", duo, "pt_installGlobalBackNavigationObservers();"),
        ("Duo:bitmaskMath", duo, "PTDuoPackGlobalBackStateBitmask"),
        ("Duo:titlebarVisMath", duo, "PTDuoShouldShowTitlebarBackButton"),
        ("Duo:homeAllowMath", duo, "PTDuoShouldAllowHomeAction"),
        ("Duo:homeTitlebarVisMath", duo, "PTDuoShouldShowTitlebarHomeButton"),
        ("Duo:horizNavVisMath", duo, "PTDuoShouldInspectHorizontalNavItems"),
        ("Duo:hostSidebarBackMath", duo, "PTDuoHostEntryCountsAsSidebarBack"),
        ("Duo:hostSidebarBackFn", duo, "pt_hostHasRelocatedSidebarBackItem"),
        ("Duo:customViewSyntheticTap", duo, "pt_dispatchSyntheticTapOnView"),
        ("Duo:customViewPriorityMath", duo, "PTDuoShouldPrioritizeCustomViewDispatch"),
        ("Duo:primaryTabFinder", duo, "pt_findPrimaryTabBarController"),
        ("AKPlugin:postClickDebounce", ak_plugin, "scheduleDebouncedGlobalBackRefresh"),
        ("AKPlugin:setupGlobalHome", ak_plugin, "@objc func setupGlobalHomeIntegration("),
        ("AKPlugin:houseSymbol", ak_plugin, '"house"'),
        ("Duo:backCueMath", duo, "PTDuoCStrMatchesBackCue"),
        ("Duo:closeCueMath", duo, "PTDuoCStrMatchesCloseCue"),
        ("Duo:kbdShortcutMath", duo, "PTDuoShouldInterceptKeyboardBackShortcut"),
        ("Duo:mouseShortcutMath", duo, "PTDuoShouldInterceptMouseBackShortcut"),
        ("AKPlugin:configPlist", ak_plugin, '"GlobalBackSettings.plist"'),
        ("AKPlugin:distNotif", ak_plugin, '"io.playcover.PlayCover.GlobalBackSettingsChanged"'),
        ("AKPlugin:defaultMouse4", ak_plugin, '"Mouse Button 4"'),
        ("AKPlugin:defaultBtnNum3", ak_plugin, "var shortcutButtonNumber: Int = 3"),
        ("AKPlugin:accessoryVC", ak_plugin, "NSTitlebarAccessoryViewController"),
        ("AKPlugin:chevronBackward", ak_plugin, '"chevron.backward"'),
        ("AKPlugin:backButtonHitGuard", ak_plugin, "isPointInGlobalBackButton("),
        ("AKPlugin:setupGlobalBack", ak_plugin, "@objc func setupGlobalBackIntegration("),
        ("AKPlugin:refreshGlobalBack", ak_plugin, "@objc func refreshGlobalBackUI()"),
    ]
    for name, content, needle in required:
        if needle not in content:
            failures.append(f"{name}: missing '{needle}'")

    # Strict generic rule: zero per-app bundleIdentifier hardcodes anywhere in Global Back / Duo logic
    for name, content in [
        ("Duo:noBundleHardcode", duo),
        ("PlayCoverSwift:noBundleHardcode", playcover_swift),
    ]:
        if re.search(r'"com\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_.-]+"', content):
            failures.append(f"{name}: unexpected bundleIdentifier literal found")

    ak_global_back_slice = ak_plugin[ak_plugin.find("struct AKGlobalBackSettingsData"):]
    if re.search(r'"com\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_.-]+"', ak_global_back_slice):
        failures.append("AKPluginGlobalBack: unexpected bundleIdentifier literal found")

    # Non-Duo reliability contracts:
    # 1. pt_installGlobalBackNavigationObservers() must run before Duo opt-in early return.
    obs_idx = duo.find("pt_installGlobalBackNavigationObservers();")
    opt_in_idx = duo.find("if (!PTShouldEnableDuoVerticalBar())", obs_idx)
    if obs_idx < 0 or opt_in_idx <= obs_idx:
        failures.append("Duo:globalBackObserversMustPrecedeDuoOptInReturn")
    # 2. refreshGlobalBackUI() must use cached globalBackSettings instead of disk I/O per refresh.
    refresh_fn_start = ak_plugin.find("@objc func refreshGlobalBackUI()")
    refresh_fn_end = ak_plugin.find("private extension AKPlugin", refresh_fn_start)
    if refresh_fn_start >= 0 and refresh_fn_end > refresh_fn_start:
        if "AKGlobalBackSettingsData.load()" in ak_plugin[refresh_fn_start:refresh_fn_end]:
            failures.append("AKPlugin:refreshGlobalBackUIMustUseCachedSettings")
    else:
        failures.append("AKPlugin:refreshGlobalBackUISliceMissing")

    # Config schema parity between PlayCover UI store and AKPlugin reader
    for key in [
        "titlebarBackEnabled",
        "onlyWhenNoSidebarBackButton",
        "includeTopCloseButtons",
        "shortcutEnabled",
        "shortcutKind",
        "shortcutKeyCode",
        "shortcutButtonNumber",
        "shortcutModifiersRaw",
        "shortcutDisplayName",
        "titlebarHomeEnabled",
        "homeShortcutEnabled",
        "homeShortcutKind",
        "homeShortcutKeyCode",
        "homeShortcutButtonNumber",
        "homeShortcutModifiersRaw",
        "homeShortcutDisplayName",
    ]:
        if key not in ak_plugin:
            failures.append(f"ConfigSchema:{key} missing from AKPlugin")

    return failures


def extract_global_back_math_block(duo_text: str) -> str:
    start_marker = "// MARK: - PTDuoGlobalBackMath"
    end_marker = "// MARK: - Associated Object Keys & State Types"
    s = duo_text.find(start_marker)
    e = duo_text.find(end_marker)
    if s < 0 or e <= s:
        raise RuntimeError("Could not locate PTDuoGlobalBackMath block in DuoVerticalBarCompatibility.m")
    return duo_text[s:e]


def run_pure_c_unit_tests(duo_path: Path) -> list[str]:
    duo_text = read_text(duo_path)
    math_block = extract_global_back_math_block(duo_text)

    c_test = f"""
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef double CGFloat;
typedef bool BOOL;
#define YES true
#define NO false

{math_block}

int main(void) {{
    // 1. State bitmask packing
    assert(PTDuoPackGlobalBackStateBitmask(NO, NO, NO) == 0);
    assert(PTDuoPackGlobalBackStateBitmask(YES, NO, NO) == 1);
    assert(PTDuoPackGlobalBackStateBitmask(YES, YES, NO) == 3);
    assert(PTDuoPackGlobalBackStateBitmask(YES, NO, YES) == 5);
    assert(PTDuoPackGlobalBackStateBitmask(YES, YES, YES) == 7);

    // 2. Titlebar '<' visibility policy
    assert(PTDuoShouldShowTitlebarBackButton(NO, YES, YES, NO) == NO);
    assert(PTDuoShouldShowTitlebarBackButton(YES, YES, NO, NO) == NO);
    assert(PTDuoShouldShowTitlebarBackButton(YES, YES, YES, YES) == NO);
    assert(PTDuoShouldShowTitlebarBackButton(YES, NO, YES, YES) == YES);
    assert(PTDuoShouldShowTitlebarBackButton(YES, YES, YES, NO) == YES);

    // 2b. Horizontal navigationItem inspection guard:
    // Blocks hidden-navBar root non-modal VCs (CamScanner Home stackCount==1),
    // while allowing pushed (stackCount>1, e.g. Bilibili GameCenter) and modal VCs.
    assert(PTDuoShouldInspectHorizontalNavItems(YES, NO, YES, 1, NO) == NO);
    assert(PTDuoShouldInspectHorizontalNavItems(YES, NO, YES, 2, NO) == YES);
    assert(PTDuoShouldInspectHorizontalNavItems(YES, NO, YES, 1, YES) == YES);
    assert(PTDuoShouldInspectHorizontalNavItems(NO, YES, YES, 2, YES) == NO);
    assert(PTDuoShouldInspectHorizontalNavItems(YES, YES, NO, 2, YES) == NO);
    assert(PTDuoShouldInspectHorizontalNavItems(YES, YES, YES, 1, NO) == YES);

    // 2c. Relocated Duo sidebar Back/Close entry guard (CoolApk Post Detail vs XHS comments sheet)
    assert(PTDuoHostEntryCountsAsSidebarBack(NO, YES, YES, YES, YES, NO, NO) == YES);
    assert(PTDuoHostEntryCountsAsSidebarBack(NO, YES, YES, YES, NO, YES, YES) == YES);
    assert(PTDuoHostEntryCountsAsSidebarBack(NO, YES, YES, YES, NO, NO, YES) == NO);
    // Overflow menu / toolbar / disabled / hidden items do not count as sidebar back
    assert(PTDuoHostEntryCountsAsSidebarBack(YES, YES, YES, YES, YES, YES, YES) == NO);
    assert(PTDuoHostEntryCountsAsSidebarBack(NO, YES, NO, YES, YES, YES, YES) == NO);
    assert(PTDuoHostEntryCountsAsSidebarBack(NO, YES, YES, NO, YES, YES, YES) == NO);
    assert(PTDuoHostEntryCountsAsSidebarBack(NO, NO, YES, YES, YES, YES, YES) == NO);
    assert(PTDuoShouldPrioritizeCustomViewDispatch(YES) == YES);
    assert(PTDuoShouldPrioritizeCustomViewDispatch(NO) == NO);

    // 2d. Global Home ("Back to First Tab / Root") availability & titlebar visibility math
    // TabBarController with >= 2 tabs: hidden only at Tab 0 Home root (no modal, stack<=1)
    assert(PTDuoShouldAllowHomeAction(YES, 4, YES, NO, 1) == NO);
    assert(PTDuoShouldAllowHomeAction(YES, 4, NO, NO, 1) == YES);   // non-zero tab -> Home available
    assert(PTDuoShouldAllowHomeAction(YES, 4, YES, NO, 2) == YES);   // pushed inside Tab 0 -> Home available
    assert(PTDuoShouldAllowHomeAction(YES, 4, YES, YES, 1) == YES);  // modal over Tab 0 -> Home available
    // Single-stack nav app (no multi-tab UITabBarController): available when modal or stack > 1
    assert(PTDuoShouldAllowHomeAction(NO, 0, YES, NO, 1) == NO);
    assert(PTDuoShouldAllowHomeAction(NO, 0, YES, NO, 2) == YES);
    assert(PTDuoShouldAllowHomeAction(NO, 0, YES, YES, 1) == YES);
    assert(PTDuoShouldAllowHomeAction(YES, 1, YES, NO, 1) == NO);
    assert(PTDuoShouldShowTitlebarHomeButton(NO, YES) == NO);
    assert(PTDuoShouldShowTitlebarHomeButton(YES, NO) == NO);
    assert(PTDuoShouldShowTitlebarHomeButton(YES, YES) == YES);

    // 3. Back cue matching without false positives
    assert(PTDuoCStrMatchesBackCue("chevron.backward") == YES);
    assert(PTDuoCStrMatchesBackCue("chevron.left") == YES);
    assert(PTDuoCStrMatchesBackCue("arrow.left") == YES);
    assert(PTDuoCStrMatchesBackCue("arrow.backward") == YES);
    assert(PTDuoCStrMatchesBackCue("back") == YES);
    assert(PTDuoCStrMatchesBackCue("goBack:") == YES);
    assert(PTDuoCStrMatchesBackCue("nav_back_btn") == YES);
    assert(PTDuoCStrMatchesBackCue("onBackClicked:") == YES);
    assert(PTDuoCStrMatchesBackCue("return") == YES);
    assert(PTDuoCStrMatchesBackCue("返回") == YES);

    assert(PTDuoCStrMatchesBackCue("background") == NO);
    assert(PTDuoCStrMatchesBackCue("setBackgroundColor:") == NO);
    assert(PTDuoCStrMatchesBackCue("playback") == NO);
    assert(PTDuoCStrMatchesBackCue("feedback") == NO);
    assert(PTDuoCStrMatchesBackCue("callback") == NO);
    assert(PTDuoCStrMatchesBackCue("search") == NO);
    assert(PTDuoCStrMatchesBackCue("") == NO);
    assert(PTDuoCStrMatchesBackCue(NULL) == NO);

    // 4. Close/collapse cue matching without false positives
    assert(PTDuoCStrMatchesCloseCue("xmark") == YES);
    assert(PTDuoCStrMatchesCloseCue("chevron.down") == YES);
    assert(PTDuoCStrMatchesCloseCue("chevron.compact.down") == YES);
    assert(PTDuoCStrMatchesCloseCue("close") == YES);
    assert(PTDuoCStrMatchesCloseCue("onCloseBtn:") == YES);
    assert(PTDuoCStrMatchesCloseCue("dismissModal:") == YES);
    assert(PTDuoCStrMatchesCloseCue("Cancel") == YES);
    assert(PTDuoCStrMatchesCloseCue("关闭") == YES);
    assert(PTDuoCStrMatchesCloseCue("收起") == YES);
    assert(PTDuoCStrMatchesCloseCue("完成") == YES);

    assert(PTDuoCStrMatchesCloseCue("disclosure") == NO);
    assert(PTDuoCStrMatchesCloseCue("enclose") == NO);
    assert(PTDuoCStrMatchesCloseCue("cancelled_count") == NO);
    assert(PTDuoCStrMatchesCloseCue("") == NO);
    assert(PTDuoCStrMatchesCloseCue(NULL) == NO);

    // 5. Keyboard shortcut safety (text input protection + repeat + hasBack)
    const NSUInteger kCmdFlag = (1UL << 20);
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, NO, kCmdFlag, kCmdFlag, 33, 33, NO, YES) == YES);
    assert(PTDuoShouldInterceptKeyboardBackShortcut(NO, NO, kCmdFlag, kCmdFlag, 33, 33, NO, YES) == NO);
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, YES, kCmdFlag, kCmdFlag, 33, 33, NO, YES) == NO);
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, NO, kCmdFlag, kCmdFlag, 33, 33, NO, NO) == NO);
    // Unmodified Backspace (51) / '[' (33) during text input passes through
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, NO, 0, 0, 51, 51, YES, YES) == NO);
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, NO, 0, 0, 33, 33, YES, YES) == NO);
    // Esc (53) and modified shortcut (Cmd+[) remain active during text input
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, NO, 0, 0, 53, 53, YES, YES) == YES);
    assert(PTDuoShouldInterceptKeyboardBackShortcut(YES, NO, kCmdFlag, kCmdFlag, 33, 33, YES, YES) == YES);

    // 6. Mouse shortcut matching (side button 4 = 3 default, modifiers, titlebar safety)
    assert(PTDuoShouldInterceptMouseBackShortcut(YES, 3, 3, 0, 0, NO, NO, YES) == YES);
    assert(PTDuoShouldInterceptMouseBackShortcut(YES, 3, 3, 0, 0, NO, NO, NO) == NO);
    assert(PTDuoShouldInterceptMouseBackShortcut(YES, 3, 3, kCmdFlag, 0, NO, NO, YES) == NO);
    assert(PTDuoShouldInterceptMouseBackShortcut(YES, 3, 3, 0, 0, NO, YES, YES) == NO);
    // Bare left-click (button 0) in titlebar drag zone must not hijack window controls
    assert(PTDuoShouldInterceptMouseBackShortcut(YES, 0, 0, 0, 0, YES, NO, YES) == NO);
    assert(PTDuoShouldInterceptMouseBackShortcut(YES, 0, 0, 0, 0, NO, NO, YES) == YES);

    printf("ALL GLOBAL BACK C TESTS PASSED\\n");
    return 0;
}}
"""

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "test_global_back.c"
        exe = Path(tmp) / "test_global_back"
        src.write_text(c_test, encoding="utf-8")
        comp = subprocess.run(
            ["xcrun", "clang", "-Wall", "-Wextra", "-Werror", str(src), "-lm", "-o", str(exe)],
            capture_output=True, text=True, check=False,
        )
        if comp.returncode != 0:
            return [f"Clang compile failed: {comp.stderr.strip()}"]
        run = subprocess.run([str(exe)], capture_output=True, text=True, check=False)
        if run.returncode != 0 or "ALL GLOBAL BACK C TESTS PASSED" not in run.stdout:
            return [f"C test failed (rc={run.returncode}): {run.stdout} {run.stderr}"]
    return []


def main() -> int:
    pt_root = Path(__file__).resolve().parents[1]
    failures = check_source_contract(pt_root)
    failures.extend(run_pure_c_unit_tests(pt_root / "PlayTools" / "DuoVerticalBarCompatibility.m"))
    if failures:
        print("Global Back Checks: FAILED")
        for f in failures:
            print(f"  FAIL {f}")
        return 1
    print("Global Back Checks: ALL PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
