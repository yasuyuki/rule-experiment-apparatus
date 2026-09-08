# Protocol and records

## Declaration

`apparatus/schemas/cycle.schema.json` は measurement cycle だけを許します。宣言は control と
treatment の2 arm、同じ base、workload、evaluation、subject list と、arm ごとの variant Git
tree / managed SHA-256 を持ちます。任意の非空 `note` は、何を測り直すか、なぜ cycle を立てたかを
残します。`cycle.py` は source の current bytes と宣言を照合します。

`materialize` は base も pinned commit だけを arm workspace へ取り出し、history は
持ち込みません。宣言が base の working tree から取り除いた rule bytes は pin した commit の
history に残っており、持ち込めば arm の中から `git log` 1回で対照条件そのものへ届きます。
測定は pin より後ろしか見ない（`merge-base --is-ancestor`、`rev-list <base>..HEAD`、
`log --diff-filter=A <base>..HEAD`、`ls-tree <base>`）ので、落とす祖先を読むものはありません。

任意の `materials` は、workload が base の外に読む必要のある tree を name / repository /
commit で宣言します。arm ごとではなく cycle に1度宣言するので、両 arm が同じ bytes を
見ることは構造上成立し、Invariant 1 を弱めません。`materialize` は pinned commit だけを
`<release>/materials/<name>` へ取り出し、history は持ち込みません。持ち込むと、宣言が
置き去りにした過去の rule bytes を arm の中から `git log` 1回で読めてしまい、variant bytes
だけが違うという Invariant 1 が成立しません。arm workspace の外側なので arm の diff には
入らず、workload からは `../materials/<name>` で届きます。`review` は収集前に各 material が
pinned commit のまま clean であることを再検査し、fingerprint を review record へ固定します。

この field が必要なのは、次の cycle の計画作成のように、過去の control record や apparatus
の docs を読まなければ成立しない workload があるからです。base の1 repository だけでは
その workload を宣言できません。

## Subject descriptor

`apparatus/schemas/subject.schema.json` は protocol version、adapter entrypoint / SHA-256、opaque
profile reference だけを持ちます。CLI 固有 field を core schema に追加しません。新しい CLI は
descriptor、adapter、adapter 固有 test を追加し、`cycle.py` を変更せず導入します。

Adapter は JSON を stdin で受け、JSON だけを stdout へ返します。

### `prepare`

入力は cycle / arm、workspace、config root、variant path / digest、workload path / digest、
宣言された material の name / path、opaque profile です。応答は adapter identity、subject version、config identity、配置先と配置後 digest、
launch 情報、`collect` に返す opaque token です。応答形式は
`apparatus/schemas/adapter-prepare.schema.json` が定めます。

### `collect`

入力は cycle / arm、workspace、opaque profile、`prepare` token です。応答は実行成否、rule
読み込み成否、sanitized evidence object です。応答形式は
`apparatus/schemas/adapter-collect.schema.json` が定めます。

Core は sanitized JSON の adapter 応答を単一 review record へ逐語で取り込み、取り込んだ後に一時
state を削除します。`prepare` token は record に残るため、adapter は credential path を含む key を
返してはいけません。subject version は arm 間の harness 差を
後から見つけるための記録であり、取得できたときだけ載る任意 field です。verdict と `promote`
の条件には入りません（`CONSTITUTION.md` Accepted risk）。

### Claude Code transcript observations

Claude Code adapter の `collect.evidence` は従来の field に加え、任意の観測 field
`transcriptCoverage`、`transcriptModels`、`toolOutcomes` を返します。これらは verdict、CLI
version の固定条件、または promotion の条件を変えません。

- `transcriptCoverage` は発見した JSONL file 数、読んだ行数、JSON parse 失敗数、object record 数、
  非 object JSON 数を記録します。object record ごとに非空文字列 timestamp の有無を数え、assistant
  message ごとに `message.usage` が object だったかを数えます。usage object が存在して数値の合計が
  zero の場合は `usageAvailable` に入り、usage が無い・object でない場合は `usageMissing` に入ります。
  session の first/last timestamp は従来どおり取得できた timestamp のみであり、活動期間や実行時間を
  表すものではありません。
- `transcriptModels.counts` は assistant message の `message.model` に逐語で明示された identifier
  （英数字で始まり、英数字、`.`, `_`, `:`, `-` だけから成る文字列）だけを identifier ごとに数えます。
  設定値や CLI version から補完しません。非文字列・空・path や空白を含む値・message 欠落は
  `transcriptModels.missing` に入ります。
- `toolOutcomes` は assistant content の `tool_use` と、他の record の content にある `tool_result` を
  ID だけで対応付けます。`tool_use_id` が非空文字列でない場合は `toolUseId` を試します。引数、result
  本文、credential は保存しません。ID の無い call/result、未知の result ID、同じ call ID の2個目以降を
  別々に数えます。`duplicateCallIds` は同じ ID の2個目以降の call ごとの数です。outcome は transcript 全体で
  1回だけ現れた call ID だけを分母にし、対応する result が
  無ければ `resultUnobserved`、一つでも `is_error: true` なら `explicitErrors`、それ以外の観測済み result
  なら `successful` です。duplicate call ID は全出現を outcome から除外し、その ID の result は
  `ambiguousResults` に数えます。unknown ID の result は `unmatchedResults` です。同じ一意 call ID の複数
  result はすべて対応済みとして扱い、1件でも明示的 error があれば error です。
  explicit error は transcript に残るその結果だけを示し、再試行や手戻りを意味しません。

## Evaluation and review

固定 evaluation program は `evaluate` 引数と JSON stdin を受け、arm ごとの同一 criteria を
返します。各 criterion は number、逐語 text、`met` / `not-met` / `unknown`、sanitized evidence
reference と、任意の numeric `value` を持ちます。`value` の boolean は numeric value ではありません。
Treatment の改善が1件以上あり、regression と unknown が無い場合だけ
review verdict は `promote` です。

`apparatus/schemas/review.schema.json` は declaration digest、base commit、workload / evaluation
digest、experiment と任意 note、両 arm の variant identity / managed bytes 合計、adapter identity /
逐語 `prepare` / `collect` / subject version、criteria、verdict、採用対象 treatment digest を1件に
固定します。

## Termination

`terminate --cycle <id> --status abandoned|failed --reason <text>` は未 review cycle に
`terminations/<id>.json` を1度だけ書きます。record は schema version、cycle、recordedAt、status、
reason、declaration SHA-256 を固定し、同じ payload の再実行は成功しても record を変更しません。
異なる payload と reviewed cycle は拒否されます。termination record がある cycle は materialize、
review、promote を実行できません。terminate は arm、release、runtime `.adapter-state` を削除しません。
同じ cycle の materialize、review、terminate は OS lock で排他され、競合した呼び出しは待機せず拒否されます。

## Baseline transition

`promote` は review digest、declaration digest、variant Git tree、現在の treatment managed digest、
stable branch / clean state を mutation 前に照合します。成功時は detached worktree で renderer と
stable test を通し、fast-forward します。`rollback` は最新 promotion commit が stable HEAD の
場合だけその commit を revert し、直前の managed digest を照合します。
