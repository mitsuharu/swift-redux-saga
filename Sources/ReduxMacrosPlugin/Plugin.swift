import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntaxMacros

@main
struct ReduxMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    ActionCasesMacro.self,
    SliceMacro.self,
    TrackedStateMacro.self,
    TrackedPropertyMacro.self,
  ]
}

enum MacroMessage: String, DiagnosticMessage {
  case actionCasesRequiresEnum
  case sliceRequiresEnum
  case trackedStateRequiresStruct
  case trackedPropertyRequiresType

  var message: String {
    switch self {
    case .actionCasesRequiresEnum: "@ActionCases can only be applied to an enum."
    case .sliceRequiresEnum: "@Slice can only be applied to an enum."
    case .trackedStateRequiresStruct: "@TrackedState can only be applied to a struct."
    case .trackedPropertyRequiresType:
      "A property of a @TrackedState struct needs an explicit type annotation."
    }
  }

  var diagnosticID: MessageID {
    MessageID(domain: "ReduxMacros", id: rawValue)
  }

  var severity: DiagnosticSeverity { .error }
}
