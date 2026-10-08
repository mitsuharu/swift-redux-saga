import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Slice`: enum を Slice にし、`initialState` を補い、`Action` に `@ActionCases` を付ける。
public struct SliceMacro {}

extension SliceMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(EnumDeclSyntax.self) else {
      context.diagnose(Diagnostic(node: Syntax(node), message: MacroMessage.sliceRequiresEnum))
      return []
    }
    // すでに準拠している場合、コンパイラは protocols を空にして渡す。
    guard !protocols.isEmpty else { return [] }
    return [try ExtensionDeclSyntax("extension \(type.trimmed): Redux.Slice {}")]
  }
}

extension SliceMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard declaration.is(EnumDeclSyntax.self) else { return [] }
    let declaresInitialState = declaration.memberBlock.members.contains { member in
      guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
      return variable.bindings.contains {
        $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "initialState"
      }
    }
    guard !declaresInitialState else { return [] }
    let access = ActionCasesMacro.accessModifier(of: declaration)
    return ["\(raw: access)static let initialState = State()"]
  }
}

extension SliceMacro: MemberAttributeMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
    guard let action = member.as(EnumDeclSyntax.self), action.name.text == "Action" else {
      return []
    }
    let alreadyAttached = action.attributes.contains {
      $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "ActionCases"
    }
    return alreadyAttached ? [] : ["@ActionCases"]
  }
}
