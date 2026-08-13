import Foundation
import Security

enum CodeSigningIdentity {
  static func currentTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let dictionary = information as? [CFString: Any] else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier] as? String
  }

  static func requirement(identifier: String) -> String? {
    if let teamIdentifier = currentTeamIdentifier(), !teamIdentifier.isEmpty {
      return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
#if DEBUG
    // Ad-hoc debug builds have no Team ID. Identifier matching is an explicit
    // development-only downgrade; Release builds fail closed instead.
    return "identifier \"\(identifier)\""
#else
    return nil
#endif
  }
}
