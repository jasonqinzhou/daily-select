import Foundation

public func photoAnalysisPixelSizes(maximum: Int) -> [Int] {
    precondition(maximum > 0)
    let candidates = [maximum, min(maximum, 2_048), min(maximum, 1_536), min(maximum, 1_024)]
    var seen: Set<Int> = []
    return candidates.filter { seen.insert($0).inserted }
}

public struct SourceFingerprint: Codable, Equatable, Sendable {
    public let byteSize: Int64
    public let modificationTime: TimeInterval

    public init(byteSize: Int64, modificationTime: TimeInterval) {
        self.byteSize = byteSize
        self.modificationTime = modificationTime
    }
}

public func checkpointMatches(
    stored: SourceFingerprint?,
    current: SourceFingerprint
) -> Bool {
    stored == current
}

public func batchSlices<T>(_ items: [T], batchSize: Int) -> [ArraySlice<T>] {
    precondition(batchSize > 0)
    return stride(from: 0, to: items.count, by: batchSize).map { start in
        items[start..<min(start + batchSize, items.count)]
    }
}

public enum FaceAppearance: String, Sendable {
    case noFaceDetected = "no-face-detected"
    case noEyewear = "no-eyewear"
    case eyewear
}

public func faceAppearance(
    faceCount: Int,
    eyewearConfidence: Float,
    threshold: Float = 0.45
) -> FaceAppearance {
    guard faceCount > 0 else { return .noFaceDetected }
    return eyewearConfidence >= threshold ? .eyewear : .noEyewear
}

public func dailyOutputDirectory(outputRoot: URL, dateKey: String) -> URL {
    outputRoot.appendingPathComponent(dateKey, isDirectory: true)
}

public func burstRepresentativeIndices(
    faceCounts: [Int],
    appearances: [FaceAppearance],
    distances: [[Float?]],
    appearanceMinimumGroupSize: Int = 4,
    distinctMinimumGroupSize: Int = 8,
    distinctDistance: Float = 0.25
) -> [Int] {
    let count = min(faceCounts.count, appearances.count, distances.count)
    guard count > 0 else { return [] }
    var chosen = [0]

    if count >= appearanceMinimumGroupSize, faceCounts[0] > 0,
       let alternate = (1..<count).first(where: {
           faceCounts[$0] > 0 && appearances[$0] != appearances[0]
       }) {
        chosen.append(alternate)
    }

    if count >= distinctMinimumGroupSize,
       let distinct = (1..<count).first(where: { candidateIndex in
           guard !chosen.contains(candidateIndex), distances[candidateIndex].count >= count else { return false }
           return chosen.allSatisfy { selectedIndex in
               guard let distance = distances[candidateIndex][selectedIndex] else { return false }
               return distance >= distinctDistance
           }
       }) {
        chosen.append(distinct)
    }

    return chosen
}
