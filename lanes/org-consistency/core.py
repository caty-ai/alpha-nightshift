#!/usr/bin/env python3
"""Credential-less org-consistency deterministic layer runner.

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
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any


CHECK_IDS = ("OC-A", "OC-B", "OC-C", "OC-D")
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
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\((?P<target>[^)]+)\)")
GITHUB_REPO_URL = re.compile(
    r"https?://github\.com/(?P<owner>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+)",
    re.IGNORECASE,
)
HEADING = re.compile(r"^(?P<marks>#{1,6})\s+(?P<title>.+?)\s*#*\s*$")
AGENT_PATH_TOKEN = re.compile(r"(?<![A-Za-z0-9_.-])(?P<token>(?:\.?\.?/)?[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)+/?(?:#[^\s`'\"<>)]*)?)")
ALLOWED_AGENT_EXTENSIONS = {
    ".c", ".cc", ".conf", ".cpp", ".css", ".csv", ".go", ".h", ".html",
    ".ini", ".java", ".js", ".json", ".jsx", ".kt", ".lock", ".md", ".mjs",
    ".php", ".plist", ".py", ".rb", ".rs", ".sh", ".sql", ".swift", ".toml",
    ".ts", ".tsx", ".txt", ".xml", ".yaml", ".yml",
}


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
        self.left_scope_window = self.positive_int("OC_LEFT_SCOPE_WINDOW_NIGHTS", 30)
        self.zero_streak_nights = self.positive_int("OC_ZERO_STREAK_NIGHTS", 5)
        self.stale_escalate_nights = self.positive_int("OC_STALE_ESCALATE_NIGHTS", 3)
        self.lang_policy = os.environ.get("OC_LANG_POLICY", "4").strip() or "4"
        self.agent_doc_globs = [
            item.strip()
            for item in os.environ.get("OC_AGENT_DOC_GLOBS", "").split(",")
            if item.strip()
        ]
        self.suggest_repo = os.environ.get(
            "OC_SUGGEST_REPO", "caty-ai/alpha-nightshift-dev"
        )
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
        self.health_path = self.state_dir / "self-health.json"
        self.snapshot_dir = self.state_dir / "snapshots"
        self.baseline = not self.findings_path.exists()
        self.migration = False
        self.migration_detail: dict[str, Any] | None = None
        self.discovered_repos: list[dict[str, Any]] = []
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
        self.self_health_findings: list[dict[str, Any]] = []
        self.new_findings: list[dict[str, Any]] = []
        self.resolved: list[dict[str, Any]] = []
        self.left_scope_expired = 0
        self.mirror_results: dict[int, tuple[bool, dict[str, Any]]] = {}
        self.registry: dict[str, Any] = {}
        self.registry_signature: dict[str, Any] | None = None
        self.repo_state: dict[str, Any] = {"repos": {}}
        self.plan: dict[str, Any] = {}
        self.settings = {
            "OC_ORG": self.org,
            "OC_EXCLUDE_REPOS": ",".join(sorted(self.exclude_names)),
            "OC_FP_SPEC_VERSION": self.fp_spec_version,
            "OC_RETENTION_NIGHTS": self.retention,
            "OC_CHECK_TIMEOUT_SEC": self.check_timeout,
            "OC_LEFT_SCOPE_WINDOW_NIGHTS": self.left_scope_window,
            "OC_LANG_POLICY": self.lang_policy,
            "OC_AGENT_DOC_GLOBS": ",".join(self.agent_doc_globs),
            "OC_SUGGEST_REPO": self.suggest_repo,
            "OC_L2_MAX_REPOS": self.positive_int("OC_L2_MAX_REPOS", 3),
            "OC_H_MAX_REPOS": self.positive_int("OC_H_MAX_REPOS", 2),
            "OC_L3_MAX_REPOS": self.positive_int("OC_L3_MAX_REPOS", 3),
            "OC_L3_WEEKDAY": self.positive_int("OC_L3_WEEKDAY", 7),
            "OC_STALE_ESCALATE_NIGHTS": self.stale_escalate_nights,
            "OC_ZERO_STREAK_NIGHTS": self.zero_streak_nights,
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
            self.state_dir / "issues",
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
            elif (
                os.environ.get("OC_TEST_MUTATE") != "exclude"
                and (repo["name"] in self.exclude_names or repo["full_name"] in self.exclude_names)
            ):
                reason = "configured"
            if reason:
                self.excluded.append({"id": repo["id"], "name": repo["full_name"], "reason": reason})
            else:
                self.targets.append(repo)
        self.discovered_repos = sorted(raw_repos, key=lambda item: item["id"])
        self.targets.sort(key=lambda item: item["id"])

    def snapshot_family_issues(self) -> None:
        destination = self.state_dir / "issues" / "family-os-open.json"
        fixture = os.environ.get("OC_TEST_ISSUES_FIXTURE", "")
        if fixture:
            value = read_json(pathlib.Path(fixture))
            if not isinstance(value, list):
                raise LaneError("OC_TEST_ISSUES_FIXTURE must contain an array")
            atomic_write_json(destination, value)
            return
        if self.api_fixture:
            return
        url = (
            f"https://api.github.com/repos/{self.org}/family-os/issues"
            "?state=open&labels=stale-pointer&per_page=100"
        )
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": "alpha-nightshift-org-consistency",
                "Accept": "application/vnd.github+json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if not isinstance(payload, list):
                raise LaneError("family-os issues API payload was not an array")
            atomic_write_json(destination, payload)
        except (OSError, urllib.error.URLError, json.JSONDecodeError, UnicodeDecodeError, LaneError) as exc:
            self.events.append({"type": "ISSUES-SNAPSHOT-MISSING", "detail": str(exc)})

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
                if (
                    old.get("full_name") != repo["full_name"]
                    and os.environ.get("OC_TEST_MUTATE") != "rename"
                ):
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

    def family_repo_ids(self) -> set[int]:
        family_os = f"{self.org}/family-os".lower()
        historical_ids: set[int] = {
            int(repo_id)
            for repo_id, repo in self.repo_state["repos"].items()
            if repo.get("full_name", "").lower() == family_os
            or any(
                item.get("full_name", "").lower() == family_os
                for item in repo.get("name_history", [])
                if isinstance(item, dict)
            )
        }
        historical_ids.update(
            repo["id"]
            for repo in self.discovered_repos
            if repo["full_name"].lower() == family_os
        )
        return historical_ids

    def is_family_repo(self, repo: dict[str, Any]) -> bool:
        return repo.get("id") in self.family_repo_ids()

    def family_plan_repo(self) -> dict[str, Any]:
        family_os = f"{self.org}/family-os".lower()
        historical_ids = self.family_repo_ids()
        for repo in self.targets:
            if repo["id"] in historical_ids or repo["full_name"].lower() == family_os:
                return repo

        absent_repo = next(
            (repo for repo in self.discovered_repos if repo["id"] in historical_ids),
            None,
        )
        if absent_repo is None:
            absent_repo = next(
                (
                    repo
                    for repo in self.discovered_repos
                    if repo["full_name"].lower() == family_os
                ),
                None,
            )
        if absent_repo is not None:
            return {**absent_repo, "family_os_absent": True}

        if historical_ids:
            repo_id = min(historical_ids)
            historical_repo = self.repo_state["repos"][str(repo_id)]
            return {
                "id": repo_id,
                "full_name": historical_repo.get("full_name", f"{self.org}/family-os"),
                "family_os_absent": True,
            }
        return {
            "id": None,
            "full_name": f"{self.org}/family-os",
            "family_os_absent": True,
        }

    def planned_cells(self) -> list[dict[str, Any]]:
        family = self.family_plan_repo()
        cells = [
            {
                "check_id": "OC-A",
                "repo_id": family["id"],
                "repo": family["full_name"],
                "layer": 1,
                "deferred": False,
            }
        ]
        for repo in self.targets:
            if not self.is_family_repo(repo):
                cells.append(
                    {
                        "check_id": "OC-B",
                        "repo_id": repo["id"],
                        "repo": repo["full_name"],
                        "layer": 1,
                        "deferred": False,
                    }
                )
            for check_id in ("OC-C", "OC-D"):
                cells.append(
                    {
                        "check_id": check_id,
                        "repo_id": repo["id"],
                        "repo": repo["full_name"],
                        "layer": 1,
                        "deferred": False,
                    }
                )
        return cells

    def write_initial_plan(self) -> None:
        self.plan = {
            "night_id": self.night_id,
            "created_at": iso_now(),
            "checks": list(CHECK_IDS),
            "cells": self.planned_cells(),
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
        counts = {
            state: sum(1 for cell in cells if cell["status"] == state)
            for state in ("RUN", "NO-INPUT", "STALE-INPUT", "NOT-RUN", "INVALID-OUTPUT")
        }
        metrics_by_check = {
            check_id: {"scanned": 0, "extracted": 0, "flagged": 0}
            for check_id in CHECK_IDS
        }
        for cell in cells:
            check_metrics = metrics_by_check.setdefault(
                cell["check_id"], {"scanned": 0, "extracted": 0, "flagged": 0}
            )
            for key in check_metrics:
                check_metrics[key] += int(cell.get("metrics", {}).get(key, 0))
        report: dict[str, Any] = {
            "night_id": self.night_id,
            "published_at": iso_now(),
            "baseline": self.baseline,
            "quiet_mode": "baseline" if self.baseline else None,
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
                "invalid_output": counts["INVALID-OUTPUT"],
                "deferred": sum(1 for cell in cells if cell.get("deferred") is True),
                "target_pages": self.target_pages,
                "left_scope_expired": self.left_scope_expired,
            },
            "effective_settings": self.settings,
            "check_metrics": metrics_by_check,
            "cells": cells,
            "events": self.events,
            "findings": {
                "new": self.new_findings,
                "resolved_candidates": self.resolved,
                "baseline": [item for item in self.new_findings if item.get("baseline")],
                "self_health": self.self_health_findings,
            },
            "digest_mapping": {
                "not_run_many": "ABORTED-equivalent",
                "all_run_zero_findings": "ZERO-equivalent",
            },
        }
        if complete:
            report["complete"] = True
        if self.migration_detail is not None:
            report["migration"] = self.migration_detail
            report["migration_mode"] = True
            report["quiet_mode"] = "migration"
        return report

    @staticmethod
    def sanitize_claim(value: str, limit: int) -> str:
        if (
            os.environ.get("OC_TEST_MODE") == "1"
            and os.environ.get("OC_TEST_MUTATE") == "sanitize"
        ):
            return value[:limit]
        safe = unicodedata.normalize("NFC", value)
        safe = re.sub(r"<!--.*?-->", " ", safe, flags=re.DOTALL)
        safe = re.sub(r"(?:```|~~~)", " ", safe)
        safe = re.sub(
            r"oc-fingerprint\s*:\s*[0-9a-f]{12,64}",
            " ",
            safe,
            flags=re.IGNORECASE,
        )
        safe = re.sub(r"(?m)^\s{0,3}#{1,6}\s*", "", safe)
        safe = safe.replace("@", "")
        safe = re.sub(r"#\d+", "", safe)
        safe = re.sub(r"\s+", " ", safe).strip()
        if not safe:
            safe = "sanitized org-consistency observation"
        return safe[:limit]

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
            f"- {len(scope['left_scope'])} repos left scope",
            f"- LEFT-SCOPE-EXPIRED: {scope['left_scope_expired']}",
            f"- NO-INPUT: {scope['no_input']}",
            f"- NOT-RUN: {scope['not_run']}",
            f"- STALE-INPUT: {scope['stale_input']}",
            f"- INVALID-OUTPUT: {scope['invalid_output']}",
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
        lines.extend(
            [
                "",
                "## Check coverage",
                "",
            ]
        )
        for check_id in CHECK_IDS:
            metrics = report["check_metrics"][check_id]
            lines.append(
                f"- {check_id}: scanned={metrics['scanned']} extracted={metrics['extracted']} flagged={metrics['flagged']}"
            )
        lines.extend(
            [
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
            lines.extend(
                [
                    f"- [{prefix}] `{item['fingerprint']}`",
                    "",
                    "```text",
                    self.sanitize_claim(str(item.get("claim", "")), 500),
                    "```",
                ]
            )
        if not report["findings"]["new"]:
            lines.append("- none")
        lines.extend(["", "## Resolved candidates", ""])
        for item in report["findings"]["resolved_candidates"]:
            lines.extend(
                [
                    f"- `{item['fingerprint']}`",
                    "",
                    "```text",
                    self.sanitize_claim(str(item.get("claim", "")), 500),
                    "```",
                ]
            )
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
    def family_remote_is_canonical(url: str, full_name: str) -> bool:
        value = url.strip().lower()
        value = re.sub(r"^git@github\.com:", "github.com/", value)
        value = re.sub(r"^(?:https?|ssh)://(?:git@)?", "", value)
        expected = f"github.com/{full_name}".lower()
        return value.rstrip("/").removesuffix(".git") == expected

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
        fp = fingerprint(self.fp_spec_version, "OC-A", str(repo["id"]), file_name, claim_kind)
        return {
            "fingerprint": fp,
            "fp_spec_version": self.fp_spec_version,
            "check_id": "OC-A",
            "repo_id": repo["id"],
            "repo": repo["full_name"],
            "file": file_name,
            "claim_kind": claim_kind,
            "claim": failure,
        }

    def run_oc_a(self, repo: dict[str, Any], mirror_meta: dict[str, Any]) -> dict[str, Any]:
        mirror = pathlib.Path(mirror_meta["mirror"])
        # Read the configured URL, not `remote get-url`: the latter expands the
        # test-only url.insteadOf transport and would obscure the trust anchor.
        remote = self.git_command(mirror, "config", "--get", "remote.origin.url", check=False)
        if remote.returncode != 0 or not self.family_remote_is_canonical(
            remote.stdout, repo["full_name"]
        ):
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

    def make_finding(
        self,
        check_id: str,
        repo: dict[str, Any],
        file_name: str,
        claim_kind: str,
        claim: str,
    ) -> dict[str, Any]:
        return {
            "fingerprint": fingerprint(
                self.fp_spec_version,
                check_id,
                str(repo["id"]),
                file_name,
                claim_kind,
            ),
            "fp_spec_version": self.fp_spec_version,
            "check_id": check_id,
            "repo_id": repo["id"],
            "repo": repo["full_name"],
            "file": normalize(file_name),
            "claim_kind": claim_kind,
            "claim": self.sanitize_claim(claim, 500),
        }

    @staticmethod
    def read_text(path: pathlib.Path) -> str:
        try:
            return path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return ""

    @staticmethod
    def markdown_anchor(title: str) -> str:
        anchor = unicodedata.normalize("NFC", title).strip().lower()
        anchor = re.sub(r"[`*_~]", "", anchor)
        anchor = re.sub(r"[^\w\-\s]", "", anchor, flags=re.UNICODE)
        return re.sub(r"[\s-]+", "-", anchor).strip("-")

    def markdown_anchors(self, path: pathlib.Path) -> set[str]:
        anchors: set[str] = set()
        in_fence = False
        for line in self.read_text(path).splitlines():
            if re.match(r"^\s*(?:```|~~~)", line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            match = HEADING.match(line)
            if match:
                anchors.add(self.markdown_anchor(match.group("title")))
        return anchors

    def oc_b_files(self, mirror: pathlib.Path) -> list[pathlib.Path]:
        result: set[pathlib.Path] = set()
        for name in (
            "README.md",
            "README.ja.md",
            "README.zh.md",
            "README.th.md",
            "AGENTS.md",
            "CLAUDE.md",
            "FOR-AGENTS.md",
        ):
            path = mirror / name
            if path.is_file():
                result.add(path)
        docs = mirror / "docs"
        if docs.is_dir():
            result.update(path for path in docs.rglob("*.md") if path.is_file())
        return sorted(result)

    def registry_repo_sets(self) -> tuple[set[str], set[str]]:
        registered: set[str] = set()
        suppressed: set[str] = set()
        modules = self.registry.get("modules", [])
        if isinstance(modules, dict):
            module_items = modules.values()
        elif isinstance(modules, list):
            module_items = modules
        else:
            module_items = []
        for item in module_items:
            if isinstance(item, dict) and isinstance(item.get("repo"), str):
                registered.add(normalize(item["repo"]))
        for key in ("retired_repos", "adjacent"):
            values = self.registry.get(key, [])
            if isinstance(values, dict):
                values = list(values.values())
            if not isinstance(values, (list, tuple)):
                continue
            for item in values:
                repo_name = item.get("repo") if isinstance(item, dict) else item
                if isinstance(repo_name, str) and "/" in repo_name:
                    suppressed.add(normalize(repo_name).removesuffix(".git"))
        return registered, suppressed

    def run_oc_b(self, repo: dict[str, Any], mirror_meta: dict[str, Any]) -> dict[str, Any]:
        mirror = pathlib.Path(mirror_meta["mirror"])
        files = self.oc_b_files(mirror)
        if not files:
            return {
                "status": "NO-INPUT",
                "reason": "no-markdown-input",
                "fresh": False,
                "metrics": {"scanned": 0, "extracted": 0, "flagged": 0},
                **mirror_meta,
            }
        org_repos = {normalize(item["full_name"]) for item in self.discovered_repos}
        org_names = {normalize(item["name"]): normalize(item["full_name"]) for item in self.discovered_repos}
        registered, suppressed = self.registry_repo_sets()
        extracted = 0
        findings: dict[str, dict[str, Any]] = {}
        for source in files:
            relative_source = source.relative_to(mirror).as_posix()
            text = self.read_text(source)
            for match in MARKDOWN_LINK.finditer(text):
                raw_target = match.group("target").strip()
                if raw_target.startswith("<") and ">" in raw_target:
                    raw_target = raw_target[1:raw_target.index(">")]
                else:
                    raw_target = raw_target.split()[0] if raw_target.split() else ""
                if not raw_target:
                    continue
                parsed = urllib.parse.urlsplit(raw_target)
                if parsed.scheme or parsed.netloc:
                    continue
                extracted += 1
                decoded_path = urllib.parse.unquote(parsed.path)
                anchor = urllib.parse.unquote(parsed.fragment)
                target = source if not decoded_path else (
                    mirror / decoded_path.lstrip("/")
                    if decoded_path.startswith("/")
                    else source.parent / decoded_path
                )
                try:
                    resolved = target.resolve(strict=False)
                    resolved.relative_to(mirror.resolve())
                except (OSError, ValueError):
                    resolved = target
                    exists = False
                else:
                    exists = resolved.exists()
                if exists and anchor and resolved.is_file():
                    exists = self.markdown_anchor(anchor) in self.markdown_anchors(resolved)
                if exists:
                    continue
                normalized_target = normalize(
                    urllib.parse.unquote(parsed.path or relative_source)
                    + (f"#{anchor}" if anchor else "")
                )
                claim_kind = f"rel:{normalized_target}"
                finding = self.make_finding(
                    "OC-B",
                    repo,
                    relative_source,
                    claim_kind,
                    f"Missing repository-relative Markdown target {raw_target}",
                )
                findings[finding["fingerprint"]] = finding
            for match in GITHUB_REPO_URL.finditer(text):
                extracted += 1
                owner = normalize(match.group("owner"))
                repo_name = normalize(match.group("repo")).removesuffix(".git")
                full_name = f"{owner}/{repo_name}"
                if full_name in suppressed:
                    continue
                owner_mismatch = repo_name in org_names and org_names[repo_name] != full_name
                if full_name in org_repos or full_name in registered:
                    continue
                reason = "owner name does not match the org repository" if owner_mismatch else "repository is absent from the org snapshot and registry"
                finding = self.make_finding(
                    "OC-B",
                    repo,
                    relative_source,
                    f"xrepo:{full_name}",
                    f"GitHub repository reference {full_name} {reason}",
                )
                findings[finding["fingerprint"]] = finding
        observations = list(findings.values())
        self.observations.extend(observations)
        return {
            "status": "RUN",
            "reason": "link-scan-complete",
            "fresh": True,
            "metrics": {
                "scanned": len(files),
                "extracted": extracted,
                "flagged": len(observations),
            },
            **mirror_meta,
        }

    def expected_languages(self, repo: dict[str, Any]) -> list[str]:
        expected: Any = None
        modules = self.registry.get("modules", [])
        if isinstance(modules, dict):
            module_items = modules.values()
        elif isinstance(modules, list):
            module_items = modules
        else:
            module_items = []
        for item in module_items:
            if not isinstance(item, dict) or normalize(str(item.get("repo", ""))) != normalize(repo["full_name"]):
                continue
            if isinstance(item.get("languages"), list):
                expected = item["languages"]
            break
        profile = self.registry.get("org_profile")
        if isinstance(profile, dict) and normalize(str(profile.get("repo", ""))) == normalize(repo["full_name"]):
            files = profile.get("files")
            if isinstance(files, dict):
                expected = list(dict.fromkeys(value for value in files.values() if isinstance(value, str)))
        if expected is None and isinstance(self.registry.get("languages"), list):
            expected = self.registry["languages"]
        policy = self.lang_policy
        for entry in policy.split(";"):
            if "=" not in entry:
                continue
            selector, value = (part.strip() for part in entry.split("=", 1))
            if normalize(selector) in {normalize(repo["name"]), normalize(repo["full_name"])}:
                expected = [] if value.lower() in {"none", "exclude", "0"} else value.split(",")
        if expected is None:
            expected = ["en", "ja", "zh", "th"] if policy == "4" else policy.split(",")
        languages = [normalize(str(item).strip()) for item in expected if str(item).strip()]
        return list(dict.fromkeys(languages))

    @staticmethod
    def readme_name(language: str) -> str:
        return "README.md" if language in {"en", "md"} else f"README.{language}.md"

    def heading_tree(self, path: pathlib.Path) -> list[tuple[int, str]]:
        result: list[tuple[int, str]] = []
        in_fence = False
        for line in self.read_text(path).splitlines():
            if re.match(r"^\s*(?:```|~~~)", line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            match = HEADING.match(line)
            if match:
                result.append((len(match.group("marks")), self.markdown_anchor(match.group("title"))))
        return result

    def run_oc_c(self, repo: dict[str, Any], mirror_meta: dict[str, Any]) -> dict[str, Any]:
        mirror = pathlib.Path(mirror_meta["mirror"])
        base = mirror / "README.md"
        if not base.is_file():
            return {
                "status": "NO-INPUT",
                "reason": "readme-missing",
                "fresh": False,
                "metrics": {"scanned": 0, "extracted": 0, "flagged": 0},
                **mirror_meta,
            }
        expected = self.expected_languages(repo)
        files = {language: mirror / self.readme_name(language) for language in expected}
        findings: dict[str, dict[str, Any]] = {}
        for language, path in files.items():
            if path.is_file():
                continue
            finding = self.make_finding(
                "OC-C",
                repo,
                self.readme_name(language),
                f"lang-missing:{language}",
                f"Declared README language {language} is missing",
            )
            findings[finding["fingerprint"]] = finding
        if all(path.is_file() for path in files.values()) and {"en", "ja", "zh", "th"}.issubset(files):
            base_tree = self.heading_tree(base)
            for language in ("ja", "zh", "th"):
                language_tree = self.heading_tree(files[language])
                max_len = max(len(base_tree), len(language_tree))
                for index in range(max_len):
                    base_heading = base_tree[index] if index < len(base_tree) else None
                    translated = language_tree[index] if index < len(language_tree) else None
                    if base_heading is not None and translated is not None and base_heading[0] == translated[0]:
                        continue
                    key = (
                        base_heading[1]
                        if base_heading is not None and base_heading[1]
                        else f"extra-{index + 1}-{translated[1] if translated else 'heading'}"
                    )
                    finding = self.make_finding(
                        "OC-C",
                        repo,
                        self.readme_name(language),
                        f"heading-drift:{language}:{key}",
                        f"README heading tree for {language} differs at position {index + 1} ({key})",
                    )
                    findings[finding["fingerprint"]] = finding
        observations = list(findings.values())
        self.observations.extend(observations)
        return {
            "status": "RUN",
            "reason": "language-scan-complete",
            "fresh": True,
            "metrics": {
                "scanned": 1 + sum(1 for path in files.values() if path.is_file() and path != base),
                "extracted": len(expected) + sum(len(self.heading_tree(path)) for path in files.values() if path.is_file()),
                "flagged": len(observations),
            },
            **mirror_meta,
        }

    def oc_d_files(self, mirror: pathlib.Path) -> list[pathlib.Path]:
        result: set[pathlib.Path] = set()
        for name in ("AGENTS.md", "CLAUDE.md", "FOR-AGENTS.md"):
            path = mirror / name
            if path.is_file():
                result.add(path)
        claude_dir = mirror / ".claude"
        if claude_dir.is_dir():
            result.update(path for path in claude_dir.rglob("*") if path.is_file())
        for pattern in self.agent_doc_globs:
            if pathlib.PurePath(pattern).is_absolute() or ".." in pathlib.PurePath(pattern).parts:
                continue
            result.update(path for path in mirror.glob(pattern) if path.is_file())
        return sorted(result)

    def agent_path_tokens(self, text: str, mirror: pathlib.Path) -> list[str]:
        top_segments = {path.name for path in mirror.iterdir() if path.exists()}
        candidates = re.findall(r"(?<![\w.-])(?:\./)?[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.@+-]+)*/?", text)
        tokens: list[str] = []
        for candidate in candidates:
            token = candidate.strip("`'\"(),;:")
            token = re.sub(r"[.,;:!?]+$", "", token)
            if not token or any(char in token for char in "*?[]#") or "://" in token:
                continue
            normalized_token = token[2:] if token.startswith("./") else token
            if normalized_token.startswith("../") or "/../" in normalized_token:
                continue
            path = pathlib.PurePosixPath(normalized_token.rstrip("/"))
            suffix_allowed = path.suffix.lower() in ALLOWED_AGENT_EXTENSIONS
            first = path.parts[0] if path.parts else ""
            extensionless_command = len(path.parts) >= 2 and first in {"bin", "scripts"}
            rooted = len(path.parts) >= 2 and first in top_segments
            if suffix_allowed or extensionless_command or rooted:
                tokens.append(normalized_token)
        return tokens

    def run_oc_d(self, repo: dict[str, Any], mirror_meta: dict[str, Any]) -> dict[str, Any]:
        mirror = pathlib.Path(mirror_meta["mirror"])
        files = self.oc_d_files(mirror)
        if not files:
            return {
                "status": "NO-INPUT",
                "reason": "no-agent-doc-input",
                "fresh": False,
                "metrics": {"scanned": 0, "extracted": 0, "flagged": 0},
                **mirror_meta,
            }
        findings: dict[str, dict[str, Any]] = {}
        extracted = 0
        for source in files:
            relative_source = source.relative_to(mirror).as_posix()
            for token in self.agent_path_tokens(self.read_text(source), mirror):
                extracted += 1
                target = mirror / token.rstrip("/")
                try:
                    target.resolve(strict=False).relative_to(mirror.resolve())
                    exists = target.exists()
                except (OSError, ValueError):
                    exists = False
                if exists:
                    continue
                normalized_token = normalize(token)
                finding = self.make_finding(
                    "OC-D",
                    repo,
                    relative_source,
                    f"ref:{normalized_token}",
                    f"Agent documentation references missing repository path {token}",
                )
                findings[finding["fingerprint"]] = finding
        observations = list(findings.values())
        self.observations.extend(observations)
        return {
            "status": "RUN",
            "reason": "agent-doc-scan-complete",
            "fresh": True,
            "metrics": {
                "scanned": len(files),
                "extracted": extracted,
                "flagged": len(observations),
            },
            **mirror_meta,
        }

    def set_cell_result(
        self, check_id: str, repo_id: int | None, result: dict[str, Any]
    ) -> None:
        for cell in self.plan["cells"]:
            if cell["check_id"] == check_id and cell["repo_id"] == repo_id:
                cell["result"] = result
                atomic_write_json(self.plan_path, self.plan)
                return
        raise LaneError(f"result does not match write-ahead plan: {check_id}/{repo_id}")

    def load_registry(self) -> None:
        family = self.family_plan_repo()
        repo_id = family.get("id")
        if repo_id is None or repo_id not in self.mirror_results:
            return
        synced, mirror_meta = self.mirror_results[repo_id]
        if not synced or "mirror" not in mirror_meta:
            return
        registry_path = pathlib.Path(mirror_meta["mirror"]) / "registry" / "modules.json"
        value = read_json(registry_path, {})
        if not isinstance(value, dict):
            raise LaneError("family-os registry/modules.json must be an object")
        self.registry = value
        self.registry_signature = {
            "version": value.get("version"),
            "schema_keys": sorted(value.keys()),
        }

    def run_cells(self) -> None:
        for repo in self.targets:
            self.mirror_results[repo["id"]] = self.sync_mirror(repo)
        self.load_registry()
        target_by_id = {repo["id"]: repo for repo in self.targets}
        family = self.family_plan_repo()
        for cell in list(self.plan["cells"]):
            check_id = cell["check_id"]
            repo_id = cell["repo_id"]
            repo = target_by_id.get(repo_id)
            if check_id == "OC-A" and family.get("family_os_absent") is True:
                result = {
                    "status": "NOT-RUN",
                    "reason": "family-os-absent",
                    "fresh": False,
                    "metrics": {"scanned": 0, "extracted": 0, "flagged": 0},
                }
            elif repo is None:
                result = {
                    "status": "NOT-RUN",
                    "reason": "mirror-missing",
                    "fresh": False,
                    "metrics": {"scanned": 0, "extracted": 0, "flagged": 0},
                }
            else:
                synced, mirror_meta = self.mirror_results[repo["id"]]
                if not synced:
                    reason = mirror_meta.get("reason", "mirror-missing")
                    if not mirror_meta.get("old_head") and reason == "fetch-failed":
                        reason = "mirror-missing"
                    result = {
                        "status": "NOT-RUN",
                        "reason": reason,
                        "fresh": False,
                        "metrics": {"scanned": 0, "extracted": 0, "flagged": 0},
                        **{key: value for key, value in mirror_meta.items() if key != "reason"},
                    }
                elif check_id == "OC-A":
                    result = self.run_oc_a(repo, mirror_meta)
                elif check_id == "OC-B":
                    result = self.run_oc_b(repo, mirror_meta)
                elif check_id == "OC-C":
                    result = self.run_oc_c(repo, mirror_meta)
                elif check_id == "OC-D":
                    result = self.run_oc_d(repo, mirror_meta)
                else:
                    raise LaneError(f"unknown check in plan: {check_id}")
                if self.target_status == "STALE" and result["status"] == "RUN":
                    result["status"] = "STALE-INPUT"
                    result["reason"] = "targets-stale"
                    result["fresh"] = False
            self.set_cell_result(check_id, repo_id, result)
            self.publish_report(complete=False)

    def self_health_fingerprint(self, event_kind: str) -> str:
        digest = hashlib.sha256()
        for field in (self.fp_spec_version, "self-health", event_kind):
            encoded = field.encode("utf-8")
            digest.update(str(len(encoded)).encode("ascii"))
            digest.update(b":")
            digest.update(encoded)
        return digest.hexdigest()

    def emit_self_health(self, event_kind: str, claim: str) -> None:
        finding = {
            "fingerprint": self.self_health_fingerprint(event_kind),
            "fp_spec_version": self.fp_spec_version,
            "check_id": "self-health",
            "repo_id": "self-health",
            "repo": self.suggest_repo,
            "file": "self-health",
            "claim_kind": event_kind,
            "claim": self.sanitize_claim(claim, 500),
        }
        if finding["fingerprint"] not in {
            item["fingerprint"] for item in self.self_health_findings
        }:
            self.self_health_findings.append(finding)
            self.observations.append(finding)

    def update_self_health(self) -> None:
        health = read_json(
            self.health_path,
            {"zero_streaks": {}, "stale_streak": 0, "registry_signature": None},
        )
        if not isinstance(health, dict):
            raise LaneError("self-health.json has an invalid schema")
        zero_streaks = health.get("zero_streaks")
        if not isinstance(zero_streaks, dict):
            zero_streaks = {}
        cells = self.effective_cells()
        for check_id in CHECK_IDS:
            extracted = sum(
                int(cell.get("metrics", {}).get("extracted", 0))
                for cell in cells
                if cell["check_id"] == check_id
            )
            streak = int(zero_streaks.get(check_id, 0)) + 1 if extracted == 0 else 0
            zero_streaks[check_id] = streak
            if streak >= self.zero_streak_nights:
                self.emit_self_health(
                    f"zero-streak:{check_id}",
                    f"{check_id} extracted zero candidates for {streak} consecutive nights",
                )
        mirror_stale = any(not synced for synced, _meta in self.mirror_results.values())
        stale = self.target_status != "FRESH" or mirror_stale or any(
            cell["status"] == "STALE-INPUT" for cell in cells
        )
        stale_streak = int(health.get("stale_streak", 0)) + 1 if stale else 0
        if stale_streak >= self.stale_escalate_nights:
            self.emit_self_health(
                "targets-stale",
                f"TARGETS or mirror input was stale for {stale_streak} consecutive nights",
            )
        layer_one = [
            cell
            for cell in cells
            if cell.get("layer") == 1 and cell.get("deferred") is not True
        ]
        not_run = sum(1 for cell in layer_one if cell["status"] == "NOT-RUN")
        if layer_one and not_run / len(layer_one) > 0.5:
            self.emit_self_health(
                "notrun-ratio",
                f"Layer 1 NOT-RUN ratio was {not_run}/{len(layer_one)} after excluding deferred cells",
            )
        if any(cell["status"] == "INVALID-OUTPUT" for cell in cells):
            self.emit_self_health("invalid-output", "At least one cell produced INVALID-OUTPUT")
        previous_signature = health.get("registry_signature")
        if (
            previous_signature is not None
            and self.registry_signature is not None
            and previous_signature != self.registry_signature
        ):
            self.emit_self_health(
                "registry-schema-changed",
                "family-os registry version or top-level schema keys changed; refresh the pinned corpus",
            )
        atomic_write_json(
            self.health_path,
            {
                "updated_night": self.night_id,
                "zero_streaks": zero_streaks,
                "stale_streak": stale_streak,
                "registry_signature": self.registry_signature or previous_signature,
            },
        )

    def migrate_ledger(self, ledger: dict[str, Any]) -> None:
        old_version = str(ledger.get("fp_spec_version", ""))
        mappings: list[dict[str, str]] = []
        seen: set[str] = set()
        for entry in ledger["findings"]:
            if not isinstance(entry, dict):
                raise LaneError("findings.json contains a non-object finding")
            required = ("check_id", "repo_id", "file", "claim_kind", "fingerprint")
            if any(key not in entry for key in required):
                raise LaneError("fp migration requires structured finding fields")
            old_fp = str(entry["fingerprint"])
            if entry["check_id"] == "self-health":
                new_fp = self.self_health_fingerprint(str(entry["claim_kind"]))
            else:
                new_fp = fingerprint(
                    self.fp_spec_version,
                    str(entry["check_id"]),
                    str(entry["repo_id"]),
                    str(entry["file"]),
                    str(entry["claim_kind"]),
                )
            if new_fp in seen:
                raise LaneError("fp migration produced a fingerprint collision")
            seen.add(new_fp)
            entry["fingerprint"] = new_fp
            entry["fp_spec_version"] = self.fp_spec_version
            mappings.append({"old": old_fp, "new": new_fp})
        ledger["fp_spec_version"] = self.fp_spec_version
        self.migration = True
        self.migration_detail = {
            "from": old_version,
            "to": self.fp_spec_version,
            "mappings": mappings,
            "quiet": True,
        }
        self.events.append(
            {"type": "FP-SPEC-MIGRATED", "from": old_version, "to": self.fp_spec_version, "mappings": mappings}
        )

    def reconcile_findings(self) -> None:
        ledger = read_json(
            self.findings_path,
            {"fp_spec_version": self.fp_spec_version, "findings": []},
        )
        if not isinstance(ledger, dict) or not isinstance(ledger.get("findings"), list):
            raise LaneError("findings.json has an invalid schema")
        if ledger.get("fp_spec_version") != self.fp_spec_version:
            self.migrate_ledger(ledger)
            ledger["findings"].sort(key=lambda item: item.get("fingerprint", ""))
            atomic_write_json(self.findings_path, ledger)
            return
        unique_observations = {
            item["fingerprint"]: item for item in self.observations
        }
        by_fp = {
            item.get("fingerprint"): item
            for item in ledger["findings"]
            if isinstance(item, dict)
        }
        current_ids = {repo["id"] for repo in self.targets}
        reopened_from_scope: set[str] = set()
        if self.target_status == "FRESH":
            for entry in ledger["findings"]:
                status = entry.get("status")
                repo_id = entry.get("repo_id")
                if status in {"target-left-scope", "left-scope-expired"} and repo_id in current_ids:
                    entry["status"] = "open"
                    entry.pop("left_scope_since", None)
                    entry.pop("left_scope_nights", None)
                    previous_status = status
                    reopened_from_scope.add(str(entry.get("fingerprint")))
                    self.events.append(
                        {"type": "REOPENED", "fingerprint": entry.get("fingerprint"), "from": previous_status}
                    )
                elif status == "open" and isinstance(repo_id, int) and repo_id not in current_ids:
                    entry["status"] = "target-left-scope"
                    entry["left_scope_since"] = self.night_id
                    entry["left_scope_nights"] = 1
                    self.events.append(
                        {"type": "TARGET-LEFT-SCOPE", "fingerprint": entry.get("fingerprint"), "repo_id": repo_id}
                    )
                    if self.left_scope_window == 1:
                        entry["status"] = "left-scope-expired"
                        entry["left_scope_expired_night"] = self.night_id
                        self.left_scope_expired += 1
                        self.events.append(
                            {"type": "LEFT-SCOPE-EXPIRED", "fingerprint": entry.get("fingerprint"), "repo_id": repo_id, "nights": 1}
                        )
                elif status == "target-left-scope" and isinstance(repo_id, int) and repo_id not in current_ids:
                    nights = int(entry.get("left_scope_nights", 1)) + 1
                    entry["left_scope_nights"] = nights
                    if nights >= self.left_scope_window:
                        entry["status"] = "left-scope-expired"
                        entry["left_scope_expired_night"] = self.night_id
                        self.left_scope_expired += 1
                        self.events.append(
                            {"type": "LEFT-SCOPE-EXPIRED", "fingerprint": entry.get("fingerprint"), "repo_id": repo_id, "nights": nights}
                        )
        for finding in unique_observations.values():
            existing = by_fp.get(finding["fingerprint"])
            if existing is not None:
                existing["last_seen"] = self.night_id
                if existing.get("status") != "open":
                    previous_status = existing.get("status")
                    existing["status"] = "open"
                    existing.pop("resolved_candidate_night", None)
                    self.events.append(
                        {"type": "REOPENED", "fingerprint": finding["fingerprint"], "from": previous_status}
                    )
                elif finding["fingerprint"] not in reopened_from_scope:
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
            self.events.append(
                {"type": "OPENED", "fingerprint": entry["fingerprint"], "baseline": self.baseline}
            )
        observed = set(unique_observations)
        fresh_cells = {
            (cell["check_id"], cell["repo_id"])
            for cell in self.effective_cells()
            if cell["status"] == "RUN" and cell.get("fresh") is True
        }
        for entry in ledger["findings"]:
            if entry.get("status") != "open" or entry.get("fingerprint") in observed:
                continue
            if str(entry.get("fingerprint")) in reopened_from_scope:
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
        ledger["fp_spec_version"] = self.fp_spec_version
        ledger["findings"].sort(key=lambda item: item.get("fingerprint", ""))
        atomic_write_json(self.findings_path, ledger)

    def write_proposals(self) -> None:
        proposal_path = self.lane_dir / "findings.jsonl"
        if self.baseline or self.migration:
            atomic_write_text(proposal_path, "")
            return
        selected: dict[str, dict[str, Any]] = {
            item["fingerprint"]: item
            for item in self.new_findings
            if item.get("baseline") is not True
        }
        selected.update(
            {item["fingerprint"]: item for item in self.self_health_findings}
        )
        try:
            evidence = self.report_json.relative_to(self.state_dir.parent).as_posix()
        except ValueError:
            evidence = f"org-consistency/report/{self.night_id}.json"
        lines: list[str] = []
        for item in selected.values():
            check_id = str(item["check_id"])
            proposal = {
                "id": f"oc-{self.night_id}-{item['fingerprint'][:12]}",
                "repo": str(item.get("repo") or self.suggest_repo),
                "target": str(item.get("file") or "self-health"),
                "symptom": self.sanitize_claim(str(item.get("claim", "")), 200),
                "kind": (
                    "org-consistency/self-health"
                    if check_id == "self-health"
                    else f"org-consistency/{check_id}"
                ),
                "confirm_cost": "即断",
                "date": self.night_id,
                "evidence": [evidence],
            }
            lines.append(json.dumps(proposal, ensure_ascii=False, sort_keys=True))
        atomic_write_text(proposal_path, "\n".join(lines) + ("\n" if lines else ""))

    def write_journal(self) -> None:
        journal = {
            "night_id": self.night_id,
            "written_at": iso_now(),
            "baseline": self.baseline,
            "migration": self.migration_detail,
            "targets": {"status": self.target_status, "snapshot_night": self.target_snapshot_night, "incomplete": self.target_incomplete},
            "cells": self.effective_cells(),
            "events": self.events,
            "new_findings": [item["fingerprint"] for item in self.new_findings],
            "resolved_candidates": [item["fingerprint"] for item in self.resolved],
            "self_health": [item["fingerprint"] for item in self.self_health_findings],
            "left_scope_expired": self.left_scope_expired,
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
        self.snapshot_family_issues()
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
            atomic_write_text(self.lane_dir / "findings.jsonl", "")
            self.prune()
            return 2
        self.run_cells()
        self.update_self_health()
        self.reconcile_findings()
        self.write_proposals()
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
