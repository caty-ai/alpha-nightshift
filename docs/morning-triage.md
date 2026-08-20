# morning-triage 設計書 v1.1.1 — 朝の裁定自動化 (#37) + 夜またぎ重複検知 (#38)

- 起点: caty-ai/alpha-nightshift #37 / #38（設計は合同1本・Issue は分離のまま）
- 作成: Alpha 2026-08-18 / オーナー決裁: 自動化 GO・Hands-off（push まで自走・事後確認）
- サイズ: **L**（loom-seats 決定論判定・席= Kimi K3 + Opus 5 + GLM 5.3・writer= codex-sol）
- 上位設計: `DESIGN.md` §2 原則4「precision 優先」・原則7「反射=機械/熟考=LLM」・§8（dedup 3段）・§9（朝ダイジェスト）
- v1.1: L1-9 設計レビュー3席（全席 GO-with-changes・NO-GO なし）の findings 反映。主変更= ①自動 dup 却下は**確定 verdict 済み canonical 限定**（open×open はクラスタ提示）②observed_at=投影スナップショット時刻固定+**Phase A〜B2 で nightshift.lock 保持** ③ALREADY_FIXED 証拠ゲート強化（不在証明+履歴ゲート）と config 段階運用 ④canonical 参照パーサの列挙仕様化 ⑤予算の Stage 分離（新規 dedup 必須+検証は再検証スキップ付き）⑥リプレイ受入のクラスタ粒度再定義+G0

## 0. 一言で

毎朝、open findings を最新 main への read-only 検証と台帳全体との重複照合にかけ、**機械的に決まる却下だけ**を `verdict-sync` 経由で自動記録し、残り（採用候補・regression 疑い・クラスタ・グレー）は**証拠つきの推奨として人裁定キューに残す**デイタイム・コアコマンド。

## 1. スコープと非スコープ

### やること（v1）

| # | 内容 | Issue |
|---|---|---|
| 1 | open findings の対 main 自動検証（CONFIRMED_CURRENT / ALREADY_FIXED / NOT_REPRODUCIBLE / UNCLEAR） | #37 |
| 2 | 自動却下 2類型のみ: ①ALREADY_FIXED（§6 の強化ゲート全 PASS・**config 段階運用**） ②高確度 DUPLICATE（**確定 verdict 済み canonical への一致のみ**） | #37 |
| 3 | 夜またぎ重複照合（新規 open × 台帳全体の canonical・3層キー構造・open×open はクラスタ提示） | #38 |
| 4 | fixed への一致 = **regression 疑い**としてレポート提示のみ（verdict は書かない） | #38 |
| 5 | 採用候補・クラスタ・グレー残差の朝レポート（証拠+推奨つき・GitHub コメント投稿） | #37 |
| 6 | #36 の46件リプレイ検証ハーネス（G0〜G5・record/replay モード付き） | 両方 |
| 7 | launchd 定時実行（06:35・実行窓ガード付き） | #37 |

### やらないこと（v1 明示非スコープ）

- **自動「採用」**（採用=修正リソース割当て= Alpha/オーナー専決。決裁事項）。機械ゲートでも強制: B3 直前に `all(.status == "rejected")` 検査（レビュー席指摘 m4: `verdict_transition_allowed` の night-bot 例外は actor=auto-triage に効かないため、設計上の約束を機械化する）
- **regression verdict の書込み**（`verdict-sync --input` の受理語彙は adopted/fixed/rejected のみ・lib/verdict.sh:49-50。fixed→regression 遷移は --input から到達不能・lib/verdict.sh:724-726。レポート提示に留める。再オープンは DESIGN §8 のとおり目付の体験 or 人裁定側）
- NOT_REPRODUCIBLE の自動却下（決裁は自動却下2類型限定。人裁定キューへ）
- deferred の自動判定（価値判断）
- embedding アダプタ（DESIGN §8 ②層。将来のプール規模対策として config スロットのみ）
- `alpha-nightshift-local/`（morning-report.sh）の改修 — morning-report は生 ledger を直読しており（実測確認済み）、triage が 07:05 までに台帳へ反映すれば無改修で当日反映される
- 夜間 ingest 経路（`ledger_ingest_proposals` / `duplicates_skipped`）の変更

## 2. 不変条件（決裁済み制約+レビュー反映の設計への写像）

1. **台帳形式不変**: 書込みは `bin/verdict-sync --input` のみ。lib/verdict.sh・lib/ledger.sh・bin/verdict-sync・lib/lock.sh は**一切変更しない**。台帳投影は STATE_DIR 差し替えで**本物の `ledger_project_findings` を呼ぶ**（投影ロジックの再実装禁止・リプレイも同じ投影器を通す）
2. **fail-closed**: 確信が持てない finding は open のまま。LLM 出力不正・証拠ゲート不一致・canonical 解決不能・コスト超過・GitHub 不達 → すべて「書かない」側。打ち切り・スキップ・対象外は**種別ごとに件数をレポート明示**（no silent caps: コスト繰越／再検証スキップ／対象外 repo／閉包未完クラスタを区別する）
3. **可逆性**: 自動却下は人が `rejected → adopted`（actor ≠ night-bot）で戻せる。**前提**: 単調性検査（lib/verdict.sh:717-723）により、人の訂正 verdict は observed_at がウォーターマーク（§2-6）より新しい必要がある。`--github-links` 経路はイベント時刻を使うため、ウォーターマーク以前に付けたラベルでの訂正は stale 拒否される — レポートに当該 run のウォーターマークを必ず表示し、復旧手順（ラベル貼り直し/新コメント）を README triage 節に記載する
4. **actor 名義**: `auto-triage` 固定。各 run で本物の台帳投影を行い、actor=auto-triage の verdict は、すべて報告 Issue と同じ repo の `https://github.com/<repo full name>/issues/` 配下を `source_ref` に持つこと（= 他人が auto-triage を名乗っていないこと）を前提検証する。自動 triage 自身の過去 verdict は許可し、異形 URL・欠落・投影不能を含む検査不能時は fail-closed とする
5. **単一 writer + ロック規律**: morning-triage は**起動直後に既存の `state/locks/nightshift.lock` を取得し、Phase A〜B2 の間保持し、B3 で verdict-sync を呼ぶ直前に解放する**（verdict-sync が自ら取得するため）。二重起動の敗者は Phase A 開始前に敗退する（LLM コスト・コメント投稿とも発生しない）。新しいロックは増やさない
6. **observed_at ウォーターマーク**: run 内の全 decision の observed_at は **A1 で台帳投影を読んだ瞬間の UTC 秒（`nightshift_iso_now` と同書式）に固定**（全件同一値）。open finding は過去 verdict を持たない（open へ戻る遷移が存在しない）ため相互衝突しない。ロック保持と合わせ、分析中に着地した人裁定は verdict-sync の stale 検査（第二の網）でバッチごと fail-closed になる
7. **実行窓**: 現在時刻が 06:30〜08:00 の外なら即 exit 0+ログ（launchd のスリープ復帰発火対策）。`--dry-run`/`--force` は窓検査を免除（リプレイ・手動運用）

## 3. アーキテクチャ配置

```
夜:  nightshift-dispatch ── lanes ──> 提案 ──> ledger_ingest_proposals（レーン内 dedup: 完全一致 id のみ・現状維持）
                                                    │ finding (open)
朝:  06:30 digest ──> 06:35 morning-triage ─────────┤
       lock 取得 → Phase A(read-only): 投影(=ウォーターマーク) → clone → Stage V 検証 → Stage D 重複照合 → draft 生成
       → B1 再検証 → B2 レポート投稿+検証 → lock 解放 → B3 verdict-sync --input → B4 結果コメント
     07:05 morning-report（既存・無改修・triage 済みの台帳を直読）
```

**dedup を ingest 時でなく朝 triage 時に置く理由**（v1.0 から不変）: 夜間クリティカルパスに LLM を入れない／重複も一度 finding として台帳に載ってから dup-reject される方が**再発見の証跡が台帳に残る**（canonical X への dup-reject verdict 件数 = 再発見回数が投影で導出可能・台帳外カウンタ不要）／suppress 方式は「何を隠したか」が台帳から消える。

## 4. 自動裁定の類型（決定表）

### 4.1 Stage V（対 main 検証）の結果 × 処理

| V 判定 | 機械ゲート | mode=reject | mode=suggest（初期既定） |
|---|---|---|---|
| ALREADY_FIXED | §6 全 PASS | rejected (auto) | レポート「fixed 推奨・証拠つき」 |
| ALREADY_FIXED | §6 いずれか FAIL | 書かない→「fixed 疑い・証拠不一致」欄 | 同左 |
| CONFIRMED_CURRENT | 現存証拠添付 | 書かない→「採用候補・推奨つき」欄 | 同左 |
| NOT_REPRODUCIBLE / UNCLEAR / 出力不正 / タイムアウト | — | 書かない→「要人裁定」「残差」欄 | 同左 |

`TRIAGE_ALREADY_FIXED_MODE=suggest|reject`（既定 suggest）。初期運用で false-fix 率ゼロを実測してから reject へ昇格（オーナー事後確認 D-6）。リプレイは reject モードで走らせ、ゲートと G5 を検証する。

### 4.2 Stage D（重複照合）の結果 × 根 canonical 状態

| D 判定 | 根 canonical の状態（§5 解決後） | アクション |
|---|---|---|
| DUPLICATE/high | adopted | rejected (auto)・reason に canonical 参照 |
| DUPLICATE/high | rejected（dup/deferred/その他起因） | rejected (auto)・deferred 起因は `canonical is deferred` 注記 |
| DUPLICATE/high | rejected（already-fixed 起因） | dup 却下しない。V の結果に従う（V=ALREADY_FIXED なら 4.1 へ・それ以外は「既知修正済み同型疑い」欄+V=CONFIRMED_CURRENT なら regression 疑い欄） |
| DUPLICATE/high | fixed | 書かない→「regression 疑い」欄（V 結果併記） |
| DUPLICATE/high | open | 同 finding が属する complete クラスタに adopted canonical があれば、その canonical で rejected (auto)。クラスタとして settled canonical を持たなければ「クラスタ提示」欄 |
| DUPLICATE/high | 解決不能（参照パース不能・不在・ループ・複数参照） | 書かない→「要人裁定」欄 |
| DUPLICATE/medium・low | — | 書かない→「dup 疑い」欄 |
| DISTINCT | — | （dedup 由来の書込みなし） |

**自動 dup 却下は「確定 verdict 済み canonical」限定**（レビュー3席収束）。LLM が同じ complete クラスタの open sibling を指した場合も、推移閉包後に選ばれた adopted canonical を使う。クラスタが incomplete、canonical が null、または adopted 以外なら提示のみに留める。

rejection_reason は機械テンプレのみ（LLM 自由文は 200 字整形・改行/タブ/パイプ除去して部分埋め込み）:
- `already fixed on main <sha>: <説明> (<file>:<line>); not a false positive`
- `duplicate of <canonical_full_id> (<共通欠陥の一言>; evidence <anchor>[, canonical is deferred][, 起因 <deferred|その他>]); not a false positive`
  - `<anchor>` は #37 制約「file:line 証拠を必ず埋める」の機械充足: 新 finding の target が `file[:line]` 形にパースできればそれ・できなければ target の正規化 60 字（LLM 自由文にしない）。継承 canonical の起因種別（deferred/その他）は1語で明示する

**再発見回数の可視化**（#38 副次価値の出力先）: レポートのクラスタ提示欄・自動 dup 却下欄に「canonical X への累計 dup-reject 数 = 再発見 n 回」を投影から導出して1列表示する

## 5. 照合キー層構造（#38 の核）

実測根拠: #36 の重複15件の target 表記は不統一（`task-runner.sh:1552` vs `task-runner.sh:recover_verifying` vs `ヘルスチェックの状態表示` vs 別ファイル）。決定論キーの recall はほぼ0。スパイク実測（2026-08-18・codex sol・実データ5件×プール10件）: 難例・敵対例含め 5/5 正解 — L2 の実現可能性は確認済み。

- **L0 機械・完全一致**: `repo + norm(target) + kind + norm(symptom)` ハッシュ完全一致 → LLM を通さず DUPLICATE/high 相当の candidate にする（原則7）。**ただし §4.2 の canonical 状態分岐は L2 と同一に通す**（L0 一致=即却下ではない）
- **L1 機械・候補生成**: プール = 同一 repo の全 canonical。`TRIAGE_DEDUP_POOL_MAX`（既定 150）超過時は lexical top-K（K=20）に縮小し**レポート明示**。縮小時の類似度軸は **symptom(+interpretation) ベース**とし target 単独は禁止（target は不安定軸であることが #36 で実証済み）
- **L2 LLM 判定**: バッチ判定。出力契約（JSONL・1行ずつ jq スキーマ検証・**不正行はその finding のみ fail-closed**・バッチ全滅にしない）:
  `{finding_id, verdict: "DUPLICATE"|"DISTINCT", canonical_id?, confidence: "high"|"medium"|"low", shared_defect}`
  判定基準: 「**同一の欠陥で、修正が1箇所なら duplicate**。同一ファイルでも欠陥が別なら distinct。DUPLICATE/high は『別々に修正することはありえない』と言い切れる時だけ」
- **canonical 遷移解決（機械・パーサ契約を列挙仕様化）**: 実台帳の rejected 41件に5書式が実在（フルid/省略記号入り/8hexサフィックスのみ/文中埋め込み/複数参照）。解決規則:
  1. reason 中のフル finding_id（`rv-[a-z0-9-]+` が台帳 id 集合に完全一致）が**ちょうど1種** → それを参照とする
  2. 8hex サフィックスのみ → 台帳 id 集合への一意サフィックス照合。非一意は fail-closed
  3. 参照 0 件・複数種・省略記号でフル復元不能 → fail-closed（dup 連鎖しない・「要人裁定」欄）
  4. 起因分類は先頭一致のみ: `already fixed on main`→fixed 起因 / `deferred`→deferred 起因 / `duplicate of`・`duplicate/absorbed`→dup（遷移継続）/ その他（`intended design` 等の自由文）→**その他起因**（dup 却下可・DESIGN §8「rejected 類似は再提案しない」と整合）
  5. 遷移は深さ上限 10・ループ検出で fail-closed。実装1歩目に**既存台帳 41件のパース率棚卸し**を行い、5書式を fixture 化する
- **同バッチ内クラスタ（open×open）の canonical 選定**: 優先 ①current_status=adopted の member（複数なら fail-closed）②open の最古 `(night_id, ts, id)` 昇順 ③同値は fail-closed。**注**: 同夜 finding の ts は ingest 時刻で全席同一になるため、②は事実上 id（席名）辞書順の正規化である（構造的意味はない・決定論性のみが目的）。クラスタは推移閉包後に決定し、**閉包が予算打ち切りで未完のクラスタは decision もクラスタ提示も出さない**（部分採用禁止・「残差」欄で件数明示）

## 6. ALREADY_FIXED の証拠ゲート（機械・v1.1 強化）

LLM 出力契約: `{finding_id, verdict, file, line, quoted_line, removed_pattern, explanation}`

機械検証（**全 PASS で初めて** mode=reject の decision 化。1つでも FAIL → open 残し+「fixed 疑い・証拠不一致」欄）:

1. finding.target を `file[:anchor]` として解釈し、file 部と出力 `file` が同じ pinned SHA の clone 内実在ファイルを指す。散文、ディレクトリ、glob、`+` 等の複数ファイル連結は FAIL。パス述語は lib/verdict.sh の `safe_relative_path` と同一（制御文字・絶対パス・スキーム・`..` 拒否）+ symlink 拒否+realpath が clone 配下
2. `line` がファイル行数以内
3. `quoted_line`: 空白正規化後に**行完全一致**・正規化後 **20 字以上**・記号のみは拒否・`line ± 3` 窓内で**一意**（複数マッチは FAIL）・finding.target がファイルを指す場合は `file` と整合すること
4. **不在証明**: `removed_pattern` は POSIX 拡張正規表現（ERE）のみ。空白正規化後8字以上で、`file` 内に 1 件もマッチしないこと（「新しい行がある」でなく「古い形が消えている」が ALREADY_FIXED の本質）
5. **履歴ゲート**: `git log --since=<finding.date> -- <file>` が非空（報告日以降に当該ファイルが変更されていなければ fixed は原理的に不可能）。このため A2 の clone は blob:none の partial clone 等**履歴を保持する形**にする（§8 A2）
6. rejection_reason は機械テンプレ生成のみ

これは「LLM の主張の物理的裏付け」であり意味論の最終保証ではない。残存リスクは §4.1 の段階運用（suggest 既定）+ G5 + 可逆性で受ける。CI に「実在するが無関係な行を引く stub」「短い自明行を引く stub」の **negative fixture** を置き、ゲートが素通りしないことを常時検証する。

## 7. actor / source / source_ref（決定ログ D-1, D-3）

- `actor: "auto-triage"` / `source: "manual-comment"` / `source_ref: <検証済みレポートコメントの html_url>`
- source 語彙は**拡張しない**（D-1）: 語彙追加は両検証（lib/verdict.sh:52-53・lib/ledger.sh:159-161）の改変=台帳形式変更で決裁違反
- レポート投稿先: 実装時に新設する「auto-triage 実行記録」Issue（**pinned + locked** で保護 — source_ref の dead link 化防止。closed/削除しない運用を README 明記）。config の Issue 番号は起動時に `pull_request` キー不在（Issue であること）を検証
- 投稿検証: POST 応答の `.id` と `.url`（API URL）を保持 → `gh api --method GET <api url>` → `.id` 一致 **かつ** body に run_id nonce を含む → PASS 時のみ `.html_url` を source_ref に採用（「200 が返った」だけの検証は素通りするため禁止・503 エラー JSON 対策込み）
- レポート本文は**必ず Markdown**（本文単体が JSON として parse 可能な形にしない — 将来の `--github-links` 経路の verdict-marker 誤認防止）。コメントは 60KB 上限で証拠を切り詰める（超過分は state 内レポートへのパス参照）
- **GitHub 不達なら書込み中止**（D-3）: decisions は draft のまま・翌朝再導出。「台帳に書いたのに公開記録が無い」状態を作らない

## 8. 実行フェーズと競合安全（v1.1 改訂）

```
bin/morning-triage [--dry-run] [--force] [--state-dir <abs>] [--repo-pin <repo>=<sha>]
  起動: 実行窓検査（§2-7）→ nightshift.lock 取得（失敗=即 exit 1・二重起動の敗者はここで終わる）
  Phase A（ロック保持・read-only）
    A1 台帳投影（本物の ledger_project_findings・STATE_DIR 経由）→ open 一覧+canonical プール+**ウォーターマーク時刻確定**
    A2 対象 repo を fresh clone（--filter=blob:none で履歴保持・--repo-pin はその SHA を checkout・клоны は staging dir 配下）
    A3 Stage D: 重複照合（前回 run 以降の新規 finding は全件必須対象・L0→L2）
    A4 Stage V: 対 main 検証（古い順・last-verified-at スキップ付き・上限件数）
    A5 decisions.draft.jsonl（**source_ref キーなし** — 万一そのまま sync に流れても validator が確実に落とす）+ report.md 生成
  Phase B（ロック保持のまま）
    B1 再検証: 台帳を再投影し ①対象 finding が open のまま ②canonical 解決（機械部分）の再実行で分岐不変 — を確認。不一致 decision は drop し**レポート本文に反映**（「人裁定先行」欄）
    B2 レポートコメント投稿 → §7 の検証 → PASS で source_ref を埋めた decisions.jsonl を tmp→mv で確定
    B2.5 機械ゲート: `jq -e 'all(.status == "rejected")'`（自動 adopted/fixed の構造的禁止）
  ロック解放 → B3 verdict-sync --input decisions.jsonl（verdict-sync が自らロック取得・失敗時 60s×5 リトライ）
  B4 結果コメント（B2 投稿成功後は best-effort。appended/idempotent/dropped の3値+B2.5/B3失敗を投稿。コメント経路確立前の lock/設定/投影/clone/HARD_WALL/POST エラーは state ログのみ）
```

- 分析〜B2 のロック保持により、人裁定（verdict-sync）は当該時間帯 fail-fast する（数分・06:35 台の実害なし）。それでも B3 直前のロック解放〜verdict-sync 再取得の微小窓は残る — §2-6 のウォーターマークが第二の網（stale でバッチ全滅=fail-closed）
- バッチ全滅 = 全体不採用は verdict-sync の既存挙動を採用。翌朝 A1 から再導出（部分適用・再送管理を自作しない）。**系統的失敗**（毒 decision で毎朝全滅）は B4 の必須失敗コメントで可視化される
- 既知の副作用: verdict-sync は decision ごとに `state/verdicts/finding-<sha>/L1-7-draft.md` を生成する（lib/verdict.sh:848-908・自動却下でも生成される）。退場トリガー（LC-1）: 週次お片付けレポートの検知対象に含め、rejected 確定から 30 日で人が手動退蔵
- `--state-dir` はリプレイ用の完全隔離（ledger・locks・triage state 全部その配下）。`--dry-run` は Phase A のみ実行し decisions.draft.jsonl と report.md を書いて終了（GitHub・verdict-sync に触れない）

## 9. リプレイ受入基準（#36 の46件・機械判定・v1.1 再定義）

ハーネス: `tests/replay/replay-36.sh`（ネットワーク+LLM 使用のため `test_*.sh` 命名にしない=CI 自動発見から除外）

- 入力: ①現行 ledger から `issues/36` の verdict 46件を除外した再構成台帳（実測済み: 本物投影で open=46）②caty-agent-harness `b7e1be1` の履歴付き clone ③`tests/replay/fixtures/ground-truth-36.jsonl`（台帳から機械生成済み: finding_id / human_class(adopted|already_fixed|duplicate|superseded|deferred) / human_canonical。35977df7 は hybrid フラグ=両経路許可）
- 実行: `morning-triage --dry-run --state-dir <隔離> --repo-pin caty-agent-harness=b7e1be1` + リプレイ config（全46件処理・reject モード・上限緩和）
- **root(x) の定義**: `root(x) = human_canonical(x) が非 null ならそれ、さもなくば x`（クラスタ同値はこの root の一致で判定）
- 合否（すべて機械判定・いずれか FAIL でハーネス exit 1）:

| # | ゲート | 基準 |
|---|---|---|
| G0 | 前提健全 | 再構成台帳が本物の投影で clean に通り open がちょうど46件 |
| G1 | 非矛盾 | decisions（auto 却下）に人裁定 adopted の24件が**1件も現れない**。全46件が open の本リプレイでは dup 側 decision は構造上出ない（§4.2 open 分岐）ため、実質 ALREADY_FIXED 経路の検査となる |
| G2 | dup 検知 recall | **クラスタ提示出力**で、人裁定 dup 15件の各 member がいずれかの提示クラスタに含まれ、そのクラスタの canonical の root が human_canonical の root と一致する。35977df7 のみ「dup クラスタ member」or「ALREADY_FIXED 経路」の両方を許可（hybrid） |
| G3 | dup 検知 precision | 非重複31件が**どの提示クラスタにも dup member として現れない**（クラスタ root として現れるのは可） |
| G4 | （G2 に統合） | — |
| G5 | fixed 非矛盾 | ALREADY_FIXED 経路（decision+推奨とも）が人裁定の「main済6件 ∪ 35977df7」の**外に出ない** |

| G6 | dup 却下経路の実データ検証 | **確定 canonical 派生 fixture**: 再構成台帳の変種（dup クラスタの canonical 9件の adopted verdict と deferred canonical の rejected verdict だけを残し、他の #36 verdict を除外）を `TRIAGE_ALREADY_FIXED_MODE=suggest` で再実行する。Stage D は open 本走の検証済み `dedup/*/final.jsonl` から15件の確定判定を機械生成して決定論再生し、①15件の dup が settled canonical への自動却下 decision として draft に現れ ②その decisions.jsonl（source_ref はダミー URL 注入）を**実物の verdict-sync --input** に隔離 state-dir で通し observed=appended・投影 rejected 化を確認（§4.2 上2行+B 経路が実データで最低1本走る）。LLM 頑健性は open 本走の G2/G3 が担当する |

- 参考指標（合否外・レポート表示）: already-fixed 検出率（目標 6/6）・CONFIRMED_CURRENT 率・LLM 呼数・所要時間
- **合格条件は record パス1回 + cache 再生1回**（cache 再生は決定性検査であり独立検証ではない。LLM 非決定性に対する頑健性は record パスを別途反復して確認する）
- **record/replay モード**: 初回実走で LLM 応答を fixture 保存 → 以降の反復はキャッシュ再生でゲート再判定（プロンプト以外の調整を課金なし・決定論で回帰テスト化）。プロンプトを変えたら再実走
- G2 未達はプロンプト/しきい値の反復調整（fail-closed 側の失敗）。**G0/G1/G3/G5/G6 の失敗は設計欠陥として判定基準でなく構造を直す**

## 10. コスト上限と締切（config・`TRIAGE_*` 名前空間・v1.1 改訂）

| キー | 既定 | 意味 |
|---|---|---|
| TRIAGE_ENABLED | 0 | 明示 opt-in |
| TRIAGE_ALREADY_FIXED_MODE | suggest | suggest=推奨提示のみ / reject=自動却下（§4.1・昇格は D-6） |
| TRIAGE_MAX_VERIFY_PER_RUN | 25 | Stage V 対象上限（古い順・**last-verified-at が TRIAGE_REVERIFY_INTERVAL_DAYS 以内の finding はスキップ**=毎朝の再検証飢餓を防ぐ。スキップ・繰越は種別明示） |
| TRIAGE_REVERIFY_INTERVAL_DAYS | 7 | 再検証間隔（triage state に保存・台帳不変） |
| TRIAGE_MAX_NEW_FOR_DEDUP | 40 | Stage D は**前回 run 以降の新規 finding を全件必須対象**（夜またぎ dedup の本丸を予算で飢餓させない・超過時のみ繰越+明示） |
| TRIAGE_VERIFY_BATCH / TRIAGE_DEDUP_BATCH | 5 / 10 | 1 LLM 呼あたりの finding 数 |
| TRIAGE_CONCURRENCY | 3 | 並列 adapter 呼数（算術: V≤5呼+D≤4呼 ≈ 9呼 / 3並列 × ~5分 ≈ 15分） |
| TRIAGE_LLM_TIMEOUT_SEC | 300 | 1呼あたり |
| TRIAGE_PHASE_A_DEADLINE_SEC | 900 | LLM ステージ締切（超過=打ち切り・確定分のみ B へ・バッチ粒度） |
| TRIAGE_HARD_WALL | 06:58 | この時刻を過ぎていたら Phase B に入らない（レポートはローカル保存・翌朝再導出）。07:05 morning-report との整合保証 |
| TRIAGE_DEDUP_POOL_MAX | 150 | §5 L1 プール上限 |
| TRIAGE_ADAPTER | lanes/review/adapters/codex.sh | 席アダプタ（契約共有・移動しない） |
| TRIAGE_REPORT_ISSUE | （必須） | 実行記録 Issue 番号（起動時に Issue kind 検証） |
| TRIAGE_TARGET_REPOS | （必須） | `<台帳repo名>=<owner/name>` 対応表。**台帳に存在するが対応表に無い repo の open findings は「対象外 repo」として件数+warning をレポート必須**（コスト繰越と区別・silent skip 禁止） |

定時: `launchd/ai.caty.nightshift.triage.plist` 06:35 + §2-7 実行窓ガード。

## 11. 触るファイル（WIP 宣言と一致）

新規: `bin/morning-triage` / `lib/triage.sh` / `templates/triage-verify.tmpl.md` / `templates/triage-dedup.tmpl.md` / `launchd/ai.caty.nightshift.triage.plist` / `tests/test_triage_failclosed.sh` / `tests/test_triage_dedup.sh` / `tests/test_triage_decisions.sh` / `tests/fixtures/triage/**` / `tests/replay/replay-36.sh` / `tests/replay/fixtures/ground-truth-36.jsonl` / `docs/morning-triage.md`（本書）

変更: `config/nightshift.conf.example` / `README.md`（triage 節: 運用・ウォーターマークと復旧手順・実行記録 Issue 保護）/ `DESIGN.md`（§8 参照1行）

**変更しない**: `bin/verdict-sync` / `lib/verdict.sh` / `lib/ledger.sh` / `lib/lock.sh` / 夜間 dispatch 系 / `lanes/review/**` / `tests/run_tests.sh`（test_*.sh は自動発見・登録不要） / `alpha-nightshift-local/**`

## 12. テスト計画（CI = LLM なし・stub adapter・決定論）

- fail-closed 網羅: LLM 出力不正（行単位 fail-closed の粒度検証込み）/ 証拠ゲート6段の各 FAIL / **negative fixture**（実在する無関係行・自明短行・removed_pattern 残存・履歴なし）/ canonical パーサ5書式（実台帳から fixture 化）+ 非一意サフィックス + 複数参照 + ループ / fixed・open・already-fixed 起因 canonical の各分岐 / confidence=medium / コスト・締切・HARD_WALL 超過 / GitHub 不達で B 中止 / B1 の drop（finding 側+canonical 側の両方）/ 実行窓外 exit / 二重起動（ロック敗退）/ dry-run の不書込み
- 決定合成: 生成 decision が**実物の `verdict_validate_decision` を通る**こと（lib/verdict.sh を source）/ **全 decision が actor=`auto-triage`・source=`manual-comment` 固定値であること** / draft に source_ref キーが無いこと・確定版で埋まること / B2.5 の all-rejected ゲート / observed_at =ウォーターマーク固定・全件同一 / 同一 finding への二重 decision の機械 dedup / dup 理由テンプレに evidence anchor と起因種別が埋まること
- L0 完全一致 / クラスタ canonical 優先順位（adopted member 優先・同値 fail-closed）/ 閉包未完クラスタの部分採用禁止
- リプレイハーネス自体の G0〜G5 判定ロジック（縮小 fixture で PASS/FAIL 両分岐）

## 13. 決定ログ（clarify バッチ+v1.1 追加・Hands-off につき推奨案で自動確定/事後確認ポイント）

| # | 論点 | 採用 | 一言根拠 |
|---|---|---|---|
| D-1 | source 語彙 | `manual-comment` 据え置き+actor=`auto-triage` | 語彙追加=台帳スキーマ変更で決裁違反 |
| D-2 | adopted canonical への再発見 | 新 finding へ dup-reject verdict（再発見回数=投影導出） | immutable 維持・正本分裂回避 |
| D-3 | source_ref | 検証済みコメント URL 必須・不達なら書込み中止 | 公開記録なき機械裁定を作らない |
| D-4 | dedup 実行点 | 朝 triage 時 | 夜のロック保持中に LLM を入れない・証跡が台帳に残る |
| D-5 | 定時 | 06:35+実行窓ガード | digest 後・morning-report 前・スリープ復帰対策 |
| D-6 | ALREADY_FIXED 段階運用 | suggest 既定→実測後 reject 昇格。**昇格基準（数値）**: fixed 推奨の人検分 累計 ≥15件・false-fix 0件・suggest 運用 14 日経過の3条件成立で reject 昇格をオーナーに提案。**退場トリガー（LC-1）**: 2026-09-15 までに昇格可否の判断を仰ぐ（suggest 恒久化=自動化の実効値ほぼゼロを防ぐ） | 証拠ゲートは物理裏付けまで・意味論の残存リスクは実測ゼロを見てから自動化（席 C2/C3/N4 反映）。suggest 期間中の自動却下は dup（確定 canonical）のみで、v1 出荷時の実効値が限定的であることは既知・意図的 |
| D-7 | 競合安全の主防御 | Phase A〜B2 ロック保持+observed_at ウォーターマーク | 運用規律でなく既存コードの検証を防壁化（席3席収束） |
| D-8 | open canonical への自動却下 | しない（クラスタ提示のみ） | 「自動却下の根拠は必ず確定 verdict 済み」の不変条件で矛盾書込みを構造的に排除（席 C1 反映） |

**オーナー事後確認ポイント: D-1 / D-3 / D-6**（D-6 の reject 昇格は実測レポート添付で改めて確認する）

## 14. 設計レビュー記録（L1-9・2026-08-18）

- 席: Kimi K3（正式ファイル納品・GO-with-changes・C1+M4+m6）/ Opus 5（requested=opus-5, actual=opus-5・ファイル書込みが席サンドボックスで不能のため SendMessage 納品・GO-with-changes・C3+M8+m8）/ GLM 5.3（初回沈黙→再試行1回で正式納品・GO-with-changes・C1+M6+m5）
- 収束（複数席独立=採用確定級）: observed_at 未指定（3席）/ open canonical 自動却下の矛盾経路（3席）/ 証拠ゲート素通り形（3席）/ canonical パーサ契約（2席）/ クラスタ粒度の受入再定義（3席）/ B2-B3 整流と二重起動（3席）
- 全 findings の裁定と反映は #37 のレビュー裁定コメント参照。不採用: Kimi「B1 を B2 後へ移動」（ロック保持設計で上位互換に置換）・Opus「morning-report を 07:15 へ」（HARD_WALL で解決・他系統の変更を避ける）
- coverage-matrix（Opus 席 delta・spec-kit 実験）: zero-coverage 0・unrequested MAJOR 0・前回19件=18 RESOLVED/1 PARTIAL 許容・累積 GO。新規 N1〜N5 は v1.1 に反映済み（N1→§9 G6・N2→§12 actor/source 検証復活・N3→§4 dup テンプレ evidence anchor・N4→D-6 数値昇格基準+退場トリガー・N5→§4 再発見回数の表示列）。M2 PARTIAL への追補=「その他起因」継承時は理由文に起因1語を明示（§4 テンプレ）
