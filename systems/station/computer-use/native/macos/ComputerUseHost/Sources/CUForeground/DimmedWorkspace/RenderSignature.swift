import AppKit

struct RenderSignature: Equatable {
    let mode: DimmingMode
    let color: NSColor
    let targetOpacity: Double
    let anchorWindowNumbers: [Int]
    let screenFrames: [CGRect]
}
