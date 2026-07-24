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
    public static func load(fromPath path: String) throws -> ReplayManifest {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchManifestError.fileNotFound(path)
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
