import XCTest
@testable import MacParakeet

final class LegacyLicensingPolicyTests: XCTestCase {
    func testDevelopmentBundleSkipsLegacyLicensingKeychain() {
        XCTAssertFalse(LegacyLicensingPolicy.usesKeychain(bundleIdentifier: "com.macparakeet.dev"))
    }

    func testProductionAndUnknownBundlesKeepLegacyLicensingBehavior() {
        XCTAssertTrue(LegacyLicensingPolicy.usesKeychain(bundleIdentifier: "com.macparakeet.MacParakeet"))
        XCTAssertTrue(LegacyLicensingPolicy.usesKeychain(bundleIdentifier: nil))
    }
}
