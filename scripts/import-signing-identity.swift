// Import only the caller's new identity; never edit existing keys or trust settings.
import Foundation
import Security

func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: "OilFindSigning", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(status))."])
    }
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "OilFindSigning", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: import-signing-identity KEYCHAIN P12 PASSWORD_FILE"])
    }
    try checked(SecKeychainSetUserInteractionAllowed(false), "Disable interactive import")
    var keychain: SecKeychain?
    try checked(SecKeychainOpen(CommandLine.arguments[1], &keychain), "Open signing keychain")
    var codesign: SecTrustedApplication?
    try checked(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign), "Identify Apple's codesign")
    guard let codesign else { throw NSError(domain: "OilFindSigning", code: 1) }
    var access: SecAccess?
    try checked(SecAccessCreate("Oil Find local signing" as CFString, [codesign] as CFArray, &access), "Create restricted signing access")
    guard let access else { throw NSError(domain: "OilFindSigning", code: 1) }
    let password = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        .trimmingCharacters(in: .newlines) as CFString
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    var format = SecExternalFormat.formatPKCS12
    var itemType = SecExternalItemType.itemTypeAggregate
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(password)
    parameters.accessRef = Unmanaged.passUnretained(access)
    try checked(SecItemImport(data as CFData, "p12" as CFString, &format, &itemType, [],
                             &parameters, keychain, nil), "Import signing identity")
    print("Imported local signing identity; private-key access is limited to /usr/bin/codesign.")
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
