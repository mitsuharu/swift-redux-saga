import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@ActionCases`: enum の case ごとに、関連値を取り出すプロパティを生成する。
public struct ActionCasesMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
      context.diagnose(
        Diagnostic(node: Syntax(node), message: MacroMessage.actionCasesRequiresEnum))
      return []
    }
    let access = accessModifier(of: enumDecl)
    return enumDecl.memberBlock.members
      .compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
      .flatMap(\.elements)
      .map { casePropertyDecl(for: $0, access: access) }
  }

  /// 1 つの case の関連値を取り出すプロパティ。
  static func casePropertyDecl(for element: EnumCaseElementSyntax, access: String) -> DeclSyntax {
    let name = element.name.trimmed
    let parameters = Array(element.parameterClause?.parameters ?? [])
    let bindings = parameters.indices.map { "value\($0)" }

    let type: String
    let pattern: String
    let value: String
    switch parameters.count {
    case 0:
      type = "Void"
      pattern = ".\(name)"
      value = "()"
    case 1:
      type = parameters[0].type.trimmedDescription
      pattern = ".\(name)(let value0)"
      value = "value0"
    default:
      // ラベルのある関連値は、同じラベルのタプルにする（`(id: Int, title: String)`）。
      let elements = parameters.map { parameter in
        let label = parameter.firstName.map { $0.text == "_" ? "" : "\($0.text): " } ?? ""
        return label + parameter.type.trimmedDescription
      }
      type = "(\(elements.joined(separator: ", ")))"
      pattern = ".\(name)(\(bindings.map { "let \($0)" }.joined(separator: ", ")))"
      value = "(\(bindings.joined(separator: ", ")))"
    }
    // 関連値の型が関数型などでも Optional にできるよう、型を括弧で囲む。
    let optionalType = parameters.count == 1 ? "(\(type))?" : "\(type)?"
    return """
      \(raw: access)var \(name): \(raw: optionalType) {
        if case \(raw: pattern) = self { \(raw: value) } else { nil }
      }
      """
  }

  /// 生成するプロパティのアクセス修飾子。enum が public / package なら同じにする。
  static func accessModifier(of decl: some DeclGroupSyntax) -> String {
    for modifier in decl.modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.public), .keyword(.open): return "public "
      case .keyword(.package): return "package "
      default: continue
      }
    }
    return ""
  }
}
