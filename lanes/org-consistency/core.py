#!/usr/bin/env python3
"""Credential-less org-consistency S1 runner.

The shell entry owns the environment and lock boundary.  This module owns the
JSON state machine so every durable file can be replaced atomically.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any


CHECK_ID = "OC-A"
DEFAULT_ORG = "caty-ai"
DEFAULT_FP_SPEC_VERSION = "2"
LINK_NEXT = re.compile(r'<([^>]+)>\s*;\s*rel="next"')
PATH_TOKEN = re.compile(
    r"(?P<path>(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:md|json|yml|yaml|py|toml|txt|sh))"
)
GITHUB_TARGET = re.compile(
    r"github(?:\\?\.)com(?:/|\\?/)(?P<repo>[A-Za-z0-9_.-]+(?:/|\\?/)[A-Za-z0-9_.-]+)",
    re.IGNORECASE,
)
EXPECTED_OFFLINE_SKIP = re.compile(
    r"^(?:reality|orphan|pin freshness|ci existence) check\s*:\s*skipped$",
    re.IGNORECASE,
)
SUMMARY_CHECK_STATUS = re.compile(
    r"^[a-z ]+check\s*:\s*(?P<status>skipped|degraded)\b",
    re.IGNORECASE,
)
FAILED_HEADER = re.compile(r"^FAILED \(\d+\):$", re.IGNORECASE)
MODULES_SCANNED = re.compile(r"^modules in registry\s*:\s*(?P<count>\d+)\s*$", re.IGNORECASE)


class LaneError(RuntimeError):
    pass


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_write_text(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def atomic_write_json(path: pathlib.Path, value: Any) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def read_json(path: pathlib.Path, default: Any = None) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default
    except (OSError, json.JSONDecodeError) as exc:
        raise LaneError(f"unreadable JSON state {path}: {exc}") from exc


def normalize(value: str) -> str:
    normalized = unicodedata.normalize("NFC", value).lower()
    if os.environ.get("OC_TEST_MUTATE") == "fp-normalize":
        return value
    normalized = re.sub(r"^[a-z][a-z0-9+.-]*://", "", normalized)
    while normalized.startswith("./"):
        normalized = normalized[2:]
    while normalized.endswith("/"):
        normalized = normalized[:-1]
    return normalized


def fingerprint(
    fp_spec_version: str,
    check_id: str,
    repo_id: str,
    file_name: str,
    claim_kind: str,
) -> str:
    fields = [fp_spec_version, check_id, repo_id, normalize(file_name), claim_kind]
    digest = hashlib.sha256()
    for field in fields:
        encoded = str(field).encode("utf-8")
        digest.update(str(len(encoded)).encode("ascii"))
        digest.update(b":")
        digest.update(encoded)
    return digest.hexdigest()


def next_link(header: str | None) -> str | None:
    if not header:
        return None
    match = LINK_NEXT.search(header)
    return match.group(1) if match else None


def repo_record(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise LaneError("org API returned a non-object repository")
    repo_id = raw.get("id")
    name = raw.get("name")
    full_name = raw.get("full_name")
    default_branch = raw.get("default_branch")
    if not isinstance(repo_id, int) or repo_id < 1:
        raise LaneError("org API repository id must be a positive integer")
    if not all(isinstance(item, str) and item for item in (name, full_name, default_branch)):
        raise LaneError(f"org API repository {repo_id} is missing identity fields")
    clone_url = raw.get("clone_url")
    if not isinstance(clone_url, str) or not clone_url:
        clone_url = f"https://github.com/{full_name}.git"
    return {
        "id": repo_id,
        "name": name,
        "full_name": full_name,
        "default_branch": default_branch,
        "clone_url": clone_url,
        "archived": raw.get("archived") is True,
        "private": raw.get("private") is True,
    }


class Runner:
    def __init__(self) -> None:
        self.state_dir = pathlib.Path(os.environ["OC_STATE_DIR"])
        self.lane_dir = pathlib.Path(os.environ["LANE_DIR"])
        self.night_id = os.environ["NIGHT_ID"]
        self.org = os.environ.get("OC_ORG", DEFAULT_ORG)
        self.exclude_names = {
            item.strip()
            for item in os.environ.get("OC_EXCLUDE_REPOS", "").split(",")
            if item.strip()
        }
        self.fp_spec_version = os.environ.get("OC_FP_SPEC_VERSION", DEFAULT_FP_SPEC_VERSION)
        self.retention = self.positive_int("OC_RETENTION_NIGHTS", 400)
        self.check_timeout = self.positive_int("OC_CHECK_TIMEOUT_SEC", 300)
        self.api_fixture = os.environ.get("OC_API_FIXTURE", "")
        self.fixture_git_root = os.environ.get("OC_TEST_FIXTURE_GIT_ROOT", "")
        if self.fixture_git_root and not self.api_fixture:
            raise LaneError("OC_TEST_FIXTURE_GIT_ROOT requires OC_API_FIXTURE")
        self.pause_after_plan = self.nonnegative_int("OC_TEST_PAUSE_AFTER_PLAN_SEC", 0)
        self.plan_path = self.state_dir / f"plan-{self.night_id}.json"
        self.report_json = self.state_dir / "report" / f"{self.night_id}.json"
        self.report_md = self.state_dir / "report" / f"{self.night_id}.md"
        self.findings_path = self.state_dir / "findings.json"
        self.repos_path = self.state_dir / "repos.json"
        self.journal_path = self.state_dir / "journal" / f"{self.night_id}.json"
        self.snapshot_dir = self.state_dir / "snapshots"
        self.baseline = not self.findings_path.exists()
        self.targets: list[dict[str, Any]] = []
        self.target_status = "FRESH"
        self.target_snapshot_night = self.night_id
        self.target_pages = 0
        self.target_incomplete = False
        self.excluded: list[dict[str, Any]] = []
        self.renamed: list[dict[str, Any]] = []
        self.branch_changed: list[dict[str, Any]] = []
        self.left_scope: list[dict[str, Any]] = []
        self.events: list[dict[str, Any]] = []
        self.observations: list[dict[str, Any]] = []
        self.new_findings: list[dict[str, Any]] = []
        self.resolved: list[dict[str, Any]] = []
        self.repo_state: dict[str, Any] = {"repos": {}}
        self.plan: dict[str, Any] = {}
        self.settings = {
            "OC_ORG": self.org,
            "OC_EXCLUDE_REPOS": ",".join(sorted(self.exclude_names)),
            "OC_FP_SPEC_VERSION": self.fp_spec_version,
            "OC_RETENTION_NIGHTS": self.retention,
            "OC_CHECK_TIMEOUT_SEC": self.check_timeout,
            "OC_L2_MAX_REPOS": self.positive_int("OC_L2_MAX_REPOS", 3),
            "OC_H_MAX_REPOS": self.positive_int("OC_H_MAX_REPOS", 2),
            "OC_L3_MAX_REPOS": self.positive_int("OC_L3_MAX_REPOS", 3),
            "OC_L3_WEEKDAY": self.positive_int("OC_L3_WEEKDAY", 7),
            "OC_STALE_ESCALATE_NIGHTS": self.positive_int("OC_STALE_ESCALATE_NIGHTS", 3),
            "OC_ZERO_STREAK_NIGHTS": self.positive_int("OC_ZERO_STREAK_NIGHTS", 5),
            "OC_API_MODE": "fixture" if self.api_fixture else "anonymous-github",
            "OC_GIT_TRANSPORT": "fixture" if self.fixture_git_root else "origin",
        }

    @staticmethod
    def positive_int(name: str, default: int) -> int:
        raw = os.environ.get(name, str(default))
        if not raw.isdigit() or int(raw) < 1:
            raise LaneError(f"{name} must be a positive integer")
        return int(raw)

    @staticmethod
    def nonnegative_int(name: str, default: int) -> int:
        raw = os.environ.get(name, str(default))
        if not raw.isdigit():
            raise LaneError(f"{name} must be a non-negative integer")
        return int(raw)

    def prepare_dirs(self) -> None:
        for path in (
            self.state_dir / "mirrors",
            self.state_dir / "journal",
            self.state_dir / "report",
            self.state_dir / "snapshots",
            self.state_dir / "diffs",
        ):
            if path.is_symlink() or (path.exists() and not path.is_dir()):
                raise LaneError(f"unsafe state directory: {path}")
            path.mkdir(parents=True, exist_ok=True)

    def fetch_fixture_pages(self) -> tuple[list[dict[str, Any]], int, bool]:
        if os.environ.get("OC_TEST_API_FAIL") == "1":
            raise LaneError("fixture API failure requested")
        fixture = read_json(pathlib.Path(self.api_fixture))
        if isinstance(fixture, list):
            pages: list[Any] = [{"repos": fixture, "link": None}]
        elif isinstance(fixture, dict) and isinstance(fixture.get("pages"), list):
            pages = fixture["pages"]
        else:
            raise LaneError("OC_API_FIXTURE must be an array or an object with pages")
        repos: list[dict[str, Any]] = []
        incomplete = False
        page_index = 0
        while True:
            if page_index >= len(pages):
                raise LaneError("fixture Link pagination points past the final page")
            page = pages[page_index]
            if isinstance(page, list):
                payload = page
                link = None
            elif isinstance(page, dict):
                payload = page.get("repos")
                link = page.get("link")
            else:
                raise LaneError("fixture page must be an array or object")
            if not isinstance(payload, list):
                raise LaneError("fixture page repos must be an array")
            incomplete = incomplete or len(payload) == 100
            repos.extend(repo_record(item) for item in payload)
            if os.environ.get("OC_TEST_MUTATE") == "target-selection":
                break
            if not next_link(link if isinstance(link, str) else None):
                break
            page_index += 1
        return repos, page_index + 1, incomplete

    def fetch_live_pages(self) -> tuple[list[dict[str, Any]], int, bool]:
        url: str | None = (
            f"https://api.github.com/orgs/{self.org}/repos?per_page=100&type=public"
        )
        repos: list[dict[str, Any]] = []
        pages = 0
        incomplete = False
        while url:
            request = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "alpha-nightshift-org-consistency",
                    "Accept": "application/vnd.github+json",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    if response.status != 200:
                        raise LaneError(f"org API returned HTTP {response.status}")
                    payload = json.loads(response.read().decode("utf-8"))
                    link = response.headers.get("Link")
            except (OSError, urllib.error.URLError, json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise LaneError(f"org API request failed: {exc}") from exc
            if not isinstance(payload, list):
                raise LaneError("org API payload was not an array")
            pages += 1
            incomplete = incomplete or len(payload) == 100
            repos.extend(repo_record(item) for item in payload)
            if os.environ.get("OC_TEST_MUTATE") == "target-selection":
                break
            url = next_link(link)
        return repos, pages, incomplete

    def previous_snapshot(self) -> dict[str, Any] | None:
        candidates = sorted(
            path for path in self.snapshot_dir.glob("repos-*.json")
            if path.name != f"repos-{self.night_id}.json"
        )
        for path in reversed(candidates):
            value = read_json(path)
            if isinstance(value, dict) and isinstance(value.get("repos"), list):
                return value
        return None

    def determine_targets(self) -> None:
        try:
            if self.api_fixture:
                raw_repos, self.target_pages, self.target_incomplete = self.fetch_fixture_pages()
            else:
                raw_repos, self.target_pages, self.target_incomplete = self.fetch_live_pages()
            snapshot = {
                "night_id": self.night_id,
                "fetched_at": iso_now(),
                "pages": self.target_pages,
                "incomplete": self.target_incomplete,
                "repos": raw_repos,
            }
            atomic_write_json(self.snapshot_dir / f"repos-{self.night_id}.json", snapshot)
        except LaneError as exc:
            snapshot = self.previous_snapshot()
            if snapshot is None:
                self.target_status = "UNAVAILABLE"
                self.events.append({"type": "TARGETS-UNAVAILABLE", "detail": str(exc)})
                return
            raw_repos = [repo_record(item) for item in snapshot["repos"]]
            self.target_status = "STALE"
            self.target_snapshot_night = str(snapshot.get("night_id", "unknown"))
            self.target_pages = int(snapshot.get("pages", 0))
            self.target_incomplete = bool(snapshot.get("incomplete", False))
            self.events.append(
                {"type": "TARGETS-STALE", "snapshot_night": self.target_snapshot_night}
            )

        seen_ids: set[int] = set()
        for repo in raw_repos:
            if repo["id"] in seen_ids:
                raise LaneError(f"duplicate repository id from org API: {repo['id']}")
            seen_ids.add(repo["id"])
            reason = ""
            if repo["archived"]:
                reason = "archived"
            elif repo["private"]:
                reason = "private"
            elif repo["name"] in self.exclude_names or repo["full_name"] in self.exclude_names:
                reason = "configured"
            if reason:
                self.excluded.append({"id": repo["id"], "name": repo["full_name"], "reason": reason})
            else:
                self.targets.append(repo)
        self.targets.sort(key=lambda item: item["id"])

    def update_repo_identity_state(self) -> None:
        prior = self.load_repo_identity_state()
        self.repo_state = prior
        current_ids = {str(repo["id"]) for repo in self.targets}
        for old_id, old in prior["repos"].items():
            if old_id not in current_ids:
                self.left_scope.append({"id": int(old_id), "name": old.get("full_name", old.get("name", "unknown"))})
        for repo in self.targets:
            key = str(repo["id"])
            old = prior["repos"].get(key)
            if old:
                if old.get("full_name") != repo["full_name"]:
                    event = {"type": "RENAMED", "repo_id": repo["id"], "from": old.get("full_name"), "to": repo["full_name"]}
                    self.renamed.append(event)
                    self.events.append(event)
                if old.get("default_branch") != repo["default_branch"]:
                    event = {"type": "BRANCH-CHANGED", "repo_id": repo["id"], "from": old.get("default_branch"), "to": repo["default_branch"]}
                    self.branch_changed.append(event)
                    self.events.append(event)
                name_history = list(old.get("name_history", []))
                branch_history = list(old.get("default_branch_history", []))
                first_seen = old.get("first_seen", self.night_id)
            else:
                name_history = []
                branch_history = []
                first_seen = self.night_id
            if not name_history or name_history[-1].get("full_name") != repo["full_name"]:
                name_history.append({"night_id": self.night_id, "full_name": repo["full_name"]})
            if not branch_history or branch_history[-1].get("branch") != repo["default_branch"]:
                branch_history.append({"night_id": self.night_id, "branch": repo["default_branch"]})
            prior["repos"][key] = {
                "id": repo["id"],
                "name": repo["name"],
                "full_name": repo["full_name"],
                "default_branch": repo["default_branch"],
                "clone_url": repo["clone_url"],
                "first_seen": first_seen,
                "last_seen": self.night_id,
                "name_history": name_history,
                "default_branch_history": branch_history,
            }

    def load_repo_identity_state(self) -> dict[str, Any]:
        prior = read_json(self.repos_path, {"repos": {}})
        if not isinstance(prior, dict) or not isinstance(prior.get("repos"), dict):
            raise LaneError("repos.json has an invalid schema")
        return prior

    def planned_targets(self) -> list[dict[str, Any]]:
        family_os = f"{self.org}/family-os".lower()
        return [repo for repo in self.targets if repo["full_name"].lower() == family_os]

    def write_initial_plan(self) -> None:
        self.plan = {
            "night_id": self.night_id,
            "created_at": iso_now(),
            "checks": [CHECK_ID],
            "cells": [
                {"check_id": CHECK_ID, "repo_id": repo["id"], "repo": repo["full_name"]}
                for repo in self.planned_targets()
            ],
        }
        atomic_write_json(self.plan_path, self.plan)

    def effective_cells(self) -> list[dict[str, Any]]:
        result = []
        for cell in self.plan.get("cells", []):
            item = dict(cell)
            if isinstance(cell.get("result"), dict):
                item.update(cell["result"])
            else:
                status = "RUN" if os.environ.get("OC_TEST_MUTATE") == "notrun" else "NOT-RUN"
                item.update({"status": status, "reason": "missing-result", "fresh": status == "RUN", "metrics": {"scanned": 0, "extracted": 0, "flagged": 0}})
            item.pop("result", None)
            result.append(item)
        return result

    def targets_label(self) -> str:
        label = "TARGETS: FRESH"
        if self.target_status == "STALE":
            label = f"TARGETS: STALE ({self.target_snapshot_night})"
        elif self.target_status == "UNAVAILABLE":
            label = "TARGETS: UNAVAILABLE"
        if self.target_incomplete:
            label += " / TARGETS: INCOMPLETE"
        return label

    def report_value(self, complete: bool) -> dict[str, Any]:
        cells = self.effective_cells()
        counts = {state: sum(1 for cell in cells if cell["status"] == state) for state in ("RUN", "NO-INPUT", "STALE-INPUT", "NOT-RUN")}
        metrics = {"scanned": 0, "extracted": 0, "flagged": 0}
        for cell in cells:
            for key in metrics:
                metrics[key] += int(cell.get("metrics", {}).get(key, 0))
        report: dict[str, Any] = {
            "night_id": self.night_id,
            "published_at": iso_now(),
            "targets_label": self.targets_label(),
            "scope": {
                "target_repos": len(self.targets),
                "excluded": self.excluded,
                "renamed": self.renamed,
                "branch_changed": self.branch_changed,
                "left_scope": self.left_scope,
                "no_input": counts["NO-INPUT"],
                "not_run": counts["NOT-RUN"],
                "stale_input": counts["STALE-INPUT"],
                "deferred": 0,
                "target_pages": self.target_pages,
            },
            "effective_settings": self.settings,
            "check_metrics": {CHECK_ID: metrics},
            "cells": cells,
            "events": self.events,
            "findings": {
                "new": self.new_findings,
                "resolved_candidates": self.resolved,
                "baseline": [item for item in self.new_findings if item.get("baseline")],
            },
            "digest_mapping": {
                "not_run_many": "ABORTED-equivalent",
                "all_run_zero_findings": "ZERO-equivalent",
            },
        }
        if complete:
            report["complete"] = True
        return report

    def report_markdown(self, report: dict[str, Any]) -> str:
        scope = report["scope"]
        lines = [
            f"# org-consistency — {self.night_id}",
            "",
            f"- {report['targets_label']}",
            f"- TARGET REPOS: {scope['target_repos']}",
            f"- EXCLUDED: {len(scope['excluded'])}",
            f"- RENAMED: {len(scope['renamed'])}",
            f"- BRANCH-CHANGED: {len(scope['branch_changed'])}",
            f"- LEFT-SCOPE: {len(scope['left_scope'])}",
            f"- NO-INPUT: {scope['no_input']}",
            f"- NOT-RUN: {scope['not_run']}",
            f"- STALE-INPUT: {scope['stale_input']}",
            f"- deferred: {scope['deferred']}",
        ]
        if report.get("complete") is True:
            lines.append("- COMPLETE: yes")
        lines.extend(
            [
                "",
                "## Digest vocabulary mapping",
                "",
                f"- many NOT-RUN cells: {report['digest_mapping']['not_run_many']}",
                f"- all RUN with zero findings: {report['digest_mapping']['all_run_zero_findings']}",
                "",
                "## Effective settings",
                "",
            ]
        )
        for key, value in sorted(report["effective_settings"].items()):
            lines.append(f"- {key}={value}")
        metrics = report["check_metrics"][CHECK_ID]
        lines.extend(
            [
                "",
                "## Check coverage",
                "",
                f"- {CHECK_ID}: scanned={metrics['scanned']} extracted={metrics['extracted']} flagged={metrics['flagged']}",
                "",
                "## Cells",
                "",
                "| check | repo id | repo | state | reason |",
                "|---|---:|---|---|---|",
            ]
        )
        for cell in report["cells"]:
            lines.append(f"| {cell['check_id']} | {cell['repo_id']} | {cell['repo']} | {cell['status']} | {cell.get('reason', '')} |")
        lines.extend(["", "## Findings", ""])
        for item in report["findings"]["new"]:
            prefix = "baseline" if item.get("baseline") else "new"
            lines.append(f"- [{prefix}] `{item['fingerprint']}` {item['claim']}")
        if not report["findings"]["new"]:
            lines.append("- none")
        lines.extend(["", "## Resolved candidates", ""])
        for item in report["findings"]["resolved_candidates"]:
            lines.append(f"- `{item['fingerprint']}` {item['claim']}")
        if not report["findings"]["resolved_candidates"]:
            lines.append("- none")
        return "\n".join(lines) + "\n"

    def publish_report(self, complete: bool = False) -> None:
        report = self.report_value(complete)
        atomic_write_json(self.report_json, report)
        atomic_write_text(self.report_md, self.report_markdown(report))

    def git_command(
        self,
        mirror: pathlib.Path,
        *args: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        command = ["git"]
        command.extend(["-C", str(mirror), *args])
        git_env = {
            key: value
            for key, value in os.environ.items()
            if key in {"PATH", "HOME", "TMPDIR", "LANG", "TERM"}
        }
        git_env.update(
            {
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
            }
        )
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=git_env,
            check=False,
        )
        if check and result.returncode != 0:
            raise LaneError(result.stdout.strip() or f"git command failed: {' '.join(args)}")
        return result

    @staticmethod
    def family_remote_is_canonical(url: str) -> bool:
        value = url.strip().lower()
        value = re.sub(r"^git@github\.com:", "github.com/", value)
        value = re.sub(r"^(?:https?|ssh)://(?:git@)?", "", value)
        return value.rstrip("/").removesuffix(".git") == "github.com/caty-ai/family-os"

    def sync_mirror(self, repo: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
        mirror = self.state_dir / "mirrors" / str(repo["id"])
        if mirror.is_symlink() or (mirror.exists() and not mirror.is_dir()):
            return False, {"reason": "unsafe-mirror-path"}
        mirror.mkdir(parents=True, exist_ok=True)
        if (mirror / ".git").is_symlink():
            return False, {"reason": "unsafe-mirror-gitdir"}
        if not (mirror / ".git").is_dir():
            init = self.git_command(mirror, "init", check=False)
            if init.returncode != 0:
                return False, {"reason": "mirror-init-failed", "detail": init.stdout[-500:]}
        origin = self.git_command(mirror, "remote", "get-url", "origin", check=False)
        if origin.returncode == 0:
            if origin.stdout.strip() != repo["clone_url"]:
                changed = self.git_command(mirror, "remote", "set-url", "origin", repo["clone_url"], check=False)
                if changed.returncode != 0:
                    return False, {"reason": "remote-update-failed", "detail": changed.stdout[-500:]}
        else:
            added = self.git_command(mirror, "remote", "add", "origin", repo["clone_url"], check=False)
            if added.returncode != 0:
                return False, {"reason": "remote-add-failed", "detail": added.stdout[-500:]}
        old_head_result = self.git_command(mirror, "rev-parse", "--verify", "HEAD", check=False)
        old_head = old_head_result.stdout.strip() if old_head_result.returncode == 0 else ""
        rewrites = self.git_command(
            mirror,
            "config",
            "--local",
            "--get-regexp",
            r"^url\..*\.(insteadof|pushinsteadof)$",
            check=False,
        )
        if rewrites.returncode == 0 and rewrites.stdout.strip():
            return False, {"reason": "git-url-rewrite-refused", "detail": rewrites.stdout[-500:], "old_head": old_head}
        fetch_remote = "origin"
        if self.fixture_git_root:
            fetch_remote = (
                pathlib.Path(self.fixture_git_root).resolve() / f"{repo['name']}.git"
            ).as_uri()
        fetched = self.git_command(
            mirror,
            "fetch",
            "--depth",
            "1",
            fetch_remote,
            repo["default_branch"],
            check=False,
        )
        if fetched.returncode != 0:
            return False, {"reason": "fetch-failed", "detail": fetched.stdout[-500:], "old_head": old_head}
        try:
            new_head = self.git_command(mirror, "rev-parse", "FETCH_HEAD").stdout.strip()
        except LaneError as exc:
            return False, {"reason": "mirror-finalize-failed", "detail": str(exc)[-500:], "old_head": old_head}
        if old_head:
            diff = self.git_command(mirror, "diff", "--stat", "HEAD", "FETCH_HEAD", check=False).stdout
        else:
            diff = "(bootstrap)\n"
        diff_path = self.state_dir / "diffs" / self.night_id / f"{repo['id']}.stat"
        atomic_write_text(diff_path, diff)
        try:
            self.git_command(mirror, "update-ref", f"refs/heads/{repo['default_branch']}", "FETCH_HEAD")
            self.git_command(mirror, "symbolic-ref", "HEAD", f"refs/heads/{repo['default_branch']}")
        except LaneError as exc:
            return False, {"reason": "mirror-finalize-failed", "detail": str(exc)[-500:], "old_head": old_head, "new_head": new_head}
        reset = self.git_command(mirror, "reset", "--hard", "FETCH_HEAD", check=False)
        if reset.returncode != 0:
            return False, {"reason": "reset-failed", "detail": reset.stdout[-500:], "old_head": old_head, "new_head": new_head}
        repo_state = self.repo_state["repos"][str(repo["id"])]
        repo_state["previous_head"] = old_head or None
        repo_state["head"] = new_head
        repo_state["head_night"] = self.night_id
        return True, {"mirror": str(mirror), "old_head": old_head or None, "new_head": new_head, "diff_stat": str(diff_path.relative_to(self.state_dir))}

    @staticmethod
    def checker_degraded(stdout: str) -> bool:
        for line in stdout.splitlines():
            stripped = line.strip()
            if os.environ.get("OC_TEST_MUTATE") == "degraded-whole-stdout":
                lowered = stripped.lower()
                if "degraded" in lowered:
                    return True
                if "skipped" in lowered and not EXPECTED_OFFLINE_SKIP.match(stripped):
                    return True
                continue
            if FAILED_HEADER.match(stripped):
                break
            summary = SUMMARY_CHECK_STATUS.match(stripped)
            if not summary:
                continue
            if summary.group("status").lower() == "degraded":
                return True
            if not EXPECTED_OFFLINE_SKIP.match(stripped):
                return True
        return False

    @staticmethod
    def parse_checker_failures(stdout: str) -> list[str]:
        failures: list[str] = []
        in_failures = False
        for line in stdout.splitlines():
            stripped = line.strip()
            if FAILED_HEADER.match(stripped):
                in_failures = True
                continue
            if in_failures and stripped.startswith("- "):
                failures.append(stripped[2:].strip())
                continue
            if in_failures and stripped:
                break
        return failures

    @staticmethod
    def parse_checker_scanned(stdout: str) -> int:
        for line in stdout.splitlines():
            match = MODULES_SCANNED.match(line.strip())
            if match:
                return int(match.group("count"))
        return 1

    @staticmethod
    def failure_discriminator(failure: str) -> str:
        normalized = unicodedata.normalize("NFC", failure).lower()
        normalized = re.sub(r"\d+", "#", normalized)
        normalized = re.sub(r"\s+", " ", normalized).strip()
        return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]

    def finding_from_failure(self, repo: dict[str, Any], failure: str) -> dict[str, Any]:
        pieces = [piece.strip() for piece in failure.split(":", 2)]
        structured = len(pieces) > 1
        check_name = normalize(pieces[0]) if structured and pieces[0] else "unknown"
        path_match = PATH_TOKEN.search(failure)
        file_name = path_match.group("path") if path_match else "registry/modules.json"
        github_target = GITHUB_TARGET.search(failure)
        if github_target:
            target_token = normalize(github_target.group("repo").replace("\\/", "/"))
        else:
            if structured and pieces[1]:
                target_token = normalize(pieces[1])
            elif path_match:
                target_token = normalize(file_name)
            else:
                target_token = "unknown"
        discriminator = self.failure_discriminator(failure)
        # S1 has never run in production, so enriching v2 IDs needs no version bump or migration.
        claim_kind = f"regcheck:{check_name}:{target_token}:{discriminator}"
        if os.environ.get("OC_TEST_MUTATE") == "failure-identity":
            claim_kind = f"regcheck:{check_name}:{target_token}"
        fp = fingerprint(self.fp_spec_version, CHECK_ID, str(repo["id"]), file_name, claim_kind)
        return {
            "fingerprint": fp,
            "fp_spec_version": self.fp_spec_version,
            "check_id": CHECK_ID,
            "repo_id": repo["id"],
            "repo": repo["full_name"],
            "file": file_name,
            "claim_kind": claim_kind,
            "claim": failure,
        }

    def run_oc_a(self, repo: dict[str, Any], mirror_meta: dict[str, Any]) -> dict[str, Any]:
        mirror = pathlib.Path(mirror_meta["mirror"])
        if repo["full_name"].lower() != f"{self.org}/family-os".lower():
            return {"status": "NO-INPUT", "reason": "not-family-os", "fresh": False, "metrics": {"scanned": 0, "extracted": 0, "flagged": 0}, **mirror_meta}
        # Read the configured URL, not `remote get-url`: the latter expands the
        # test-only url.insteadOf transport and would obscure the trust anchor.
        remote = self.git_command(mirror, "config", "--get", "remote.origin.url", check=False)
        if remote.returncode != 0 or not self.family_remote_is_canonical(remote.stdout):
            return {"status": "NOT-RUN", "reason": "family-os-remote-untrusted", "fresh": False, "metrics": {"scanned": 0, "extracted": 0, "flagged": 0}, **mirror_meta}
        checker = mirror / "tools" / "check_registry.py"
        if not checker.is_file():
            return {"status": "NO-INPUT", "reason": "checker-missing", "fresh": False, "metrics": {"scanned": 0, "extracted": 0, "flagged": 0}, **mirror_meta}
        try:
            result = subprocess.run(
                ["/usr/bin/python3", "-B", "tools/check_registry.py", "--offline"],
                cwd=mirror,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.check_timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return {"status": "NOT-RUN", "reason": "checker-timeout", "fresh": False, "metrics": {"scanned": 1, "extracted": 0, "flagged": 0}, **mirror_meta}
        scanned = self.parse_checker_scanned(result.stdout)
        failures = self.parse_checker_failures(result.stdout)
        failed_block = any(FAILED_HEADER.match(line.strip()) for line in result.stdout.splitlines())
        if (
            result.returncode == 0
            and failed_block
            and os.environ.get("OC_TEST_MUTATE") != "rc0-contract"
        ):
            return {
                "status": "NOT-RUN",
                "reason": "checker-contract-violation",
                "fresh": False,
                "checker_exit": result.returncode,
                "checker_stdout": result.stdout[-4000:],
                "checker_stderr": result.stderr[-1000:],
                "metrics": {"scanned": scanned, "extracted": len(failures), "flagged": 0},
                **mirror_meta,
            }
        if result.returncode == 0:
            failures = []
        if result.returncode != 0 and not result.stdout.strip():
            return {"status": "NOT-RUN", "reason": "checker-nonzero-without-stdout", "fresh": False, "checker_exit": result.returncode, "metrics": {"scanned": scanned, "extracted": 0, "flagged": 0}, **mirror_meta}
        if result.returncode != 0 and not failures:
            first_line = next(
                (line.strip() for line in result.stdout.splitlines() if line.strip()),
                "non-empty stdout",
            )
            failures = [
                f"checker: tools/check_registry.py: exit {result.returncode}: {first_line[:300]}"
            ]
        observations = [self.finding_from_failure(repo, failure) for failure in failures]
        self.observations.extend(observations)
        stale = self.checker_degraded(result.stdout)
        status = "STALE-INPUT" if stale else "RUN"
        return {
            "status": status,
            "reason": "checker-degraded" if stale else "checker-complete",
            "fresh": not stale,
            "checker_exit": result.returncode,
            "checker_stdout": result.stdout[-4000:],
            "checker_stderr": result.stderr[-1000:],
            "metrics": {"scanned": scanned, "extracted": len(failures), "flagged": len(observations)},
            **mirror_meta,
        }

    def set_cell_result(self, repo_id: int, result: dict[str, Any]) -> None:
        for cell in self.plan["cells"]:
            if cell["check_id"] == CHECK_ID and cell["repo_id"] == repo_id:
                cell["result"] = result
                atomic_write_json(self.plan_path, self.plan)
                return
        raise LaneError(f"result does not match write-ahead plan: {CHECK_ID}/{repo_id}")

    def run_cells(self) -> None:
        for repo in self.planned_targets():
            synced, mirror_meta = self.sync_mirror(repo)
            if not synced:
                result = {"status": "NOT-RUN", "fresh": False, "metrics": {"scanned": 0, "extracted": 0, "flagged": 0}, **mirror_meta}
            else:
                result = self.run_oc_a(repo, mirror_meta)
                if self.target_status == "STALE" and result["status"] == "RUN":
                    result["status"] = "STALE-INPUT"
                    result["reason"] = "targets-stale"
                    result["fresh"] = False
            self.set_cell_result(repo["id"], result)
            self.publish_report(complete=False)

    def reconcile_findings(self) -> None:
        ledger = read_json(self.findings_path, {"fp_spec_version": self.fp_spec_version, "findings": []})
        if not isinstance(ledger, dict) or not isinstance(ledger.get("findings"), list):
            raise LaneError("findings.json has an invalid schema")
        if ledger.get("fp_spec_version") != self.fp_spec_version:
            raise LaneError("fp_spec_version migration is outside S1 and must fail closed")
        by_fp = {item.get("fingerprint"): item for item in ledger["findings"] if isinstance(item, dict)}
        observed = {item["fingerprint"] for item in self.observations}
        for finding in self.observations:
            existing = by_fp.get(finding["fingerprint"])
            if existing is not None:
                existing["last_seen"] = self.night_id
                if existing.get("status") != "open":
                    previous_status = existing.get("status")
                    existing["status"] = "open"
                    existing.pop("resolved_candidate_night", None)
                    self.events.append(
                        {
                            "type": "REOPENED",
                            "fingerprint": finding["fingerprint"],
                            "from": previous_status,
                        }
                    )
                else:
                    self.events.append({"type": "SEEN", "fingerprint": finding["fingerprint"]})
                continue
            entry = {
                **finding,
                "first_seen": self.night_id,
                "last_seen": self.night_id,
                "status": "open",
                "baseline": self.baseline,
            }
            ledger["findings"].append(entry)
            by_fp[entry["fingerprint"]] = entry
            self.new_findings.append(entry)
            self.events.append({"type": "OPENED", "fingerprint": entry["fingerprint"], "baseline": self.baseline})
        fresh_cells = {(cell["check_id"], cell["repo_id"]) for cell in self.effective_cells() if cell["status"] == "RUN" and cell.get("fresh") is True}
        for entry in ledger["findings"]:
            if entry.get("status") != "open" or entry.get("fingerprint") in observed:
                continue
            if (entry.get("check_id"), entry.get("repo_id")) not in fresh_cells:
                continue
            if entry.get("baseline") is True:
                entry["status"] = "resolved"
                event_type = "BASELINE-RESOLVED"
            else:
                entry["status"] = "resolved-candidate"
                entry["resolved_candidate_night"] = self.night_id
                event_type = "RESOLVED-CANDIDATE"
                self.resolved.append(entry)
            self.events.append({"type": event_type, "fingerprint": entry["fingerprint"]})
        ledger["findings"].sort(key=lambda item: item.get("fingerprint", ""))
        atomic_write_json(self.findings_path, ledger)

    def write_journal(self) -> None:
        journal = {
            "night_id": self.night_id,
            "written_at": iso_now(),
            "baseline": self.baseline,
            "targets": {"status": self.target_status, "snapshot_night": self.target_snapshot_night, "incomplete": self.target_incomplete},
            "cells": self.effective_cells(),
            "events": self.events,
            "new_findings": [item["fingerprint"] for item in self.new_findings],
            "resolved_candidates": [item["fingerprint"] for item in self.resolved],
        }
        atomic_write_json(self.journal_path, journal)

    def prune(self) -> None:
        collections = (
            ("plan-*.json", self.state_dir),
            ("*.json", self.state_dir / "journal"),
            ("repos-*.json", self.state_dir / "snapshots"),
            ("*", self.state_dir / "diffs"),
        )
        for pattern, directory in collections:
            paths = sorted(directory.glob(pattern))
            for path in paths[:-self.retention]:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()

    def run(self) -> int:
        self.prepare_dirs()
        self.determine_targets()
        if self.target_status == "UNAVAILABLE":
            self.repo_state = self.load_repo_identity_state()
        else:
            self.update_repo_identity_state()
        self.write_initial_plan()
        self.publish_report(complete=False)
        if self.pause_after_plan:
            time.sleep(self.pause_after_plan)
        if self.target_status == "UNAVAILABLE":
            atomic_write_json(self.repos_path, self.repo_state)
            self.prune()
            return 2
        self.run_cells()
        self.reconcile_findings()
        atomic_write_json(self.repos_path, self.repo_state)
        self.write_journal()
        self.prune()
        self.publish_report(complete=True)
        return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "fingerprint":
        if len(argv) not in (7, 8):
            print("usage: core.py fingerprint FP_SPEC CHECK REPO_ID FILE CLAIM_KIND [SECTION_ANCHOR]", file=sys.stderr)
            return 2
        # SECTION_ANCHOR is accepted only by this diagnostic surface so tests
        # can prove that heading changes are intentionally outside the ID.
        print(fingerprint(*argv[2:7]))
        return 0
    if len(argv) >= 2 and argv[1] == "normalize":
        if len(argv) != 3:
            print("usage: core.py normalize VALUE", file=sys.stderr)
            return 2
        print(normalize(argv[2]))
        return 0
    if len(argv) >= 2 and argv[1] == "targets":
        try:
            runner = Runner()
            runner.prepare_dirs()
            runner.determine_targets()
            print(json.dumps({
                "status": runner.target_status,
                "pages": runner.target_pages,
                "incomplete": runner.target_incomplete,
                "ids": [repo["id"] for repo in runner.targets],
                "excluded": runner.excluded,
                "label": runner.targets_label(),
            }, sort_keys=True))
            return 0 if runner.target_status != "UNAVAILABLE" else 2
        except (LaneError, KeyError, OSError) as exc:
            print(f"org-consistency: ERROR: {exc}", file=sys.stderr)
            return 2
    if len(argv) != 2 or argv[1] != "run":
        print("usage: core.py run", file=sys.stderr)
        return 2
    try:
        return Runner().run()
    except (LaneError, KeyError, OSError) as exc:
        print(f"org-consistency: ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
