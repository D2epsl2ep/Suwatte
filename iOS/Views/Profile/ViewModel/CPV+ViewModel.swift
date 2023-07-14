//
//  CPV+ViewModel.swift
//  Suwatte
//
//  Created by Mantton on 2022-03-06.
//

import Foundation
import RealmSwift
import SwiftUI
import UIKit

// Reference: KingBri <https://github.com/bdashore3>
extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double = 1.0) async throws {
        let duration = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: duration)
    }
}

// MARK: - Definition
extension ProfileView {
    final class ViewModel: ObservableObject {
        @Published var entry: DaisukeEngine.Structs.Highlight
        var source: AnyContentSource
        
        @Published var content: DSKCommon.Content = .placeholder
        @Published var loadableContent: Loadable<Bool> = .idle
        var storedContent: StoredContent {
            try! content.toStoredContent(withSource: source.id)
        }
        
        @Published var chapters: Loadable<[StoredChapter]> = .idle
        @Published var working = false
        @Published var presentCollectionsSheet = false
        @Published var presentTrackersSheet = false
        @Published var presentSafariView = false
        @Published var presentBookmarksSheet = false
        @Published var presentManageContentLinks = false {
            didSet {
                if !presentManageContentLinks { // Dismissed check if linked changed, if so refresh
                    Task {
                        let newLinked = DataManager.shared.getLinkedContent(for: contentIdentifier).map(\.id)
                        if newLinked != linkedContentIDs {
                            await MainActor.run {
                                self.loadableContent = .idle
                                self.chapters = .idle
                            }
                        }
                    }
                    
                }
            }
        }
        @Published var presentMigrationView = false
        @Published var syncState = SyncState.idle
        @Published var resolvingLinks = false
        @Published var actionState: ActionState = .init(state: .none)
        @Published var threadSafeChapters: [DSKCommon.Chapter]?
        // Tokens
        var currentMarkerToken: NotificationToken?
        private var linkedContentIDs = [String]()
        
        // Download Tracking Variables
        var downloadTrackingToken: NotificationToken?
        @Published var downloads: [String: ICDMDownloadObject] = [:]
        // Chapter Marking Variables
        var progressToken: NotificationToken?
        @Published var readChapters = Set<Double>()
        
        // Library Tracking Token
        var libraryTrackingToken: NotificationToken?
        var readLaterToken: NotificationToken?
        
        // Library State Values
        @Published var savedForLater: Bool = false
        @Published var inLibrary: Bool = false
        
        
        init(_ entry: DaisukeEngine.Structs.Highlight, _ source: AnyContentSource) {
            self.entry = entry
            self.source = source
        }
        
        @Published var selection: String?
        // De Init
        deinit {
            disconnect()
            removeNotifier()
        }

        
        var contentIdentifier: String {
            sttIdentifier().id
        }
        func sttIdentifier() -> ContentIdentifier {
            .init(contentId: entry.id, sourceId: source.id)
        }
    }
}

// MARK: - Observers
extension ProfileView.ViewModel {
    
    func disconnect() {
        currentMarkerToken?.invalidate()
        progressToken?.invalidate()
        downloadTrackingToken?.invalidate()
        libraryTrackingToken?.invalidate()
        readLaterToken?.invalidate()
    }
    
    func setupObservers() {
        let realm = try! Realm()
        
        // Get Read Chapters
        let _r1 = realm
            .objects(ProgressMarker.self)
            .where { $0.id == contentIdentifier && $0.isDeleted == false }
        
        progressToken = _r1.observe { [weak self] _ in
            defer { self?.setActionState() }
            let target = _r1.first
            guard let target else { return }
            self?.readChapters = Set(target.readChapters)
        }
        
        // Get Library
        let id = sttIdentifier().id
        
        let _r3 = realm
            .objects(LibraryEntry.self)
            .where { $0.id == id && !$0.isDeleted }
        
        libraryTrackingToken = _r3.observe { [weak self] _ in
            self?.inLibrary = !_r3.isEmpty
        }
        
        // Read Later
        let _r4 = realm
            .objects(ReadLater.self)
            .where { $0.id == id }
            .where { $0.isDeleted == false }
        
        readLaterToken = _r4.observe { [weak self] _ in
            self?.savedForLater = !_r4.isEmpty
        }
    }
        
    func observeDownloads() {
        guard let chapters = chapters.value else { return } // Chapters must be loaded
        let realm = try! Realm()

        downloadTrackingToken?.invalidate()
        downloadTrackingToken = nil
        
        let ids = chapters.map { $0.id }
        
        let collection = realm
            .objects(ICDMDownloadObject.self)
            .where { $0.chapter.id.in(ids) }
        
        downloadTrackingToken = collection
            .observe { [weak self] _ in
                self?.downloads = Dictionary(uniqueKeysWithValues: collection.map { ($0._id, $0) })
            }
    }
    
    func removeNotifier() {
        currentMarkerToken?.invalidate()
        currentMarkerToken = nil
        
        progressToken?.invalidate()
        progressToken = nil
        
        downloadTrackingToken?.invalidate()
        downloadTrackingToken = nil
        
        libraryTrackingToken?.invalidate()
        libraryTrackingToken = nil
        
        readLaterToken?.invalidate()
        readLaterToken = nil
    }
}

// MARK: - Content Loading
extension ProfileView.ViewModel {
    func loadContentFromNetwork() async {
        do {
            // Fetch From JS
            let parsed = try await source.getContent(id: entry.id)
            await MainActor.run { [weak self] in
                self?.content = parsed
                self?.loadableContent = .loaded(true)
                self?.working = false
            }
            try Task.checkCancellation()
            try await Task.sleep(seconds: 0.1)
            
            // Load Chapters
            Task.detached { [weak self] in
                await self?.loadChapters(parsed.chapters)
            }
            
            // Save to Realm
            Task.detached { [weak self] in
                if let source = self?.source, let stored = try? parsed.toStoredContent(withSource: source.id) {
                    DataManager.shared.storeContent(stored)
                }
            }
        } catch {
            Task.detached { [weak self] in
                await self?.loadChapters()
            }
            
            Task { @MainActor [weak self] in
                if self?.loadableContent.LOADED ?? false {
                    ToastManager.shared.error("Failed to Update Profile")
                    Logger.shared.error("[ProfileView] \(error.localizedDescription)")
                } else {
                    self?.loadableContent = .failed(error)
                }
                self?.working = false
            }
        }
    }
    
    func loadContentFromDatabase() async {
        await MainActor.run(body: {
            withAnimation {
                self.loadableContent = .loading
            }
        })
        
        let target = DataManager.shared.getStoredContent(source.id, entry.id)
        
        if let target = target {
            do {
                let c = try target.toDSKContent()
                await MainActor.run(body: {
                    content = c
                    loadableContent = .loaded(true)
                })
                
            } catch {}
        }
        
        if StateManager.shared.NetworkStateHigh || target == nil { // Connected To Network OR The Content is not saved thus has to be fetched regardless
            Task {
                await loadContentFromNetwork()
            }
        } else {
            loadChaptersfromDB()
        }
    }
    
  
}
// MARK: - Chapter Loading
extension ProfileView.ViewModel {
    func loadChapters(_ parsedChapters: [DSKCommon.Chapter]? = nil) async {
        await MainActor.run { [weak self] in
            self?.working = true
            self?.threadSafeChapters = parsedChapters
        }
        let sourceId = source.id
        do {
            // Fetch Chapters
            var chapters =  parsedChapters
            if chapters == nil {
                chapters = try await source.getContentChapters(contentId: entry.id)
            }
            guard let chapters else { fatalError("Chapters Should be defined") }
            
            // Prepare Unmanaged Chapters
            let unmanaged = chapters.map { $0.toStoredChapter(withSource: source.id) }.sorted(by: \.index, descending: false)
            
            // Update UI with fetched values
            await MainActor.run { [weak self] in
                withAnimation {
                    self?.threadSafeChapters = chapters
                    self?.chapters = .loaded(unmanaged)
                    self?.working = false
                }
            }
            // Store To Realm
            Task.detached {
                let stored = chapters.map { $0.toStoredChapter(withSource: sourceId) }
                DataManager.shared.storeChapters(stored)
            }
            
            // Post Chapter Load Actions
            Task.detached { [weak self] in
                await self?.didLoadChapters()
            }
            
        } catch {
            Logger.shared.error(error, source.id)
            Task { @MainActor [weak self] in
                self?.loadChaptersfromDB()
                if self?.chapters.LOADED ?? false {
                    ToastManager.shared.error("Failed to Fetch Chapters: \(error.localizedDescription)")
                    return
                } else {
                    self?.chapters = .failed(error)
                }
                self?.working = false
            }
        }
    }
        
    func loadChaptersfromDB() {
        let realm = try! Realm()
        let storedChapters = realm
            .objects(StoredChapter.self)
            .where { $0.contentId == entry.contentId }
            .where { $0.sourceId == source.id }
            .sorted(by: \.index, ascending: true)
            .map { $0.freeze() } as [StoredChapter]
        if storedChapters.isEmpty { return }
        
        Task { @MainActor in
            chapters = .loaded(storedChapters)
            observeDownloads()
        }
                
        Task { @MainActor [weak self] in
            self?.calculateActionState()
        }
    }
    
    
    
    func didLoadChapters() async {
        let id = sttIdentifier()
        
        // Resolve Links, Sync & Update Action State
        Task.detached { [weak self] in
            await self?.resolveLinks()
            await self?.handleSync()
            self?.setActionState()
            DataManager.shared.updateUnreadCount(for: id)
            
            guard let self else { return }
            Task { @MainActor in
                self.observeDownloads()
            }
        }
    
        // Clear Updates
        Task.detached {
            DataManager.shared.clearUpdates(id: id.id)
        }
    }
}

// MARK: - Linking
extension ProfileView.ViewModel {
 
    // Handles the addition on linked chapters
    func resolveLinks() async {
        await MainActor.run {
            working = true
        }
        defer {
            Task { @MainActor in
                working = false
            }
        }
        guard let threadSafeChapters else { return }
        
        // Contents that this title is linked to
        let entries = DataManager
            .shared
            .getLinkedContent(for: contentIdentifier)
            .map { $0.freeze() }
        
        self.linkedContentIDs = entries
            .map(\.id)
                
        // Ensure there are linked titles
        guard !entries.isEmpty, !Task.isCancelled else { return }
        
        // Get The current highest chapter on the viewing source
        let currentMaxChapter = threadSafeChapters.map(\.number).max() ?? 0.0
        
        // Get Distinct Chapters which are higher than our currnent max available
        let chaptersToBeAdded = await withTaskGroup(of: [(String, DSKCommon.Chapter)].self, body: { group in
            // Build
            for entry in entries {
                guard let source = DSK.shared.getSource(id: entry.sourceId) else { continue }
                
                // Get Chapters from source that are higher than our current max available chapter
                 group.addTask {
                    do {
                        let chapters = try await source.getContentChapters(contentId: entry.contentId)
                        // Save to db
                        Task {
                            let stored = chapters.map { $0.toStoredChapter(withSource: source.id) }
                            DataManager.shared.storeChapters(stored)
                        }
                        return chapters
                            .filter { $0.number > currentMaxChapter }
                            .map { (source.id, $0) }
                        
                    } catch {
                        Logger.shared.error(error, source.id)
                    }
                    return []
                }
            }
            
            // Resolve
            var out: [(String, DSKCommon.Chapter)] = []
            
            for await result in group {
                guard !result.isEmpty else { continue } // empty guard
                out.append(contentsOf: result)
               
            }
            
            return out
                .distinct(by: \.1.number)
                .sorted(by: \.1.number, descending: true)
        })
        
        
        // Get the highest index point, remember the higher the index, the more recent the chapter
        
        // Prepare Unmanaged Chapters
        let base = (self.chapters.value ?? []).sorted(by: \.index, descending: false)
        let newChapters = chaptersToBeAdded.map { $0.1.toStoredChapter(withSource: $0.0) }
        // Correct Indexes
        let unmanaged = (newChapters + base)
            .enumerated()
            .map { (idx, c) in
            c.index = idx
            return c
        }
        let prepped = threadSafeChapters + chaptersToBeAdded.map(\.1)
        // Update UI with fetched values
        await MainActor.run { [weak self] in
            withAnimation {
                self?.threadSafeChapters = prepped
                self?.chapters = .loaded(unmanaged)
            }
        }
    }
}

// MARK: - Sync
extension ProfileView.ViewModel {
    enum SyncState: Hashable {
        case idle, syncing, done
    }
    
    func handleSync() async {
        await MainActor.run {
            self.syncState = .syncing
        }
        await syncWithAllParties()
        await MainActor.run {
            self.syncState = .done
        }
    }
    
    // Sync
    
    func syncWithAllParties() async {
        let identifier = sttIdentifier()
        let chapterNumbers = Set(threadSafeChapters?.map(\.number) ?? [])        
        // gets tracker matches in a [TrackerID:EntryID] format
        let matches: [String: String] = DataManager.shared.getTrackerLinks(for: contentIdentifier)
               
        
        // Get A Dictionary representing the trackers and the current max read chapter on each tracker
        typealias Marker = (String, Double)
        let markers = await withTaskGroup(of: Marker.self, body: { group in
            
            for (key, value) in matches {
                // Get Tracker To handle
                guard let tracker = DSK.shared.getTracker(id: key) else {
                    continue
                }
                
                group.addTask {
                    do {
                        let item = try await tracker.getTrackItem(id: value)
                        let originMaxReadChapter = item.entry?.progress.lastReadChapter ?? 0
                        return (tracker.id, originMaxReadChapter)
                    } catch {
                        Logger.shared.error(error, tracker.id)
                        return (tracker.id, 0)
                    }
                }
            }
            
            var markers: [String: Double] = [:]

            for await (key, chapter) in group {
                markers[key] = chapter
            }
            return markers
        })
        
        // Source Chapter Sync Handler
        var sourceOriginHighestRead : Double = 0
        if source.intents.chapterSyncHandler {
            do {
                let chapterIds = try await source.getReadChapterMarkers(contentId: entry.contentId)
                sourceOriginHighestRead = threadSafeChapters?
                    .filter { chapterIds.contains($0.chapterId) }
                    .map(\.number)
                    .max() ?? 0
            } catch {
                Logger.shared.error(error, source.id)
            }
        }
        
        // Prepare the Highest Read Chapter Number
        let localHighestRead = DataManager.shared.getHighestMarkedChapter(id: identifier.id)
        let originHighestRead = Array(markers.values).max() ?? 0
        let maxRead = max(localHighestRead, originHighestRead, sourceOriginHighestRead)
        
        // Max Read is 0, do not sync
        guard maxRead != 0 else { return }
        
        // Update Origin Value if outdated
        await withTaskGroup(of: String?.self, body: { group in
            for (key, value) in markers {
                guard let tracker = DSK.shared.getTracker(id: key), maxRead > value, let entryId = matches[key] else { return }
                group.addTask {
                    do {
                        try await tracker.didUpdateLastReadChapter(id: entryId, progress: .init(chapter: maxRead, volume: nil))
                        return tracker.id
                    } catch {
                        Logger.shared.error(error, tracker.id)
                    }
                    return nil
                }
            }
            
            for await result in group {
                guard let result else { continue }
                Logger.shared.debug("Sync Complete", result)
            }
        })
        
        // Update Local Value if outdated, sources are notified if they have the Chapter Event Handler
        if maxRead != localHighestRead {
            let chaptersToMark = chapterNumbers.filter { $0 <= maxRead }
            let linked = DataManager.shared.getLinkedContent(for: identifier.id)
            DataManager.shared.markChaptersByNumber(for: identifier, chapters: chaptersToMark)
            linked
                .forEach { DataManager.shared.markChaptersByNumber(for: $0.ContentIdentifier, chapters: chaptersToMark) }
        }
    }
}

// MARK: - Action State
extension ProfileView.ViewModel {
    struct ActionState: Hashable {
        var state: ProgressState
        var chapter: ChapterInfo?
        var marker: Marker?
        
        struct ChapterInfo: Hashable {
            var name: String
            var id: String
        }
        
        struct Marker: Hashable {
            var progress: Double
            var date: Date?
        }
    }
    
    enum ProgressState: Int, Hashable {
        case none, start, resume, bad_path, reRead, upNext, restart
        
        var description: String {
            switch self {
            case .none:
                return " - "
            case .start:
                return "Start"
            case .resume:
                return "Resume"
            case .bad_path:
                return "Chapter not Found"
            case .reRead:
                return "Re-read"
            case .upNext:
                return "Up Next"
            case .restart:
                return "Restart"
            }
        }
    }
    
    func setActionState() {
        let state = calculateActionState()
        Task { @MainActor in
            withAnimation {
                self.actionState = state
            }
        }
    }
    func calculateActionState() -> ActionState {
        guard let chapters = chapters.value, !chapters.isEmpty else {
            return .init(state: .none)
        }
        
        guard content.contentId == entry.contentId else {
            return .init(state: .none)
        }
        
        let marker = DataManager
            .shared
            .getLatestLinkedMarker(for: contentIdentifier)?
            .freeze()
        
        
        guard let marker else {
            // No Progress marker present, return first chapter
            let chapter = chapters.last!
            return .init(state: .start, chapter: .init(name: chapter.chapterName, id: chapter.id), marker: nil)
        }
        
        guard let chapterRef = marker.currentChapter else {
            // Marker Exists but there is not reference to the chapter
            let maxRead = marker.maxReadChapter
            
            // Check the max read chapter and use this instead
            guard let maxRead else  {
                // No Maximum Read Chapter, meaning marker exists without any reference or read chapers, point to first chapter instead
                let chapter = chapters.last!
                return .init(state: .start, chapter: .init(name: chapter.chapterName, id: chapter.id), marker: nil)
            }
            
            
            // Get The latest chapter
            guard let targetIndex = chapters.lastIndex(where: { $0.number >= maxRead })  else {
                let target = chapters.first!

                return .init(state: .reRead, chapter: .init(name: target.chapterName, id: target.id))
            }
            // We currently have the index of the last read chapter, if this index points to the last chapter, represent a reread else get the next up
            guard let currentMaxReadChapter = chapters.get(index: targetIndex) else {
                return .init(state: .none) // Should Never Happen
            }
            
            if currentMaxReadChapter == chapters.first { // Max Read is lastest available chapter
                return .init(state: .reRead, chapter: .init(name: currentMaxReadChapter.chapterName, id: currentMaxReadChapter.id))
            } else if let nextUpChapter = chapters.get(index: max(0, targetIndex - 1)) { // Point to next after max read
                return .init(state: .upNext, chapter: .init(name: nextUpChapter.chapterName, id: nextUpChapter.id))
            }
            
            return .init(state: .none)
        }
        
        // Fix Situation where the chapter being referenced is not in the joined chapter list by picking the last where the numbers match
        var correctedChapterId = chapterRef.id
        if !chapters.contains(where: { $0.id == chapterRef.id }), let chapter = chapters.last(where: { $0.number >= chapterRef.number }) {
            correctedChapterId = chapter.id
        }
        
        // 
        let info = ActionState.ChapterInfo(name: chapterRef.chapterName, id: correctedChapterId)

        if !marker.isCompleted {
            // Marker Exists, Chapter has not been completed, resume
            return .init(state: .resume, chapter: info, marker: .init(progress: marker.progress ?? 0.0, date: marker.dateRead))
        }
        // Chapter has been completed, Get Current Index
        guard var index = chapters.firstIndex(where: { $0.id == info.id }) else {
            return .init(state: .none) // Should never occur due to earlier correction
        }
        
        // Current Index is equal to that of the last available chapter
        // Set action state to re-read
        // marker is nil to avoid progress display
        if index == 0 {
            if content.status == .COMPLETED, let chapter = chapters.last {
                return .init(state: .restart, chapter: .init(name: chapter.chapterName, id: chapter.id), marker: nil)
            }
            return .init(state: .reRead, chapter: info, marker: nil)
        }
        
        // index not 0, decrement, sourceIndex moves inverted
        index -= 1
        let next = chapters.get(index: index)
        return .init(state: .upNext, chapter: next.flatMap { .init(name: $0.chapterName, id: $0.id) }, marker: nil)
    }
}
