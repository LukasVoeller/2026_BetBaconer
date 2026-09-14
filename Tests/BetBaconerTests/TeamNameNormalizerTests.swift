#if canImport(XCTest)
import XCTest
@testable import BetBaconer

final class TeamNameNormalizerTests: XCTestCase {
    func testNormalizesBundesligaClubNumbers() {
        XCTAssertEqual(normalizedTeamKey("SV 07 Elversberg", "Bayer 04 Leverkusen"),
                       normalizedTeamKey("SV Elversberg", "Bayer Leverkusen"))
    }
}
#endif
