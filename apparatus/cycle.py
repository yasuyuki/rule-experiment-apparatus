#!/usr/bin/env python3
"""比較キーだけを持つサイクル宣言から、candidate 上に同一 base の2アームを
実体化し、subject 用の config root を構成する。サブコマンドは `materialize` と
`handoff`、判定器を両アームへ同一に適用して記録する `judge`、transcript の
読み取り専用照合 `transcripts`。`freeze` は推定器が読んでよい凍結入力の束を作り
hash で識別する。`estimate` は較正済みの推定器の出力を triage 専用の推定記録
として残す。`calibrate` は計測済みサイクルの片アームから較正記録を作る
（`--prepare` は凍結と正解データ導出可否だけを確認し、計測結果は出力しない）。
`--selfcheck` は実資産に触れずに照合関数を検査する。

    python cycle.py materialize --cycle <name>
    python cycle.py handoff --cycle <name>
    python cycle.py judge --cycle <name> [--replace]
    python cycle.py transcripts --cycle <name>
    python cycle.py freeze --cycle <name> --arm <arm-id>
    python cycle.py estimate --frozen <hash> --estimator <id> --input <path> [--replace] [--allow-measured]
    python cycle.py calibrate --cycle <name> --arm <arm-id> --estimator <id> (--prepare | --input <path>) [--replace]
    python cycle.py --selfcheck

環境 primitive は exec_() ひとつだけ。アームのファイル操作（コピー・sha256・
git）はすべて distro 内から行う。Windows 側で読むのは manifest.json と
宣言 JSON、正本照合用の git コマンド、および比較キー用ファイルの sha256 だけで、
UNC 経由（\\wsl$ 配下）へは書き込まない。`freeze` は凍結入力の束（transcript を
含む）を作るため例外的に exec_() 経由でアーム内ファイルの内容（base64）を読む。
"""

import argparse
import base64
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time

APPARATUS_DIR = os.path.dirname(os.path.abspath(__file__))
CYCLES_DIR = os.path.join(APPARATUS_DIR, "cycles")
SUBJECTS_DIR = os.path.join(APPARATUS_DIR, "subjects")
SCHEMAS_DIR = os.path.join(APPARATUS_DIR, "schemas")


def to_mnt(win_path):
    """Windows パスを distro 内から見える /mnt/<drive>/... へ直す。"""
    drive, rest = os.path.splitdrive(win_path)
    if not drive:
        return win_path
    return "/mnt/%s%s" % (drive[0].lower(), rest.replace("\\", "/"))


def parse_timestamp(value):
    """Python 3.10 でも RFC 3339 の UTC 接尾辞を読めるようにする。"""
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


# 既存の sibling 構成は移行中の既定値としてだけ残す。処理本体は環境記述子の
# `agentRulesRoot` を読むため、公開 apparatus は sibling 名に依存しない。
WORK_WIN = os.path.dirname(os.path.dirname(APPARATUS_DIR))
DEFAULT_ENVIRONMENT_PATH = os.path.join(
    WORK_WIN, "private-control", "apparatus-environment.json"
)
ENVIRONMENT_PATH = DEFAULT_ENVIRONMENT_PATH

# manifest の無い変種は正本のうち subject が使うものだけをアームへ運ぶ。
# README.md は構造と使い方だけを書き、測定に言及しない。
# reconciliation.md と controller.md は比較や測定に言及するので除外する（憲法 不変条件 3）。
VARIANT_COPY_ITEMS = ("bin", "rules", "placement.json", "README.md")

# 不変条件 8(3) と docs/EXECUTION-UNIT.md の閉じた可読性候補。
META_READABILITY_FIXED = (
    "CONSTITUTION.md",
    "TERMS.md",
    "docs/RULE-EXPERIMENT.md",
    "docs/CYCLE-RECORD-CRITERIA.md",
    "docs/EXECUTION-UNIT.md",
)
META_READABILITY_GLOBS = (
    "apparatus/cycles/*.json",
    "apparatus/schemas/*",
)

# 推定機構（docs/RULE-EXPERIMENT.md §7）の置き場。環境記述子の
# 親を private control root とし、実データ・実推定器資産はここへは版管理しない。
CONTROL_DIR = os.path.dirname(ENVIRONMENT_PATH)
FROZEN_DIR = os.path.join(CONTROL_DIR, "frozen")
ESTIMATIONS_DIR = os.path.join(CONTROL_DIR, "estimations")
CALIBRATIONS_DIR = os.path.join(CONTROL_DIR, "calibrations")
ESTIMATORS_DIR = os.path.join(CONTROL_DIR, "estimators")

# 凍結入力の member.source にこれらの部分文字列が含まれていたら拒否する。
# 計測記録・判定器・baseline manifest を凍結入力へ混ぜない（不変条件10と同型の
# 「推定を計測に混ぜない」を束ねる段階でも守る）。
FROZEN_FORBIDDEN_SOURCE_SUBSTRINGS = ("/reviews/", "/judge/", "baseline-")

# 推定記録・較正記録に書いてはならないキー（docs/CYCLE-RECORD-CRITERIA.md §9、
# 憲法 不変条件10。「用途は triage に限る」を構造で守る）。
FORBIDDEN_RECORD_KEYS = {"verdict", "promote", "promotable", "approved", "proven", "recommendation"}

# git の空 tree object。root commit の親として使う（variant-injection の diff）。
EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

_environment_cache = None
_subject_cache = {}


def configure_environment(path=None):
    """Select an environment descriptor and derive its private control root.

    With no option, retain the legacy sibling layout for migration.  A supplied
    descriptor may live anywhere; its parent is the control root for all
    runtime records produced by this process.
    """
    global ENVIRONMENT_PATH, CONTROL_DIR
    global FROZEN_DIR, ESTIMATIONS_DIR, CALIBRATIONS_DIR, ESTIMATORS_DIR
    global _environment_cache

    ENVIRONMENT_PATH = os.path.abspath(path or DEFAULT_ENVIRONMENT_PATH)
    CONTROL_DIR = os.path.dirname(ENVIRONMENT_PATH)
    FROZEN_DIR = os.path.join(CONTROL_DIR, "frozen")
    ESTIMATIONS_DIR = os.path.join(CONTROL_DIR, "estimations")
    CALIBRATIONS_DIR = os.path.join(CONTROL_DIR, "calibrations")
    ESTIMATORS_DIR = os.path.join(CONTROL_DIR, "estimators")
    _environment_cache = None


def agent_rules_root():
    """Return the agent-rules root named by the active environment descriptor."""
    value = load_environment().get("agentRulesRoot")
    if value is None:
        # Compatibility for pre-cutover descriptors.  New descriptors should
        # always set agentRulesRoot, so public layouts do not require siblings.
        return os.path.join(os.path.dirname(CONTROL_DIR), "agent-rules")
    if os.path.isabs(value):
        return os.path.normpath(value)
    return os.path.normpath(os.path.join(CONTROL_DIR, value))


def _jsonschema_mod():
    try:
        import jsonschema
    except ImportError:
        raise SystemExit(
            "jsonschema is required; install with: pip install -r %s"
            % os.path.join(APPARATUS_DIR, "requirements.txt")
        )
    return jsonschema


def validate_against_schema(instance, schema_filename, label):
    """schema_filename は schemas/ 配下。失敗は SystemExit。"""
    jsonschema = _jsonschema_mod()
    schema_path = os.path.join(SCHEMAS_DIR, schema_filename)
    with open(schema_path, encoding="utf-8") as handle:
        schema = json.load(handle)
    validator_cls = jsonschema.validators.validator_for(schema)
    validator = validator_cls(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
    if errors:
        raise SystemExit("\n".join(
            "%s schema: %s: %s"
            % (label, "/".join(str(p) for p in err.absolute_path) or "(root)", err.message)
            for err in errors
        ))


def load_environment():
    """private-control 配下の環境記述子。プロセス内キャッシュ。"""
    global _environment_cache
    if _environment_cache is not None:
        return _environment_cache
    if not os.path.isfile(ENVIRONMENT_PATH):
        raise SystemExit("environment descriptor not found: %s" % ENVIRONMENT_PATH)
    with open(ENVIRONMENT_PATH, encoding="utf-8") as handle:
        env = json.load(handle)
    validate_against_schema(env, "environment.schema.json", "environment")
    _environment_cache = env
    return env


def load_subject(subject_id):
    """subjects/<id>.json を schema 検証して返す。id とファイル名 stem は一致必須。"""
    if subject_id in _subject_cache:
        return _subject_cache[subject_id]
    validate_identifier("subject id", subject_id)
    path = os.path.join(SUBJECTS_DIR, "%s.json" % subject_id)
    if not os.path.isfile(path):
        raise SystemExit("subject descriptor not found: %s" % path)
    with open(path, encoding="utf-8") as handle:
        subject = json.load(handle)
    validate_against_schema(subject, "subject.schema.json", "subject %s" % subject_id)
    if subject.get("id") != subject_id:
        raise SystemExit(
            "subject id %r does not match filename stem %r: %s"
            % (subject.get("id"), subject_id, path)
        )
    _subject_cache[subject_id] = subject
    return subject


def subject_ids(decl):
    """宣言の subject を id リストへ正規化する。文字列または非空の文字列リスト。"""
    value = decl.get("subject")
    if isinstance(value, str):
        return [value]
    if (
        isinstance(value, list)
        and value
        and all(isinstance(item, str) and item for item in value)
    ):
        return value
    raise SystemExit(
        "declaration subject must be a non-empty string or a non-empty list of strings: %r"
        % (value,)
    )


def iter_transcript_subjects():
    """apparatus/subjects/ のうち transcripts が非 null の記述子を id 順で返す。"""
    for name in sorted(os.listdir(SUBJECTS_DIR)):
        if not name.endswith(".json"):
            continue
        subject = load_subject(name[:-5])
        if subject.get("transcripts") is None:
            continue
        yield subject


def execution_unit_path():
    return os.path.join(os.path.dirname(APPARATUS_DIR), "docs", "EXECUTION-UNIT.md")


def exec_(cmd, check=True):
    """環境記述子の host に応じてコマンドを実行する。

    host=unix: wsl.exe -d <distro> -u <user> -e bash -lc '<cmd>'
    host=windows: powershell.exe -NoProfile -NonInteractive -Command '<cmd>'

    check=True（既定）なら非0終了時に stderr を添えて例外を送出し、stdout を
    返す。既存の呼び出し（materialize / handoff）はこの既定のままで挙動は
    変わらない。check=False なら例外を送出せず (stdout, stderr, returncode)
    を返す。呼び出し元が判定結果（例: judge.py の exit 1 は判定未達であって
    infra 失敗ではない）と infra 失敗を自分で区別できるようにするため。

    unix 側は `--` ではなく `-e` を使う: この環境の wsl.exe は `--` 区切りだと
    既定シェル経由の余分な中継が入り、渡した文字列内の `$var` /
    `$(...)` が本来の bash -lc に届く前に空へ潰れる（cd や変数に依存する
    スクリプトが無言で壊れる）。`-e` はその中継を経ずに argv を直接
    execve するため、実測でこの問題が再現しない。"""
    env = load_environment()
    host = env["host"]
    if host == "unix":
        argv = [
            "wsl.exe", "-d", env["distro"], "-u", env["user"],
            "-e", "bash", "-lc", cmd,
        ]
    elif host == "windows":
        argv = [
            "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd,
        ]
    else:
        raise SystemExit("unsupported environment host: %r" % host)
    result = subprocess.run(
        argv,
        capture_output=True, text=True, encoding="utf-8",
    )
    if check:
        if result.returncode != 0:
            # 理由を先に出す。スクリプト本文で埋めない（§1-7 の是正）。
            raise SystemExit(
                "%s\nexec failed (%d) in: %s"
                % (result.stderr.strip(), result.returncode, cmd.splitlines()[1 if cmd.startswith("set -e") else 0])
            )
        return result.stdout
    return result.stdout, result.stderr, result.returncode


def git_win(*args):
    """agent-rules を Windows 側の git で読む（正本照合専用）。"""
    result = subprocess.run(
        ["git", "-C", agent_rules_root(), *args],
        capture_output=True, text=True, encoding="utf-8",
    )
    if result.returncode != 0:
        raise SystemExit("git %s failed: %s" % (" ".join(args), result.stderr))
    return result.stdout


IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def validate_identifier(kind, value):
    """シェルコマンドとパスへ入る識別子（cycle 名・arm id）の形式検証。
    `.` / `..` は形式を満たしてもパストラバーサルになるので明示的に拒否する。"""
    if not isinstance(value, str) or not IDENTIFIER_RE.match(value) or value in (".", ".."):
        raise SystemExit(
            "invalid %s: %r (must match ^[A-Za-z0-9._-]+$ and must not be '.' or '..')"
            % (kind, value)
        )


def cycle_path(name):
    return os.path.join(CYCLES_DIR, "%s.json" % name)


def load_cycle(name):
    with open(cycle_path(name), encoding="utf-8") as handle:
        decl = json.load(handle)
    validate_against_schema(decl, "cycle.schema.json", "cycle %s" % name)
    return decl


def cycle_kind(decl):
    """宣言の kind。欠落は measurement。"""
    return decl.get("kind", "measurement")


def validate_arms(cycle_name, decl):
    """宣言の arms を使う前に検証する。空・必須キー欠落・id の形式不正・
    id 重複は SystemExit。重複を許すと judge の reports 集計が id で潰れ、
    「全アームの report が揃った」ガードが黙って照合をスキップする。
    estimation は arms ちょうど1件、それ以外は2件以上かつ control が1件以上。"""
    path = cycle_path(cycle_name)
    arms = decl.get("arms")
    if not arms:
        raise SystemExit("declaration has no arms: %s" % path)
    for index, arm in enumerate(arms):
        for key in ("id", "role", "variant", "variantTree"):
            if key not in arm:
                raise SystemExit(
                    "arms[%d] is missing key %r in declaration: %s" % (index, key, path)
                )
        validate_identifier("arm id", arm["id"])
    ids = [arm["id"] for arm in arms]
    duplicates = sorted({arm_id for arm_id in ids if ids.count(arm_id) > 1})
    if duplicates:
        raise SystemExit(
            "duplicate arm id(s) in declaration: %s: %s" % (", ".join(duplicates), path)
        )
    if cycle_kind(decl) == "estimation":
        if len(arms) != 1:
            raise SystemExit(
                "estimation cycle requires exactly 1 arm, got %d: %s" % (len(arms), path)
            )
    else:
        if len(arms) < 2:
            raise SystemExit(
                "measurement cycle requires at least 2 arms, got %d: %s"
                % (len(arms), path)
            )
        if not any(arm.get("role") == "control" for arm in arms):
            raise SystemExit(
                "measurement cycle requires at least one arm with role 'control': %s"
                % path
            )


def require_subject(cycle_name, decl, require_version):
    """`subject`（judge では `subjectVersion` も）の必須化。欠落を KeyError の
    traceback や `null` 入りの記録にしない（憲法 不変条件 (9) は版の記録を
    要求している）。列挙した id の記述子が読めることもここで担保する。"""
    path = cycle_path(cycle_name)
    if "subject" not in decl:
        raise SystemExit("declaration is missing key 'subject': %s" % path)
    for sid in subject_ids(decl):
        load_subject(sid)
    if require_version and not decl.get("subjectVersion"):
        raise SystemExit(
            "declaration is missing key 'subjectVersion' (or it is null/empty): %s" % path
        )


def release_path(cycle_name):
    """distro 内の release パス。`~` のシェル展開に頼らず $HOME を使う。
    識別子は検証済みだが、可変部の引用も併せて掛ける。"""
    return '"$HOME"/releases/%s' % shlex.quote(cycle_name)


def verify_canonical(experiment, arm):
    """正本の照合。宣言の variantTree と実体の食い違い、作業ツリーの汚れを
    リストで返す（無ければ空リスト）。呼び出し元が exit するかどうかを決める。"""
    mismatches = []
    rel = "experiments/%s/variants/%s" % (experiment, arm["variant"])
    actual = git_win("rev-parse", "HEAD:%s" % rel).strip()
    if actual != arm["variantTree"]:
        mismatches.append(
            "mismatch: variantTree for %s: declared %s, actual %s"
            % (arm["id"], arm["variantTree"], actual)
        )
    dirty = git_win("status", "--porcelain", "--", rel)
    if dirty.strip():
        mismatches.append("mismatch: canonical is dirty for %s:\n%s" % (arm["id"], dirty))
    return mismatches


def variant_canonical_dir(experiment, variant):
    return os.path.join(agent_rules_root(), "experiments", experiment, "variants", variant)


def copy_plan_from_manifest(experiment, variant):
    """manifest.json から `<arm>/` 宛てファイルの (src, dest_rel, sha256) を作る。"""
    manifest_path = os.path.join(variant_canonical_dir(experiment, variant), "manifest.json")
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    root = "%s/experiments/%s/variants/%s" % (to_mnt(agent_rules_root()), experiment, variant)
    plan = []
    for entry in manifest["files"]:
        if not entry["source"].startswith("<arm>/"):
            continue
        dest_rel = entry["source"][len("<arm>/"):]
        plan.append(("%s/%s" % (root, entry["recorded"]), dest_rel, entry["sha256"]))
    return plan


def _bash_copy_file_with_conflict(src_expr, dest_expr):
    """src_expr / dest_expr は既に shell 向けに引用済み、または "$var" 形式。"""
    return (
        "if [ -e %(dest)s ]; then "
        "got=$(sha256sum %(dest)s | cut -d' ' -f1); "
        "want=$(sha256sum %(src)s | cut -d' ' -f1); "
        "if [ \"$got\" != \"$want\" ]; then "
        "echo \"mismatch: %(dest)s exists with different sha256\" >&2; exit 1; "
        "fi; "
        "else "
        "mkdir -p \"$(dirname %(dest)s)\"; "
        "cp %(src)s %(dest)s; "
        "fi"
    ) % {"src": src_expr, "dest": dest_expr}


def _bash_copy_tree_with_conflict(src_root, dest_root):
    """ディレクトリまたは単一ファイルを衝突検査付きでコピーする。"""
    src_q = shlex.quote(src_root)
    dest_q = shlex.quote(dest_root)
    return "\n".join([
        "if [ -d %s ]; then" % src_q,
        "  while IFS= read -r -d '' f; do",
        "    rel=${f#%s/}" % src_root,
        "    dest=%s/$rel" % dest_q,
        "    " + _bash_copy_file_with_conflict("\"$f\"", "\"$dest\""),
        "  done < <(find %s -type f -print0)" % src_q,
        "elif [ -e %s ]; then" % src_q,
        "  " + _bash_copy_file_with_conflict(src_q, dest_q),
        "else",
        "  echo \"missing variant item: %s\" >&2; exit 1" % src_root,
        "fi",
    ])


def build_arm_inject_lines(arm, experiment):
    """1アーム分の注入コマンド行。manifest 有無で方式を選ぶ。"""
    variant = arm["variant"]
    arm_id = arm["id"]
    vdir_win = variant_canonical_dir(experiment, variant)
    root_mnt = "%s/experiments/%s/variants/%s" % (to_mnt(agent_rules_root()), experiment, variant)
    lines = []
    if os.path.isfile(os.path.join(vdir_win, "manifest.json")):
        plan = copy_plan_from_manifest(experiment, variant)
        for src, dest_rel, _sha in plan:
            dest = "%s/%s" % (arm_id, dest_rel)
            lines.append(
                _bash_copy_file_with_conflict(shlex.quote(src), shlex.quote(dest))
            )
        if plan:
            quoted = " ".join(shlex.quote(dest) for _, dest, _ in plan)
            lines.append("cd %s" % shlex.quote(arm_id))
            lines.append(
                "sha256sum %s | while read hash path; do "
                "echo PLANSHA256 %s $path $hash; done"
                % (quoted, shlex.quote(arm_id))
            )
            lines.append("cd ..")
        return lines, plan
    for item in VARIANT_COPY_ITEMS:
        src = "%s/%s" % (root_mnt, item)
        dest = "%s/%s" % (arm_id, item)
        lines.extend(_bash_copy_tree_with_conflict(src, dest).splitlines())
    if os.path.isfile(os.path.join(vdir_win, "bin", "rules.py")):
        lines.append("cd %s" % shlex.quote(arm_id))
        # render は新規ファイルを書いてよい。既存ファイルの内容変更は衝突。
        lines.append(
            "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\n"
            "import hashlib, os, subprocess, sys\n"
            "def digest(path):\n"
            "    hasher = hashlib.sha256()\n"
            "    with open(path, 'rb') as handle:\n"
            "        for chunk in iter(lambda: handle.read(65536), b''):\n"
            "            hasher.update(chunk)\n"
            "    return hasher.hexdigest()\n"
            "before = {}\n"
            "for root, _dirs, files in os.walk('.'):\n"
            "    for name in files:\n"
            "        rel = os.path.join(root, name)\n"
            "        before[rel] = digest(rel)\n"
            "result = subprocess.run([sys.executable, 'bin/rules.py', 'render', '.'])\n"
            "if result.returncode != 0:\n"
            "    raise SystemExit(result.returncode)\n"
            "for rel, old in before.items():\n"
            "    if digest(rel) != old:\n"
            "        sys.stderr.write('mismatch: render overwrote existing %s\\n' % rel)\n"
            "        raise SystemExit(1)\n"
            "PY"
        )
        lines.append("cd ..")
    return lines, []


def resolve_materialize_base(decl):
    """宣言の base を解決する。無ければ拒否。repo は装置親 basename と一致必須。"""
    base = decl.get("base")
    if not isinstance(base, dict) or "repo" not in base or "commit" not in base:
        raise SystemExit("materialize requires base: {repo, commit}")
    repo_id = base["repo"]
    parent = os.path.dirname(APPARATUS_DIR)
    expected = os.path.basename(parent)
    if repo_id != expected:
        raise SystemExit(
            "base.repo %r does not match apparatus parent basename %r"
            % (repo_id, expected)
        )
    commit = base["commit"]
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("base.commit must be a 40-char lowercase hex git object")
    return parent, commit


def build_setup_script(cycle, src_mnt, commit, arms, experiment):
    """実リポジトリを base に clone → detach checkout → 各アーム clone → 注入。"""
    release = release_path(cycle)
    lines = [
        "set -e",
        'if [ -e %s ]; then echo "already exists: %s" >&2; exit 1; fi' % (release, release),
        "mkdir -p %s" % release,
        "cd %s" % release,
        "git clone -q %s base" % shlex.quote(src_mnt),
        "git -C base checkout -q --detach %s" % shlex.quote(commit),
        (
            "actual=$(git -C base rev-parse HEAD); "
            "if [ \"$actual\" != %s ]; then "
            "echo \"mismatch: base HEAD $actual != declared %s\" >&2; exit 1; fi"
            % (shlex.quote(commit), commit)
        ),
    ]
    for arm in arms:
        lines.append("git clone -q base %s" % shlex.quote(arm["id"]))
    manifest_plans = []
    for arm in arms:
        inject_lines, plan = build_arm_inject_lines(arm, experiment)
        lines.extend(inject_lines)
        if plan:
            manifest_plans.append((arm["id"], plan))
    for arm in arms:
        arm_q = shlex.quote(arm["id"])
        # 実リポジトリ base は deny-by-default の .gitignore を持つ。注入した
        # 常時適用ファイルは allowlist 外なので、force しないと commit 対象が空。
        lines.append("git -C %s add -A -f" % arm_q)
        lines.append(
            "if git -C %s diff --cached --quiet; then "
            "echo \"mismatch: %s has nothing to commit after inject\" >&2; exit 1; fi"
            % (arm_q, arm["id"])
        )
        lines.append(
            "git -C %s commit -q -m %s"
            % (arm_q, shlex.quote("variant %s" % arm["variant"]))
        )
    lines.append("echo BASE=$(git -C base rev-parse HEAD)")
    arm_list = " ".join(shlex.quote(arm["id"]) for arm in arms)
    lines.append(
        "for a in %s; do echo ARM=$a; "
        "echo ROOT=$(git -C $a rev-list --max-parents=0 HEAD); "
        "echo SIZE=$(du -sh $a | cut -f1); "
        "echo FILES=$(git -C $a ls-files | wc -l); done" % arm_list
    )
    return "\n".join(lines), manifest_plans


def parse_summary(output):
    summary = {"arms": {}}
    current = None
    for line in output.splitlines():
        if line.startswith("BASE="):
            summary["base"] = line[len("BASE="):]
        elif line.startswith("ARM="):
            current = line[len("ARM="):]
            summary["arms"][current] = {}
        elif line.startswith("ROOT="):
            summary["arms"][current]["root"] = line[len("ROOT="):]
        elif line.startswith("SIZE="):
            summary["arms"][current]["size"] = line[len("SIZE="):]
        elif line.startswith("FILES="):
            summary["arms"][current]["files"] = line[len("FILES="):]
    return summary


def materialize(cycle_name):
    start = time.time()
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    experiment = decl["experiment"]
    src_win, commit = resolve_materialize_base(decl)
    src_mnt = to_mnt(src_win)

    for arm in decl["arms"]:
        mismatches = verify_canonical(experiment, arm)
        if mismatches:
            raise SystemExit("\n".join(mismatches))

    script, manifest_plans = build_setup_script(
        cycle_name, src_mnt, commit, decl["arms"], experiment
    )
    setup_out = exec_(script)

    actual = {}
    for line in setup_out.splitlines():
        if not line.startswith("PLANSHA256 "):
            continue
        _kind, arm_id, dest_rel, digest = line.split(" ", 3)
        actual["%s/%s" % (arm_id, dest_rel)] = digest
    mismatches = []
    for arm_id, plan in manifest_plans:
        for _src, dest, sha in plan:
            key = "%s/%s" % (arm_id, dest)
            if actual.get(key) != sha:
                mismatches.append(key)
    if mismatches:
        raise SystemExit("sha256 mismatch for: %s" % ", ".join(mismatches))

    summary = parse_summary(setup_out)

    injection_commits = {}
    for arm in decl["arms"]:
        injection_commits[arm["id"]] = exec_(
            "git -C %s/%s rev-parse HEAD" % (release_path(cycle_name), shlex.quote(arm["id"]))
        ).strip()
    write_materialized(cycle_name, decl, injection_commits)

    elapsed = time.time() - start
    print("base commit: %s" % summary.get("base"))
    for arm_id, info in summary["arms"].items():
        print(
            "%s: root=%s size=%s files=%s"
            % (arm_id, info.get("root"), info.get("size"), info.get("files"))
        )
    print("elapsed: %.1fs" % elapsed)


def write_materialized(cycle_name, decl, injection_commits):
    """アーム外の <release>/materialized.json に注入 commit を残す。"""
    arms = []
    for arm in decl["arms"]:
        arms.append({
            "id": arm["id"],
            "variant": arm["variant"],
            "variantTree": arm["variantTree"],
            "injectionCommit": injection_commits[arm["id"]],
        })
    payload = {
        "cycle": cycle_name,
        "experiment": decl["experiment"],
        "materializedAt": datetime.datetime.now().astimezone().isoformat(),
        "arms": arms,
    }
    body = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    exec_("cat > %s/materialized.json <<'MATJSON'\n%sMATJSON" % (release_path(cycle_name), body))


def load_materialized(cycle_name):
    """`<release>/materialized.json` を読む。成功は `(payload, None)`。
    ファイルが無いときは `(None, "missing")`、JSON として読めないときは
    `(None, "invalid")`。"""
    stdout, _stderr, code = exec_(
        "cat %s/materialized.json" % release_path(cycle_name), check=False
    )
    if code != 0:
        return None, "missing"
    try:
        return json.loads(stdout), None
    except ValueError:
        return None, "invalid"


def collect_provenance_mismatches(cycle_name, decl):
    """宣言の variantTree とアーム HEAD が materialize 時の注入と結び付いているか照合する。

    handoff 時点ではアームは注入 commit そのものだが、judge 時点では subject が
    workload を実行して commit を重ねている。等号にすると judge が必ず落ちる。
    だから merge-base --is-ancestor。
    """
    mismatches = []
    release = release_path(cycle_name)
    materialized, error = load_materialized(cycle_name)
    if error == "missing":
        mismatches.append("mismatch: materialized.json is missing")
        return mismatches
    if error == "invalid":
        mismatches.append("mismatch: materialized.json is not valid JSON")
        return mismatches

    by_id = {}
    for entry in materialized.get("arms") or ():
        if isinstance(entry, dict) and "id" in entry:
            by_id[entry["id"]] = entry

    for arm in decl["arms"]:
        entry = by_id.get(arm["id"])
        if entry is None:
            mismatches.append(
                "mismatch: materialized.json has no entry for %s" % arm["id"]
            )
            continue
        recorded_tree = entry.get("variantTree")
        if recorded_tree != arm["variantTree"]:
            mismatches.append(
                "mismatch: variantTree for %s in materialized.json: recorded %s, declared %s"
                % (arm["id"], recorded_tree, arm["variantTree"])
            )
            continue
        injection = entry.get("injectionCommit")
        if not isinstance(injection, str):
            injection = ""
        _out, _err, ancestor_code = exec_(
            "git -C %s/%s merge-base --is-ancestor %s HEAD"
            % (release, shlex.quote(arm["id"]), shlex.quote(injection)),
            check=False,
        )
        if ancestor_code != 0:
            mismatches.append(
                "mismatch: %s injectionCommit %s is not an ancestor of HEAD"
                % (arm["id"], injection)
            )

    return mismatches


# session contract file は subject へ渡す唯一の常時適用指示。marker 文字列以外は
# 両アームで 1バイトも変えない（`MEASUREMENT.md` §9-4、憲法 不変条件 (2) の唯一の例外）。
# この文面に実験・計測・測定・アーム・比較といった語を足さない。
# 正本は agent-rules/experiments/<experiment>/session-contract.md。
def session_contract_path(experiment):
    return os.path.join(
        agent_rules_root(), "experiments", experiment, "session-contract.md"
    )


def load_session_contract(experiment):
    with open(session_contract_path(experiment), "rb") as handle:
        return handle.read().decode("utf-8")


def sha256_file(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def is_meta_readability_candidate(path):
    """閉じた可読性候補集合に入るか。posix 相対パスのみ。"""
    if not isinstance(path, str) or not path or "\\" in path or path.startswith("/"):
        return False
    if path in META_READABILITY_FIXED:
        return True
    return any(fnmatch.fnmatch(path, pat) for pat in META_READABILITY_GLOBS)


def meta_readability_hash(path_to_sha):
    """path→内容 sha256 の dict から metaReadabilityHash を純関数で計算する。"""
    parts = []
    for path in sorted(path_to_sha):
        if "\\" in path:
            raise ValueError("meta readability path must be posix: %r" % path)
        parts.append("%s %s\n" % (path, path_to_sha[path]))
    return hashlib.sha256("".join(parts).encode("utf-8")).hexdigest()


def collect_meta_readability_mismatches(readable_meta, declared_hash, present):
    """可読性宣言とアーム上の閉じた集合の照合。実アーム不要の純関数。

    present: アームに存在する閉じた集合パス → 内容 sha256。
    """
    mismatches = []
    declared = list(readable_meta or ())
    present_paths = set(present or ())
    declared_set = set(declared)

    for path in declared:
        if "\\" in path or not path or path.startswith("/"):
            mismatches.append("mismatch: readableMeta path is not posix relative: %s" % path)
            continue
        if not is_meta_readability_candidate(path):
            mismatches.append(
                "mismatch: readableMeta path outside closed set: %s" % path
            )

    for path in sorted(declared_set - present_paths):
        mismatches.append(
            "mismatch: readableMeta declares %s but it is absent on the arm" % path
        )
    for path in sorted(present_paths - declared_set):
        mismatches.append(
            "mismatch: undeclared readability on arm: %s" % path
        )

    if mismatches:
        return mismatches

    computed = meta_readability_hash({p: present[p] for p in declared})
    if computed != declared_hash:
        mismatches.append(
            "mismatch: metaReadabilityHash declared %s, actual %s"
            % (declared_hash, computed)
        )
    return mismatches


def collect_arm_meta_readability_present(cycle_name, arm_id):
    """アーム上の閉じた可読性候補について {path: sha256} を読む。"""
    release = release_path(cycle_name)
    arm_ref = "%s/%s" % (release, shlex.quote(arm_id))
    fixed = " ".join(shlex.quote(p) for p in META_READABILITY_FIXED)
    globs = " ".join(shlex.quote(p) for p in META_READABILITY_GLOBS)
    script = "\n".join([
        "set -e",
        "arm=%s" % arm_ref,
        "for p in %s; do" % fixed,
        "  if [ -e \"$arm/$p\" ]; then",
        "    printf '%s %s\\n' \"$p\" \"$(sha256sum \"$arm/$p\" | cut -d' ' -f1)\"",
        "  fi",
        "done",
        "cd \"$arm\"",
        (
            "git ls-files -z -- %s | while IFS= read -r -d '' p; do "
            "printf '%%s %%s\\n' \"$p\" \"$(sha256sum \"$p\" | cut -d' ' -f1)\"; "
            "done"
        ) % globs,
    ])
    out = exec_(script)
    present = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        path, _, digest = line.partition(" ")
        if path and digest:
            present[path] = digest
    return present


def write_cycle(name, decl):
    path = os.path.join(CYCLES_DIR, "%s.json" % name)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(decl, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def collect_handoff_mismatches(cycle_name, decl):
    """handoff 前の照合。宣言と実物の食い違い、アームが materialize 直後で
    ないこと、config root に transcript が既にあることをすべて集めて返す
    （無ければ空リスト）。"""
    experiment = decl["experiment"]
    mismatches = []

    for arm in decl["arms"]:
        mismatches.extend(verify_canonical(experiment, arm))

    hash_checks = [
        ("workloadHash", os.path.join(agent_rules_root(), "experiments", experiment, "workload.md")),
        ("measurementHash", os.path.join(agent_rules_root(), "experiments", experiment, "MEASUREMENT.md")),
        ("judgeHash", os.path.join(agent_rules_root(), "experiments", experiment, "judge", "judge.py")),
        ("sessionContractHash", session_contract_path(experiment)),
        ("executionUnitHash", execution_unit_path()),
    ]
    if cycle_kind(decl) == "estimation":
        hash_checks = [item for item in hash_checks if item[0] != "judgeHash"]
    for key, path in hash_checks:
        actual = sha256_file(path)
        if actual != decl[key]:
            mismatches.append("mismatch: %s declared %s, actual %s" % (key, decl[key], actual))

    release = release_path(cycle_name)
    # 全アームが同じ履歴 root から出ていること、および base HEAD の上の
    # commit が variant 注入の1つだけであること。
    roots = {"base": exec_("git -C %s/base rev-list --max-parents=0 HEAD" % release).strip()}
    for arm in decl["arms"]:
        roots[arm["id"]] = exec_(
            "git -C %s/%s rev-list --max-parents=0 HEAD" % (release, shlex.quote(arm["id"]))
        ).strip()
    if len(set(roots.values())) != 1:
        mismatches.append(
            "mismatch: base commit not aligned: %s"
            % ", ".join("%s=%s" % (name, sha) for name, sha in roots.items())
        )

    base_head = exec_("git -C %s/base rev-parse HEAD" % release).strip()
    declared_base = decl.get("base") if isinstance(decl.get("base"), dict) else None
    declared_commit = declared_base.get("commit") if declared_base else None
    if declared_commit and base_head != declared_commit:
        mismatches.append(
            "mismatch: base HEAD %s != declared base.commit %s"
            % (base_head, declared_commit)
        )
    for arm in decl["arms"]:
        dirty = exec_("git -C %s/%s status --porcelain" % (release, shlex.quote(arm["id"])))
        if dirty.strip():
            mismatches.append("mismatch: %s tree is dirty:\n%s" % (arm["id"], dirty.strip()))
        # workload.md は commit を許すので porcelain は実行後に空へ戻る。
        # materialize は base HEAD の上に variant 注入 1 commit だけを置く。
        after_base = exec_(
            "git -C %s/%s rev-list --count %s..HEAD"
            % (release, shlex.quote(arm["id"]), shlex.quote(base_head))
        ).strip()
        if after_base != "1":
            mismatches.append(
                "mismatch: %s has %s commits after base (expected 1: variant injection only)"
                % (arm["id"], after_base)
            )
        transcripts = find_transcripts(cycle_name, arm, decl)
        if transcripts:
            mismatches.append(
                "mismatch: %s already has transcript(s); refusing to rebuild: %s"
                % (arm["id"], ", ".join(transcripts))
            )

    if "readableMeta" in decl or "metaReadabilityHash" in decl:
        for arm in decl["arms"]:
            present = collect_arm_meta_readability_present(cycle_name, arm["id"])
            mismatches.extend(
                collect_meta_readability_mismatches(
                    decl.get("readableMeta"),
                    decl.get("metaReadabilityHash"),
                    present,
                )
            )

    mismatches.extend(collect_provenance_mismatches(cycle_name, decl))
    return mismatches


def build_config_script(cycle, experiment, arms, subject):
    """両アームの config root を作り直し、subject 記述子の configRoot 項目を置く。
    null の項目は書かない。"""
    release = release_path(cycle)
    lines = ["set -e", "cd %s" % release]
    template = load_session_contract(experiment)
    config = subject["configRoot"]
    always_apply = config["alwaysApplyFile"]
    empty_rules = config["emptyRulesDir"]
    cred_dest = config["credentialDest"]
    cred_source = config["credentialSource"]
    for arm in arms:
        cfg = "cfg-%s" % arm["variant"]
        lines.append("rm -rf %s" % shlex.quote(cfg))
        lines.append("mkdir -p %s" % shlex.quote(cfg))
        if empty_rules is not None:
            lines.append("mkdir -p %s" % shlex.quote("%s/%s" % (cfg, empty_rules)))
        if always_apply is not None:
            body = template % (experiment, arm["variant"])
            lines.append(
                "cat > %s <<'CFGEOF'\n%sCFGEOF"
                % (shlex.quote("%s/%s" % (cfg, always_apply)), body)
            )
        if cred_source is not None and cred_dest is not None:
            lines.append(
                "cp %s %s" % (cred_source, shlex.quote("%s/%s" % (cfg, cred_dest)))
            )
            lines.append("chmod 600 %s" % shlex.quote("%s/%s" % (cfg, cred_dest)))
    return "\n".join(lines)


def build_baseline_script(cycle, judge_path, arm):
    """1アーム分の baseline manifest をアームの外（release 直下）へ出力する。"""
    release = release_path(cycle)
    output = "baseline-%s.json" % arm["id"]
    lines = [
        "set -e",
        "cd %s" % release,
        "python3 %s baseline --arm %s -o %s"
        % (shlex.quote(judge_path), shlex.quote(arm["id"]), shlex.quote(output)),
        "grep -m1 %s %s" % (shlex.quote('"arm"'), shlex.quote(output)),
    ]
    return "\n".join(lines)


def handoff(cycle_name):
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    require_subject(cycle_name, decl, require_version=False)
    experiment = decl["experiment"]
    ids = subject_ids(decl)
    if len(ids) != 1:
        raise SystemExit("handoff は subject 1つ")
    subject = load_subject(ids[0])
    if subject["versionCommand"] is None or subject["binary"] is None:
        raise SystemExit(
            "subject %s has unconfirmed versionCommand or binary; refusing to proceed"
            % subject["id"]
        )

    mismatches = collect_handoff_mismatches(cycle_name, decl)
    if mismatches:
        raise SystemExit("\n".join(mismatches))

    version = exec_(subject["versionCommand"]).strip()
    if "subjectVersion" in decl:
        del decl["subjectVersion"]
    versioned = {}
    for key, value in decl.items():
        versioned[key] = value
        if key == "subject":
            versioned["subjectVersion"] = version
    decl = versioned
    write_cycle(cycle_name, decl)
    print("subject version: %s" % version)

    exec_(build_config_script(cycle_name, experiment, decl["arms"], subject))

    if cycle_kind(decl) != "estimation":
        judge_path = "%s/experiments/%s/judge/judge.py" % (to_mnt(agent_rules_root()), experiment)
        for arm in decl["arms"]:
            out = exec_(build_baseline_script(cycle_name, judge_path, arm))
            print("baseline %s: %s" % (arm["id"], out.strip().replace("\n", " ")))

    env = load_environment()
    if env["host"] != "unix":
        raise SystemExit(
            "launch command printing is only defined for host=unix (got %r)" % env["host"]
        )
    print("")
    for arm in sorted(decl["arms"], key=lambda a: a["variant"]):
        print(
            "wsl.exe -d %s -u %s -e bash -lc 'cd $HOME/releases/%s/%s && "
            "%s=$HOME/releases/%s/cfg-%s %s'"
            % (
                env["distro"], env["user"], cycle_name, arm["id"],
                subject["isolationEnv"], cycle_name, arm["variant"], subject["binary"],
            )
        )


def _transcript_search_base(cycle_name, arm, search_root="config-root"):
    """`_list_transcript_paths` が列挙する起点ディレクトリ。config-root は
    アームの cfg-<variant> 配下、home-cursor は distro の $HOME/.cursor 配下
    （cursor-agent の transcript は cfg 配下に置かれないため。実測は
    docs/ISSUES.md 参照）。"""
    if search_root == "home-cursor":
        return '"$HOME"/.cursor'
    release = release_path(cycle_name)
    cfg = shlex.quote("cfg-%s" % arm["variant"])
    return "%s/%s" % (release, cfg)


def _list_transcript_paths(cycle_name, arm, glob_pat, search_root="config-root"):
    """1つの glob で起点ディレクトリ（search_root）配下を列挙する。"""
    if search_root == "home-cursor":
        arm_path = '"$HOME"/releases/%s/%s' % (
            shlex.quote(cycle_name), shlex.quote(arm["id"]),
        )
        pattern = '"$HOME"/.cursor/projects/$slug/%s' % glob_pat
        out, _stderr, _code = exec_(
            'arm_path=%s; slug=${arm_path#/}; slug=${slug//\\//-}; ls %s 2>/dev/null'
            % (arm_path, pattern),
            check=False,
        )
        return [line.strip() for line in out.splitlines() if line.strip()]
    base = _transcript_search_base(cycle_name, arm, search_root)
    pattern = "%s/%s" % (base, glob_pat)
    prefix = "shopt -s globstar; " if "**" in glob_pat else ""
    out, _stderr, _code = exec_("%sls %s 2>/dev/null" % (prefix, pattern), check=False)
    return [line.strip() for line in out.splitlines() if line.strip()]


def find_transcripts(cycle_name, arm, decl=None):
    """`$HOME/releases/<cycle>/cfg-<variant>/` 配下（または subject 記述子が
    `searchRoot: home-cursor` を指すなら distro の `$HOME/.cursor` 配下）を、
    subjects/ 全記述子の transcripts.glob で列挙する。transcripts が null の
    subject は飛ばす。重複パスは1回。0件なら空リスト。発見した全件を返し、選ばない。
    decl は呼び出し互換のため受け取るが、列挙対象は宣言の subject に限らない。"""
    del decl  # 宣言の subject だけに限らない。
    paths = []
    seen = set()
    for subject in iter_transcript_subjects():
        transcripts = subject["transcripts"]
        for line in _list_transcript_paths(
            cycle_name, arm, transcripts["glob"], transcripts.get("searchRoot", "config-root")
        ):
            if line not in seen:
                seen.add(line)
                paths.append(line)
    return paths


def project_slug(arm_path):
    """subject が transcript を置く project ディレクトリ名を、アームの絶対パス
    （distro 内）から導く。実測した規則（2026-08-18、ライブ資産で確認）:
    絶対パスの `/` を `-` へ置換したもの。この規則を推測で広げない。導けない
    名前は照合側（transcript_slug_mismatch）が mismatch として報告する。"""
    return arm_path.replace("/", "-")


def cursor_project_slug(arm_path):
    """cursor-agent が transcript を置く project ディレクトリ名。ワークスペース
    絶対パスの先頭 `/` を落としてから `/` を `-` へ置換する。project_slug との
    違いは先頭ハイフンの有無だけ（この規則は変えない）。"""
    trimmed = arm_path[1:] if arm_path.startswith("/") else arm_path
    return project_slug(trimmed)


def transcript_slug_mismatch(arm, transcript):
    """transcript の project ディレクトリ名が、そのアームのパスから導けるかを
    照合する。`cd <arm>` × isolation env var を別 cfg に向けた取り違えで、別の
    アームのセッションの証拠がこのアームの判定に使われる経路を塞ぐ。導けれ
    ば None、導けなければ mismatch 文字列を返す。armBinding == project-slug
    のときだけ呼ぶこと。"""
    # find_transcripts の glob により、transcript は必ず
    # <release>/cfg-<variant>/projects/<slug>/<file>.jsonl の形をしている。
    parts = transcript.split("/")
    actual_slug = parts[-2]
    release_root = "/".join(parts[:-4])
    expected_slug = project_slug("%s/%s" % (release_root, arm["id"]))
    if actual_slug != expected_slug:
        return (
            "mismatch: %s transcript project slug %s does not derive from the arm path "
            "(expected %s): %s" % (arm["id"], actual_slug, expected_slug, transcript)
        )
    return None


def derive_arm_path(arm, transcript):
    """transcript パスに /cfg-<variant>/ があれば、その手前を release root とし
    {release}/{arm.id} を返す。無ければ None。"""
    marker = "/cfg-%s/" % arm["variant"]
    idx = transcript.find(marker)
    if idx < 0:
        return None
    return "%s/%s" % (transcript[:idx], arm["id"])


def classify_session(arm, fact):
    """所属を確定する純関数。返り値は (belonging, belongingReason|None)。
    belonging は belongs / does-not-belong / unclassifiable。正本は
    docs/EXECUTION-UNIT.md。"""
    binding = fact.get("armBinding")
    if binding == "project-slug":
        mismatch = transcript_slug_mismatch(arm, fact["path"])
        if mismatch:
            return "does-not-belong", mismatch
        return "belongs", None
    if binding == "cursor-project-slug":
        arm_path = fact.get("armPath")
        if not arm_path:
            return "unclassifiable", "armPath could not be derived"
        marker = "/.cursor/projects/"
        _before, found, rest = fact["path"].partition(marker)
        if not found or not rest:
            return "unclassifiable", "cursor transcript project path missing"
        actual_slug = rest.split("/", 1)[0]
        expected_slug = cursor_project_slug(arm_path)
        if actual_slug == expected_slug:
            return "belongs", None
        return (
            "does-not-belong",
            "cursor project slug %s does not derive from armPath %s"
            % (actual_slug, arm_path),
        )
    if binding == "session-meta-cwd":
        cwd = fact.get("cwd")
        if not cwd:
            return "unclassifiable", "session_meta cwd missing"
        arm_path = fact.get("armPath") or derive_arm_path(arm, fact["path"])
        if not arm_path:
            return "unclassifiable", "armPath could not be derived"
        if cwd == arm_path:
            return "belongs", None
        return (
            "does-not-belong",
            "cwd %s does not match armPath %s" % (cwd, arm_path),
        )
    return "unclassifiable", "armBinding %r" % (binding,)


def injection_commit_of(materialized, arm_id):
    """materialized.json の arms[] から、そのアームの injectionCommit を取る。"""
    if not materialized:
        return None
    for entry in materialized.get("arms") or ():
        if isinstance(entry, dict) and entry.get("id") == arm_id:
            value = entry.get("injectionCommit")
            if isinstance(value, str) and value:
                return value
            return None
    return None


def load_commits_since(cycle_name, arm, since_sha):
    """`since_sha..HEAD` の (sha, author time) を新しい順で返す。"""
    out = exec_(
        "git -C %s/%s log --format='%%H %%aI' %s..HEAD"
        % (release_path(cycle_name), shlex.quote(arm["id"]), shlex.quote(since_sha))
    )
    commits = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        sha, _, author_time = line.partition(" ")
        commits.append((sha, author_time))
    return commits


def commits_since_root_fallback(cycle_name, arm):
    """materialized.json が無いときの照合B対象。root の直後の commit を
    注入とみなし、`その commit..HEAD` を返す（injection..HEAD と同じ
    排他区間）。root 自身や注入 commit を対象に入れると、controller が書いた
    注入が span 外になり照合Bが落ちる。"""
    root = exec_(
        "git -C %s/%s rev-list --max-parents=0 HEAD"
        % (release_path(cycle_name), shlex.quote(arm["id"]))
    ).strip()
    listed = exec_(
        "git -C %s/%s rev-list --reverse %s..HEAD"
        % (release_path(cycle_name), shlex.quote(arm["id"]), shlex.quote(root))
    )
    after_root = [line.strip() for line in listed.splitlines() if line.strip()]
    since = after_root[0] if after_root else root
    return load_commits_since(cycle_name, arm, since), root, since


def build_transcript_facts_script(paths, participation, arm_binding=None):
    """distro 内 python3 で、各 jsonl の最初/最後の timestamp と参加エントリ数を出す。

    参加判定は subject 記述子の transcripts.participation。`jsonlField` は
    ドット区切りで入れ子（例: `payload.role`）を辿れる単一 predicate
    （`{jsonlField, equals}`）、複数 predicate の AND（`{"all": [predicate, ...]}`）、
    または null を取る。participation が null なら assistantCount は常に 0
    （推測の判定形式を焼かない）。
    arm_binding が session-meta-cwd のとき、先頭の非空行が type==session_meta なら
    payload.cwd を取る（無ければ None）。他の形は推測で足さない。
    marker の数え方は判定器の仕事であり、装置は持たない。
    """
    lines = [
        "set -e",
        "python3 - <<'PY'",
        "import json",
        "paths = %s" % json.dumps(paths, ensure_ascii=False),
        "participation = %s" % json.dumps(participation, ensure_ascii=False),
        "arm_binding = %s" % json.dumps(arm_binding, ensure_ascii=False),
        "",
        "def _resolve(obj, dotted):",
        "    cur = obj",
        "    for part in dotted.split('.'):",
        "        if not isinstance(cur, dict) or part not in cur:",
        "            return None",
        "        cur = cur[part]",
        "    return cur",
        "",
        "def _participation_matches(obj, participation):",
        "    if participation is None:",
        "        return False",
        "    preds = participation['all'] if 'all' in participation else [participation]",
        "    return all(_resolve(obj, p['jsonlField']) == p['equals'] for p in preds)",
        "",
        "results = []",
        "for path in paths:",
        "    first = last = None",
        "    assistants = 0",
        "    cwd = None",
        "    first_nonempty = True",
        "    with open(path, encoding='utf-8') as handle:",
        "        for raw in handle:",
        "            line = raw.strip()",
        "            if not line:",
        "                continue",
        "            obj = json.loads(line)",
        "            if first_nonempty:",
        "                first_nonempty = False",
        "                if arm_binding == 'session-meta-cwd' and obj.get('type') == 'session_meta':",
        "                    payload = obj.get('payload')",
        "                    if isinstance(payload, dict):",
        "                        cwd = payload.get('cwd')",
        "            ts = obj.get('timestamp')",
        "            if isinstance(ts, str):",
        "                if first is None:",
        "                    first = ts",
        "                last = ts",
        "            if _participation_matches(obj, participation):",
        "                assistants += 1",
        "    results.append({",
        "        'path': path,",
        "        'firstTimestamp': first,",
        "        'lastTimestamp': last,",
        "        'assistantCount': assistants,",
        "        'cwd': cwd,",
        "    })",
        "print(json.dumps(results, ensure_ascii=False))",
        "PY",
    ]
    return "\n".join(lines)


def transcript_facts(cycle_name, arm, decl=None):
    """アームの config root にある全 jsonl について、span と参加エントリ数を返す。
    subjects/ 全記述子を走査する。各 fact に tool / armBinding / armPath /
    （session-meta-cwd なら）cwd を付ける。"""
    del decl
    facts = []
    for subject in iter_transcript_subjects():
        transcripts = subject["transcripts"]
        paths = _list_transcript_paths(
            cycle_name, arm, transcripts["glob"], transcripts.get("searchRoot", "config-root")
        )
        if not paths:
            continue
        arm_binding = transcripts.get("armBinding")
        raw = exec_(
            build_transcript_facts_script(
                paths, transcripts.get("participation"), arm_binding
            )
        )
        payload = json.loads(raw)
        for item in payload:
            path = item["path"]
            fact = {
                "tool": subject["id"],
                "path": path,
                "firstTimestamp": item.get("firstTimestamp"),
                "lastTimestamp": item.get("lastTimestamp"),
                "assistantCount": int(item["assistantCount"]),
                "armBinding": arm_binding,
                "armPath": (
                    "%s/releases/%s/%s" % (path.partition("/.cursor/projects/")[0], cycle_name, arm["id"])
                    if arm_binding == "cursor-project-slug" else derive_arm_path(arm, path)
                ),
            }
            if arm_binding == "session-meta-cwd":
                fact["cwd"] = item.get("cwd")
            facts.append(fact)
    return facts


def format_transcript_fact(fact):
    first, last = fact["firstTimestamp"], fact["lastTimestamp"]
    if first and last:
        span = "%s..%s" % (first, last)
    else:
        span = "(no timestamp)"
    participating = "yes" if fact["assistantCount"] >= 1 else "no"
    return "%s span=%s assistant=%d participating=%s" % (
        fact["path"], span, fact["assistantCount"], participating,
    )


def collect_execution_mismatches(arm, facts, commits):
    """照合A′（所属・参加）と照合B′（commit の author time が所属参加
    セッションの span の和に内包されること）。正本は docs/EXECUTION-UNIT.md。

    facts と commits を引数で受け、実資産に触れない。所属は各 fact の
    armBinding で確定する。件数の上限は無い。装置は参加エントリの存在だけを
    見る。marker は持たない。
    """
    mismatches = []
    belongs_participating = []
    for fact in facts:
        belonging, reason = classify_session(arm, fact)
        if belonging == "unclassifiable":
            mismatches.append(
                "mismatch: %s session unclassifiable (%s): %s"
                % (arm["id"], reason, fact["path"])
            )
            continue
        if belonging == "does-not-belong":
            if isinstance(reason, str) and reason.startswith("mismatch:"):
                mismatches.append(reason)
            else:
                mismatches.append(
                    "mismatch: %s session does not belong to this arm (%s): %s"
                    % (arm["id"], reason, fact["path"])
                )
            continue
        if fact["assistantCount"] >= 1:
            belongs_participating.append(fact)

    if not belongs_participating:
        details = ", ".join(format_transcript_fact(fact) for fact in facts) or "(none)"
        mismatches.append(
            "mismatch: %s belonging participating session count 0: %s"
            % (arm["id"], details)
        )
        return mismatches

    missing_ts = False
    for session in belongs_participating:
        first, last = session["firstTimestamp"], session["lastTimestamp"]
        if not first or not last:
            missing_ts = True
            mismatches.append(
                "mismatch: %s belonging participating session has no timestamp; "
                "cannot build span: %s" % (arm["id"], session["path"])
            )
    if missing_ts:
        return mismatches

    start = min(
        parse_timestamp(s["firstTimestamp"]) for s in belongs_participating
    )
    end = max(
        parse_timestamp(s["lastTimestamp"]) for s in belongs_participating
    )
    first_label = min(
        (s["firstTimestamp"] for s in belongs_participating),
        key=parse_timestamp,
    )
    last_label = max(
        (s["lastTimestamp"] for s in belongs_participating),
        key=parse_timestamp,
    )
    for sha, author_time in commits:
        moment = parse_timestamp(author_time)
        if moment < start or moment > end:
            mismatches.append(
                "mismatch: %s commit %s at %s is outside belonging participating "
                "session span [%s, %s]"
                % (arm["id"], sha, author_time, first_label, last_label)
            )
    return mismatches


def belonging_participating_sessions(arm, facts):
    """belongs かつ assistantCount >= 1 の fact 一覧。"""
    out = []
    for fact in facts:
        belonging, _reason = classify_session(arm, fact)
        if belonging == "belongs" and fact["assistantCount"] >= 1:
            out.append(fact)
    return out


def participating_path(arm, facts):
    """現行 judge.py 向け。belongs 参加がちょうど1件のときだけその path。"""
    participating = belonging_participating_sessions(arm, facts)
    if len(participating) != 1:
        return None
    return participating[0]["path"]


def session_entries_for_record(arm, facts):
    """記録の arms[].sessions。発見した各セッションの所属確定結果。"""
    entries = []
    for fact in facts:
        belonging, reason = classify_session(arm, fact)
        entry = {
            "tool": fact["tool"],
            "path": fact["path"],
            "span": {
                "start": fact.get("firstTimestamp"),
                "end": fact.get("lastTimestamp"),
            },
            "assistantCount": fact["assistantCount"],
            "belonging": belonging,
        }
        if reason:
            entry["belongingReason"] = reason
        entries.append(entry)
    return entries


def baseline_arg(cycle_name, arm):
    """`judge.py --baseline` へ渡す引数。`$HOME` は distro 内の bash が展開する。
    実際に渡すもの（build_judge_script）と記録する出所（baseline_provenance）が
    同じパスを指すことを、組み立てを1箇所にして担保する。"""
    return "%s/%s" % (release_path(cycle_name), shlex.quote("baseline-%s.json" % arm["id"]))


def stat_mtime_to_iso8601(value):
    """`stat -c %y` の出力（例: `2026-08-18 08:51:53.882533183 +0900`）を
    オフセット付き ISO 8601 へ直す。ナノ秒はマイクロ秒へ切り詰める。"""
    match = re.match(
        r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?:\.(\d+))? ([+-]\d{2}):?(\d{2})$",
        value.strip(),
    )
    if not match:
        raise SystemExit("unrecognized stat mtime output: %r" % value)
    date, hms, frac, offset_h, offset_m = match.groups()
    micro = ((frac or "") + "000000")[:6]
    return "%sT%s.%s%s:%s" % (date, hms, micro, offset_h, offset_m)


def baseline_provenance(cycle_name, arm):
    """記録へ書く baseline manifest の出所を distro 内で採る。返り値は
    (path, sha256, mtime の ISO 8601)。path は sha256sum が出力した実パス
    （`$HOME` 展開後）で、判定器が実際に受け取ったものと同じ。"""
    baseline = baseline_arg(cycle_name, arm)
    out = exec_("sha256sum %s && stat -c %%y %s" % (baseline, baseline))
    lines = [line for line in out.splitlines() if line.strip()]
    digest, _, path = lines[0].partition("  ")
    return path, digest, stat_mtime_to_iso8601(lines[1])


def build_judge_script(cycle_name, experiment, arm, transcript):
    """1アーム分の `judge.py judge` 呼び出し。判定が全 met でなければ判定器は
    exit 1 を返すが、それは正当な計測結果であって infra 失敗ではない。呼び
    出し元は returncode を 0/1 とそれ以外で扱い分ける。"""
    release = release_path(cycle_name)
    judge_path = "%s/experiments/%s/judge/judge.py" % (to_mnt(agent_rules_root()), experiment)
    workload_path = "%s/experiments/%s/workload.md" % (to_mnt(agent_rules_root()), experiment)
    arm_path = "%s/%s" % (release, shlex.quote(arm["id"]))
    baseline_path = baseline_arg(cycle_name, arm)
    return (
        "python3 %s judge --arm %s --workload %s --variant %s --transcript %s --baseline %s"
        % (
            shlex.quote(judge_path),
            arm_path,
            shlex.quote(workload_path),
            shlex.quote(arm["variant"]),
            shlex.quote(transcript),
            baseline_path,
        )
    )


def validate_record(record):
    """書く直前の記録検証。形はスキーマに委ね、スキーマで書けないアーム間
    条件だけをここで持つ。失敗は SystemExit、成功は None。"""
    try:
        import jsonschema
    except ImportError:
        raise SystemExit(
            "jsonschema is required to validate cycle records; install with: pip install -r %s"
            % os.path.join(APPARATUS_DIR, "requirements.txt")
        )

    schema_path = os.path.join(APPARATUS_DIR, "schemas", "cycle-record.schema.json")
    with open(schema_path, encoding="utf-8") as handle:
        schema = json.load(handle)
    validator_cls = jsonschema.validators.validator_for(schema)
    validator = validator_cls(schema)
    schema_errors = sorted(validator.iter_errors(record), key=lambda e: list(e.absolute_path))
    if schema_errors:
        raise SystemExit("\n".join(
            "schema: %s: %s" % ("/".join(str(p) for p in err.absolute_path) or "(root)", err.message)
            for err in schema_errors
        ))

    mismatches = []
    arms = record["arms"]
    ids = [arm["id"] for arm in arms]
    if len(ids) != len(set(ids)):
        mismatches.append("arms[].id not unique: %s" % ids)

    criteria_lengths = [len(arm["criteria"]) for arm in arms]
    if len(set(criteria_lengths)) != 1:
        mismatches.append(
            "criteria length not identical across arms: %s" % criteria_lengths
        )
    else:
        n = criteria_lengths[0]
        expected = list(range(1, n + 1))
        for arm in arms:
            numbers = sorted(item["criterion"] for item in arm["criteria"])
            if numbers != expected:
                mismatches.append(
                    "criteria must be 1..%d exactly once for arm %s: %s"
                    % (n, arm["id"], numbers)
                )

    judge_shas = {arm["judgeSha256"] for arm in arms}
    if len(judge_shas) != 1:
        mismatches.append("judgeSha256 not identical across arms: %s" % sorted(judge_shas))

    workload_shas = {arm["workloadSha256"] for arm in arms}
    if len(workload_shas) != 1:
        mismatches.append("workloadSha256 not identical across arms: %s" % sorted(workload_shas))

    texts_by_criterion = {}
    for arm in arms:
        for item in arm["criteria"]:
            if item["criterion"] == 1:
                continue
            texts_by_criterion.setdefault(item["criterion"], []).append(item["text"])
    for number in sorted(texts_by_criterion):
        texts = texts_by_criterion[number]
        if len(set(texts)) != 1:
            mismatches.append(
                "criterion %s text not identical across arms: %s" % (number, texts)
            )

    # フィールド間の比較はスキーマで書けない。baseline manifest は
    # workload 実行前に採ったものなので、記録時刻より前でなければならない。
    recorded_at = parse_timestamp(record["recordedAt"])
    for arm in arms:
        if parse_timestamp(arm["baselineRecordedAt"]) >= recorded_at:
            mismatches.append(
                "baselineRecordedAt %s is not before recordedAt %s for arm %s"
                % (arm["baselineRecordedAt"], record["recordedAt"], arm["id"])
            )
        if arm["transcript"] not in arm["transcriptsDiscovered"]:
            mismatches.append(
                "transcript %s is not in transcriptsDiscovered for arm %s"
                % (arm["transcript"], arm["id"])
            )

    if mismatches:
        raise SystemExit("\n".join(mismatches))
    return None


def judge(cycle_name, replace=False):
    """判定器を両アームへ同一に適用し、記録を private-control/reviews/ へ
    書く。1つでも照合に落ちたら記録は書かず exit 非0にする（食い違いは
    全件集めてから出す）。既存記録の上書きは --replace の明示が要る。"""
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    if cycle_kind(decl) == "estimation":
        raise SystemExit(
            "estimation cycle rejects judge (no comparison arms): %s" % cycle_name
        )
    require_subject(cycle_name, decl, require_version=True)
    experiment = decl["experiment"]
    mismatches = []

    judge_win = os.path.join(agent_rules_root(), "experiments", experiment, "judge", "judge.py")
    workload_win = os.path.join(agent_rules_root(), "experiments", experiment, "workload.md")
    measurement_win = os.path.join(agent_rules_root(), "experiments", experiment, "MEASUREMENT.md")
    session_contract_win = session_contract_path(experiment)
    judge_sha256 = sha256_file(judge_win)
    workload_sha256 = sha256_file(workload_win)
    measurement_sha256 = sha256_file(measurement_win)
    session_contract_sha256 = sha256_file(session_contract_win)
    execution_unit_sha256 = sha256_file(execution_unit_path())
    for key, actual in (
        ("judgeHash", judge_sha256),
        ("workloadHash", workload_sha256),
        ("measurementHash", measurement_sha256),
        ("sessionContractHash", session_contract_sha256),
        ("executionUnitHash", execution_unit_sha256),
    ):
        if actual != decl[key]:
            mismatches.append("mismatch: %s declared %s, actual %s" % (key, decl[key], actual))

    # 判定対象そのものの照合。上書きガードより先に行い、食い違いを全件まとめて
    # 出す（ここで落ちる限り記録は書かれないので、ガードの保証は変わらない）。
    materialized, _mat_error = load_materialized(cycle_name)
    facts_by_arm = {}
    transcripts_by_arm = {}
    sessions_by_arm = {}
    for arm in decl["arms"]:
        # 作業ツリーが汚れていると、判定器は git ではなく glob で読む以上、
        # 判定は作業ツリーの内容に対して行われるのに記録の armCommit はその
        # 内容を指さない。装置側で空であることを担保するしかない。
        dirty = exec_(
            "git -C %s/%s status --porcelain"
            % (release_path(cycle_name), shlex.quote(arm["id"]))
        )
        if dirty.strip():
            mismatches.append("mismatch: %s tree is dirty:\n%s" % (arm["id"], dirty.strip()))
        facts = transcript_facts(cycle_name, arm, decl)
        facts_by_arm[arm["id"]] = facts
        sessions_by_arm[arm["id"]] = session_entries_for_record(arm, facts)
        injection = injection_commit_of(materialized, arm["id"])
        commits = load_commits_since(cycle_name, arm, injection) if injection else []
        mismatches.extend(collect_execution_mismatches(arm, facts, commits))
        chosen = participating_path(arm, facts)
        if chosen:
            transcripts_by_arm[arm["id"]] = chosen

    mismatches.extend(collect_provenance_mismatches(cycle_name, decl))

    if mismatches:
        raise SystemExit("\n".join(mismatches))

    for arm in decl["arms"]:
        if arm["id"] not in transcripts_by_arm:
            parts = belonging_participating_sessions(arm, facts_by_arm[arm["id"]])
            raise SystemExit(
                "mismatch: %s belonging participating sessions %d; "
                "current judge.py takes exactly 1 transcript (aggregation is not implemented)"
                % (arm["id"], len(parts))
            )

    review_path = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if os.path.exists(review_path):
        try:
            with open(review_path, encoding="utf-8") as handle:
                existing = json.load(handle)
        except (ValueError, UnicodeDecodeError):
            raise SystemExit(
                "existing record is not valid JSON (not schemaVersion 2); "
                "refusing to overwrite even with --replace: %s" % review_path
            )
        if not isinstance(existing, dict) or existing.get("schemaVersion") != 2:
            raise SystemExit(
                "existing record schemaVersion is %r (expected 2); "
                "refusing to overwrite even with --replace: %s"
                % (
                    existing.get("schemaVersion") if isinstance(existing, dict) else type(existing).__name__,
                    review_path,
                )
            )
        if existing.get("cycle") != cycle_name:
            raise SystemExit(
                "existing record cycle is %r but this run is for %r; "
                "refusing to overwrite: %s"
                % (existing.get("cycle"), cycle_name, review_path)
            )
        if not replace:
            existing_judge = None
            for arm in existing.get("arms") or ():
                if "judgeSha256" in arm:
                    existing_judge = arm["judgeSha256"]
                    break
            raise SystemExit(
                "record already exists for cycle %s (recordedAt=%s, judgeSha256=%s); "
                "pass --replace to overwrite: %s"
                % (cycle_name, existing.get("recordedAt"), existing_judge, review_path)
            )

    reports = {}
    for arm in decl["arms"]:
        transcript = transcripts_by_arm[arm["id"]]
        stdout, stderr, code = exec_(build_judge_script(cycle_name, experiment, arm, transcript), check=False)
        if code not in (0, 1):
            raise SystemExit(
                "judge invocation failed for %s (exit %d): %s" % (arm["id"], code, stderr.strip())
            )
        try:
            report = json.loads(stdout)
        except ValueError as exc:
            mismatches.append("mismatch: %s judge output is not valid JSON: %s" % (arm["id"], exc))
            continue
        reports[arm["id"]] = {"transcript": transcript, "report": report, "exitCode": code}

    # validate_arms が arm id の一意性を保証しているので、この等式は本来の
    # 意味（全アームの report が揃った）を持つ。重複 id で reports が潰れて
    # 以下の照合が黙ってスキップされる経路は無い。ガードを消さない。
    if len(reports) == len(decl["arms"]):
        judge_shas = {info["report"]["judgeSha256"] for info in reports.values()}
        if len(judge_shas) != 1 or next(iter(judge_shas)) != decl["judgeHash"]:
            mismatches.append(
                "mismatch: judgeSha256 across arms/declaration: %s vs declared %s"
                % (sorted(judge_shas), decl["judgeHash"])
            )
        workload_shas = {info["report"]["workloadSha256"] for info in reports.values()}
        if len(workload_shas) != 1 or next(iter(workload_shas)) != decl["workloadHash"]:
            mismatches.append(
                "mismatch: workloadSha256 across arms/declaration: %s vs declared %s"
                % (sorted(workload_shas), decl["workloadHash"])
            )

    if mismatches:
        raise SystemExit("\n".join(mismatches))

    base_commit = exec_("git -C %s/base rev-parse HEAD" % release_path(cycle_name)).strip()

    injection_by_id = {
        entry["id"]: entry["injectionCommit"]
        for entry in materialized["arms"]
    }

    arms_out = []
    for arm in decl["arms"]:
        info = reports[arm["id"]]
        arm_commit = exec_(
            "git -C %s/%s rev-parse HEAD" % (release_path(cycle_name), shlex.quote(arm["id"]))
        ).strip()
        baseline_real_path, baseline_sha256, baseline_recorded_at = baseline_provenance(
            cycle_name, arm
        )
        arms_out.append({
            "id": arm["id"],
            "role": arm["role"],
            "variant": arm["variant"],
            "variantTree": arm["variantTree"],
            "variantInjectionCommit": injection_by_id[arm["id"]],
            "armCommit": arm_commit,
            "transcript": info["transcript"],
            "transcriptsDiscovered": [fact["path"] for fact in facts_by_arm[arm["id"]]],
            "sessions": sessions_by_arm[arm["id"]],
            "baselinePath": baseline_real_path,
            "baselineSha256": baseline_sha256,
            "baselineRecordedAt": baseline_recorded_at,
            "workloadSha256": info["report"]["workloadSha256"],
            "judgeSha256": info["report"]["judgeSha256"],
            "judgeExitCode": info["exitCode"],
            "criteria": info["report"]["criteria"],
        })

    record = {
        "schemaVersion": 2,
        "cycle": cycle_name,
        "experiment": experiment,
        "recordedAt": datetime.datetime.now().astimezone().isoformat(),
        "subject": decl["subject"],
        # require_subject が非空を保証済み。get() で null を通さない。
        "subjectVersion": decl["subjectVersion"],
        "baseCommit": base_commit,
        "measurementSha256": measurement_sha256,
        "arms": arms_out,
    }

    validate_record(record)
    with open(review_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    for arm in decl["arms"]:
        info = reports[arm["id"]]
        parts = " ".join("%d=%s" % (c["criterion"], c["result"]) for c in info["report"]["criteria"])
        print("%s: %s (judge exit %d)" % (arm["id"], parts, info["exitCode"]))
    judge_identical = len({info["report"]["judgeSha256"] for info in reports.values()}) == 1
    print("judgeSha256 identical across arms: %s" % judge_identical)
    print("recorded: %s" % review_path)


def transcripts_report(cycle_name):
    """アームごとに発見した transcript と注入以降の commit を出し、照合A′・B′
    の結果を書く。書き込みはしない。"""
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    require_subject(cycle_name, decl, require_version=False)
    materialized, mat_error = load_materialized(cycle_name)
    print("cycle: %s" % cycle_name)
    if mat_error:
        print(
            "materialized.json is missing; commit range is derived from the root commit "
            "(first commit after root is treated as injection)"
        )
    for arm in decl["arms"]:
        facts = transcript_facts(cycle_name, arm, decl)
        if materialized:
            injection = injection_commit_of(materialized, arm["id"])
            commits = load_commits_since(cycle_name, arm, injection) if injection else []
            since_label = "injection %s" % injection if injection else "(no injectionCommit)"
        else:
            commits, root, since = commits_since_root_fallback(cycle_name, arm)
            since_label = "first commit after root %s (= %s)" % (root, since)
        mismatches = collect_execution_mismatches(arm, facts, commits)
        participating = belonging_participating_sessions(arm, facts)
        print("")
        print("%s" % arm["id"])
        print("  discovered: %d  participating: %d" % (len(facts), len(participating)))
        if facts:
            for fact in facts:
                print("    %s" % format_transcript_fact(fact))
        else:
            print("    (none)")
        print("  commits since %s:" % since_label)
        if commits:
            for sha, author_time in commits:
                print("    %s %s" % (sha, author_time))
        else:
            print("    (none)")
        a_fail = any(
            "unclassifiable" in item
            or "does not belong" in item
            or "project slug" in item
            or "belonging participating session count 0" in item
            for item in mismatches
        )
        b_fail = any(
            "outside belonging participating" in item or "has no timestamp" in item
            for item in mismatches
        )
        check_a = "FAIL" if a_fail else "pass"
        if a_fail and not participating:
            check_b = "skipped"
        elif b_fail:
            check_b = "FAIL"
        else:
            check_b = "pass"
        print("  check A' (execution unit belonging/participation): %s" % check_a)
        print("  check B' (commits inside belonging participating span union): %s" % check_b)
        if mismatches:
            print("  mismatches:")
            for item in mismatches:
                print("    %s" % item)


####################################################################
# 推定機構（freeze / estimate / calibrate）
####################################################################


def canonical_bytes(obj):
    """hash の入力となる正規化バイト列。キー順を固定し、整形（indent 等）に
    依存しない。ファイルバイト列や整形済み JSON テキストから hash を計算すると
    整形が変わるたびに hash が動くので、必ずこの関数経由で python オブジェクト
    から計算する。"""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def content_hash(obj):
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


_IDENTITY_LEAK_WIN_PATH_RE = re.compile(r"[A-Za-z]:[\\/]")
_IDENTITY_LEAK_WSL_UNC_RE = re.compile(r"\\wsl\$", re.IGNORECASE)
_IDENTITY_LEAK_WSL_MOUNT_RE = re.compile(r"/mnt/[A-Za-z](?:/|$)", re.IGNORECASE)


def _walk_strings(obj):
    """dict/list を再帰的に辿り、キーと値の両方の文字列を yield する。"""
    if isinstance(obj, dict):
        for key, value in obj.items():
            if isinstance(key, str):
                yield key
            yield from _walk_strings(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _walk_strings(value)
    elif isinstance(obj, str):
        yield obj


def _reject_identity_leak(obj, label):
    """次のいずれかを検出したら拒否する（dict のキーも値と同様に辿り、
    比較はすべて大文字小文字を無視する。`wrapper/lib/ReleaseReview.ps1` の
    Get-FoundationIdentityLeakNeedles が [StringComparer]::OrdinalIgnoreCase を
    使うのに倣う）:

    - Windows 絶対パス（ドライブレター + `:` + `\\` または `/`）
    - `\\wsl$` UNC パス
    - `/mnt/<drive>/...`（WSL 経由での Windows パス参照）
    - 実行環境の実 USERNAME（os.environ['USERNAME']）を大文字小文字無視で含む文字列

    Get-FoundationIdentityLeakNeedles とは needle 集合が完全一致しない
    （wslUser/wslHome/releasesRoot/localDataRoot を environment.json から読んで
    needle 化することは、スコープが広がるためここでは行っていない）。
    `/home/ubuntu/...` のような WSL 側の絶対パスは上記のいずれにも一致しないので
    検出しない（凍結入力の member.source として意図的に許容している）。"""
    username = os.environ.get("USERNAME")
    username_lower = username.lower() if username else None
    for value in _walk_strings(obj):
        if _IDENTITY_LEAK_WIN_PATH_RE.search(value):
            raise SystemExit("identity leak in %s: %s" % (label, value))
        if _IDENTITY_LEAK_WSL_UNC_RE.search(value):
            raise SystemExit("identity leak in %s: %s" % (label, value))
        if _IDENTITY_LEAK_WSL_MOUNT_RE.search(value):
            raise SystemExit("identity leak in %s: %s" % (label, value))
        if username_lower and username_lower in value.lower():
            raise SystemExit("identity leak in %s: %s" % (label, value))


def _reject_forbidden_keys(obj, label, _path=""):
    """FORBIDDEN_RECORD_KEYS のいずれかが（何階層ネストしていても）dict の
    キーに出現したら拒否する。"""
    if isinstance(obj, dict):
        for key, value in obj.items():
            here = "%s/%s" % (_path, key) if _path else key
            if key in FORBIDDEN_RECORD_KEYS:
                raise SystemExit("forbidden key in %s: %s" % (label, here))
            _reject_forbidden_keys(value, label, here)
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            here = "%s[%d]" % (_path, index)
            _reject_forbidden_keys(value, label, here)


_MEMBER_ID_ORDER = {
    "declaration": 0,
    "workload": 1,
    "measurement": 2,
    "variant-injection": 3,
    "arm-run": 4,
}

_ARTIFACT_FILENAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def member_sort_key(member_id):
    """members[] の固定順（declaration / workload / measurement /
    variant-injection / arm-run / transcript-01, transcript-02...）。この順で
    ソートしてから hash するので、束ねる順序が変わっても同じ manifest からは
    同じ hash になる。"""
    if member_id in _MEMBER_ID_ORDER:
        return (_MEMBER_ID_ORDER[member_id], member_id)
    if member_id.startswith("transcript-"):
        return (5, member_id)
    return (6, member_id)


def _member_filename(member_id):
    if member_id == "declaration":
        return "declaration.json"
    if member_id == "workload":
        return "workload.md"
    if member_id == "measurement":
        return "measurement.md"
    if member_id == "variant-injection":
        return "variant-injection.patch"
    if member_id == "arm-run":
        return "arm-run.patch"
    if member_id.startswith("transcript-"):
        return "%s.jsonl" % member_id
    raise SystemExit("unknown frozen-input member id: %r" % member_id)


def estimator_identity(components):
    """推定器の identity。id と note は含めない（推定器の中身ではなく、内容
    から決まる識別子だけを装置へ焼き込む。憲法 不変条件2と同型）。"""
    return content_hash(components)


def derive_ground_truth(record):
    """計測済みサイクル記録から正解データを導出する（純関数）。criterion 1 は
    比較から除外する（marker はアームごとに text が違う設計のため）。criterion
    2 以降のいずれかで control と treatment の result が unknown を含んでいたら
    導出不能として SystemExit する（呼び出し元はそのまま拒否として扱う）。"""
    control = None
    treatments = []
    for arm in record["arms"]:
        if arm["role"] == "control":
            control = arm
        elif arm["role"] == "treatment":
            treatments.append(arm)
    if control is None:
        raise SystemExit(
            "calibration source cycle %s has no control arm" % record.get("cycle")
        )
    if not treatments:
        raise SystemExit(
            "calibration source cycle %s has no treatment arm" % record.get("cycle")
        )

    control_by_n = {
        item["criterion"]: item for item in control["criteria"] if item["criterion"] != 1
    }
    numbers = sorted(control_by_n)
    differing = set()
    for treatment in treatments:
        treatment_by_n = {
            item["criterion"]: item for item in treatment["criteria"] if item["criterion"] != 1
        }
        for number in numbers:
            control_result = control_by_n[number]["result"]
            treatment_item = treatment_by_n.get(number)
            treatment_result = treatment_item["result"] if treatment_item else None
            if control_result == "unknown" or treatment_result in (None, "unknown"):
                raise SystemExit(
                    "criterion %d is unknown; ground truth is not derivable" % number
                )
            if control_result != treatment_result:
                differing.add(number)

    differing_list = sorted(differing)
    attributable = "attributable" if differing_list else "not-attributable"
    if differing_list:
        derivation = "criteria>=2 differ across control and treatment: %s" % differing_list
    else:
        derivation = "criteria>=2 identical across control and treatment"
    return {
        "attributable": attributable,
        "comparedCriteria": numbers,
        "differingCriteria": differing_list,
        "derivation": derivation,
    }


def agreement_of(estimate, ground_truth):
    """推定と正解データの一致判定（純関数）。"""
    est_value = estimate["attributable"]
    truth_value = ground_truth["attributable"]
    if est_value == truth_value:
        return "match"
    if est_value == "indeterminate":
        return "indeterminate"
    return "mismatch"


def estimator_path(estimator_id):
    return os.path.join(ESTIMATORS_DIR, "%s.json" % estimator_id)


def _verify_estimator_artifacts(descriptor, estimators_dir):
    """記述子の任意キー artifacts を照合する。artifacts は identity に含めない。
    TEMP 配下の記述子検査からも呼べるよう estimators_dir を引数で取る。"""
    artifacts = descriptor.get("artifacts")
    if not artifacts:
        return
    components = descriptor.get("components") or {}
    for key, filename in artifacts.items():
        if (
            not isinstance(filename, str)
            or not _ARTIFACT_FILENAME_RE.fullmatch(filename)
            or filename in (".", "..")
        ):
            raise SystemExit("invalid estimator artifact filename: %r" % filename)
        path = os.path.join(estimators_dir, filename)
        if not os.path.isfile(path):
            raise SystemExit("estimator artifact not found: %s" % path)
        actual = sha256_file(path)
        expected = components.get(key)
        if actual != expected:
            raise SystemExit(
                "estimator artifact sha256 mismatch for %s: expected %s, actual %s"
                % (key, expected, actual)
            )


def load_estimator(estimator_id):
    """private-control/estimators/<id>.json を読み、schema 検証して返す。"""
    validate_identifier("estimator id", estimator_id)
    path = estimator_path(estimator_id)
    if not os.path.isfile(path):
        raise SystemExit("estimator descriptor not found: %s" % path)
    with open(path, encoding="utf-8") as handle:
        descriptor = json.load(handle)
    validate_against_schema(descriptor, "estimator.schema.json", "estimator")
    if descriptor.get("id") != estimator_id:
        raise SystemExit(
            "estimator id %r does not match filename stem %r: %s"
            % (descriptor.get("id"), estimator_id, path)
        )
    _verify_estimator_artifacts(descriptor, ESTIMATORS_DIR)
    return descriptor


def frozen_bundle_dir(frozen_hash):
    return os.path.join(FROZEN_DIR, frozen_hash)


def load_frozen_manifest(frozen_hash):
    """凍結束を読み、manifest の再計算と全 member の payload sha256 を照合する。
    束が無い、または改変されていれば SystemExit。成功すれば manifest を返す。"""
    bundle_dir = frozen_bundle_dir(frozen_hash)
    manifest_path = os.path.join(bundle_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise SystemExit("frozen bundle not found: %s" % bundle_dir)
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if content_hash(manifest) != frozen_hash:
        raise SystemExit("frozen bundle has been modified: %s" % bundle_dir)
    for member in manifest.get("members", []):
        member_path = os.path.join(bundle_dir, *member["path"].split("/"))
        if not os.path.isfile(member_path) or sha256_file(member_path) != member["sha256"]:
            raise SystemExit("frozen bundle has been modified: %s" % bundle_dir)
    return manifest


def freeze_arm(cycle_name, arm_id):
    """凍結入力を束ね、frozen/<hash>/ へ書く（既にあり改変されていなければ
    再利用）。CLI (`freeze`) と `calibrate --prepare` の両方から呼ばれる共通
    処理。戻り値は {"hash", "bundleDir", "memberCount", "reused"}。"""
    validate_identifier("cycle", cycle_name)
    validate_identifier("arm id", arm_id)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    require_subject(cycle_name, decl, require_version=True)
    experiment = decl["experiment"]
    arm = next((a for a in decl["arms"] if a["id"] == arm_id), None)
    if arm is None:
        raise SystemExit("cycle %s declaration has no arm %r" % (cycle_name, arm_id))

    mismatches = []
    mismatches.extend(collect_provenance_mismatches(cycle_name, decl))

    materialized, _mat_error = load_materialized(cycle_name)
    facts = transcript_facts(cycle_name, arm, decl)
    injection = injection_commit_of(materialized, arm_id)
    commits = load_commits_since(cycle_name, arm, injection) if injection else []
    mismatches.extend(collect_execution_mismatches(arm, facts, commits))

    release = release_path(cycle_name)
    arm_ref = "%s/%s" % (release, shlex.quote(arm_id))
    dirty = exec_("git -C %s status --porcelain" % arm_ref)
    if dirty.strip():
        mismatches.append("mismatch: %s tree is dirty:\n%s" % (arm_id, dirty.strip()))

    if mismatches:
        raise SystemExit("\n".join(mismatches))

    workload_win = os.path.join(agent_rules_root(), "experiments", experiment, "workload.md")
    with open(workload_win, "rb") as handle:
        workload_bytes = handle.read()
    actual_workload_sha = hashlib.sha256(workload_bytes).hexdigest()
    if actual_workload_sha != decl["workloadHash"]:
        raise SystemExit(
            "mismatch: workloadHash declared %s, actual %s"
            % (decl["workloadHash"], actual_workload_sha)
        )

    measurement_win = os.path.join(
        agent_rules_root(), "experiments", experiment, "MEASUREMENT.md"
    )
    with open(measurement_win, "rb") as handle:
        measurement_bytes = handle.read()
    actual_measurement_sha = hashlib.sha256(measurement_bytes).hexdigest()
    if actual_measurement_sha != decl["measurementHash"]:
        raise SystemExit(
            "mismatch: measurementHash declared %s, actual %s"
            % (decl["measurementHash"], actual_measurement_sha)
        )

    with open(cycle_path(cycle_name), "rb") as handle:
        decl_bytes = handle.read()

    base_commit = exec_("git -C %s/base rev-parse HEAD" % release).strip()
    arm_head = exec_("git -C %s rev-parse HEAD" % arm_ref).strip()
    arm_toplevel = exec_("git -C %s rev-parse --show-toplevel" % arm_ref).strip()

    _out, _err, parent_code = exec_(
        "git -C %s rev-parse --verify --quiet %s^" % (arm_ref, injection), check=False
    )
    parent = "%s^" % injection if parent_code == 0 else EMPTY_TREE_SHA
    # base64 経由でバイト列として受け取る（transcript と同じ経路に統一）。
    # exec_() のテキストモード（text=True, encoding="utf-8"）を diff の生バイト列に
    # 直接使うと CRLF 正規化や非 UTF-8 バイトでの UnicodeDecodeError が起こりうる。
    variant_injection_b64 = exec_(
        "git -C %s diff --no-color --no-ext-diff --no-renames %s %s | base64 -w0"
        % (arm_ref, parent, injection)
    ).strip()
    variant_injection_patch = base64.b64decode(variant_injection_b64)
    arm_run_b64 = exec_(
        "git -C %s diff --no-color --no-ext-diff --no-renames %s %s | base64 -w0"
        % (arm_ref, injection, arm_head)
    ).strip()
    arm_run_patch = base64.b64decode(arm_run_b64)

    members_raw = [
        (
            "declaration", "declaration", decl_bytes,
            "apparatus/cycles/%s.json" % cycle_name,
        ),
        (
            "workload", "workload", workload_bytes,
            "agent-rules/experiments/%s/workload.md" % experiment,
        ),
        (
            "measurement", "measurement", measurement_bytes,
            "agent-rules/experiments/%s/MEASUREMENT.md" % experiment,
        ),
        (
            "variant-injection", "artifact-diff", variant_injection_patch,
            "git diff %s..%s in %s" % (parent, injection, arm_toplevel),
        ),
        (
            "arm-run", "artifact-diff", arm_run_patch,
            "git diff %s..%s in %s" % (injection, arm_head, arm_toplevel),
        ),
    ]

    sessions = session_entries_for_record(arm, facts)
    participating = belonging_participating_sessions(arm, facts)
    for index, session in enumerate(sorted(participating, key=lambda s: s["path"]), start=1):
        path = session["path"]
        b64 = exec_("base64 -w0 %s" % shlex.quote(path)).strip()
        content = base64.b64decode(b64)
        members_raw.append(("transcript-%02d" % index, "transcript", content, path))

    members = []
    payload_bytes_by_path = {}
    for member_id, kind, content, source in members_raw:
        for substring in FROZEN_FORBIDDEN_SOURCE_SUBSTRINGS:
            if substring in source:
                raise SystemExit(
                    "forbidden source substring %r in member %s: %s"
                    % (substring, member_id, source)
                )
        payload_rel = "payload/%s" % _member_filename(member_id)
        members.append({
            "id": member_id,
            "kind": kind,
            "path": payload_rel,
            "source": source,
            "sha256": hashlib.sha256(content).hexdigest(),
            "bytes": len(content),
        })
        payload_bytes_by_path[payload_rel] = content

    members.sort(key=lambda m: member_sort_key(m["id"]))

    manifest = {
        "schemaVersion": 1,
        "kind": "frozen-input",
        "cycle": cycle_name,
        "experiment": experiment,
        "arm": arm_id,
        "armRole": arm["role"],
        "variant": arm["variant"],
        "variantTree": arm["variantTree"],
        "subject": decl["subject"],
        "subjectVersion": decl["subjectVersion"],
        "declarationSha256": hashlib.sha256(decl_bytes).hexdigest(),
        "workloadSha256": actual_workload_sha,
        "measurementSha256": actual_measurement_sha,
        "commitRange": {
            "base": base_commit,
            "injection": injection,
            "head": arm_head,
            "commits": [
                {"commit": sha, "authorTime": author_time} for sha, author_time in commits
            ],
        },
        "sessions": sessions,
        "members": members,
    }

    _reject_identity_leak(manifest, "frozen manifest")
    validate_against_schema(manifest, "frozen-input.schema.json", "frozen manifest")

    frozen_hash = content_hash(manifest)
    bundle_dir = frozen_bundle_dir(frozen_hash)
    manifest_path = os.path.join(bundle_dir, "manifest.json")

    if os.path.isdir(bundle_dir) and os.path.isfile(manifest_path):
        with open(manifest_path, encoding="utf-8") as handle:
            existing_manifest = json.load(handle)
        if content_hash(existing_manifest) != frozen_hash:
            raise SystemExit("frozen bundle has been modified: %s" % bundle_dir)
        broken = []
        for member in existing_manifest.get("members", []):
            member_path = os.path.join(bundle_dir, *member["path"].split("/"))
            if not os.path.isfile(member_path) or sha256_file(member_path) != member["sha256"]:
                broken.append(member["id"])
        if broken:
            raise SystemExit("frozen bundle has been modified: %s" % bundle_dir)
        return {
            "hash": frozen_hash,
            "bundleDir": bundle_dir,
            "memberCount": len(existing_manifest.get("members", [])),
            "reused": True,
        }

    os.makedirs(os.path.join(bundle_dir, "payload"), exist_ok=True)
    written_paths = []
    for payload_rel, content in payload_bytes_by_path.items():
        payload_path = os.path.join(bundle_dir, *payload_rel.split("/"))
        with open(payload_path, "wb") as handle:
            handle.write(content)
        written_paths.append(payload_path)

    with open(manifest_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    written_paths.append(manifest_path)

    meta = {
        "frozenHash": frozen_hash,
        "frozenAt": datetime.datetime.now().astimezone().isoformat(),
        "cycle": cycle_name,
        "arm": arm_id,
    }
    meta_path = os.path.join(bundle_dir, "frozen.meta.json")
    with open(meta_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(meta, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    written_paths.append(meta_path)

    for path in written_paths:
        os.chmod(path, stat.S_IREAD)

    return {
        "hash": frozen_hash,
        "bundleDir": bundle_dir,
        "memberCount": len(manifest["members"]),
        "reused": False,
    }


def freeze(cycle_name, arm_id):
    result = freeze_arm(cycle_name, arm_id)
    print("frozen-input: %s" % result["hash"])
    print("bundle: %s" % result["bundleDir"])
    print("members: %d" % result["memberCount"])
    print("reused: %s" % ("yes" if result["reused"] else "no"))


def estimations_path(cycle_name):
    return os.path.join(ESTIMATIONS_DIR, "%s.json" % cycle_name)


def calibrations_path(estimator_id):
    return os.path.join(CALIBRATIONS_DIR, "%s.json" % estimator_id)


def load_calibration_record(estimator_id):
    path = calibrations_path(estimator_id)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def calibration_count_for_identity(estimator_id, identity):
    """未較正ゲート（estimate の拒否条件4）に使う件数。読み取り経路にも
    validate_calibration_record() を掛ける（schema・calibrationHash・identity
    再計算の3層が read 側でも効くようにする）。"""
    record = load_calibration_record(estimator_id)
    if record is None:
        return 0
    validate_calibration_record(record)
    return sum(
        1 for entry in record.get("calibrations", [])
        if entry.get("estimator", {}).get("identity") == identity
    )


def validate_estimation_record(record):
    """スキーマで書けないアーム間・フィールド間の条件をコードで検証する。
    失敗は SystemExit、成功は None。"""
    validate_against_schema(record, "estimation-record.schema.json", "estimation record")
    _reject_forbidden_keys(record, "estimation record")
    _reject_identity_leak(record, "estimation record")

    seen = set()
    for entry in record.get("estimations", []):
        frozen = entry["frozenInput"]
        manifest = frozen["manifest"]
        if content_hash(manifest) != frozen["hash"]:
            raise SystemExit(
                "estimation record: frozenInput.manifest content_hash does not match frozenInput.hash"
            )
        if manifest.get("cycle") != record.get("cycle"):
            raise SystemExit(
                "estimation record: manifest.cycle %r does not match record.cycle %r"
                % (manifest.get("cycle"), record.get("cycle"))
            )
        if manifest.get("arm") != frozen.get("arm"):
            raise SystemExit(
                "estimation record: manifest.arm %r does not match frozenInput.arm %r"
                % (manifest.get("arm"), frozen.get("arm"))
            )
        estimator = entry["estimator"]
        if estimator["identity"] != estimator_identity(estimator["components"]):
            raise SystemExit(
                "estimation record: estimator identity does not match content_hash(components)"
            )
        member_ids = {member["id"] for member in manifest.get("members", [])}
        for basis in entry.get("estimate", {}).get("basis", []):
            if basis.get("memberId") not in member_ids:
                raise SystemExit(
                    "estimation record: basis memberId %r not found in manifest members"
                    % basis.get("memberId")
                )
        key = (frozen["hash"], estimator["identity"])
        if key in seen:
            raise SystemExit(
                "estimation record: duplicate (frozenInput.hash, estimator.identity): %s" % (key,)
            )
        seen.add(key)
    return None


def validate_calibration_record(record):
    """スキーマで書けないアーム間・フィールド間の条件をコードで検証する。
    失敗は SystemExit、成功は None。"""
    validate_against_schema(record, "calibration-record.schema.json", "calibration record")
    _reject_forbidden_keys(record, "calibration record")
    _reject_identity_leak(record, "calibration record")

    seen = set()
    for entry in record.get("calibrations", []):
        manifest = entry["frozenInput"]["manifest"]
        if content_hash(manifest) != entry["frozenInput"]["hash"]:
            raise SystemExit(
                "calibration record: frozenInput.manifest content_hash does not match frozenInput.hash"
            )
        if manifest.get("cycle") != entry["source"].get("cycle"):
            raise SystemExit(
                "calibration record: manifest.cycle %r does not match source.cycle %r"
                % (manifest.get("cycle"), entry["source"].get("cycle"))
            )
        if manifest.get("arm") != entry["source"].get("arm"):
            raise SystemExit(
                "calibration record: manifest.arm %r does not match source.arm %r"
                % (manifest.get("arm"), entry["source"].get("arm"))
            )
        estimator = entry["estimator"]
        if estimator["identity"] != estimator_identity(estimator["components"]):
            raise SystemExit(
                "calibration record: estimator identity does not match content_hash(components)"
            )
        member_ids = {member["id"] for member in manifest.get("members", [])}
        for basis in entry.get("estimate", {}).get("basis", []):
            if basis.get("memberId") not in member_ids:
                raise SystemExit(
                    "calibration record: basis memberId %r not found in manifest members"
                    % basis.get("memberId")
                )
        expected_hash = content_hash({
            key: value for key, value in entry.items()
            if key not in ("calibratedAt", "calibrationHash")
        })
        if entry["calibrationHash"] != expected_hash:
            raise SystemExit(
                "calibration record: calibrationHash does not match "
                "content_hash(entry minus calibratedAt/calibrationHash)"
            )
        key = (entry["frozenInput"]["hash"], estimator["identity"])
        if key in seen:
            raise SystemExit(
                "calibration record: duplicate (frozenInputHash, estimator.identity): %s" % (key,)
            )
        seen.add(key)
    return None


def estimate(frozen_hash, estimator_id, input_path, replace=False, allow_measured=False):
    """凍結入力へ較正済みの推定器の出力を当て、triage 専用の推定記録として
    残す。拒否の判定順は固定する。"""
    if not re.fullmatch(r"[0-9a-f]{64}", frozen_hash or ""):
        raise SystemExit("invalid --frozen (must be a 64-char lowercase hex sha256): %r" % frozen_hash)
    descriptor = load_estimator(estimator_id)  # 1: 記述子が無い, 2: schema違反
    manifest = load_frozen_manifest(frozen_hash)  # 3: 凍結束が無い/改変
    if not any(member.get("id") == "measurement" for member in manifest.get("members", [])):
        raise SystemExit(  # 3b: 計測仕様メンバーが無い旧構成の束
            "frozen input %s has no measurement member; re-freeze before estimate"
            % frozen_hash
        )
    identity = estimator_identity(descriptor["components"])

    if calibration_count_for_identity(estimator_id, identity) < 1:  # 4: 未較正
        raise SystemExit(
            "estimator %s identity %s has no calibration; run calibrate first"
            % (estimator_id, identity)
        )
    calibration_for_gate = load_calibration_record(estimator_id) or {"calibrations": []}
    if any(
        entry.get("estimator", {}).get("identity") == identity
        and entry.get("agreement") == "mismatch"
        for entry in calibration_for_gate.get("calibrations", [])
    ):
        raise SystemExit(  # 4: 当該 identity の較正に mismatch がある
            "estimator %s identity %s has mismatch calibration; recalibrate"
            % (estimator_id, identity)
        )

    with open(input_path, encoding="utf-8") as handle:
        payload = json.load(handle)

    input_identity = (payload.get("estimator") or {}).get("identity")  # 5
    if not input_identity:
        raise SystemExit("estimator input has no identity")
    if input_identity != identity:
        raise SystemExit(
            "estimator identity mismatch: input %s, computed %s" % (input_identity, identity)
        )

    input_frozen_hash = (payload.get("frozenInput") or {}).get("hash")  # 6
    if input_frozen_hash != frozen_hash:
        raise SystemExit(
            "frozen input hash mismatch: input %s, --frozen %s" % (input_frozen_hash, frozen_hash)
        )

    cycle_name = manifest["cycle"]
    review_path = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)  # 7
    if os.path.exists(review_path) and not allow_measured:
        raise SystemExit(
            "cycle %s already has a measurement record; pass --allow-measured" % cycle_name
        )

    estimate_obj = payload.get("estimate")
    if not isinstance(estimate_obj, dict):
        raise SystemExit("estimator input is missing 'estimate'")

    calibration_record = load_calibration_record(estimator_id)
    if calibration_record is not None:
        validate_calibration_record(calibration_record)
    calibration_record = calibration_record or {"calibrations": []}
    calibration_refs = [
        {
            "cycle": entry["source"]["cycle"],
            "arm": entry["source"]["arm"],
            "frozenInputHash": entry["frozenInput"]["hash"],
            "calibrationHash": entry["calibrationHash"],
            "agreement": entry["agreement"],
        }
        for entry in calibration_record.get("calibrations", [])
        if entry.get("estimator", {}).get("identity") == identity
    ]

    new_entry = {
        "estimatedAt": datetime.datetime.now().astimezone().isoformat(),
        "use": "triage",
        "estimator": {
            "id": estimator_id,
            "identity": identity,
            "components": descriptor["components"],
        },
        "frozenInput": {
            "hash": frozen_hash,
            "arm": manifest["arm"],
            "manifest": manifest,
        },
        "calibrations": calibration_refs,
        "estimate": estimate_obj,
    }

    _reject_forbidden_keys(new_entry, "estimation record")  # 8
    _reject_identity_leak(new_entry, "estimation record")  # 8

    record_path = estimations_path(cycle_name)
    existing_record = None
    if os.path.isfile(record_path):
        with open(record_path, encoding="utf-8") as handle:
            existing_record = json.load(handle)

    duplicate_exists = any(
        entry.get("frozenInput", {}).get("hash") == frozen_hash
        and entry.get("estimator", {}).get("identity") == identity
        for entry in (existing_record or {}).get("estimations", [])
    )
    if duplicate_exists and not replace:  # 9
        raise SystemExit(
            "estimation already exists for frozen input %s and estimator identity %s; "
            "pass --replace" % (frozen_hash, identity)
        )

    if existing_record is None:
        existing_record = {
            "schemaVersion": 1,
            "kind": "estimation-record",
            "cycle": cycle_name,
            "experiment": manifest["experiment"],
            "estimations": [],
        }

    estimations = [
        entry for entry in existing_record["estimations"]
        if not (
            entry.get("frozenInput", {}).get("hash") == frozen_hash
            and entry.get("estimator", {}).get("identity") == identity
        )
    ]
    estimations.append(new_entry)
    existing_record["estimations"] = estimations

    validate_estimation_record(existing_record)

    os.makedirs(ESTIMATIONS_DIR, exist_ok=True)
    with open(record_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(existing_record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print("estimation recorded: %s" % record_path)
    print("estimator: %s identity=%s" % (estimator_id, identity))
    print("frozenInput: %s" % frozen_hash)
    print("attributable: %s" % estimate_obj.get("attributable"))


def calibrate_prepare(cycle_name, arm_id, estimator_id):
    """`calibrate --prepare`。指定アームだけを凍結し、正解データが導出可能か
    だけを確認する。計測結果（attributable の値等）は一切出力しない。

    record の読み込み・validate_record() が投げる SystemExit はそのまま伝播させる
    （握り潰さない）。「control アームが無い」は、record が schema 上有効に読めた
    上で control ロールのアームが本当に無い場合だけの、独立した条件にする。"""
    validate_identifier("cycle", cycle_name)
    validate_identifier("arm id", arm_id)
    load_estimator(estimator_id)  # 記述子の存在・schema だけを確認する（内容は使わない）

    review_path = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if not os.path.isfile(review_path):
        raise SystemExit("no measurement record for cycle %s" % cycle_name)

    with open(review_path, encoding="utf-8") as handle:
        record = json.load(handle)
    validate_record(record)  # 無効なら SystemExit がそのまま伝播する
    if not any(arm.get("role") == "control" for arm in record.get("arms", [])):
        raise SystemExit("calibration source cycle %s has no control arm" % cycle_name)

    derive_ground_truth(record)  # unknown/treatment 不在などは SystemExit で拒否する

    result = freeze_arm(cycle_name, arm_id)
    print("frozen-input: %s" % result["hash"])
    print("ground truth derivable: yes")


def calibrate_input(cycle_name, arm_id, estimator_id, input_path, replace=False):
    """`calibrate --input`。片アームの盲検推定出力と計測済みサイクルの正解
    データを突き合わせ、較正記録へ追記する。"""
    validate_identifier("cycle", cycle_name)
    validate_identifier("arm id", arm_id)
    descriptor = load_estimator(estimator_id)  # 1, 2
    identity = estimator_identity(descriptor["components"])

    with open(input_path, encoding="utf-8") as handle:
        payload = json.load(handle)

    input_identity = (payload.get("estimator") or {}).get("identity")  # 5
    if not input_identity:
        raise SystemExit("estimator input has no identity")
    if input_identity != identity:
        raise SystemExit(
            "estimator identity mismatch: input %s, computed %s" % (input_identity, identity)
        )

    input_frozen_hash = (payload.get("frozenInput") or {}).get("hash")
    if not input_frozen_hash:
        raise SystemExit("estimator input has no frozen input hash")

    manifest = load_frozen_manifest(input_frozen_hash)  # 3

    recomputed = freeze_arm(cycle_name, arm_id)
    if recomputed["hash"] != input_frozen_hash:  # 新規: --cycle/--arm との突き合わせ
        raise SystemExit(
            "frozen input for calibration does not match --cycle/--arm: "
            "input %s, recomputed %s" % (input_frozen_hash, recomputed["hash"])
        )

    estimate_obj = payload.get("estimate")
    if not isinstance(estimate_obj, dict):
        raise SystemExit("estimator input is missing 'estimate'")

    review_path = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if not os.path.isfile(review_path):
        raise SystemExit("no measurement record for cycle %s" % cycle_name)
    with open(review_path, encoding="utf-8") as handle:
        record = json.load(handle)
    validate_record(record)
    ground_truth = derive_ground_truth(record)
    agreement = agreement_of(estimate_obj, ground_truth)
    record_sha256 = sha256_file(review_path)

    entry_wo_meta = {
        "estimator": {
            "id": estimator_id,
            "identity": identity,
            "components": descriptor["components"],
        },
        "source": {
            "cycle": cycle_name,
            "arm": arm_id,
            "recordPath": "reviews/%s.json" % cycle_name,
            "recordSha256": record_sha256,
        },
        "frozenInput": {"hash": input_frozen_hash, "manifest": manifest},
        "estimate": estimate_obj,
        "groundTruth": ground_truth,
        "agreement": agreement,
    }

    _reject_forbidden_keys(entry_wo_meta, "calibration record")
    _reject_identity_leak(entry_wo_meta, "calibration record")

    calibration_hash = content_hash(entry_wo_meta)

    calib_record = load_calibration_record(estimator_id)
    duplicate_exists = False
    if calib_record:
        for entry in calib_record.get("calibrations", []):
            if (
                entry.get("frozenInput", {}).get("hash") == input_frozen_hash
                and entry.get("estimator", {}).get("identity") == identity
            ):
                duplicate_exists = True
                break
    if duplicate_exists and not replace:
        raise SystemExit(
            "calibration already exists for frozen input %s and estimator identity %s; "
            "pass --replace" % (input_frozen_hash, identity)
        )

    new_entry = dict(entry_wo_meta)
    new_entry["calibratedAt"] = datetime.datetime.now().astimezone().isoformat()
    new_entry["calibrationHash"] = calibration_hash

    if calib_record is None:
        calib_record = {
            "schemaVersion": 1,
            "kind": "calibration-record",
            "estimator": {"id": estimator_id},
            "calibrations": [],
        }

    calibrations = [
        entry for entry in calib_record["calibrations"]
        if not (
            entry.get("frozenInput", {}).get("hash") == input_frozen_hash
            and entry.get("estimator", {}).get("identity") == identity
        )
    ]
    calibrations.append(new_entry)
    calib_record["calibrations"] = calibrations

    validate_calibration_record(calib_record)

    os.makedirs(CALIBRATIONS_DIR, exist_ok=True)
    path = calibrations_path(estimator_id)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(calib_record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print("calibration recorded: %s" % path)
    print("agreement: %s" % agreement)


def calibrate(cycle_name, arm_id, estimator_id, prepare=False, input_path=None, replace=False):
    if prepare:
        calibrate_prepare(cycle_name, arm_id, estimator_id)
    else:
        calibrate_input(cycle_name, arm_id, estimator_id, input_path, replace=replace)


def selfcheck(check_active_environment=False):
    """照合関数を実資産に触れずに検査する。環境記述子の実ファイルは読まない。"""
    global FROZEN_DIR, ESTIMATORS_DIR, CALIBRATIONS_DIR, CONTROL_DIR
    # The descriptor parent, rather than this repository's sibling layout, is
    # the control root.  Exercise both supported agentRulesRoot forms in
    # unrelated temporary locations without invoking a subject or WSL.
    old_environment_path = ENVIRONMENT_PATH
    if check_active_environment:
        load_environment()
        assert CONTROL_DIR == os.path.dirname(ENVIRONMENT_PATH)
        assert agent_rules_root()
    try:
        with tempfile.TemporaryDirectory(prefix="cycle-selfcheck-environment-") as env_root:
            control_dir = os.path.join(env_root, "private-control")
            relative_rules = os.path.join(env_root, "unrelated-rules")
            absolute_rules = os.path.join(env_root, "another-rules")
            os.makedirs(control_dir)
            os.makedirs(relative_rules)
            os.makedirs(absolute_rules)
            descriptor_path = os.path.join(control_dir, "environment.json")

            with open(descriptor_path, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(
                    {"host": "windows", "agentRulesRoot": "../unrelated-rules"},
                    handle,
                )
            configure_environment(descriptor_path)
            assert CONTROL_DIR == control_dir
            assert agent_rules_root() == relative_rules
            assert FROZEN_DIR == os.path.join(control_dir, "frozen")

            with open(descriptor_path, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(
                    {"host": "windows", "agentRulesRoot": absolute_rules},
                    handle,
                )
            configure_environment(descriptor_path)
            assert agent_rules_root() == absolute_rules
    finally:
        configure_environment(old_environment_path)

    arm = {"id": "arm-control", "variant": "control"}
    arm_path = "/home/ubuntu/releases/cyc/arm-control"
    good = (
        "/home/ubuntu/releases/cyc/cfg-control/projects/"
        "-home-ubuntu-releases-cyc-arm-control/a.jsonl"
    )
    other = (
        "/home/ubuntu/releases/cyc/cfg-control/projects/"
        "-home-ubuntu-releases-cyc-arm-treatment/b.jsonl"
    )
    codex_path = (
        "/home/ubuntu/releases/cyc/cfg-control/sessions/"
        "2026/08/18/rollout-a.jsonl"
    )

    def fact(path, first, last, count, binding="project-slug", cwd=None, tool="claude-code"):
        item = {
            "tool": tool,
            "path": path,
            "firstTimestamp": first,
            "lastTimestamp": last,
            "assistantCount": count,
            "armBinding": binding,
            "armPath": arm_path,
        }
        if binding == "session-meta-cwd":
            item["cwd"] = cwd
        return item

    span_first = "2026-08-18T09:15:12.901Z"
    span_last = "2026-08-18T09:20:04.233Z"
    inside = "2026-08-18T18:16:46+09:00"
    outside = "2026-08-18T09:00:00+09:00"

    multi = collect_execution_mismatches(
        arm,
        [
            fact(good, span_first, span_last, 1, "project-slug"),
            fact(codex_path, span_first, span_last, 1, "session-meta-cwd", cwd=arm_path, tool="codex"),
        ],
        [],
    )
    assert multi == [], multi

    unclassifiable = collect_execution_mismatches(
        arm,
        [
            fact(good, span_first, span_last, 1, "project-slug"),
            fact(codex_path, span_first, span_last, 1, "session-meta-cwd", cwd=None, tool="codex"),
        ],
        [],
    )
    assert any("unclassifiable" in item for item in unclassifiable), unclassifiable

    zero = collect_execution_mismatches(
        arm, [fact(good, span_first, span_last, 0)], []
    )
    assert any("belonging participating session count 0" in item for item in zero), zero

    ok = collect_execution_mismatches(
        arm, [fact(good, span_first, span_last, 1)], [("d3afb44", inside)]
    )
    assert ok == [], ok

    spilled = collect_execution_mismatches(
        arm, [fact(good, span_first, span_last, 1)], [("deadbeef", outside)]
    )
    assert any("outside belonging participating" in item for item in spilled), spilled

    on_first = collect_execution_mismatches(
        arm, [fact(good, span_first, span_last, 1)], [("bound1", span_first)]
    )
    assert on_first == [], on_first

    on_last = collect_execution_mismatches(
        arm, [fact(good, span_first, span_last, 1)], [("bound2", span_last)]
    )
    assert on_last == [], on_last

    no_ts = collect_execution_mismatches(
        arm, [fact(good, None, None, 1)], [("d3afb44", inside)]
    )
    assert any("has no timestamp" in item for item in no_ts), no_ts

    mixed = collect_execution_mismatches(
        arm, [fact(other, span_first, span_last, 1)], []
    )
    assert any("project slug" in item for item in mixed), mixed

    for name in sorted(os.listdir(SUBJECTS_DIR)):
        if not name.endswith(".json"):
            continue
        sid = name[:-5]
        subject = load_subject(sid)
        assert subject["id"] == sid

    default_base = _transcript_search_base("cyc", arm)
    assert "cfg-control" in default_base, default_base
    assert ".cursor" not in default_base, default_base
    cursor_base = _transcript_search_base("cyc", arm, "home-cursor")
    assert cursor_base == '"$HOME"/.cursor', cursor_base
    assert "cfg-" not in cursor_base, cursor_base

    slug_arm_path = "/home/ubuntu/releases/cyc/arm-control"
    assert project_slug(slug_arm_path) == "-home-ubuntu-releases-cyc-arm-control"
    assert cursor_project_slug(slug_arm_path) == "home-ubuntu-releases-cyc-arm-control"
    assert cursor_project_slug(slug_arm_path) != project_slug(slug_arm_path)
    cursor_fact = fact(
        "/home/ubuntu/.cursor/projects/home-ubuntu-releases-cyc-arm-control/"
        "agent-transcripts/2026/rollout.jsonl",
        span_first, span_last, 1, "cursor-project-slug",
    )
    assert classify_session(arm, cursor_fact) == ("belongs", None)
    cursor_fact["path"] = cursor_fact["path"].replace("arm-control", "other")
    assert classify_session(arm, cursor_fact)[0] == "does-not-belong"

    codex_participation = {
        "all": [
            {"jsonlField": "type", "equals": "response_item"},
            {"jsonlField": "payload.role", "equals": "assistant"},
        ]
    }
    codex_lines = [
        {"type": "response_item", "payload": {"role": "assistant"}, "timestamp": "2026-08-18T00:00:00Z"},
        {"type": "response_item", "payload": {"role": "user"}, "timestamp": "2026-08-18T00:00:01Z"},
        {"type": "session_meta", "payload": {"role": "assistant"}, "timestamp": "2026-08-18T00:00:02Z"},
        {"type": "response_item", "payload": {}, "timestamp": "2026-08-18T00:00:03Z"},
    ]
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".jsonl", delete=False, encoding="utf-8"
    ) as handle:
        for obj in codex_lines:
            handle.write(json.dumps(obj) + "\n")
        codex_fixture_path = handle.name
    try:
        script = build_transcript_facts_script(
            [codex_fixture_path], codex_participation, arm_binding="session-meta-cwd"
        )
        inner = script.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        proc = subprocess.run(
            [sys.executable, "-c", inner], capture_output=True, text=True,
        )
        assert proc.returncode == 0, proc.stderr
        payload = json.loads(proc.stdout)
        assert payload[0]["assistantCount"] == 1, payload
    finally:
        os.remove(codex_fixture_path)

    example_path = os.path.join(SCHEMAS_DIR, "environment.example.json")
    with open(example_path, encoding="utf-8") as handle:
        example = json.load(handle)
    validate_against_schema(example, "environment.schema.json", "environment.example")

    # ---- 推定サイクル宣言（kind / judgeHash 条件付き必須）。----
    assert cycle_kind({}) == "measurement"
    assert cycle_kind({"kind": "measurement"}) == "measurement"
    assert cycle_kind({"kind": "estimation"}) == "estimation"

    def _kind_arm(arm_id, role, variant):
        return {
            "id": arm_id,
            "role": role,
            "variant": variant,
            "variantTree": "a" * 40,
        }

    def _kind_decl(arms, kind=None, with_judge=True):
        decl = {
            "cycle": "selfcheck-kind",
            "experiment": "selfcheck-experiment",
            "subject": "claude-code",
            "workloadHash": "a" * 64,
            "measurementHash": "b" * 64,
            "sessionContractHash": "c" * 64,
            "executionUnitHash": "d" * 64,
            "arms": arms,
        }
        if kind is not None:
            decl["kind"] = kind
        if with_judge:
            decl["judgeHash"] = "e" * 64
        return decl

    def _kind_expect_exit(fn, *args, **kwargs):
        try:
            fn(*args, **kwargs)
        except SystemExit:
            return True
        return False

    one_arm = [_kind_arm("arm-only", "treatment", "v1")]
    two_arms = [
        _kind_arm("arm-control", "control", "v1"),
        _kind_arm("arm-treatment", "treatment", "v2"),
    ]
    two_treatment = [
        _kind_arm("arm-a", "treatment", "v1"),
        _kind_arm("arm-b", "treatment", "v2"),
    ]

    est_ok = _kind_decl(one_arm, kind="estimation", with_judge=False)
    validate_against_schema(est_ok, "cycle.schema.json", "selfcheck estimation")
    validate_arms("selfcheck-kind", est_ok)

    est_with_judge = _kind_decl(one_arm, kind="estimation", with_judge=True)
    validate_against_schema(est_with_judge, "cycle.schema.json", "selfcheck estimation+judge")

    assert _kind_expect_exit(
        validate_arms, "selfcheck-kind", _kind_decl(two_arms, kind="estimation")
    )
    assert _kind_expect_exit(
        validate_arms, "selfcheck-kind", _kind_decl(one_arm)
    )
    assert _kind_expect_exit(
        validate_arms, "selfcheck-kind", _kind_decl(two_treatment)
    )
    validate_arms("selfcheck-kind", _kind_decl(two_arms))
    validate_arms("selfcheck-kind", _kind_decl(two_arms, kind="measurement"))

    assert _kind_expect_exit(
        validate_against_schema,
        _kind_decl(two_arms, with_judge=False),
        "cycle.schema.json",
        "selfcheck missing judgeHash",
    )
    assert _kind_expect_exit(
        validate_against_schema,
        _kind_decl(two_arms, kind="measurement", with_judge=False),
        "cycle.schema.json",
        "selfcheck measurement missing judgeHash",
    )

    global CYCLES_DIR
    old_cycles_dir = CYCLES_DIR
    kind_cycles_dir = tempfile.mkdtemp()
    try:
        CYCLES_DIR = kind_cycles_dir
        est_path = os.path.join(kind_cycles_dir, "selfcheck-est-judge.json")
        with open(est_path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(est_ok, handle)
            handle.write("\n")
        try:
            judge("selfcheck-est-judge")
            raise AssertionError("estimation judge should exit")
        except SystemExit as exc:
            msg = str(exc)
            assert "estimation" in msg and "judge" in msg, msg
    finally:
        CYCLES_DIR = old_cycles_dir
        for name in os.listdir(kind_cycles_dir):
            os.remove(os.path.join(kind_cycles_dir, name))
        os.rmdir(kind_cycles_dir)

    present = {
        "CONSTITUTION.md": "a" * 64,
        "TERMS.md": "b" * 64,
    }
    good_hash = meta_readability_hash(present)
    assert collect_meta_readability_mismatches(
        ["CONSTITUTION.md", "TERMS.md"], good_hash, present
    ) == []
    bad_hash = collect_meta_readability_mismatches(
        ["CONSTITUTION.md", "TERMS.md"], "0" * 64, present
    )
    assert any("metaReadabilityHash" in item for item in bad_hash), bad_hash
    wrong_file = dict(present)
    wrong_file["CONSTITUTION.md"] = "c" * 64
    bad_file = collect_meta_readability_mismatches(
        ["CONSTITUTION.md", "TERMS.md"], good_hash, wrong_file
    )
    assert any("metaReadabilityHash" in item for item in bad_file), bad_file
    extra = dict(present)
    extra["docs/RULE-EXPERIMENT.md"] = "d" * 64
    bad_extra = collect_meta_readability_mismatches(
        ["CONSTITUTION.md", "TERMS.md"], good_hash, extra
    )
    assert any("undeclared readability" in item for item in bad_extra), bad_extra
    bad_missing = collect_meta_readability_mismatches(
        ["CONSTITUTION.md", "TERMS.md", "docs/EXECUTION-UNIT.md"],
        good_hash,
        present,
    )
    assert any("absent on the arm" in item for item in bad_missing), bad_missing

    assert subject_ids({"subject": "claude-code"}) == ["claude-code"]
    assert subject_ids({"subject": ["claude-code", "codex"]}) == ["claude-code", "codex"]

    # ---- 推定機構（freeze / estimate / calibrate）。実資産に触れず、
    # 合成データだけを使う。----

    def _expect_system_exit(fn, *args, **kwargs):
        try:
            fn(*args, **kwargs)
        except SystemExit:
            return True
        return False

    sample_obj = {"b": 1, "a": 2, "nested": {"y": 2, "x": 1}}
    assert content_hash(sample_obj) == content_hash({"nested": {"x": 1, "y": 2}, "a": 2, "b": 1})

    member_decl = {
        "id": "declaration", "kind": "declaration", "path": "payload/declaration.json",
        "source": "apparatus/cycles/selfcheck-cycle.json", "sha256": "a" * 64, "bytes": 1,
    }
    member_workload = {
        "id": "workload", "kind": "workload", "path": "payload/workload.md",
        "source": "agent-rules/experiments/selfcheck-experiment/workload.md",
        "sha256": "b" * 64, "bytes": 2,
    }
    member_measurement = {
        "id": "measurement", "kind": "measurement", "path": "payload/measurement.md",
        "source": "agent-rules/experiments/selfcheck-experiment/MEASUREMENT.md",
        "sha256": "c" * 64, "bytes": 3,
    }
    member_variant = {
        "id": "variant-injection", "kind": "artifact-diff",
        "path": "payload/variant-injection.patch",
        "source": "git diff parent..injection in /home/ubuntu/releases/selfcheck-cycle/arm-v1",
        "sha256": "d" * 64, "bytes": 4,
    }
    member_arm_run = {
        "id": "arm-run", "kind": "artifact-diff", "path": "payload/arm-run.patch",
        "source": "git diff injection..head in /home/ubuntu/releases/selfcheck-cycle/arm-v1",
        "sha256": "e" * 64, "bytes": 5,
    }
    member_transcript = {
        "id": "transcript-01", "kind": "transcript", "path": "payload/transcript-01.jsonl",
        "source": "/home/ubuntu/releases/selfcheck-cycle/cfg-v1/x.jsonl", "sha256": "f" * 64, "bytes": 6,
    }
    member_fallback = {
        "id": "zzz-other", "kind": "transcript", "path": "payload/zzz-other.jsonl",
        "source": "/home/ubuntu/releases/selfcheck-cycle/cfg-v1/y.jsonl", "sha256": "1" * 64, "bytes": 7,
    }
    order1 = sorted(
        [
            member_transcript, member_decl, member_arm_run, member_workload,
            member_fallback, member_measurement, member_variant,
        ],
        key=lambda m: member_sort_key(m["id"]),
    )
    order2 = sorted(
        [
            member_workload, member_transcript, member_measurement, member_decl,
            member_variant, member_fallback, member_arm_run,
        ],
        key=lambda m: member_sort_key(m["id"]),
    )
    assert order1 == order2
    assert [m["id"] for m in order1] == [
        "declaration", "workload", "measurement", "variant-injection", "arm-run",
        "transcript-01", "zzz-other",
    ]

    sample_manifest = {
        "schemaVersion": 1,
        "kind": "frozen-input",
        "cycle": "selfcheck-cycle",
        "experiment": "selfcheck-experiment",
        "arm": "arm-selfcheck",
        "armRole": "control",
        "variant": "v1",
        "variantTree": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "subject": "claude-code",
        "subjectVersion": "9.9.9 (selfcheck)",
        "declarationSha256": "a" * 64,
        "workloadSha256": "b" * 64,
        "measurementSha256": "c" * 64,
        "commitRange": {
            "base": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "injection": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "head": "cccccccccccccccccccccccccccccccccccccccc",
            "commits": [
                {"commit": "cccccccccccccccccccccccccccccccccccccccc", "authorTime": "2026-01-01T00:00:00+00:00"}
            ],
        },
        "sessions": [],
        "members": [m for m in order1 if m["id"] != "zzz-other"],
    }
    validate_against_schema(sample_manifest, "frozen-input.schema.json", "selfcheck frozen manifest")

    hash1 = content_hash(dict(sample_manifest, members=sample_manifest["members"]))
    hash2 = content_hash(dict(
        sample_manifest,
        members=sorted(
            [m for m in order2 if m["id"] != "zzz-other"],
            key=lambda m: member_sort_key(m["id"]),
        ),
    ))
    assert hash1 == hash2, "member 順序が同じ内容で hash が変わった"
    tampered_member = dict(member_decl, sha256="2" * 64)
    tampered_members = sorted(
        [
            tampered_member, member_workload, member_measurement, member_variant,
            member_arm_run, member_transcript,
        ],
        key=lambda m: member_sort_key(m["id"]),
    )
    hash3 = content_hash(dict(sample_manifest, members=tampered_members))
    assert hash3 != hash1, "member の sha256 を変えても hash が同じだった"

    assert _expect_system_exit(_reject_identity_leak, {"p": "C:\\foo\\bar"}, "selfcheck")
    assert _expect_system_exit(
        _reject_identity_leak, {"p": "\\\\wsl$\\Ubuntu\\home\\x"}, "selfcheck"
    )
    assert _expect_system_exit(
        _reject_identity_leak, {"p": "\\\\WSL$\\Ubuntu\\home\\x"}, "selfcheck"
    ), "大文字小文字を無視した \\\\wsl$ 検出が効いていない"
    assert _expect_system_exit(
        _reject_identity_leak, {"p": "/mnt/c/Users/x/work"}, "selfcheck"
    ), "/mnt/c/... 形の検出が効いていない"
    assert _expect_system_exit(
        _reject_identity_leak, {"C:\\foo\\bar": "value"}, "selfcheck"
    ), "dict のキーが検出対象になっていない"
    _reject_identity_leak({"p": "/home/ubuntu/releases/selfcheck-cycle/arm-v1"}, "selfcheck")

    assert _expect_system_exit(
        _reject_forbidden_keys, {"a": {"b": [{"c": {"verdict": "pass"}}]}}, "selfcheck"
    )
    assert _expect_system_exit(
        _reject_forbidden_keys, {"a": [1, {"promote": True}]}, "selfcheck"
    )
    _reject_forbidden_keys({"a": {"b": "c"}}, "selfcheck")

    sample_components = {"model": "selfcheck-model", "promptSha256": "e" * 64, "protocol": "blind-bundle-read-v1"}
    assert estimator_identity(sample_components) == estimator_identity(dict(sample_components))
    bad_estimator = {"schemaVersion": 1, "kind": "estimator", "id": "selfcheck-estimator", "components": {}}
    assert _expect_system_exit(
        validate_against_schema, bad_estimator, "estimator.schema.json", "selfcheck estimator"
    )

    def crit(number, result):
        return {"criterion": number, "text": "criterion %d" % number, "result": result, "evidence": "e"}

    control_arm = {"role": "control", "criteria": [crit(1, "met"), crit(2, "met"), crit(3, "met")]}
    treatment_same = {"role": "treatment", "criteria": [crit(1, "met"), crit(2, "met"), crit(3, "met")]}
    treatment_diff = {
        "role": "treatment", "criteria": [crit(1, "met"), crit(2, "not-met"), crit(3, "met")]
    }
    treatment_unknown = {
        "role": "treatment", "criteria": [crit(1, "met"), crit(2, "unknown"), crit(3, "met")]
    }

    ground_truth_same = derive_ground_truth({"cycle": "c", "arms": [control_arm, treatment_same]})
    assert ground_truth_same["attributable"] == "not-attributable", ground_truth_same
    assert ground_truth_same["differingCriteria"] == [], ground_truth_same

    ground_truth_diff = derive_ground_truth({"cycle": "c", "arms": [control_arm, treatment_diff]})
    assert ground_truth_diff["attributable"] == "attributable", ground_truth_diff
    assert ground_truth_diff["differingCriteria"] == [2], ground_truth_diff

    assert _expect_system_exit(
        derive_ground_truth, {"cycle": "c", "arms": [control_arm, treatment_unknown]}
    )

    gt = {"attributable": "not-attributable"}
    assert agreement_of({"attributable": "not-attributable"}, gt) == "match"
    assert agreement_of({"attributable": "attributable"}, gt) == "mismatch"
    assert agreement_of({"attributable": "indeterminate"}, gt) == "indeterminate"

    sample_estimation_record = {
        "schemaVersion": 1,
        "kind": "estimation-record",
        "cycle": sample_manifest["cycle"],
        "experiment": sample_manifest["experiment"],
        "estimations": [
            {
                "estimatedAt": "2026-08-19T00:00:00+09:00",
                "use": "triage",
                "estimator": {
                    "id": "selfcheck-estimator",
                    "identity": estimator_identity(sample_components),
                    "components": sample_components,
                },
                "frozenInput": {
                    "hash": content_hash(sample_manifest),
                    "arm": sample_manifest["arm"],
                    "manifest": sample_manifest,
                },
                "calibrations": [
                    {
                        "cycle": "selfcheck-calibration-cycle", "arm": "arm-selfcheck",
                        "frozenInputHash": "e" * 64, "calibrationHash": "f" * 64, "agreement": "match",
                    }
                ],
                "estimate": {
                    "attributable": "not-attributable",
                    "confidence": "medium",
                    "basis": [{"memberId": "declaration", "locator": "manifest", "note": "n"}],
                    "rejectedInterpretations": [
                        {"interpretation": "attributable", "reason": "selfcheck dummy rejection"}
                    ],
                },
            }
        ],
    }
    validate_estimation_record(sample_estimation_record)
    bad_estimation_record = json.loads(json.dumps(sample_estimation_record))
    bad_estimation_record["estimations"][0]["verdict"] = "pass"
    assert _expect_system_exit(validate_estimation_record, bad_estimation_record)

    calibration_ground_truth = {
        "attributable": "not-attributable", "comparedCriteria": [2, 3], "differingCriteria": [],
        "derivation": "criteria>=2 identical across control and treatment",
    }
    calibration_estimate = {
        "attributable": "not-attributable", "confidence": "medium",
        "basis": [{"memberId": "workload", "locator": "x"}],
        "rejectedInterpretations": [
            {"interpretation": "attributable", "reason": "selfcheck dummy rejection"}
        ],
    }
    calibration_entry_wo_meta = {
        "estimator": {
            "id": "selfcheck-estimator",
            "identity": estimator_identity(sample_components),
            "components": sample_components,
        },
        "source": {
            "cycle": sample_manifest["cycle"], "arm": sample_manifest["arm"],
            "recordPath": "reviews/selfcheck-cycle.json", "recordSha256": "a" * 64,
        },
        "frozenInput": {"hash": content_hash(sample_manifest), "manifest": sample_manifest},
        "estimate": calibration_estimate,
        "groundTruth": calibration_ground_truth,
        "agreement": "match",
    }
    calibration_entry = dict(calibration_entry_wo_meta)
    calibration_entry["calibratedAt"] = "2026-08-19T00:00:00+09:00"
    calibration_entry["calibrationHash"] = content_hash(calibration_entry_wo_meta)
    sample_calibration_record = {
        "schemaVersion": 1,
        "kind": "calibration-record",
        "estimator": {"id": "selfcheck-estimator"},
        "calibrations": [calibration_entry],
    }
    validate_calibration_record(sample_calibration_record)
    bad_calibration_record = json.loads(json.dumps(sample_calibration_record))
    bad_calibration_record["calibrations"][0]["approved"] = True
    assert _expect_system_exit(validate_calibration_record, bad_calibration_record)

    # ---- estimate 拒否 3b / 4 と artifacts 照合（TEMP のみ、実資産に触れない）----
    old_dirs = (FROZEN_DIR, ESTIMATORS_DIR, CALIBRATIONS_DIR, CONTROL_DIR)
    try:
        with tempfile.TemporaryDirectory(prefix="cycle-selfcheck-est-") as sc_root:
            CONTROL_DIR = sc_root
            FROZEN_DIR = os.path.join(sc_root, "frozen")
            ESTIMATORS_DIR = os.path.join(sc_root, "estimators")
            CALIBRATIONS_DIR = os.path.join(sc_root, "calibrations")
            os.makedirs(FROZEN_DIR)
            os.makedirs(ESTIMATORS_DIR)
            os.makedirs(CALIBRATIONS_DIR)
            os.makedirs(os.path.join(sc_root, "reviews"))
            os.makedirs(os.path.join(sc_root, "estimations"))

            gate_estimator_id = "selfcheck-gate-estimator"
            gate_components = {
                "model": "selfcheck-model",
                "promptSha256": "3" * 64,
                "protocol": "blind-bundle-read-v1",
            }
            gate_identity = estimator_identity(gate_components)
            with open(
                os.path.join(ESTIMATORS_DIR, "%s.json" % gate_estimator_id),
                "w",
                encoding="utf-8",
            ) as handle:
                json.dump(
                    {
                        "schemaVersion": 1,
                        "kind": "estimator",
                        "id": gate_estimator_id,
                        "components": gate_components,
                    },
                    handle,
                )

            def _write_gate_bundle(include_measurement):
                decl_bytes = b'{"cycle":"selfcheck-gate-cycle"}'
                workload_bytes = b"workload"
                measurement_bytes = b"measurement"
                members = [
                    {
                        "id": "declaration",
                        "kind": "declaration",
                        "path": "payload/declaration.json",
                        "source": "apparatus/cycles/selfcheck-gate-cycle.json",
                        "sha256": hashlib.sha256(decl_bytes).hexdigest(),
                        "bytes": len(decl_bytes),
                    },
                    {
                        "id": "workload",
                        "kind": "workload",
                        "path": "payload/workload.md",
                        "source": "agent-rules/experiments/selfcheck-experiment/workload.md",
                        "sha256": hashlib.sha256(workload_bytes).hexdigest(),
                        "bytes": len(workload_bytes),
                    },
                ]
                payload_map = {
                    "payload/declaration.json": decl_bytes,
                    "payload/workload.md": workload_bytes,
                }
                manifest = {
                    "schemaVersion": 1,
                    "kind": "frozen-input",
                    "cycle": "selfcheck-gate-cycle",
                    "experiment": "selfcheck-experiment",
                    "arm": "arm-selfcheck",
                    "armRole": "control",
                    "variant": "v1",
                    "variantTree": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "subject": "claude-code",
                    "subjectVersion": "9.9.9 (selfcheck)",
                    "declarationSha256": hashlib.sha256(decl_bytes).hexdigest(),
                    "workloadSha256": hashlib.sha256(workload_bytes).hexdigest(),
                    "commitRange": {
                        "base": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "injection": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        "head": "cccccccccccccccccccccccccccccccccccccccc",
                        "commits": [],
                    },
                    "sessions": [],
                    "members": members,
                }
                if include_measurement:
                    members.append({
                        "id": "measurement",
                        "kind": "measurement",
                        "path": "payload/measurement.md",
                        "source": "agent-rules/experiments/selfcheck-experiment/MEASUREMENT.md",
                        "sha256": hashlib.sha256(measurement_bytes).hexdigest(),
                        "bytes": len(measurement_bytes),
                    })
                    payload_map["payload/measurement.md"] = measurement_bytes
                    manifest["measurementSha256"] = hashlib.sha256(
                        measurement_bytes
                    ).hexdigest()
                    members.sort(key=lambda m: member_sort_key(m["id"]))
                frozen_hash = content_hash(manifest)
                bundle_dir = os.path.join(FROZEN_DIR, frozen_hash)
                os.makedirs(os.path.join(bundle_dir, "payload"), exist_ok=True)
                with open(
                    os.path.join(bundle_dir, "manifest.json"), "w", encoding="utf-8"
                ) as handle:
                    json.dump(manifest, handle, ensure_ascii=False, indent=2)
                    handle.write("\n")
                for rel, content in payload_map.items():
                    with open(
                        os.path.join(bundle_dir, *rel.split("/")), "wb"
                    ) as handle:
                        handle.write(content)
                return frozen_hash, manifest

            hash_no_measurement, _ = _write_gate_bundle(False)
            missing_input = os.path.join(sc_root, "does-not-exist.json")
            try:
                estimate(hash_no_measurement, gate_estimator_id, missing_input)
                raise AssertionError("estimate without measurement member should exit")
            except SystemExit as exc:
                assert "measurement" in str(exc), exc

            hash_with_measurement, gate_manifest = _write_gate_bundle(True)
            mismatch_entry_wo_meta = {
                "estimator": {
                    "id": gate_estimator_id,
                    "identity": gate_identity,
                    "components": gate_components,
                },
                "source": {
                    "cycle": gate_manifest["cycle"],
                    "arm": gate_manifest["arm"],
                    "recordPath": "reviews/selfcheck-gate-cycle.json",
                    "recordSha256": "a" * 64,
                },
                "frozenInput": {
                    "hash": hash_with_measurement,
                    "manifest": gate_manifest,
                },
                "estimate": {
                    "attributable": "attributable",
                    "confidence": "low",
                    "basis": [{"memberId": "measurement", "locator": "selfcheck"}],
                    "rejectedInterpretations": [
                        {"interpretation": "not-attributable", "reason": "selfcheck"}
                    ],
                },
                "groundTruth": {
                    "attributable": "not-attributable",
                    "comparedCriteria": [2],
                    "differingCriteria": [],
                    "derivation": "selfcheck mismatch fixture",
                },
                "agreement": "mismatch",
            }
            mismatch_entry = dict(mismatch_entry_wo_meta)
            mismatch_entry["calibratedAt"] = "2026-08-19T00:00:00+09:00"
            mismatch_entry["calibrationHash"] = content_hash(mismatch_entry_wo_meta)
            with open(
                os.path.join(CALIBRATIONS_DIR, "%s.json" % gate_estimator_id),
                "w",
                encoding="utf-8",
            ) as handle:
                json.dump(
                    {
                        "schemaVersion": 1,
                        "kind": "calibration-record",
                        "estimator": {"id": gate_estimator_id},
                        "calibrations": [mismatch_entry],
                    },
                    handle,
                )
            try:
                estimate(hash_with_measurement, gate_estimator_id, missing_input)
                raise AssertionError("estimate with mismatch calibration should exit")
            except SystemExit as exc:
                assert "mismatch" in str(exc), exc

            artifact_bytes = b"selfcheck-artifact-body"
            artifact_name = "selfcheck-prompt.txt"
            artifact_sha = hashlib.sha256(artifact_bytes).hexdigest()
            with open(os.path.join(ESTIMATORS_DIR, artifact_name), "wb") as handle:
                handle.write(artifact_bytes)
            good_artifacts_desc = {
                "schemaVersion": 1,
                "kind": "estimator",
                "id": "unused",
                "components": {"promptSha256": artifact_sha, "model": "x"},
                "artifacts": {"promptSha256": artifact_name},
            }
            _verify_estimator_artifacts(good_artifacts_desc, ESTIMATORS_DIR)
            missing_artifacts_desc = dict(good_artifacts_desc)
            missing_artifacts_desc["artifacts"] = {"promptSha256": "missing-file.txt"}
            assert _expect_system_exit(
                _verify_estimator_artifacts, missing_artifacts_desc, ESTIMATORS_DIR
            )
            bad_hash_desc = dict(good_artifacts_desc)
            bad_hash_desc["components"] = {
                "promptSha256": "0" * 64,
                "model": "x",
            }
            assert _expect_system_exit(
                _verify_estimator_artifacts, bad_hash_desc, ESTIMATORS_DIR
            )
            slash_desc = dict(good_artifacts_desc)
            slash_desc["artifacts"] = {"promptSha256": "../escape.txt"}
            assert _expect_system_exit(
                _verify_estimator_artifacts, slash_desc, ESTIMATORS_DIR
            )
            dotdot_desc = dict(good_artifacts_desc)
            dotdot_desc["artifacts"] = {"promptSha256": ".."}
            assert _expect_system_exit(
                _verify_estimator_artifacts, dotdot_desc, ESTIMATORS_DIR
            )
    finally:
        FROZEN_DIR, ESTIMATORS_DIR, CALIBRATIONS_DIR, CONTROL_DIR = old_dirs

    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--environment",
        help="environment descriptor; its parent is the private control root",
    )
    parser.add_argument(
        "--selfcheck", action="store_true",
        help="validate pure helpers without materializing a cycle",
    )
    sub = parser.add_subparsers(dest="command")
    materialize_parser = sub.add_parser("materialize")
    materialize_parser.add_argument("--cycle", required=True)
    handoff_parser = sub.add_parser("handoff")
    handoff_parser.add_argument("--cycle", required=True)
    judge_parser = sub.add_parser("judge")
    judge_parser.add_argument("--cycle", required=True)
    judge_parser.add_argument("--replace", action="store_true")
    transcripts_parser = sub.add_parser("transcripts")
    transcripts_parser.add_argument("--cycle", required=True)
    freeze_parser = sub.add_parser("freeze")
    freeze_parser.add_argument("--cycle", required=True)
    freeze_parser.add_argument("--arm", required=True)
    estimate_parser = sub.add_parser("estimate")
    estimate_parser.add_argument("--frozen", required=True)
    estimate_parser.add_argument("--estimator", required=True)
    estimate_parser.add_argument("--input", required=True)
    estimate_parser.add_argument("--replace", action="store_true")
    estimate_parser.add_argument("--allow-measured", action="store_true")
    calibrate_parser = sub.add_parser("calibrate")
    calibrate_parser.add_argument("--cycle", required=True)
    calibrate_parser.add_argument("--arm", required=True)
    calibrate_parser.add_argument("--estimator", required=True)
    calibrate_mode = calibrate_parser.add_mutually_exclusive_group(required=True)
    calibrate_mode.add_argument("--prepare", action="store_true")
    calibrate_mode.add_argument("--input")
    calibrate_parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()

    configure_environment(args.environment)
    if args.selfcheck:
        if args.command is not None:
            parser.error("--selfcheck cannot be combined with a subcommand")
        return selfcheck(check_active_environment=args.environment is not None)
    if args.command is None:
        parser.error("a subcommand is required unless --selfcheck is used")

    if args.command == "materialize":
        materialize(args.cycle)
    elif args.command == "handoff":
        handoff(args.cycle)
    elif args.command == "judge":
        judge(args.cycle, replace=args.replace)
    elif args.command == "transcripts":
        transcripts_report(args.cycle)
    elif args.command == "freeze":
        freeze(args.cycle, args.arm)
    elif args.command == "estimate":
        estimate(
            args.frozen, args.estimator, args.input,
            replace=args.replace, allow_measured=args.allow_measured,
        )
    elif args.command == "calibrate":
        calibrate(
            args.cycle, args.arm, args.estimator,
            prepare=args.prepare, input_path=args.input, replace=args.replace,
        )


if __name__ == "__main__":
    sys.exit(main() or 0)
