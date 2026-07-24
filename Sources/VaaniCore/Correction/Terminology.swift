import Foundation

public struct TerminologyEntry: Codable, Equatable, Sendable {
    public let canonical: String
    public let aliases: [String]
    public let language: LanguageTag
    public let script: String
    public let protected: Bool
    public let outputForms: [String: String]
    public let collisionRisk: Double

    public init(
        canonical: String,
        aliases: [String],
        language: LanguageTag,
        script: String,
        protected: Bool,
        outputForms: [String: String],
        collisionRisk: Double
    ) throws {
        guard !canonical.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("terminology entry canonical must not be empty")
        }
        guard !script.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("terminology entry script must not be empty for \(canonical)")
        }
        guard collisionRisk >= 0, collisionRisk <= 1 else {
            throw VaaniCoreError.invalidProbability(field: "collisionRisk", value: collisionRisk)
        }
        for alias in aliases where alias.isEmpty {
            throw VaaniCoreError.invalidConfiguration("terminology entry \(canonical) has an empty alias")
        }
        let supportedOutputForms: Set<String> = ["gujaratiScript", "bapsRoman"]
        for (key, value) in outputForms {
            guard supportedOutputForms.contains(key) else {
                throw VaaniCoreError.invalidConfiguration(
                    "terminology entry \(canonical) has unsupported output form '\(key)'"
                )
            }
            guard !value.isEmpty else {
                throw VaaniCoreError.invalidConfiguration(
                    "terminology entry \(canonical) has empty output form '\(key)'"
                )
            }
        }
        self.canonical = canonical
        self.aliases = aliases
        self.language = language
        self.script = script
        self.protected = protected
        self.outputForms = outputForms
        self.collisionRisk = collisionRisk
    }

    private enum CodingKeys: String, CodingKey {
        case canonical, aliases, language, script, protected, outputForms, collisionRisk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canonical: try container.decode(String.self, forKey: .canonical),
            aliases: try container.decode([String].self, forKey: .aliases),
            language: try container.decode(LanguageTag.self, forKey: .language),
            script: try container.decode(String.self, forKey: .script),
            protected: try container.decode(Bool.self, forKey: .protected),
            outputForms: try container.decode([String: String].self, forKey: .outputForms),
            collisionRisk: try container.decode(Double.self, forKey: .collisionRisk)
        )
    }
}

public struct TerminologyPack: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let license: String
    public let provenance: String
    public let entries: [TerminologyEntry]

    public init(
        schemaVersion: Int,
        id: String,
        version: String,
        license: String,
        provenance: String,
        entries: [TerminologyEntry]
    ) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw VaaniCoreError.invalidConfiguration(
                "unsupported terminology pack schemaVersion \(schemaVersion); expected \(Self.supportedSchemaVersion)"
            )
        }
        guard !id.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("terminology pack id must not be empty")
        }
        guard !version.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("terminology pack version must not be empty")
        }
        guard !license.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("terminology pack license must not be empty")
        }
        guard !provenance.isEmpty else {
            throw VaaniCoreError.invalidConfiguration("terminology pack provenance must not be empty")
        }

        var seenCanonicals: Set<String> = []
        for entry in entries {
            let folded = entry.canonical.folding(options: .caseInsensitive, locale: nil)
            guard !seenCanonicals.contains(folded) else {
                throw VaaniCoreError.invalidConfiguration("duplicate terminology canonical: \(entry.canonical)")
            }
            seenCanonicals.insert(folded)
        }

        for entry in entries {
            var seenAliases: Set<String> = []
            for alias in entry.aliases {
                let folded = alias.folding(options: .caseInsensitive, locale: nil)
                guard !seenAliases.contains(folded) else {
                    throw VaaniCoreError.invalidConfiguration(
                        "duplicate alias '\(alias)' within entry \(entry.canonical)"
                    )
                }
                seenAliases.insert(folded)
            }
        }

        var aliasOwners: [String: String] = [:]
        for entry in entries {
            for alias in entry.aliases {
                let folded = alias.folding(options: .caseInsensitive, locale: nil)
                if let existingOwner = aliasOwners[folded], existingOwner != entry.canonical {
                    throw VaaniCoreError.invalidConfiguration(
                        "alias '\(alias)' is ambiguous between '\(existingOwner)' and '\(entry.canonical)'"
                    )
                }
                aliasOwners[folded] = entry.canonical
            }
        }

        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.license = license
        self.provenance = provenance
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, version, license, provenance, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            id: try container.decode(String.self, forKey: .id),
            version: try container.decode(String.self, forKey: .version),
            license: try container.decode(String.self, forKey: .license),
            provenance: try container.decode(String.self, forKey: .provenance),
            entries: try container.decode([TerminologyEntry].self, forKey: .entries)
        )
    }
}
