import CryptoKit
import Foundation

actor DiskSnapshots {
    static let shared = DiskSnapshots(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.strata.DiskWorkspace/ScanSnapshots-v1", isDirectory: true))
    private let directory: URL
    private let limit = 16 * 1024 * 1024

    init(directory: URL) { self.directory = directory }

    struct Scope: Sendable {
        let root: URL
        let wholeDisk: Bool
        let selection: URL?

        var filename: String {
            if root == DiskScanner.startupRoot && wholeDisk && selection == nil { return "startup.plist" }
            let key = [root.path, wholeDisk ? "whole" : "folder", selection?.path ?? ""].joined(separator: "\0")
            return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".plist"
        }
    }

    func read(_ scope: Scope) -> DiskScanResult? {
        let url = directory.appendingPathComponent(scope.filename)
        guard !Task.isCancelled, let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit,
              var report = try? PropertyListDecoder().decode(DiskScanResult.self, from: data),
              report.root == scope.root, report.measuredAt != nil, report.pendingDirectories == 0,
              valid(report.entries, under: report.root) else { return nil }
        // Older parent totals are usable, but their child rows used global link attribution.
        if report.independentChildSizes != true { report.children.removeAll() }
        let folders = Set(report.entries.filter { $0.isDirectory && !$0.requiresSelection }.map(\.url))
        guard report.children.allSatisfy({ folders.contains($0.key) && valid($0.value, under: $0.key) }) else { return nil }
        return report
    }

    private func valid(_ entries: [DiskEntry], under root: URL) -> Bool {
        var total: Int64 = 0
        for entry in entries {
            let sum = total.addingReportingOverflow(entry.bytes)
            guard !sum.overflow, entry.bytes >= 0, entry.tileColorIndex ?? 0 >= 0, entry.url.isFileURL,
                  entry.name != ".", entry.name != "..", !entry.name.isEmpty,
                  entry.url == root.appendingPathComponent(entry.name, isDirectory: entry.isDirectory) else { return false }
            total = sum.partialValue
        }
        return true
    }

    func save(_ report: DiskScanResult, for scope: Scope) throws {
        let manager = FileManager.default
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(report)
        guard data.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try Task.checkCancellation()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(scope.filename)
        try data.write(to: file, options: .atomic)
        let others = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "plist" && $0.lastPathComponent != "startup.plist" && $0 != file }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (old, _) in others.dropFirst(scope.filename == "startup.plist" ? 8 : 7) { try? manager.removeItem(at: old) }
    }
}
