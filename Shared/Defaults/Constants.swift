//
//  Constants.swift
//  Suwatte
//
//  Created by Mantton on 2022-03-07.
//

import Foundation
import UIKit

typealias JSON = [String: Any]

enum STTHost {
    static var root = URL(string: "https://suwatte.mantton.com")!

    static var notFound = root.appendingPathComponent("404")
    static var api = root.appendingPathComponent("api")
    static var tnc = root.appendingPathComponent("tnc")

    static var coverNotFound = notFound.appendingPathComponent("thumb.png")
}

let STTUserDefaults: [String: Any] = [
    STTKeys.PagedDirection: true,
    STTKeys.ForceTransition: true,
    STTKeys.TapSidesToNavigate: true,
    STTKeys.ImageInteractions: true,
    STTKeys.ShowOnlyDownloadedTitles: false,
    STTKeys.LastFetchedUpdates: Date.distantPast,
    STTKeys.TileStyle: TileStyle.SEPARATED.rawValue,
    STTKeys.VerticalNavigator: ReaderView.ReaderNavigation.Modes.lNav.rawValue,
    STTKeys.PagedNavigator: ReaderView.ReaderNavigation.Modes.standard.rawValue,
    STTKeys.GridItemsPerRow_P: Int((2 * UIScreen.main.bounds.width) / 375), // IPhone 13 Mini
    STTKeys.GridItemsPerRow_LS: Int((6 * UIScreen.main.bounds.height) / 812),
    STTKeys.TimeoutDuration: LocalAuthManager.TimeoutDuration.immediately.rawValue,
    STTKeys.LibrarySections: LibraryView.LibrarySectionOrder.allCases.map { $0.rawValue },
    STTKeys.UpdateInterval: STTUpdateInterval.oneHour.rawValue, // 1 Hour,
    STTKeys.HideNSFWRunners: true,
    STTKeys.DefaultUserAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:108.0) Gecko/20100101 Firefox/108.0",
]

let SCHEMA_VERSION = 8
let STT_BRIDGE_VERSION = "1.4.0"

let KEY_WINDOW = UIApplication
    .shared
    .connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap { $0.windows }
    .first { $0.isKeyWindow }

let STT_USER_AGENT = "Suwatte iOS Client V\(Bundle.main.releaseVersionNumberPretty)"
