import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntaxMacros

@main
struct ReduxMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    ActionCasesMacro.self,
    SliceMacro.self,
  ]
}

enum MacroMessage: String, DiagnosticMessage {
  case actionCasesRequiresEnum
  case sliceRequiresEnum

  var message: String {
    switch self {
    case .actionCasesRequiresEnum: "@ActionCases can only be applied to an enum."
    case .sliceRequiresEnum: "@Slice can only be applied to an enum."
    }
  }

  var diagnosticID: MessageID {
    MessageID(domain: "ReduxMacros", id: rawValue)
  }

  var severity: DiagnosticSeverity { .error }
}
