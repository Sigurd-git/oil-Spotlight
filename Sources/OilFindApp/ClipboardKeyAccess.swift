import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum ClipboardKeyService {
    static let serviceID = "com.oiloil.find.clipboard-key-service"
    static let hostID = "com.oiloil.find"
    static let service = "com.oiloil.find.clipboard-history"
    static let account = "aes-gcm-v1"
}

@objc(OilFindClipboardKeyServiceProtocol)
protocol OilFindClipboardKeyServiceProtocol {
    func readKey(createIfMissing: Bool, allowsInteraction: Bool, reply: @escaping (Data?, Int) -> Void)
}

enum ClipboardKeyAccessFailure: Int, Error {
    case keyUnavailable = 1
    case keychainUnavailable = 2
}

final class ClipboardKeyServiceLifetime {
    private let lock = NSLock()
    private var active = true

    func end() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func performIfActive(_ operation: () throws -> Data) throws -> Data {
        lock.lock()
        let canStart = active
        lock.unlock()
        guard canStart else { throw ClipboardKeyAccessFailure.keychainUnavailable }
        // A Security call already in progress cannot be cancelled. Do not hold
        // this lock across it: invalidation must immediately cancel queued work.
        return try operation()
    }
}

enum ClipboardKeyAccess {
    private static let interactionLock = NSRecursiveLock()

    static func bytes(service: String, account: String, allowsInteraction: Bool,
                      keychain: SecKeychain? = nil, createIfMissing: Bool) throws -> Data {
        // LAContext does not suppress prompts for legacy macOS keychain items.
        // Limit this process-wide switch to the serialized request and restore it.
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var interactionAllowed: DarwinBoolean = false
        // XPC services may start with interaction disabled. Only an explicit
        // settings request enables it, and both paths restore the prior state.
        guard SecKeychainGetUserInteractionAllowed(&interactionAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowsInteraction) == errSecSuccess
        else { throw ClipboardKeyAccessFailure.keychainUnavailable }
        defer { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }
        let context = LAContext()
        context.interactionNotAllowed = !allowsInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        if let keychain { lookup[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else { throw ClipboardKeyAccessFailure.keyUnavailable }
            return bytes
        }
        guard status == errSecItemNotFound else { throw ClipboardKeyAccessFailure.keychainUnavailable }
        guard createIfMissing else { throw ClipboardKeyAccessFailure.keyUnavailable }
        let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var addition = query
        if let keychain { addition[kSecUseKeychain as String] = keychain }
        addition[kSecValueData as String] = generated
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addition[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(addition as CFDictionary, nil)
        if added == errSecDuplicateItem {
            return try bytes(service: service, account: account, allowsInteraction: allowsInteraction,
                             keychain: keychain, createIfMissing: false)
        }
        guard added == errSecSuccess else { throw ClipboardKeyAccessFailure.keychainUnavailable }
        return generated
    }
}

enum ClipboardCodeSigningFailure: Error {
    case invalidIdentity
    case invalidRequirement
}

enum ClipboardCodeSigning {
    struct Identity: Equatable {
        let identifier: String
        let certificateSHA1: String
    }

    static func currentIdentity() throws -> Identity {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
        else { throw ClipboardCodeSigningFailure.invalidIdentity }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { throw ClipboardCodeSigningFailure.invalidIdentity }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any]
        else { throw ClipboardCodeSigningFailure.invalidIdentity }
        return try identity(signingInformation: information)
    }

    // A pure metadata seam lets tests reject unsigned identities without a keychain.
    static func identity(signingInformation: [String: Any]) throws -> Identity {
        guard let identifier = signingInformation[kSecCodeInfoIdentifier as String] as? String,
              validIdentifier(identifier),
              let certificates = signingInformation[kSecCodeInfoCertificates as String] as? [Any],
              let firstCertificate = certificates.first,
              CFGetTypeID(firstCertificate as CFTypeRef) == SecCertificateGetTypeID()
        else { throw ClipboardCodeSigningFailure.invalidIdentity }
        let certificate = firstCertificate as! SecCertificate
        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprint = Insecure.SHA1.hash(data: certificateData).map { String(format: "%02X", $0) }.joined()
        return Identity(identifier: identifier, certificateSHA1: fingerprint)
    }

    static func requirement(identifier: String, certificateSHA1: String) throws -> String {
        guard validIdentifier(identifier), certificateSHA1.utf8.count == 40,
              certificateSHA1.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              })
        else { throw ClipboardCodeSigningFailure.invalidRequirement }
        let requirement = "identifier \"\(identifier)\" and certificate leaf = H\"\(certificateSHA1.uppercased())\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &parsed) == errSecSuccess,
              parsed != nil
        else { throw ClipboardCodeSigningFailure.invalidRequirement }
        return requirement
    }

    static func requirementForCurrentProcess(identifier: String) throws -> String {
        try requirement(identifier: identifier, certificateSHA1: currentIdentity().certificateSHA1)
    }

    private static func validIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.count <= 255 else { return false }
        return identifier.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }
    }
}
