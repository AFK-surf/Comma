import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct SwiftUIMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [StateMacro.self, ProjectedValueMacro.self]
}

struct MacroError: Error, CustomStringConvertible {
    let description: String
}

private let accessModifiers: Set<Keyword> = [.private, .fileprivate, .internal, .package, .public, .open]

private struct StateProperty {
    let name: String
    let type: TypeSyntax?
    let initialValue: ExprSyntax?
    let access: String

    init(attribute: AttributeSyntax, declaration: some DeclSyntaxProtocol) throws {
        guard let variable = declaration.as(VariableDeclSyntax.self),
            variable.bindings.count == 1,
            let binding = variable.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
        else {
            throw MacroError(description: "@State applies to one stored property")
        }
        name = pattern.identifier.identifier?.name ?? pattern.identifier.text
        type = binding.typeAnnotation?.type.trimmed
        var value = binding.initializer?.value.trimmed
        if case .argumentList(let arguments) = attribute.arguments, let argument = arguments.first {
            value = argument.expression.trimmed
        }
        if value == nil, let type, Self.isOptional(type) {
            value = "nil"
        }
        initialValue = value
        access = variable.modifiers
            .filter { modifier in
                if case .keyword(let keyword) = modifier.name.tokenKind {
                    return accessModifiers.contains(keyword) && modifier.detail == nil
                }
                return false
            }
            .map { "\($0.name.text) " }
            .joined()
    }

    private static func isOptional(_ type: TypeSyntax) -> Bool {
        type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
            || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
    }
}

/// `@State`, expanded as SwiftUI expands it for a property that is not private.
public struct StateMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let property = try StateProperty(attribute: node, declaration: declaration)
        let storage = "_\(property.name)"
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = SwiftUICore.State(initialValue: initialValue)
            }
            """,
            """
            get {
                \(raw: storage).wrappedValue
            }
            """,
            """
            nonmutating set {
                \(raw: storage).wrappedValue = newValue
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let property = try StateProperty(attribute: node, declaration: declaration)
        let storage = "_\(property.name)"
        let projection = "$\(property.name)"
        if let value = property.initialValue {
            let state = property.type.map { "SwiftUICore.State<\($0)>" } ?? "SwiftUICore.State"
            return [
                "private var \(raw: storage) = \(raw: state)(initialValue: \(value))",
                """
                @SwiftUICore._PropertyWrapperProjectedValue
                \(raw: property.access)var \(raw: projection) = \(raw: state)(initialValue: \(value)).projectedValue
                """,
            ]
        }
        guard let type = property.type else {
            throw MacroError(description: "@State needs a type annotation or an initial value")
        }
        return [
            "private var \(raw: storage): SwiftUICore.State<\(type)>",
            """
            \(raw: property.access)var \(raw: projection): SwiftUICore.Binding<\(type)> {
                \(raw: storage).projectedValue
            }
            """,
        ]
    }
}

/// `_PropertyWrapperProjectedValue`: makes `$name` read `_name.projectedValue`.
public struct ProjectedValueMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
            let pattern = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self),
            pattern.identifier.text.hasPrefix("$")
        else {
            throw MacroError(description: "_PropertyWrapperProjectedValue applies to a $ property")
        }
        let base = String(pattern.identifier.text.dropFirst())
        return [
            """
            get {
                _\(raw: base).projectedValue
            }
            """
        ]
    }
}
