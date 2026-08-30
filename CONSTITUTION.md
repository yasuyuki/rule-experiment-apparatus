# Constitution

## Purpose

唯一の基本目的は、agent rule の行動差を信頼できる control / treatment 比較で計測し、
実際に評価した rule bytes と同一の bytes を baseline へ採用できるようにすることです。

## Boundary

```text
CONSTITUTION.md + docs/IMPROVEMENT-POLICY.md
├── TERMS.md
├── docs/RULE-EXPERIMENT.md
├── docs/SETUP-GUIDE.md
└── docs/USER-GUIDE.md
```

`CONSTITUTION.md` と `docs/IMPROVEMENT-POLICY.md` を憲章文書と呼び、同じ位置づけで扱います。
前者は装置が何であるかを、後者は purpose を失わずにどう削減し改善するかを定めます。他の文書が
憲章文書と食い違うときは憲章文書を正とします。

Controller は宣言、repository の複製、digest 照合、評価、review、baseline の状態遷移を
扱います。Subject は注入済み variant の下で逐語の workload だけを実行します。
Subject adapter は CLI 固有の executable、config、credential、session、rule placement と
sanitized evidence reference を所有します。

## Invariants

1. control / treatment で base commit、workload bytes、evaluation bytes、subject adapter identity
   を一致させ、variant bytes だけを変える。
2. variant source は arm 外の version control 下に置き、Git tree と managed bytes の SHA-256
   を宣言と照合する。
3. adapter は versioned entrypoint であり、descriptor の SHA-256 と実ファイルを一致させる。
4. adapter の `prepare` / `collect` 応答を schema 検証し、同じ adapter identity を返させる。
5. adapter の一時応答は単一 review record へ digest として取り込み、その後削除する。
6. review は declaration、base、workload、evaluation、adapter 応答、各 arm の criteria、verdict、
   treatment digest を1件にまとめる。
7. `promote` は review の treatment digest と現在の source bytes が一致するときだけ実行する。
8. baseline を直接変更せず、状態遷移を `promote` と最新 promotion の `rollback` に限る。
9. 失敗した cycle は後編集せず、修正した declaration で新しい cycle を作る。

## Accepted risk

subject を実行する harness、すなわち agent CLI の version は Invariant 1 の一致対象に
含めません。harness version の固定は運用上現実的でないため、control / treatment arm 間の
version 差、および cycle 実行中の version drift を、比較の妥当性に対する残存リスクとして
受容します。version を取得できたときは review record に記録するにとどめ、検出の成否を
cycle の verdict や `promote` の条件にはしません。version を取得・比較できないことは
欠陥ではありません。

## Necessity gate

機能、schema、文書、test は、それを削除すると purpose が未達または未証明になる場合だけ
維持します。製品開発、汎用 release 配布、CLI lifecycle はこの装置の責務ではありません。

この gate をどの順序で適用するかは `docs/IMPROVEMENT-POLICY.md` が定めます。憲章文書自身は
gate の対象ではありません。憲章文書の変更は、削減の一手ではなく、purpose または改善順序を
変える意図的な決定として行います。
