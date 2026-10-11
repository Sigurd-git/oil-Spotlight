import XCTest
@testable import OilFindApp

final class ClipboardKeyServiceClientTests: XCTestCase {
    func testTimeoutRejectsLateReplyAndDoesNotAffectNextRequest() throws {
        let expired = ClipboardKeyServiceRequest()
        XCTAssertThrowsError(try expired.wait(timeout: 0)) { error in
            XCTAssertEqual(error as? ClipboardKeyAccessFailure, .keychainUnavailable)
        }
        expired.resolve(data: Data(repeating: 7, count: 32), failure: nil)
        XCTAssertThrowsError(try expired.wait(timeout: 0))
        let next = ClipboardKeyServiceRequest()
        let bytes = Data(repeating: 8, count: 32)
        next.resolve(data: bytes, failure: nil)
        XCTAssertEqual(try next.wait(timeout: 0.1), bytes)
    }

    func testFailureWinsOverReplyAndMalformedKeyIsRejected() {
        let failed = ClipboardKeyServiceRequest()
        failed.resolve(data: nil, failure: .keychainUnavailable)
        failed.resolve(data: Data(repeating: 7, count: 32), failure: nil)
        XCTAssertThrowsError(try failed.wait(timeout: 0.1)) { error in
            XCTAssertEqual(error as? ClipboardKeyAccessFailure, .keychainUnavailable)
        }
        for size in [0, 31, 33] {
            let malformed = ClipboardKeyServiceRequest()
            malformed.resolve(data: Data(repeating: 7, count: size), failure: nil)
            XCTAssertThrowsError(try malformed.wait(timeout: 0.1)) { error in
                XCTAssertEqual(error as? ClipboardKeyAccessFailure, .keyUnavailable)
            }
        }
    }
}
