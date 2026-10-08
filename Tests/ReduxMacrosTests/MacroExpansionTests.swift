// マクロの実装（プラグイン）はビルドするマシン向けにしかビルドされず、iOS シミュレータ向けのテストでは
// import できない。展開のテストはマシン上（macOS / Linux）でだけ行う。
#if canImport(ReduxMacrosPlugin)
  import ReduxMacrosPlugin
  import SwiftSyntaxMacroExpansion
  import SwiftSyntaxMacros
  import SwiftSyntaxMacrosGenericTestSupport
  import Testing

  private let actionCases = ["ActionCases": MacroSpec(type: ActionCasesMacro.self)]
  // @Slice が付ける @ActionCases は、ここでは展開せずに付いたことだけを確かめる。
  private let slice = ["Slice": MacroSpec(type: SliceMacro.self, conformances: ["Slice"])]

  /// マクロの展開結果を確かめ、違っていれば Swift Testing の Issue として記録する。
  private func expectExpansion(
    _ source: String, expandsTo expected: String, diagnostics: [DiagnosticSpec] = [],
    macros: [String: MacroSpec] = actionCases,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    assertMacroExpansion(
      source, expandedSource: expected, diagnostics: diagnostics,
      macroSpecs: macros, indentationWidth: .spaces(2),
      failureHandler: { Issue.record("\($0.message)", sourceLocation: sourceLocation) }
    )
  }

  @Suite struct MacroExpansionTests {
    @Test func actionCasesGeneratesAPropertyForEveryKindOfCase() {
      expectExpansion(
        """
        @ActionCases
        enum Action {
          case reset
          case toggle(Int), user(UserAction)
          case add(id: Int, title: String)
          case pair(Int, String)
        }
        """,
        expandsTo: """
          enum Action {
            case reset
            case toggle(Int), user(UserAction)
            case add(id: Int, title: String)
            case pair(Int, String)

            var reset: Void? {
              if case .reset = self {
                ()
              } else {
                nil
              }
            }

            var toggle: (Int)? {
              if case .toggle(let value0) = self {
                value0
              } else {
                nil
              }
            }

            var user: (UserAction)? {
              if case .user(let value0) = self {
                value0
              } else {
                nil
              }
            }

            var add: (id: Int, title: String)? {
              if case .add(let value0, let value1) = self {
                (value0, value1)
              } else {
                nil
              }
            }

            var pair: (Int, String)? {
              if case .pair(let value0, let value1) = self {
                (value0, value1)
              } else {
                nil
              }
            }
          }
          """
      )
    }

    @Test func actionCasesUsesTheAccessLevelOfThePublicEnum() {
      expectExpansion(
        """
        @ActionCases
        public enum Action {
          case reset
        }
        """,
        expandsTo: """
          public enum Action {
            case reset

            public var reset: Void? {
              if case .reset = self {
                ()
              } else {
                nil
              }
            }
          }
          """
      )
    }

    @Test func actionCasesOnANonEnumIsAnError() {
      expectExpansion(
        """
        @ActionCases
        struct Action {}
        """,
        expandsTo: """
          struct Action {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@ActionCases can only be applied to an enum.", line: 1, column: 1)
        ]
      )
    }

    @Test func sliceAddsTheConformanceTheInitialStateAndActionCases() {
      expectExpansion(
        """
        @Slice
        public enum Counter {
          public struct State {}
          public enum Action {
            case increment
          }
        }
        """,
        expandsTo: """
          public enum Counter {
            public struct State {}
            @ActionCases
            public enum Action {
              case increment
            }

            public static let initialState = State()
          }

          extension Counter: Redux.Slice {
          }
          """,
        macros: slice
      )
    }

    @Test func sliceKeepsAnExplicitInitialState() {
      expectExpansion(
        """
        @Slice
        enum Counter {
          struct State {}
          static let initialState = State()
        }
        """,
        expandsTo: """
          enum Counter {
            struct State {}
            static let initialState = State()
          }

          extension Counter: Redux.Slice {
          }
          """,
        macros: slice
      )
    }

    @Test func sliceOnANonEnumIsAnError() {
      expectExpansion(
        """
        @Slice
        struct Counter {}
        """,
        expandsTo: """
          struct Counter {}
          """,
        diagnostics: [
          DiagnosticSpec(message: "@Slice can only be applied to an enum.", line: 1, column: 1)
        ],
        macros: slice
      )
    }
  }
#endif
