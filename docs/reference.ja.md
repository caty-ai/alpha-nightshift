← [READMEに戻る](../README.ja.md)

## ガードモードとエビデンススキーマ

すべてのガードコマンドは、出力するJSONの中で、これらのモード値のうちちょうど1つを報告または継承します。

| モード | 意味 |
|---|---|
| `LOCAL_ONLY_REMOTE_UNPROVEN` | フェーズ1a: ローカルチェックのみ。鍵やネットワークへのアクセスは一切試みない。 |

フェーズ1aのすべてのエビデンス文書には、スキーマバージョンフィールドが含まれます:

```json
{
  "schema": "alpha-nightshift/text-policy-evidence/v1",
  "mode": "LOCAL_ONLY_REMOTE_UNPROVEN",
  "write_mode": false,
  ...
}
```

---

## Preflightのフィールドとwrite_mode

preflightのレスポンスは常に、2つの主要フィールドを持つJSONオブジェクトです:

- `write_mode`: 真偽値。フェーズ1aでは常に`false`。この設定が書き込みトークンを発行したりリモートの状態を変更したりすることを許可されているかを報告する。
- `mode`: 上記のガードモード値のいずれか。

その他のフィールドは、各前提条件の状態を`PROVEN`、`UNPROVEN`、`UNSUPPORTED`のいずれかで報告します:

- ファイルシステムの前提条件（設定パス、所有者、パーミッション）
- サンドボックスの能力（macOS sandbox.sbのレンダリング可否）
- IDとUIDの隔離
- リモートのGitHub Appとインストールの準備状況

フェーズ1aでは、設定内容にかかわらず`write_mode`は無条件に`false`です。

---

## パブリッシャーポリシーの形式と公開先

パブリッシャーポリシーは、公開に使用するGitHub App、リポジトリ、ルールセット、鍵材料を指定するJSONファイルです。

### 非アクティブなポリシーの例

チェックインされている`config/publisher-policy.example.json`は、意図的にオーナー情報が不完全なままにされています:
- `mode`: "INACTIVE"
- `write_mode`: false
- App ID、インストールID、アカウント値: ゼロ
- 鍵パス、監査ディレクトリパス、マニフェストパス: null
- ルールセット: 空配列
- ランタイムシール: null

実運用のポリシーは、パブリッシャー所有・モード0600である必要があり、正確なIDとパスを紐付けなければなりません:
- パブリッシャーのUIDとリポジトリの数値ID
- App IDとインストールID
- ルールセットIDと有効なルールのベースライン
- 鍵パス（パブリッシャー所有、モード0600）
- 監査ディレクトリ（パブリッシャー所有、モード0700）

さらに、以下をシールする:
- スキャナーマニフェストパス（パブリッシャー所有、モード0600）
- 固定されたBash、Git、jq、gitleaks、curl、openssl、およびパブリッシャープログラムファイルのSHA-256ダイジェスト、UID、モード

### 公開先ブランチのパターン

許可される公開先は、ブローカーが生成する、次のパターンに一致するブランチのみです:

```
refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8
```

内訳:
- `YYYYMMDD`は日付
- `NNNN`は4桁の連番
- `HEX8`は8文字の16進文字列（例: `a1b2c3d4`）

自由形式の公開、マージ、変更、および任意コマンドの実行は、ゲートウェイとブローカーの両方で強制的に無効化されたままです。

---

## ドリフトモニターの判定語彙

drift-monitorは、オーナーがシールした実運用設定を読み込み、GitHub Appの権限、Webhook設定、インストールIDを検証します。最終的な結果は次のいずれかに限定されます:

| 判定 | 意味 |
|---|---|
| `MATCH` | 検証されたすべての不変条件が一致（App権限、Webhookの状態、インストールID、リポジトリ設定、タグ、リリースがポリシーのベースラインと一致） |
| `DRIFT_DENY` | 明確な不一致を検出（ポリシー／ランタイム／App／インストール／ルールセット／有効ルール／デフォルトブランチ／プライベート設定／タグ／リリースの不変条件が異なる） |
| `MONITOR_UNVERIFIED` | 不完全なレスポンス、不正なデータ、ページネーションのタイムアウト、認証失敗、失効失敗、監査失敗のいずれか。フェイルクローズド。 |

残余値`rule_suite_result:"UNPROVEN_NO_ADMIN_READ"`が明示されているのは、Appにまだ`Administration:read`権限がないためです。GitHubの公開JWT APIはWebhook設定を公開しているため、URLが空であるという表現は機械的に検証されます。最初の実運用リードバックでは、GitHub側の実際の「Webhook無効」という表現をなお確認する必要があります。

「OAuthユーザー認可の無効化」というコントロールには公開の読み取りAPIが存在せず、`UNPROVEN_MANUAL_OWNER_BASELINE`のままです——オーナーが手動で確認する必要があります。

---

## スキャナー契約

スキャナーは、ローカルGitリポジトリの絶対パス、正確なベースおよび候補コミットのSHA、そしてアクティベーションマニフェストを受け取ります。実行内容:

- Git設定とネットワーク／認証情報の仕組みをクリアする
- ローカルのGitストアから、IDによって正規のオブジェクトを読み取る
- 候補コミットが新たに持ち込むcommit／tree／blobオブジェクトに、表現ゲートとgitleaks-stdinゲートを適用する
- オブジェクトID、種別、サイズ、生のSHA-256という決定論的なローカル集計を記録する

### バージョン固定されたgitleaks

スキャナーはバージョン固定された**gitleaks 8.30.1**を使用します。バイナリのハッシュは、SHA-256チェックサムの比較によって、CIの実行ごとに検証されます:

```
ba52fb1bfabbcde42f032afad3d6e0b19dff8ed105229a16e7caa338bbc0e84f
```

入力パス: `/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks`

### Gitオブジェクトのstdinスキャン

スキャナーは、stdin経由でGitオブジェクトに対してgitleaksを呼び出します:

```sh
gitleaks stdin --policy <policy> < <git-object-bytes>
```

これはオブジェクトの生バイト列を受け取り、ファイルシステムへのアクセスを必要とせずにgitleaksポリシーを適用します。

### MIME許可リスト

MIMEの許可リストは意図的に狭く設定されています。受け入れられるのは次のタイプのみです:

- `text/plain`
- `application/json`
- 認識済みの空コンテンツ

拒否されるタイプ（フェーズ1aではフェイルクローズド）:

- バイナリアーカイブ（tar、zip、gzip、bzip2、xz）
- 実行可能ファイル（ELF、Mach-O、PE、シェルスクリプト）
- メディア（画像、音声、動画、フォント）
- ドキュメント（PDF、Office、圧縮ファイル）
- 不透明なエンコーディングや別文字コードのエンコーディング

`text/x-shellscript`や`text/x-c`のような一般的なソースファイルタイプは、そのバイト列が有効なUTF-8であっても、`file`コマンドによって分類され、拒否されます。

### ラッパー形式とチェックサム形式

ペイロード全体がラッパー形式になっているコンテンツはフェイルクローズドです:

- Base64形式のコンテンツ
- 16進数形式のコンテンツ
- パーセントエンコードされたコンテンツ
- Base64url形式のコンテンツ（十分に長いケバブケースやアンダースコア区切りのトークンを含む）
- 正規化が曖昧なコンテンツ

そのため、本来は無害なエンコード済みテキスト、チェックサム、ラッパー形式のソースデータが、フェーズ1aでは誤って拒否される（false-deny）ことがあります。これらの分類に対応するには、別途レビューされた表現ポリシーが必要です。

### テキスト検証

テキスト検証（コミットメッセージ、タイトル、本文、コメント）は、構造的なチェックを適用します:

- BOM、NUL、CR/CRLFを含まない、有効なNFC UTF-8であること
- C0/C1制御文字やUnicodeの行区切り文字を含まないこと
- 非文字（noncharacter）や未割り当てによる曖昧さを含まないこと
- 双方向制御文字（bidi）やデフォルトで無視されるコードポイントを含まないこと
- Unicodeのフォーマット文字（`Cf`）や私用領域文字（`Co`）を含まないこと

種別ごとの、保守的なバイト数上限:

| 種別 | 最大バイト数 | 行のルール |
|---|---:|---|
| `title` | 512 | 空でない行がちょうど1行；LFなし |
| `commit_message` | 16,384 | 空でないこと；末尾にLFがちょうど1つ |
| `body` | 65,536 | 空でないこと；末尾にLFがちょうど1つ |
| `comment` | 32,768 | 空でないこと；末尾にLFがちょうど1つ |

テキストも、Gitオブジェクトと同じバージョン固定gitleaks 8.30.1のstdinポリシーを通過し、同じランナーの挙動（空コンテンツの無視、インラインallowの拒否、全バイトの診断、レダクト済みレポート、フェイルクローズド）が維持されます。

---

## 失効ランブック

オーナー主導の封じ込め手順の全体については、[night-bot-revocation.md](night-bot-revocation.md)を参照してください。

このランブックが提供するもの:
- ドライラン用レンダラー（ケースのメタデータを検証し、トークンを展開せずに正確なアクション順序を出力する）
- 順序立てられたオーナーのアクション（サービスの無効化、スプールの隔離、トークンの失効、Appの一時停止、鍵の失効）
- 変更がブロックされていることを確認するリードバック検証
- 新たなオーナーレビューと独立した承認を必要とする復旧手順

---

## テキスト検証の判定スキーマ

テキスト検証が成功すると、次を出力します:

```json
{
  "schema": "alpha-nightshift/text-policy-evidence/v1",
  "mode": "LOCAL_ONLY_REMOTE_UNPROVEN",
  "write_mode": false,
  "verdict": "PASS_LOCAL_ONLY",
  "kind": "body",
  "bytes": 123,
  "accepted_sha256": "...",
  "scanner_policy_sha256": "...",
  "gitleaks_version": "8.30.1",
  "gitleaks_sha256": "ba52fb1bfabbcde42f032afad3d6e0b19dff8ed105229a16e7caa338bbc0e84f"
}
```

成功時も拒否時も、提案されたテキストそのものが出力されることはありません。

---

## レビューレーンのアダプター設定

| 設定 | 既定値 | 意味 |
|---|---|---|
| `GLM_KEY_FILE` | GLM使用時に必須 | グループ・その他ユーザーが読み取れない、シンボリックリンクではない通常ファイルの絶対パス。1行目はキー単体または`NAME=value`形式にします（`export`と引用符は禁止）。キー単体には`=`を含めず、`=`を使う場合は`NAME=value`形式にしてください。NAMEは`^[A-Z][A-Z0-9_]*$`に一致し、空でないキーには英数字と`.`、`_`、`-`のみ使用できます。 |
| `REVIEW_GLM_MODEL` | `glm-5.3` | GLMアダプターのモデル。`^[A-Za-z0-9._-]+$`に一致する必要があります。アダプターの環境変数として指定します。現状の`run.sh`はこの上書き設定を転送しません。 |

<a id="review-lane-rotation-settings"></a>

## レビューレーンのローテーション設定

| 設定 | スコープと例値 | 意味 |
|---|---|---|
| `REVIEW_ROTATION_TARGETS` | レーン、空白区切りの`name=/abs/path`指定が必須 | 順序付きのレビュー対象一覧。各nameは一意で、空白を含まない絶対ミラーパスのbasenameと完全に一致する必要があります。ミラーはベアでない作業ツリー付きクローンにします。 |
| `REVIEW_ROTATION_STATE` | レーン、絶対パス必須 | 各対象の最新試行日と結果（`run`、`missing-mirror`、`refresh-failed`）を記録するJSON stateファイル。親ディレクトリは事前に存在している必要があります。 |
| `REVIEW_ROTATION_REFRESH` | レーン、`1` | レビュー前に`GIT_TERMINAL_PROMPT=0 git pull --ff-only --quiet`を実行する場合は`1`、更新せず現在のミラーHEADを使う場合は`0`にします。 |
| `REVIEW_ROTATION_RUN` | レーン、`lanes/review/run.sh` | 対象選択後に起動するレビューレーンスクリプト。主にテストまたは運用者管理のラッパーで使用します。 |

レーンコマンドは`env -i`下で動くため、ローテーション設定とレビュー設定はすべて`config/nightshift.conf.example`の例のように`LANE_CMD_2`文字列内へ埋め込む必要があります。空白を含まないパスのベアでない作業ツリー付きクローンを使い、事前に`mkdir -p "$REPO_ROOT/state/lanes"`を実行してください。`rotate.sh`はstate親ディレクトリを作成しません。未試行の対象を最優先し、その後は`NIGHT_ID`の辞書順で最終試行が古い対象からローテーションし、同値なら一覧の先頭を選びます。また、レビューをexecする前にstateを書き込むため、同じ夜に再実行すると次のスロットを消費し、中断されたレーンでもその順番は消費されます。選ばれたミラーが存在しないかGitリポジトリとして無効な場合は`missing-mirror`を記録し、そのスロットを消費してローテーション周期ごとに一度レーンを失敗させ、別のリポジトリへ黙って切り替えません。停止した更新処理はレーンのタイムボックスだけで制限され、そのターンはすでに消費済みです。

---

<a id="health-lane-settings"></a>

## ヘルスレーン設定

`lanes/health/run.sh`は選択したリポジトリのコミット済みHEADをローカルにクローンしてテストし、元のチェックアウトには書き込みません。必須の`LANE_DIR`と`NIGHT_ID`はディスパッチャーが渡します。レーンは`env -i`下で動くため、すべての`HEALTH_*`設定を`LANE_CMD_n`文字列に埋め込んでください。

| 設定 | 既定値 | 意味 |
|---|---|---|
| `HEALTH_TARGET_SOURCE` | 未設定 | ベアでないGitチェックアウトの絶対パス。ローテーション指定より優先します。パスのbasenameがfindingの`repo`になります。 |
| `HEALTH_ROTATION_LANE` | 未設定 | `lane_1`など、`^lane_[0-9]+$`に一致する兄弟レーン名。明示的なsourceがない場合は必須です。そのレーン直下の`rotation.json`を読み、当夜の`NIGHT_ID`、空でない`selected`、絶対パスの`path`を要求します。`refresh`の値は`health.json`に記録しますが判定には使いません。 |
| `HEALTH_ROTATION_STATE` | 未設定 | レビューローテーションstate JSONの任意の絶対パス。ローテーション経由の場合に`.targets[selected].last_attempt == NIGHT_ID`を要求し、`.targets[selected].last_result == "missing-mirror"`なら`rotation-missing-mirror`を報告します。このファイルは読み取り専用です。 |
| `HEALTH_TEST_CMD` | 未設定 | クローン内で`/bin/bash -c`に渡す明示的なコマンド。`HEALTH_SUITE_GLOB`との同時指定は禁止です。 |
| `HEALTH_SUITE_GLOB` | 未設定 | `tests/*.test.sh`など、クローンルートからの相対glob。一致する通常ファイルをそれぞれ`/bin/bash`で実行します。`HEALTH_TEST_CMD`との同時指定は禁止です。 |
| `HEALTH_TIMEBOX_SEC` | `1800` | コマンド・スイートごとの制限秒数（正の整数）。超過時はコマンドのプロセスツリー全体を停止し、タイムアウトしたコマンドのfindingは生成しません。 |

コマンドもsuite globも未指定の場合、行頭が`test:`の行を含む`Makefile`（`make test`）、`tests/run.sh`、`tests/run_tests.sh`の順に検出します。後者2つは`/bin/bash`で実行します。失敗したコマンド・スイートごとに`findings.jsonl`へ`test-failure`を1件記録し、再実行時にはこのファイルを空にします。ログは`evidence/`に置き、全ログのSHA-256とバイト数を`evidence/manifest.json`へ記録します。

終了コード`0`はテスト実行済みを意味し、失敗が見つかった場合も同じです。`3`はNO-INPUTで、`health: NO-INPUT reason=...`を出力します。理由は`no-test-runner`、`no-suites-matched`、`rotation-evidence-missing`（不正な証跡や別の夜の証跡を含む）、`rotation-missing-mirror`（stateファイルが当夜を`missing-mirror`と記録している、または選択されたパスが存在しない・Gitリポジトリでない・ベアである）、`rotation-state-mismatch`です。`1`は設定・基盤エラーまたはタイムアウトです。`refresh=skipped`だけでは失敗になりません。`rotate.sh`はミラー欠落時だけでなく`REVIEW_ROTATION_REFRESH=0`でも`skipped`を書くため、更新なしの正常な夜は通常どおり実行します。ヘルスレーンはローテーションレーンより**後の番号**に配置します。`HEALTH_ROTATION_LANE=lane_1`なら`LANE_CMD_2`以降を使い、レーン番号は連番にしてください。

`LANE_DIR`が判明した後は、NO-INPUT、設定エラー、タイムアウトでも`health.json`を書き出します。構造は`{night_id, repo, source, commit, selection, runner, result, reason, refresh, suites, failures, elapsed_sec, commands}`です。`selection`は`explicit`または`rotation`、`runner`は`explicit-cmd`、`suite-glob`、`make-test`、`tests-run`、`tests-run_tests`または`null`、`result`は`ran`、`no-input`、`timeout`または`error`、`reason`は文字列または`null`、`refresh`はローテーション証跡の`refresh`文字列（明示的なsourceでは`null`）です。`commands`の各要素は`{target, exit_code, elapsed_sec, log}`です。

---

<a id="org-consistency-settings"></a>

## Org-consistency設定

以下の公開運用設定は`config/nightshift.conf.example`と同期しています。正の整数を要求する設定は不正な値でフェイルクローズし、`OC_L3_WEEKDAY`はさらにISO曜日の`1`〜`7`のみを受け付けます。

| 設定 | スコープと例値 | 意味 |
|---|---|---|
| `OC_FRESHNESS_ENFORCE` | 日中ダイジェスト、`0` | レーンを有効にしたら`1`に設定し、org-consistencyレポートの未生成・鮮度低下を朝ダイジェストに表示します。 |
| `OC_REPORT_DIR` | 日中ダイジェスト／`oc-suggest`、未設定 | レポートディレクトリの上書き。未設定の場合はNightshift stateディレクトリ下のorg-consistencyディレクトリに従います。 |
| `OC_REPORT_MAX_AGE_DAYS` | 日中ダイジェスト／`oc-suggest`、`3` | 鮮度センサーが警告するまでの最大レポート経過日数。 |
| `OC_SUGGEST_REPO` | レーンと`oc-suggest`、`caty-ai/alpha-nightshift-dev` | 日中のIssue起票先、およびレーン自身のself-health帰属先リポジトリ。 |
| `OC_STATE_DIR` | レーン、絶対パス必須 | ミラー、plan、レポート、journal、finding台帳を保存する非シンボリックリンクのstate root。 |
| `OC_L2_MAX_REPOS` | レーン、`3` | `OC-E`／`OC-F`／`OC-G`合同キューの1夜あたりリポジトリ上限。 |
| `OC_H_MAX_REPOS` | レーン、`2` | `OC-H`用の独立した1夜あたりリポジトリ上限。 |
| `OC_L3_MAX_REPOS` | レーン、`3` | `OC-I`／`OC-J`実行時のリポジトリ上限。対象は最終試行が古い順にローテーションします。 |
| `OC_L3_WEEKDAY` | レーン、`7` | `NIGHT_ID`から決定論的に導出したL3計画のISO曜日（`1`は月曜日、`7`は日曜日）。 |
| `OC_EXCLUDE_REPOS` | レーン、空 | 対象集合から除外する、カンマ区切りのリポジトリ名または`owner/name`。 |
| `OC_LANG_POLICY` | レーン、`4` | registryに宣言がない場合のREADME言語フォールバック。`4`は英語、日本語、簡体中国語、タイ語を意味し、カンマ区切りの一覧とセミコロン区切りのリポジトリ個別上書きも受け付けます。 |
| `OC_AGENT_DOC_GLOBS` | レーン、空 | 組み込み名以外にagent指示ドキュメントとして追加する、カンマ区切りのglob。 |
| `OC_LEFT_SCOPE_WINDOW_NIGHTS` | レーン、`30` | findingがleft-scope-expiredになるまで、現在の対象集合外で保持される夜数。 |
| `OC_ZERO_STREAK_NIGHTS` | レーン、`5` | 情報提供用self-health findingを発行するまでの、連続した抽出ゼロ夜数。 |
| `OC_STALE_ESCALATE_NIGHTS` | レーン、`3` | staleな対象またはミラーについてself-healthを発行するまでの連続夜数。 |
| `OC_PROMPT_MAX_BYTES` | レーン、`262144` | モデル席1回の起動で許されるエンコード済みprompt最大バイト数。超過した作業は理由`prompt-too-large`の`NOT-RUN`として記録されます。 |
| `OC_SEAT_TIMEOUT_SEC` | レーン、`900` | 読み取り専用モデル席の1起動あたり正のタイムアウト秒数。 |
| `OC_SEAT_CMD` | レーン、L2／L3で必須 | `seat.sh`が使う完全なコマンド。promptをstdinで受け、scratch作業ディレクトリから実行されます。 |

レーンコマンドは意図的に`env -i`下で起動されます。したがって`nightshift.conf`のトップレベルへの代入は**レーンに継承されません**。レーンスコープのすべての`OC_*`値は、`config/nightshift.conf.example`の例のように`LANE_CMD_3`のコマンド文字列内へ埋め込む必要があります。日中の鮮度設定は、dispatcherと`oc-suggest`が隔離レーンプロセス外で読むため例外です。`LANE_CMD_n`は連番を維持してください。dispatcherは最初に欠番した番号で走査を停止します。

---

<a id="lane-status-settings"></a>

## レーンステータス設定

朝ダイジェストは、運用者が管理するlane-status reporterを呼び出し、そのJSON結果を表示できます。正の整数を要求する設定は不正な値でフェイルクローズします。reporterの取得失敗や契約違反はダイジェスト内に表示されますが、ダイジェスト自体を失敗させません。

| 設定 | スコープと例値 | 意味 |
|---|---|---|
| `LANE_STATUS_CMD` | 日中ダイジェスト、未設定 | `/bin/bash -c`で実行するシェルコマンド。運用者管理ラッパーの絶対パスを指定します。未設定または空の場合はセクションを省略し、フッターに`lane status: not configured`を表示します。 |
| `LANE_STATUS_TIMEOUT_SEC` | 日中ダイジェスト、`120` | 7桁以内の正のタイムアウト秒数。 |
| `LANE_STATUS_MAX_ROWS` | 日中ダイジェスト、`10` | 7桁以内の正のリスト別行数上限。ヘッダーの件数は上限適用前の値です。 |

reporterはstdoutへJSONオブジェクトをちょうど1つ出力し、終了コード0で終了する必要があります。実行はすべての子孫プロセスが終了した場合にのみ完了し、`LANE_STATUS_TIMEOUT_SEC`を過ぎてもバックグラウンドの子プロセスを残すreporterは、有効なJSONを出力していても`timeout`として報告されるため、バックグラウンドプロセスを残してはいけません。未知のフィールドは無視されます。`errors`と`truncated`は省略可能で、省略時は空配列として数えます:

```json
{
  "ci_red": [{"repo":"example/alpha","scope":"main","branch":"main","workflow":"ci","conclusion":"failure","since":"2026-09-04T01:00:00Z"}],
  "lanes": [{"repo":"example/alpha","kind":"issue","number":42,"title":"Choose rollout","owner":"human","stale":false,"reason":"decision needed","state":"hold"}],
  "roster": {"repos":["example/alpha"]},
  "errors": [{"repo":"example/alpha","message":"synthetic error"}],
  "truncated": ["LIST TRUNCATED: example/alpha pulls"]
}
```

トップレベルには配列の`ci_red`と`lanes`、および文字列配列の`roster.repos`が必須です。`errors`と`truncated`は、存在する場合は配列でなければなりません。トップレベル違反はセクション全体をunavailableにします。各行は次の閉じた契約で独立に検査され、不正行はフィルターや上限適用の前に除外・集計されます:

| 配列 | フィールド | 型 | 閉じた値 | 表示 |
|---|---|---|---|---|
| `ci_red` | `repo` | string | — | はい |
| `ci_red` | `scope` | string | `main`, `pr`, `branch` | いいえ。`main`だけをデフォルトブランチ一覧へ選択 |
| `ci_red` | `branch` | string | — | はい |
| `ci_red` | `workflow` | string | — | はい |
| `ci_red` | `conclusion` | string | — | いいえ |
| `ci_red` | `since` | string | — | はい |
| `lanes` | `repo` | string | — | はい |
| `lanes` | `kind` | string | `pr`, `issue` | いいえ |
| `lanes` | `number` | integerのJSON number | — | はい |
| `lanes` | `title` | string | — | はい |
| `lanes` | `owner` | string | `human`, `alpha`, `unknown` | いいえ。human-owned一覧を選択 |
| `lanes` | `stale` | boolean | — | いいえ。stale一覧を選択 |
| `lanes` | `reason` | string | — | はい |
| `lanes` | `state` | 省略可能なstring | — | いいえ |

コマンドはその夜のstateディレクトリ下にある実行別scratchから`env -i`で動きます。環境変数は最小`PATH`、隔離された`HOME`、scratchの`TMPDIR`、`LANG`、`TERM=dumb`、`NIGHT_ID`、`GIT_CEILING_DIRECTORIES`、`GH_CONFIG_DIR`だけです。ファイルベースの`gh`認証は`GH_CONFIG_DIR`経由でのみ利用でき、`GH_TOKEN`、`GITHUB_TOKEN`、その他の呼び出し元変数は渡りません。最小`PATH`にはバージョンマネージャーのshimがないため、必要なinterpreter環境を準備する絶対パスのラッパーを使ってください。reporter契約では`gh`以外のネットワークアクセスとstateディレクトリ外への書き込みを禁止しますが、これは運用契約でありOS sandbox境界ではありません。

---

## ローカルゲートウェイインターフェース

ゲートウェイが受け付けるのは、次の操作のみです:

- `status`: 現在の設定状態を報告する
- `inspect`: 変更を加えずにオブジェクトを検査する
- `preflight`: 前提条件を検証する（ローカルのみ）
- `scan`: Gitオブジェクトスキャナーを実行する
- `validate_text`: コミットメッセージやテキストをローカルでチェックする
- `publish_status`: 公開試行の状態を報告する
- `publish_branch`: ブローカーを起動する（すべての安全ゲートを通過した場合のみ）

自由形式の公開、マージ、変更、任意コマンドの実行は強制的に無効化されています。
