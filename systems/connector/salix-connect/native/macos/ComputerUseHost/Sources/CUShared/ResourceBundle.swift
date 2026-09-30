import Foundation

extension Bundle {
    // SwiftPM's generated accessor checks the app root, not Contents/Resources.
    // Resolve the signed app layout first; keep SwiftPM's fallback for swift test
    // and unbundled development executables. The fallback must remain lazy.
    static let commaResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(
            "ComputerUseHost_CUShared.bundle"
        ), let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
