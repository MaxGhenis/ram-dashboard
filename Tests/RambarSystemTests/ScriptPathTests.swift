import XCTest
@testable import RambarSystem

final class ScriptPathTests: XCTestCase {
    func testFirstNonFlagArgumentWins() {
        XCTAssertEqual(
            scriptPath(fromArguments: ["node", "/x/mcp/index.js", "--port", "3000"]),
            "/x/mcp/index.js"
        )
        XCTAssertEqual(
            scriptPath(fromArguments: ["node", "--max-old-space-size=4096", "/x/server.js"]),
            "/x/server.js"
        )
    }

    func testNoScriptReturnsNil() {
        XCTAssertNil(scriptPath(fromArguments: ["node"]))
        XCTAssertNil(scriptPath(fromArguments: ["node", "--version"]))
    }

    func testEnvAssignmentsSkipped() {
        XCTAssertEqual(
            scriptPath(fromArguments: ["python", "PYTHONHASHSEED=0", "/x/train.py"]),
            "/x/train.py"
        )
    }
}
