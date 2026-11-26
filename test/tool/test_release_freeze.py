"""Tests for tool/release/freeze.py (SS-111). Offline: gh, git and HTTP are fakes.

tool/check_build_config.sh is the one real command run, because it is local and
the freeze must agree with what CI enforces. Run with
`python3 -m unittest discover -s test/tool -p 'test_release_freeze.py'`.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_freeze", ROOT / "tool/release/freeze.py")
freeze = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(freeze)

# Synthetic values, assembled at runtime so no secret-shaped literal is in source.
SHA = "a1" * 20
OTHER_SHA = "b2" * 20
BLOB_SHA = "c3" * 20
FAKE_TOKEN = "-".join(["0f8e2c1a", "3b4d", "4e5f", "8a6b", "7c8d9e0f1a2b"])
SENTINEL = "SENTINEL" + "-z" * 8  # stands in for a variable that must never be printed
APK_BYTES = b"PK\x03\x04" + b"synthetic apk body " * 100

JUDGES = """# Testing SousSight

## 1. Open the app

**Hosted web app:** https://example.test

- **Best experience:** Chrome on a desktop computer.
- Firefox and Safari are not supported.

## 3. Turn on Chrome's on-device model

You need desktop Chrome and:

- at least **22 GB free** on the drive
  that holds your Chrome profile;
- a GPU with more than 4 GB of memory; <!-- VERIFY: hardware list -->

Steps:

- not a prerequisite

## 6. Android and iOS

### Android (gated)

- **APK:** https://example.test/app.apk (SHA-256 `{apk_sha}`), signed release build.
- Needs a phone that runs Gemini Nano through AICore.

### iOS (gated)

- To build it yourself: Xcode and a device with Apple Intelligence turned on.

## 7. What is simulated
"""


def judges(apk_sha="<APK_SHA256>", **replace):
    text = JUDGES.replace("{apk_sha}", apk_sha)
    for old, new in replace.items():
        text = text.replace(old, new)
    return text


def hosted_version(commit=SHA, ref="main", **config):
    values = {"LIVE_BACKEND": "none", "DINNER_MODE": "simulated", "CLOUD_ROUTES": "hybridFallback,research"}
    values.update(config)
    return {"app_name": "soussight", "version": "1.0.0", "build_number": "1",
            "commit": commit, "ref": ref, "config": values}


def ci_runs(sha=SHA):
    return [
        {"databaseId": 11, "workflowName": "Validate and deploy SousSight", "status": "completed",
         "conclusion": "success", "event": "push", "headBranch": "main", "headSha": sha,
         "createdAt": "2026-11-29T10:00:00Z"},
        {"databaseId": 12, "workflowName": "Secret scan", "status": "completed",
         "conclusion": "success", "event": "push", "headBranch": "main", "headSha": sha,
         "createdAt": "2026-11-29T10:00:00Z"},
    ]


def jobs(deploy="success", validate="success"):
    return {"jobs": [{"name": "Tests and rehearsal build", "status": "completed", "conclusion": validate},
                     {"name": "Deploy production", "status": "completed", "conclusion": deploy}]}


class FakeRunner:
    """Answers the gh and git commands freeze.py issues; runs check_build_config.sh for real."""

    def __init__(self):
        self.commands = []
        self.refs = {"buildhybridai-rc": SHA, SHA: SHA, "main": SHA}
        self.tags = {"buildhybridai-rc": SHA}
        self.tag_types = {"buildhybridai-rc": "tag"}  # "tag" = annotated, "commit" = lightweight
        self.tag_fails = False
        self.judges = judges()
        self.main_tip = SHA
        self.compare_status = "identical"
        self.runs = ci_runs()
        self.jobs = {11: jobs()}
        self.variables = [
            {"name": "CLOUD_ROUTES", "value": "hybridFallback,research"},
            {"name": "RECAPTCHA_SITE_KEY", "value": SENTINEL},
            {"name": "GCP_DEPLOY_SERVICE_ACCOUNT", "value": SENTINEL},
        ]
        self.fail = {}  # first argv words -> (exit code, stderr)
        self.raw = {}   # first argv words -> raw stdout

    def __call__(self, argv, **kwargs):
        assert isinstance(argv, list), "commands are argv lists"
        assert not kwargs.get("shell")
        assert kwargs["timeout"] == freeze.COMMAND_TIMEOUT
        self.commands.append(list(argv))
        if argv[0] == str(freeze.CHECK_BUILD_CONFIG):
            env = {k: v for k, v in os.environ.items() if k != "APPCHECK_DEBUG_TOKEN"}
            return subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False, env=env)
        for prefix, (code, stderr) in self.fail.items():
            if tuple(argv[:len(prefix)]) == prefix:
                return subprocess.CompletedProcess(argv, code, stdout="", stderr=stderr)
        for prefix, stdout in self.raw.items():
            if tuple(argv[:len(prefix)]) == prefix:
                return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")
        if argv[0] == "git":
            return self.git(argv)
        if argv[0] == "gh":
            return self.ok(argv, json.dumps(self.gh(argv[1:])))
        raise AssertionError(f"unexpected command {argv}")

    @staticmethod
    def ok(argv, stdout, code=0):
        return subprocess.CompletedProcess(argv, code, stdout=stdout, stderr="")

    def git(self, argv):
        args = argv[1:]
        if args[:4] == ["rev-parse", "--verify", "--quiet", "--end-of-options"]:
            target = args[4]
            if target.startswith("refs/tags/"):
                name = target[len("refs/tags/"):].removesuffix("^{commit}")
                return self.ok(argv, self.tags[name] + "\n") if name in self.tags else self.ok(argv, "", 1)
            name = target.removesuffix("^{commit}")
            return self.ok(argv, self.refs[name] + "\n") if name in self.refs else self.ok(argv, "", 1)
        if args[:3] == ["rev-parse", "--verify", "--end-of-options"]:
            name = args[3][len("refs/tags/"):].removesuffix("^{commit}")
            return self.ok(argv, self.tags[name] + "\n") if name in self.tags else self.ok(argv, "", 128)
        if args[:2] == ["cat-file", "-t"]:
            name = args[2][len("refs/tags/"):]
            return self.ok(argv, self.tag_types.get(name, "tag") + "\n") if name in self.tags else self.ok(argv, "", 128)
        if args[0] == "show":
            assert args[1] == f"{SHA}:{freeze.JUDGES_PATH}", "JUDGES.md is read at the frozen commit"
            return self.ok(argv, self.judges) if self.judges is not None else self.ok(argv, "", 128)
        if args[0] == "rev-parse" and args[1] == f"{SHA}:{freeze.JUDGES_PATH}":
            return self.ok(argv, BLOB_SHA + "\n")
        if args[:2] == ["tag", "-a"]:
            if self.tag_fails:
                return self.ok(argv, "", 128)
            self.tags[args[2]] = args[3]
            self.tag_types[args[2]] = "tag"
            return self.ok(argv, "")
        if args[:2] == ["tag", "-d"]:
            self.tags.pop(args[2])
            return self.ok(argv, "")
        raise AssertionError(f"unexpected git command {argv}")

    def gh(self, args):
        if args[0] == "api":
            assert not {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"} & set(args), \
                "gh api is only ever a GET"
            if args[1] == "repos/terryhh/SousSight/commits/main":
                return {"sha": self.main_tip}
            if args[1].startswith("repos/terryhh/SousSight/compare/"):
                return {"status": self.compare_status, "ahead_by": 3 if self.compare_status == "ahead" else 0,
                        "behind_by": 0}
        if args[:2] == ["run", "list"]:
            assert args[args.index("--commit") + 1] == SHA
            return self.runs
        if args[:2] == ["run", "view"]:
            return self.jobs[int(args[2])]
        if args[:2] == ["variable", "list"]:
            return self.variables
        raise AssertionError(f"unexpected gh command {args}")


class FakeFetch:
    def __init__(self, body=None, status=200):
        self.urls = []
        self.status = status
        self.body = json.dumps(hosted_version()).encode() if body is None else body
        self.error = None

    def __call__(self, url):
        self.urls.append(url)
        if self.error:
            raise self.error
        return self.status, self.body


class FreezeTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.output = self.dir / "RELEASE-IDENTITY.md"
        self.runner = FakeRunner()
        self.fetch = FakeFetch()

    def freezer(self, **kwargs):
        import datetime
        return freeze.Freezer(runner=self.runner, fetch=self.fetch, root=self.dir,
                              now=lambda: datetime.datetime(2026, 11, 30, 14, 0, tzinfo=datetime.timezone.utc),
                              **kwargs)

    def run_main(self, *args, **kwargs):
        out, err = io.StringIO(), io.StringIO()
        self.last = self.freezer(**kwargs)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = freeze.main([*args, "--output", str(self.output)], freezer=self.last)
        self.stdout, self.stderr = out.getvalue(), err.getvalue()
        return code

    def status(self, key):
        return self.last.checks[key].status

    def detail(self, key):
        return self.last.checks[key].detail

    def assert_not_frozen(self, code, key, pattern=None):
        self.assertEqual(code, 1, self.stdout + self.stderr)
        self.assertEqual(self.status(key), freeze.FAIL, self.detail(key))
        if pattern:
            self.assertRegex(self.detail(key), pattern)
        self.assertFalse(self.output.exists(), "nothing is written when a check fails")
        self.assertIn("NOT FROZEN", self.stderr)
        self.assertNotIn(("git", "tag"), [tuple(c[:2]) for c in self.runner.commands])
        self.assert_no_secrets()

    def assert_no_secrets(self):
        printed = self.stdout + self.stderr + (self.output.read_text() if self.output.exists() else "")
        self.assertNotIn(SENTINEL, printed)
        self.assertNotIn(FAKE_TOKEN, printed)


class HappyPathTests(FreezeTestCase):
    def test_all_checks_pass_and_write_identity_without_tagging(self):
        code = self.run_main("buildhybridai-rc")
        self.assertEqual(code, 0, self.stdout + self.stderr)
        text = self.output.read_text()
        self.assertIn("**Status:** Frozen. Every required check below passed; 1 warning(s)", text)
        self.assertIn(f"| Commit | `{SHA}` |", text)
        self.assertIn("`buildhybridai-rc` (tag)", text)
        self.assertIn("LIVE_BACKEND=`none`, DINNER_MODE=`simulated`, CLOUD_ROUTES=`hybridFallback,research`", text)
        self.assertIn("| `RESEARCH_MODEL` (from the defines; `version.json` does not report it) | `gemini-3.8-flash` |", text)
        self.assertIn("workflow defaults for DINNER_MODE, LIVE_BACKEND, RESEARCH_MODEL", text)
        self.assertIn(f"`{BLOB_SHA}`", text)
        self.assertIn("2026-11-30T14:00:00Z", text)
        self.assertIn("| Release APK SHA-256 | NOT RUN | no --apk given", text)
        self.assertIn("| Annotated tag | NOT RUN | no --tag given; nothing tagged |", text)
        # Prerequisites come from JUDGES.md, comments stripped and continuations joined.
        self.assertIn("- **Best experience:** Chrome on a desktop computer.", text)
        self.assertIn("- at least **22 GB free** on the drive that holds your Chrome profile;", text)
        self.assertIn("- a GPU with more than 4 GB of memory;\n", text)
        self.assertNotIn("not a prerequisite", text)
        self.assertNotIn("Firefox", text)
        self.assertIn("- Needs a phone that runs Gemini Nano through AICore.", text)
        self.assertNotIn("**APK:**", text.split("## Device prerequisites")[1])
        self.assertIn("- To build it yourself: Xcode", text)
        self.assertNotIn(("git", "tag"), [tuple(c[:2]) for c in self.runner.commands])
        self.assert_no_secrets()

    def test_hosted_url_is_https_with_cache_buster(self):
        self.run_main(SHA)
        self.assertEqual(self.fetch.urls, [f"https://devfest-flutter-a59e8.web.app/version.json?freeze={SHA[:12]}"])

    def test_every_command_is_read_only(self):
        self.run_main(SHA, "--tag", "buildhybridai-2026")
        allowed = {("git", "rev-parse"), ("git", "show"), ("git", "tag"), ("git", "cat-file"), ("gh", "api"),
                   ("gh", "run"), ("gh", "variable"), (str(freeze.CHECK_BUILD_CONFIG), "--judged")}
        for command in self.runner.commands:
            self.assertIn(tuple(command[:2]), allowed, command)
            self.assertNotIn("push", command)
            if command[:2] == ["gh", "run"]:
                self.assertIn(command[2], ("list", "view"))
            if command[:2] == ["gh", "variable"]:
                self.assertEqual(command[2], "list")

    def test_output_dash_prints_document_and_writes_nothing(self):
        out = io.StringIO()
        self.last = self.freezer()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = freeze.main([SHA, "--output", "-"], freezer=self.last)
        self.assertEqual(code, 0)
        self.assertIn("# Release identity", out.getvalue())
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_default_output_is_release_identity_in_repo(self):
        (self.dir / "docs/buildhybridai").mkdir(parents=True)
        self.last = self.freezer()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(freeze.main([SHA], freezer=self.last), 0)
        self.assertTrue((self.dir / freeze.DEFAULT_OUTPUT).read_text().startswith("# Release identity"))

    def test_clean_judges_has_no_warning(self):
        self.runner.judges = judges(apk_sha="d4" * 32).replace("<!-- VERIFY: hardware list -->", "")
        self.assertEqual(self.run_main(SHA), 0)
        self.assertEqual(self.status("docs"), freeze.PASS)
        self.assertIn("**Status:** Frozen. Every required check below passed.\n", self.output.read_text())

    def test_commit_on_main_behind_tip_is_reported(self):
        self.runner.main_tip, self.runner.compare_status = OTHER_SHA, "ahead"
        self.run_main(SHA)
        self.assertEqual(self.status("main"), freeze.PASS)
        self.assertIn("main has 3 newer commit(s)", self.detail("main"))


class RefTests(FreezeTestCase):
    def test_unknown_ref_fails_and_runs_nothing_else(self):
        code = self.run_main("no-such-tag")
        self.assert_not_frozen(code, "ref", "does not resolve")
        for key in ("main", "ci", "config", "hosted", "devices"):
            self.assertEqual(self.status(key), freeze.NOT_RUN, key)
        self.assertEqual(self.fetch.urls, [])

    def test_option_shaped_ref_is_usage_error(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(freeze.main(["--output", str(self.output), "--", "-x"], freezer=self.freezer()), 2)
        self.assertIn("not an option", err.getvalue())
        self.assertEqual(self.runner.commands, [])

    def test_bad_tag_name_and_http_url_are_usage_errors(self):
        for args, kwargs in (([SHA, "--tag", "bad tag"], {}), ([SHA], {"hosted_url": "http://example.test"})):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(freeze.main([*args, "--output", str(self.output)],
                                             freezer=self.freezer(**kwargs)), 2)
        self.assertFalse(self.output.exists())


class MainAndCiTests(FreezeTestCase):
    def test_commit_not_on_main_fails(self):
        for status in ("diverged", "behind"):
            with self.subTest(status=status):
                self.runner.compare_status = status
                self.assert_not_frozen(self.run_main(SHA), "main", f"not on main.*{status}")

    def test_gh_failure_fails_check_without_echoing_stderr(self):
        self.runner.fail[("gh", "api")] = (1, f"HTTP 401: token {FAKE_TOKEN} rejected")
        self.assert_not_frozen(self.run_main(SHA), "main", r"`gh api repos/terryhh/SousSight/commits/main` failed \(exit 1\)")

    def test_gh_invalid_json_fails(self):
        self.runner.raw[("gh", "run", "list")] = "not json"
        self.assert_not_frozen(self.run_main(SHA), "ci", "invalid JSON")

    def test_missing_required_workflow_fails(self):
        self.runner.runs = [run for run in ci_runs() if run["workflowName"] != "Secret scan"]
        self.assert_not_frozen(self.run_main(SHA), "ci", "no 'Secret scan' run on main")

    def test_runs_from_other_branches_events_or_commits_do_not_count(self):
        for change in ({"headBranch": "hybrid/integration"}, {"event": "pull_request"}, {"headSha": OTHER_SHA}):
            with self.subTest(change=change):
                self.runner.runs = [dict(run, **change) for run in ci_runs()]
                self.assert_not_frozen(self.run_main(SHA), "ci", "no 'Validate and deploy SousSight' run")

    def test_in_progress_or_failed_run_fails(self):
        for change, pattern in (({"status": "in_progress", "conclusion": ""}, "in_progress, not completed"),
                                ({"conclusion": "failure"}, "concluded failure"),
                                ({"conclusion": "cancelled"}, "concluded cancelled")):
            with self.subTest(change=change):
                runs = ci_runs()
                runs[1].update(change)
                self.runner.runs = runs
                self.assert_not_frozen(self.run_main(SHA), "ci", pattern)

    def test_latest_run_attempt_decides(self):
        older_failure = dict(ci_runs()[0], databaseId=10, conclusion="failure", createdAt="2026-11-29T09:00:00Z")
        self.runner.runs = [older_failure, *ci_runs()]
        self.assertEqual(self.run_main(SHA), 0)
        self.output.unlink()
        newer_failure = dict(ci_runs()[0], databaseId=13, conclusion="failure", createdAt="2026-11-29T11:00:00Z")
        self.runner.runs = [*ci_runs(), newer_failure]
        self.assert_not_frozen(self.run_main(SHA), "ci", "run 13 concluded failure")

    def test_skipped_or_failed_deploy_job_fails_even_when_run_is_green(self):
        for deploy in ("skipped", "failure"):
            with self.subTest(deploy=deploy):
                self.runner.jobs = {11: jobs(deploy=deploy)}
                self.assert_not_frozen(self.run_main(SHA), "ci", f"'Deploy production' {deploy}")

    def test_missing_deploy_job_fails(self):
        self.runner.jobs = {11: {"jobs": [jobs()["jobs"][0]]}}
        self.assert_not_frozen(self.run_main(SHA), "ci", "'Deploy production' missing")


class ConfigTests(FreezeTestCase):
    def test_repository_variables_rejected_by_check_build_config(self):
        for name, value, pattern in (("LIVE_BACKEND", "ephemeral", "ephemeral is not allowed"),
                                     ("DINNER_MODE", "real", "requires DINNER_MODE=simulated"),
                                     ("CLOUD_ROUTES", "research,", "empty entry")):
            with self.subTest(name=name):
                self.runner.variables = [v for v in FakeRunner().variables if v["name"] != name]
                self.runner.variables.append({"name": name, "value": value})
                self.fetch.body = json.dumps(hosted_version(**{name: value})).encode()
                self.assert_not_frozen(self.run_main(SHA), "config", pattern)

    def test_unset_or_empty_variables_use_workflow_defaults(self):
        self.runner.variables = [{"name": "CLOUD_ROUTES", "value": "hybridFallback,research"},
                                 {"name": "DINNER_MODE", "value": ""}]
        self.assertEqual(self.run_main(SHA), 0, self.stdout)
        self.assertIn("DINNER_MODE=simulated", self.detail("config"))

    def test_other_variable_values_are_never_printed(self):
        self.run_main(SHA)
        self.assert_no_secrets()

    def test_variables_unreadable_fails_config_and_does_not_run_hosted(self):
        self.runner.fail[("gh", "variable")] = (1, SENTINEL)
        code = self.run_main(SHA)
        self.assert_not_frozen(code, "config", "gh variable list")
        self.assertEqual(self.status("hosted"), freeze.NOT_RUN)
        self.assertEqual(self.fetch.urls, [])

    def test_defines_file_replaces_variables(self):
        defines = self.dir / "judged.json"
        defines.write_text(json.dumps({"FAKE_BACKEND": False, "DINNER_MODE": "simulated", "LIVE_BACKEND": "none",
                                       "CLOUD_ROUTES": "hybridFallback,research", "RESEARCH_MODEL": "model-x"}))
        self.assertEqual(self.run_main(SHA, "--defines", str(defines)), 0, self.stdout)
        self.assertNotIn(("gh", "variable"), [tuple(c[:2]) for c in self.runner.commands])
        self.assertIn("| Build defines source | file judged.json |", self.output.read_text())
        self.assertIn("`model-x`", self.output.read_text())

    def test_defines_file_with_debug_token_or_fake_backend_fails_without_printing_token(self):
        for extra, pattern in (({"APPCHECK_DEBUG_TOKEN": FAKE_TOKEN}, "APPCHECK_DEBUG_TOKEN is set"),
                               ({"FAKE_BACKEND": True}, "FAKE_BACKEND rehearsal")):
            with self.subTest(extra=list(extra)):
                defines = self.dir / "judged.json"
                defines.write_text(json.dumps({"DINNER_MODE": "simulated", "CLOUD_ROUTES": "hybridFallback,research",
                                               **extra}))
                self.assert_not_frozen(self.run_main(SHA, "--defines", str(defines)), "config", pattern)

    def test_bad_defines_file_fails(self):
        for content, pattern in (("{", "not valid JSON"), ("[]", "JSON object"), (None, "could not read")):
            with self.subTest(content=content):
                defines = self.dir / "judged.json"
                if content is None:
                    defines.unlink(missing_ok=True)
                else:
                    defines.write_text(content)
                self.assert_not_frozen(self.run_main(SHA, "--defines", str(defines)), "config", pattern)


class HostedTests(FreezeTestCase):
    def test_hosted_mismatches_fail(self):
        cases = (
            (hosted_version(commit=OTHER_SHA), f"serves commit `{OTHER_SHA}`"),
            (hosted_version(ref="hybrid/integration"), "ref is `hybrid/integration`, not `main`"),
            (hosted_version(LIVE_BACKEND="aiLogic"), "config.LIVE_BACKEND is `aiLogic`, build defines say `none`"),
            (hosted_version(DINNER_MODE="real"), "config.DINNER_MODE is `real`"),
            (hosted_version(CLOUD_ROUTES="research"), "config.CLOUD_ROUTES is `research`"),
            ({k: v for k, v in hosted_version().items() if k != "config"}, "has no config object"),
            ({k: v for k, v in hosted_version().items() if k != "commit"}, "serves commit `None`"),
            (dict(hosted_version(), config={"LIVE_BACKEND": "none", "DINNER_MODE": "simulated"}),
             "config.CLOUD_ROUTES is missing"),
        )
        for body, pattern in cases:
            with self.subTest(pattern=pattern):
                self.fetch.body = json.dumps(body).encode()
                self.assert_not_frozen(self.run_main(SHA), "hosted", re.escape(pattern))

    def test_bad_hosted_responses_fail(self):
        for status, body, pattern in ((404, b"", "HTTP 404"), (200, b"<html>", "not valid JSON"),
                                      (200, b"[]", "not a JSON object"),
                                      (200, b" " * (freeze.MAX_VERSION_JSON_BYTES + 1), "larger than expected")):
            with self.subTest(pattern=pattern):
                self.fetch.status, self.fetch.body = status, body
                self.assert_not_frozen(self.run_main(SHA), "hosted", pattern)

    def test_network_error_fails_hosted(self):
        self.fetch.error = freeze.FreezeError("could not reach the hosted site; check the network.")
        self.assert_not_frozen(self.run_main(SHA), "hosted", "could not reach")

    def test_hosted_values_are_sanitized_in_the_document(self):
        self.fetch.body = json.dumps(dict(hosted_version(), version="1|2\n# injected")).encode()
        self.assertEqual(self.run_main(SHA), 0)
        text = self.output.read_text()
        self.assertIn("version 1\\|2 # injected+1", text)
        self.assertNotIn("\n# injected", text)


class ApkTests(FreezeTestCase):
    def test_apk_hash_recorded(self):
        apk = self.dir / "app-release.apk"
        apk.write_bytes(APK_BYTES)
        self.assertEqual(self.run_main(SHA, "--apk", str(apk)), 0, self.stdout)
        digest = hashlib.sha256(APK_BYTES).hexdigest()
        self.assertEqual(self.status("apk"), freeze.RECORDED)
        self.assertIn(f"| Release APK SHA-256 | `{digest}` (app-release.apk, {len(APK_BYTES)} bytes) |",
                      self.output.read_text())

    def test_apk_matching_judges_hash_is_noted(self):
        apk = self.dir / "app-release.apk"
        apk.write_bytes(APK_BYTES)
        self.runner.judges = judges(apk_sha=hashlib.sha256(APK_BYTES).hexdigest())
        self.assertEqual(self.run_main(SHA, "--apk", str(apk)), 0)
        self.assertIn("matches JUDGES.md", self.detail("apk"))

    def test_apk_mismatches_fail(self):
        apk = self.dir / "app-release.apk"
        cases = ((None, None, "APK not found"), (b"not a zip", None, "not an APK"),
                 (APK_BYTES, "e5" * 32, "differs from JUDGES.md"))
        for content, listed, pattern in cases:
            with self.subTest(pattern=pattern):
                if content is None:
                    apk.unlink(missing_ok=True)
                else:
                    apk.write_bytes(content)
                if listed:
                    self.runner.judges = judges(apk_sha=listed)
                self.assert_not_frozen(self.run_main(SHA, "--apk", str(apk)), "apk", pattern)


class JudgesTests(FreezeTestCase):
    def test_missing_judges_fails(self):
        self.runner.judges = None
        self.assert_not_frozen(self.run_main(SHA), "devices", "not in the frozen commit")

    def test_missing_sections_fail(self):
        for old, new, pattern in (("## 3. Turn on Chrome's on-device model", "## 3. Something else", "Turn on Chrome"),
                                  ("### iOS (gated)", "### Other", "no '### iOS' section"),
                                  ("- Needs a phone that runs Gemini Nano through AICore.", "Text only.",
                                   "Android section lists no prerequisites")):
            with self.subTest(pattern=pattern):
                self.runner.judges = judges(**{old: new})
                self.assert_not_frozen(self.run_main(SHA), "devices", pattern)

    def test_platform_stated_out_of_entry_is_recorded(self):
        text = re.sub(r"### Android \(gated\).*?(?=### iOS)", "Android is not part of this entry.\n\n",
                      judges(), flags=re.S)
        self.runner.judges = text
        self.assertEqual(self.run_main(SHA), 0, self.stdout)
        self.assertIn("### Android\n\n- Not part of this entry (per JUDGES.md).", self.output.read_text())

    def test_hidden_comment_is_not_a_platform_decision(self):
        # Codex #247: the real JUDGES.md has this sentence inside a VERIFY instruction.
        note = '<!-- VERIFY: gate G4. If G4 did not pass, replace this section with "Android is not part of this entry." -->'
        self.runner.judges = judges(**{"### Android (gated)": f"### Mobile Android (gated) {note}"})
        self.assert_not_frozen(self.run_main(SHA), "devices", "no '### Android' section and does not say it is out")
        self.runner.judges = judges(**{"### Android (gated)": f"### Android (gated) {note}"})
        self.output.unlink(missing_ok=True)
        self.assertEqual(self.run_main(SHA), 0, self.stdout)
        self.assertIn("- Needs a phone that runs Gemini Nano", self.output.read_text())

    def test_exclusion_must_be_its_own_visible_line(self):
        text = re.sub(r"### Android \(gated\).*?(?=### iOS)",
                      "We may say Android is not part of this entry later.\n\n", judges(), flags=re.S)
        self.runner.judges = text
        self.assert_not_frozen(self.run_main(SHA), "devices", "no '### Android' section")

    def test_section_and_exclusion_together_fail(self):
        self.runner.judges = judges(**{"### iOS (gated)": "Android is not part of this entry.\n\n### iOS (gated)"})
        self.assert_not_frozen(self.run_main(SHA), "devices", "both has a '### Android' section")

    def test_open_items_warn_but_do_not_block(self):
        self.assertEqual(self.run_main(SHA), 0)
        self.assertEqual(self.status("docs"), freeze.WARN)
        self.assertIn("1 VERIFY comment(s) and placeholders <APK_SHA256>", self.detail("docs"))


class TagTests(FreezeTestCase):
    def test_tag_created_only_after_all_checks_pass(self):
        self.assertEqual(self.run_main(SHA, "--tag", "buildhybridai-2026"), 0)
        self.assertIn(["git", "tag", "-a", "buildhybridai-2026", SHA, "-m", freeze.TAG_MESSAGE],
                      self.runner.commands)
        self.assertIn("git push origin buildhybridai-2026", self.detail("tag"))
        self.assertIn("| Tag | `buildhybridai-2026` |", self.output.read_text())

    def test_no_tag_when_a_check_fails(self):
        self.fetch.body = json.dumps(hosted_version(commit=OTHER_SHA)).encode()
        self.assert_not_frozen(self.run_main(SHA, "--tag", "buildhybridai-2026"), "hosted")
        self.assertEqual(self.status("tag"), freeze.NOT_RUN)
        self.assertIn("nothing was tagged", self.detail("tag"))

    def test_existing_tag_elsewhere_is_not_moved(self):
        self.runner.tags["buildhybridai-2026"] = OTHER_SHA
        self.assert_not_frozen(self.run_main(SHA, "--tag", "buildhybridai-2026"), "tag", "already exists")
        self.assertEqual(self.runner.tags["buildhybridai-2026"], OTHER_SHA)

    def test_existing_annotated_tag_at_commit_is_kept(self):
        self.runner.tags["buildhybridai-2026"] = SHA
        self.runner.tag_types["buildhybridai-2026"] = "tag"
        self.assertEqual(self.run_main(SHA, "--tag", "buildhybridai-2026"), 0)
        self.assertNotIn(("git", "tag"), [tuple(c[:2]) for c in self.runner.commands])
        self.assertIn("annotated tag `buildhybridai-2026` already points at", self.detail("tag"))
        self.assertIn("| Tag | `buildhybridai-2026` |", self.output.read_text())

    def test_existing_lightweight_tag_at_commit_fails_and_is_not_moved(self):
        # Codex #247: peeling to ^{commit} gives the same SHA for lightweight and annotated tags.
        self.runner.tags["buildhybridai-2026"] = SHA
        self.runner.tag_types["buildhybridai-2026"] = "commit"
        self.assert_not_frozen(self.run_main(SHA, "--tag", "buildhybridai-2026"), "tag", "lightweight tag")
        self.assertEqual(self.runner.tags["buildhybridai-2026"], SHA)
        self.assertEqual(self.runner.tag_types["buildhybridai-2026"], "commit")

    def test_tag_creation_failure_writes_nothing(self):
        self.runner.tag_fails = True
        code = self.run_main(SHA, "--tag", "buildhybridai-2026")
        self.assertEqual(code, 1)
        self.assertEqual(self.status("tag"), freeze.FAIL)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.dir.iterdir()), [], "the staged report is removed")
        self.assertIn("the tag could not be created", self.stderr)

    def test_tag_with_stdout_output_is_refused_before_any_command(self):
        # Codex #247: stdout can fail (ENOSPC, at write or flush) after a tag exists.
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = freeze.main([SHA, "--tag", "buildhybridai-2026", "--output", "-"], freezer=self.freezer())
        self.assertEqual(code, 2)
        self.assertIn("--tag needs a report file", err.getvalue())
        self.assertEqual(self.runner.commands, [])
        self.assertNotIn("buildhybridai-2026", self.runner.tags)


class FailingStream(io.StringIO):
    def __init__(self, fail_on):
        super().__init__()
        self.fail_on = fail_on

    def write(self, text):
        if self.fail_on == "write" and text.startswith("# Release identity"):
            raise OSError(28, "No space left on device")
        return super().write(text)

    def flush(self):
        if self.fail_on == "flush" and "# Release identity" in self.getvalue():
            raise OSError(28, "No space left on device")
        return super().flush()


class StdoutTests(FreezeTestCase):
    def test_stdout_write_or_flush_failure_exits_cleanly(self):
        for fail_on in ("write", "flush"):
            with self.subTest(fail_on=fail_on):
                err = io.StringIO()
                with contextlib.redirect_stdout(FailingStream(fail_on)), contextlib.redirect_stderr(err):
                    code = freeze.main([SHA, "--output", "-"], freezer=self.freezer())
                self.assertEqual(code, 1)
                self.assertIn("NOT FROZEN: the report could not be written to stdout.", err.getvalue())
                self.assertNotIn(("git", "tag"), [tuple(c[:2]) for c in self.runner.commands])


class OutputTests(FreezeTestCase):
    """Codex #247: an unwritable report path must never leave a new tag without its report."""

    def test_unwritable_destination_is_refused_before_any_command(self):
        blocker = self.dir / "not-a-dir"
        blocker.write_text("file")
        for target in (blocker / "RELEASE-IDENTITY.md", self.dir / "missing" / "RELEASE-IDENTITY.md", self.dir):
            with self.subTest(target=target.name), contextlib.redirect_stdout(io.StringIO()):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    code = freeze.main([SHA, "--tag", "buildhybridai-2026", "--output", str(target)],
                                       freezer=self.freezer())
                self.assertEqual(code, 2)
                self.assertIn("--output", err.getvalue())
        self.assertEqual(self.runner.commands, [])
        self.assertNotIn("buildhybridai-2026", self.runner.tags)

    def test_staging_failure_creates_no_tag(self):
        original = freeze.tempfile.mkstemp

        def no_space(*args, **kwargs):
            raise OSError(28, "No space left on device")
        freeze.tempfile.mkstemp = no_space
        self.addCleanup(setattr, freeze.tempfile, "mkstemp", original)
        self.assertEqual(self.run_main(SHA, "--tag", "buildhybridai-2026"), 1)
        self.assertNotIn(["git", "tag", "-a", "buildhybridai-2026", SHA, "-m", freeze.TAG_MESSAGE],
                         self.runner.commands)
        self.assertNotIn("buildhybridai-2026", self.runner.tags)
        self.assertEqual(self.status("tag"), freeze.NOT_RUN)
        self.assertIn("could not write the report", self.stderr)
        self.assertFalse(self.output.exists())

    def test_failed_final_write_deletes_the_new_tag(self):
        original = freeze.os.replace

        def fail_replace(src, dst):
            raise OSError(5, "I/O error")
        freeze.os.replace = fail_replace
        self.addCleanup(setattr, freeze.os, "replace", original)
        self.assertEqual(self.run_main(SHA, "--tag", "buildhybridai-2026"), 1)
        self.assertIn(["git", "tag", "-d", "buildhybridai-2026"], self.runner.commands)
        self.assertNotIn("buildhybridai-2026", self.runner.tags)
        self.assertEqual(self.status("tag"), freeze.FAIL)
        self.assertIn("tag deleted again", self.detail("tag"))
        self.assertEqual(list(self.dir.iterdir()), [], "no report and no staged file are left")

    def test_failed_final_write_keeps_a_pre_existing_tag(self):
        self.runner.tags["buildhybridai-2026"] = SHA
        self.runner.tag_types["buildhybridai-2026"] = "tag"
        original = freeze.os.replace
        freeze.os.replace = lambda src, dst: (_ for _ in ()).throw(OSError(5, "I/O error"))
        self.addCleanup(setattr, freeze.os, "replace", original)
        self.assertEqual(self.run_main(SHA, "--tag", "buildhybridai-2026"), 1)
        self.assertNotIn(("git", "tag"), [tuple(c[:2]) for c in self.runner.commands])
        self.assertEqual(self.runner.tags["buildhybridai-2026"], SHA)

    def test_existing_report_is_replaced_atomically(self):
        self.output.write_text("old")
        self.assertEqual(self.run_main(SHA), 0)
        self.assertTrue(self.output.read_text().startswith("# Release identity"))
        self.assertEqual([p.name for p in self.dir.iterdir()], [self.output.name])


class ErrorPathTests(FreezeTestCase):
    def test_missing_git_fails_cleanly(self):
        def no_git(argv, **kwargs):
            raise FileNotFoundError(argv[0])
        self.last = freeze.Freezer(runner=no_git, fetch=self.fetch, root=self.dir)
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            self.assertEqual(freeze.main([SHA, "--output", str(self.output)], freezer=self.last), 1)
        self.assertIn("git rev-parse did not complete", err.getvalue())
        self.assertIn("NOT FROZEN", err.getvalue())
        self.assertFalse(self.output.exists())

    def test_git_show_crash_fails_devices(self):
        real = self.runner.git

        def flaky(argv):
            if argv[1] == "show":
                raise subprocess.TimeoutExpired(argv, 60)
            return real(argv)
        self.runner.git = flaky
        self.assert_not_frozen(self.run_main(SHA), "devices", "git show did not complete")

    def test_unreadable_apk_fails(self):
        apk = self.dir / "app-release.apk"
        apk.mkdir()  # a directory is not a file
        self.assert_not_frozen(self.run_main(SHA, "--apk", str(apk)), "apk", "APK not found")
        apk.rmdir()
        apk.write_bytes(APK_BYTES)
        apk.chmod(0)
        self.addCleanup(apk.chmod, 0o600)
        if os.access(apk, os.R_OK):
            self.skipTest("running as a user who can read mode-000 files")
        self.assert_not_frozen(self.run_main(SHA, "--apk", str(apk)), "apk", "could not be read")


class FetchHttpsTests(unittest.TestCase):
    """The real fetcher, with urlopen replaced: still no network."""

    class Response:
        def __init__(self, url, status=200, body=b"{}"):
            self.url, self.status, self.body = url, status, body

        def geturl(self):
            return self.url

        def read(self, limit):
            return self.body[:limit]

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fetch_with(self, behaviour):
        original = freeze.urllib.request.urlopen
        freeze.urllib.request.urlopen = behaviour
        self.addCleanup(setattr, freeze.urllib.request, "urlopen", original)
        return freeze.fetch_https("https://example.test/version.json")

    def test_ok_and_http_error(self):
        self.assertEqual(self.fetch_with(lambda request, timeout: self.Response(request.full_url)), (200, b"{}"))

        def not_found(request, timeout):
            raise freeze.urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, io.BytesIO(b"gone"))
        self.assertEqual(self.fetch_with(not_found), (404, b""))

    def test_redirect_off_https_and_broken_reads_fail(self):
        with self.assertRaisesRegex(freeze.FreezeError, "redirected away from https"):
            self.fetch_with(lambda request, timeout: self.Response("http://example.test/version.json"))
        for error in (freeze.urllib.error.URLError("down"), freeze.http.client.IncompleteRead(b""),
                      ConnectionResetError()):
            with self.subTest(error=type(error).__name__):
                def broken(request, timeout, error=error):
                    raise error
                with self.assertRaisesRegex(freeze.FreezeError, "could not reach"):
                    self.fetch_with(broken)


class RepositoryContractTests(unittest.TestCase):
    def test_committed_template_matches_the_generator(self):
        committed = (ROOT / freeze.DEFAULT_OUTPUT).read_text(encoding="utf-8")
        self.assertEqual(committed, freeze.template(),
                         "regenerate docs/buildhybridai/RELEASE-IDENTITY.md from freeze.template()")
        self.assertIn("Template. Not frozen yet", committed)
        self.assertNotRegex(committed, r"[0-9a-f]{40}")

    def test_workflow_defaults_and_names_match_the_deploy_workflow(self):
        workflow = (ROOT / ".github/workflows/firebase.yml").read_text(encoding="utf-8")
        for key, default in freeze.WORKFLOW_DEFAULTS.items():
            with self.subTest(key=key):
                self.assertRegex(workflow, rf"\b{key}: \$\{{\{{ vars\.{key} \|\| '{re.escape(default)}' \}}\}}")
        self.assertIn("'FAKE_BACKEND': 'false'", workflow)
        workflows = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / ".github/workflows").glob("*.yml"))
        for name, jobs_required in freeze.REQUIRED_WORKFLOWS:
            self.assertRegex(workflows, rf"(?m)^name: {re.escape(name)}$")
            for job in jobs_required:
                self.assertRegex(workflow, rf"(?m)^    name: {re.escape(job)}$")

    def test_hosted_config_keys_match_the_bundle_stamp(self):
        stamp = (ROOT / "tool/check_web_bundle.sh").read_text(encoding="utf-8")
        self.assertIn("'LIVE_BACKEND', 'DINNER_MODE', 'CLOUD_ROUTES'", stamp)
        self.assertEqual(freeze.CONFIG_KEYS, ("LIVE_BACKEND", "DINNER_MODE", "CLOUD_ROUTES"))

    def test_real_judges_guide_parses(self):
        found, problems = freeze.device_prerequisites((ROOT / freeze.JUDGES_PATH).read_text(encoding="utf-8"))
        self.assertEqual(problems, [], "freeze.py could not read JUDGES.md's device prerequisites")
        self.assertEqual(set(found), {"Web (desktop Chrome)", "Android", "iOS"})


if __name__ == "__main__":
    unittest.main()
