# iroha

iroha（いろは）は、azooKey の macOS 版コードをベースにした日本語入力メソッドです。
macOS 標準の日本語入力に近い操作感を保ちつつ、ローカルAIによる変換候補、文章補完、選択テキスト変換を追加することを目的にしています。

現在は開発版です。通常のかな漢字変換は既存の変換エンジンを中心に行い、AIは補助候補として非同期に利用します。

## 現在の機能

- macOS InputMethodKit ベースの日本語入力
- ライブ変換、予測候補、ユーザ辞書、履歴学習
- Ollama 経由の Gemma E2B による「いい感じ変換」と文章補完
- 選択テキストに対するAI変換
- AI候補リクエストのデバウンス、キャンセル、キャッシュ
- Chromium / Electron 系アプリでの同期IME問い合わせ回避
- 未対応アプリでは Apple 日本語入力へ自動切替する設定
- 将来の MLX Swift 実装に差し替えやすいAIバックエンド分離

## AIバックエンド

設定画面の「AIバックエンド」から選択します。

- `オフ`: AI支援を使いません。
- `Ollama (Gemma E2B)`: 開発初期の推奨設定です。
- `MLX Swift`: 将来の本命実装用です。現時点では基盤のみで、推論ランタイムは未接続です。
- `OpenAI API`: 外部APIを使った検証用です。
- `Foundation Models`: 対応macOSで利用可能な場合の選択肢です。

Ollama の既定値:

- モデル名: `gemma4:e2b`
- エンドポイント: `http://localhost:11434/api/chat`

Ollama を使う場合は、事前に Ollama を起動し、設定画面の接続テストで疎通を確認してください。

## 開発環境

- macOS
- Xcode
- SwiftLint
- Git submodule

```bash
brew install swiftlint
git submodule update --init --recursive
```

SwiftLint のローカルキャッシュで権限エラーが出る場合は、キャッシュ先を明示してください。

```bash
swiftlint --quiet --strict --cache-path /private/tmp/swiftlint-cache-iroha
```

## ビルド

```bash
xcodebuild \
  -project azooKeyMac.xcodeproj \
  -scheme azooKeyMac \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build
```

## 開発インストール

開発中はユーザー領域の Input Methods にインストールするスクリプトを使います。

```bash
./script/dev_install_input_method.sh
```

このスクリプトは以下を行います。

- Debug ビルド
- `~/Library/Input Methods/iroha.app` への配置
- LaunchServices の再登録
- TextInput 系エージェントの再起動
- `iroha` 入力ソースの自動選択

入力ソースの登録が壊れた場合は、重複登録を整理してから入れ直します。

```bash
swift script/reset_iroha_input_sources.swift
./script/dev_install_input_method.sh
```

管理者権限が必要な環境では、システム設定から手動で入力ソースを削除・追加してください。

## リリース向けインストール

`install.sh` はアーカイブビルドを行い、`/Library/Input Methods/iroha.app` にインストールします。
署名設定が必要です。

```bash
./install.sh
```

SwiftLint を一時的にスキップする場合:

```bash
./install.sh --ignore-lint
```

## よくある問題

### 入力ソースに表示されない

- `./script/dev_install_input_method.sh` を再実行する
- システム設定を開き直す
- 必要ならログアウト、再ログインする
- 重複登録がある場合は `script/reset_iroha_input_sources.swift` で整理する

### Chromium / Electron 系アプリで入力が不安定

InputMethodKit では、入力中にクライアントへ同期問い合わせを行うと一部アプリでフリーズすることがあります。
iroha では `attributes`、`selectedRange`、`markedRange`、`string` などの危険な同期呼び出しを避ける経路を入れています。

それでも特定アプリで問題が出る場合は、設定の「未対応アプリではApple日本語入力へ自動切替」を有効にしてください。

### Ollama に接続できない

- Ollama が起動しているか確認する
- `http://localhost:11434/api/chat` が設定されているか確認する
- Gemma E2B のモデル名が設定と一致しているか確認する
- 設定画面の接続テストを使う

## ディレクトリ

- `azooKeyMac/`: macOS IME アプリ本体
- `Core/`: 変換、設定、AIバックエンドなどの共有ロジック
- `script/`: 開発インストール、入力ソース整理、入力ソース選択
- `azooKeyMacTests/`: 回帰テスト
- `azooKeyMacUITests/`: UIテスト

## 出自

このプロジェクトは [azooKey](https://github.com/ensan-hcl/azooKey) の macOS 関連コードをベースにしています。
iroha では macOS 向け入力体験とローカルAI支援に焦点を当てて開発しています。
