import Foundation
import Security
import XCTest
@testable import OilFindApp

final class ClipboardKeyAccessTests: XCTestCase {
    func testEndedConnectionDoesNotStartKeyOperation() {
        let lifetime = ClipboardKeyServiceLifetime()
        lifetime.end()
        var called = false
        XCTAssertThrowsError(try lifetime.performIfActive {
            called = true
            return Data(repeating: 7, count: 32)
        })
        XCTAssertFalse(called)
    }

    func testEndingConnectionDoesNotWaitForInFlightSecurityOperation() throws {
        let lifetime = ClipboardKeyServiceLifetime()
        let bytes = try lifetime.performIfActive {
            lifetime.end()
            return Data(repeating: 7, count: 32)
        }
        XCTAssertEqual(bytes.count, 32)
        XCTAssertThrowsError(try lifetime.performIfActive { Data(repeating: 8, count: 32) })
    }

    func testServiceUsesFixedHostAndKeychainNamespace() {
        XCTAssertEqual(ClipboardKeyService.serviceID, "com.oiloil.find.clipboard-key-service")
        XCTAssertEqual(ClipboardKeyService.hostID, "com.oiloil.find")
        XCTAssertEqual(ClipboardKeyService.service, "com.oiloil.find.clipboard-history")
        XCTAssertEqual(ClipboardKeyService.account, "aes-gcm-v1")
        XCTAssertNotEqual(ClipboardKeyService.serviceID, ClipboardKeyService.hostID)
    }

    func testFailureCodesRoundTripAndDoNotTreatSuccessOrUnknownStatusAsFailure() {
        for failure in [ClipboardKeyAccessFailure.keyUnavailable, .keychainUnavailable] {
            XCTAssertEqual(ClipboardKeyAccessFailure(rawValue: failure.rawValue), failure)
        }
        XCTAssertNotEqual(ClipboardKeyAccessFailure.keyUnavailable.rawValue,
                          ClipboardKeyAccessFailure.keychainUnavailable.rawValue)
        XCTAssertNil(ClipboardKeyAccessFailure(rawValue: 0))
        XCTAssertNil(ClipboardKeyAccessFailure(rawValue: -1))
    }

    func testRequirementBindsExactIdentifierAndNormalizesLeafFingerprint() throws {
        let fingerprint = "0123456789abcdef0123456789abcdef01234567"
        let requirement = try ClipboardCodeSigning.requirement(identifier: ClipboardKeyService.hostID,
                                                              certificateSHA1: fingerprint)
        XCTAssertEqual(requirement,
                       "identifier \"com.oiloil.find\" and certificate leaf = H\"\(fingerprint.uppercased())\"")
        let helperRequirement = try ClipboardCodeSigning.requirement(identifier: ClipboardKeyService.serviceID,
                                                                    certificateSHA1: fingerprint)
        XCTAssertNotEqual(requirement, helperRequirement)
    }

    func testMalformedOrInjectedRequirementInputsAreRejected() {
        let fingerprint = String(repeating: "A", count: 40)
        for identifier in ["", "com.oiloil.find\" or true", "com.oiloil.find\n"] {
            XCTAssertThrowsError(try ClipboardCodeSigning.requirement(identifier: identifier,
                                                                     certificateSHA1: fingerprint)) { error in
                guard case ClipboardCodeSigningFailure.invalidRequirement = error else {
                    return XCTFail("Expected invalidRequirement, got \(error)")
                }
            }
        }
        for invalidFingerprint in ["", String(repeating: "A", count: 39), String(repeating: "A", count: 41),
                                   String(repeating: "G", count: 40), fingerprint + "\" or true"] {
            XCTAssertThrowsError(try ClipboardCodeSigning.requirement(identifier: ClipboardKeyService.hostID,
                                                                     certificateSHA1: invalidFingerprint))
        }
    }

    func testUnsignedAdHocAndMalformedIdentityMetadataAreRejected() {
        let identifier = kSecCodeInfoIdentifier as String
        let certificates = kSecCodeInfoCertificates as String
        let information: [[String: Any]] = [
            [:],
            [identifier: ClipboardKeyService.hostID],
            [identifier: ClipboardKeyService.hostID, certificates: [SecCertificate]()],
            [identifier: ClipboardKeyService.hostID, certificates: ["not a certificate"]],
            [identifier: 1, certificates: [SecCertificate]()]
        ]
        for value in information {
            XCTAssertThrowsError(try ClipboardCodeSigning.identity(signingInformation: value)) { error in
                guard case ClipboardCodeSigningFailure.invalidIdentity = error else {
                    return XCTFail("Expected invalidIdentity, got \(error)")
                }
            }
        }
    }
}
