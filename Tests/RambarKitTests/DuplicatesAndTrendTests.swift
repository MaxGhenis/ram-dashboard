import XCTest
@testable import RambarKit

final class DuplicatesAndTrendTests: XCTestCase {
    func testDuplicateMcpServersAcrossSessionsAreReported() {
        var samples = Fixture.machine
        let script = "/Users/dev/.local/share/mcp/server-everything/index.js"
        samples.append(Fixture.process(106, 102, Fixture.node, script: script, mb: 150))
        samples.append(Fixture.process(113, 111, Fixture.node, script: script, mb: 150))
        samples.append(Fixture.process(204, 202, Fixture.node, script: script, mb: 150))

        let groups = findDuplicates(in: buildSessionTrees(samples))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 3)
        XCTAssertEqual(groups[0].footprint, 450 * 1_048_576)
        XCTAssertEqual(groups[0].basename, "index.js")
    }

    func testInterpreterBinaryAloneDoesNotMergeDistinctScripts() {
        // Three node children running three different scripts must not group.
        let groups = findDuplicates(in: buildSessionTrees(Fixture.machine))
        XCTAssertTrue(groups.isEmpty)
    }

    func testSlopeOnLinearGrowth() {
        // +1 MB every 30 seconds → 2 MB/min.
        let points = (0..<10).map { (time: Double($0) * 30, bytes: UInt64($0) * 1_048_576) }
        let slope = footprintSlope(points)
        XCTAssertEqual(slope ?? 0, Double(1_048_576) / 30.0, accuracy: 1.0)
        XCTAssertTrue(isRising(slopeBytesPerSecond: slope))
    }

    func testFlatSeriesIsNotRising() {
        let points = (0..<10).map { (time: Double($0) * 30, bytes: UInt64(500) * 1_048_576) }
        XCTAssertFalse(isRising(slopeBytesPerSecond: footprintSlope(points)))
    }

    func testTooFewPointsReturnsNil() {
        let points = (0..<5).map { (time: Double($0), bytes: UInt64($0)) }
        XCTAssertNil(footprintSlope(points))
    }

    func testFormatBytes() {
        XCTAssertEqual(formatBytes(512), "512 B")
        XCTAssertEqual(formatBytes(200 * 1_048_576), "200 MB")
        XCTAssertEqual(formatBytes(3_435_973_837), "3.2 GB")
    }
}
