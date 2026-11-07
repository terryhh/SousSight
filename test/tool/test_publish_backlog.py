import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("publish_backlog", ROOT / "tool/publish_backlog.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


def manifest():
    return {
        "schemaVersion": 1, "repository": "terryhh/SousSight",
        "projectOwner": "terryhh", "projectTitle": "SousSight",
        "tasks": [
            {"id": "SS-001", "priority": "P0", "title": "Camera `literal` $value", "owner": "Codex", "assignee": "terryhh",
             "status": "InProgress", "verified": False, "description": "Live camera + voice.",
             "acceptance": ["Verify real audio."], "dependsOn": [], "evidence": ["Local code; live service unverified."]},
            {"id": "SS-002", "priority": "P1", "title": "AGY research panel", "owner": "Sister (AGY)", "assignee": "jennajh",
             "status": "Todo", "verified": False, "description": "Implement cited answers.",
             "acceptance": ["Explicit cook confirmation."], "dependsOn": ["SS-001"], "evidence": ["Assignment ready."]},
        ],
    }


class FakeGhRunner:
    def __init__(self):
        self.commands, self.issues, self.items = [], [], []
        self.bodies, self.statuses = {}, {}
        self.projects = [{"id": "PVT_project", "number": 7, "title": "SousSight", "closed": False}]
        self.options = [{"id": "todo-id", "name": "Todo"},
                        {"id": "progress-id", "name": "In Progress"},
                        {"id": "done-id", "name": "Done"}]
        self.fail_edit_once = False
        self.claim_on_view = None

    def __call__(self, argv, **kwargs):
        assert isinstance(argv, list)
        assert not kwargs.get("shell")
        assert kwargs["timeout"] == 30
        assert argv[0] == "gh"
        self.commands.append(argv)
        args = argv[1:]
        stdout = None
        if args[:2] == ["project", "list"]:
            stdout = {"projects": self.projects, "totalCount": len(self.projects)}
        elif args[:2] == ["project", "view"]:
            stdout = self.projects[0]
        elif args[:2] == ["project", "field-list"]:
            stdout = {"fields": [{"id": "status-field", "name": "Status", "options": self.options}], "totalCount": 1}
        elif args[:1] == ["api"]:
            assert "--paginate" in args and "--slurp" in args
            stdout = [self.issues[:1], self.issues[1:]]
        elif args[:2] == ["project", "item-list"]:
            stdout = {"items": self.items, "totalCount": len(self.items)}
        elif args[:2] == ["issue", "create"]:
            path = args[args.index("--body-file") + 1]
            body = Path(path).read_text()
            number = len(self.issues) + 1
            url = f"https://github.com/terryhh/SousSight/issues/{number}"
            assignee = args[args.index("--assignee") + 1]
            self.issues.append({"html_url": url, "body": body, "number": number,
                                "assignees": [{"login": assignee}]})
            self.bodies[url] = body
            return subprocess.CompletedProcess(argv, 0, stdout=url + "\n", stderr="")
        elif args[:2] == ["issue", "view"]:
            issue = next(issue for issue in self.issues if issue["html_url"] == args[2])
            if self.claim_on_view:
                issue["assignees"] = [{"login": self.claim_on_view}]
            stdout = {"assignees": issue["assignees"]}
        elif args[:2] == ["issue", "edit"]:
            issue = next(issue for issue in self.issues if issue["html_url"] == args[2])
            assignee = args[args.index("--add-assignee") + 1]
            issue["assignees"].append({"login": assignee})
            return subprocess.CompletedProcess(argv, 0, stdout=issue["html_url"], stderr="")
        elif args[:2] == ["project", "item-add"]:
            url = args[args.index("--url") + 1]
            item = {"id": f"PVTI_{len(self.items) + 1}", "content": {"url": url}}
            self.items.append(item)
            stdout = item
        elif args[:2] == ["project", "item-edit"]:
            if self.fail_edit_once:
                self.fail_edit_once = False
                return subprocess.CompletedProcess(argv, 1, stdout="", stderr="SECRET_TOKEN_SHOULD_NOT_PRINT")
            self.statuses[args[args.index("--id") + 1]] = args[args.index("--single-select-option-id") + 1]
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
        else:
            raise AssertionError(f"Unexpected gh command: {argv}")
        return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(stdout), stderr="")


class PublisherTests(unittest.TestCase):
    def apply(self, fake, data=None, **kwargs):
        return publisher.publish(data or manifest(), gh=publisher.Gh(fake), apply=True, output=lambda _: None, **kwargs)

    def test_default_dry_run_is_offline_and_never_calls_gh(self):
        fake = FakeGhRunner()
        output = []
        publisher.publish(manifest(), gh=publisher.Gh(fake), output=output.append)
        self.assertEqual(fake.commands, [])
        self.assertIn("DRY RUN", output[0])
        self.assertTrue(any("Sister (AGY)" in line for line in output))

    def test_publish_creates_marked_issues_dependency_links_and_project_status(self):
        fake = FakeGhRunner()
        self.apply(fake)
        self.assertEqual(len(fake.issues), 2)
        self.assertEqual(len(fake.items), 2)
        self.assertEqual(fake.statuses, {"PVTI_1": "progress-id", "PVTI_2": "todo-id"})
        self.assertIn("<!-- soussight-backlog:SS-001 -->", fake.issues[0]["body"])
        self.assertIn("[SS-001](https://github.com/terryhh/SousSight/issues/1)", fake.issues[1]["body"])
        create = next(cmd for cmd in fake.commands if cmd[1:3] == ["issue", "create"])
        self.assertEqual(create[create.index("--title") + 1], "[P0] SS-001: Camera `literal` $value")
        self.assertFalse(Path(create[create.index("--body-file") + 1]).exists())
        self.assertEqual(fake.issues[0]["assignees"], [{"login": "terryhh"}])
        self.assertEqual(fake.issues[1]["assignees"], [{"login": "jennajh"}])

    def test_existing_unassigned_issue_gets_manifest_assignee_without_body_changes(self):
        fake = FakeGhRunner()
        self.apply(fake)
        fake.issues[0]["assignees"] = []
        before = fake.issues[0]["body"]
        fake.commands.clear()
        self.apply(fake)
        self.assertEqual(fake.issues[0]["assignees"], [{"login": "terryhh"}])
        self.assertEqual(fake.issues[0]["body"], before)
        edits = [c for c in fake.commands if c[1:3] == ["issue", "edit"]]
        self.assertEqual(len(edits), 1)
        self.assertNotIn("--remove-assignee", edits[0])

    def test_existing_human_and_jenna_assignments_are_preserved(self):
        fake = FakeGhRunner()
        self.apply(fake)
        fake.issues[0]["assignees"] = [{"login": "another-cook"}, {"login": "jennajh"}]
        fake.commands.clear()
        self.apply(fake)
        self.assertEqual(fake.issues[0]["assignees"], [{"login": "another-cook"}, {"login": "jennajh"}])
        self.assertEqual(fake.issues[1]["assignees"], [{"login": "jennajh"}])
        self.assertFalse(any(c[1:3] == ["issue", "edit"] for c in fake.commands))

    def test_new_human_claim_since_listing_is_preserved(self):
        fake = FakeGhRunner()
        self.apply(fake)
        fake.issues[0]["assignees"] = []
        fake.claim_on_view = "jennajh"
        fake.commands.clear()
        self.apply(fake)
        self.assertEqual(fake.issues[0]["assignees"], [{"login": "jennajh"}])
        self.assertFalse(any(c[1:3] == ["issue", "edit"] for c in fake.commands))

    def test_unknown_assignment_metadata_stops_before_writes(self):
        fake = FakeGhRunner()
        self.apply(fake)
        del fake.issues[0]["assignees"]
        fake.commands.clear()
        with self.assertRaisesRegex(publisher.PublishError, "assignment metadata"):
            self.apply(fake)
        self.assertFalse(any(c[1:3] in (["issue", "edit"], ["project", "item-edit"]) for c in fake.commands))

    def test_second_apply_reuses_issues_and_items_without_changing_bodies(self):
        fake = FakeGhRunner()
        self.apply(fake)
        fake.issues[0]["body"] += "\nHuman review notes preserved."
        fake.commands.clear()
        self.apply(fake)
        self.assertFalse(any(cmd[1:3] in (["issue", "create"], ["project", "item-add"]) for cmd in fake.commands))
        self.assertIn("Human review notes preserved", fake.issues[0]["body"])

    def test_resume_after_ambiguous_partial_failure_does_not_duplicate_issue(self):
        fake = FakeGhRunner()
        fake.fail_edit_once = True
        with self.assertRaises(publisher.PublishError) as error:
            self.apply(fake)
        self.assertNotIn("SECRET_TOKEN", str(error.exception))
        self.assertEqual(len(fake.issues), 1)
        self.apply(fake)
        self.assertEqual(len(fake.issues), 2)
        self.assertEqual(len(fake.items), 2)

    def test_duplicate_project_titles_stop_before_issue_writes(self):
        fake = FakeGhRunner()
        fake.projects.append({"id": "PVT_other", "number": 8, "title": "SousSight"})
        with self.assertRaisesRegex(publisher.PublishError, "exactly one"):
            self.apply(fake)
        self.assertEqual(fake.issues, [])
        self.apply(fake, project_number=7)
        self.assertEqual(len(fake.issues), 2)

    def test_duplicate_markers_stop_before_any_new_issue(self):
        fake = FakeGhRunner()
        fake.issues = [{"body": publisher.marker("SS-001"), "html_url": f"https://github.com/terryhh/SousSight/issues/{n}"} for n in (1, 2)]
        with self.assertRaisesRegex(publisher.PublishError, "Multiple issues"):
            self.apply(fake)
        self.assertEqual(fake.items, [])
        self.assertEqual(len(fake.issues), 2)

    def test_backlog_column_accepts_todo_tasks(self):
        fake = FakeGhRunner()
        fake.options[0] = {"id": "backlog-id", "name": "Backlog"}
        self.apply(fake)
        self.assertEqual(fake.statuses["PVTI_2"], "backlog-id")

    def test_explicit_todo_takes_precedence_over_backlog(self):
        fake = FakeGhRunner()
        fake.options.append({"id": "backlog-id", "name": "Backlog"})
        self.apply(fake)
        self.assertEqual(fake.statuses["PVTI_2"], "todo-id")

    def test_missing_status_option_stops_before_issue_writes(self):
        fake = FakeGhRunner()
        fake.options = fake.options[:1]
        with self.assertRaisesRegex(publisher.PublishError, "Status must offer"):
            self.apply(fake)
        self.assertEqual(fake.issues, [])

    def test_incomplete_listing_is_not_treated_as_missing_items(self):
        with self.assertRaisesRegex(publisher.PublishError, "Incomplete"):
            publisher.complete_page({"items": [], "totalCount": 1}, "items")

    def test_dependency_order_is_independent_of_manifest_order(self):
        data = manifest()
        data["tasks"].reverse()
        self.assertEqual([task["id"] for task in publisher.ordered_tasks(data)], ["SS-001", "SS-002"])

    def test_manifest_rejects_unverified_done_unknown_dependency_and_cycles(self):
        for mutation in ("done", "unknown", "cycle"):
            data = manifest()
            if mutation == "done":
                data["tasks"][0]["status"] = "Done"
            elif mutation == "unknown":
                data["tasks"][0]["dependsOn"] = ["SS-999"]
            else:
                data["tasks"][0]["dependsOn"] = ["SS-002"]
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "manifest.json"
                path.write_text(json.dumps(data))
                with self.assertRaises(publisher.PublishError):
                    publisher.load_manifest(path)

    def test_manifest_requires_one_explicit_github_login_per_task(self):
        for invalid in (None, "", "@terryhh", "terryhh,jennajh", "-owner", "owner-", "a" * 40):
            with self.subTest(assignee=invalid), tempfile.TemporaryDirectory() as temp:
                data = manifest()
                if invalid is None:
                    del data["tasks"][0]["assignee"]
                else:
                    data["tasks"][0]["assignee"] = invalid
                path = Path(temp) / "manifest.json"
                path.write_text(json.dumps(data))
                with self.assertRaisesRegex(publisher.PublishError, "GitHub assignee"):
                    publisher.load_manifest(path)

    def test_local_concurrent_publisher_is_rejected_without_deleting_lock(self):
        with publisher.publisher_lock("terryhh/SousSight-test-lock"):
            with self.assertRaisesRegex(publisher.PublishError, "Another local"):
                with publisher.publisher_lock("terryhh/SousSight-test-lock"):
                    self.fail("Second publisher acquired lock")
        with publisher.publisher_lock("terryhh/SousSight-test-lock"):
            pass

    def test_real_backlog_has_sister_task_and_no_unverified_done(self):
        data = publisher.load_manifest(ROOT / "docs/backlog.json")
        sister = next(task for task in data["tasks"] if task["id"] == "SS-005")
        self.assertIn("AGY-COOKING-RESEARCH.md", sister["description"])
        self.assertIn("AGY", sister["owner"])
        self.assertEqual(sister["assignee"], "jennajh")
        # Validate explicit owners without assuming future pickup work belongs to Terry.
        self.assertTrue(all(task["assignee"] in {"terryhh", "jennajh"} for task in data["tasks"]))
        self.assertEqual(next(task for task in data["tasks"] if task["id"] == "SS-005")["assignee"], "jennajh")
        self.assertTrue(all(task["status"] != "Done" or task["verified"] is True for task in data["tasks"]))


if __name__ == "__main__":
    unittest.main()
