import CryptoKit
import Foundation

public actor ParakeetModelStore {
    private let root: URL

    public init(root: URL = URL.applicationSupportDirectory.appending(path: "Murmur/Models")) {
        self.root = root
    }

    /// Keeps the existing v2 cache. Only this model is downloaded or loaded.
    public var directory: URL { root.appending(path: "parakeetV2", directoryHint: .isDirectory) }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let assets = try assets()
        let destination = directory
        if try assets.allSatisfy({ try Self.isValid(destination.appending(path: $0.path), asset: $0) }) {
            return destination
        }
        let staging = root.appending(path: ".parakeetV2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let total = assets.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        var completed: Int64 = 0
        for asset in assets {
            try Task.checkCancellation()
            let delegate = ModelDownloadProgress(completed: completed, total: total, report: progress)
            let (temporary, response) = try await URLSession.shared.download(from: asset.url, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw RecognitionError.message("Couldn't download Parakeet v2. Check your connection and retry.")
            }
            guard try Self.isValid(temporary, asset: asset) else {
                throw RecognitionError.message("Model verification failed. Please retry the download.")
            }
            let target = staging.appending(path: asset.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += Int64(asset.bytes)
            progress(Double(completed) / Double(total))
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private func assets() throws -> [ModelAsset] {
        guard let url = Bundle.module.url(forResource: "ParakeetV2", withExtension: "json") else {
            throw RecognitionError.message("The Parakeet v2 download manifest is missing.")
        }
        let assets = try JSONDecoder().decode([ModelAsset].self, from: Data(contentsOf: url))
        guard !assets.isEmpty else { throw RecognitionError.message("The Parakeet v2 download manifest is empty.") }
        return assets
    }

    static func isValid(_ file: URL, asset: ModelAsset) throws -> Bool {
        try Task.checkCancellation()
        guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == asset.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}
