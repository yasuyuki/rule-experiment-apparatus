#!/usr/bin/env python3
"""Claude Code subject adapter for the rule experiment protocol."""

import glob
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys


MANAGED_ITEMS = ("rules", "placement.json", "bin/rules.py")
CREDENTIALS = (".credentials.json", ".claude.json")
PHASE_RE = re.compile(r"^\.claude/plan-phases/[^/]+/phase-[^/]*\.md$")
SKILL_NAME_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")
EVIDENCE_KIND = "rule-experiment-evidence-v1"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def managed_digest(root):
    digest = hashlib.sha256()
    for relative in MANAGED_ITEMS:
        path = os.path.join(root, relative)
        files = []
        if os.path.isdir(path):
            for current, dirs, names in os.walk(path):
                dirs.sort()
                files.extend(os.path.join(current, name) for name in sorted(names))
        elif os.path.isfile(path):
            files.append(path)
        else:
            raise SystemExit("managed source is missing: %s" % path)
        for filename in files:
            name = os.path.relpath(filename, root).replace(os.sep, "/")
            digest.update(name.encode("utf-8") + b"\0")
            with open(filename, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
            digest.update(b"\0")
    return digest.hexdigest()


def config_digest(root):
    digest = hashlib.sha256()
    for current, dirs, names in os.walk(root):
        if current == root:
            dirs[:] = sorted(name for name in dirs if name not in ("projects", "sessions"))
        else:
            dirs.sort()
        for name in sorted(names):
            relative = os.path.relpath(os.path.join(current, name), root).replace(os.sep, "/")
            if relative in CREDENTIALS:
                continue
            path = os.path.join(current, name)
            digest.update(relative.encode("utf-8") + b"\0")
            if os.path.islink(path):
                digest.update(os.readlink(path).encode("utf-8"))
            else:
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(65536), b""):
                        digest.update(chunk)
            digest.update(b"\0")
    return digest.hexdigest()


def profile(raw):
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as error:
        raise SystemExit("invalid Claude adapter profile: %s" % error)
    required = {"binary", "configTemplate", "credentialSources", "launchPrefix"}
    if not isinstance(value, dict) or set(value) != required:
        raise SystemExit("Claude adapter profile must contain only %s" % ", ".join(sorted(required)))
    if not all(
        isinstance(value[key], str) and value[key]
        for key in ("binary", "configTemplate", "launchPrefix")
    ):
        raise SystemExit("Claude adapter profile values must be non-empty strings")
    sources = value["credentialSources"]
    if (
        not isinstance(sources, dict) or set(sources) != set(CREDENTIALS)
        or not all(isinstance(sources[name], str) and sources[name] for name in CREDENTIALS)
    ):
        raise SystemExit("Claude adapter credentialSources must contain only %s" % ", ".join(CREDENTIALS))
    for key in ("binary", "configTemplate"):
        value[key] = os.path.expanduser(value[key])
        if not os.path.isabs(value[key]):
            raise SystemExit("Claude adapter profile %s must be absolute or home-relative" % key)
    for name in CREDENTIALS:
        sources[name] = os.path.expanduser(sources[name])
        if not os.path.isabs(sources[name]):
            raise SystemExit("Claude adapter credential source %s must be absolute or home-relative" % name)
        sources[name] = os.path.realpath(sources[name])
    return value


def run(argv, cwd=None, check=True, env=None):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True,
                            encoding="utf-8", errors="replace", env=env)
    if check and result.returncode:
        raise SystemExit("%s failed: %s" % (" ".join(argv), result.stderr.strip()))
    return result


def git(root, *args, check=True):
    return run(["git", "-C", root, *args], check=check)


def renderer(variant, operation, workspace, check=True):
    return run([sys.executable, os.path.join(variant, "bin", "rules.py"), operation, workspace],
               check=check)


def placements(workspace):
    root = os.path.join(workspace, ".claude", "rules")
    output = []
    for current, dirs, names in os.walk(root):
        dirs.sort()
        for name in sorted(names):
            path = os.path.join(current, name)
            output.append({
                "path": os.path.relpath(path, workspace).replace(os.sep, "/"),
                "sha256": sha256_file(path),
            })
    if not output:
        raise SystemExit("Claude adapter placed no rules")
    return output


def verify_credential_links(config_root, sources):
    for name in CREDENTIALS:
        path = os.path.join(config_root, name)
        source = sources[name]
        # Claude Code atomically replaces these symlinks with regular files.
        if not os.path.islink(path) and os.path.isfile(path):
            shutil.copyfile(path, source)
            os.remove(path)
            os.symlink(source, path)
        if not os.path.islink(path) or os.readlink(path) != source:
            raise SystemExit("Claude credential link changed: %s" % name)


def verify_subscription(settings, config_root):
    environment = os.environ.copy()
    environment["CLAUDE_CONFIG_DIR"] = config_root
    result = run([settings["binary"], "auth", "status", "--json"], check=False, env=environment)
    try:
        status = json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        status = None
    if (
        not isinstance(status, dict) or status.get("loggedIn") is not True
        or status.get("authMethod") != "claude.ai" or not status.get("subscriptionType")
    ):
        raise SystemExit("Claude subscription authentication is unavailable")


def prepare(payload, identity):
    settings = profile(payload["profile"])
    workspace = payload["workspace"]
    config_root = payload["configRoot"]
    variant = payload["variant"]["path"]
    actual_digest = managed_digest(variant)
    if actual_digest != payload["variant"]["digest"]:
        raise SystemExit("variant digest mismatch")
    if os.path.lexists(config_root):
        if not os.path.isdir(config_root) or config_digest(config_root) != config_digest(
            settings["configTemplate"]
        ):
            raise SystemExit("config root differs from template: %s" % config_root)
    else:
        shutil.copytree(
            settings["configTemplate"], config_root, symlinks=True,
            ignore=shutil.ignore_patterns(*CREDENTIALS, "projects", "sessions"),
        )
        for name in CREDENTIALS:
            source = settings["credentialSources"][name]
            if not os.path.exists(source):
                raise SystemExit("credential source is missing: %s" % name)
            os.symlink(source, os.path.join(config_root, name))
    verify_credential_links(config_root, settings["credentialSources"])
    verify_subscription(settings, config_root)
    verify_credential_links(config_root, settings["credentialSources"])
    claim_project_directory(config_root, workspace)

    renderer(variant, "render", workspace)
    marker = "[rule-experiment-loaded:%s]" % payload["cycle"]
    probe = os.path.join(workspace, ".claude", "rules", "apparatus-probe.md")
    os.makedirs(os.path.dirname(probe), exist_ok=True)
    with open(probe, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("# Apparatus probe\n\nこのセッション中の応答のどれかに `%s` を1回以上出力する。\n" % marker)
    renderer(variant, "verify", workspace)

    version = run([settings["binary"], "--version"], check=False)
    subject_version = (version.stdout or version.stderr).strip().splitlines()
    # Declared read-only trees the workload must reach. Claude Code confines reads to
    # the working directory unless the extra roots are named at launch.
    extra = "".join(
        " --add-dir %s" % shlex.quote(material["path"]) for material in payload.get("materials", [])
    )
    inner = "cd %s && CLAUDE_CONFIG_DIR=%s %s%s" % (
        tuple(shlex.quote(value) for value in (workspace, config_root, settings["binary"])) + (extra,)
    )
    return {
        "protocolVersion": 1,
        "adapterIdentity": identity,
        "subjectVersion": subject_version[0] if subject_version else "unknown",
        "configIdentity": config_digest(config_root),
        "variantDigest": actual_digest,
        "placements": placements(workspace),
        "launch": "%s %s" % (settings["launchPrefix"], shlex.quote(inner)),
        "token": {
            "workspace": workspace,
            "configRoot": config_root,
            "variantPath": variant,
            "baseHead": git(workspace, "rev-parse", "HEAD").stdout.strip(),
            "marker": marker,
        },
    }


def phase_path(workspace, value):
    if not isinstance(value, str) or not value:
        return None
    candidate = value.replace("\\", "/")
    root = workspace.replace("\\", "/").rstrip("/") + "/"
    if candidate.startswith(root):
        candidate = candidate[len(root):]
    while candidate.startswith("./"):
        candidate = candidate[2:]
    return candidate if PHASE_RE.fullmatch(candidate) else None


def add_usage(total, value):
    """Accumulate the numeric leaves of Claude's nested message.usage object."""
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        if not isinstance(key, str):
            continue
        if isinstance(child, dict):
            nested = total.get(key)
            if not isinstance(nested, dict):
                nested = {}
                total[key] = nested
            add_usage(nested, child)
        elif (
            isinstance(child, (int, float))
            and not isinstance(child, bool)
            and math.isfinite(child)
        ):
            existing = total.get(key, 0)
            total[key] = (existing if isinstance(existing, (int, float)) else 0) + child


def session_path(config_root, path):
    return os.path.relpath(path, config_root).replace(os.sep, "/")


def project_directory(config_root, workspace):
    name = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(workspace))
    return os.path.join(config_root, "projects", name)


def claim_project_directory(config_root, workspace):
    root = project_directory(config_root, workspace)
    os.makedirs(root, exist_ok=True)
    marker = os.path.join(root, ".rule-experiment-workspace")
    identity = hashlib.sha256(os.path.abspath(workspace).encode("utf-8")).hexdigest()
    if os.path.lexists(marker):
        with open(marker, encoding="utf-8") as handle:
            if handle.read() != identity + "\n":
                raise SystemExit("Claude project directory collision between workspaces")
    else:
        with open(marker, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(identity + "\n")


def redact_paths(text, paths):
    for path in sorted({path for path in paths if path}, key=len, reverse=True):
        text = text.replace(path, "[redacted-path]")
        text = text.replace(path.replace(os.sep, "/"), "[redacted-path]")
    return text


def transcript_evidence(config_root, workspace, marker):
    documents, skills = {}, {}
    assistant_count = marker_count = tool_use_count = 0
    usage, session_records = {}, []
    paths = sorted(glob.glob(
        os.path.join(project_directory(config_root, workspace), "**", "*.jsonl"), recursive=True
    ))
    for path in paths:
        first_timestamp = last_timestamp = None
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(item, dict):
                    continue
                timestamp = item.get("timestamp")
                if isinstance(timestamp, str) and timestamp:
                    if first_timestamp is None:
                        first_timestamp = timestamp
                    last_timestamp = timestamp
                if item.get("type") != "assistant":
                    continue
                assistant_count += 1
                message = item.get("message")
                if not isinstance(message, dict):
                    continue
                add_usage(usage, message.get("usage"))
                content = message.get("content")
                if isinstance(content, str):
                    marker_count += content.count(marker)
                    continue
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text" and isinstance(block.get("text"), str):
                        marker_count += block["text"].count(marker)
                        continue
                    if block.get("type") != "tool_use":
                        continue
                    tool_use_count += 1
                    if not isinstance(block.get("input"), dict):
                        continue
                    args = block["input"]
                    if block.get("name") == "Skill":
                        # A rule reaches the subject by being in context; a skill only
                        # reaches it when the subject invokes it. Without this count,
                        # "the skill changed nothing" and "the skill never ran" are the
                        # same observation. The name is subject-supplied, so only a bare
                        # identifier is kept and everything else is dropped.
                        name = args.get("skill")
                        if isinstance(name, str) and SKILL_NAME_RE.fullmatch(name):
                            skills[name] = skills.get(name, 0) + 1
                        continue
                    relative = phase_path(workspace, args.get("file_path"))
                    if relative is None:
                        continue
                    if block.get("name") == "Write" and isinstance(args.get("content"), str):
                        documents[relative] = args["content"]
                    elif block.get("name") == "Edit" and relative in documents:
                        old, new = args.get("old_string"), args.get("new_string")
                        if isinstance(old, str) and isinstance(new, str) and old in documents[relative]:
                            documents[relative] = documents[relative].replace(old, new, 1)
        session_records.append({
            "path": session_path(config_root, path),
            "firstTimestamp": first_timestamp,
            "lastTimestamp": last_timestamp,
        })
    return session_records, assistant_count, marker_count, tool_use_count, documents, skills, usage


def git_shortstat(root, base_head):
    output = git(root, "diff", "--shortstat", "%s..HEAD" % base_head).stdout
    fields = {"files": 0, "insertions": 0, "deletions": 0}
    for name, pattern in (
        ("files", r"(\d+) files? changed"),
        ("insertions", r"(\d+) insertions?\(\+\)"),
        ("deletions", r"(\d+) deletions?\(-\)"),
    ):
        match = re.search(pattern, output)
        if match:
            fields[name] = int(match.group(1))
    return fields


def collect(payload, identity):
    token = payload["token"]
    if payload["workspace"] != token.get("workspace"):
        raise SystemExit("workspace differs from prepare token")
    workspace, config_root = token["workspace"], token["configRoot"]
    settings = profile(payload["profile"])
    verify_credential_links(config_root, settings["credentialSources"])
    sessions, assistants, markers, tool_uses, documents, skills, usage = transcript_evidence(
        config_root, workspace, token["marker"]
    )
    private_paths = [config_root] + list(settings["credentialSources"].values())
    documents = {
        path: redact_paths(content, private_paths)
        for path, content in documents.items()
    }
    clean = not git(workspace, "status", "--porcelain").stdout.strip()
    commits = int(git(workspace, "rev-list", "--count", "%s..HEAD" % token["baseHead"]).stdout)
    verified = renderer(token["variantPath"], "verify", workspace, check=False).returncode == 0
    evidence = {
        "kind": EVIDENCE_KIND,
        "sessions": sessions,
        "assistantCount": assistants,
        "toolUseCount": tool_uses,
        "markerCount": markers,
        "phaseDocuments": documents,
        "skillInvocations": skills,
        "usage": usage,
        "shortstat": git_shortstat(workspace, token["baseHead"]),
        "clean": clean,
        "commitsAfterBase": commits,
    }
    return {
        "protocolVersion": 1,
        "adapterIdentity": identity,
        "success": bool(sessions) and assistants > 0 and clean and commits >= 2,
        "ruleLoaded": verified and markers > 0,
        "evidence": evidence,
    }


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("prepare", "collect"):
        raise SystemExit("usage: claude_code.py prepare|collect")
    payload = json.load(sys.stdin)
    if payload.get("protocolVersion") != 1:
        raise SystemExit("unsupported protocol version")
    identity = sha256_file(os.path.abspath(__file__))
    result = prepare(payload, identity) if sys.argv[1] == "prepare" else collect(payload, identity)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
