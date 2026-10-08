import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@TrackedState`: struct のプロパティの読み取りを Store に知らせるようにする。
///
/// - `_$tracking`（読み取りを知らせる先）を追加し、`TrackedState` に準拠させる。
/// - 保存プロパティ（`var`）に `@TrackedProperty` を付ける。
public struct TrackedStateMacro {}

extension TrackedStateMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard declaration.is(StructDeclSyntax.self) else {
      context.diagnose(
        Diagnostic(node: Syntax(node), message: MacroMessage.trackedStateRequiresStruct))
      return []
    }
    let access = ActionCasesMacro.accessModifier(of: declaration)
    return ["\(raw: access)var _$tracking = Redux.StateTrackingContext()"]
  }
}

extension TrackedStateMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(StructDeclSyntax.self), !protocols.isEmpty else { return [] }
    return [try ExtensionDeclSyntax("extension \(type.trimmed): Redux.TrackedState {}")]
  }
}

extension TrackedStateMacro: MemberAttributeMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
    guard let variable = member.as(VariableDeclSyntax.self), variable.isTrackableStoredProperty
    else { return [] }
    return ["@TrackedProperty"]
  }
}

/// `@TrackedProperty`: 保存プロパティを、読み取りを知らせる計算プロパティと、裏の保存プロパティに分ける。
public struct TrackedPropertyMacro {}

extension TrackedPropertyMacro: AccessorMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let variable = declaration.as(VariableDeclSyntax.self),
      variable.isTrackableStoredProperty,
      let name = variable.singleIdentifier
    else { return [] }
    guard variable.bindings.first?.typeAnnotation != nil else {
      context.diagnose(
        Diagnostic(node: Syntax(variable), message: MacroMessage.trackedPropertyRequiresType))
      return []
    }
    return [
      """
      @storageRestrictions(initializes: _\(raw: name))
      init(initialValue) {
        _\(raw: name) = initialValue
      }
      """,
      """
      get {
        Redux.StateTrackingContext.read(_\(raw: name), at: \\Self.\(raw: name), in: _$tracking)
      }
      """,
      """
      set {
        _\(raw: name) = newValue
      }
      """,
    ]
  }
}

extension TrackedPropertyMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let variable = declaration.as(VariableDeclSyntax.self),
      variable.isTrackableStoredProperty,
      let name = variable.singleIdentifier,
      let type = variable.bindings.first?.typeAnnotation?.type
    else { return [] }
    // 初期値は元のプロパティ（init アクセサ）に残し、裏の保存プロパティには付けない。
    return ["private var _\(raw: name): \(type.trimmed)"]
  }
}

extension VariableDeclSyntax {
  /// 追跡の対象にする保存プロパティか（`var` で、アクセサがなく、static / lazy でない、1 つの名前）。
  var isTrackableStoredProperty: Bool {
    guard bindingSpecifier.tokenKind == .keyword(.var), bindings.count == 1,
      let binding = bindings.first, binding.accessorBlock == nil,
      let name = singleIdentifier, !name.hasPrefix("_")
    else { return false }
    let excluded: Set<String> = ["static", "class", "lazy"]
    return !modifiers.contains { excluded.contains($0.name.text) }
  }

  var singleIdentifier: String? {
    bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
  }
}
