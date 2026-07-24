import Foundation
import VaaniAdapters

public enum BenchManifestError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidManifest(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "manifest file not found at \(path)"
        case .invalidManifest(let reason):
            return "invalid manifest: \(reason)"
        }
    }
}

public enum BenchManifestLoader {
    public static let maximumManifestBytes = 64 * 1024 * 1024

    public static func load(fromPath path: String) throws -> ReplayManifest {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchManifestError.fileNotFound(path)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw BenchManifestError.invalidManifest("\(error)")
        }
        if let size = attributes[.size] as? Int, size > maximumManifestBytes {
            throw BenchManifestError.invalidManifest(
                "manifest file exceeds \(maximumManifestBytes) byte limit (was \(size) bytes)"
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchManifestError.invalidManifest("\(error)")
        }
        do {
            return try JSONDecoder().decode(ReplayManifest.self, from: data)
        } catch {
            throw BenchManifestError.invalidManifest("\(error)")
        }
    }
}
