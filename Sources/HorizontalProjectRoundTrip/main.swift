import Foundation
import HorizontalProjectIO

@main
struct HorizontalProjectRoundTrip {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        guard let firstArgument = arguments.first else {
            print("usage: HorizontalProjectRoundTrip <project.hprj | project.horizontal>")
            throw ExitCode.failure
        }

        let sourceURL = URL(fileURLWithPath: firstArgument).standardizedFileURL
        let archive = try HorizontalProjectArchive.completeProject(from: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-roundtrip-\(UUID().uuidString)")

        try archive.write(to: outputURL)
        let writtenArchive = try HorizontalProjectArchive.snapshot(from: outputURL)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard archive.root == writtenArchive.root else {
            throw HorizontalProjectArchiveError.roundTripMismatch
        }

        print("Round-trip OK")
        print("Files: \(archive.regularFileCount)")
        print("Directories: \(archive.directoryCount)")
        print("Symlinks: \(archive.symbolicLinkCount)")
        if let manifest = archive.manifest {
            print("Project root: \(manifest.baseURL.path)")
            print("Included references: \(manifest.includedURLs.count)")
            print("Missing references: \(manifest.missingReferences.count)")
            print("External references: \(manifest.externalReferences.count)")
        }
    }
}

private enum ExitCode: Error {
    case failure
}
