//
//  PlayInformation.swift
//  PlayTools
//

import Foundation
import ObjectiveC

class PlayInfo: NSObject {
    private static var powerStateHooksInstalled = false

    static var isLauncherInstalled: Bool {
        return AKInterface.shared!
            .urlForApplicationWithBundleIdentifier("io.playcover.PlayCover") != nil
    }

    @objc static var isUnrealEngine: Bool {
        let appFolder = Bundle.main.bundleURL
        let ueFiles: [URL] = [
            appFolder.appendingPathComponent("ue4commandline.txt"),
            appFolder.appendingPathComponent("uecommandline.txt")
        ]

        for ueFile in ueFiles where FileManager.default.fileExists(atPath: ueFile.path) {
            return true
        }
        return false
    }

    @objc static func installPowerStateHooksIfNeeded() {
        let policy = PlaySettings.shared.powerStatePolicy
        guard !powerStateHooksInstalled, policy == 1 || policy == 2 else {
            return
        }
        powerStateHooksInstalled = true
        let baseCls: AnyClass = ProcessInfo.self
        let runtimeCls: AnyClass = type(of: ProcessInfo.processInfo)
        let targetClasses: [AnyClass] = (runtimeCls === baseCls) ? [baseCls] : [baseCls, runtimeCls]

        if policy == 1 {
            replaceInstanceMethod(
                on: targetClasses,
                selector: #selector(getter: ProcessInfo.thermalState),
                with: #selector(ProcessInfo.pt_spoofedThermalState),
                sourceClass: baseCls
            )
            replaceInstanceMethod(
                on: targetClasses,
                selector: #selector(getter: ProcessInfo.isLowPowerModeEnabled),
                with: #selector(ProcessInfo.pt_spoofedIsLowPowerModeEnabledFalse),
                sourceClass: baseCls
            )
        } else if policy == 2 {
            replaceInstanceMethod(
                on: targetClasses,
                selector: #selector(getter: ProcessInfo.isLowPowerModeEnabled),
                with: #selector(ProcessInfo.pt_spoofedIsLowPowerModeEnabledTrue),
                sourceClass: baseCls
            )
        }
    }

    private static func replaceInstanceMethod(
        on targetClasses: [AnyClass],
        selector: Selector,
        with replacementSelector: Selector,
        sourceClass: AnyClass
    ) {
        guard let hookMethod = class_getInstanceMethod(sourceClass, replacementSelector) else {
            return
        }
        let hookIMP = method_getImplementation(hookMethod)
        let hookTypes = method_getTypeEncoding(hookMethod)
        for cls in targetClasses {
            let existingTypes = class_getInstanceMethod(cls, selector).flatMap { method_getTypeEncoding($0) }
            class_replaceMethod(cls, selector, hookIMP, existingTypes ?? hookTypes)
        }
    }
}

extension ProcessInfo {
    @objc open var isMacCatalystApp: Bool {
        return false
    }
    @objc open var isiOSAppOnMac: Bool {
        return true
    }
    @objc fileprivate func pt_spoofedThermalState() -> ProcessInfo.ThermalState {
        return .nominal
    }
    @objc fileprivate func pt_spoofedIsLowPowerModeEnabledFalse() -> Bool {
        return false
    }
    @objc fileprivate func pt_spoofedIsLowPowerModeEnabledTrue() -> Bool {
        return true
    }
}
