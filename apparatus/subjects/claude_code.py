#!/usr/bin/env python3
"""Claude Code subject adapter for the rule experiment protocol."""

import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys


MANAGED_ITEMS = ("rules", "placement.json", "bin/rules.py")
CREDENTIALS = (".credentials.json", ".claude.json")
PHASE_RE = re.compile(r"^\.claude/plan-phases/[^/]+/phase-[^/]*\.md$")
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
        if not os.path.islink(path) or os.readlink(path) != sources[name]:
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
        raise SystemExit("config root already exists: %s" % config_root)
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


def transcript_evidence(config_root, workspace, marker):
    documents = {}
    assistant_count = marker_count = 0
    sessions = sorted(glob.glob(os.path.join(config_root, "projects", "*", "*.jsonl")))
    for path in sessions:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(item, dict) or item.get("type") != "assistant":
                    continue
                assistant_count += 1
                content = (item.get("message") or {}).get("content")
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
                    if block.get("type") != "tool_use" or not isinstance(block.get("input"), dict):
                        continue
                    args = block["input"]
                    relative = phase_path(workspace, args.get("file_path"))
                    if relative is None:
                        continue
                    if block.get("name") == "Write" and isinstance(args.get("content"), str):
                        documents[relative] = args["content"]
                    elif block.get("name") == "Edit" and relative in documents:
                        old, new = args.get("old_string"), args.get("new_string")
                        if isinstance(old, str) and isinstance(new, str) and old in documents[relative]:
                            documents[relative] = documents[relative].replace(old, new, 1)
    return sessions, assistant_count, marker_count, documents


def collect(payload, identity):
    token = payload["token"]
    if payload["workspace"] != token.get("workspace"):
        raise SystemExit("workspace differs from prepare token")
    workspace, config_root = token["workspace"], token["configRoot"]
    settings = profile(payload["profile"])
    verify_credential_links(config_root, settings["credentialSources"])
    sessions, assistants, markers, documents = transcript_evidence(
        config_root, workspace, token["marker"]
    )
    clean = not git(workspace, "status", "--porcelain").stdout.strip()
    commits = int(git(workspace, "rev-list", "--count", "%s..HEAD" % token["baseHead"]).stdout)
    verified = renderer(token["variantPath"], "verify", workspace, check=False).returncode == 0
    evidence = json.dumps({
        "kind": EVIDENCE_KIND,
        "assistantCount": assistants,
        "markerCount": markers,
        "phaseDocuments": documents,
        "sessionCount": len(sessions),
        "clean": clean,
        "commitsAfterBase": commits,
    }, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return {
        "protocolVersion": 1,
        "adapterIdentity": identity,
        "success": bool(sessions) and assistants > 0 and clean and commits >= 2,
        "ruleLoaded": verified and markers > 0,
        "evidence": [evidence],
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
