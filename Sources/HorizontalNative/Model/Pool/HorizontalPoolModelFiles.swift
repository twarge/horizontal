import Foundation
import HorizontalProjectIO

/// Owns immutable model files for an unsaved library update and its undo snapshots.
final class HorizontalPoolModelFiles: @unchecked Sendable {
    let directory: URL
    let contents: [String: Data]

    init(contents: [String: Data]) throws {
        self.contents = contents
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-library-models-\(UUID().uuidString)")
        do {
            for (path, data) in contents {
                let url = try HorizontalPoolCacheProvenance.safeURL(path, in: directory)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func apply(to board: inout HorizontalBoard) {
        for index in board.packages.indices {
            guard var model = board.packages[index].model3D, contents[model.filename] != nil else { continue }
            model.fileURL = directory.appendingPathComponent(model.filename)
            board.packages[index].model3D = model
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension HorizontalProject {
    mutating func retainPoolModels(in archive: HorizontalProjectArchive, reusing existing: HorizontalPoolModelFiles? = nil) throws {
        guard let poolDirectory, var board else { return }
        let filenames = Set(board.packages.compactMap { $0.model3D?.filename })
        let files = HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: poolDirectory).filter { filenames.contains($0.key) }
        guard !files.isEmpty else { return }
        let retained: HorizontalPoolModelFiles
        if let existing, existing.contents == files { retained = existing }
        else { retained = try HorizontalPoolModelFiles(contents: files) }
        retained.apply(to: &board)
        self.board = board
        poolModelFiles = retained
    }

    static func poolModelsChanged(from before: HorizontalProjectArchive, to after: HorizontalProjectArchive, poolDirectory: String?) -> Bool {
        guard let poolDirectory else { return false }
        let prefix = poolDirectory + "/3d_models/"
        let paths = Set(before.regularFilePaths + after.regularFilePaths).filter { $0.hasPrefix(prefix) }
        return paths.contains { before.regularFileData(relativePath: $0) != after.regularFileData(relativePath: $0) }
    }
}
