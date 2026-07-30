# alpha-nightshift（夜番）設計書 v0.1

- status: **council-reviewed draft**（5席レビュー反映済み・repo 新設と起票は翔さん判断待ち）
- date: 2026-07-29（v0 同日 council: Kimi/Opus/GLM=全体, Grok/Fable=§10 敵対。採否= `reviews/2026-07-29-design-v0/DISPOSITION.md`）
- owner: Alpha（翔さんとの壁打ち 2026-07-28〜29 の決定を統合）
- scope: v0 = 保守2レーン（UX目付＋バックヤード）。v0.1 = 生成レーン追加（persona-engine）

## 0. 一言で

完成後（または開発中）のシステムに対し、夜間に git worktree 隔離で「観測 → 合議 → Issue → 実装 → 検証 → パケット化」を**必ず完走**させ、人間（翔さん）は朝の確認予算内で PR 単位のチェリーピックだけを行う、証拠駆動の夜間保守ループ。

## 1. 目的と非目標

**目的**
- 人間の睡眠時間を、システムの保守・検証・研磨の稼働時間に変える
- 人間の関与を4点に圧縮する: ①repo 指定 ②GOALS 承認 ③朝のチェリーピック ④main 適用
- OSS として公開可能な汎用ツールとして設計する（特定環境専用にしない）

**非目標**
- main への自動 merge・本番 deploy（永久に人間の専権）
- 新機能の自律企画（入口はゴール承認済みの改善・修正のみ）
- 無制限の研磨（朝の確認予算が生産量の上限）
- v0 では外部 Issue triage の**実行**はスコープ外

## 2. 設計原則（8箇条）

1. **ゴール先出し**: 答え（GOALS）が承認されるまで実装しない。未承認 repo は観測のみ（fail-closed）
2. **完走原則**: 承認待ちで途中停止しない。マージ以外は走り切る。走り切れないものは理由付き HOLD（guard/予算/締切による停止は完走原則に優先する）
3. **チェリーピック前提**: 1発見 = 1 Issue = 1 bot branch。PR 作成・merge は朝の owner 操作として分離し、複数の変更を1つの branch に混ぜない
4. **precision 優先**: 迷ったら実装しない。確度の低い発見は観察台帳に留める
5. **証拠駆動**: すべての主張に実測を付ける。完了記録は handbook L1-7 様式
6. **検品2争点**: ①機能が一切削がれていないか→プラスになっているか ②最小モジュール構成に近づいたか→つけ外しが効くか・一発で理解できるか
7. **反射=機械/熟考=LLM**: 機械判定できるものに LLM を使わない
8. **コア/アダプタ分離**: コアだけで安全と最低品質が成立し、アダプタは強化にのみ使う（アダプタ欠如が安全低下にならないこと）

## 3. アーキテクチャ

### 3.1 コア部品（6つ）

| 部品 | 責務 |
|---|---|
| dispatcher | 夜間起床・適格/予算確認・repo/focus 決定・レーン起動・締切 kill・orphan worktree 回収。多重起動防止は mkdir ロック（macOS に flock(1) は無い） |
| queue 規約 | GitHub labels: `night:candidate` → `night:ready` → `night:done` / `night:hold` / `night:rejected`。**台帳が正・label は投影**（dispatcher が毎夜照合し、食い違いは台帳勝ち）。`night:rejected`→`night:ready` の遷移は actor が夜番 identity 以外の場合のみ有効 |
| findings 台帳 | 発見の永続記録と重複検出（§8）。カウンタ（retry・レーン数・Issue 数）の永続化もここ |
| night-guard | 安全強制4層（§10） |
| packet + digest | 完成パケット様式（§9）と朝ダイジェスト生成。**null digest 保証**: LLM ゼロで生成できる機械テンプレートを別プロセスで必ず走らせ、「夜番が起きなかった夜」と「0件の夜」を区別可能にする（dead-man） |
| verdict-sync | **朝の裁定の書き戻し**。PR の merge/close 状態と理由 label を照会し、台帳へ adopted/fixed/rejected(+理由) を記録。L1-7 完了記録の下書きも生成。KPI（差し戻し率・revert 率）の計測源 |

### 3.2 コア/アダプタ分離（OSS 前提）

- **core の依存**: bash/POSIX・git・gh・jq。**公開 repo を扱う場合は gitleaks も core 必須依存**（無い構成は private 専用モードに自動限定）
- **BYO 注入点（command template）**: ①実装/観測エージェント ②reviewer。reviewer 未設定の構成は trust ladder L1 が上限になり、全パケットに `unreviewed` フラグが付く
- **adapters（私たちの環境の例）**: sitter-run（stall 検知の追加層。**不在時の縮退 = dispatcher の wall-clock 締切 kill のみ**）・AMC dashboard（可視化）・council 席起動・recall（embedding dedup）
- **同梱しないもの**: PII 辞書・環境 config・GOALS/台帳の実データ
- AMC からの機能移植は行わない（台帳とダイジェストは core 自前・実行 ledger は sitter 推奨依存）

### 3.3 役割分担

| 役 | 担当 | 備考 |
|---|---|---|
| 目付の実走（sim/ブラウザ/CLI 操作・スクショ・中身観測） | codex | サンドボックス内（§10.3） |
| ペルソナ/シナリオ設計・観点選定・合議の裁定・最終検品・朝ダイジェスト肉付け | Fable（Alpha） | digest はテンプレ生成が正・Fable は肉付け（§11） |
| バックヤード技術調査の設計と深掘り | Fable（観点広め）。再現実験の実走は codex | 翔さん指定 |
| 実装 writer | codex（Sol/high 既定） | — |
| クロスレビュー | council（S/M = Kimi+GLM。guard 変更 = 5席） | OSS 利用者は BYO reviewer |
| 反射層 | 機械（gitleaks・lint・テストスイート・dedup・予算メータ） | テスト実行も§10.3の隔離下 |

- UX 発見の合議は「機械再現」を強制しない: **再現 or 複数ペルソナの独立合致**のいずれかで通過（体験系発見が precision 優先で過剰に死なないため）

## 4. 入口2レーンと観点カタログ

- **UX レーン**: 目付による擬似デモ。ペルソナ N 人（初期値: 初心者/熟練者/せっかちな人。Phase 0 で較正）で主要フローを実走し、観察と解釈を分離して記録
- **バックヤードレーン**: テスト・ログ・静的解析・再現実験による技術バグの発見
- **観点カタログ（意地悪レンズ集）**: Bug / External Issue Triage(受け口のみ) / Refactor / Feature Improvement / Security / Performance / Dependency / UI・UX・Accessibility / Demo Device・UT / Documentation Drift。網羅義務なし、focus 選定と敵対視点の語彙

## 5. ゴール先出し（GOALS）

- **初夜の成果物**（実装はしない）: ①GOALS 案（UX ゴール＋技術ゴール）②機能マップ ③可動域マップ（シミュ確認可能/実機必須の実測仕分け）
- Phase 0 では GOALS 案は**夜番 state dir に生成**し、昼に Alpha が通常レーンで `docs/NIGHTSHIFT-GOALS.md` の PR にして翔さん承認（Phase 0 の GitHub 書き込みゼロを崩さない）。Phase 1 以降も夜番は bot branch 作成までとし、PR は昼の owner 操作とする
- **GOALS のライフサイクル**: 版番号を持ち、変更は必ず PR（=人間承認）。夜番は現行版との差分だけを見る。未承認 repo は観測のみ
- リファクタのゴール定義（固定）: **機能を一切削がず、最小モジュール形式へ**（§6）

## 6. 最小モジュール検品（粒度4層）〔v0 では休眠・v0.1+ で有効化〕

v0 の運転モード（LP=研磨 L1・CatyPhone=UX 100%）ではこの機構はほぼ出番がないため、**v0 では判定ゲートとして使わない**。有効化は「理解可能性テストの採点 rubric 確定」を前提条件とする。

| 層 | 実体 | 境界ルール | 機械判定（反射層） |
|---|---|---|---|
| レポジトリ | 全機能の集合 | 製品・デプロイ単位 | — |
| 大カテゴリー | ディレクトリ/パッケージ | 1機能ドメイン・公開口1箇所・責務が README 3行で言える | 循環依存ゼロ・公開面の広さ |
| 中カテゴリー | 1ファイル | 1責務1ファイル | 行数目安（300-400・言語別）超過で「分割候補」 |
| 小カテゴリー | 関数 | 1仕事・署名だけで契約が読める | 長さ・引数数の lint |

- 分割には理由必須（再利用2箇所以上・並列作業境界・テスト独立）。**統合提案も等価に出す**
- 理解可能性テスト: fresh context のエージェントに責務・公開API・変更ポイントを説明させる（rubric 未確定のため v0 は非ゲートの参考情報）
- 論理4層→物理形の対応表を各 repo の `ARCHITECTURE.md` に固定

## 7. 一晩のフロー

```
23:30 dispatcher 起床（MBP 電源接続・スリープ抑止が運用前提）
 → 予算・適格・バックログ確認 → repo/focus 決定（承認済み repo 集合の内側で focus をローテーション）
 → 最新 main からローカル worktree 作成（公開 ref とは別の一時作業 branch）
 → 観測: 目付擬似デモ（codex）＋機械スキャン＋技術調査（Fable）  〔タイムボックス制・Phase 0 で実測して配分〕
 → findings 台帳照会（dedup・再発判定・rejected 再提案禁止）
 → 合議（再現 or 複数ペルソナ合致）→ 通過分だけ Issue 起票（Why/Done when/触るファイル予測。上限 = レーン数×2/夜）
 → 観測終了時点の残時間からレーン数を逆算 → レーン実行（L2-4 非交差チェック。対象 = 昼の WIP 宣言 ＋ 夜番自身の open PR の実績ファイル集合）:
     実装 → テスト → クロスレビュー → 修正 → 再検証
 → commit ＋ fresh `night-bot/run-*` branch 1本の create（§10.4 公開ゲート通過が前提）。PR/merge は朝の owner 操作。予測外ファイルに触れたレーンは「衝突注意」フラグ
04:30 実装締切（dispatcher が kill → HOLD 化。未完は翌夜継続 or 廃棄）
 → retro（失敗分析 → config/playbook への変更提案 PR。guard パスは §10.6 特別扱い）
 → 繰越 bot branch の再利用・自動更新は行わず、衝突または stale は HOLD 化
06:30 朝ダイジェスト確定（テンプレは必ず生成・Fable 肉付けは予算内のみ）
朝   翔さん確認（§9 予算内）→ PR 単位チェリーピック → main 適用（翔さんのみ）→ verdict-sync が裁定を台帳へ書き戻し
```

- focus 選定基準: ①直近 git 変更が多い領域 ②前回 findings が濃かった領域 ③翔さん指定（最優先）
- **深夜の人間作業との衝突**: WIP 照会は「昼/夜」でなく「現在時刻に有効な WIP 宣言の有無」で判定
- **起床失敗・蓋閉じ**: その夜は skip として null digest に記録（catch-up はしない）。代替ホスト（Mac mini 等）での dispatcher 稼働は v1 検討
- **crash 回収**: 次回起床時に orphan worktree/branch を検出し、台帳と突合して 再開（HOLD 継続）/廃棄 を判定。夜番系 worktree の合計サイズ上限あり（超過で新規レーン停止・GC 実行）

## 8. findings 台帳と重複検出

- 台帳: JSONL 1行1発見。`{id, repo, target, symptom, kind, status, issue/pr, confirm_cost(即断|1分|3分), rejection_reason, embedding_ref, date}`
- status 語彙: `open / adopted / fixed / rejected / deferred / regression`。**rejected と rejection_reason は verdict-sync（§3.1）が朝の裁定から書き戻す**
- dedup 3段: ①機械（repo+target+kind+正規化 symptom キーの完全一致。表揺れは②送り）②embedding 類似（アダプタ）③グレーのみ LLM 判定
- ルール: fixed 類似はスキップ。**目付の体験で再発した指摘は regression として再オープン**（体験は台帳 status より強い）。**rejected 類似は再提案しない**
- 台帳の保存先は夜番 state dir（単一 writer = dispatcher 経由の直列追記。レーンは提案ファイルを置き dispatcher が取り込む）

## 9. 完成パケットと朝ダイジェスト

**パケット必須項目**: 何を/なぜ/どう直したか・実行テストと結果・証拠（**UI レーン = before/after スクショ or sim 録画必須・バックヤード = テスト/ログ実測で可**）・レビュー評決（席・model・verdict。unreviewed 構成はその旨）・残リスク・確認方法と所要時間（即断/1分/3分）・Alpha 判定（merge 推奨/非推奨＋理由）・機械可読 manifest（packet.json: 触った実績ファイル一覧・フラグ）

**証拠媒体の置き場**: スクショ・動画は**夜番 state dir に保存**し、ダイジェストからローカル参照。対象 repo にも PR にも添付しない（公開共有は人間の作為のみ）

**朝ダイジェスト**:
- 1件1行「どの機能が体感でどう良くなるか」＋詳細リンク＋確認所要時間
- 上限: **≤10件/日・確認時間合計 ≤30分**（LP 等の即断級前提）。**CatyPhone は別枠 cap**（実機必須 packet は sim 録画で夜番が証拠を出し、実機は spot-check のみ。1日あたりの実機 packet 数を別途制限。初期値は Phase 2 開始時に翔さんが決める）
- マージ儀式の軽量化: 夜番 PR は squash 一発マージ前提・L1-7 記録は verdict-sync が下書き
- **バックプレッシャー**: 未確認バックログが K 件を超えたら dispatcher がレーン数を自動削減（K 初期値 = 15。Phase 0 で較正）
- 繰越 PR は夜ごと自動 rebase・N 夜（初期値 7）経過で close 提案をダイジェストに出す
- 即断化（実機を触らず判断できる形）を最優先で作る。HOLD はダイジェスト非掲載（台帳と Issue に記録・件数だけ footer に表示）
- **TEST 変更フラグ**: テストの期待値を変更する PR は明示フラグ（夜番が単独でテストを弱めた形を人間が見逃さない）
- **GUARD 変更フラグ**: §10.6 参照

## 10. night-guard v2（安全強制・4層）★fail-open 致命領域・5席レビュー反映済み

原則: **ガードは夜番エージェントの善意に依存しない**。各層が独立に「main 到達・公開漏洩・外部作用・範囲外書き込み」を遮断し、どの1層のバグも他層が受け止める。ガード自身のエラーは全て停止側（fail-closed）。「悪い形の列挙（deny-list）」は採らず、**受理する文法を小さく列挙して外は全部 deny**（alpha-loom #4 実測知見）。

### 10.1 L1: アイデンティティ層（最優先）
- 夜番は**専用 GitHub identity（night-bot broker）**で動く。GitHub App は対象 repo のみへ install し、permissions は Metadata:read + Contents:write のみ、ruleset で `night-bot/run-*` の通常 create/update だけを許可する。**merge 不可・admin 不可・workflow 書き込み不可・delete 不可**
- 対象 repo の main に **server-side branch protection**（PR 必須・force-push 禁止）。夜番のトークンでは main を動かす API 呼び出しが権限エラーになる状態を作る＝ローカル層の全バイパス（`--no-verify`・hooksPath 差し替え・`gh pr merge`・API merge・refspec `HEAD:main`）を remote で無効化する最終防壁
- オーナー個人のトークン・ssh 鍵・cloud credential は夜番レーンのプロセス環境に**注入しない**（gateway が最小環境で起動）
- 副次効果: branch publication の認証主体が GitHub App installation として監査され、夜番の作為が識別可能

### 10.2 L2: 実行ゲートウェイ層
- 夜番レーンから git/gh への唯一の経路は core 同梱の **gateway wrapper**。publish は strict request を broker へ渡し、broker が `refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8` を生成して 1 回だけ create する。列挙外は全 deny＋監査ログ
- push/PR/Issue 系は gateway 内で L4 公開ゲートを強制通過
- pre-push hook は dispatcher が `core.hooksPath` で worktree 外から注入（レーンは hooks に書けないまま・設置主体は dispatcher/インストーラ）
- gateway・guard config・budget 定義への書き込みは L3 で遮断（§10.6）

### 10.3 L3: プロセスサンドボックス層
- レーン（BYO agent・**テストスイート実行**・sim/ブラウザ実走を含む——テスト＝任意コード実行として扱う）はサンドボックス profile 下で起動:
  - FS write = 対象 worktree ＋ レーン state dir のみ
  - FS read = worktree ＋ 宣言済み依存のみ（`~/.ssh`・`~/.aws`・keychain・他 repo は read も不可）
  - network egress = 宣言済みホストのみ
- macOS 実装は sandbox-exec profile（Phase 1 で実装・実測）。実装しきれない項目は**残存リスクとして本書に明記**し、L1 の credential 非注入で被害上限を規定する
- 外部副作用を持つテスト（実 API・staging DB 書き込み等）の repo は適格条件で除外 or 隔離実行必須（§12）

**Phase 0 の残存リスク**: Phase 0 の timebox は process group を TERM/KILL
した後、`pgrep -P` で収集した子孫を再帰 sweep し、`setsid()` で group を
離れたプロセスも、離脱前後に観測できた場合は停止を試みる。停止後も
Phase 0 inspector が識別できる生存 PID は `lane_end.survivors` に記録し、
lane 失敗かつ当夜の後続 lane 停止とする。`survivors` は inspector が
識別できた集合だけであり、不在証明ではない。特に classic double fork
（`fork` → `setsid` → `fork`）で中間親が観測前に終了すると、reparent
された孫は parent/PGID model から不可視になり、配列へ記録されずに生存
し得る。これは検知と fail-closed 化であり封じ込めではない。この逃避の
防止、同一 UID で読める host secret、lane 外 filesystem へのアクセスを
含む完全な containment は Phase 1 sandbox の責務である。

### 10.4 L4: 公開ゲート層
- 対象: **GitHub へ出る全て**——push の全 commit range（中間 commit 含む）・commit message・PR/Issue の title/body/comment
- スキャナ: gitleaks（**全 push・private repo にも適用**）＋ PII 辞書スキャン（public のみ・利用者ローカル辞書）
- **辞書不在の public repo は公開系操作を全拒否**（fail-closed）。明示 config `pii_gate: acknowledge-none` を人間が書いた場合のみ gitleaks-only に縮退
- スキャナ実行不能・エラー = 公開系操作全停止
- visibility flip（private→public）の前提条件: 夜番 commit 全履歴の再スキャン PASS（適格条件に記載）

### 10.5 データ境界（v0 = 前提で縛る方式・翔さん裁定 2026-07-29）
- **v0 の第一防壁は信頼境界の前提条件**（§12 適格条件6）: 対象は「書き込み者が家族に限られる private repo」のみ。外部由来テキストの流入経路を前提から排除し、注入対策の作り込みは v0 ではしない（キリがない領域はスコープで縛る、が owner 裁定）
- 前提が変わる時——外部 Issue 受け入れ（v1）・public 化後の外部 PR/Issue——には、構造化組み立て（prompt はハーネスが構造化フィールドから組み立て、自由テキストは引用フェンスのみ）等の注入対策が**開始の前提条件**になる。v1 設計に委譲
- v0 でも維持されるもの（追加コストゼロ・事故対策として元々存在）: 騙され/暴走の別なく、被害上限は L1（鍵独占）・L4（公開ゲート）・main=人間 が規定する
- **queue の完全性**: `night:rejected`→`night:ready` は actor ≠ night-bot の場合のみ有効（注入対策ではなくループ健全性の仕組みとして維持）

### 10.6 自己不変性（self-guard immutability）
- gateway・guard config・hooks・budget 定義は夜番レーンの書き込みスコープ外（L3 強制）
- 夜番自身の repo を対象にする場合（dogfood）、guard パスに触れる PR は「**GUARD 変更**」フラグ＋通常チェリーピックと分離した明示承認を要求。retro 提案 PR も同ルール
- 書き込みスコープは2種を明確に分離: **レーン** = 対象 worktree ＋ レーン state dir ／ **dispatcher** = 夜番 state dir のみ

### 10.7 資源・締切
- カウンタ（retry ≤2/レーン・レーン数・Issue ≤ レーン数×2/夜）は**台帳に永続化**（プロセス再起動で消えない）
- 締切強制は core: dispatcher が 04:30 に SIGTERM → HOLD 化（sitter は stall 検知の追加層）
- 共有ロック（sim mutex 等）取得失敗 = そのレーン skip/HOLD（fail-closed）。stale lock の破棄は人間のみ
- worktree/branch GC: merge/close 済みは即回収・夜番系 worktree 合計サイズ上限・超過で新規レーン停止
- ロックは mkdir 方式

### 10.8 検証不能時停止
- 「green」の判定に **false-green 対策**: テスト 0 件・全 skip・スイート実行不能は green と見なさない
- レーン実行中にスイートが red 化したら当該レーンは書き込み中断・HOLD
- 検証手段が壊れている夜は書き込み系レーンを起動しない（handbook FP 原則）

## 11. 予算と締切

- **1夜の総予算**を一次制約にする: 全エンジン（Fable・codex・council・vision）を統合計上（トークン＋wall-clock）。計測はローカルログ（token-audit 資産）。**メータが壊れたら新規レーン停止**（fail-closed）
- **Fable 上限（私有運用の追加制約）**: 翌朝 07:00 時点の rolling window 残量が昼業務に足りることを目標に逆算して停止（初期目安 = 消費 80% で停止。夜が2枠にまたがる点を含め Phase 0 で実測較正）。**ダイジェスト生成分は先にリザーブ**——かつダイジェストは機械テンプレで必ず出る設計（§3.1）なので、Fable 枯渇でも朝の成果物は消えない
- **優先度オーバーライドはエージェント側に存在しない**。予算超過は無条件で HOLD。例外は「前夜までに人間が特定 Issue へ priority 指定を宣言した場合」のみ（宣言も台帳に記録）
- 時間: 23:30〜04:30 実装・06:30 ダイジェスト確定。観測フェーズはタイムボックス制で、超過したら残時間からレーン数を逆算縮小
- codex の異常長時間・stall は sitter（アダプタ）が検知。sitter 不在構成は wall-clock kill のみと明記

## 12. repo 適格条件と初期3 repo

**適格条件**（欠ける repo は観測のみ）:
1. 1コマンドで回る検証スイートが存在し green（**テスト 0 件・全 skip は不適格**）
2. main 直結デプロイでない（**bot branch create が preview deploy 等の外部作用を起こさないことを実査**。PR 作成は夜番権限外。LP は wrangler 構成が見えているため Phase 0 で deploy 経路を実査してから書き込み解禁を判断）
3. 現在時刻に有効な WIP 宣言と非衝突
4. 公開 repo は secrets ゲート整備済み＋PII 辞書 or 明示 opt-out
5. テストが外部副作用を持たない（or 隔離実行できる）
6. **信頼境界（v0 前提・翔さん裁定 2026-07-29）**: 書き込み者が家族（翔さん＋AI ファミリー）に限られる private repo であること。外部の書き込み（外部 Issue/PR・ユーザー生成コンテンツ）が流入する repo は v0 対象外——外部入力の受け入れは v1 で注入対策とセットで設計する
- **検証スイートが無い repo の bootstrap 経路**: 夜番の最初の提案を「検証スイート追加」（L1 扱い）にできる。承認・整備されるまで観測のみ

**repo 選定は人間指定制**（指定 = 承認済み repo 集合への追加。夜ごとの focus ローテーションはその集合の内側でのみ行う）。停滞 repo は「どの機能が体感でどう良くなるか」1-2行で提案 → 翔さん承認。

**初期3 repo の運転モード**:
| repo | 位置づけ | モード |
|---|---|---|
| caty-talk LP | 初陣（Phase 0-1・急ぎ） | ブラウザ目付・即断級パケット中心。deploy 経路実査が先行タスク |
| CatyPhone（wip-caty-talk） | 本命（Phase 2） | リリース前は **UX 100% モード**・focus 週次ローテーション・sim mutex 遵守・sim 録画を証拠の正とし実機は spot-check・**朝予算は別枠 cap** |
| persona-engine | v0.1（生成レーン） | 関係性×感情グラデーションの SFW テンプレート生成。様式 lint（SFW ゲート含む）＋重複チェックが機械ゲート |

## 13. trust ladder と自己進化

- ladder: **L0 観測のみ → L1 S研磨（docs/lint/dead code）→ L2 M修正（バグ・依存）→ L3 UX 変更全般**。reviewer 不在構成は L1 が上限
- 昇格 KPI: 差し戻し率・revert 率・完走率（**計測源 = verdict-sync の書き戻し**）。閾値は Phase 0-1 の実測から数値化し、以後 N 夜連続達成で昇格**提案**（人間承認）。事故（機能退行・ガード違反・ガード迂回の試行検知）で即自動降格
- retro: 毎晩の失敗を分析し config/playbook への変更を **PR として提案**。自己書き換え禁止・guard パスは §10.6 の特別承認。マージは人間

## 14. Phase 計画

| Phase | 対象 | 内容 | ゲート（開始条件） |
|---|---|---|---|
| 0 | LP | **GitHub 書き込み完全ゼロ＝credential 不在で仕組み保証**（レーンのプロセス環境に GitHub credential を注入しない。照会が必要な情報はハーネスが取得してファイルで渡す。観測・台帳・null digest・ダイジェスト。GOALS 案は state dir 生成→昼に Alpha が PR 化）・7夜 | 設計承認・レーン環境に書き込み credential が存在しないことのテスト実証・予算メータ稼働 |
| 1 | LP | L1 解禁・1-2 レーン | **enforcement build 完了**: dedicated GitHub App＋branch protection＋gateway/broker＋公開ゲート稼働、**5席の攻撃経路を test case 化したバイパス E2E が全 deny を実証** |
| 2 | CatyPhone | UX 100% モードで L2-L3・focus ローテーション | Phase 1 KPI 閾値内・CatyPhone 朝予算 cap の翔さん決定 |
| v0.1 | persona-engine | 生成レーン追加 | 様式ゲート（SFW lint）稼働 |
| v1 | — | 外部 Issue triage 実行・代替ホスト・container 隔離・repo 追加拡大 | 別途設計 |

- Phase 0 の完了条件（誤検知率・ダイジェスト品質）は**較正**であり数値ゲートではない。Phase 1 以降のゲート数値は Phase 0 実測から設定する

### 14.1 Phase 1a local enforcement（inactive）

Issue #6 の Phase 1a として、`guard/` に credential-free のローカル
enforcement package を実装した。Phase 0 dispatcher/lane からは呼ばれず、
opt-in かつ inactive であり、全 report の mode は
`LOCAL_ONLY_REMOTE_UNPROVEN`、write mode は常に false である。gateway と
broker に Git/GitHub の自由形式 write command、lane 指定 destination ref、
credential/API path は存在しない。inactive publisher に実装した
`refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8` は broker 生成のみとする。

Phase 1a は、strict grammar/preflight、固定環境での local Git object
enumeration、pinned gitleaks 8.30.1 stdin scanner、candidate-introduced
commit/tree/blob の representation gate、sandbox-exec profile の render と
ローカル bypass regression を提供する。Phase 1a の base は caller が指定
した local base reachability であり、protected-tip equality や remote
provenance の証明ではない。resident-base/outgoing の object
ID/type/size/raw SHA-256 record を local-only aggregate として残し、
candidate-introduced object だけを full representation/scanner/canary gate
へ通す。protected-tip refetch と remote equality は Phase 1b の未証明要件
である。

binary/archive/executable/document/media/opaque class は Phase 1a では deny
する。MIME allowlist も意図的に `text/plain`、`application/json`、empty
class へ限定するため、byte-valid UTF-8 の一般的な source file でも
`text/x-shellscript` や `text/x-c` 等に分類されれば deny し得る。
whole-payload の Base64、hex、percent、Base64url-shaped content と
normalization-ambiguous wrapper は fail-closed であり、無害な encoded text
や checksum-shaped content も Phase 1a では false-deny し得る。
sandbox-exec で表現・実測不能な process/Mach/sysctl/keychain/descriptor/
signal/trace cell は `UNSUPPORTED` の hard-disable residual であり、
containment 済みとは扱わない。fixed profile の実行可否は
`sandbox_runtime_capability` として独立に記録し、実行不能時は named
fixture proof もそれぞれ `UNSUPPORTED` のままにする。

この round では user、account、App installation、token、protection、ruleset
を作成・変更しておらず、real GitHub write/negative proof も試行していない。
orchestrator preflight では private GitHub Free の protection が 403 を返した
ため、Phase 1b/1c activation には protection を支える private-repository
plan/host、night-bot broker identity、GitHub App private key、potentially
mutating proof への owner 明示承認が必要である。default-branch negative
proof は直前 main tip の content-identical descendant を使い、予期せず受理
された場合は cleanup 成功ではなく incident とする。rule-suite endpoint は
Administration:read を要求するため widening は行わず、
`rule_suite_result:"UNPROVEN_NO_ADMIN_READ"` を残存リスクとして監査する。

したがって Phase 1 と Issue #6 は未完了である。owner-authorized Phase 1b
remote proof と protection readback が完了するまで close してはならない。

## 15. OSS 化ロードマップ

- repo: `shojikumaru/alpha-nightshift` を PRIVATE で新設 → 公開同等整備（LICENSE=MIT・EN README 正本＋README.ja・COC/SECURITY・gitleaks クリーン）→ 翔さん flip（handbook 実証済みコース）
- **OSS flip の技術ゲート**: core 単独で安全が成立していること——G1 相当が core 内で完結（gateway＋hooksPath 注入）・reviewer/PII 不在時の degraded モード定義済み・sandbox 要件文書化（council GLM M1/M2/M3 の解消）
- 推奨依存（public / public 予定）: fable-loop-harness・sitter
- AMC はアダプタ接続のみ（コード移植なし）

## 16. 未決事項

1. embedding dedup の実装方式（recall 局所層 vs 軽量索引）→ Phase 0 で決定
2. 目付ペルソナ既定値の妥当性 → Phase 0 実測で調整
3. CatyPhone 機能マップ初期値・朝予算 cap 値 → Phase 2 開始時（cap は翔さん専決）
4. dispatcher 常駐の具体（launchd plist・電源設定）・sandbox-exec profile の実装可能範囲 → Phase 1 実装 Issue
5. KPI 閾値・バックプレッシャー K・繰越 close N の本数値 → Phase 0-1 実測から
6. 外部 Issue triage の実行設計 → v1
7. night-bot broker identity の作成と GitHub App private key 封印 → **翔さん玉**（Phase 1 前）

## 17. 決定ログ

- 2026-07-28: 構想開始。最小部品＋既存流用・「精度は客観検証可能性で決まる」原則（翔さん×Alpha）
- 2026-07-28: ゴール先出し・リファクタゴール=機能非削減×最小モジュール・粒度4層・repo 人間指定制（翔さん）
- 2026-07-29: 役割分担（目付実走=codex/設計・裁定=Fable）・完走原則・チェリーピック方式・朝30分/≤10件・Fable 予算・レンズカタログ・embedding dedup 方針（翔さん）
- 2026-07-29: 初期3 repo（LP/CatyPhone/persona-engine）・名前=alpha-nightshift・OSS 前提コア/アダプタ分離・AMC 非依存化（翔さん）
- 2026-07-29: 設計書 v0 → council GO・persona-engine は v0.1 後発（翔さん）
- 2026-07-29: **council 5席実施**（Kimi/Opus/GLM=全体 GO-with-changes・Grok/Fable=§10 敵対 NO-GO）→ 統合裁定・v0.1 改訂: §10 を4層強制に全面改稿・verdict-sync 新設・予算/朝運用/OSS 成立性の修正。採否記録 = `reviews/2026-07-29-design-v0/DISPOSITION.md`（Alpha 裁定）
