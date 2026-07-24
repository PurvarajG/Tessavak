import Foundation
import Testing
import VaaniCore

@testable import VaaniPacks

@Suite struct PackLoaderTests {

    @Test func bundledPackDecodesWithValidSchema() throws {
        let pack = try PackLoader.bundledBAPSGujarati()
        #expect(pack.schemaVersion == 1)
        #expect(!pack.id.isEmpty)
        #expect(!pack.version.isEmpty)
        #expect(!pack.provenance.isEmpty)
        #expect(!pack.license.isEmpty)
        #expect(!pack.entries.isEmpty)
    }

    @Test func bundledPackHasUniqueCaseFoldedCanonicals() throws {
        let pack = try PackLoader.bundledBAPSGujarati()
        let folded = pack.entries.map { $0.canonical.folding(options: .caseInsensitive, locale: nil) }
        #expect(Set(folded).count == folded.count)
    }

    @Test func bundledPackCollisionRiskWithinRange() throws {
        let pack = try PackLoader.bundledBAPSGujarati()
        for entry in pack.entries {
            #expect(entry.collisionRisk >= 0 && entry.collisionRisk <= 1)
        }
    }

    @Test func bundledPackAliasesEachMapToOnlyOneEntry() throws {
        let pack = try PackLoader.bundledBAPSGujarati()
        var owners: [String: String] = [:]
        for entry in pack.entries {
            for alias in entry.aliases {
                let folded = alias.folding(options: .caseInsensitive, locale: nil)
                if let existing = owners[folded] {
                    #expect(existing == entry.canonical)
                } else {
                    owners[folded] = entry.canonical
                }
            }
        }
    }

    @Test func bundledPackContainsExpectedSeedTerms() throws {
        let pack = try PackLoader.bundledBAPSGujarati()
        let canonicals = Set(pack.entries.map(\.canonical))
        #expect(canonicals.isSuperset(of: ["BAPS", "Vachanamrut", "Pramukh Swami Maharaj"]))
    }

    @Test func loadRejectsUnsupportedSchemaVersion() {
        let json = Data(
            """
            {
              "schemaVersion": 2,
              "id": "x",
              "version": "1",
              "license": "Apache-2.0",
              "provenance": "test",
              "entries": []
            }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try PackLoader.load(data: json)
        }
    }

    @Test func loadRejectsDuplicateCanonicals() {
        let json = Data(
            """
            {
              "schemaVersion": 1,
              "id": "x",
              "version": "1",
              "license": "Apache-2.0",
              "provenance": "test",
              "entries": [
                {
                  "canonical": "Term",
                  "aliases": [],
                  "language": "en",
                  "script": "Latin",
                  "protected": true,
                  "outputForms": {},
                  "collisionRisk": 0.1
                },
                {
                  "canonical": "term",
                  "aliases": [],
                  "language": "en",
                  "script": "Latin",
                  "protected": true,
                  "outputForms": {},
                  "collisionRisk": 0.1
                }
              ]
            }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try PackLoader.load(data: json)
        }
    }

    @Test func loadRejectsAmbiguousAlias() {
        let json = Data(
            """
            {
              "schemaVersion": 1,
              "id": "x",
              "version": "1",
              "license": "Apache-2.0",
              "provenance": "test",
              "entries": [
                {
                  "canonical": "Alpha",
                  "aliases": ["shared"],
                  "language": "en",
                  "script": "Latin",
                  "protected": false,
                  "outputForms": {},
                  "collisionRisk": 0.1
                },
                {
                  "canonical": "Beta",
                  "aliases": ["shared"],
                  "language": "en",
                  "script": "Latin",
                  "protected": false,
                  "outputForms": {},
                  "collisionRisk": 0.1
                }
              ]
            }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try PackLoader.load(data: json)
        }
    }

    @Test func rejectsCanonicalAliasOwnershipCollision() throws {
        let first = try TerminologyEntry(
            canonical: "Alpha",
            aliases: ["Beta"],
            language: .english,
            script: "Latin",
            protected: true,
            outputForms: [:],
            collisionRisk: 0
        )
        let second = try TerminologyEntry(
            canonical: "Beta",
            aliases: [],
            language: .english,
            script: "Latin",
            protected: true,
            outputForms: [:],
            collisionRisk: 0
        )
        #expect(throws: (any Error).self) {
            _ = try TerminologyPack(
                schemaVersion: 1,
                id: "x",
                version: "1",
                license: "Apache-2.0",
                provenance: "test",
                entries: [first, second]
            )
        }
    }

    @Test func rejectsCanonicalAliasOwnershipCollisionAcrossCasing() throws {
        let first = try TerminologyEntry(
            canonical: "Alpha",
            aliases: ["BETA"],
            language: .english,
            script: "Latin",
            protected: true,
            outputForms: [:],
            collisionRisk: 0
        )
        let second = try TerminologyEntry(
            canonical: "Beta",
            aliases: [],
            language: .english,
            script: "Latin",
            protected: true,
            outputForms: [:],
            collisionRisk: 0
        )
        #expect(throws: (any Error).self) {
            _ = try TerminologyPack(
                schemaVersion: 1,
                id: "x",
                version: "1",
                license: "Apache-2.0",
                provenance: "test",
                entries: [first, second]
            )
        }
    }

    @Test func loadRejectsEmptyCanonical() {
        let json = Data(
            """
            {
              "schemaVersion": 1,
              "id": "x",
              "version": "1",
              "license": "Apache-2.0",
              "provenance": "test",
              "entries": [
                {
                  "canonical": "",
                  "aliases": [],
                  "language": "en",
                  "script": "Latin",
                  "protected": false,
                  "outputForms": {},
                  "collisionRisk": 0.1
                }
              ]
            }
            """.utf8
        )
        #expect(throws: (any Error).self) {
            try PackLoader.load(data: json)
        }
    }
}
