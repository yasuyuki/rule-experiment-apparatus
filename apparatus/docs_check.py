#!/usr/bin/env python3
"""版管理下の文書構造を照合する。違反があれば列挙して非ゼロ終了する。

索引は人が README.md に書く。この検査が見るのは網羅性と整合性だけである。

1. 憲章文書の実在 — CONSTITUTION.md と docs/IMPROVEMENT-POLICY.md が版管理下にある。
   両者は同じ位置づけであり、削減の一手として消してよい文書ではない。実際に片方が
   削減の commit に巻き込まれて消えた。
2. 到達可能性 — README.md から Markdown リンクを推移的に辿り、版管理下の md 全件へ
   到達する。到達しない文書は「存在するが入口から辿れない」状態であり、実際に
   見落とされた（アームの可視範囲が正本に無いまま候補が立った）。
3. リンク切れ — 版管理下 md の相対リンク先が実在する。
4. 索引の包含 — CONSTITUTION.md の関連文書図に現れる md が README の索引にもある。
   索引が2つに分かれて食い違うのを防ぐ。
5. 履歴の表明 — README の履歴表に載る文書が、先頭 15 行以内で自分を履歴と宣言する。
6. 未追跡の文書 — docs/ と apparatus/ に置かれた md が版管理下にある。書いたが git add
   していない、または .gitignore の allowlist から外れた文書は、検査 1〜4 の対象に
   ならないまま消える。
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = "README.md"
# 同位の憲章文書。一方が消えると、削除の可否を判断する根拠自体が失われる。
CONSTITUTIONAL = ("CONSTITUTION.md", "docs/IMPROVEMENT-POLICY.md")
HISTORICAL_HEADING = "### Historical"
HISTORICAL_MARK = "現行の作業指示に使わない"
HISTORICAL_MARK_LINES = 15
REQUIRED_RECORDING_STATEMENTS = {
    "CONSTITUTION.md": (
        "adapter の応答は sanitized JSON として単一 review record へ逐語で取り込み、一時 state はその後削除する。",
    ),
    "docs/RULE-EXPERIMENT.md": (
        "Core は sanitized JSON の adapter 応答を単一 review record へ逐語で取り込み、取り込んだ後に一時",
    ),
}

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
FENCE = re.compile(r"^```", re.MULTILINE)


def read(relative):
    with open(os.path.join(ROOT, relative), encoding="utf-8") as handle:
        return handle.read()


def tracked_markdown():
    out = subprocess.check_output(
        ["git", "ls-files", "-z", "*.md"], cwd=ROOT
    ).decode("utf-8")
    # Phase files are scratch/provenance, not product documentation. They are
    # deliberately absent from the README index and from a public apparatus.
    return sorted(p for p in out.split("\0") if p and not p.startswith(".claude/plan-phases/"))


def untracked_markdown():
    """docs/ と apparatus/ にある未追跡の md。ignore されているものも含める。"""
    found = []
    for extra in (["--others", "--exclude-standard"],
                  ["--others", "--ignored", "--exclude-standard"]):
        # pathspec を docs/ と apparatus/ に限る。リポジトリ全体を走査すると
        # ignore 済みの Cursor プロファイルまで開きに行き、警告と待ち時間が出る。
        out = subprocess.check_output(
            ["git", "ls-files", "-z"] + extra + ["--", "docs/", "apparatus/"],
            cwd=ROOT,
        ).decode("utf-8")
        found.extend(p for p in out.split(chr(0)) if p.endswith(".md"))
    return sorted(set(found))


def strip_fences(text):
    """コードブロック内の擬似リンクを拾わないよう、フェンス内を落とす。"""
    parts = FENCE.split(text)
    return "\n".join(parts[::2])


def links_in(relative, text):
    """relative の本文から、リポジトリ相対に正規化した内部リンク先を返す。"""
    base = os.path.dirname(relative)
    found = []
    for target in LINK.findall(strip_fences(text)):
        if "://" in target or target.startswith("#") or target.startswith("mailto:"):
            continue
        target = target.split("#", 1)[0]
        if not target:
            continue
        found.append(os.path.normpath(os.path.join(base, target)).replace(os.sep, "/"))
    return found


def historical_entries(index_text):
    """README の履歴表に載る文書のパス。"""
    if HISTORICAL_HEADING not in index_text:
        return None
    tail = index_text.split(HISTORICAL_HEADING, 1)[1]
    return links_in(INDEX, tail)


def main():
    problems = []
    tracked = tracked_markdown()
    tracked_set = set(tracked)

    # 1. 憲章文書の実在。以降の検査はこれらを読むので、欠けていれば先に打ち切る。
    missing = [path for path in CONSTITUTIONAL if path not in tracked_set]
    if missing:
        for path in missing:
            print("憲章文書の欠落: %s が版管理下に無い" % path)
        print("FAIL: %d tracked markdown, %d problem(s)"
              % (len(tracked), len(missing)))
        return 1

    index_text = read(INDEX)

    # Invariant 5 and the protocol must agree about retaining the sanitized,
    # verbatim adapter responses before state deletion. Keep this narrow so the
    # document checker remains a structure checker rather than a prose linter.
    for path, statements in REQUIRED_RECORDING_STATEMENTS.items():
        for statement in statements:
            if statement not in read(path):
                problems.append("記録 protocol の表明が無い: %s に %r が無い" % (path, statement))

    # 2. 到達可能性（推移的）
    seen, queue = {INDEX}, [INDEX]
    while queue:
        current = queue.pop()
        for target in links_in(current, read(current)):
            if target in tracked_set and target not in seen:
                seen.add(target)
                queue.append(target)
    for path in tracked:
        if path not in seen:
            problems.append("到達不能: %s は %s から辿れない" % (path, INDEX))

    # 3. リンク切れ
    for path in tracked:
        for target in links_in(path, read(path)):
            if not os.path.exists(os.path.join(ROOT, target)):
                problems.append("リンク切れ: %s -> %s" % (path, target))

    # 4. 索引の包含（関連文書図 ⊆ README の索引）
    index_links = set(links_in(INDEX, index_text))
    diagram = re.findall(r"^```text\n(.*?)^```", read("CONSTITUTION.md"),
                         re.MULTILINE | re.DOTALL)
    for block in diagram:
        for token in re.findall(r"[\w./-]+\.md", block):
            token = token.replace("\\", "/")
            if token in tracked_set and token not in index_links:
                problems.append(
                    "索引漏れ: CONSTITUTION.md の関連文書図にある %s が %s の索引に無い"
                    % (token, INDEX))

    # 5. 履歴の表明
    entries = historical_entries(index_text)
    if entries is None:
        problems.append("%s に %s 見出しが無い" % (INDEX, HISTORICAL_HEADING))
    else:
        for path in entries:
            if path not in tracked_set:
                continue
            head = read(path).split("\n")[:HISTORICAL_MARK_LINES]
            if not any(HISTORICAL_MARK in line for line in head):
                problems.append(
                    "履歴の表明が無い: %s の先頭 %d 行に %r が無い"
                    % (path, HISTORICAL_MARK_LINES, HISTORICAL_MARK))

    # 6. 未追跡の文書
    for path in untracked_markdown():
        problems.append("未追跡: %s は版管理下に無く、索引の照合対象にならない" % path)

    for problem in problems:
        print(problem)
    print("%s: %d tracked markdown, %d problem(s)"
          % ("FAIL" if problems else "OK", len(tracked), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
