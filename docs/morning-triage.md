# morning-triage 設計書 v1.0 — 朝の裁定自動化 (#37) + 夜またぎ重複検知 (#38)

- 起点: shojikumaru/alpha-nightshift #37 / #38（設計は合同1本・Issue は分離のまま）
- 作成: Alpha 2026-08-18 / 翔さん決裁: 自動化 GO・Hands-off（push まで自走・事後確認）
- サイズ: **L**（loom-seats 決定論判定・席= Kimi K3 + Opus 5 + GLM 5.3・writer= codex-sol）
- 上位設計: `DESIGN.md` §8（dedup 3段）・§9（朝ダイジェスト）・原則4「precision 優先」・原則7「反射=機械/熟考=LLM」

## 0. 一言で

毎朝、open findings を最新 main への read-only 検証と台帳全体との重複照合にかけ、**機械的に決まる却下だけ**を `verdict-sync` 経由で自動記録し、残り（採用候補・regression 疑い・グレー）は**証拠つきの推奨として人裁定キューに残す**デイタイム・コアコマンド。

## 1. スコープと非スコープ

### やること（v1）

| # | 内容 | Issue |
|---|---|---|
| 1 | open findings の対 main 自動検証（CONFIRMED_CURRENT / ALREADY_FIXED / NOT_REPRODUCIBLE / UNCLEAR） | #37 |
| 2 | 自動却下 2類型のみ: ①ALREADY_FIXED（main の行を指せる+引用行の機械照合 PASS） ②高確度 DUPLICATE（canonical 参照つき） | #37 |
| 3 | 夜またぎ重複照合（新規 open × 台帳全体の canonical・3層キー構造） | #38 |
| 4 | fixed への一致 = **regression 疑い**としてレポート提示のみ（verdict は書かない） | #38 |
| 5 | 採用候補・グレー残差の朝レポート（証拠+推奨つき・GitHub コメント投稿） | #37 |
| 6 | #36 の46件リプレイ検証ハーネス | 両方 |
| 7 | launchd 定時実行（06:35・digest 06:30 と morning-report 07:05 の間） | #37 |

### やらないこと（v1 明示非スコープ）

- **自動「採用」**（採用=修正リソース割当て= Alpha/オーナー専決。決裁事項）
- **regression verdict の書込み**（`verdict-sync --input` の受理語彙は adopted/fixed/rejected のみ。台帳形式を変えないため、regression はレポート提示に留める。再オープンは DESIGN §8 のとおり目付の体験 or 人裁定側）
- NOT_REPRODUCIBLE の自動却下（R-1 は「再現不能の記録付き」却下を許すが、今回の決裁は自動却下 2類型限定。人裁定キューへ）
- deferred の自動判定（価値判断）
- embedding アダプタ（DESIGN §8 の②層。プール規模 112 では不要。将来のスケール対策として config に空スロットのみ確保）
- `alpha-nightshift-local/`（morning-report.sh）の改修 — triage は台帳と GitHub コメントにだけ書き、morning-report は従来どおり台帳投影を読む（改修不要で 07:05 に triage 結果が反映される）
- 夜間 ingest 経路（`ledger_ingest_proposals` / `duplicates_skipped`）の変更 — 夜またぎ dedup は朝 triage 側に置く（§3 理由）

## 2. 不変条件（決裁済み制約の設計への写像）

1. **台帳形式不変**: 書込みは `verdict-sync --input` のみ。lib/verdict.sh・lib/ledger.sh・bin/verdict-sync は**一切変更しない**。イベント immutable・訂正は新イベント
2. **fail-closed**: 確信が持てない finding は open のまま残す。LLM 出力の不正・証拠ゲート不一致・コスト超過・GitHub 不達 → すべて「書かない」側に倒す
3. **可逆性**: 自動却下は人が `rejected → adopted`（actor ≠ night-bot で合法遷移）で上書き可能。自動 verdict はこの遷移を塞ぐ状態を作らない（fixed を書かない理由でもある）
4. **actor 名義**: `auto-triage` 固定。人間の verdict と機械の verdict は actor で常に区別可能
5. **単一 writer**: 台帳書込みは verdict-sync が `state/locks/nightshift.lock` を取る既存規律のまま。triage の分析フェーズはロック外・read-only
6. **no silent caps**: コスト上限・プール上限・打ち切りが発生したら必ずレポートに残件数を明示

## 3. アーキテクチャ配置

```
夜:  nightshift-dispatch ── lanes ──> 提案 ──> ledger_ingest_proposals（レーン内 dedup: 完全一致 id のみ・現状維持）
                                                    │ finding (open)
朝:  06:30 digest ──> 06:35 morning-triage ─────────┤
       Phase A(ロック外・read-only): 台帳投影 → fresh clone → 検証(LLM) → 重複照合(機械+LLM) → decisions.jsonl + report
       Phase B(書込み): report を GitHub コメント投稿 → URL 検証 → verdict-sync --input（ロックは verdict-sync が取得）
     07:05 morning-report（既存・無改修・triage 済みの台帳投影を読む）
```

**dedup を ingest 時でなく朝 triage 時に置く理由**（#38 の「ingest 時 or triage 時」の裁定）:

- 夜間クリティカルパス（ロック保持中の dispatcher）に LLM 呼び出しを入れない
- 重複も一度 finding として台帳に載ってから dup-reject される方が、**再発見の証跡が台帳に残る**（#38 の副次価値。canonical X への dup-reject verdict の件数 = 再発見回数、が投影で導出できる。台帳外カウンタ不要・追記型維持）
- suppress 方式（台帳に載せない）は「何を隠したか」が台帳から消え、fail-closed 検証ができない

## 4. 自動裁定の類型（決定表）

LLM 判定はすべて**機械の証拠ゲートを通過して初めて**decision になる。ゲート不通過は open 残し。

| LLM 判定 | 機械ゲート | 台帳アクション | rejection_reason 様式（機械生成） |
|---|---|---|---|
| ALREADY_FIXED | §6 引用行照合 PASS | rejected (auto) | `already fixed on main <sha>: <説明> (<file>:<line>); not a false positive` |
| DUPLICATE / confidence=high | §5 canonical 解決 PASS | rejected (auto) | `duplicate of <canonical_id> (<共通欠陥の一言>[, canonical is deferred]); not a false positive` |
| DUPLICATE / canonical が fixed | — | **書かない** | レポート「regression 疑い」欄へ |
| DUPLICATE / confidence=medium,low | — | 書かない | レポート「dup 疑い・要人裁定」欄へ |
| CONFIRMED_CURRENT | 現存証拠 (file:line) 添付 | 書かない | レポート「採用候補・推奨つき」欄へ |
| NOT_REPRODUCIBLE | — | 書かない | レポート「要人裁定」欄へ |
| UNCLEAR / 出力不正 / タイムアウト | — | 書かない | レポート「残差」欄へ（件数明示） |

rejection_reason の様式は #36 の人裁定 46件と同型（`; not a false positive` 終端を含む）。既存台帳との読み味を揃える。

## 5. 照合キー層構造（#38 の核・DESIGN §8「dedup 3段」への対応）

実測根拠: #36 の重複15件の target 表記は不統一（`task-runner.sh:1552` vs `task-runner.sh:recover_verifying` vs `ヘルスチェックの状態表示` vs 別ファイル `docs/reference.md` → canonical は `install.sh --check` 系）。**決定論キーの完全一致では15件中ほぼ0件しか拾えない**。よって機械層は「確実に同じもの」だけを取り、本命は LLM 層に置く。

- **L0 機械・完全一致**（DESIGN §8 ①）: `repo + norm(target) + kind + norm(symptom)` のハッシュ完全一致 → LLM を通さず dup 確定（原則7）。norm = NFC・小文字化・空白圧縮
- **L1 機械・候補生成**: 照合プール = 同一 repo の全 canonical（open の先行 finding + adopted + rejected + fixed + deferred）。プールが `TRIAGE_DEDUP_POOL_MAX`（既定 150）超なら lexical 類似 top-K（K=20）に縮小し**レポートに縮小を明示**。現状 112 件なので v1 は常に全プール
- **L2 LLM 判定**（DESIGN §8 ③）: 新規 open × プールをバッチ判定。出力契約（JSONL・jq スキーマ検証・不正は fail-closed）:
  `{finding_id, verdict: "DUPLICATE"|"DISTINCT", canonical_id?, confidence: "high"|"medium"|"low", shared_defect: "<一言>"}`
  判定基準をプロンプトで固定: 「**同一の欠陥で、修正が1箇所なら duplicate**。同一ファイルでも欠陥が別なら distinct」（#36 の人裁定基準そのまま）
- **canonical 解決（機械）**: LLM が指した canonical_id を台帳投影で解決
  - canonical が dup-reject 済み → その rejection_reason 中の canonical へ**遷移的に根まで解決**（深さ上限 10・ループ検出で fail-closed）
  - 根 canonical の current_status: `open|adopted` → dup 却下可 / `rejected(deferred 起因)` → dup 却下可+`canonical is deferred` 注記（#36 e87a215a の人裁定パターン）/ `rejected(already-fixed 起因)` → dup 却下せず、その finding 自身の ALREADY_FIXED 検証結果に委ねる（証拠は自前で持たせる）/ `fixed` → regression 疑い（書かない）
  - canonical_id が台帳に存在しない → fail-closed（open 残し・レポート）
- **同バッチ内クラスタの canonical 選定（機械）**: open 同士が相互 dup の場合、最古 `(night_id, ts, id)` 昇順の1件を canonical とし残りを dup 側へ。クラスタ推移閉包後に決定

## 6. ALREADY_FIXED の証拠ゲート（機械）

LLM 出力契約: `{finding_id, verdict: "ALREADY_FIXED", file, line, quoted_line, explanation}`

機械検証（全部 PASS で decision 化・1つでも落ちたら open 残し+レポート「fixed 疑い・証拠不一致」）:

1. `file` が pinned SHA の clone に存在（symlink 拒否・repo 外パス拒否）
2. `line` がファイル行数以内
3. `quoted_line` が `line ± 3` 行以内に現存（空白正規化して比較・空文字列は拒否）
4. rejection_reason は機械テンプレで生成（LLM の自由文を直接台帳に入れない。explanation は 200 字に切り詰め・改行/パイプ除去）

これは「LLM の主張を台帳に書く前に、主張の物理的裏付けだけは機械で確認する」ゲート。意味論の最終保証ではない（残存リスクは §9 リプレイと可逆性 §2-3 で受ける）。

## 7. actor / source / source_ref（決定ログ D-1, D-3）

- `actor: "auto-triage"` / `source: "manual-comment"` / `source_ref: <triage 実行レポートのコメント URL>`
- source 語彙は**拡張しない**（D-1）: `auto` 追加は lib/verdict.sh + lib/ledger.sh 両検証の改変=台帳形式変更に該当し決裁違反。機械/人の区別は actor が担う（#37 本文の指定どおり）
- レポート投稿先: 実装時に新設する「auto-triage 実行記録」Issue（pinned・1 run = 1 コメント）。POST は REST（503 対策）→ 応答 `html_url` を **GET で再検証**（503 のエラー JSON を stdout に出す gh の罠対策・handoff 実測）→ 検証済み URL を source_ref に採用
- **GitHub 不達なら Phase B を丸ごと中止**（decisions は state に保存・レポートはローカル保存・翌朝再導出）。「台帳に書いたのに公開記録が無い」状態を作らない（fail-closed の一部）

## 8. 実行フェーズと競合安全

```
bin/morning-triage [--dry-run] [--ledger <path>] [--repo-pin <repo>=<sha>]
  Phase A（ロック外・read-only・冪等）
    A1 台帳投影（ledger_project_findings 相当を read-only 利用）→ open 一覧+canonical プール
    A2 対象 repo を scratch に fresh shallow clone・HEAD SHA 記録（--repo-pin はリプレイ用）
    A3 Stage V: 対 main 検証（LLM・上限内・古い finding 優先）
    A4 Stage D: 重複照合（L0 機械 → L2 LLM）
    A5 decisions.jsonl + report.md を state/triage/<run_id>/ に生成
  Phase B（--dry-run では実行しない）
    B1 直前に台帳を再投影し、current_status ≠ open の finding を decisions から**落とす**（分析中の人裁定を上書きしない・落とした件数はレポートに明示）
    B2 レポートを GitHub コメント投稿 → URL 検証 → 全 decision の source_ref に埋める
    B3 verdict-sync --input decisions.jsonl（ロック取得は verdict-sync・失敗時 60s×5 リトライ）
    B4 sync 結果（observed/appended/idempotent）を同 Issue に後続コメント（best-effort）
```

- **バッチ失敗 = 全体不採用**は verdict-sync の既存挙動をそのまま採用（fail-closed。翌朝 A1 の再投影から自然に再導出されるので、部分適用や再送管理を自作しない）
- 二重起動: launchd の単一スケジュール+verdict-sync ロックで担保（第2走者は B3 で敗退し全体中止）。triage 自前のロックは持たない（新しい鍵を増やさない）
- 人裁定との競合窓は B1 の再投影で秒オーダーまで縮む。残存窓で人の adopted に auto の rejected が重なった場合も §2-3 の可逆遷移で復旧可能

## 9. リプレイ受入基準（#36 の46件・機械判定）

ハーネス: `tests/replay/replay-36.sh`（ネットワーク+LLM を使うため `run_tests.sh` の既定スイートには**入れない**。手動/レーン起動）

- 入力: ①現行 ledger.jsonl から `source_ref = …issues/36` の verdict 46件を除外した再構成台帳（46件が open だった状態の復元） ②caty-agent-harness `b7e1be1` の pinned clone ③正解表 `tests/replay/fixtures/ground-truth-36.jsonl`（#36 決定表の機械化: finding_id / human_verdict / human_canonical）
- 実行: `morning-triage --dry-run --ledger <再構成台帳> --repo-pin caty-agent-harness=b7e1be1`（GitHub 投稿なし・sync なし・コスト上限はリプレイ用に緩和 config）
- 合否（すべて機械判定・1つでも FAIL でハーネス exit 1）:

| # | ゲート | 基準 |
|---|---|---|
| G1 | 非矛盾 | 人裁定 adopted 24件が decisions に**1件も現れない** |
| G2 | dup recall | 人裁定 重複15件（superseded の 35977df7 含む）が**全件** decisions の rejected に現れる（dup 経路 or already-fixed 経路のどちらでも「拾った」と数える） |
| G3 | dup precision | 非重複31件（採用24+main済6+deferred1）に **dup 却下ゼロ**（誤併合ゼロ） |
| G4 | canonical 一致 | dup 却下の canonical が、人裁定 canonical と**同一クラスタ根**に解決される |
| G5 | fixed 非矛盾 | already-fixed 経路の自動却下が、人裁定の「main 済6件 or 35977df7」の外に**出ない** |

- 参考指標（合否に入れない・レポートに出す）: already-fixed 検出率（目標 6/6）・adopted 24件の CONFIRMED_CURRENT 率・LLM 呼数・所要時間
- G2 が未達の間はプロンプト/しきい値を反復調整して再実行（fail-closed 側の失敗なので安全に反復できる）。**G1/G3/G5 の失敗は設計欠陥として扱い、しきい値でなく判定基準を直す**

## 10. コスト上限と締切（config・`TRIAGE_*` 名前空間）

| キー | 既定 | 意味 |
|---|---|---|
| TRIAGE_ENABLED | 0 | 明示 opt-in（conf 未設定ホストでは何もしない） |
| TRIAGE_MAX_FINDINGS_PER_RUN | 25 | 1回の検証対象上限（古い順・超過分は翌朝へ・レポート明示） |
| TRIAGE_MAX_LLM_CALLS | 40 | 検証+dedup 合計呼数上限 |
| TRIAGE_LLM_TIMEOUT_SEC | 300 | 1呼あたり |
| TRIAGE_DEADLINE_SEC | 1500 | 全体締切（超過時点で打ち切り・確定分のみ Phase B へ） |
| TRIAGE_DEDUP_POOL_MAX | 150 | §5 L1 プール上限 |
| TRIAGE_ADAPTER | lanes/review/adapters/codex.sh | 席アダプタ（review レーンと同一契約 `(prompt_file, workdir, out_dir)`・アダプタは移動しない） |
| TRIAGE_REPORT_ISSUE | （必須・番号） | 実行記録 Issue 番号 |
| TRIAGE_TARGET_REPOS | （必須） | `owner/name` カンマ区切り。台帳 repo 名との対応表 |

定時: `launchd/ai.caty.nightshift.triage.plist` 06:35（digest 06:30 の完了後・morning-report 07:05 の前に台帳へ反映が終わる設計。締切 1500s は 07:00 終了を保証）

## 11. 触るファイル（WIP 宣言と一致させる）

新規: `bin/morning-triage` / `lib/triage.sh` / `templates/triage-verify.tmpl.md` / `templates/triage-dedup.tmpl.md` / `launchd/ai.caty.nightshift.triage.plist` / `tests/test_triage_failclosed.sh` / `tests/test_triage_dedup.sh` / `tests/test_triage_decisions.sh` / `tests/fixtures/triage/**` / `tests/replay/replay-36.sh` / `tests/replay/fixtures/ground-truth-36.jsonl` / `docs/morning-triage.md`（本書）

変更: `config/nightshift.conf.example`（TRIAGE_* 追記）/ `README.md`（Record morning verdicts 節の下に triage 節）/ `tests/run_tests.sh`（新テスト3本の登録）/ `DESIGN.md`（§8 に本書への参照 1 行）

**変更しない**: `bin/verdict-sync` / `lib/verdict.sh` / `lib/ledger.sh` / `lib/lock.sh` / 夜間 dispatch 系 / `lanes/review/**` / `alpha-nightshift-local/**`

## 12. テスト計画（CI = LLM なし・決定論）

stub アダプタ（fixture の応答を返すだけ）で:

- fail-closed 網羅: LLM 出力不正 / 証拠ゲート各段の不一致 / canonical 不在 / canonical ループ / fixed canonical / confidence=medium / コスト・締切超過 / GitHub 不達（B 中止）/ B1 の非 open 脱落
- 決定合成: rejection_reason テンプレの形式（`verdict_validate_decision` を実際に通して受理されること）/ actor・source 固定値 / dry-run が state 外に何も書かないこと
- L0 完全一致 dedup / クラスタ canonical 選定の決定論性
- リプレイハーネス自体の合否判定ロジック（正解表 fixture の縮小版で G1〜G5 の PASS/FAIL 分岐）

## 13. 決定ログ（clarify バッチ・spec-kit 様式・Hands-off につき推奨案で自動確定/事後確認ポイント）

| # | 論点 | 採用 | 代替案と不採用理由 |
|---|---|---|---|
| D-1 | source 語彙 | `manual-comment` 据え置き+actor で機械区別 | `auto` 語彙追加は台帳スキーマ変更（決裁違反）。旧投影コードが新イベントで全滅するリスクも |
| D-2 | adopted canonical への再発見 | 新 finding に dup-reject verdict を積む（再発見回数=投影導出） | canonical レコードへの追記は immutable 違反。台帳外カウンタは正本分裂 |
| D-3 | source_ref | GitHub コメント URL 必須・不達なら書込み中止 | ローカルパス source_ref は「公開記録なき機械裁定」を許してしまう。#34/#36 の URL 慣行とも不整合 |
| D-4 | dedup の実行点 | 朝 triage 時（夜 ingest は現状維持） | §3 のとおり。夜のロック保持中 LLM・証跡消失を避ける |
| D-5 | 定時 | 06:35（digest 後・morning-report 前） | 夜間実行は dispatch と鍵を取り合う。07:05 後だと当日レポートに乗らない |

いずれも本文に根拠を展開済み。**翔さん事後確認ポイント: D-1 と D-3**（台帳の意味論に関わるため。異議があれば verdict イベントは可逆なので巻き戻し可能）
