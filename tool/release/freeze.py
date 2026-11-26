#!/usr/bin/env python3
"""Freeze and check the release identity of the judged #BuildHybridAI build.

    python3 tool/release/freeze.py REF [--apk PATH] [--defines FILE]
                                       [--tag NAME] [--output PATH]

REF is a commit or tag. The script checks, in order:

1. REF resolves to one full commit SHA in this checkout.
2. That commit is on `main` on GitHub (`gh api .../compare`).
3. CI was green for it on `main`: the latest push run of every required
   workflow succeeded, including the deploy job (`gh run list`, `gh run view`).
4. The build defines pass `tool/check_build_config.sh --judged`. They are
   rebuilt from the repository variables exactly as the deploy job builds them
   (with the workflow's defaults), or read from --defines FILE.
5. The hosted `/version.json` serves this commit from `main`, with the same
   LIVE_BACKEND, DINNER_MODE and CLOUD_ROUTES as those defines.
6. With --apk, the APK's SHA-256 (and, if JUDGES.md already lists one, that
   they agree).
7. The device prerequisites, read from docs/buildhybridai/JUDGES.md at the
   frozen commit.

It writes docs/buildhybridai/RELEASE-IDENTITY.md only when every check
passed; otherwise it prints what failed and exits 1 without writing.

Read-only against production: it never deploys, never pushes, and only reads
GitHub and the hosted site. It creates an annotated tag only with --tag, and
only locally, after every check passed; pushing it stays a human step.
It never prints secrets: gh and git stderr is not echoed, and of the
repository variables only the four non-secret build keys are read.

Exit codes: 0 frozen, 1 a check failed, 2 bad usage.
"""

import argparse
import datetime
import hashlib
import http.client
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REPO = "terryhh/SousSight"
DEFAULT_HOSTED_URL = "https://devfest-flutter-a59e8.web.app"
DEFAULT_OUTPUT = "docs/buildhybridai/RELEASE-IDENTITY.md"
JUDGES_PATH = "docs/buildhybridai/JUDGES.md"
CHECK_BUILD_CONFIG = ROOT / "tool/check_build_config.sh"
TAG_MESSAGE = "#BuildHybridAI 2026 entry"

# Workflows that must have succeeded for the frozen commit on main, and the
# jobs inside them that must have run and succeeded (a skipped deploy job
# still leaves the run green, so it is checked by name).
REQUIRED_WORKFLOWS = (
    ("Validate and deploy SousSight", ("Tests and rehearsal build", "Deploy production")),
    ("Secret scan", ()),
)

# The judged build defines as the deploy job in .github/workflows/firebase.yml
# writes them: `vars.X || default`. A test keeps these defaults in sync.
WORKFLOW_DEFAULTS = {
    "DINNER_MODE": "simulated",
    "LIVE_BACKEND": "none",
    "CLOUD_ROUTES": "",
    "RESEARCH_MODEL": "gemini-3.8-flash",
}
# Keys stamped into the hosted version.json by tool/check_web_bundle.sh.
CONFIG_KEYS = ("LIVE_BACKEND", "DINNER_MODE", "CLOUD_ROUTES")

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
MAX_VERSION_JSON_BYTES = 64 * 1024
COMMAND_TIMEOUT = 60

PASS, FAIL, NOT_RUN, RECORDED, WARN = "PASS", "FAIL", "NOT RUN", "RECORDED", "WARN"
BLANK = "__________"


class FreezeError(Exception):
    """A check could not complete. The message never contains command output."""


class UsageError(Exception):
    pass


class Check:
    """One line of the report. Starts NOT RUN; only code that verified something sets PASS."""

    def __init__(self, key, title):
        self.key, self.title = key, title
        self.status, self.detail = NOT_RUN, "not run"

    def set(self, status, detail):
        self.status, self.detail = status, detail

    @property
    def ok(self):
        return self.status in (PASS, RECORDED)


# --------------------------------------------------------------------------
# Commands and HTTP, injectable for tests.


def run_command(argv, runner, *, cwd=None):
    """Run argv (never through a shell). Returns the CompletedProcess."""
    try:
        return runner(argv, capture_output=True, text=True, timeout=COMMAND_TIMEOUT,
                      check=False, cwd=cwd)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise FreezeError(f"{argv[0]} {argv[1]} did not complete; check the CLI and network.") from error


def command_failed(argv, result):
    # Never echo stderr: it can carry tokens, URLs with credentials or values.
    sub = " ".join(argv[1:3]) if len(argv) > 2 else argv[1]
    return FreezeError(f"`{argv[0]} {sub}` failed (exit {result.returncode}).")


def fetch_https(url, *, timeout=20):
    """GET url and return (status, body bytes). Body is capped."""
    request = urllib.request.Request(url, headers={
        "Cache-Control": "no-cache", "User-Agent": "soussight-release-freeze"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 (https only, checked)
            if not response.geturl().startswith("https://"):
                raise FreezeError("the hosted site redirected away from https; not read.")
            return response.status, response.read(MAX_VERSION_JSON_BYTES + 1)
    except urllib.error.HTTPError as error:
        error.close()
        return error.code, b""
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
        raise FreezeError("could not reach the hosted site; check the network.") from error


def cell(value):
    """Make a value safe for one Markdown table cell or list item."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value)).strip()
    return text.replace("|", "\\|") or "(empty)"


def code(value):
    text = cell(value).replace("`", "'")
    return f"`{text}`"


# --------------------------------------------------------------------------
# JUDGES.md parsing.


def strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def section(text, heading_re, level):
    """Return the body under the first heading matching heading_re, up to the next heading of <= level."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        match = re.match(r"^(#{1,6})\s+(.*)$", line)
        if not match:
            continue
        depth = len(match.group(1))
        if start is None:
            if depth == level and re.search(heading_re, match.group(2)):
                start = index + 1
        elif depth <= level:
            return "\n".join(lines[start:index])
    return None if start is None else "\n".join(lines[start:])


def bullets(text):
    """Top-level `- ` bullets with their indented continuation lines, comments removed."""
    items, current = [], None
    for line in strip_comments(text).splitlines():
        if line.startswith("- "):
            current = [line[2:].strip()]
            items.append(current)
        elif current is not None and line.startswith("  ") and line.strip():
            current.append(line.strip())
        else:
            current = None
    return [" ".join(" ".join(item).split()) for item in items if " ".join(item).strip()]


def device_prerequisites(judges):
    """Return ({platform: [prerequisite, ...]}, [problem, ...]) from JUDGES.md text."""
    problems, found = [], {}
    web = section(judges, r"Turn on Chrome", 2)
    if web is None:
        problems.append("JUDGES.md has no '## … Turn on Chrome …' section")
    else:
        before_steps = re.split(r"^Steps:\s*$", web, maxsplit=1, flags=re.M)[0]
        browser = [item for item in bullets(section(judges, r"Open the app", 2) or "")
                   if item.startswith("**Best experience:**")]
        found["Web (desktop Chrome)"] = browser + bullets(before_steps)
        if not found["Web (desktop Chrome)"]:
            problems.append("JUDGES.md's Chrome section lists no prerequisites")
    for name in ("Android", "iOS"):
        body = section(judges, rf"^{name}\b", 3)
        if body is None:
            if re.search(rf"{name} is not part of this entry", judges):
                found[name] = ["Not part of this entry (per JUDGES.md)."]
            else:
                problems.append(f"JUDGES.md has no '### {name}' section and does not say it is out")
            continue
        # The Android APK link is release identity, not a device prerequisite.
        items = [item for item in bullets(body) if not item.startswith("**APK:**")]
        found[name] = items
        if not items:
            problems.append(f"JUDGES.md's {name} section lists no prerequisites")
    return found, problems


def judges_open_items(judges):
    verify = len(re.findall(r"<!--\s*VERIFY", judges))
    placeholders = sorted(set(re.findall(r"<(?:HOSTED_URL|APK_URL|APK_SHA256|FINAL_TAG)>", judges)))
    return verify, placeholders


def judges_apk_sha(judges):
    android = section(judges, r"^Android\b", 3) or ""
    match = re.search(r"SHA-256\s*`([0-9a-fA-F]{64})`", strip_comments(android))
    return match.group(1).lower() if match else None


# --------------------------------------------------------------------------
# The freeze.


class Freezer:
    def __init__(self, *, repo=DEFAULT_REPO, hosted_url=DEFAULT_HOSTED_URL, root=ROOT,
                 runner=subprocess.run, fetch=fetch_https, now=None, output=print):
        self.repo = repo
        self.hosted_url = hosted_url.rstrip("/")
        self.root = Path(root)
        self.runner = runner
        self.fetch = fetch
        self.now = now or (lambda: datetime.datetime.now(datetime.timezone.utc))
        self.output = output
        self.checks = {key: Check(key, title) for key, title in (
            ("ref", "Ref resolves to one commit"),
            ("main", "Commit is on main"),
            ("ci", "CI green on main for this commit"),
            ("config", "Build defines pass check_build_config.sh --judged"),
            ("hosted", "Hosted version.json matches commit and config"),
            ("apk", "Release APK SHA-256"),
            ("devices", "Device prerequisites from JUDGES.md"),
            ("docs", "JUDGES.md placeholders and VERIFY comments"),
            ("tag", "Annotated tag"),
        )}
        self.facts = {}
        self.devices = {}

    # -- commands ---------------------------------------------------------

    def git(self, *args):
        argv = ["git", *args]
        result = run_command(argv, self.runner, cwd=self.root)
        if result.returncode:
            raise command_failed(argv, result)
        return result.stdout

    def gh_json(self, *args):
        argv = ["gh", *args]
        result = run_command(argv, self.runner, cwd=self.root)
        if result.returncode:
            raise command_failed(argv, result)
        try:
            return json.loads(result.stdout)
        except (TypeError, ValueError) as error:
            raise FreezeError(f"`gh {args[0]}` returned invalid JSON.") from error

    # -- checks -------------------------------------------------------------

    def resolve(self, ref):
        check = self.checks["ref"]
        if not ref or ref.startswith("-") or any(c.isspace() for c in ref):
            raise UsageError("REF must be a commit or tag name, not an option.")
        result = run_command(["git", "rev-parse", "--verify", "--quiet", "--end-of-options",
                              f"{ref}^{{commit}}"], self.runner, cwd=self.root)
        sha = result.stdout.strip() if result.returncode == 0 else ""
        if not SHA_RE.match(sha):
            check.set(FAIL, f"{code(ref)} does not resolve to a commit in this checkout (fetch tags and main first)")
            return None
        tag = run_command(["git", "rev-parse", "--verify", "--quiet", "--end-of-options",
                           f"refs/tags/{ref}"], self.runner, cwd=self.root)
        self.facts["ref_is_tag"] = tag.returncode == 0 and bool(tag.stdout.strip())
        self.facts.update(ref=ref, sha=sha)
        check.set(PASS, f"{code(ref)} is {code(sha)}" + (" (tag)" if self.facts["ref_is_tag"] else ""))
        return sha

    def check_main(self, sha):
        check = self.checks["main"]
        tip = self.gh_json("api", f"repos/{self.repo}/commits/main", "--jq", "{sha: .sha}")
        compare = self.gh_json("api", f"repos/{self.repo}/compare/{sha}...main", "--jq",
                               "{status: .status, ahead_by: .ahead_by, behind_by: .behind_by}")
        tip_sha = tip.get("sha") if isinstance(tip, dict) else None
        status = compare.get("status") if isinstance(compare, dict) else None
        if not isinstance(tip_sha, str) or not SHA_RE.match(tip_sha) or status is None:
            check.set(FAIL, "GitHub returned an unexpected shape for main or the comparison")
            return
        self.facts["main_tip"] = tip_sha
        if status not in ("identical", "ahead"):
            check.set(FAIL, f"{code(sha)} is not on main (GitHub compare status {code(status)})")
            return
        ahead = compare.get("ahead_by") if status == "ahead" else 0
        if tip_sha == sha:
            check.set(PASS, f"{code(sha)} is the tip of main")
        else:
            check.set(PASS, f"{code(sha)} is on main; main has {ahead} newer commit(s), tip {code(tip_sha)}")

    def check_ci(self, sha):
        check = self.checks["ci"]
        runs = self.gh_json("run", "list", "-R", self.repo, "--commit", sha, "--limit", "100", "--json",
                            "databaseId,workflowName,status,conclusion,event,headBranch,headSha,createdAt")
        if not isinstance(runs, list):
            check.set(FAIL, "`gh run list` returned an unexpected shape")
            return
        problems, passed = [], []
        for workflow, jobs in REQUIRED_WORKFLOWS:
            candidates = [run for run in runs if isinstance(run, dict)
                          and run.get("workflowName") == workflow
                          and run.get("headSha") == sha
                          and run.get("headBranch") == "main"
                          and run.get("event") in ("push", "workflow_dispatch")]
            if not candidates:
                problems.append(f"no {workflow!r} run on main for this commit")
                continue
            latest = max(candidates, key=lambda run: str(run.get("createdAt") or ""))
            run_id = latest.get("databaseId")
            if latest.get("status") != "completed":
                problems.append(f"{workflow!r} run {run_id} is {latest.get('status')}, not completed")
                continue
            if latest.get("conclusion") != "success":
                problems.append(f"{workflow!r} run {run_id} concluded {latest.get('conclusion')}")
                continue
            if jobs:
                view = self.gh_json("run", "view", str(run_id), "-R", self.repo, "--json", "jobs")
                listed = view.get("jobs") if isinstance(view, dict) else None
                if not isinstance(listed, list):
                    problems.append(f"{workflow!r} run {run_id} returned no job list")
                    continue
                by_name = {job.get("name"): job for job in listed if isinstance(job, dict)}
                missing = [name for name in jobs if by_name.get(name, {}).get("conclusion") != "success"]
                if missing:
                    detail = ", ".join(
                        f"{name!r} {by_name[name].get('conclusion') or by_name[name].get('status')}"
                        if name in by_name else f"{name!r} missing" for name in missing)
                    problems.append(f"{workflow!r} run {run_id}: {detail}")
                    continue
            passed.append(f"{workflow} run {run_id} succeeded")
        if problems:
            check.set(FAIL, "; ".join(problems))
        else:
            check.set(PASS, "; ".join(passed))
            self.facts["ci_runs"] = passed

    def expected_defines(self, defines_path):
        """The judged build's defines: from --defines, or rebuilt from repository variables."""
        if defines_path:
            try:
                data = json.loads(Path(defines_path).read_text(encoding="utf-8"))
            except OSError as error:
                raise FreezeError(f"could not read --defines {defines_path}") from error
            except ValueError as error:
                raise FreezeError("--defines is not valid JSON") from error
            if not isinstance(data, dict):
                raise FreezeError("--defines must be a JSON object")
            self.facts["defines_source"] = f"file {Path(defines_path).name}"
            # Only the keys the freeze needs; the rest of the file is never read further.
            defines = {}
            for key in ("FAKE_BACKEND", "APPCHECK_DEBUG_TOKEN", *WORKFLOW_DEFAULTS):
                value = data.get(key)
                if value is None:
                    continue
                defines[key] = ("true" if value else "false") if isinstance(value, bool) else str(value)
            return defines
        listed = self.gh_json("variable", "list", "-R", self.repo, "--json", "name,value")
        if not isinstance(listed, list):
            raise FreezeError("`gh variable list` returned an unexpected shape")
        # Keep only the non-secret build keys; drop every other variable unread.
        values = {}
        for item in listed:
            if isinstance(item, dict) and item.get("name") in WORKFLOW_DEFAULTS:
                values[item["name"]] = item.get("value")
        defines = {"FAKE_BACKEND": "false"}
        defaulted = []
        for key, default in WORKFLOW_DEFAULTS.items():
            value = values.get(key)
            # GitHub's `vars.X || 'default'` also falls back on an empty value.
            if value in (None, ""):
                defaulted.append(key)
                value = default
            defines[key] = str(value)
        self.facts["defines_source"] = "repository variables" + (
            f" (workflow defaults for {', '.join(defaulted)})" if defaulted else "")
        return defines

    def check_config(self, defines):
        check = self.checks["config"]
        with tempfile.TemporaryDirectory(prefix="soussight-freeze-") as tmp:
            path = Path(tmp, "judged_defines.json")
            path.write_text(json.dumps(defines), encoding="utf-8")
            argv = [str(CHECK_BUILD_CONFIG), "--judged", str(path)]
            result = run_command(argv, self.runner, cwd=self.root)
        # check_build_config.sh prints only non-secret keys, and reduces the
        # debug token to "set"; its lines are safe to show. The temp path is not.
        lines = [line.replace(str(path), "<defines>") for line in
                 (result.stdout or "").splitlines() if line.strip()]
        if result.returncode == 0:
            check.set(PASS, lines[-1] if lines else "accepted")
            self.facts["research_model"] = defines.get("RESEARCH_MODEL")
        else:
            errors = [line.removeprefix("::error::") for line in lines if line.startswith("::error::")]
            check.set(FAIL, "; ".join(errors) or f"check_build_config.sh exited {result.returncode}")

    def check_hosted(self, sha, defines):
        check = self.checks["hosted"]
        url = f"{self.hosted_url}/version.json?freeze={sha[:12]}"
        status, body = self.fetch(url)
        self.facts["hosted_url"] = self.hosted_url
        if status != 200:
            check.set(FAIL, f"{self.hosted_url}/version.json returned HTTP {status}")
            return
        if len(body) > MAX_VERSION_JSON_BYTES:
            check.set(FAIL, "version.json is larger than expected; not parsed")
            return
        try:
            version = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            check.set(FAIL, "version.json is not valid JSON")
            return
        if not isinstance(version, dict):
            check.set(FAIL, "version.json is not a JSON object")
            return
        problems = []
        served = version.get("commit")
        if served != sha:
            problems.append(f"serves commit {code(served if isinstance(served, str) else repr(served))}, "
                            f"not {code(sha)}")
        if version.get("ref") != "main":
            problems.append(f"ref is {code(version.get('ref'))}, not `main`")
        config = version.get("config")
        if not isinstance(config, dict):
            problems.append("has no config object")
            config = {}
        hosted_config = {}
        for key in CONFIG_KEYS:
            value = config.get(key)
            expected = defines.get(key, "")
            if key == "LIVE_BACKEND":
                expected = expected or "none"  # check_web_bundle.sh stamps an empty value as none
            if not isinstance(value, str):
                problems.append(f"config.{key} is missing")
                continue
            hosted_config[key] = value
            if value != expected:
                problems.append(f"config.{key} is {code(value)}, build defines say {code(expected)}")
        self.facts["hosted"] = {
            "commit": served if isinstance(served, str) else None,
            "ref": version.get("ref") if isinstance(version.get("ref"), str) else None,
            "version": "+".join(str(version.get(k)) for k in ("version", "build_number")
                                if isinstance(version.get(k), (str, int))),
            "config": hosted_config,
        }
        if problems:
            check.set(FAIL, "version.json " + "; ".join(problems))
        else:
            check.set(PASS, f"serves {code(sha)} from main with "
                      + ", ".join(f"{key}={code(hosted_config[key])}" for key in CONFIG_KEYS))

    def check_apk(self, apk, judges):
        check = self.checks["apk"]
        if not apk:
            check.set(NOT_RUN, "no --apk given (needed only if gate G4 passed)")
            return
        path = Path(apk)
        if not path.is_file():
            check.set(FAIL, f"APK not found: {code(apk)}")
            return
        digest, size = hashlib.sha256(), 0
        try:
            with path.open("rb") as handle:
                head = handle.read(4)
                digest.update(head)
                size += len(head)
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
                    size += len(chunk)
        except OSError:
            check.set(FAIL, f"{code(path.name)} could not be read")
            return
        if head != b"PK\x03\x04":
            check.set(FAIL, f"{code(path.name)} is not an APK (no zip header)")
            return
        sha256 = digest.hexdigest()
        listed = judges_apk_sha(judges) if judges is not None else None
        if listed and listed != sha256:
            check.set(FAIL, f"{code(path.name)} SHA-256 {code(sha256)} differs from JUDGES.md {code(listed)}")
            return
        self.facts["apk"] = {"name": path.name, "sha256": sha256, "size": size}
        check.set(RECORDED, f"{code(path.name)} {size} bytes, SHA-256 {code(sha256)}"
                  + (" (matches JUDGES.md)" if listed else ""))

    def read_judges(self, sha):
        result = run_command(["git", "show", f"{sha}:{JUDGES_PATH}"], self.runner, cwd=self.root)
        if result.returncode:
            return None
        blob = run_command(["git", "rev-parse", f"{sha}:{JUDGES_PATH}"], self.runner, cwd=self.root)
        if blob.returncode == 0 and SHA_RE.match(blob.stdout.strip()):
            self.facts["judges_blob"] = blob.stdout.strip()
        return result.stdout

    def check_devices(self, judges):
        check = self.checks["devices"]
        if judges is None:
            check.set(FAIL, f"{JUDGES_PATH} is not in the frozen commit")
            return
        found, problems = device_prerequisites(judges)
        if problems:
            check.set(FAIL, "; ".join(problems))
            return
        self.devices = found
        check.set(RECORDED, f"{sum(len(v) for v in found.values())} prerequisite(s) for "
                  + ", ".join(found))

    def check_docs(self, judges):
        check = self.checks["docs"]
        if judges is None:
            return
        verify, placeholders = judges_open_items(judges)
        if verify or placeholders:
            parts = []
            if verify:
                parts.append(f"{verify} VERIFY comment(s)")
            if placeholders:
                parts.append("placeholders " + ", ".join(placeholders))
            check.set(WARN, "JUDGES.md still has " + " and ".join(parts) + " (RELEASE.md §1)")
        else:
            check.set(PASS, "JUDGES.md has no VERIFY comments or placeholders")

    def make_tag(self, name, sha):
        check = self.checks["tag"]
        if not name:
            check.set(NOT_RUN, "no --tag given; nothing tagged")
            return
        existing = run_command(["git", "rev-parse", "--verify", "--quiet", "--end-of-options",
                                f"refs/tags/{name}^{{commit}}"], self.runner, cwd=self.root)
        if existing.returncode == 0 and existing.stdout.strip():
            if existing.stdout.strip() == sha:
                check.set(PASS, f"{code(name)} already points at {code(sha)}; left as is")
                self.facts["tag"] = name
            else:
                check.set(FAIL, f"{code(name)} already exists at {code(existing.stdout.strip())}; not moved")
            return
        self.git("tag", "-a", name, sha, "-m", TAG_MESSAGE)
        check.set(PASS, f"created annotated tag {code(name)} at {code(sha)} locally; "
                  f"push it with `git push origin {name}`")
        self.facts["tag"] = name

    # -- run ----------------------------------------------------------------

    def run(self, ref, *, apk=None, defines_path=None, tag=None):
        if tag is not None and not TAG_RE.match(tag):
            raise UsageError("--tag must be a plain tag name (letters, digits, . _ -).")
        if not self.hosted_url.startswith("https://"):
            raise UsageError("--hosted-url must be https.")
        sha = self.resolve(ref)
        if sha:
            self.guard(self.check_main, sha)
            self.guard(self.check_ci, sha)
            defines = self.guard(self.expected_defines, defines_path, check="config")
            if defines is not None:
                self.guard(self.check_config, defines)
                self.guard(self.check_hosted, sha, defines)
            else:
                self.checks["hosted"].set(NOT_RUN, "not run: the build defines could not be read")
            try:
                judges = self.read_judges(sha)
            except FreezeError as error:
                judges = None
                self.checks["devices"].set(FAIL, str(error))
            self.guard(self.check_apk, apk, judges)
            if self.checks["devices"].status == NOT_RUN:
                self.check_devices(judges)
            self.check_docs(judges)
        if self.frozen_ok():
            self.guard(self.make_tag, tag, sha)
        elif tag:
            self.checks["tag"].set(NOT_RUN, "not run: an earlier check failed, so nothing was tagged")
        else:
            self.checks["tag"].set(NOT_RUN, "no --tag given; nothing tagged")
        return self.frozen_ok() and self.checks["tag"].status != FAIL

    def guard(self, step, *args, check=None):
        """Run one step; a FreezeError fails that step's check, never passes it."""
        try:
            return step(*args)
        except FreezeError as error:
            key = check or {
                self.check_main: "main", self.check_ci: "ci", self.check_config: "config",
                self.check_hosted: "hosted", self.check_apk: "apk", self.make_tag: "tag",
            }.get(step)
            self.checks[key].set(FAIL, str(error))
            return None

    def frozen_ok(self):
        required = ("ref", "main", "ci", "config", "hosted", "devices")
        return (all(self.checks[key].ok for key in required)
                and self.checks["apk"].status != FAIL)

    # -- output -------------------------------------------------------------

    def summary_lines(self):
        width = max(len(status) for status in (PASS, FAIL, NOT_RUN, RECORDED, WARN))
        return [f"  {check.status:<{width}}  {check.title}: {check.detail}"
                for check in self.checks.values()]

    def render(self):
        stamp = self.now()
        try:
            from zoneinfo import ZoneInfo
            eastern = stamp.astimezone(ZoneInfo("America/New_York")).strftime("%Y-%m-%d %H:%M %Z")
        except Exception:  # noqa: BLE001 (tz database missing: UTC alone is still exact)
            eastern = None
        utc = stamp.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        hosted = self.facts.get("hosted", {})
        apk = self.facts.get("apk")
        warnings = sum(check.status == WARN for check in self.checks.values())
        values = {
            "status": "Frozen. Every required check below passed" + (
                f"; {warnings} warning(s) to resolve before submitting." if warnings else "."),
            "frozen_at": utc + (f" ({eastern})" if eastern else ""),
            "ref": code(self.facts["ref"]) + (" (tag)" if self.facts.get("ref_is_tag") else ""),
            "commit": code(self.facts["sha"]),
            "tag": code(self.facts["tag"]) if self.facts.get("tag") else "none created by this run",
            "repo": code(self.repo),
            "main_tip": code(self.facts.get("main_tip", "")),
            "ci": cell("; ".join(self.facts.get("ci_runs", []))),
            "hosted_url": cell(self.facts.get("hosted_url", "")),
            "hosted_commit": code(hosted.get("commit") or ""),
            "hosted_version": cell(f"ref {hosted.get('ref')}, version {hosted.get('version') or 'not reported'}"),
            "config": ", ".join(f"{key}={code(hosted.get('config', {}).get(key, ''))}" for key in CONFIG_KEYS),
            "defines_source": cell(self.facts.get("defines_source", "")),
            "research_model": code(self.facts.get("research_model") or ""),
            "apk": (f"{code(apk['sha256'])} ({cell(apk['name'])}, {apk['size']} bytes)" if apk
                    else "not recorded (no --apk given)"),
            "judges_blob": code(self.facts.get("judges_blob", "")) if self.facts.get("judges_blob") else "not read",
        }
        return render_document(values, self.checks.values(), self.devices)


def render_document(values, checks, devices):
    def v(key):
        return values.get(key) or BLANK

    lines = [
        "# Release identity",
        "",
        "<!-- Card SS-111 (#242), part of SS-080 (#167). Written by tool/release/freeze.py; do not edit by hand. -->",
        "",
        "The checked identity of the judged #BuildHybridAI 2026 build: which commit, which hosted",
        "build, which configuration and which APK. Until the freeze this file is a template and every",
        "value is blank. At the freeze (Nov 29–30, with Terry) run, from an up-to-date checkout:",
        "",
        "```sh",
        "git fetch origin --tags",
        "python3 tool/release/freeze.py <FINAL_SHA_OR_TAG> [--apk PATH] [--tag buildhybridai-2026]",
        "```",
        "",
        "It overwrites this file only if every required check passes, and is read-only against",
        "production: no deploy, no push, and a local tag only with `--tag`.",
        "",
        "> **Keep the filled-in file off `main` after the freeze.** Every merge to `main` redeploys the",
        "> hosted site and changes the commit its `version.json` reports, so the identity below would",
        "> no longer match. Attach the filled-in file to the GitHub Release for the tag instead.",
        "",
        f"**Status:** {values.get('status') or 'Template. Not frozen yet; every value is blank.'}",
        "",
        "## Identity",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Frozen at | {v('frozen_at')} |",
        f"| Requested ref | {v('ref')} |",
        f"| Commit | {v('commit')} |",
        f"| Tag | {v('tag')} |",
        f"| Repository | {v('repo')} |",
        f"| `main` tip at freeze | {v('main_tip')} |",
        f"| CI on `main` | {v('ci')} |",
        f"| Hosted URL | {v('hosted_url')} |",
        f"| Hosted `version.json` commit | {v('hosted_commit')} |",
        f"| Hosted `version.json` ref and version | {v('hosted_version')} |",
        f"| Hosted build config | {v('config')} |",
        f"| Build defines source | {v('defines_source')} |",
        f"| `RESEARCH_MODEL` (from the defines; `version.json` does not report it) | {v('research_model')} |",
        f"| Release APK SHA-256 | {v('apk')} |",
        f"| `JUDGES.md` blob at the commit | {v('judges_blob')} |",
        "",
        "## Checks",
        "",
        "| Check | Result | Detail |",
        "|---|---|---|",
    ]
    for check in checks:
        lines.append(f"| {check.title} | {check.status if values else BLANK} | "
                     f"{cell(check.detail) if values else BLANK} |")
    lines += [
        "",
        "`NOT RUN` means the check did not run; it is never counted as passed.",
        "",
        "## Device prerequisites",
        "",
        f"As written in `{JUDGES_PATH}` at the frozen commit.",
        "",
    ]
    for platform in ("Web (desktop Chrome)", "Android", "iOS"):
        lines.append(f"### {platform}")
        lines.append("")
        items = devices.get(platform) if devices else None
        lines += [f"- {cell(item)}" for item in items] if items else [f"- {BLANK}"]
        lines.append("")
    lines += [
        "## Not checked here",
        "",
        "- `FAKE_BACKEND`: `version.json` does not report it. The deploy job hard-codes `false`, and",
        "  the build defines above are checked with `--judged`, which rejects `true`.",
        "- App Check enforcement, debug-token revocation and API key restrictions: console checks in",
        "  `RELEASE.md` §5.",
        "- On-device and cloud behaviour of the hosted build: `RELEASE.md` §4 release acceptance.",
        "- That the APK was built from this commit: the hash identifies the file, not its source.",
        "",
    ]
    return "\n".join(lines)


def template():
    """The committed, unfrozen RELEASE-IDENTITY.md."""
    checks = Freezer(runner=_no_runner, fetch=_no_fetch).checks.values()
    return render_document({}, checks, {})


def _no_runner(*_args, **_kwargs):
    raise AssertionError("template() runs no commands")


def _no_fetch(*_args, **_kwargs):
    raise AssertionError("template() fetches nothing")


def main(argv=None, *, freezer=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ref", help="commit SHA or tag to freeze")
    parser.add_argument("--apk", help="release APK to hash (only if gate G4 passed)")
    parser.add_argument("--defines", help="build defines JSON to check instead of the repository variables")
    parser.add_argument("--tag", help="create this annotated tag locally at the commit, after every check passed")
    parser.add_argument("--output",
                        help=f"where to write the identity (default {DEFAULT_OUTPUT} in the repo; '-' for stdout)")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--hosted-url", default=DEFAULT_HOSTED_URL)
    args = parser.parse_args(argv)
    freezer = freezer or Freezer(repo=args.repo, hosted_url=args.hosted_url)
    try:
        ok = freezer.run(args.ref, apk=args.apk, defines_path=args.defines, tag=args.tag)
    except UsageError as error:
        print(f"freeze: {error}", file=sys.stderr)
        return 2
    except FreezeError as error:
        print(f"freeze: {error} NOT FROZEN. Nothing was written.", file=sys.stderr)
        return 1
    print(f"Release freeze for {args.ref}:")
    for line in freezer.summary_lines():
        print(line)
    if not ok:
        print("NOT FROZEN: fix the FAIL lines above and run again. Nothing was written.", file=sys.stderr)
        return 1
    document = freezer.render()
    if args.output == "-":
        sys.stdout.write(document)
        return 0
    target = Path(args.output) if args.output else freezer.root / DEFAULT_OUTPUT
    target.write_text(document, encoding="utf-8")
    print(f"Frozen. Wrote {target}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
