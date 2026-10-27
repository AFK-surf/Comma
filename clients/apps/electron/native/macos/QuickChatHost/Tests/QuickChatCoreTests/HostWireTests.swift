import Foundation
import Testing
@testable import QuickChatCore

struct HostWireTests {
    private func configure(_ tap: String) throws -> HostCommand {
        let strings = #"{"listening":"","close":"","send":"","preparing":"","microphoneDenied":"","speechUnavailable":"","sendFailed":"","resume":""}"#
        let line = #"{"type":"configure","strings":\#(strings)\#(tap)}"#
        return try JSONDecoder().decode(HostCommand.self, from: Data(line.utf8))
    }

    @Test func configureCarriesTheTappedModifier() throws {
        guard case let .configure(_, tap) = try configure(#","tap":"alt""#) else { Issue.record(); return }
        #expect(tap == .alt)
    }

    @Test func aNullTapWatchesNoModifier() throws {
        guard case let .configure(_, tap) = try configure(#","tap":null"#) else { Issue.record(); return }
        #expect(tap == nil)
    }

    @Test func aConfigureWithoutTapKeepsCommand() throws {
        guard case let .configure(_, tap) = try configure("") else { Issue.record(); return }
        #expect(tap == .meta)
    }
}
