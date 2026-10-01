import XCTest
@testable import FounderOfficeCopilotCore

/// Covers MemoryEntity's plain value-type behavior - initialization defaults, equality, and
/// the Kind enum's cases. No Core Data, no MemoryManager here - see MemoryStoreTests/
/// MemoryManagerTests for persistence-layer coverage.
final class MemoryEntityTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let entity = MemoryEntity(kind: .person, name: "Sarah")

        XCTAssertEqual(entity.kind, .person)
        XCTAssertEqual(entity.name, "Sarah")
        XCTAssertEqual(entity.aliases, [])
        XCTAssertNil(entity.notes)
        XCTAssertFalse(entity.isUserVerified)
        XCTAssertEqual(entity.mentionCount, 1)
    }

    func testInitializerAcceptsAllExplicitValues() {
        let id = UUID()
        let created = Date(timeIntervalSinceReferenceDate: 100)
        let mentioned = Date(timeIntervalSinceReferenceDate: 200)

        let entity = MemoryEntity(
            id: id,
            kind: .organization,
            name: "Acme Corp",
            aliases: ["Acme", "Acme Inc"],
            notes: "met at a conference",
            isUserVerified: true,
            createdAt: created,
            lastMentionedAt: mentioned,
            mentionCount: 5
        )

        XCTAssertEqual(entity.id, id)
        XCTAssertEqual(entity.kind, .organization)
        XCTAssertEqual(entity.name, "Acme Corp")
        XCTAssertEqual(entity.aliases, ["Acme", "Acme Inc"])
        XCTAssertEqual(entity.notes, "met at a conference")
        XCTAssertTrue(entity.isUserVerified)
        XCTAssertEqual(entity.createdAt, created)
        XCTAssertEqual(entity.lastMentionedAt, mentioned)
        XCTAssertEqual(entity.mentionCount, 5)
    }

    func testTwoEntitiesWithTheSameIDAndFieldsAreEqual() {
        let id = UUID()
        let date = Date()
        let a = MemoryEntity(id: id, kind: .project, name: "Friday", createdAt: date, lastMentionedAt: date)
        let b = MemoryEntity(id: id, kind: .project, name: "Friday", createdAt: date, lastMentionedAt: date)
        XCTAssertEqual(a, b)
    }

    func testTwoEntitiesWithDifferentIDsAreNotEqual() {
        let a = MemoryEntity(kind: .project, name: "Friday")
        let b = MemoryEntity(kind: .project, name: "Friday")
        XCTAssertNotEqual(a, b, "distinct ids must never compare equal even with identical other fields")
    }

    func testAllKindValuesAreDistinct() {
        let all = MemoryEntity.Kind.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count, "no two kinds should share a raw value")
        let selfKind: MemoryEntity.Kind = .self // typed-context leading-dot resolves to the case, not the `.self` metatype operator
        XCTAssertTrue(all.contains(selfKind))
        XCTAssertTrue(all.contains(.person))
        XCTAssertTrue(all.contains(.organization))
        XCTAssertTrue(all.contains(.project))
        XCTAssertTrue(all.contains(.place))
        XCTAssertTrue(all.contains(.concept))
        XCTAssertTrue(all.contains(.tool))
        XCTAssertTrue(all.contains(.other))
    }

    func testSelfKindRawValueIsExactlySelf() {
        // The persisted vocabulary matters (round-trips through MemoryStore as a raw string) -
        // confirms the backtick-escaped `case `self`` persists as the string "self", not some
        // mangled/alternate spelling. `MemoryEntity.Kind.self` (fully qualified) is NOT used
        // here deliberately - that spelling resolves to Swift's built-in metatype `.self`
        // operator, not the enum case, since it takes priority when the case name is directly
        // appended after a type name. A typed-context leading-dot (`let k: Kind = .self`) is
        // the only form that resolves to the case unambiguously.
        let selfKind: MemoryEntity.Kind = .self
        XCTAssertEqual(selfKind.rawValue, "self")
    }
}
