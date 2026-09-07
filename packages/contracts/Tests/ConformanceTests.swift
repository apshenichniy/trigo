import Foundation
import Testing

@testable import TrigoContracts

struct Fixture: Decodable {
  let name: String
  let kind: String
  let document: String
  let references: [String: String]
  let expected: String?
}
let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent("fixtures")
@Test func sharedConformance() throws {
  let fixtures = try JSONDecoder()
    .decode(
      [Fixture].self,
      from: Data(contentsOf: fixtureRoot.appendingPathComponent("cases.json"))
    )
  for fixture in fixtures {
    do {
      let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent(fixture.document))
      let document: ValidatedDocument
      if fixture.kind == "CallDocument" {
        let refs = try fixture.references.mapValues {
          try Data(contentsOf: fixtureRoot.appendingPathComponent($0))
        }
        document = try Contract.validateArchive(bytes, references: refs)
      } else {
        document = try Contract.validate(fixture.kind, bytes: bytes)
      }
      #expect(fixture.expected == nil, "Unexpected success: \(fixture.name)")
      let roundTrip = try Contract.validate(
        fixture.kind,
        bytes: typedRoundTrip(fixture.kind, bytes: document.storedBytes)
      )
      #expect(roundTrip.value == document.value)
    } catch let error as ContractError {
      #expect(error.rawValue == fixture.expected, "\(fixture.name): \(error.rawValue)")
    }
  }
}
@Test func hashesExactBytes() {
  #expect(
    Contract.hash(Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  )
  #expect(Contract.hash(Data("{\"a\":1}".utf8)) != Contract.hash(Data("{ \"a\": 1 }".utf8)))
}
