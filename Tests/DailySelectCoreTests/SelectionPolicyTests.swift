import Foundation
import Testing
@testable import DailySelectCore

@Test func createsDescendingPhotoAnalysisRetrySizes() {
    #expect(photoAnalysisPixelSizes(maximum: 2_048) == [2_048, 1_536, 1_024])
    #expect(photoAnalysisPixelSizes(maximum: 1_536) == [1_536, 1_024])
    #expect(photoAnalysisPixelSizes(maximum: 1_024) == [1_024])
    #expect(photoAnalysisPixelSizes(maximum: 3_000) == [3_000, 2_048, 1_536, 1_024])
}

@Test func classifiesFaceAppearance() {
    #expect(faceAppearance(faceCount: 0, eyewearConfidence: 0.9) == .noFaceDetected)
    #expect(faceAppearance(faceCount: 3, eyewearConfidence: 0.004) == .noEyewear)
    #expect(faceAppearance(faceCount: 3, eyewearConfidence: 0.87) == .eyewear)
}

@Test func usesOneFlatFolderPerDay() {
    let root = URL(fileURLWithPath: "/tmp/Daily Select", isDirectory: true)
    let result = dailyOutputDirectory(outputRoot: root, dateKey: "2026-08-09")
    #expect(result.path == "/tmp/Daily Select/2026-08-09")
}

@Test func preservesAnAlternateEyewearAppearance() {
    let appearances: [FaceAppearance] = [.noEyewear, .noEyewear, .eyewear, .eyewear]
    let distances = Array(repeating: Array<Float?>(repeating: nil, count: 4), count: 4)
    let result = burstRepresentativeIndices(
        faceCounts: [3, 3, 3, 3],
        appearances: appearances,
        distances: distances
    )
    #expect(result == [0, 2])
}

@Test func rejectsAThirdViewThatIsStillTooSimilar() {
    let count = 8
    let appearances: [FaceAppearance] = [.noEyewear, .noEyewear, .eyewear, .eyewear, .eyewear, .eyewear, .eyewear, .eyewear]
    var distances = Array(repeating: Array<Float?>(repeating: nil, count: count), count: count)
    distances[1][0] = 0.18
    distances[2][0] = 0.40
    distances[3][0] = 0.31
    distances[3][2] = 0.29
    let result = burstRepresentativeIndices(
        faceCounts: Array(repeating: 3, count: count),
        appearances: appearances,
        distances: distances
    )
    #expect(result == [0, 2, 3])
}

@Test func dividesWorkIntoBoundedBatches() {
    let slices = batchSlices(Array(0..<2_501), batchSize: 1_000)
    #expect(slices.map(\.count) == [1_000, 1_000, 501])
    #expect(Array(slices[1].prefix(2)) == [1_000, 1_001])
}

@Test func checkpointInvalidatesAChangedSource() {
    let original = SourceFingerprint(byteSize: 42, modificationTime: 100)
    #expect(checkpointMatches(stored: original, current: original))
    #expect(!checkpointMatches(
        stored: original,
        current: SourceFingerprint(byteSize: 43, modificationTime: 100)
    ))
    #expect(!checkpointMatches(
        stored: original,
        current: SourceFingerprint(byteSize: 42, modificationTime: 101)
    ))
}
