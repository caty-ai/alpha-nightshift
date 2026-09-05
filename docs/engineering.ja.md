← [READMEに戻る](../README.ja.md)

## 概要

alpha-nightshiftは、リポジトリメンテナンスのためのmacOS向け夜間観察・修復ハーネスです。決められた時刻になると、ディスパッチャーが認証情報を持たない観察レーンを起動し、それらが出力するJSONL形式の提案を台帳（ledger）へ順次記録します。日中に別途実行されるmorning-triageコマンドが調査結果を検証し、実行間の重複を排除し、エビデンスの証跡とともに採用判断を提示します。

---

## アーキテクチャ

このシステムは、安全性と監査可能性を維持するために隔離境界の中で動作するコアコンポーネントで構成されています。

| コンポーネント | パス | 役割 |
|---|---|---|
| guard-publisher | `guard/publisher.sh`, `guard/publisher-lib.sh`, `guard/broker.sh`, `guard/remote-preflight.sh` | 決定論的なpreflight、バージョン固定gitleaks 8.30.1によるGitオブジェクトスキャン、フェイルクローズドなブローカーオーケストレーションを備えた、強制適用のフェーズ1a/1b公開ゲートウェイ |
| night-bot | `launchd/`, `bin/nightshift-dispatch` | 認証情報を持たない観察レーンを直列に実行し、worktreeのライフサイクルを管理し、SIGINTを適切に処理し、実時間タイムアウトを強制するディスパッチャー |
| triage | `bin/morning-triage`, `lib/triage-*.sh`, `templates/` | 現在のmainに対する日中の読み取り専用検証、台帳履歴全体にわたる自動重複排除、GitHub連携によるエビデンス駆動の候補ランキング |
| metsuke | `lanes/review/run.sh`, `lib/evidence.sh` | 決定論的なDESIGN観点の割り当て、ローテーションするレビュアー席、ペルソナ再構成付きJSONLパース、レーンHOMEによる認証情報の限定を備えたマルチモデルレビュー観察レーン |
| org-consistency | `lanes/org-consistency/`, `bin/oc-suggest` | 決定論的検査とモデル補助検査、fingerprintライフサイクル台帳、人間がゲートする日中の起票経路を備えた、org全体の公開面ドリフト検出 |
| drift-monitor | `guard/drift-monitor.sh` | GitHub Appの権限、Webhook設定、インストールIDを検証し、MATCH／DRIFT_DENY／MONITOR_UNVERIFIEDのいずれかの判定のみを出力する、読み取り専用のコントロールプレーンドリフトチェック |
| tests-ci | `.github/workflows/ci.yml`, `.github/workflows/test-lint.yml`, `tests/run_tests.sh` | lintとmake test用のGitHubホスト型再利用可能ゲート（ubuntu＋macos）に加え、バージョン固定ツール検証を伴う完全契約スイート（全イベントとも hosted の macos-15） |
| docs | `docs/*.md` | morning-triage仕様書、night-bot失効ランブック、およびこのエンジニアリングガイドを含む設計ドキュメント |
| i18n | `README.ja.md`, `README.zh.md`, `README.th.md`, `docs/*.ja.md` | 非コード翻訳: 4言語版の玄関口README、およびengineering・referenceドキュメントの日本語ミラー |

---

## Org-consistency観察レーン

org-consistencyレーンは、GitHubの認証情報を使わずにorgの公開リポジトリを読み取り、夜間にIssueを起票・クローズせずにドリフトを検出します。検査はコストと判断の性質で分かれます。**L1**は毎回の対象実行で決定論的検査（`OC-A`〜`OC-D`）を行い、**L2**は読み取り専用モデル席で差分駆動の意味比較（`OC-E`〜`OC-H`）を行い、**L3**は設定された曜日にREADMEの定性検査（`OC-I`と`OC-J`）をローテーション実行します。L2とL3の席出力はスキーマ検証された信頼しない入力として扱われ、識別子はレーン自身が計算します。

作業開始前に、ランナーは`state/org-consistency/plan-<NIGHT_ID>.json`を書きます。**セル**は、計画された1つの`check_id × repo_id`実行単位です。レポートの状態語彙は`RUN`、`NO-INPUT`、`STALE-INPUT`、`NOT-RUN`、`INVALID-OUTPUT`のクローズドセットで、上限で後回しになった作業は消えずに`deferred`と記録されます。結果のないセルは`NOT-RUN`となり、レポートは実行中もatomicに公開されるため、夜間実行が中断しても、綺麗だったと誤表示せず部分カバレッジが残ります。

findingは、fingerprint仕様版、検査ID、数値のリポジトリID、正規化したファイル、レーンが導出したclaim kindの各識別フィールドを長さ付きで連結した、決定論的なSHA-256 **fingerprint**によって`state/org-consistency/findings.json`へ照合されます。再観測は`last_seen`を更新し、open findingが解決候補になるのはそのセル自身がfreshな入力で正常完了した後だけです。初回baselineとfingerprint移行の実行は静粛化され、初期棚卸しや識別子書き換えがIssueの大量発生になることを防ぎます。

`bin/oc-suggest`は独立した日中のゲートです。open・解決候補の表示、baseline fingerprintの明示的な昇格、選択されfingerprintだけの認証済み`gh`セッションによる起票、およびレーンのロック下でのIssue参照書き戻しを行います。self-health findingは情報提供専用で、昇格や起票はできません。レーンは、抽出ゼロの継続、対象・ミラーの鮮度低下、未実行セルの過多、不正なモデル出力、registryスキーマの変化など、カバレッジの劣化信号に対してself-healthを発行します。

鮮度は二重に検査されます。`oc-suggest`は最新レポートが古すぎると警告し、通常の朝ダイジェストは`OC_FRESHNESS_ENFORCE=1`のときorg-consistencyレポートの未生成・鮮度低下を表示できます。`env -i`によるコマンド埋め込み要件を含む運用設定の全体は[リファレンス](reference.ja.md#org-consistency-settings)を参照してください。

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

このゲートはubuntuとmacOS上で`make test`と`make lint`を実行します（macOSでの実行は`run_macos: true`で制御されます）。スイートの整合性確認はubuntuジョブで強制されます（`require_suite_reconciliation: true`）。再利用可能ゲートのmacOSジョブでは整合性確認を行いません。

テストレーンは意図的に異なる深さをカバーしています。というのも、このスイートの大半はDarwin固有だからです:

- **ubuntu** — 移植可能な部分（Darwin依存のスイートは、呼び出し元が宣言したスキップ上限の範囲内で、スキップ理由をスイートごとに出力しつつスキップします）、`make lint`、そして整合性確認の算出処理そのもの
- **hosted macOS・共通ワークフロー側**（`test-lint.yml` の `test-macos`） — このレーンは固定版gitleaks／gitの契約パスを導入しないため、それらに紐づくスイートはスキップする
- **hosted macOS・完全契約**（`ci.yml` の `pull_request`） — 固定版gitleaks／gitの契約パスをジョブ自身が導入し、検出済みの全censusを実行し、1つでもスイートがスキップされたら失敗する
- **hosted macOS・完全契約**（`ci.yml` の `main` への `push`） — 同じ完全契約を、マージ後に再実行

### 完全契約スイート

`.github/workflows/ci.yml`ワークフローは、実行前に全スイート契約を自分でインストール・検証します。全イベントが hosted の`macos-15`で実行され、このリポジトリにセルフホストランナーは登録されていません。これは意図的です — プルリクエストはこのジョブの手順自体を書き換えられ、手順はソフトウェアを導入するため、常駐のセルフホストランナーでは fork プルリクエストがオーナーのマシン上での任意コード実行になってしまいます（issue #58）。hosted ランナーなら fork プルリクエストには読み取り専用トークン・secrets なし・使い捨て VM が与えられます。ツール検証の手順:

- ShellCheckをインストールし、ガードスクリプトに対して実行
- バージョン固定gitleaks 8.30.1バイナリを、インストール時だけでなく実行のたびにSHA-256で検証
- 実際のランナーバージョンを検証するGit互換パスのシム
- `/usr/bin/jq`にあるシステムjqの可用性確認
- `sandbox-exec`の可用性確認（他レーンではサンドボックススイートがスキップになるため、このレーンだけは大声で失敗させる）
- `/opt/homebrew/bin/git`にあるBrew版gitの可用性確認

実行と分析:

- すべてのシェルスクリプトのBash構文チェック
- パブリッシャー表面とテストに対するShellCheckのlint
- `tests/run_tests.sh`によるフルテストスイートの実行、続けてゼロスキップ・アサーション（このランナーにはすべての契約がインストール済みのため、1つでもスキップがあれば契約がサイレントに壊れたことを意味します）
- PR範囲のgitleaksスキャンは、この`ci.yml`ワークフローではなく再利用可能な呼び出し元`.github/workflows/gitleaks.yml`側に存在します

ランナー選択は自動で、編集は不要になりました: 式は`push`を正マッチで判定し、それ以外はすべて hosted に落とすため、想定外のトリガーが増えても mini ではなく hosted に載ります。ただし`pull_request`では GitHub が PR ブランチ側のワークフローファイルを実行するため、この振り分けは既定の露出を無くすだけで、それ自体は境界ではありません — mini のランナーグループを`refs/heads/main`に限定することが本来の境界です。

---

## テストスイート

テストスイートは`tests/run_tests.sh`によって検出・実行されます。

### テストの検出と整合性確認

1つのスイートは1つの`tests/test_*.sh`ファイルに対応します。ランナーはそれらのファイルをglobで検出したうえで、検出件数を`tests/expected_suite_count`という台帳（census）ファイルと突き合わせ、不一致があればフェイルクローズドで停止します。これにより、台帳ファイルの更新を伴わずにスイートが消えたり（あるいは新たに現れたり）した場合に、カバレッジがサイレントに縮小するのではなく、実行そのものが赤くなります。最終サマリーとして整合性確認の行を出力します:

```
suites: declared=N executed=M skipped=K
```

`N`は検出された（台帳と突き合わせ済みの）スイートファイル数、`M`は実行された数、`K`はスキップされた数です。ubuntuのCIジョブはこれに加えて、`declared = executed + skipped`であること、実行数がゼロでないこと、呼び出し元が宣言したスキップ上限の範囲内であることを強制します。

### 環境契約によるスキップ

スイートを実行する前に、ランナーはそのスイートが宣言する環境契約を確認し、契約が1つでも欠けていれば`SKIP <suite>: missing contract <name>`という行を出力してそのスイートをスキップします。契約の語彙はクローズドセットです:

- `darwin_userland` — BSDユーザーランドのセマンティクス（`date -v`、`stat -f`、macOSのプロセス挙動）
- `sandbox_exec` — macOSの`sandbox-exec`ツール
- `pinned_gitleaks` — 契約パスに配置された、ハッシュ固定済みのgitleaksバイナリ
- `cellar_git_shim` / `brew_git` — ガードスイートが確認する、バージョン固定gitおよびbrew版gitのパス
- `system_jq` — `/usr/bin/jq`

契約がすべて揃っているスイートがスキップされることはありません。実行されたスイートが失敗すれば、その実行は必ず非ゼロで終了します。macOS依存の契約を持たないスイート（公開ゲートのセルフテストや、リポジトリに対する公開ゲートの実スキャンを含む）はどの環境でも実行されます。

---

## 手動操作

ディスパッチャーは、テストと診断のための手動起動をサポートしています:

```sh
/bin/bash bin/nightshift-dispatch run
/bin/bash bin/nightshift-dispatch digest
/bin/bash bin/nightshift-dispatch status
```

合成reporterでレーンステータスセクションを試すには、絶対パスの一時ラッパーを作り、ダイジェストにだけ渡します:

```sh
fake_reporter=$(mktemp /tmp/lane-status-reporter.XXXXXX)
trap 'rm -f "$fake_reporter"' EXIT
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf '\''%s\n'\'' '\''{"ci_red":[],"lanes":[],"roster":{"repos":["example/alpha"]}}'\'''
} > "$fake_reporter"
chmod 0700 "$fake_reporter"
LANE_STATUS_CMD="$fake_reporter" /bin/bash bin/nightshift-dispatch digest
```

生成されたダイジェストには`## Lane status`が入り、フッター末尾は`lane status: ok (...)`になります。`LANE_STATUS_CMD`を付けずにもう一度実行するとセクションは省略され、フッターは`lane status: not configured`になります。完全な契約と隔離の詳細は[レーンステータス設定](reference.ja.md#lane-status-settings)を参照してください。

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
