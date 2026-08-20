//
//  SharedFolderICloudMirror.swift
//  Minis
//
//  A one-way, phone-authoritative mirror of /var/minis/shared to iCloud Drive.
//

import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted after the app-owned `shared` directory changes. The payload never
    /// contains filenames or file content, because those may be user data.
    static let minisSharedFolderDidChange = Notification.Name("com.1agents.phone.shared-folder-did-change")
}

/// Publishes a Finder-visible copy of the app's `shared` directory to iCloud
/// Drive. This deliberately has no import/download path: files in iCloud are
/// never read back into Minis, so the phone remains the sole source of truth.
@MainActor
final class SharedFolderICloudMirror: ObservableObject {
    static let shared = SharedFolderICloudMirror()

    static let iCloudContainerIdentifier = "iCloud.com.1agents.phone"
    static let iCloudFolderName = "Minis Shared"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?

    private static let enabledKey = "sharedFolderICloudMirror.enabled"
    private static let lastSyncedAtKey = "sharedFolderICloudMirror.lastSyncedAt"

    private var didStart = false
    private var notificationObserver: NSObjectProtocol?
    private var pendingSyncWork: DispatchWorkItem?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

    /// Starts observation and performs an initial reconciliation when enabled.
    /// Safe to call on every SwiftUI appearance.
    func start() {
        guard !didStart else { return }
        didStart = true
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .minisSharedFolderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync(reason: "shared changed") }
        }
        if isEnabled { scheduleSync(reason: "app launch") }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        lastError = nil
        if enabled {
            scheduleSync(reason: "enabled")
        } else {
            pendingSyncWork?.cancel()
            pendingSyncWork = nil
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active, isEnabled {
            scheduleSync(reason: "foreground")
        }
    }

    func syncNow() {
        scheduleSync(reason: "manual", delayNanoseconds: 0)
    }

    /// Resolves only the local projection of the ubiquity container. It does
    /// not enumerate or read files from iCloud.
    var isICloudAvailable: Bool {
        iCloudDirectoryURL != nil
    }

    private var iCloudDirectoryURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: Self.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.iCloudFolderName, isDirectory: true)
    }

    private func scheduleSync(reason: String, delayNanoseconds: UInt64 = 750_000_000) {
        guard isEnabled else { return }
        pendingSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.runSync(reason: reason)
            }
        }
        pendingSyncWork = work
        let delay = Double(delayNanoseconds) / 1_000_000_000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runSync(reason: String) async {
        guard !isSyncing else { return }
        guard let destination = iCloudDirectoryURL else {
            lastError = "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive, then try again."
            return
        }

        isSyncing = true
        lastError = nil
        let source = AIChatViewModel.minisSharedPersistentDir
        let logger = AppLogger(category: "SharedICloudMirror")

        let result = await Task.detached(priority: .utility) {
            try SharedFolderICloudMirror.reconcile(source: source, destination: destination)
        }.result

        isSyncing = false
        switch result {
        case .success(let summary):
            let now = Date()
            lastSyncedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncedAtKey)
            logger.info("[SharedICloudMirror] reason=\(reason) copied=\(summary.copied) deleted=\(summary.deleted) skipped=\(summary.skipped)")
        case .failure(let error):
            lastError = error.localizedDescription
            logger.error("[SharedICloudMirror] failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private struct Summary {
        var copied = 0
        var deleted = 0
        var skipped = 0
    }

    /// Reconciles the destination using source data only. The destination is
    /// never inspected for content and is never imported into the app.
    private nonisolated static func reconcile(source: URL, destination: URL) throws -> Summary {
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var summary = Summary()
        var sourcePaths = Set<String>()
        sourcePaths.insert("")

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return summary }

        for case let sourceItem as URL in enumerator {
            let values = try sourceItem.resourceValues(forKeys: keys)
            // A link could point outside the user-approved shared directory;
            // don't follow or publish it.
            if values.isSymbolicLink == true {
                summary.skipped += 1
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let relativePath = sourceItem.path.replacingOccurrences(of: source.path + "/", with: "")
            guard !relativePath.isEmpty, !relativePath.hasPrefix("../") else { continue }
            sourcePaths.insert(relativePath)
            let destinationItem = destination.appendingPathComponent(relativePath, isDirectory: values.isDirectory == true)

            if values.isDirectory == true {
                try fm.createDirectory(at: destinationItem, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else {
                summary.skipped += 1
                continue
            }

            if destinationMatches(source: sourceItem, destination: destinationItem, sourceValues: values) {
                summary.skipped += 1
                continue
            }
            try copyAtomically(source: sourceItem, destination: destinationItem, fileManager: fm)
            summary.copied += 1
        }

        // The phone is authoritative. Removing a file locally removes its
        // previously mirrored copy; files created or edited on Mac are never
        // imported and will be overwritten/deleted on the next reconciliation.
        let destinationKeys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let destinationEnumerator = fm.enumerator(
            at: destination,
            includingPropertiesForKeys: Array(destinationKeys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return summary }
        var staleItems: [URL] = []
        for case let destinationItem as URL in destinationEnumerator {
            let relativePath = destinationItem.path.replacingOccurrences(of: destination.path + "/", with: "")
            if !sourcePaths.contains(relativePath) { staleItems.append(destinationItem) }
        }
        for staleItem in staleItems.sorted(by: { $0.path.count > $1.path.count }) {
            try fm.removeItem(at: staleItem)
            summary.deleted += 1
        }
        return summary
    }

    private nonisolated static func destinationMatches(
        source: URL,
        destination: URL,
        sourceValues: URLResourceValues
    ) -> Bool {
        guard let destinationValues = try? destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              destinationValues.isRegularFile == true,
              destinationValues.fileSize == sourceValues.fileSize else { return false }
        guard let sourceDate = sourceValues.contentModificationDate,
              let destinationDate = destinationValues.contentModificationDate else { return false }
        return abs(sourceDate.timeIntervalSince(destinationDate)) < 1
    }

    private nonisolated static func copyAtomically(source: URL, destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".minis-mirror-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}

struct SharedFolderICloudMirrorSettingsView: View {
    @ObservedObject private var mirror = SharedFolderICloudMirror.shared
    @State private var confirmEnable = false

    var body: some View {
        List {
            Section {
                Toggle("Mirror Shared to iCloud Drive", isOn: Binding(
                    get: { mirror.isEnabled },
                    set: { enabled in
                        if enabled { confirmEnable = true }
                        else { mirror.setEnabled(false) }
                    }
                ))
            } footer: {
                Text("Minis copies /var/minis/shared to iCloud Drive/Minis/Minis Shared. The phone is authoritative: iCloud changes are never imported back into Minis.")
            }

            Section("Status") {
                LabeledContent("iCloud Drive", value: mirror.isICloudAvailable ? "Available" : "Unavailable")
                if let lastSyncedAt = mirror.lastSyncedAt {
                    LabeledContent("Last mirrored", value: lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = mirror.lastError {
                    Text(error).foregroundStyle(.red)
                }
                Button(mirror.isSyncing ? "Syncing…" : "Sync now") { mirror.syncNow() }
                    .disabled(!mirror.isEnabled || mirror.isSyncing)
            }
        }
        .navigationTitle("iCloud Drive Mirror")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Copy Shared Files to iCloud Drive?",
            isPresented: $confirmEnable,
            titleVisibility: .visible
        ) {
            Button("Enable Mirror") { mirror.setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files in /var/minis/shared will be copied to iCloud Drive and become available on devices signed in to this iCloud account. Mac changes are not imported into Minis.")
        }
    }
}
