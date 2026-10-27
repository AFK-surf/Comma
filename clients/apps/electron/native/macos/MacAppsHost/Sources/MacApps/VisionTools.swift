import CoreGraphics
import CoreImage
import Foundation
import MCP
import ScreenCaptureKit
import Vision

enum VisionTools {
    static let all: [ToolDefinition] = [
        recognizeText, recognizeScreenText, barcodes, faces, classify, document, animals, bodyPose, extractSubject,
    ]

    private static let pathSchema = Schema.string(
        "Image file in Comma Drive (/drive/...). Copy a Task file into /drive with fs.copy_file first.")

    static let recognizeText = ToolDefinition(
        app: .vision,
        name: "recognize_text",
        title: "Read text in image",
        description: "Reads the text in an image file with on-device text recognition. Returns the text and each line's position (0 to 1, from the top left).",
        inputSchema: Schema.object([
            "path": pathSchema,
            "languages": Schema.strings("Language codes to prefer, such as zh-Hans or en-US. Detected automatically when left out."),
            "fast": Schema.boolean("Faster, less accurate recognition."),
        ], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = try textRequest(arguments)
        try image.perform([request])
        return textValue(request.results ?? [])
    }

    static let recognizeScreenText = ToolDefinition(
        app: .vision,
        name: "recognize_screen_text",
        title: "Read text on screen",
        description: "Takes a picture of this Mac's main display and reads the text on it. Needs Screen Recording permission for Comma.",
        inputSchema: Schema.object([
            "languages": Schema.strings("Language codes to prefer. Detected automatically when left out."),
            "fast": Schema.boolean("Faster, less accurate recognition."),
        ]),
        readOnly: true,
        requirements: [.screenRecording]
    ) { arguments, _ in
        let request = try textRequest(arguments)
        let picture = try await ScreenPicture.mainDisplay()
        try VNImageRequestHandler(cgImage: picture).perform([request])
        return textValue(request.results ?? [])
    }

    static let barcodes = ToolDefinition(
        app: .vision,
        name: "detect_barcodes",
        title: "Read QR codes and barcodes",
        description: "Finds QR codes and barcodes in an image file and reads their contents.",
        inputSchema: Schema.object(["path": pathSchema], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = VNDetectBarcodesRequest()
        try image.perform([request])
        return ["codes": .array((request.results ?? []).map { code in
            [
                "payload": .optional(code.payloadStringValue),
                "symbology": .string(code.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")),
                "box": box(code.boundingBox),
            ]
        })]
    }

    static let faces = ToolDefinition(
        app: .vision,
        name: "detect_faces",
        title: "Find faces",
        description: "Finds faces in an image file and returns where they are. It does not identify people.",
        inputSchema: Schema.object(["path": pathSchema], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = VNDetectFaceRectanglesRequest()
        try image.perform([request])
        return ["faces": .array((request.results ?? []).map { face in
            [
                "box": box(face.boundingBox),
                "confidence": rounded(face.confidence),
                "roll_degrees": face.roll.map { .double(round($0.doubleValue * 180 / .pi)) } ?? .null,
                "yaw_degrees": face.yaw.map { .double(round($0.doubleValue * 180 / .pi)) } ?? .null,
            ]
        })]
    }

    static let classify = ToolDefinition(
        app: .vision,
        name: "classify_image",
        title: "Describe image",
        description: "Labels what an image file shows (for example beach, document, dog), with confidence from 0 to 1.",
        inputSchema: Schema.object([
            "path": pathSchema,
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 50),
        ], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let limit = try arguments.limit(default: 10, max: 50)
        let image = try ImageInput(arguments, files: context.files)
        let request = VNClassifyImageRequest()
        try image.perform([request])
        let labels = (request.results ?? []).filter { $0.confidence >= 0.1 }.sorted { $0.confidence > $1.confidence }
        return ["labels": .array(labels.prefix(limit).map { label in
            ["label": .string(label.identifier), "confidence": rounded(label.confidence)]
        })]
    }

    static let document = ToolDefinition(
        app: .vision,
        name: "detect_document",
        title: "Find document",
        description: "Finds a document or receipt in a photo. With save: true (the default), writes a straightened copy next to the photo as <name>-document.png.",
        inputSchema: Schema.object([
            "path": pathSchema,
            "save": Schema.boolean("Write the straightened copy. Defaults to true."),
        ], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = VNDetectDocumentSegmentationRequest()
        try image.perform([request])
        guard let page = request.results?.first else { return ["found": .bool(false)] }
        var value: [String: Value] = [
            "found": .bool(true),
            "confidence": rounded(page.confidence),
            "corners": [
                "top_left": point(page.topLeft), "top_right": point(page.topRight),
                "bottom_right": point(page.bottomRight), "bottom_left": point(page.bottomLeft),
            ],
        ]
        if try arguments.bool("save") ?? true {
            let source = try image.ciImage()
            let size = source.extent.size
            func pixel(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
            guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
                throw ToolFailure("app_error", "Perspective correction is not available.")
            }
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(pixel(page.topLeft), forKey: "inputTopLeft")
            filter.setValue(pixel(page.topRight), forKey: "inputTopRight")
            filter.setValue(pixel(page.bottomRight), forKey: "inputBottomRight")
            filter.setValue(pixel(page.bottomLeft), forKey: "inputBottomLeft")
            guard let output = filter.outputImage else {
                throw ToolFailure("app_error", "The document could not be straightened.")
            }
            value["saved"] = try image.writeSibling(output, suffix: "document")
        }
        return .object(value)
    }

    static let animals = ToolDefinition(
        app: .vision,
        name: "detect_animals",
        title: "Find cats and dogs",
        description: "Finds cats and dogs in an image file.",
        inputSchema: Schema.object(["path": pathSchema], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = VNRecognizeAnimalsRequest()
        try image.perform([request])
        return ["animals": .array((request.results ?? []).compactMap { animal in
            guard let label = animal.labels.first else { return nil }
            return [
                "label": .string(label.identifier.lowercased()),
                "confidence": rounded(label.confidence),
                "box": box(animal.boundingBox),
            ]
        })]
    }

    static let bodyPose = ToolDefinition(
        app: .vision,
        name: "detect_body_pose",
        title: "Body pose",
        description: "Finds up to 10 people in an image file and the positions of their joints (0 to 1, from the top left).",
        inputSchema: Schema.object(["path": pathSchema], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = VNDetectHumanBodyPoseRequest()
        try image.perform([request])
        let people = (request.results ?? []).prefix(10).map { person -> Value in
            let joints = ((try? person.recognizedPoints(.all)) ?? [:])
                .filter { $0.value.confidence > 0.1 }
                .reduce(into: [String: Value]()) { result, joint in
                    result[joint.key.rawValue.rawValue] = point(joint.value.location)
                }
            return ["joints": .object(joints)]
        }
        return ["people": .array(Array(people))]
    }

    static let extractSubject = ToolDefinition(
        app: .vision,
        name: "extract_subject",
        title: "Cut out subject",
        description: "Cuts the main subjects out of a photo onto a transparent background and writes it next to the photo as <name>-subject.png.",
        inputSchema: Schema.object(["path": pathSchema], required: ["path"]),
        readOnly: true
    ) { arguments, context in
        let image = try ImageInput(arguments, files: context.files)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try image.perform([request])
        guard let mask = request.results?.first, !mask.allInstances.isEmpty else {
            return ["found": .bool(false)]
        }
        let buffer = try mask.generateMaskedImage(
            ofInstances: mask.allInstances, from: image.handler, croppedToInstancesExtent: false)
        return [
            "found": .bool(true),
            "subjects": .int(mask.allInstances.count),
            "saved": try image.writeSibling(CIImage(cvPixelBuffer: buffer), suffix: "subject"),
        ]
    }

    // MARK: - Helpers

    private static func textRequest(_ arguments: Arguments) throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = try arguments.bool("fast") == true ? .fast : .accurate
        request.usesLanguageCorrection = true
        let languages = try arguments.strings("languages")
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        return request
    }

    private static func textValue(_ observations: [VNRecognizedTextObservation]) -> Value {
        let lines = observations.compactMap { observation -> (String, Float, CGRect)? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return (best.string, best.confidence, observation.boundingBox)
        }
        let text = lines.map(\.0).joined(separator: "\n")
        return [
            "text": .string(truncated(text, 50_000)),
            "lines": .array(lines.prefix(1_000).map { line in
                ["text": .string(line.0), "confidence": rounded(line.1), "box": box(line.2)]
            }),
            "truncated": .bool(text.count > 50_000 || lines.count > 1_000),
        ]
    }

    /// Vision measures from the bottom left; the tools report from the top left.
    static func box(_ rect: CGRect) -> Value {
        [
            "x": .double(round4(rect.minX)),
            "y": .double(round4(1 - rect.maxY)),
            "width": .double(round4(rect.width)),
            "height": .double(round4(rect.height)),
        ]
    }

    static func point(_ p: CGPoint) -> Value {
        ["x": .double(round4(p.x)), "y": .double(round4(1 - p.y))]
    }

    private static func rounded(_ value: Float) -> Value { .double(round4(Double(value))) }

    private static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
    private static func round4(_ value: CGFloat) -> Double { round4(Double(value)) }
}

/// An image file a Vision tool reads, in Comma Drive (`/drive/...`): the files the
/// workspace already shares with this Mac, never any other file on it.
struct ImageInput {
    static let maximumBytes = 50 * 1_024 * 1_024

    let url: URL
    /// The `/drive/...` folder the image came from, to name outputs the Agent can use.
    let driveFolder: String
    let handler: VNImageRequestHandler

    init(_ arguments: Arguments, files: FileLocations) throws {
        let path = try arguments.requiredString("path")
        guard path == "/drive" || path.hasPrefix("/drive/") else {
            throw ToolFailure.invalidArguments("path", "path must be a Comma Drive path (/drive/...).")
        }
        guard let root = files.driveRoot?.resolvingSymlinksInPath() else {
            throw ToolFailure("unavailable", "Comma Drive is not set up on this Mac.")
        }
        let relative = String(path.dropFirst("/drive".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Symlinks are resolved first, so none inside Drive leads out of it.
        url = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            throw ToolFailure.invalidArguments("path", "The path leaves Comma Drive.")
        }
        driveFolder = "/drive/" + (relative as NSString).deletingLastPathComponent
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ToolFailure.notFound("There is no file at \(path) on this Mac.")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ToolFailure.invalidArguments("path", "\(path) is not a file.")
        }
        guard (attributes[.size] as? Int ?? 0) <= Self.maximumBytes else {
            throw ToolFailure.invalidArguments("path", "The image is larger than 50 MB.")
        }
        handler = VNImageRequestHandler(url: url)
    }

    func perform(_ requests: [VNRequest]) throws {
        do {
            try handler.perform(requests)
        } catch {
            throw ToolFailure("invalid_image", "The file could not be read as an image: \(error.localizedDescription)")
        }
    }

    /// The image as Vision sees it, with its EXIF orientation applied.
    func ciImage() throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ToolFailure("invalid_image", "The file could not be read as an image.")
        }
        return image
    }

    /// Writes `image` beside the input as `<name>-<suffix>.png`, never replacing a file.
    func writeSibling(_ image: CIImage, suffix: String) throws -> Value {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var name = "\(stem)-\(suffix).png"
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem)-\(suffix)-\(counter).png"
            counter += 1
        }
        let output = folder.appendingPathComponent(name)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ToolFailure("app_error", "The image could not be written.")
        }
        do {
            try CIContext().writePNGRepresentation(of: image, to: output, format: .RGBA8, colorSpace: space)
        } catch {
            throw ToolFailure("app_error", "The image could not be written next to the original: \(error.localizedDescription)")
        }
        return [
            "path": .string(output.path),
            "drive_path": .string((driveFolder as NSString).appendingPathComponent(name)),
        ]
    }
}

enum ScreenPicture {
    static func mainDisplay() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ToolFailure.permissionRequired(.screenRecording, .notGranted)
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw ToolFailure("unavailable", "This Mac has no display to read.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = CGDisplayPixelsWide(display.displayID)
        configuration.height = CGDisplayPixelsHigh(display.displayID)
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
