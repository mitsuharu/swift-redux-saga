import Redux
import ReduxMacros
import Saga
import SagaTesting
import Testing

// default isolation のモジュールでも、nonisolated を付ければマクロで生成したメンバーをメインアクター外から使える。
@Slice
nonisolated enum Light {
  struct State: Sendable, Equatable {
    var isOn = false
  }

  enum Action: Sendable, Equatable {
    case toggle
    case set(Bool)
  }

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .toggle: state.isOn.toggle()
    case .set(let isOn): state.isOn = isOn
    }
  }
}

@Suite struct MacroDefaultIsolationTests {
  @Test func macrosWorkInADefaultMainActorModule() async throws {
    let tester = SagaTester(
      initialState: Light.initialState,
      reduce: Light.reducer.reduce,
      saga: Saga { ctx in
        ctx.takeEvery(.case(\.toggle)) { ctx, _ in await ctx.put(.set(true)) }
      }
    )
    await tester.send(.toggle)
    try tester.receive(.set(true))
    #expect(tester.state.isOn)
    try await tester.finish()
  }
}
