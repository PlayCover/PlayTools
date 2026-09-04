//
//  UserPluginLoader.swift
//  PlayTools
//
//  Loads user-sideloaded dylibs from Frameworks/UserPlugins/.
//

import Darwin
import Foundation

enum UserPluginLoader {
    private static let userPluginsDirectoryName = "UserPlugins"

    static func initialize() {
        for dylibURL in userDylibURLs() {
            load(at: dylibURL)
        }
    }

    private static func userDylibURLs() -> [URL] {
        guard let frameworksURL = Bundle.main.privateFrameworksURL else { return [] }
        let userPluginsURL = frameworksURL.appendingPathComponent(userPluginsDirectoryName)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: userPluginsURL.path) else {
            return []
        }
        return names
            .map { userPluginsURL.appendingPathComponent($0) }
            .filter { $0.pathExtension == "dylib" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func load(at url: URL) {
        // dlopen the plugin, let them rip.
        guard dlopen(url.path, RTLD_NOW) != nil else {
            let message = dlerror().flatMap { String(cString: $0) } ?? "unknown error"
            print("[PlayTools] Failed to load user plugin \(url.lastPathComponent): \(message)")
            return
        }
        print("[PlayTools] Loaded user plugin \(url.lastPathComponent)")
    }
}
