import Foundation

extension CaptureMasterProfile {
  public static func selected() throws -> Self {
    try checked.get()
  }

  private static let checked: Result<Self, any Error> = Result {
    guard
      let url = Bundle.module.url(forResource: "capture-master-profile.v1", withExtension: "json")
    else {
      throw ContractError.structure
    }
    return try Contract.decode(Self.self, bytes: Data(contentsOf: url)).value
  }
}
