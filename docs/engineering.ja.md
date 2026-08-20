← [READMEに戻る](../README.ja.md)

## 概要

alpha-nightshiftは、リポジトリメンテナンスのためのmacOS向け夜間観察・修復ハーネスです。決められた時刻になると、ディスパッチャーが認証情報を持たない観察レーンを起動し、それらが出力するJSONL形式の提案を台帳（ledger）へ順次記録します。日中に別途実行されるmorning-triageコマンドが調査結果を検証し、実行間の重複を排除し、エビデンスの証跡とともに採用判断を提示します。

---

## アーキテクチャ

このシステムは、安全性と監査可能性を維持するために隔離境界の中で動作する8つのコアコンポーネントで構成されています。

| コンポーネント | パス | 役割 |
|---|---|---|
| guard-publisher | `guard/publisher.sh`, `guard/publisher-lib.sh`, `guard/broker.sh`, `guard/remote-preflight.sh` | 決定論的なpreflight、バージョン固定gitleaks 8.30.1によるGitオブジェクトスキャン、フェイルクローズドなブローカーオーケストレーションを備えた、強制適用のフェーズ1a/1b公開ゲートウェイ |
| night-bot | `launchd/`, `bin/nightshift-dispatch` | 認証情報を持たない観察レーンを直列に実行し、worktreeのライフサイクルを管理し、SIGINTを適切に処理し、実時間タイムアウトを強制するディスパッチャー |
| triage | `bin/morning-triage`, `lib/triage-*.sh`, `templates/` | 現在のmainに対する日中の読み取り専用検証、台帳履歴全体にわたる自動重複排除、GitHub連携によるエビデンス駆動の候補ランキング |
| metsuke | `lanes/review/run.sh`, `lib/evidence.sh` | 決定論的なDESIGN観点の割り当て、ローテーションするレビュアー席、ペルソナ再構成付きJSONLパース、レーンHOMEによる認証情報の限定を備えたマルチモデルレビュー観察レーン |
| drift-monitor | `guard/drift-monitor.sh` | GitHub Appの権限、Webhook設定、インストールIDを検証し、MATCH／DRIFT_DENY／MONITOR_UNVERIFIEDのいずれかの判定のみを出力する、読み取り専用のコントロールプレーンドリフトチェック |
| tests-ci | `.github/workflows/ci.yml`, `.github/workflows/test-lint.yml`, `tests/run_tests.sh` | lintとmake test用のGitHubホスト型再利用可能ゲート（ubuntu＋macos）に加え、バージョン固定ツール検証を伴うセルフホストmac-mini完全契約スイート |
| docs | `docs/*.md` | morning-triage仕様書、night-bot失効ランブック、およびこのエンジニアリングガイドを含む設計ドキュメント |
| i18n | `README.ja.md`, `README.zh.md`, `README.th.md` | 玄関口となるREADMEの非コード翻訳（docsはフェーズ0では英語のみ） |

---

## フェーズステータス

### 現在のデプロイ状況: フェーズ1a/1c

チェックインされたパッケージは、鍵やネットワークへのアクセスより前の段階で拒否します。そのモードは`LOCAL_ONLY_REMOTE_UNPROVEN`であり、preflightは常に`write_mode:false`を報告し、パブリッシャーポリシーのサンプルは非アクティブのままです。今回の変更でユーザー、GitHub Appインストール、トークン、保護設定、ルールセットのいずれも作成・変更されていません。既存のフェーズ0のディスパッチャーとレーンの挙動は変わりません。

**フェーズ1a — ローカル強制:**

ローカルパッケージは、厳格な型付きゲートウェイ、決定論的な強制無効化preflight、バージョン固定gitleaks 8.30.1のstdinを使った実際のGitオブジェクトスキャナー、レンダリング済みのmacOS sandbox-exec計測プロファイル、そしてオフラインのバイパステストを提供します。候補コミットが新たに持ち込むバイナリ、アーカイブ、実行可能ファイル、ドキュメント、メディア、不透明なオブジェクトはすべて拒否されます。表現または計測ができないサンドボックスセルは、封じ込めの主張ではなく、`UNSUPPORTED`という強制無効化の残余として扱われます。ローカルのベースエビデンスは、ローカルで読み取ったオブジェクト記録の決定論的な集計にすぎず、保護されたtipやリモートとの一致を証明するものではありません。

MIMEの許可リストは意図的に狭く設定されており（`text/plain`、`application/json`、認識済みの空コンテンツのみ）、そのため`text/x-shellscript`や`text/x-c`のような一般的なソースMIMEタイプも拒否されることがあります。ペイロード全体がラッパー形式やチェックサム形式になっているものはフェイルクローズドで扱われるため、本来は無害なBase64、16進数、パーセントエンコード、Base64url形式のコンテンツが誤って拒否される（false-deny）こともあります。

**フェーズ1b/1c — リモート証明（実際の認証情報では未証明）:**

オーケストレーターのpreflightにより、GitHub Free上のプライベートリポジトリに対する保護設定の確認が403を返すことが判明しました。そのため有効化には、対応するプライベートリポジトリのプラン／ホスト、ちょうど1つのリポジトリにインストールされた専用のGitHub App、Appの秘密鍵を保有するnight-botブローカーID、そしてリモートを変更しうる証明に対するオーナーの明示的な認可が引き続き必要です。

公開先として許可されるのは、新規に生成された`refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8`ブランチのみです。ルールセットの対応関係は`UNPROVEN_NO_ADMIN_READ`のままであり、失効やリードバックの失敗はサイレントな後始末ではなくインシデントとして扱われます。リモートの証明と保護のリードバックが成功するまで、フェーズ1は完了とみなしてはいけません。

読み取り専用のドリフトモニターは、パブリッシャーのポリシー／JWT／read-IAT／リードバックの仕組みを再利用し、`contents:write`トークンを一切発行せず、`MATCH`、`DRIFT_DENY`、`MONITOR_UNVERIFIED`のいずれかのみを出力します。そのJWT preflightは、トークンを発行する前にAppの正確な権限／イベント、無効化されたWebhook設定、正確なインストールIDを検証します。リードバックが証明できるのは現在の`main`／タグ／リリース／代表refの一致のみであり、隠れた`refs/notes/*`や`refs/replace/*`の来歴を証明するものではありません。

**フェーズ0 — ローカル観察（稼働中）:**

macOSの夜間観察ハーネスは23:30に認証情報を持たない観察レーンを実行し、そのJSONL形式の提案を順次取り込みます。06:30には、別のマシンテンプレートによるダイジェストが調査結果、クリーンなゼロ件、あるいは夜間実行が一度も開始されなかった「デッドマン」状態のいずれかを報告します。フェーズ0はハーネス自体の中でGitHubやネットワークの操作を一切行いません。日中に別途実行される`verdict-sync`コマンドは、リンクファイルが明示的に与えられた場合に限り、範囲を限定した読み取り専用のGitHub調査を行うことができます。

---

## CIとテスト

### GitHubホスト型の再利用可能ゲート

ワークフロー`.github/workflows/test-lint.yml`は、family-dev-handbookの`ci-v1`にある再利用可能ゲートを使用します:

```
uses: caty-ai/family-dev-handbook/.github/workflows/reusable-test-lint.yml@ci-v1
```

このゲートはubuntuとmacOS上で`make test`と`make lint`を実行します（macOSでの実行は`run_macos: true`で制御されます）。スイートの整合性確認は強制されます（`require_suite_reconciliation: true`）。

### セルフホストmac-mini完全契約スイート

`.github/workflows/ci.yml`ワークフローは、ガード契約がシステムの`/usr/bin/jq`に依存しているため、セルフホストのARM64 macOSランナー上で実行されます。ツール検証の手順:

- ShellCheckをインストールし、ガードスクリプトに対して実行
- バージョン固定gitleaks 8.30.1バイナリを、インストール時だけでなく実行のたびにSHA-256で検証
- 実際のランナーバージョンを検証するGit互換パスのシム
- `/usr/bin/jq`にあるシステムjqの可用性確認
- `/opt/homebrew/bin/git`にあるBrew版gitの可用性確認

実行と分析:

- すべてのシェルスクリプトのBash構文チェック
- パブリッシャー表面とテストに対するShellCheckのlint
- `tests/run_tests.sh`によるフルテストスイートの実行
- ベースコミットからHEADまでの差分範囲に限定したgitleaks

フォールバック: セルフホストランナーが利用できない場合、ワークフローを編集して`runs-on: macos-15`（GitHubホスト型、消費分数10倍レート）を使うこともできます。

---

## テストスイート

テストスイートは`tests/run_tests.sh`によって検出・実行されます。

### テストの検出と整合性確認

このスクリプトは、`tests/`配下のファイル内で`test_*`というパターンに一致するBash関数を列挙することでテスト関数を検出します。そして整合性確認の行を出力します:

```
suites: declared=N executed=M skipped=K
```

内訳:
- `N`は宣言されたテスト関数の総数
- `M`は実際に実行された数
- `K`はスキップされた数（例: プラットフォームが利用できない場合やCI環境チェックによるもの）

### 環境契約によるスキップ

テストのスキップは、その理由とともに出力されます。よくある理由には次のようなものがあります:

- 任意の依存関係が不足している場合（例: オプションのレビュアー席）
- プラットフォームの制約（例: 特定のmacOSバージョンを要求するテスト）
- CI環境の制限（例: GitHubランナー固有のテスト）
- サンドボックスの可用性（例: サンドボックスツールが利用できない場合のmacOS sandbox.sbレンダリングテスト）

宣言されたテストが「実行済み＋スキップ」の合計で説明できない場合、このスクリプトは失敗ステータスで終了します。

---

## 手動操作

ディスパッチャーは、テストと診断のための手動起動をサポートしています:

```sh
/bin/bash bin/nightshift-dispatch run
/bin/bash bin/nightshift-dispatch digest
/bin/bash bin/nightshift-dispatch status
```

SIGINT（Ctrl+C）は、現在の実行を中断する合図として処理されます。単純なPOSIXのバックグラウンドジョブはSIGINTを無視した状態を引き継ぐことがあるため、その種の起動を止めるにはSIGTERMを使用してください。

---

## launchdのインストール

チェックインされているplistファイルには、リテラルの`__NIGHTSHIFT_ROOT__`トークンが含まれています。インストール手順:

```sh
root=$(pwd -P)
for plist in launchd/ai.caty.nightshift.plist launchd/ai.caty.nightshift.digest.plist; do
  sed "s|__NIGHTSHIFT_ROOT__|$root|g" "$plist" \
    > "$HOME/Library/LaunchAgents/$(basename "$plist")"
  launchctl load "$HOME/Library/LaunchAgents/$(basename "$plist")"
done
mkdir -p state/logs
```

実行ロックは`state/locks/nightshift.lock`です。古くなったロックは意図的に自動削除されません。`meta`ファイルを確認し、記録されたプロセスが存在しないことを確かめてから、手動でロックディレクトリを削除してください。

---

## 関連ドキュメント

- [morning-triage 設計書](morning-triage.md) — 日中の判定検証と重複排除の仕様
- [night-bot 失効ランブック](night-bot-revocation.md) — オーナー主導の封じ込め手順
- [DESIGN.md](../DESIGN.md) — システム全体のアーキテクチャ、設計原則、役割分担
