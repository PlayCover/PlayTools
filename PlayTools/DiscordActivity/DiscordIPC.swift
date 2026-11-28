//
//  DiscordIPC.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/07/15.
//

import Darwin
import Foundation
import SwordRPC
import UIKit

class DiscordIPC {
    public static let shared = DiscordIPC()
    private var activeRPC: SwordRPC?
    private var terminationObserver: NSObjectProtocol?

    func initialize() {
        let custom = PlaySettings.shared.discordActivity
        let rawAppID = custom.applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard custom.enable else {
            return
        }
        let appID = rawAppID.isEmpty ? "996108521680678993" : rawAppID
        // Only spin up SwordRPC / iTunes artwork lookup when a Discord IPC socket
        // actually exists; otherwise SwordRPC leaks 10 SwiftNIO EventLoopGroup threads.
        guard Self.hasReachableDiscordIPCSocket() else {
            return
        }

        let ipc = SwordRPC(appId: appID)
        activeRPC = ipc

        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.activeRPC?.disconnect()
                self?.activeRPC = nil
            }
        }

        Task(priority: .background) { [weak self] in
            guard let self = self else { return }
            let activity = await self.createActivity(from: custom)
            ipc.connect()
            ipc.setPresence(activity)
        }
    }

    private static func hasReachableDiscordIPCSocket() -> Bool {
        var candidateDirs: [String] = []
        let tempDir = FileManager.default.temporaryDirectory.path
        candidateDirs.append(tempDir)
        let nsTemp = (NSTemporaryDirectory() as NSString).standardizingPath
        if !candidateDirs.contains(nsTemp) {
            candidateDirs.append(nsTemp)
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
           !xdg.isEmpty,
           !candidateDirs.contains(xdg) {
            candidateDirs.append(xdg)
        }
        if !candidateDirs.contains("/tmp") {
            candidateDirs.append("/tmp")
        }

        var foundAnySocket = false
        var foundInSwordRPCDir = false
        for dir in candidateDirs {
            let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            for ipcPort in 0..<10 {
                let path = "\(trimmed)/discord-ipc-\(ipcPort)"
                if access(path, F_OK) == 0 {
                    foundAnySocket = true
                    if trimmed == tempDir || trimmed == nsTemp {
                        foundInSwordRPCDir = true
                    }
                    break
                }
            }
        }
        // SwordRPC.connect() only opens sockets in FileManager.default.temporaryDirectory,
        // so require a socket there to prevent 10 failed MultiThreadedEventLoopGroup leaks.
        return foundAnySocket && foundInSwordRPCDir
    }

    func createActivity(from custom: DiscordActivity) async -> RichPresence {
        var activity = RichPresence()

        if custom.details.isEmpty {
            let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
            let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? name
            activity.details = "Playing \(displayName)"
        } else {
            if custom.details.count == 1 { custom.details += " " }
            activity.details = custom.details
        }
        activity.detailsUrl = "https://github.com/PlayCover/PlayCover/releases"

        activity.statusDisplayType = .details

        let poweredStr = "Powered by PlayCover"
        if custom.state.isEmpty {
            activity.state = poweredStr
        } else {
            if custom.state.count == 1 { custom.state += " " }
            activity.state = custom.state
            activity.assets.smallText = poweredStr
            activity.assets.largeText = poweredStr
        }
        activity.stateUrl = "https://github.com/PlayCover/PlayCover/releases"

        let logo = "https://raw.githubusercontent.com/PlayCover/PlaySite/master/src/assets/square-logo.png"
        if custom.image.isEmpty {
            let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
            if let appImage = await loadImage(bundleID: bundleID) {
                activity.assets.largeImage = appImage
                activity.assets.largeText = nil
                activity.assets.smallImage = logo
            } else {
                activity.assets.largeImage = logo
            }
        } else {
            activity.assets.largeImage = custom.image
            activity.assets.largeText = nil
            activity.assets.smallImage = logo
        }

        activity.timestamps.start = Date()

        return activity
    }

    func loadImage(bundleID: String) async -> String? {
        let lookup = "http://itunes.apple.com/lookup?bundleId=\(bundleID)"
        guard let url = URL(string: lookup) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let decoder = JSONDecoder()
            let jsonResult: ITunesResponse = try decoder.decode(ITunesResponse.self, from: data)
            if jsonResult.resultCount > 0 {
                return jsonResult.results[0].artworkUrl512
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }
}

struct ITunesResult: Decodable {
    var isGameCenterEnabled: Bool
    var supportedDevices: [String]
    var features: [String]
    var advisories: [String]
    var screenshotUrls: [String]
    var ipadScreenshotUrls: [String]
    var appletvScreenshotUrls: [String]
    var artworkUrl60: String
    var artworkUrl512: String
    var artworkUrl100: String
    var artistViewUrl: String
    var kind: String
    var isVppDeviceBasedLicensingEnabled: Bool
    var currentVersionReleaseDate: String
    var releaseNotes: String
    var description: String
    var trackId: Int
    var trackName: String
    var bundleId: String
    var sellerName: String
    var genreIds: [String]
    var primaryGenreName: String
    var primaryGenreId: Int
    var currency: String
    var formattedPrice: String
    var contentAdvisoryRating: String
    var averageUserRatingForCurrentVersion: Float
    var userRatingCountForCurrentVersion: Int
    var trackViewUrl: String
    var trackContentRating: String
    var averageUserRating: Float
    var minimumOsVersion: String
    var trackCensoredName: String
    var languageCodesISO2A: [String]
    var fileSizeBytes: String
    var releaseDate: String
    var artistId: Int
    var artistName: String
    var genres: [String]
    var price: Float
    var version: String
    var wrapperType: String
    var userRatingCount: Int
}

struct ITunesResponse: Decodable {
    var resultCount: Int
    var results: [ITunesResult]
}
