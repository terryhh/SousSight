#!/usr/bin/env python3
"""Publish docs/backlog.json to repository issues and an existing GitHub Project.

Default: offline dry-run. --apply performs the writes already described by the
manifest. Requires gh authentication with repository and project access. Run one
publisher per repository; a local flock prevents concurrent runs on this machine.
Stable issue markers make interrupted runs resumable. Existing issue bodies are
preserved; project Status is synchronized from the manifest on each apply.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class PublishError(Exception):
    pass


class Gh:
    def __init__(self, runner=None):
        self.runner = runner or subprocess.run

    def run(self, args, *, json_output=True):
        try:
            result = self.runner(
                ["gh", *args], capture_output=True, text=True,
                timeout=30, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise PublishError(f"gh {args[0]} did not complete; check CLI/network access.") from error
        if result.returncode:
            # Do not echo raw stderr, arguments, environment, or credential values.
            raise PublishError(
                f"gh {args[0]} {args[1] if len(args) > 1 else ''} failed "
                f"(exit {result.returncode}); check network, login, repository access and project scope."
            )
        if not json_output:
            return result.stdout.strip()
        try:
            return json.loads(result.stdout)
        except (ValueError, TypeError) as error:
            raise PublishError("gh returned invalid JSON; stopped without retrying the command.") from error


def marker(task_id):
    return f"<!-- soussight-backlog:{task_id} -->"


def load_manifest(path):
    with open(path, encoding="utf-8") as source:
        manifest = json.load(source)
    if manifest.get("schemaVersion") != 1:
        raise PublishError("Unsupported backlog schemaVersion.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", manifest.get("repository", "")):
        raise PublishError("Invalid repository name.")
    if not re.fullmatch(r"[A-Za-z0-9-]+", manifest.get("projectOwner", "")):
        raise PublishError("Invalid project owner.")
    if not manifest.get("projectTitle"):
        raise PublishError("Missing project title.")
    tasks = manifest.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise PublishError("The backlog must contain tasks.")
    ids = set()
    for task in tasks:
        task_id = task.get("id", "")
        if not re.fullmatch(r"SS-[0-9]{3}", task_id) or task_id in ids:
            raise PublishError(f"Invalid or duplicate task ID: {task_id!r}")
        ids.add(task_id)
        if task.get("priority") not in ("P0", "P1") or task.get("status") not in ("Todo", "InProgress", "Done"):
            raise PublishError(f"Invalid priority/status for {task_id}.")
        for field in ("title", "owner", "description"):
            if not isinstance(task.get(field), str) or not task[field].strip():
                raise PublishError(f"Missing {field} for {task_id}.")
        for field in ("acceptance", "dependsOn", "evidence"):
            if not isinstance(task.get(field), list) or not all(isinstance(s, str) for s in task[field]):
                raise PublishError(f"Invalid {field} for {task_id}.")
        if not task["acceptance"]:
            raise PublishError(f"Missing acceptance criteria for {task_id}.")
        if task["status"] == "Done" and (task.get("verified") is not True or not task["evidence"]):
            raise PublishError(f"{task_id} cannot be Done without verified=true and evidence.")
    for task in tasks:
        if any(dep not in ids for dep in task["dependsOn"]):
            raise PublishError(f"Unknown dependency for {task['id']}.")
    ordered_tasks(manifest)  # Also reject dependency cycles before any API call.
    return manifest


def ordered_tasks(manifest):
    by_id = {task["id"]: task for task in manifest["tasks"]}
    result, visiting, complete = [], set(), set()

    def visit(task_id):
        if task_id in complete:
            return
        if task_id in visiting:
            raise PublishError(f"Dependency cycle at {task_id}.")
        visiting.add(task_id)
        for dependency in by_id[task_id]["dependsOn"]:
            visit(dependency)
        visiting.remove(task_id)
        complete.add(task_id)
        result.append(by_id[task_id])

    for task in manifest["tasks"]:
        visit(task["id"])
    return result


def complete_page(data, key):
    values = data.get(key)
    if not isinstance(values, list) or data.get("totalCount", len(values)) > len(values):
        raise PublishError(f"Incomplete {key} listing; refusing to guess or create duplicates.")
    return values


def find_project(gh, manifest, number=None):
    owner = manifest["projectOwner"]
    if number is not None:
        project = gh.run(["project", "view", str(number), "--owner", owner, "--format", "json"])
    else:
        projects = complete_page(gh.run([
            "project", "list", "--owner", owner, "--format", "json", "--limit", "1000",
        ]), "projects")
        matches = [p for p in projects if p.get("title") == manifest["projectTitle"] and not p.get("closed")]
        if len(matches) != 1:
            raise PublishError("Expected exactly one open SousSight project; specify --project-number to select it explicitly.")
        project = matches[0]
    if not project.get("id") or not isinstance(project.get("number"), int):
        raise PublishError("Project metadata is incomplete.")
    fields = complete_page(gh.run([
        "project", "field-list", str(project["number"]), "--owner", owner,
        "--format", "json", "--limit", "100",
    ]), "fields")
    status_fields = [field for field in fields if field.get("name") == "Status"]
    if len(status_fields) != 1:
        raise PublishError("Project must have exactly one Status single-select field.")
    field = status_fields[0]
    options = {}
    for option in field.get("options", []):
        name = re.sub(r"[\s_-]", "", option.get("name", "")).lower()
        if name in options:
            raise PublishError("Ambiguous Status options.")
        options[name] = option["id"]
    # GitHub team projects commonly use Backlog instead of Todo.
    if "todo" not in options and "backlog" in options:
        options["todo"] = options["backlog"]
    if not field.get("id") or not all(name in options for name in ("todo", "inprogress", "done")):
        raise PublishError("Status must offer Todo (or Backlog), In Progress and Done options.")
    return project, field["id"], options


def issue_body(task, urls):
    lines = [marker(task["id"]), "", task["description"], "",
             f"Priority: {task['priority']}  ", f"Work owner: {task['owner']}", "", "Acceptance:", ""]
    lines += [f"- [ ] {criterion}" for criterion in task["acceptance"]]
    lines += ["", "Dependencies:", ""]
    lines += [f"- [{dep}]({urls[dep]})" if dep in urls else f"- {dep}" for dep in task["dependsOn"]] or ["- None."]
    lines += ["", "Current evidence:", ""]
    lines += [f"- {evidence}" for evidence in task["evidence"]]
    lines += ["", "Local code or a fake demo alone does not establish real-service verification.", ""]
    return "\n".join(lines)


@contextlib.contextmanager
def publisher_lock(repository):
    name = hashlib.sha256(repository.encode()).hexdigest()[:24]
    path = Path(tempfile.gettempdir()) / f"soussight-backlog-{name}.lock"
    with open(path, "a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PublishError("Another local backlog publisher is running for this repository.") from error
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def publish(manifest, *, gh=None, apply=False, project_number=None, output=print):
    tasks = ordered_tasks(manifest)
    if not apply:
        output(f"DRY RUN: {manifest['repository']} → {manifest['projectOwner']}/{manifest['projectTitle']} (no network or writes)")
        for task in tasks:
            output(f"{task['id']} [{task['priority']}] {task['status']} — {task['title']} — {task['owner']}")
        output("Run with --apply after checking the manifest; optionally select --project-number N.")
        return
    gh = gh or Gh()
    repo, owner = manifest["repository"], manifest["projectOwner"]
    with publisher_lock(repo):
        # Finish all discovery and ambiguity checks before creating anything.
        project, status_field, options = find_project(gh, manifest, project_number)
        pages = gh.run(["api", "--paginate", "--slurp", f"repos/{repo}/issues?state=all&per_page=100"])
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise PublishError("Invalid paginated issue listing.")
        issues = [issue for page in pages for issue in page if "pull_request" not in issue]
        urls = {}
        for task in tasks:
            matches = [issue for issue in issues if marker(task["id"]) in (issue.get("body") or "")]
            if len(matches) > 1:
                raise PublishError(f"Multiple issues contain {task['id']}; resolve duplicates before publishing.")
            if matches:
                urls[task["id"]] = matches[0]["html_url"]
        items = complete_page(gh.run([
            "project", "item-list", str(project["number"]), "--owner", owner,
            "--format", "json", "--limit", "1000",
        ]), "items")
        item_ids = {item.get("content", {}).get("url"): item["id"] for item in items}
        for task in tasks:
            task_id = task["id"]
            if task_id not in urls:
                body_path = None
                try:
                    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", prefix="soussight-issue-", delete=False) as body:
                        body.write(issue_body(task, urls))
                        body_path = body.name
                    url = gh.run([
                        "issue", "create", "--repo", repo,
                        "--title", f"[{task['priority']}] {task_id}: {task['title']}",
                        "--body-file", body_path,
                    ], json_output=False)
                finally:
                    if body_path:
                        os.unlink(body_path)
                urls[task_id] = url
            url = urls[task_id]
            if not re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/issues/[0-9]+", url):
                raise PublishError("Issue URL did not match the intended repository; stopped.")
            item_id = item_ids.get(url)
            if not item_id:
                item = gh.run([
                    "project", "item-add", str(project["number"]), "--owner", owner,
                    "--url", url, "--format", "json",
                ])
                item_id = item.get("id")
                if not item_id:
                    raise PublishError("GitHub did not return a project item ID; rerun to reconcile.")
                item_ids[url] = item_id
            gh.run([
                "project", "item-edit", "--id", item_id, "--project-id", project["id"],
                "--field-id", status_field, "--single-select-option-id", options[task["status"].lower()],
            ], json_output=False)
            output(f"{task_id}: {url} [{task['status']}]")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[1] / "docs/backlog.json")
    parser.add_argument("--project-number", type=int)
    parser.add_argument("--apply", action="store_true", help="Create missing issues, add them to the project, and synchronize Status.")
    args = parser.parse_args(argv)
    try:
        if args.project_number is not None and args.project_number <= 0:
            raise PublishError("Project number must be positive.")
        manifest = load_manifest(args.manifest)
        publish(manifest, apply=args.apply, project_number=args.project_number)
    except (PublishError, OSError, ValueError) as error:
        print(f"Backlog not fully published: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
