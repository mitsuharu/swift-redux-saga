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
    // 追跡の仕組みを入れられない保存プロパティ（let やプロパティラッパー付きなど）があれば、
    // その型の値は全体の変化で通知する必要がある。
    let hasUntracked = declaration.memberBlock.members.contains {
      guard let variable = $0.decl.as(VariableDeclSyntax.self) else { return false }
      return variable.isInstanceStoredProperty && !variable.isTrackableStoredProperty
    }
    return [
      "\(raw: access)var _$tracking = Redux.StateTrackingContext()",
      "\(raw: access)static var _$hasUntrackedProperties: Bool { \(raw: hasUntracked) }",
    ]
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
  /// 追跡の対象にする保存プロパティか（型を書いた `var` で、アクセサやプロパティラッパーがなく、
  /// static / lazy でない、1 つの名前）。
  var isTrackableStoredProperty: Bool {
    guard isInstanceStoredProperty, bindingSpecifier.tokenKind == .keyword(.var),
      bindings.count == 1, let name = singleIdentifier, !name.hasPrefix("_")
    else { return false }
    // プロパティラッパーはアクセサと併用できないため対象外にする（@TrackedProperty 自身は除く）。
    let otherAttributes = attributes.filter {
      $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription != "TrackedProperty"
    }
    return otherAttributes.isEmpty && !modifiers.contains { $0.name.text == "lazy" }
  }

  /// インスタンスの保存プロパティか（計算プロパティと static / class を除く）。
  var isInstanceStoredProperty: Bool {
    guard !modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else {
      return false
    }
    return bindings.allSatisfy { binding in
      guard let accessors = binding.accessorBlock?.accessors else { return true }
      // willSet / didSet だけのプロパティは保存プロパティ。
      guard case .accessors(let list) = accessors else { return false }
      return list.allSatisfy {
        [.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind)
      }
    }
  }

  var singleIdentifier: String? {
    bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
  }
}
