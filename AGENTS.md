# AGENTS.md

このリポジトリで作業するエージェント（と人）が常に守るルールです。設計の詳細は [docs/design.md](docs/design.md)、作業の順序は [docs/roadmap.md](docs/roadmap.md) を参照してください。

## プロジェクト

- Swift 版 Redux（Redux Toolkit を参考にした新実装）と、その上で動く Redux Saga の Swift Package。
- 主目的は **Saga**。Redux 本体はその土台だが、単体でも使える品質にする。

## 必須の制約

1. **Swift 6 言語モード**（strict concurrency 完全対応）。警告ゼロ。
   - `Action` と `State` は `Sendable`。
   - グローバルな可変状態を持たない。チャネルは Store / Saga ランタイムのインスタンスが所有する。
   - 隔離を明示する: Store は `@MainActor`、reducer は同期の純粋関数、Saga はメインアクター外で実行。
   - アプリ側が default MainActor isolation を有効にしていても、無効でも使えること。ライブラリ自体は default isolation を使わず、公開 API の隔離をすべて明示する。
   - `@unchecked Sendable` / `nonisolated(unsafe)` は原則使わない。使う場合は理由と安全性の根拠をコメントに書く。
2. **外部ライブラリを使わない**。標準ライブラリと Apple 公式フレームワークのみ。
   - 使う: Swift Concurrency（`AsyncStream`, `Task`, `TaskGroup`）、Observation、SwiftUI、UIKit、`Clock` / `Duration`、Swift Testing。
   - コアでは Combine を使わない。
   - swift-async-algorithms / CasePaths / swift-clocks / swift-collections などは使わず、必要な機能は自前で実装する。
   - 例外: マクロターゲット（別ターゲット）のみ swift-syntax に依存してよい。マクロなしで全機能が使える API を先に完成させる。
3. **ロックインを避ける**。
   - ビジネスロジック（UseCase / Repository など）が本ライブラリを import せずに書けること。
   - Saga は「Action を受け → ビジネスロジックを呼び → 結果を Action で返す」薄い接着層として使える API にする。
   - `call` は任意の async 関数を受け取る（パラメータパック `each`）。Action を引数に取る関数に限定しない。
   - 依存（UseCase など）はシングルトンではなく、Saga の起動時に注入する。
   - Saga のコアは Redux 本体の具体型に依存せず、`SagaHost` プロトコル（dispatch / 状態の取得）と `emit` による Action の流し込みだけで動く。
4. **Swift Package Manager** で提供する。
5. **プラットフォーム**: iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1 以上。UI に依存しないターゲットは Linux でもビルド・テストできること。

## 進め方

- `main` へ直接コミットしない。すべて PR で進める。
- `docs/roadmap.md` の順に進める。1 PR = 1 目的で、小さく保つ。
- 公開 API の変更は `docs/design.md` も同じ PR で更新する。`docs/roadmap.md` の該当行に PR のリンクを付ける。
- 判断に迷う設計変更や、`docs/design.md` の方針から外れる変更は、マージせず作者（@mitsuharu）に確認する。

### ブランチ・コミット・PR

- ブランチ名: `feature/<内容>`, `fix/<内容>`, `docs/<内容>`, `ci/<内容>`, `refactor/<内容>`
- コミットは目的・機能ごとに分ける。1 コミットにテストと実装を含めてよいが、無関係な変更を混ぜない。
- コミットメッセージは Conventional Commits 形式（`feat:`, `fix:`, `docs:`, `test:`, `ci:`, `refactor:`, `chore:`）。本文は日本語でよい。
- エージェントがコード作成・変更またはコミットを行った場合は、コミットメッセージ末尾に空行を挟んで `Co-authored-by: <エージェント名> <メールアドレス>` を必ず付ける。名前は実際に作業したエージェント自身の名前とし、メールアドレスはそのエージェント用のものを使う（例: `Co-authored-by: Codex <noreply@openai.com>`）。マージコミットにも付け、コミット前に付け忘れがないことを確認する。
- PR の説明には「目的」「変更内容」「テスト内容」「要確認事項」を書く（`.github/pull_request_template.md`）。

### セルフレビュー（フェーズ 1 以降）

設計 PR（M0）は作者の承認後にマージする。フェーズ 1 以降の PR は、次の手順でセルフレビューしてからマージしてよい。

1. 差分全体を読み直し、PR にレビューコメントとして指摘と対応を残す。
2. 確認観点:
   - Swift 6 の並行性: データ競合、不要な `@unchecked Sendable` や `nonisolated(unsafe)`、隔離の境界
   - キャンセルの伝播とリソースの解放（Task・continuation・ストリームのリーク）
   - 外部ライブラリを追加していないか
   - ビジネスロジックが本ライブラリに依存しない使い方を妨げていないか
   - 公開 API の命名・アクセス修飾子・ドキュメントコメント
   - テストの十分さ（キャンセル、エラー、競合するタイミングのケース）
3. CI がすべて成功していることを確認してからマージする。squash ではなく、コミット単位の履歴が残るマージ方法（merge commit）を使う。

## リリース

- バージョンは Semantic Versioning。1.0.0 までは、マイナーバージョンでも公開 API が変わり得る。
- 公開 API や振る舞いを変えた PR は、`CHANGELOG.md` の `Unreleased` に追記する。未リリースの機能の修正（利用者が一度も使っていない振る舞いの修正）は書かない。
- リリースは PR で `CHANGELOG.md`（`## [0.1.0] - 日付` の節）と README のインストール手順を更新し、マージ後にタグ（`0.1.0` の形式、`v` を付けない）と GitHub Release を作る。タグと GitHub Release は公開されて取り消しにくいので、作る前に作者（@mitsuharu）に確認する。
- タグと GitHub Release は Release ワークフロー（`.github/workflows/release.yml`）で作る。タグを push するか、Actions の画面から手動で実行してバージョンを入れる（タグがなければ、実行したブランチの先頭に打つ）。リリースノートは `CHANGELOG.md` の該当の節から作り、節がなければ失敗する。

## 完了の定義（各 PR 共通）

- Swift 6 言語モードで警告・エラーなし
- 追加した機能にテストがあり、CI がすべて成功
- 公開 API にドキュメントコメントがある
- 外部ライブラリの追加なし（マクロターゲットの swift-syntax を除く）
- 関連ドキュメント（`docs/design.md` / `docs/roadmap.md` / README）が更新されている

## コメントとコミットメッセージ

何をどこに書くかを分ける。

| 書く場所 | 伝えること |
| --- | --- |
| コード | How（どう実現しているか）。コード自体で読み取れるように書く |
| テストコード | What（何を保証するか）。テスト名と本文で仕様が分かるように書く |
| コミットメッセージ | Why（なぜこの変更をしたか） |
| コードコメント | Why not（なぜ他の書き方をしなかったか）。自明な処理の説明は書かない |

- コメントは日本語で書く。
- 設定ファイル（CI のワークフローなど）にも、選んだ値と採らなかった選択肢の理由を日本語のコメントで残す。

## テスト

- Swift Testing を使う。
- 並行処理のテストは `TestClock` や `settle()` を使い、実時間や `Task.yield()` の回数に依存しない。フレーキーなテストを入れない。
- キャンセル、エラー、競合するタイミングのケースを必ず含める。

## シミュレータ・実機での動作確認

- Example アプリをシミュレータや実機で操作・確認するときは [callstack/agent-device](https://github.com/callstack/agent-device) を使う。

## GitHub Actions

- サードパーティを含むすべてのアクションは、タグではなく**コミットの完全な SHA** で固定し、行末にバージョンをコメントで書く（GitHub 公式のセキュリティ強化ガイドの推奨）。

  ```yaml
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  ```

- SHA は推測で書かず、公式リポジトリのリリースタグから確認する（例: `gh api repos/actions/checkout/git/ref/tags/v7.0.1`。注釈付きタグの場合は指すコミットまでたどる）。
- アクションを更新するときは SHA とコメントのバージョンを同時に更新する。
- アクションの更新は Dependabot（`.github/dependabot.yml`、月 1 回）に任せる。Dependabot は SHA とバージョンのコメントを合わせて更新する。
- Swift の依存（swift-syntax）の更新も Dependabot（週 1 回）に任せる。
- runner イメージと Xcode のバージョンも推測で書かず、[actions/runner-images](https://github.com/actions/runner-images) の公開情報で確認する。

## よく使うコマンド

```sh
swift build
swift test
# CI と同じく、このパッケージのターゲットの警告をエラーにする（理由は Package.swift を参照）
SWIFT_REDUX_SAGA_WARNINGS_AS_ERRORS=1 swift build --build-tests

# フォーマット（Examples も対象）
swift format lint --strict --recursive --parallel Package.swift Sources Tests Examples
swift format --in-place --recursive --parallel Package.swift Sources Tests Examples

# iOS シミュレータ向けのテスト（マクロを使うので -skipMacroValidation が必要）
xcodebuild test -scheme swift-redux-saga-Package \
  -destination "platform=iOS Simulator,name=iPhone 17" -skipMacroValidation

# Example のロジックのテストとアプリのビルド
(cd Examples/ExampleKit && swift test)
xcodebuild build -project Examples/Examples.xcodeproj -scheme SwiftUIExample \
  -destination "generic/platform=iOS Simulator" -skipMacroValidation

# ドキュメント（DocC）の警告の確認
xcodebuild docbuild -scheme swift-redux-saga-Package -destination "generic/platform=macOS" -skipMacroValidation
```

## フレーキーなテストを入れないための確認

並行処理を変更した PR は、マージ前にテストを並列で繰り返し実行して、失敗が 0 であることを確かめる。

```sh
swift build --build-tests
for p in 1 2 3 4; do (for i in $(seq 1 10); do swift test --skip-build 2>&1 | grep -E '✘|Fatal' ; done) & done; wait
```

## メモリリークの確認

- 解放されるべきオブジェクト（Store、Saga ランタイム、ミドルウェア、購読、テスト支援）は、`weak` 参照が `nil` になることをテストで確かめる（`MemoryTests`）。参照を持つ型を追加したら、ここにテストを足す。
- Example は、agent-device でひととおり操作した後に `leaks` で確かめる。シミュレータ向けのビルドには `get-task-allow` が付かないため、付けて署名し直してからインストールする。

```sh
codesign -f -s - --entitlements <get-task-allow を true にした plist> <ビルドした .app>
leaks <シミュレータで動いているアプリの pid>
```
