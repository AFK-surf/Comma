import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct PreviewsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SwiftUIView.self,
        SwiftUIViewGroup_1.self,
        KitViewMacro.self,
        PreviewCommonGroup.self,
        Common.self,
        Previewable.self,
    ]
}

/// `#Preview` registers a preview for Xcode only. A build outside Xcode expands it to nothing.
public protocol NoPreview: DeclarationMacro {}

extension NoPreview {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct SwiftUIView: NoPreview {}
public struct SwiftUIViewGroup_1: NoPreview {}
public struct KitViewMacro: NoPreview {}
public struct PreviewCommonGroup: NoPreview {}
public struct Common: NoPreview {}

public struct Previewable: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
