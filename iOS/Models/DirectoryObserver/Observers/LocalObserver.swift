//
//  LocalObserver.swift
//  Suwatte (iOS)
//
//  Created by Mantton on 2023-06-20.
//

import Foundation
import UIKit

// Reference: https://medium.com/over-engineering/monitoring-a-folder-for-changes-in-ios-dc3f8614f902
class LocalObserver: DirectoryObserver {

    var path: URL
    var extensions: [String]
    
    private var observer: DispatchSourceFileSystemObject?
    private var callback: ((Folder) -> Void)?
    private var updatesEnabled = true
    init(extensions: [String], url: URL) {
        self.extensions = extensions
        self.path = url
    }
    
    func observe(_ callback: @escaping ((Folder) -> Void)) {
        self.stop()
        self.callback = callback
        self.observer = createObserver()
        observer?.resume()
    }
    
    func stop() {
        self.observer?.cancel()
        self.observer = nil
    }
    
    private func createObserver() -> DispatchSourceFileSystemObject? {
        if !path.exists {
            path.createDirectory()
        }
        
        let descriptor = open(path.path, O_EVTONLY)
        let observer = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global(qos: .background))
        observer.setEventHandler { [weak self] in            
            self?.didReceiveNotification()
        }

        observer.setRegistrationHandler { [weak self] in
            self?.didReceiveNotification()
        }

        observer.setCancelHandler {
            close(descriptor)
        }
        return observer
    }
    
    private func didReceiveNotification() {
        guard updatesEnabled else {
            return
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            parseList(urls: urls)
            
        } catch {
            Task { @MainActor in
                ToastManager.shared.error(error)
                Logger.shared.error(error)
            }
        }
    }
    
    private func parseList(urls: [URL]) {
        updatesEnabled = false
        var rootFolder = Folder(url: path)
        for url in urls {
            
            // Folder
            if url.hasDirectoryPath {
                
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                let name = url.lastPathComponent
                let folder: Folder.SubFolder = .init(url: url, id: STTHelpers.generateFolderIdentifier(created: created, name: name), name: name)
                rootFolder.folders.append(folder)
                continue
            }
            
            // File
            guard extensions.contains(url.pathExtension) else { continue } // File Type Guard
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            
            // Generate Unique Identifier
            let fileSize = resourceValues?.fileSize.flatMap(Int64.init) ?? .zero
            let creationDate = resourceValues?.creationDate ?? .now
            let contentChangeDate = resourceValues?.contentModificationDate ?? .now
            let id = STTHelpers.generateFileIdentifier(size: fileSize, created: creationDate, modified: contentChangeDate)
            
            let pageCount = try? ArchiveHelper().getItemCount(for: url)
            let file = File(url: url, isOnDevice: true, id: id, name: url.fileName, created: creationDate, size: fileSize, pageCount: pageCount)
            rootFolder.files.append(file)
        }
        
        let final = rootFolder
        Task { @MainActor in
            callback?(final)
        }
        updatesEnabled = true
    }

}
