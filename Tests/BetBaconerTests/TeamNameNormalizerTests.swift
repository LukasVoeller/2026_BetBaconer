import Foundation
import Testing
@testable import BetBaconer

final class TeamNameNormalizerTests {

    @Test
    func testNormalizesBundesligaClubNumbers() {
        XCTAssertEqual(normalizedTeamKey("SV 07 Elversberg", "Bayer 04 Leverkusen"),
                       normalizedTeamKey("SV Elversberg", "Bayer Leverkusen"))
    }
}
