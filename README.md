# swift-redux-saga

Swift 6 で書かれた Redux（[Redux Toolkit](https://redux-toolkit.js.org/) を参考にした実装）と、その上で動く [Redux Saga](https://redux-saga.js.org/) の Swift Package です。

> [!WARNING]
> 開発初期段階です。API はまだ存在せず、今後大きく変わります。

## 特徴（予定）

- Swift 6 言語モード（strict concurrency）対応
- 外部ライブラリに依存しない（標準ライブラリと Apple 公式フレームワークのみ）
- 構造化並行性で実装した Saga（`take` / `put` / `call` / `fork` / `takeLatest` / `race` など）
- ビジネスロジックが本ライブラリに依存しない構成を取れる設計
- SwiftUI / UIKit の Observation に対応

## 動作環境（予定）

- Swift 6.2 以降（Xcode 26 以降）
- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1 以降

## 背景

作者が以前 [ReSwift の拡張として実装した Saga](https://github.com/mitsuharu/ReSwift-Saga)（[解説記事](https://qiita.com/mitsuharu_e/items/c2f7893a2c974dd5fc77)）を、Redux 本体も含めて Swift 6 向けに作り直すプロジェクトです。

## ライセンス

[MIT](LICENSE)
