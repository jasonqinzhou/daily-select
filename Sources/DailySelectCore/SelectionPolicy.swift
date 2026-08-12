import Foundation

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
