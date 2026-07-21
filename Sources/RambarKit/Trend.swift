import Foundation

/// Least-squares slope over (unix seconds, bytes) points, in bytes/second.
/// Returns nil below 6 points — too few samples to call a direction.
public func footprintSlope(_ points: [(time: Double, bytes: UInt64)]) -> Double? {
    guard points.count >= 6 else { return nil }
    let n = Double(points.count)
    let t0 = points[0].time
    var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
    for point in points {
        let x = point.time - t0
        let y = Double(point.bytes)
        sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
    }
    let denominator = n * sumXX - sumX * sumX
    guard denominator > 0 else { return nil }
    return (n * sumXY - sumX * sumY) / denominator
}

/// A session is "rising" when it grows at ≥ 1 MB/min sustained across the
/// sampled window.
public func isRising(slopeBytesPerSecond: Double?) -> Bool {
    guard let slope = slopeBytesPerSecond else { return false }
    return slope >= Double(1_048_576) / 60.0
}
