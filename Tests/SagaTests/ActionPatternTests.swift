import Saga
import Testing

private enum UserAction: Sendable, Equatable {
  case fetch(id: Int)
  case logout
}

private enum AppAction: Sendable, Equatable {
  case user(UserAction)
  case tick
}

private protocol Event: Sendable {}
private struct Login: Event, Equatable { var name: String }
private struct Logout: Event {}

private let fetch = ActionPattern<AppAction, Int>.case {
  if case .user(.fetch(let id)) = $0 { id } else { nil }
}

@Suite struct ActionPatternTests {
  @Test func caseExtractsTheAssociatedValueOfAMatchingCase() {
    #expect(fetch.match(.user(.fetch(id: 3))) == 3)
    #expect(fetch.match(.user(.logout)) == nil)
    #expect(fetch.match(.tick) == nil)
  }

  @Test func anyMatchesEveryAction() {
    let pattern = ActionPattern<AppAction, AppAction>.any
    #expect(pattern.match(.tick) == .tick)
    #expect(pattern.match(.user(.logout)) == .user(.logout))
  }

  @Test func filterMatchesOnlyActionsSatisfyingThePredicate() {
    let pattern = ActionPattern<AppAction, AppAction>.filter { $0 != .tick }
    #expect(pattern.match(.tick) == nil)
    #expect(pattern.match(.user(.logout)) == .user(.logout))
  }

  @Test func actionMatchesOnlyAnEqualAction() {
    let pattern = ActionPattern<AppAction, AppAction>.action(.user(.logout))
    #expect(pattern.match(.user(.logout)) == .user(.logout))
    #expect(pattern.match(.user(.fetch(id: 1))) == nil)
  }

  @Test func typeMatchesActionsOfTheGivenTypeInAnExistentialAction() {
    let pattern = ActionPattern<any Event, Login>.type(Login.self)
    #expect(pattern.match(Login(name: "a")) == Login(name: "a"))
    #expect(pattern.match(Logout()) == nil)
  }

  @Test func oneOfReturnsTheValueOfTheFirstMatchingPattern() {
    let first = ActionPattern<AppAction, Int>.case { $0 == .tick ? 1 : nil }
    let second = ActionPattern<AppAction, Int>.case { $0 == .tick ? 2 : nil }
    let pattern = ActionPattern.oneOf(fetch, first, second)
    #expect(pattern.match(.tick) == 1)
    #expect(pattern.match(.user(.fetch(id: 9))) == 9)
    #expect(pattern.match(.user(.logout)) == nil)
  }

  @Test func whereMatchesOnlyWhenTheExtractedValueSatisfiesThePredicate() {
    let pattern = fetch.where { $0 > 0 }
    #expect(pattern.match(.user(.fetch(id: 1))) == 1)
    #expect(pattern.match(.user(.fetch(id: 0))) == nil)
  }
}
