#!/usr/bin/env python3
"""Materialize, hand off, judge, promote, and roll back rule experiments.

    python cycle.py materialize --cycle <name>
    python cycle.py handoff --cycle <name>
    python cycle.py judge --cycle <name> [--replace]
    python cycle.py transcripts --cycle <name>
    python cycle.py freeze --cycle <name> --arm <arm-id>
    python cycle.py estimate --frozen <hash> --estimator <id> --input <path> [--replace] [--allow-measured]
    python cycle.py calibrate --cycle <name> --arm <arm-id> --estimator <id> (--prepare | --input <path>) [--replace]
    python cycle.py promote --cycle <name>
    python cycle.py rollback --cycle <name>
    python cycle.py --selfcheck

Normal commands require an explicit environment descriptor. Executor operations use bash through
either WSL or local POSIX. Promotion changes only the declared stable rule-source repository;
runtime distribution, push, tag, and release are outside this program.
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
import shutil
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


def to_executor_path(host_path):
    if load_environment()["executor"]["kind"] == "wsl":
        return to_mnt(host_path)
    return host_path.replace("\\", "/")


def parse_timestamp(value):
    """Python 3.10 でも RFC 3339 の UTC 接尾辞を読めるようにする。"""
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


ENVIRONMENT_PATH = None

# manifest の無い変種は正本のうち subject が使うものだけをアームへ運ぶ。
# README.md は構造と使い方だけを書き、測定に言及しない。
# reconciliation.md と controller.md は比較や測定に言及するので除外する（憲法 不変条件 3）。
MANAGED_ITEMS = ("rules", "placement.json", "bin/rules.py")

# 不変条件 8(3) と docs/EXECUTION-UNIT.md の閉じた可読性候補。固定部分は
# 装置リポジトリ（cycle.py 実行元。アーム側ではない）の追跡下 markdown 全件を
# meta_readability_fixed() が動的に導出する。アーム側の git ls-files を使うと、
# 注入された変種そのものが可読性候補に混入し、metaReadabilityHash がアームごとに
# 違う値になって宣言1つで照合できなくなる（比較可能性が壊れる）ため使わない。
META_READABILITY_GLOBS = (
    "apparatus/cycles/*.json",
    "apparatus/schemas/*",
)
_META_READABILITY_DEVICE_CACHE = None

# 推定機構（docs/RULE-EXPERIMENT.md）の置き場。環境記述子の
# 親を private control root とし、実データ・実推定器資産はここへは版管理しない。
CONTROL_DIR = None
FROZEN_DIR = None
ESTIMATIONS_DIR = None
CALIBRATIONS_DIR = None
ESTIMATORS_DIR = None

# 凍結入力の member.source にこれらの部分文字列が含まれていたら拒否する。
# 計測記録・判定器・baseline manifest を凍結入力へ混ぜない（不変条件10と同型の
# 「推定を計測に混ぜない」を束ねる段階でも守る）。
FROZEN_FORBIDDEN_SOURCE_SUBSTRINGS = ("/reviews/", "/judge/", "baseline-")

# 推定記録・較正記録に書いてはならないキー（憲法 不変条件10。
# 「用途は triage に限る」を構造で守る）。
FORBIDDEN_RECORD_KEYS = {"verdict", "promote", "promotable", "approved", "proven", "recommendation"}

# git の空 tree object。root commit の親として使う（variant-injection の diff）。
EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

_environment_cache = None
_subject_cache = {}


def configure_environment(path):
    """Select the required environment descriptor and its private record root."""
    global ENVIRONMENT_PATH, CONTROL_DIR
    global FROZEN_DIR, ESTIMATIONS_DIR, CALIBRATIONS_DIR, ESTIMATORS_DIR
    global _environment_cache

    if not path:
        raise SystemExit("--environment is required")
    ENVIRONMENT_PATH = os.path.abspath(path)
    CONTROL_DIR = os.path.dirname(ENVIRONMENT_PATH)
    FROZEN_DIR = os.path.join(CONTROL_DIR, "frozen")
    ESTIMATIONS_DIR = os.path.join(CONTROL_DIR, "estimations")
    CALIBRATIONS_DIR = os.path.join(CONTROL_DIR, "calibrations")
    ESTIMATORS_DIR = os.path.join(CONTROL_DIR, "estimators")
    _environment_cache = None


def resolve_control_path(value):
    """Resolve a host-side path relative to the environment descriptor."""
    if os.path.isabs(value):
        return os.path.normpath(value)
    return os.path.normpath(os.path.join(CONTROL_DIR, value))


def variant_source_root():
    return resolve_control_path(load_environment()["variantSourceRoot"])


def stable_rules_root():
    return resolve_control_path(load_environment()["stableRules"]["root"])


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
    """foundation-control 配下の環境記述子。プロセス内キャッシュ。"""
    global _environment_cache
    if _environment_cache is not None:
        return _environment_cache
    if not ENVIRONMENT_PATH or not os.path.isfile(ENVIRONMENT_PATH):
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
    for entry in subject["credentialPaths"]:
        if entry == "." or any(segment == ".." for segment in entry.split("/")):
            raise SystemExit(
                "invalid credentialPaths entry %r in subject %s" % (entry, subject_id)
            )
    _subject_cache[subject_id] = subject
    return subject


def subject_ids(decl):
    """Return the declaration's immutable subject id list."""
    value = decl.get("subjects")
    if (
        isinstance(value, list)
        and value
        and all(isinstance(item, str) and item for item in value)
        and len(value) == len(set(value))
    ):
        return value
    raise SystemExit(
        "declaration subjects must be a non-empty unique list of strings: %r"
        % (value,)
    )


def execution_unit_path():
    return os.path.join(os.path.dirname(APPARATUS_DIR), "docs", "EXECUTION-UNIT.md")


def exec_(cmd, check=True):
    """Run bash either through the declared WSL boundary or locally.

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
    executor = load_environment()["executor"]
    kind = executor["kind"]
    if kind == "wsl":
        argv = [
            "wsl.exe", "-d", executor["distro"], "-u", executor["user"],
            "-e", "bash", "-lc", cmd,
        ]
    elif kind == "local-posix":
        argv = ["bash", "-lc", cmd]
    else:
        raise SystemExit("unsupported executor kind: %r" % kind)
    result = subprocess.run(
        argv,
        capture_output=True, text=True, encoding="utf-8",
    )
    if check:
        if result.returncode != 0:
            # 理由を先に出す。スクリプト本文で埋めない。
            raise SystemExit(
                "%s\nexec failed (%d) in: %s"
                % (result.stderr.strip(), result.returncode, cmd.splitlines()[1 if cmd.startswith("set -e") else 0])
            )
        return result.stdout
    return result.stdout, result.stderr, result.returncode


def git_source(*args):
    """Read the private variant-source repository on the controller host."""
    result = subprocess.run(
        ["git", "-C", variant_source_root(), *args],
        capture_output=True, text=True, encoding="utf-8",
    )
    if result.returncode != 0:
        raise SystemExit("variant source git %s failed: %s" % (" ".join(args), result.stderr))
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
    return decl["kind"]


def validate_arms(cycle_name, decl):
    """宣言の arms を使う前に検証する。空・必須キー欠落・id の形式不正・
    id 重複は SystemExit。重複を許すと judge の reports 集計が id で潰れ、
    「全アームの report が揃った」ガードが黙って照合をスキップする。
    estimation is exactly one arm; measurement is one control plus one treatment."""
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
        roles = [arm["role"] for arm in arms]
        if len(arms) != 2 or sorted(roles) != ["control", "treatment"]:
            raise SystemExit(
                "measurement cycle requires exactly one control and one treatment: %s"
                % roles
            )


def require_subject(cycle_name, decl):
    """Validate every declared subject and its private template binding."""
    path = cycle_path(cycle_name)
    if "subjects" not in decl:
        raise SystemExit("declaration is missing key 'subjects': %s" % path)
    configured = load_environment()["subjects"]
    for sid in subject_ids(decl):
        load_subject(sid)
        if sid not in configured:
            raise SystemExit("subject %s has no configTemplate in environment: %s" % (sid, path))


def release_path(cycle_name):
    """distro 内の release パス。`~` のシェル展開に頼らず $HOME を使う。
    識別子は検証済みだが、可変部の引用も併せて掛ける。"""
    return '"$HOME"/releases/%s' % shlex.quote(cycle_name)


def verify_canonical(experiment, arm):
    """正本の照合。宣言の variantTree と実体の食い違い、作業ツリーの汚れを
    リストで返す（無ければ空リスト）。呼び出し元が exit するかどうかを決める。"""
    mismatches = []
    rel = "experiments/%s/variants/%s/source" % (experiment, arm["variant"])
    actual = git_source("rev-parse", "HEAD:%s" % rel).strip()
    if actual != arm["variantTree"]:
        mismatches.append(
            "mismatch: variantTree for %s: declared %s, actual %s"
            % (arm["id"], arm["variantTree"], actual)
        )
    dirty = git_source("status", "--porcelain", "--", rel)
    if dirty.strip():
        mismatches.append("mismatch: canonical is dirty for %s:\n%s" % (arm["id"], dirty))
    return mismatches


def variant_canonical_dir(experiment, variant):
    return os.path.join(
        variant_source_root(), "experiments", experiment, "variants", variant, "source"
    )


def load_variant_placement(experiment, variant):
    path = os.path.join(variant_canonical_dir(experiment, variant), "placement.json")
    with open(path, encoding="utf-8") as handle:
        placement = json.load(handle)
    if not isinstance(placement.get("tools"), dict) or not placement["tools"]:
        raise SystemExit("variant placement has no tools: %s" % path)
    return placement


def selected_output_patterns(decl, arm):
    """Return proven renderer output patterns for the selected subjects."""
    placement = load_variant_placement(decl["experiment"], arm["variant"])
    patterns = []
    must_stay_empty = set(placement.get("mustStayEmpty", []))
    mismatches = []
    for sid in subject_ids(decl):
        subject = load_subject(sid)
        must_stay_empty.update(subject["keepEmpty"])
        spec = placement["tools"].get(subject["tool"])
        if spec is None or not isinstance(spec.get("path"), str):
            mismatches.append("mismatch: variant has no placement for subject %s" % sid)
            continue
        output = spec["path"].replace("{id}", "*")
        proven = [p["path"] for p in subject["workspacePlacement"] if p["proven"]]
        if not any(fnmatch.fnmatch(output, path) or fnmatch.fnmatch(path, output) for path in proven):
            mismatches.append(
                "mismatch: output %s for subject %s is not on a proven placement"
                % (output, sid)
            )
        patterns.append(output)
    if mismatches:
        raise SystemExit("\n".join(mismatches))
    return sorted(set(patterns)), sorted(must_stay_empty)


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


def build_arm_inject_lines(arm, decl):
    """Render outside the arm, then copy only selected proven outputs."""
    source = to_executor_path(variant_canonical_dir(decl["experiment"], arm["variant"]))
    patterns, must_stay_empty = selected_output_patterns(decl, arm)
    case_patterns = "|".join(patterns)
    arm_q = shlex.quote(arm["id"])
    lines = [
        "tmp=$(mktemp -d)",
        "PYTHONDONTWRITEBYTECODE=1 python3 %s render \"$tmp\"" % shlex.quote(source + "/bin/rules.py"),
        "while IFS= read -r -d '' f; do",
        "  rel=${f#$tmp/}",
        "  case \"$rel\" in",
        "    %s) dest=%s/$rel; %s ;;" % (
            case_patterns,
            arm_q,
            _bash_copy_file_with_conflict('"$f"', '"$dest"'),
        ),
        "  esac",
        "done < <(find \"$tmp\" -type f -print0)",
        "rm -rf \"$tmp\"",
    ]
    for path in must_stay_empty:
        target = "%s/%s" % (arm_q, shlex.quote(path))
        lines.append(
            "if { [ -e %(target)s ] || [ -L %(target)s ]; } && "
            "{ [ ! -d %(target)s ] || "
            "[ -n \"$(find %(target)s -mindepth 1 -print -quit)\" ]; }; "
            "then echo %(message)s >&2; exit 1; fi"
            % {
                "target": target,
                "message": shlex.quote(
                    "mismatch: unused always-apply path is not empty: %s" % path
                ),
            }
        )
    return lines


def resolve_materialize_base(decl):
    """Resolve the declared workload repository without a sibling convention."""
    base = decl.get("base")
    if not isinstance(base, dict) or "repo" not in base or "commit" not in base:
        raise SystemExit("materialize requires base: {repo, commit}")
    repo_id = base["repo"]
    parent = repo_id if os.path.isabs(repo_id) else os.path.join(CONTROL_DIR, repo_id)
    parent = os.path.normpath(parent)
    if not os.path.isdir(os.path.join(parent, ".git")):
        raise SystemExit("base.repo is not a Git repository: %s" % parent)
    commit = base["commit"]
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("base.commit must be a 40-char lowercase hex git object")
    return parent, commit


def build_setup_script(cycle, src_mnt, commit, arms, experiment, subjects):
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
    for arm in arms:
        inject_lines = build_arm_inject_lines(arm, {"experiment": experiment, "subjects": subjects})
        lines.extend(inject_lines)
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
    return "\n".join(lines)


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
    src_mnt = to_executor_path(src_win)

    for arm in decl["arms"]:
        mismatches = verify_canonical(experiment, arm)
        if mismatches:
            raise SystemExit("\n".join(mismatches))

    script = build_setup_script(
        cycle_name, src_mnt, commit, decl["arms"], experiment, subject_ids(decl)
    )
    setup_out = exec_(script)

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
# 両アームで 1バイトも変えない（`MEASUREMENT.md`、憲法 不変条件 (2) の唯一の例外）。
# この文面に実験・計測・測定・アーム・比較といった語を足さない。
# 正本は rule-experiment-source/experiments/<experiment>/session-contract.md。
def session_contract_path(experiment):
    return os.path.join(
        variant_source_root(), "experiments", experiment, "session-contract.md"
    )


def load_session_contract(experiment):
    with open(session_contract_path(experiment), "rb") as handle:
        return handle.read().decode("utf-8")


def sha256_file(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def atomic_write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".%s." % os.path.basename(path), dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def meta_readability_fixed():
    """可読性候補の固定部分: 装置リポジトリ（cycle.py 実行元。アーム側ではない）
    の追跡下 markdown 全件。posix 相対パスのタプル。プロセス内キャッシュ。"""
    global _META_READABILITY_DEVICE_CACHE
    if _META_READABILITY_DEVICE_CACHE is None:
        device_repo_root = os.path.dirname(APPARATUS_DIR)
        result = subprocess.run(
            ["git", "-C", device_repo_root, "ls-files", "-z", "--", "*.md"],
            capture_output=True, text=True, encoding="utf-8", check=True,
        )
        _META_READABILITY_DEVICE_CACHE = tuple(
            sorted(p for p in result.stdout.split("\0") if p)
        )
    return _META_READABILITY_DEVICE_CACHE


def is_meta_readability_candidate(path):
    """閉じた可読性候補集合に入るか。posix 相対パスのみ。"""
    if not isinstance(path, str) or not path or "\\" in path or path.startswith("/"):
        return False
    if path in meta_readability_fixed():
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
    fixed = " ".join(shlex.quote(p) for p in meta_readability_fixed())
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


def collect_handoff_mismatches(cycle_name, decl):
    """handoff 前の照合。宣言と実物の食い違い、アームが materialize 直後で
    ないこと、config root に transcript が既にあることをすべて集めて返す
    （無ければ空リスト）。"""
    experiment = decl["experiment"]
    mismatches = []

    for arm in decl["arms"]:
        mismatches.extend(verify_canonical(experiment, arm))

    hash_checks = [
        ("workloadHash", os.path.join(variant_source_root(), "experiments", experiment, "workload.md")),
        ("measurementHash", os.path.join(variant_source_root(), "experiments", experiment, "MEASUREMENT.md")),
        ("judgeHash", os.path.join(variant_source_root(), "experiments", experiment, "judge", "judge.py")),
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


def executor_template_path(subject_id):
    value = load_environment()["subjects"][subject_id]["configTemplate"]
    if value.startswith("/") or value.startswith("~"):
        return value
    return to_executor_path(resolve_control_path(value))


def executor_store_path(subject_id):
    """credentialStore（任意）の executor 側パス。未設定なら None。

    `~` は shlex.quote 越しでは展開されず無言で壊れるので明示的に拒否する
    （executor_template_path にある同種の危険は変更しない）。"""
    value = load_environment()["subjects"][subject_id].get("credentialStore")
    if value is None:
        return None
    if value.startswith("~"):
        raise SystemExit("credentialStore must not start with '~': %s" % value)
    if value.startswith("/"):
        return to_executor_path(value)
    return to_executor_path(resolve_control_path(value))


def transcript_exclude_root(subject):
    """複製から除外する transcript の置き場（`transcripts.glob` の先頭
    セグメントから導出）。transcript 非対応、または searchRoot が
    home-cursor（config root の外を見る）の subject では除外なし（None）。"""
    transcripts = subject["transcripts"]
    if transcripts is None or transcripts.get("searchRoot") == "home-cursor":
        return None
    glob = transcripts["glob"]
    root = glob.split("/", 1)[0]
    if root in (".", "..") or any(ch in root for ch in "*?["):
        raise SystemExit(
            "transcripts.glob root segment cannot be a wildcard or parent reference: %r" % glob
        )
    return root


def config_root_path(cycle, arm_id, subject_id):
    return "%s/configs/%s/%s" % (
        release_path(cycle), shlex.quote(arm_id), shlex.quote(subject_id)
    )


def build_config_script(cycle, experiment, arms, subjects):
    """Clone each private template into configs/<arm>/<subject>, strip
    credential and transcript paths from the clone, symlink credentials in
    from the shared store (if configured), and hash the identity of the
    surviving plain files."""
    lines = ["set -e"]
    contract = load_session_contract(experiment)
    for arm in arms:
        for sid in subjects:
            subject = load_subject(sid)
            cfg = config_root_path(cycle, arm["id"], sid)
            source = executor_template_path(sid)
            lines.extend([
                "rm -rf %s" % cfg,
                "mkdir -p %s" % cfg,
                "cp -a %s/. %s/" % (shlex.quote(source), cfg),
            ])

            exclude_paths = list(subject["credentialPaths"])
            exclude_root = transcript_exclude_root(subject)
            if exclude_root is not None:
                exclude_paths.append(exclude_root)
            for rel in exclude_paths:
                lines.append("rm -rf %s/%s" % (cfg, shlex.quote(rel)))

            store = executor_store_path(sid)
            if store is not None:
                lines.append(
                    'case %s in "$HOME"/releases/*) echo %s >&2; exit 1;; esac'
                    % (
                        shlex.quote(store),
                        shlex.quote("credentialStore must not point inside $HOME/releases: %s" % store),
                    )
                )
                for rel in subject["credentialPaths"]:
                    store_item = "%s/%s" % (store, shlex.quote(rel))
                    target = "%s/%s" % (cfg, shlex.quote(rel))
                    lines.append(
                        "[ -e %s ] || { echo %s >&2; exit 1; }"
                        % (store_item, shlex.quote("credential missing in store: %s" % rel))
                    )
                    lines.append("mkdir -p \"$(dirname %s)\"" % target)
                    lines.append("ln -sfn %s %s" % (store_item, target))

            marker = subject["markerFile"]
            if marker is not None:
                body = contract % (experiment, arm["variant"])
                target = "%s/%s" % (cfg, shlex.quote(marker))
                lines.append("mkdir -p \"$(dirname %s)\"" % target)
                lines.append("cat > %s <<'CFGEOF'\n%sCFGEOF" % (target, body))

            for rel in subject["credentialPaths"]:
                target = "%s/%s" % (cfg, shlex.quote(rel))
                lines.append(
                    "if [ -e %s ] && [ ! -L %s ]; then echo %s >&2; exit 1; fi"
                    % (target, target, shlex.quote("credential file in release: %s" % rel))
                )

            if marker is not None:
                prune = " ! -path %s" % shlex.quote("./%s" % marker)
            else:
                prune = ""
            lines.extend([
                "identity=$(cd %s && find . -type f%s -print0 "
                "| LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"
                % (cfg, prune),
                "printf 'CONFIG %%s %%s %%s %%s\\n' %s %s \"$identity\" %s"
                % (shlex.quote(arm["id"]), shlex.quote(sid), cfg),
            ])
    return "\n".join(lines)


def collect_credential_placement_mismatches(cycle_name, decl):
    """defence in depth after handoff: 各アーム×subject の credentialPaths が
    config root で「不在または symlink」のままであることを照合する。
    build_config_script 内の同種のアサーションを handoff 後の時点でも掛け
    直す（手動編集や凍結準備時のドリフトを検出するため）。judge() からは
    呼ばない（完了した計測を hygiene 理由で拒否させない）。"""
    mismatches = []
    lines = ["set -e"]
    for arm in decl["arms"]:
        for sid in subject_ids(decl):
            subject = load_subject(sid)
            cfg = config_root_path(cycle_name, arm["id"], sid)
            for rel in subject["credentialPaths"]:
                target = "%s/%s" % (cfg, shlex.quote(rel))
                lines.append(
                    "if [ -e %s ] && [ ! -L %s ]; then printf 'MISMATCH %%s %%s\\n' %s %s; fi"
                    % (target, target, shlex.quote(arm["id"]), shlex.quote(rel))
                )
    if len(lines) == 1:
        return mismatches
    out = exec_("\n".join(lines))
    for line in out.splitlines():
        if line.startswith("MISMATCH "):
            _tag, arm_id, rel = line.split(" ", 2)
            mismatches.append(
                "mismatch: %s credential file in release (must be absent or a symlink): %s"
                % (arm_id, rel)
            )
    return mismatches


def build_baseline_script(cycle, judge_path, arm):
    """1アーム分の baseline manifest をアームの外（release 直下）へ出力する。"""
    release = release_path(cycle)
    output = "baseline-%s.json" % arm["id"]
    lines = [
        "set -e",
        "cd %s" % release,
        "python3 %s baseline --arm %s -o %s"
        % (shlex.quote(judge_path), shlex.quote(arm["id"]), shlex.quote(output)),
        "[ -s %s ]" % shlex.quote(output),
    ]
    return "\n".join(lines)


def handoff(cycle_name):
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    require_subject(cycle_name, decl)
    experiment = decl["experiment"]
    ids = subject_ids(decl)

    mismatches = collect_handoff_mismatches(cycle_name, decl)
    if mismatches:
        raise SystemExit("\n".join(mismatches))

    versions = {sid: exec_(load_subject(sid)["versionCommand"]).strip() for sid in ids}
    config_out = exec_(build_config_script(cycle_name, experiment, decl["arms"], ids))
    configs = {}
    for line in config_out.splitlines():
        if line.startswith("CONFIG "):
            _tag, arm_id, sid, identity, path = line.split(" ", 4)
            configs[(arm_id, sid)] = (identity, path)
    for sid in ids:
        identities = {configs[(arm["id"], sid)][0] for arm in decl["arms"]}
        if len(identities) != 1:
            raise SystemExit("mismatch: config identity differs across arms for %s" % sid)

    if cycle_kind(decl) != "estimation":
        judge_path = "%s/experiments/%s/judge/judge.py" % (to_executor_path(variant_source_root()), experiment)
        for arm in decl["arms"]:
            out = exec_(build_baseline_script(cycle_name, judge_path, arm))
            print("baseline %s: %s" % (arm["id"], out.strip().replace("\n", " ")))

    executor = load_environment()["executor"]
    record = {"schemaVersion": 1, "cycle": cycle_name,
              "recordedAt": datetime.datetime.now().astimezone().isoformat(), "arms": []}
    for arm in decl["arms"]:
        arm_out = {"id": arm["id"], "subjects": []}
        for sid in ids:
            subject = load_subject(sid)
            identity, cfg = configs[(arm["id"], sid)]
            inner = "cd $HOME/releases/%s/%s && %s=%s %s" % (
                cycle_name, arm["id"], subject["isolationEnv"], cfg, subject["binary"]
            )
            if executor["kind"] == "wsl":
                launch = "wsl.exe -d %s -u %s -e bash -lc %s" % (
                    executor["distro"], executor["user"], shlex.quote(inner)
                )
            else:
                launch = "bash -lc %s" % shlex.quote(inner)
            arm_out["subjects"].append({
                "id": sid, "version": versions[sid], "configIdentity": identity,
                "configRoot": cfg, "launch": launch,
            })
            print(launch)
        record["arms"].append(arm_out)
    validate_against_schema(record, "handoff.schema.json", "handoff %s" % cycle_name)
    handoff_path = os.path.join(CONTROL_DIR, "handoffs", "%s.json" % cycle_name)
    if os.path.exists(handoff_path):
        raise SystemExit("handoff record already exists: %s" % handoff_path)
    atomic_write_json(handoff_path, record)
    print("recorded: %s" % handoff_path)


def _list_transcript_paths(cycle_name, arm, subject_id, glob_pat, search_root="config-root"):
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
    base = config_root_path(cycle_name, arm["id"], subject_id)
    pattern = "%s/%s" % (base, glob_pat)
    prefix = "shopt -s globstar; " if "**" in glob_pat else ""
    out, _stderr, _code = exec_("%sls %s 2>/dev/null" % (prefix, pattern), check=False)
    return [line.strip() for line in out.splitlines() if line.strip()]


def find_transcripts(cycle_name, arm, decl):
    """`$HOME/releases/<cycle>/configs/<arm>/<subject>/` 配下（または subject 記述子が
    `searchRoot: home-cursor` を指すなら distro の `$HOME/.cursor` 配下）を、
    subjects/ 全記述子の transcripts.glob で列挙する。transcripts が null の
    subject は飛ばす。重複パスは1回。0件なら空リスト。発見した全件を返し、選ばない。
    decl は呼び出し互換のため受け取るが、列挙対象は宣言の subject に限らない。"""
    paths = []
    seen = set()
    for sid in subject_ids(decl):
        subject = load_subject(sid)
        if subject["transcripts"] is None:
            continue
        transcripts = subject["transcripts"]
        for line in _list_transcript_paths(
            cycle_name, arm, sid, transcripts["glob"], transcripts.get("searchRoot", "config-root")
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


def transcript_slug_mismatch(arm, fact):
    """transcript の project ディレクトリ名が、そのアームのパスから導けるかを
    照合する。`cd <arm>` × isolation env var を別 cfg に向けた取り違えで、別の
    アームのセッションの証拠がこのアームの判定に使われる経路を塞ぐ。導けれ
    ば None、導けなければ mismatch 文字列を返す。armBinding == project-slug
    のときだけ呼ぶこと。"""
    # find_transcripts の glob により、transcript は必ず
    # <release>/configs/<arm>/<subject>/projects/<slug>/<file>.jsonl の形をしている。
    transcript = fact["path"]
    parts = transcript.split("/")
    actual_slug = parts[-2]
    expected_slug = project_slug(fact["armPath"])
    if actual_slug != expected_slug:
        return (
            "mismatch: %s transcript project slug %s does not derive from the arm path "
            "(expected %s): %s" % (arm["id"], actual_slug, expected_slug, transcript)
        )
    return None


def derive_arm_path(arm, transcript):
    marker = "/configs/%s/" % arm["id"]
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
        mismatch = transcript_slug_mismatch(arm, fact)
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


def transcript_facts(cycle_name, arm, decl):
    """アームの config root にある全 jsonl について、span と参加エントリ数を返す。
    subjects/ 全記述子を走査する。各 fact に tool / armBinding / armPath /
    （session-meta-cwd なら）cwd を付ける。"""
    facts = []
    arm_path = exec_("realpath %s/%s" % (release_path(cycle_name), shlex.quote(arm["id"]))).strip()
    for sid in subject_ids(decl):
        subject = load_subject(sid)
        if subject["transcripts"] is None:
            continue
        transcripts = subject["transcripts"]
        paths = _list_transcript_paths(
            cycle_name, arm, sid, transcripts["glob"], transcripts.get("searchRoot", "config-root")
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
                "tool": sid,
                "path": path,
                "firstTimestamp": item.get("firstTimestamp"),
                "lastTimestamp": item.get("lastTimestamp"),
                "assistantCount": int(item["assistantCount"]),
                "armBinding": arm_binding,
                "armPath": arm_path,
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

    for sha, author_time in commits:
        moment = parse_timestamp(author_time)
        if not any(
            parse_timestamp(s["firstTimestamp"]) <= moment <= parse_timestamp(s["lastTimestamp"])
            for s in belongs_participating
        ):
            mismatches.append(
                "mismatch: %s commit %s at %s is outside belonging participating "
                "session spans"
                % (arm["id"], sha, author_time)
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


def build_judge_script(cycle_name, experiment, arm, execution_path):
    """1アーム分の `judge.py judge` 呼び出し。判定が全 met でなければ判定器は
    exit 1 を返すが、それは正当な計測結果であって infra 失敗ではない。呼び
    出し元は returncode を 0/1 とそれ以外で扱い分ける。"""
    release = release_path(cycle_name)
    judge_path = "%s/experiments/%s/judge/judge.py" % (to_executor_path(variant_source_root()), experiment)
    workload_path = "%s/experiments/%s/workload.md" % (to_executor_path(variant_source_root()), experiment)
    arm_path = "%s/%s" % (release, shlex.quote(arm["id"]))
    baseline_path = baseline_arg(cycle_name, arm)
    return (
        "python3 %s judge --arm %s --workload %s --variant %s --execution %s --baseline %s"
        % (
            shlex.quote(judge_path),
            arm_path,
            shlex.quote(workload_path),
            shlex.quote(arm["variant"]),
            shlex.quote(to_executor_path(execution_path)),
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

    if mismatches:
        raise SystemExit("\n".join(mismatches))
    return None


def judge(cycle_name, replace=False):
    """判定器を両アームへ同一に適用し、記録を foundation-control/reviews/ へ
    書く。1つでも照合に落ちたら記録は書かず exit 非0にする（食い違いは
    全件集めてから出す）。既存記録の上書きは --replace の明示が要る。"""
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    if cycle_kind(decl) == "estimation":
        raise SystemExit(
            "estimation cycle rejects judge (no comparison arms): %s" % cycle_name
        )
    require_subject(cycle_name, decl)
    experiment = decl["experiment"]
    mismatches = []

    judge_win = os.path.join(variant_source_root(), "experiments", experiment, "judge", "judge.py")
    workload_win = os.path.join(variant_source_root(), "experiments", experiment, "workload.md")
    measurement_win = os.path.join(variant_source_root(), "experiments", experiment, "MEASUREMENT.md")
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
    handoff_path = os.path.join(CONTROL_DIR, "handoffs", "%s.json" % cycle_name)
    if not os.path.isfile(handoff_path):
        raise SystemExit("handoff record not found: %s" % handoff_path)
    with open(handoff_path, encoding="utf-8") as handle:
        handoff_record = json.load(handle)
    validate_against_schema(handoff_record, "handoff.schema.json", "handoff %s" % cycle_name)
    handoff_by_arm = {arm["id"]: arm for arm in handoff_record["arms"]}
    execution = {"schemaVersion": 1, "cycle": cycle_name,
                 "recordedAt": datetime.datetime.now().astimezone().isoformat(), "arms": []}
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
        injection = injection_commit_of(materialized, arm["id"])
        commits = load_commits_since(cycle_name, arm, injection) if injection else []
        mismatches.extend(collect_execution_mismatches(arm, facts, commits))
        subjects_out = []
        handoff_subjects = {item["id"]: item for item in handoff_by_arm[arm["id"]]["subjects"]}
        for sid in subject_ids(decl):
            sessions = [
                entry for entry in session_entries_for_record(arm, facts)
                if entry["tool"] == sid and entry["belonging"] == "belongs"
                and entry["assistantCount"] >= 1
            ]
            if not sessions:
                mismatches.append("mismatch: %s has no participating session for %s" % (arm["id"], sid))
                continue
            start = handoff_subjects[sid]
            subjects_out.append({
                "id": sid, "version": start["version"],
                "configIdentity": start["configIdentity"], "launch": start["launch"],
                "sessions": sessions,
            })
        execution["arms"].append({
            "id": arm["id"], "subjects": subjects_out,
            "commits": [{"sha": sha, "authoredAt": authored} for sha, authored in commits],
        })

    mismatches.extend(collect_provenance_mismatches(cycle_name, decl))

    if mismatches:
        raise SystemExit("\n".join(mismatches))

    validate_against_schema(execution, "execution.schema.json", "execution %s" % cycle_name)
    execution_path = os.path.join(CONTROL_DIR, "executions", "%s.json" % cycle_name)
    atomic_write_json(execution_path, execution)
    execution_sha256 = sha256_file(execution_path)

    review_path = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if os.path.exists(review_path):
        try:
            with open(review_path, encoding="utf-8") as handle:
                existing = json.load(handle)
        except (ValueError, UnicodeDecodeError):
            raise SystemExit(
                "existing record is not valid JSON (not schemaVersion 3); "
                "refusing to overwrite even with --replace: %s" % review_path
            )
        if not isinstance(existing, dict) or existing.get("schemaVersion") != 3:
            raise SystemExit(
                "existing record schemaVersion is %r (expected 3); "
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
        stdout, stderr, code = exec_(
            build_judge_script(cycle_name, experiment, arm, execution_path), check=False
        )
        if code not in (0, 1):
            raise SystemExit(
                "judge invocation failed for %s (exit %d): %s" % (arm["id"], code, stderr.strip())
            )
        try:
            report = json.loads(stdout)
        except ValueError as exc:
            mismatches.append("mismatch: %s judge output is not valid JSON: %s" % (arm["id"], exc))
            continue
        reports[arm["id"]] = {"report": report, "exitCode": code}

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
        arms_out.append({
            "id": arm["id"],
            "role": arm["role"],
            "variant": arm["variant"],
            "variantTree": arm["variantTree"],
            "variantInjectionCommit": injection_by_id[arm["id"]],
            "armCommit": arm_commit,
            "workloadSha256": info["report"]["workloadSha256"],
            "judgeSha256": info["report"]["judgeSha256"],
            "judgeExitCode": info["exitCode"],
            "criteria": info["report"]["criteria"],
        })

    record = {
        "schemaVersion": 3,
        "cycle": cycle_name,
        "experiment": experiment,
        "recordedAt": datetime.datetime.now().astimezone().isoformat(),
        "subjects": decl["subjects"],
        "baseCommit": base_commit,
        "measurementSha256": measurement_sha256,
        "executionSha256": execution_sha256,
        "arms": arms_out,
    }

    validate_record(record)
    atomic_write_json(review_path, record)

    for arm in decl["arms"]:
        info = reports[arm["id"]]
        parts = " ".join("%d=%s" % (c["criterion"], c["result"]) for c in info["report"]["criteria"])
        print("%s: %s (judge exit %d)" % (arm["id"], parts, info["exitCode"]))
    judge_identical = len({info["report"]["judgeSha256"] for info in reports.values()}) == 1
    print("judgeSha256 identical across arms: %s" % judge_identical)
    print("recorded: %s" % review_path)


def transcripts_report(cycle_name):
    """アームごとに発見した transcript と注入以降の commit、および
    collect_execution_mismatches / collect_provenance_mismatches の結果を
    そのまま出す。書き込みはしない。materialized.json 欠落は
    collect_provenance_mismatches が他コマンドと同じ形の mismatch として扱う。"""
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    require_subject(cycle_name, decl)
    materialized, _mat_error = load_materialized(cycle_name)
    print("cycle: %s" % cycle_name)
    for arm in decl["arms"]:
        facts = transcript_facts(cycle_name, arm, decl)
        injection = injection_commit_of(materialized, arm["id"])
        commits = load_commits_since(cycle_name, arm, injection) if injection else []
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
        print("  commits since %s:" % ("injection %s" % injection if injection else "(no injectionCommit)"))
        if commits:
            for sha, author_time in commits:
                print("    %s %s" % (sha, author_time))
        else:
            print("    (none)")
        if mismatches:
            print("  mismatches:")
            for item in mismatches:
                print("    %s" % item)
        else:
            print("  mismatches: (none)")
    provenance_mismatches = collect_provenance_mismatches(cycle_name, decl)
    if provenance_mismatches:
        print("")
        print("provenance mismatches:")
        for item in provenance_mismatches:
            print("  %s" % item)


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
    """次のいずれかを検出したら拒否する。dict のキーも値と同様に辿り、
    比較はすべて大文字小文字を無視する。

    - Windows 絶対パス（ドライブレター + `:` + `\\` または `/`）
    - `\\wsl$` UNC パス
    - `/mnt/<drive>/...`（WSL 経由での Windows パス参照）
    - 実行環境の実 USERNAME（os.environ['USERNAME']）を大文字小文字無視で含む文字列

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
    """foundation-control/estimators/<id>.json を読み、schema 検証して返す。"""
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
    require_subject(cycle_name, decl)
    experiment = decl["experiment"]
    arm = next((a for a in decl["arms"] if a["id"] == arm_id), None)
    if arm is None:
        raise SystemExit("cycle %s declaration has no arm %r" % (cycle_name, arm_id))

    mismatches = []
    mismatches.extend(collect_provenance_mismatches(cycle_name, decl))
    mismatches.extend(collect_credential_placement_mismatches(cycle_name, decl))

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

    workload_win = os.path.join(variant_source_root(), "experiments", experiment, "workload.md")
    with open(workload_win, "rb") as handle:
        workload_bytes = handle.read()
    actual_workload_sha = hashlib.sha256(workload_bytes).hexdigest()
    if actual_workload_sha != decl["workloadHash"]:
        raise SystemExit(
            "mismatch: workloadHash declared %s, actual %s"
            % (decl["workloadHash"], actual_workload_sha)
        )

    measurement_win = os.path.join(
        variant_source_root(), "experiments", experiment, "MEASUREMENT.md"
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
            "rule-experiment-source/experiments/%s/workload.md" % experiment,
        ),
        (
            "measurement", "measurement", measurement_bytes,
            "rule-experiment-source/experiments/%s/MEASUREMENT.md" % experiment,
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

    handoff_file = os.path.join(CONTROL_DIR, "handoffs", "%s.json" % cycle_name)
    if not os.path.isfile(handoff_file):
        raise SystemExit("handoff record not found: %s" % handoff_file)
    with open(handoff_file, encoding="utf-8") as handle:
        handoff = json.load(handle)
    handoff_arm = next(item for item in handoff["arms"] if item["id"] == arm_id)
    manifest = {
        "schemaVersion": 2,
        "kind": "frozen-input",
        "cycle": cycle_name,
        "experiment": experiment,
        "arm": arm_id,
        "armRole": arm["role"],
        "variant": arm["variant"],
        "variantTree": arm["variantTree"],
        "subjects": [
            {"id": item["id"], "version": item["version"],
             "configIdentity": item["configIdentity"]}
            for item in handoff_arm["subjects"]
        ],
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


def run_host(argv, cwd=None, check=True):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
    if check and result.returncode != 0:
        raise SystemExit(
            "%s failed (%d): %s" % (" ".join(argv), result.returncode, result.stderr.strip())
        )
    return result


def git_host(root, *args, check=True):
    return run_host(["git", "-C", root, *args], check=check)


def managed_digest(root):
    hasher = hashlib.sha256()
    for relative in MANAGED_ITEMS:
        path = os.path.join(root, relative.replace("/", os.sep))
        if not os.path.exists(path):
            raise SystemExit("managed source is missing: %s" % path)
        files = []
        if os.path.isdir(path):
            for current, dirs, names in os.walk(path):
                dirs.sort()
                files.extend(os.path.join(current, name) for name in sorted(names))
        else:
            files.append(path)
        for filename in files:
            rel = os.path.relpath(filename, root).replace(os.sep, "/")
            hasher.update(rel.encode("utf-8") + b"\0")
            with open(filename, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    hasher.update(chunk)
            hasher.update(b"\0")
    return hasher.hexdigest()


def sync_managed(source, destination):
    for relative in MANAGED_ITEMS:
        src = os.path.join(source, relative.replace("/", os.sep))
        dest = os.path.join(destination, relative.replace("/", os.sep))
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        elif os.path.exists(dest):
            os.unlink(dest)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copytree(src, dest) if os.path.isdir(src) else shutil.copy2(src, dest)


def renderer_and_stable_tests(root):
    renderer = os.path.join(root, "bin", "rules.py")
    with tempfile.TemporaryDirectory(prefix="renderer-smoke-", dir=CONTROL_DIR) as workspace:
        run_host([sys.executable, renderer, "render", workspace], cwd=root)
        run_host([sys.executable, renderer, "verify", workspace], cwd=root)
    tests = os.path.join(root, "tests", "test_rules.py")
    if os.path.isfile(tests):
        run_host([sys.executable, tests], cwd=root)


def promotion_reasons(cycle_name, decl, review):
    reasons = []
    if review.get("schemaVersion") != 3 or review.get("cycle") != cycle_name:
        return ["review identity or schemaVersion is invalid"]
    arms = review.get("arms") or []
    control = [arm for arm in arms if arm.get("role") == "control"]
    treatment = [arm for arm in arms if arm.get("role") == "treatment"]
    if len(control) != 1 or len(treatment) != 1:
        return ["review must contain exactly one control and one treatment"]
    declared = {arm["id"]: arm["variantTree"] for arm in decl["arms"]}
    for arm in arms:
        if declared.get(arm.get("id")) != arm.get("variantTree"):
            reasons.append("variant tree differs between declaration and review for %s" % arm.get("id"))
    if any(item.get("result") == "unknown" for arm in arms for item in arm.get("criteria", [])):
        reasons.append("review contains unknown criteria")
    c = {(item["criterion"], item["text"]): item["result"] for item in control[0]["criteria"]}
    t = {(item["criterion"], item["text"]): item["result"] for item in treatment[0]["criteria"]}
    comparable = set(c) & set(t)
    if not any(t[key] == "met" and c[key] != "met" for key in comparable):
        reasons.append("no attributable effect")
    if any(c[key] == "met" and t[key] != "met" for key in comparable):
        reasons.append("review contains regression")
    if any((c.get(key) or t.get(key)) != "met" for key in set(c) ^ set(t)):
        reasons.append("incomparable criteria are not all met")
    return reasons


def promotion_path(cycle_name):
    return os.path.join(CONTROL_DIR, "promotions", "%s.json" % cycle_name)


def rollback_path(cycle_name):
    return os.path.join(CONTROL_DIR, "rollbacks", "%s.json" % cycle_name)


def promote(cycle_name):
    validate_identifier("cycle", cycle_name)
    decl = load_cycle(cycle_name)
    validate_arms(cycle_name, decl)
    if cycle_kind(decl) != "measurement":
        raise SystemExit("only a measurement cycle can be promoted")
    treatment = next(arm for arm in decl["arms"] if arm["role"] == "treatment")
    review_path = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if not os.path.isfile(review_path):
        raise SystemExit("review not found: %s" % review_path)
    with open(review_path, encoding="utf-8") as handle:
        review = json.load(handle)
    review_sha = sha256_file(review_path)
    record_path = promotion_path(cycle_name)
    source = variant_canonical_dir(decl["experiment"], treatment["variant"])
    target_digest = managed_digest(source)
    stable = stable_rules_root()
    branch = load_environment()["stableRules"]["branch"]
    old_head = git_host(stable, "rev-parse", "HEAD").stdout.strip()
    old_digest = managed_digest(stable)

    if os.path.exists(record_path):
        with open(record_path, encoding="utf-8") as handle:
            record = json.load(handle)
        validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
        if record["reviewSha256"] != review_sha or record["variantTree"] != treatment["variantTree"]:
            raise SystemExit("prepared promotion inputs drifted: %s" % cycle_name)
        if record["status"] == "promoted":
            if old_head != record["newStableCommit"]:
                raise SystemExit("stable HEAD moved after promotion: %s" % old_head)
            print("already promoted: %s" % record["newStableCommit"])
            return
        if record["status"] == "not-promoted":
            print("not promoted: %s" % "; ".join(record["reasons"]))
            return
        if old_head not in (record["oldStableCommit"], record["newStableCommit"]):
            raise SystemExit("stable HEAD does not match prepared promotion")
        if old_head == record["oldStableCommit"]:
            git_host(stable, "merge", "--ff-only", record["newStableCommit"])
        if managed_digest(stable) != record["managedDigest"]:
            raise SystemExit("stable managed digest differs from prepared promotion")
        record["status"] = "promoted"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(record_path, record)
        print("promoted: %s" % record["newStableCommit"])
        return

    reasons = promotion_reasons(cycle_name, decl, review)
    reasons.extend(verify_canonical(decl["experiment"], treatment))
    if git_host(stable, "status", "--porcelain").stdout.strip():
        reasons.append("stable worktree is dirty")
    if git_host(stable, "branch", "--show-current").stdout.strip() != branch:
        reasons.append("stable branch is not %s" % branch)
    record = {
        "schemaVersion": 1, "cycle": cycle_name,
        "recordedAt": datetime.datetime.now().astimezone().isoformat(),
        "status": "not-promoted", "reviewSha256": review_sha,
        "variantTree": treatment["variantTree"], "oldManagedDigest": old_digest,
        "managedDigest": target_digest, "oldStableCommit": old_head,
        "newStableCommit": None, "reasons": reasons,
    }
    if reasons:
        validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
        atomic_write_json(record_path, record)
        print("not promoted: %s" % "; ".join(reasons))
        return

    temporary = tempfile.mkdtemp(prefix="promotion-", dir=CONTROL_DIR)
    try:
        git_host(stable, "worktree", "add", "--detach", temporary, branch)
        try:
            sync_managed(source, temporary)
            if managed_digest(temporary) != target_digest:
                raise SystemExit("managed source digest mismatch after sync")
            renderer_and_stable_tests(temporary)
        except SystemExit as exc:
            record.update({"status": "not-promoted", "newStableCommit": None,
                           "reasons": [str(exc)]})
            validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
            atomic_write_json(record_path, record)
            print("not promoted: %s" % exc)
            return
        git_host(temporary, "add", "--", *MANAGED_ITEMS)
        if git_host(temporary, "diff", "--cached", "--quiet", check=False).returncode == 0:
            raise SystemExit("treatment source is already the stable managed source")
        git_host(temporary, "commit", "-m", "promote rule experiment %s" % cycle_name)
        new_head = git_host(temporary, "rev-parse", "HEAD").stdout.strip()
        record.update({"status": "prepared", "newStableCommit": new_head})
        validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
        atomic_write_json(record_path, record)
        git_host(stable, "merge", "--ff-only", new_head)
        if managed_digest(stable) != target_digest:
            raise SystemExit("stable managed digest differs after fast-forward")
        record["status"] = "promoted"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(record_path, record)
        print("promoted: %s" % new_head)
    finally:
        git_host(stable, "worktree", "remove", "--force", temporary, check=False)
        if os.path.isdir(temporary):
            shutil.rmtree(temporary)


def rollback(cycle_name):
    validate_identifier("cycle", cycle_name)
    record_file = promotion_path(cycle_name)
    if not os.path.isfile(record_file):
        raise SystemExit("promotion record not found: %s" % record_file)
    with open(record_file, encoding="utf-8") as handle:
        promotion = json.load(handle)
    validate_against_schema(promotion, "promotion.schema.json", "promotion %s" % cycle_name)
    if promotion["status"] != "promoted":
        raise SystemExit("cycle is not promoted: %s" % cycle_name)
    stable = stable_rules_root()
    head = git_host(stable, "rev-parse", "HEAD").stdout.strip()
    output = rollback_path(cycle_name)
    if os.path.exists(output):
        with open(output, encoding="utf-8") as handle:
            existing = json.load(handle)
        validate_against_schema(existing, "rollback.schema.json", "rollback %s" % cycle_name)
        if existing["status"] == "rolled-back":
            if head != existing["newStableCommit"]:
                raise SystemExit("stable HEAD moved after rollback")
            print("already rolled back: %s" % existing["newStableCommit"])
            return
        if head not in (existing["oldStableCommit"], existing["newStableCommit"]):
            raise SystemExit("stable HEAD does not match prepared rollback")
        if head == existing["oldStableCommit"]:
            git_host(stable, "merge", "--ff-only", existing["newStableCommit"])
        if managed_digest(stable) != existing["restoredManagedDigest"]:
            raise SystemExit("stable managed digest differs from prepared rollback")
        existing["status"] = "rolled-back"
        existing["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(output, existing)
        print("rolled back: %s" % existing["newStableCommit"])
        return
    if head != promotion["newStableCommit"]:
        raise SystemExit("stable HEAD is not the recorded promotion commit")
    if git_host(stable, "status", "--porcelain").stdout.strip():
        raise SystemExit("stable worktree is dirty")
    temporary = tempfile.mkdtemp(prefix="rollback-", dir=CONTROL_DIR)
    try:
        git_host(stable, "worktree", "add", "--detach", temporary, head)
        git_host(temporary, "revert", "--no-edit", promotion["newStableCommit"])
        if managed_digest(temporary) != promotion["oldManagedDigest"]:
            raise SystemExit("rollback did not restore the prior managed digest")
        renderer_and_stable_tests(temporary)
        new_head = git_host(temporary, "rev-parse", "HEAD").stdout.strip()
        record = {
            "schemaVersion": 1, "cycle": cycle_name,
            "recordedAt": datetime.datetime.now().astimezone().isoformat(),
            "status": "prepared", "reviewSha256": promotion["reviewSha256"],
            "variantTree": promotion["variantTree"],
            "promotionCommit": promotion["newStableCommit"],
            "oldStableCommit": head, "newStableCommit": new_head,
            "promotedManagedDigest": promotion["managedDigest"],
            "restoredManagedDigest": promotion["oldManagedDigest"],
        }
        validate_against_schema(record, "rollback.schema.json", "rollback %s" % cycle_name)
        atomic_write_json(output, record)
        git_host(stable, "merge", "--ff-only", new_head)
        record["status"] = "rolled-back"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(output, record)
        print("rolled back: %s" % new_head)
    finally:
        git_host(stable, "worktree", "remove", "--force", temporary, check=False)
        if os.path.isdir(temporary):
            shutil.rmtree(temporary)


def core_selfcheck(check_active_environment=False):
    if check_active_environment:
        load_environment()
    for name in sorted(os.listdir(SUBJECTS_DIR)):
        if name.endswith(".json"):
            load_subject(name[:-5])
    sha = "a" * 64
    tree = "b" * 40
    base = {
        "cycle": "check", "experiment": "check", "kind": "measurement",
        "subjects": ["claude-code"], "workloadHash": sha,
        "measurementHash": sha, "judgeHash": sha, "sessionContractHash": sha,
        "executionUnitHash": sha,
        "base": {"repo": ".", "commit": tree},
        "arms": [
            {"id": "c", "role": "control", "variant": "v1", "variantTree": tree},
            {"id": "t", "role": "treatment", "variant": "v2", "variantTree": tree},
        ],
    }
    validate_against_schema(base, "cycle.schema.json", "selfcheck measurement")
    invalid = dict(base)
    invalid["arms"] = base["arms"] + [
        {"id": "t2", "role": "treatment", "variant": "v3", "variantTree": tree}
    ]
    try:
        validate_against_schema(invalid, "cycle.schema.json", "selfcheck invalid measurement")
    except SystemExit:
        pass
    else:
        raise AssertionError("measurement with three arms passed schema")
    review = {
        "schemaVersion": 3, "cycle": "check",
        "arms": [
            {"id": "c", "role": "control", "variantTree": tree,
             "criteria": [{"criterion": 1, "text": "effect", "result": "not-met"}]},
            {"id": "t", "role": "treatment", "variantTree": tree,
             "criteria": [{"criterion": 1, "text": "effect", "result": "met"}]},
        ],
    }
    assert promotion_reasons("check", base, review) == []
    review["arms"][0]["criteria"][0]["result"] = "met"
    assert "no attributable effect" in promotion_reasons("check", base, review)
    review["arms"][1]["criteria"][0]["result"] = "not-met"
    assert "review contains regression" in promotion_reasons("check", base, review)
    review["arms"][1]["criteria"][0]["result"] = "unknown"
    assert "review contains unknown criteria" in promotion_reasons("check", base, review)
    arm = {"id": "c", "variant": "v1"}
    fact = {
        "tool": "claude-code", "path": "/tmp/x/projects/-tmp-arm/session.jsonl",
        "firstTimestamp": "2026-01-01T00:00:00+00:00",
        "lastTimestamp": "2026-01-01T00:01:00+00:00", "assistantCount": 1,
        "armBinding": "session-meta-cwd", "armPath": "/tmp/arm", "cwd": "/tmp/arm",
    }
    assert collect_execution_mismatches(
        arm, [fact], [(tree, "2026-01-01T00:00:30+00:00")]
    ) == []
    assert collect_execution_mismatches(
        arm, [fact], [(tree, "2026-01-01T00:02:00+00:00")]
    )
    wrong_arm = dict(fact, cwd="/tmp/other")
    assert collect_execution_mismatches(arm, [wrong_arm], [])
    unclassified = dict(fact, cwd=None)
    assert collect_execution_mismatches(arm, [unclassified], [])

    # derive_ground_truth: criterion 2 が食い違えば attributable、一致すれば
    # not-attributable、unknown が絡めば SystemExit。
    gt_record = {
        "cycle": "check",
        "arms": [
            {"role": "control", "criteria": [
                {"criterion": 1, "result": "not-met"}, {"criterion": 2, "result": "not-met"},
            ]},
            {"role": "treatment", "criteria": [
                {"criterion": 1, "result": "met"}, {"criterion": 2, "result": "met"},
            ]},
        ],
    }
    assert derive_ground_truth(gt_record)["attributable"] == "attributable"
    gt_record["arms"][1]["criteria"][1]["result"] = "not-met"
    assert derive_ground_truth(gt_record)["attributable"] == "not-attributable"
    gt_record["arms"][1]["criteria"][1]["result"] = "unknown"
    try:
        derive_ground_truth(gt_record)
    except SystemExit:
        pass
    else:
        raise AssertionError("derive_ground_truth accepted an unknown criterion result")

    # agreement_of: match / mismatch / indeterminate の3経路。
    ground_truth = {"attributable": "attributable"}
    assert agreement_of({"attributable": "attributable"}, ground_truth) == "match"
    assert agreement_of({"attributable": "not-attributable"}, ground_truth) == "mismatch"
    assert agreement_of({"attributable": "indeterminate"}, ground_truth) == "indeterminate"

    # collect_meta_readability_mismatches: 宣言と present の一致/未宣言/hash不一致。
    present = {"CONSTITUTION.md": "c" * 64}
    correct_hash = meta_readability_hash(present)
    assert collect_meta_readability_mismatches(["CONSTITUTION.md"], correct_hash, present) == []
    extra_present = dict(present, **{"TERMS.md": "d" * 64})
    undeclared = collect_meta_readability_mismatches(
        ["CONSTITUTION.md"], correct_hash, extra_present
    )
    assert any("undeclared readability on arm" in item for item in undeclared)
    hash_mismatch = collect_meta_readability_mismatches(
        ["CONSTITUTION.md"], "e" * 64, present
    )
    assert any("metaReadabilityHash" in item for item in hash_mismatch)

    print("selfcheck: ok")
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
    promote_parser = sub.add_parser("promote")
    promote_parser.add_argument("--cycle", required=True)
    rollback_parser = sub.add_parser("rollback")
    rollback_parser.add_argument("--cycle", required=True)
    args = parser.parse_args()

    if args.selfcheck:
        if args.command is not None:
            parser.error("--selfcheck cannot be combined with a subcommand")
        if args.environment:
            configure_environment(args.environment)
        return core_selfcheck(check_active_environment=args.environment is not None)
    if args.command is None:
        parser.error("a subcommand is required unless --selfcheck is used")
    if not args.environment:
        parser.error("--environment is required for commands")
    configure_environment(args.environment)

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
    elif args.command == "promote":
        promote(args.cycle)
    elif args.command == "rollback":
        rollback(args.cycle)


if __name__ == "__main__":
    sys.exit(main() or 0)
