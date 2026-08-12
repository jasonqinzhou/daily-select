import AVFoundation
import DailySelectCore
import Foundation
import ImageIO
import Vision

private let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp"
]
private let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

enum MediaKind: String, Codable {
    case image
    case video
}

struct LabelScore: Codable {
    let label: String
    let confidence: Float
}

enum AnalysisMode: String, Codable {
    case full
    case partial
    case basicFallback = "basic-fallback"
}

struct FrameAnalysis {
    let aesthetics: Float
    let isUtility: Bool
    let faceQuality: Float?
    let faceCount: Int
    let eyewearConfidence: Float
    let labels: [LabelScore]
    let featurePrint: VNFeaturePrintObservation?
    let analysisMode: AnalysisMode
}

final class Candidate {
    let sourceURL: URL
    let kind: MediaKind
    let captureDate: Date
    let byteSize: Int64
    let analysis: FrameAnalysis
    var topic = "Other Good Moments"
    var score: Float = 0
    var groupID = ""
    var selected = false
    var decision = "Not evaluated"
    var copiedTo: String?

    init(sourceURL: URL, kind: MediaKind, captureDate: Date, byteSize: Int64, analysis: FrameAnalysis) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.captureDate = captureDate
        self.byteSize = byteSize
        self.analysis = analysis
    }
}

struct Settings: Codable {
    let selectionRatio: Double
    let maximumPerTopic: Int
    let photoAnalysisMaxPixels: Int
    let nearDuplicateSeconds: Double
    let nearDuplicateDistance: Float
}

struct AssetRecord: Codable {
    let source: String
    let captureDate: String
    let mediaType: String
    let bytes: Int64
    let topic: String
    let aestheticScore: Float
    let faceQuality: Float?
    let faceCount: Int
    let eyewearConfidence: Float
    let appearanceVariant: String
    let utilityImage: Bool
    let labels: [LabelScore]
    let analysisMode: String
    let duplicateGroup: String
    let selected: Bool
    let decision: String
    let copiedTo: String?
}

struct Summary: Codable {
    let discovered: Int
    let analyzed: Int
    let selected: Int
    let skipped: Int
    let copied: Int
    let alreadyPresent: Int
    let failed: Int
    let degradedPhotos: Int
    let selectedByDateAndTopic: [String: [String: Int]]
}

struct RunManifest: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let inputRoot: String
    let outputRoot: String
    let dryRun: Bool
    let settings: Settings
    let summary: Summary
    let assets: [AssetRecord]
    let failures: [String]
}

struct Options {
    let input: URL
    let output: URL
    let dryRun: Bool
    let ratio: Double
    let maxPerTopic: Int
    let photoMaxPixels: Int
}

enum DailySelectError: Error, CustomStringConvertible {
    case usage(String)
    case invalidPath(String)
    case noMedia(String)

    var description: String {
        switch self {
        case .usage(let message), .invalidPath(let message), .noMedia(let message):
            return message
        }
    }
}

private let settingsNearDuplicateSeconds = 180.0
private let settingsNearDuplicateDistance: Float = 0.36
private let eyewearThreshold: Float = 0.45
private let distinctViewDistance: Float = 0.25
private let defaultPhotoMaxPixels = 2_048

func expandedURL(_ path: String) -> URL {
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
}

func parseOptions() throws -> Options {
    var positional: [String] = []
    var dryRun = false
    var ratio = 0.35
    var maxPerTopic = 12
    var photoMaxPixels = defaultPhotoMaxPixels
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    while let argument = iterator.next() {
        switch argument {
        case "--dry-run":
            dryRun = true
        case "--ratio":
            guard let value = iterator.next(), let parsed = Double(value), parsed > 0, parsed <= 1 else {
                throw DailySelectError.usage("--ratio must be greater than 0 and no more than 1")
            }
            ratio = parsed
        case "--max-per-topic":
            guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                throw DailySelectError.usage("--max-per-topic must be a positive integer")
            }
            maxPerTopic = parsed
        case "--photo-max-pixels":
            guard let value = iterator.next(), let parsed = Int(value), parsed >= 512 else {
                throw DailySelectError.usage("--photo-max-pixels must be an integer of at least 512")
            }
            photoMaxPixels = parsed
        case "--help", "-h":
            throw DailySelectError.usage(usage())
        default:
            if argument.hasPrefix("--") {
                throw DailySelectError.usage("Unknown option: \(argument)\n\n\(usage())")
            }
            positional.append(argument)
        }
    }

    guard positional.count == 1 || positional.count == 2 else {
        throw DailySelectError.usage(usage())
    }

    let input = expandedURL(positional[0])
    let output = positional.count == 2
        ? expandedURL(positional[1])
        : input.deletingLastPathComponent().appendingPathComponent("Daily Select", isDirectory: true)

    return Options(
        input: input,
        output: output,
        dryRun: dryRun,
        ratio: ratio,
        maxPerTopic: maxPerTopic,
        photoMaxPixels: photoMaxPixels
    )
}

func usage() -> String {
    """
    Usage: daily-select [options] INPUT_FOLDER [OUTPUT_FOLDER]

    Options:
      --dry-run                 Analyze and report without copying files
      --ratio NUMBER            Target fraction selected per topic (default: 0.35)
      --max-per-topic NUMBER    Maximum selected per date/topic (default: 12)
      --photo-max-pixels NUMBER Longest photo-analysis edge (default: 2048; minimum: 512)
      -h, --help                Show this help

    The input is always read-only. If OUTPUT_FOLDER is omitted, the tool creates
    a sibling folder named "Daily Select".
    """
}

func validatePaths(_ options: Options) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: options.input.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw DailySelectError.invalidPath("Input folder does not exist: \(options.input.path)")
    }

    let inputPath = options.input.path.hasSuffix("/") ? options.input.path : options.input.path + "/"
    let outputPath = options.output.path.hasSuffix("/") ? options.output.path : options.output.path + "/"
    if inputPath == outputPath || inputPath.hasPrefix(outputPath) || outputPath.hasPrefix(inputPath) {
        throw DailySelectError.invalidPath("Input and output folders must not overlap")
    }
}

func discoverMedia(in root: URL) throws -> [(URL, MediaKind)] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var media: [(URL, MediaKind)] = []
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true, values?.isHidden != true else { continue }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            media.append((url, .image))
        } else if videoExtensions.contains(ext) {
            media.append((url, .video))
        }
    }

    return media.sorted { $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending }
}

func dateFromFilename(_ filename: String) -> Date? {
    let pattern = #"(\d{8})[^0-9]?(\d{6})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
          let dateRange = Range(match.range(at: 1), in: filename),
          let timeRange = Range(match.range(at: 2), in: filename) else {
        return nil
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.date(from: String(filename[dateRange]) + String(filename[timeRange]))
}

func imageMetadataDate(_ url: URL) -> Date? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }

    var candidates: [String] = []
    if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String { candidates.append(original) }
        if let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String { candidates.append(digitized) }
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       let dateTime = tiff[kCGImagePropertyTIFFDateTime] as? String {
        candidates.append(dateTime)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return candidates.compactMap { formatter.date(from: $0) }.first
}

func captureDate(for url: URL, kind: MediaKind) -> Date {
    if kind == .image, let metadataDate = imageMetadataDate(url) { return metadataDate }
    if let filenameDate = dateFromFilename(url.lastPathComponent) { return filenameDate }

    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return values?.creationDate ?? values?.contentModificationDate ?? Date()
}

func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? 0)
}

struct FaceMetrics {
    let count: Int
    let maximumQuality: Float?
    let eyewearConfidence: Float
}

func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let intersection = first.intersection(second)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = first.width * first.height + second.width * second.height - intersectionArea
    return unionArea > 0 ? intersectionArea / unionArea : 0
}

func expandedFaceRect(_ rect: CGRect, within extent: CGRect) -> CGRect {
    let horizontalPadding = rect.width * 0.45
    let verticalPadding = rect.height * 0.45
    return rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding).intersection(extent)
}

func cropImage(_ image: CGImage, visionRect: CGRect) -> CGImage? {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let bounded = visionRect.intersection(imageBounds)
    guard !bounded.isNull, !bounded.isEmpty else { return nil }

    // Vision rectangles use a lower-left origin. CGImage cropping uses the
    // underlying bitmap's upper-left origin, so flip the vertical coordinate.
    let cropRect = CGRect(
        x: bounded.minX,
        y: CGFloat(image.height) - bounded.maxY,
        width: bounded.width,
        height: bounded.height
    ).integral.intersection(imageBounds)
    return image.cropping(to: cropRect)
}

func detectFaceRects(in image: CGImage, seedFaces: [VNFaceObservation], useTiling: Bool) throws -> [CGRect] {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    var faces = seedFaces.map { VNImageRectForNormalizedRect($0.boundingBox, image.width, image.height) }
    guard useTiling else { return faces }

    let tileFraction: CGFloat = 0.45
    let positions: [CGFloat] = [0, 0.275, 0.55]
    for horizontalPosition in positions {
        for verticalPosition in positions {
            let tileRect = CGRect(
                x: width * horizontalPosition,
                y: height * verticalPosition,
                width: width * tileFraction,
                height: height * tileFraction
            )
            guard let tile = cropImage(image, visionRect: tileRect) else { continue }
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: tile).perform([request])

            for observation in request.results ?? [] {
                var faceRect = VNImageRectForNormalizedRect(observation.boundingBox, tile.width, tile.height)
                faceRect.origin.x += tileRect.origin.x
                faceRect.origin.y += tileRect.origin.y
                if !faces.contains(where: { intersectionOverUnion($0, faceRect) > 0.35 }) {
                    faces.append(faceRect)
                }
            }
        }
    }
    return faces
}

func analyzeFaces(in image: CGImage, seedFaces: [VNFaceObservation], useTiling: Bool) throws -> FaceMetrics {
    let faceRects = try detectFaceRects(in: image, seedFaces: seedFaces, useTiling: useTiling)
    guard !faceRects.isEmpty else { return FaceMetrics(count: 0, maximumQuality: nil, eyewearConfidence: 0) }

    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var qualities: [Float] = []
    var maximumEyewearConfidence: Float = 0

    for rect in faceRects {
        let cropRect = expandedFaceRect(rect, within: imageBounds)
        guard let crop = cropImage(image, visionRect: cropRect) else { continue }
        let quality = VNDetectFaceCaptureQualityRequest()
        let classification = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: crop).perform([quality])
        try VNImageRequestHandler(cgImage: crop).perform([classification])
        qualities.append(contentsOf: (quality.results ?? []).compactMap(\.faceCaptureQuality))

        for label in classification.results ?? [] {
            let identifier = label.identifier.lowercased()
            if identifier == "sunglasses" || identifier == "eyeglasses" {
                maximumEyewearConfidence = max(maximumEyewearConfidence, label.confidence)
            }
        }
    }

    return FaceMetrics(
        count: faceRects.count,
        maximumQuality: qualities.max(),
        eyewearConfidence: maximumEyewearConfidence
    )
}

func analyzeFrame(_ cgImage: CGImage) throws -> FrameAnalysis {
    let aesthetics = VNCalculateImageAestheticsScoresRequest()
    let classifications = VNClassifyImageRequest()
    let faces = VNDetectFaceRectanglesRequest()
    let feature = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage)
    try handler.perform([aesthetics, classifications, faces, feature])

    let aestheticsResult = aesthetics.results?.first
    let labels = (classifications.results ?? [])
        .filter { $0.confidence >= 0.08 }
        .prefix(15)
        .map { LabelScore(label: $0.identifier, confidence: $0.confidence) }
    let peopleSignal = labelMatches(
        labels,
        ["person", "people", "human", "portrait", "selfie", "family", "crowd", "child", "baby"]
    )
    let faceMetrics = try analyzeFaces(
        in: cgImage,
        seedFaces: faces.results ?? [],
        useTiling: peopleSignal || !(faces.results ?? []).isEmpty
    )

    return FrameAnalysis(
        aesthetics: aestheticsResult?.overallScore ?? 0,
        isUtility: aestheticsResult?.isUtility ?? false,
        faceQuality: faceMetrics.maximumQuality,
        faceCount: faceMetrics.count,
        eyewearConfidence: faceMetrics.eyewearConfidence,
        labels: labels,
        featurePrint: feature.results?.first,
        analysisMode: .full
    )
}

func photoThumbnail(_ url: URL, maximumPixelSize: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw DailySelectError.invalidPath("Cannot decode image: \(url.path)")
    }

    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldAllowFloat: false
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        throw DailySelectError.invalidPath("Cannot create analysis thumbnail: \(url.path)")
    }
    return image
}

func performVisionRequest(_ request: VNRequest, on image: CGImage) throws {
    try VNImageRequestHandler(cgImage: image).perform([request])
}

func analyzePhotoFrame(_ cgImage: CGImage, bestEffort: Bool) throws -> FrameAnalysis {
    let aesthetics = VNCalculateImageAestheticsScoresRequest()
    let classifications = VNClassifyImageRequest()
    let faces = VNDetectFaceRectanglesRequest()
    let feature = VNGenerateImageFeaturePrintRequest()
    let requests: [VNRequest] = [aesthetics, classifications, faces, feature]
    var completedRequests = 0
    var firstError: Error?

    // Run requests one at a time to keep Vision's peak temporary-buffer use low.
    for request in requests {
        do {
            try performVisionRequest(request, on: cgImage)
            completedRequests += 1
        } catch {
            firstError = firstError ?? error
            if !bestEffort { throw error }
        }
    }

    let aestheticsResult = aesthetics.results?.first
    let labels = (classifications.results ?? [])
        .filter { $0.confidence >= 0.08 }
        .prefix(15)
        .map { LabelScore(label: $0.identifier, confidence: $0.confidence) }
    let peopleSignal = labelMatches(
        labels,
        ["person", "people", "human", "portrait", "selfie", "family", "crowd", "child", "baby"]
    )

    var faceMetrics = FaceMetrics(
        count: faces.results?.count ?? 0,
        maximumQuality: nil,
        eyewearConfidence: 0
    )
    var faceAnalysisFailed = false
    if faces.results != nil {
        do {
            faceMetrics = try analyzeFaces(
                in: cgImage,
                seedFaces: faces.results ?? [],
                useTiling: peopleSignal || !(faces.results ?? []).isEmpty
            )
        } catch {
            firstError = firstError ?? error
            faceAnalysisFailed = true
            if !bestEffort { throw error }
        }
    }

    if !bestEffort, let firstError { throw firstError }
    let mode: AnalysisMode
    if completedRequests == requests.count && !faceAnalysisFailed {
        mode = .full
    } else if completedRequests > 0 {
        mode = .partial
    } else {
        mode = .basicFallback
    }

    return FrameAnalysis(
        aesthetics: aestheticsResult?.overallScore ?? 0,
        isUtility: aestheticsResult?.isUtility ?? false,
        faceQuality: faceMetrics.maximumQuality,
        faceCount: faceMetrics.count,
        eyewearConfidence: faceMetrics.eyewearConfidence,
        labels: labels,
        featurePrint: feature.results?.first,
        analysisMode: mode
    )
}

func analyzeImage(_ url: URL, maximumPixelSize: Int) throws -> FrameAnalysis {
    let sizes = photoAnalysisPixelSizes(maximum: maximumPixelSize)
    var lastError: Error?

    for (index, size) in sizes.enumerated() {
        do {
            return try autoreleasepool {
                let image = try photoThumbnail(url, maximumPixelSize: size)
                return try analyzePhotoFrame(image, bestEffort: index == sizes.count - 1)
            }
        } catch {
            lastError = error
        }
    }

    throw lastError ?? DailySelectError.invalidPath("Cannot analyze image: \(url.path)")
}

func analyzeVideo(_ url: URL) async throws -> FrameAnalysis {
    let asset = AVURLAsset(url: url)
    let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
    guard durationSeconds.isFinite, durationSeconds > 0 else {
        throw DailySelectError.invalidPath("Cannot determine video duration: \(url.path)")
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1920, height: 1920)

    let fractions: [Double] = durationSeconds < 3 ? [0.5] : [0.15, 0.5, 0.85]
    var frames: [FrameAnalysis] = []
    for fraction in fractions {
        let time = CMTime(seconds: durationSeconds * fraction, preferredTimescale: 600)
        let image = try await generator.image(at: time).image
        frames.append(try analyzeFrame(image))
    }

    let combinedLabels = Dictionary(grouping: frames.flatMap(\.labels), by: \.label)
        .map { LabelScore(label: $0.key, confidence: $0.value.map(\.confidence).max() ?? 0) }
        .sorted { $0.confidence > $1.confidence }
        .prefix(15)

    return FrameAnalysis(
        aesthetics: frames.map(\.aesthetics).reduce(0, +) / Float(frames.count),
        isUtility: frames.allSatisfy(\.isUtility),
        faceQuality: frames.compactMap(\.faceQuality).max(),
        faceCount: frames.map(\.faceCount).max() ?? 0,
        eyewearConfidence: frames.map(\.eyewearConfidence).max() ?? 0,
        labels: Array(combinedLabels),
        featurePrint: frames[frames.count / 2].featurePrint,
        analysisMode: .full
    )
}

func labelMatches(_ labels: [LabelScore], _ terms: Set<String>) -> Bool {
    labels.contains { observation in
        let normalized = observation.label.lowercased().replacingOccurrences(of: "_", with: " ")
        return terms.contains { normalized == $0 || normalized.contains($0) }
    }
}

func assignTopic(to candidate: Candidate) -> String {
    let labels = candidate.analysis.labels
    let people: Set<String> = ["person", "people", "human", "portrait", "selfie", "family", "crowd", "child", "baby"]
    let food: Set<String> = ["food", "meal", "dish", "restaurant", "cuisine", "plate", "seafood", "meat", "vegetable", "fruit", "dessert", "drink", "beverage", "coffee"]
    let animals: Set<String> = ["animal", "dog", "cat", "bird", "wildlife", "pet", "horse"]
    let mountainsAndLakes: Set<String> = ["mountain", "lake", "water body", "water_body", "alpine", "summit", "volcano", "glacier"]
    let nature: Set<String> = ["nature", "outdoor", "landscape", "forest", "tree", "plant", "flower", "garden", "park", "river", "waterfall", "ocean", "beach", "shore", "sky", "cloud"]
    let travel: Set<String> = ["building", "architecture", "city", "street", "road", "vehicle", "car", "bus", "train", "boat", "aircraft", "tower", "bridge", "monument", "museum", "sign", "trail"]
    let documents: Set<String> = ["document", "text", "receipt", "screen", "screenshot", "menu", "paper"]

    if candidate.analysis.faceCount > 0 || labelMatches(labels, people) { return "People & Portraits" }
    if labelMatches(labels, food) { return "Food & Dining" }
    if labelMatches(labels, animals) { return "Animals & Pets" }
    if labelMatches(labels, mountainsAndLakes) { return "Mountains & Lakes" }
    if labelMatches(labels, nature) { return "Nature & Outdoors" }
    if labelMatches(labels, travel) { return "Travel & Places" }
    if candidate.analysis.isUtility || labelMatches(labels, documents) { return "Documents & Screens" }
    return "Other Good Moments"
}

func candidateScore(_ candidate: Candidate) -> Float {
    let faceBonus = (candidate.analysis.faceQuality ?? 0) * 0.16
    let videoBonus: Float = candidate.kind == .video ? 0.10 : 0
    let utilityPenalty: Float = candidate.analysis.isUtility ? 0.40 : 0
    return candidate.analysis.aesthetics + faceBonus + videoBonus - utilityPenalty
}

func appearanceVariant(_ candidate: Candidate) -> String {
    faceAppearance(
        faceCount: candidate.analysis.faceCount,
        eyewearConfidence: candidate.analysis.eyewearConfidence,
        threshold: eyewearThreshold
    ).rawValue
}

final class UnionFind {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    func find(_ value: Int) -> Int {
        if parent[value] != value { parent[value] = find(parent[value]) }
        return parent[value]
    }

    func union(_ first: Int, _ second: Int) {
        let a = find(first)
        let b = find(second)
        if a != b { parent[b] = a }
    }
}

func featureDistance(_ first: Candidate, _ second: Candidate) -> Float? {
    guard let firstPrint = first.analysis.featurePrint, let secondPrint = second.analysis.featurePrint else { return nil }
    var distance: Float = 0
    do {
        try firstPrint.computeDistance(&distance, to: secondPrint)
        return distance
    } catch {
        return nil
    }
}

func groupNearDuplicates(_ candidates: [Candidate]) -> [[Candidate]] {
    let unionFind = UnionFind(count: candidates.count)
    let calendar = Calendar.current

    for firstIndex in candidates.indices {
        for secondIndex in candidates.indices where secondIndex > firstIndex {
            let first = candidates[firstIndex]
            let second = candidates[secondIndex]
            guard first.kind == second.kind,
                  first.topic == second.topic,
                  calendar.isDate(first.captureDate, inSameDayAs: second.captureDate),
                  abs(first.captureDate.timeIntervalSince(second.captureDate)) <= settingsNearDuplicateSeconds,
                  let distance = featureDistance(first, second),
                  distance <= settingsNearDuplicateDistance else {
                continue
            }
            unionFind.union(firstIndex, secondIndex)
        }
    }

    var grouped: [Int: [Candidate]] = [:]
    for index in candidates.indices {
        grouped[unionFind.find(index), default: []].append(candidates[index])
    }

    return grouped.values
        .map { $0.sorted { $0.score > $1.score } }
        .sorted { ($0.first?.captureDate ?? .distantPast) < ($1.first?.captureDate ?? .distantPast) }
}

func dateKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func isoDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func groupRepresentatives(_ group: [Candidate]) -> [(candidate: Candidate, reason: String)] {
    guard !group.isEmpty else { return [] }
    var distances = Array(
        repeating: Array<Float?>(repeating: nil, count: group.count),
        count: group.count
    )
    for firstIndex in group.indices {
        for secondIndex in group.indices where secondIndex > firstIndex {
            let distance = featureDistance(group[firstIndex], group[secondIndex])
            distances[firstIndex][secondIndex] = distance
            distances[secondIndex][firstIndex] = distance
        }
    }

    let appearances = group.map {
        faceAppearance(
            faceCount: $0.analysis.faceCount,
            eyewearConfidence: $0.analysis.eyewearConfidence,
            threshold: eyewearThreshold
        )
    }
    let indices = burstRepresentativeIndices(
        faceCounts: group.map { $0.analysis.faceCount },
        appearances: appearances,
        distances: distances,
        distinctDistance: distinctViewDistance
    )

    return indices.enumerated().map { position, index in
        let reason: String
        if position == 0 {
            reason = group.count > 1
                ? "Best-quality representative of \(group.count) similar captures"
                : "Unique capture eligible for selection"
        } else if appearances[index] != appearances[0] {
            reason = "Strong alternate face-appearance variant from the same burst"
        } else {
            reason = "Additional visually distinct high-quality view from a large burst"
        }
        return (group[index], reason)
    }
}

func selectCandidates(_ candidates: [Candidate], ratio: Double, maxPerTopic: Int) {
    let groups = groupNearDuplicates(candidates)
    var representatives: [Candidate] = []

    for (index, group) in groups.enumerated() {
        let groupID = String(format: "group-%04d", index + 1)
        for candidate in group { candidate.groupID = groupID }

        let chosen = groupRepresentatives(group)
        for selection in chosen {
            representatives.append(selection.candidate)
            selection.candidate.decision = selection.reason
        }

        for candidate in group where !chosen.contains(where: { $0.candidate === candidate }) {
            candidate.decision = "Skipped as a lower-ranked similar capture"
        }
    }

    let eligible = representatives.filter { candidate in
        if candidate.analysis.isUtility && candidate.analysis.faceCount == 0 {
            candidate.decision = "Skipped as a utility image such as a document, receipt, or screen"
            return false
        }
        if candidate.analysis.aesthetics < -0.35 {
            candidate.decision = "Skipped because the visual-quality score was very low"
            return false
        }
        return true
    }

    let buckets = Dictionary(grouping: eligible) { "\(dateKey($0.captureDate))\u{0}\($0.topic)" }
    for bucket in buckets.values {
        let originalCount = candidates.filter {
            dateKey($0.captureDate) == dateKey(bucket[0].captureDate) && $0.topic == bucket[0].topic
        }.count
        let desired = min(maxPerTopic, max(min(2, bucket.count), Int(ceil(Double(originalCount) * ratio))))
        let ranked = bucket.sorted {
            if $0.kind != $1.kind { return $0.kind == .video }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.captureDate < $1.captureDate
        }

        for candidate in ranked.prefix(desired) {
            candidate.selected = true
            candidate.decision += "; selected within the date/topic quota"
        }
        for candidate in ranked.dropFirst(desired) {
            candidate.decision = "Skipped after higher-quality, more diverse selections filled the date/topic quota"
        }
    }
}

func destinationForCopy(source: URL, directory: URL) -> (url: URL, alreadyPresent: Bool) {
    let manager = FileManager.default
    let initial = directory.appendingPathComponent(source.lastPathComponent)
    if !manager.fileExists(atPath: initial.path) { return (initial, false) }
    if manager.contentsEqual(atPath: source.path, andPath: initial.path) { return (initial, true) }

    let stem = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var counter = 2
    while true {
        let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
        let candidate = directory.appendingPathComponent(name)
        if !manager.fileExists(atPath: candidate.path) { return (candidate, false) }
        if manager.contentsEqual(atPath: source.path, andPath: candidate.path) { return (candidate, true) }
        counter += 1
    }
}

func writeManifest(_ manifest: RunManifest, output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    try data.write(to: output.appendingPathComponent("_daily-select-manifest.json"), options: .atomic)
}

func run() async throws {
    let options = try parseOptions()
    try validatePaths(options)
    let discovered = try discoverMedia(in: options.input)
    guard !discovered.isEmpty else {
        throw DailySelectError.noMedia("No supported photos or videos found in \(options.input.path)")
    }

    print("Daily Select")
    print("Input:  \(options.input.path)")
    print("Output: \(options.output.path)\(options.dryRun ? " (dry run)" : "")")
    print("Found \(discovered.count) supported media files")

    var candidates: [Candidate] = []
    var failures: [String] = []
    for (index, item) in discovered.enumerated() {
        let (url, kind) = item
        do {
            let analysis: FrameAnalysis
            if kind == .image {
                analysis = try analyzeImage(url, maximumPixelSize: options.photoMaxPixels)
            } else {
                analysis = try await analyzeVideo(url)
            }
            let candidate = Candidate(
                sourceURL: url,
                kind: kind,
                captureDate: captureDate(for: url, kind: kind),
                byteSize: fileSize(url),
                analysis: analysis
            )
            candidate.topic = assignTopic(to: candidate)
            candidate.score = candidateScore(candidate)
            candidates.append(candidate)
        } catch {
            failures.append("\(url.path): \(error)")
        }
        print("Analyzed \(index + 1)/\(discovered.count)", terminator: "\r")
        fflush(stdout)
    }
    print(String(repeating: " ", count: 40), terminator: "\r")

    selectCandidates(candidates, ratio: options.ratio, maxPerTopic: options.maxPerTopic)

    var copied = 0
    var alreadyPresent = 0
    if !options.dryRun {
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        for candidate in candidates.filter(\.selected).sorted(by: { $0.captureDate < $1.captureDate }) {
            let directory = dailyOutputDirectory(
                outputRoot: options.output,
                dateKey: dateKey(candidate.captureDate)
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = destinationForCopy(source: candidate.sourceURL, directory: directory)
            if destination.alreadyPresent {
                alreadyPresent += 1
            } else {
                try FileManager.default.copyItem(at: candidate.sourceURL, to: destination.url)
                copied += 1
            }
            candidate.copiedTo = destination.url.path
        }
    }

    var selectedByDateAndTopic: [String: [String: Int]] = [:]
    for candidate in candidates.filter(\.selected) {
        selectedByDateAndTopic[dateKey(candidate.captureDate), default: [:]][candidate.topic, default: 0] += 1
    }

    let records = candidates.sorted { $0.captureDate < $1.captureDate }.map { candidate in
        AssetRecord(
            source: candidate.sourceURL.path,
            captureDate: isoDate(candidate.captureDate),
            mediaType: candidate.kind.rawValue,
            bytes: candidate.byteSize,
            topic: candidate.topic,
            aestheticScore: candidate.analysis.aesthetics,
            faceQuality: candidate.analysis.faceQuality,
            faceCount: candidate.analysis.faceCount,
            eyewearConfidence: candidate.analysis.eyewearConfidence,
            appearanceVariant: appearanceVariant(candidate),
            utilityImage: candidate.analysis.isUtility,
            labels: candidate.analysis.labels,
            analysisMode: candidate.analysis.analysisMode.rawValue,
            duplicateGroup: candidate.groupID,
            selected: candidate.selected,
            decision: candidate.decision,
            copiedTo: candidate.copiedTo
        )
    }

    let summary = Summary(
        discovered: discovered.count,
        analyzed: candidates.count,
        selected: candidates.filter(\.selected).count,
        skipped: candidates.filter { !$0.selected }.count,
        copied: copied,
        alreadyPresent: alreadyPresent,
        failed: failures.count,
        degradedPhotos: candidates.filter {
            $0.kind == .image && $0.analysis.analysisMode != .full
        }.count,
        selectedByDateAndTopic: selectedByDateAndTopic
    )
    let manifest = RunManifest(
        schemaVersion: 3,
        generatedAt: isoDate(Date()),
        inputRoot: options.input.path,
        outputRoot: options.output.path,
        dryRun: options.dryRun,
        settings: Settings(
            selectionRatio: options.ratio,
            maximumPerTopic: options.maxPerTopic,
            photoAnalysisMaxPixels: options.photoMaxPixels,
            nearDuplicateSeconds: settingsNearDuplicateSeconds,
            nearDuplicateDistance: settingsNearDuplicateDistance
        ),
        summary: summary,
        assets: records,
        failures: failures
    )

    if !options.dryRun {
        try writeManifest(manifest, output: options.output)
    }

    print("Analyzed: \(summary.analyzed), selected: \(summary.selected), skipped: \(summary.skipped), failed: \(summary.failed)")
    if summary.degradedPhotos > 0 {
        print("Photos kept with partial or basic fallback analysis: \(summary.degradedPhotos)")
    }
    if !options.dryRun {
        print("Copied: \(summary.copied), already present: \(summary.alreadyPresent)")
    }
    for date in selectedByDateAndTopic.keys.sorted() {
        print("\(date):")
        for (topic, count) in (selectedByDateAndTopic[date] ?? [:]).sorted(by: { $0.key < $1.key }) {
            print("  \(topic): \(count)")
        }
    }
    if !failures.isEmpty {
        print("Failures:")
        for failure in failures { print("  \(failure)") }
    }
}

Task {
    do {
        try await run()
        exit(0)
    } catch let error as DailySelectError {
        fputs("Error: \(error.description)\n", stderr)
        exit(2)
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
