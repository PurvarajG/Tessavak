import Foundation
import TessavakCore

public enum PackLoader {
    public static func bundledBAPSGujarati() throws -> TerminologyPack {
        guard let url = Bundle.module.url(forResource: "baps-gujarati-v1", withExtension: "json") else {
            throw TessavakCoreError.invalidConfiguration("bundled resource baps-gujarati-v1.json not found")
        }
        let data = try Data(contentsOf: url)
        return try load(data: data)
    }

    public static func load(data: Data) throws -> TerminologyPack {
        try JSONDecoder().decode(TerminologyPack.self, from: data)
    }
}
