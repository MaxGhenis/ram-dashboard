import XCTest
@testable import RambarKit

final class AgentFamilyTests: XCTestCase {
    func testDesktopHostedEngineMatchesClaude() {
        XCTAssertEqual(agentFamily(forExecutablePath: Fixture.desktopEngine), .claude)
    }

    func testStandaloneCLIMatchesClaude() {
        XCTAssertEqual(agentFamily(forExecutablePath: Fixture.cliEngine), .claude)
        XCTAssertEqual(agentFamily(forExecutablePath: "/opt/homebrew/bin/claude"), .claude)
    }

    func testClaudeDesktopUIDoesNotMatch() {
        XCTAssertNil(agentFamily(forExecutablePath: Fixture.claudeDesktopUI))
    }

    func testClaudeDesktopFrameworksHelperDoesNotMatch() {
        // Full resolved paths mean the space in "Claude Helper (Renderer)"
        // cannot truncate into a false "claude" basename — the v1 bug.
        XCTAssertNil(agentFamily(forExecutablePath: Fixture.claudeDesktopHelper))
    }

    func testDisclaimerWrapperDoesNotMatch() {
        XCTAssertNil(agentFamily(forExecutablePath: Fixture.disclaimer))
    }

    func testCodexAndGeminiMatch() {
        XCTAssertEqual(agentFamily(forExecutablePath: Fixture.codexEngine), .codex)
        XCTAssertEqual(agentFamily(forExecutablePath: "/usr/local/bin/gemini"), .gemini)
    }

    func testUnrelatedBinariesDoNotMatch() {
        XCTAssertNil(agentFamily(forExecutablePath: Fixture.node))
        XCTAssertNil(agentFamily(forExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    }
}
