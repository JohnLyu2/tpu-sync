# Copyright 2026 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Golden-commit tooling for tpu_sync.

A golden commit is a commit on main whose tpu_sync_torch nightly wheel passed
the two downstream canaries that consume the wheel: the vllm-torchtpu canary
pipeline on Buildkite and the sglang-torchtpu remote-wheel workflow on GitHub
Actions. .github/workflows/golden_commit.yml drives the subcommands below and
RELEASING.md describes the process; the subcommands also run by hand from a
checkout, which is what the golden-commit skill does.

Subcommands (each prints a JSON object and, under GitHub Actions, writes its
keys to $GITHUB_OUTPUT):

  resolve  Pick the candidate: the newest tpu-sync-torch .dev release on PyPI,
           or --version, and the main commit its nightly was built from.
  vllm     Start the vllm-torchtpu canary build for the version and wait for
           it (or wait for an existing build with --build-number).
  sglang   Dispatch the sglang-torchtpu remote-wheel workflow for the version
           and wait for it (or wait for an existing run with --run-id).
  record   Write lkg.version and append the row to verified_commits.csv.
  bump     Rewrite the tpu-sync-torch pin in a downstream checkout.

Only the standard library is used, so the script runs on a stock python3.
"""

import argparse
import csv
import datetime
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PYPI_PROJECT = "tpu-sync-torch"
PYPI_JSON_URL = f"https://pypi.org/pypi/{PYPI_PROJECT}/json"
GITHUB_API_URL = "https://api.github.com"
BUILDKITE_API_URL = "https://api.buildkite.com/v2"

# The repository the nightlies are built from.
DEFAULT_REPO = "google/tpu-sync"
NIGHTLY_WORKFLOW = "nightly_build.yml"
# The nightly uploads an artifact of this name per version (see
# nightly_build.yml); its workflow run names the commit.
MANIFEST_ARTIFACT_PREFIX = "nightly-manifest-"
# Without a manifest, the nightly run is the one that started within this
# window of the version stamp (the stamp is taken at the start of the run).
NIGHTLY_MATCH_WINDOW = datetime.timedelta(minutes=20)

# The vllm-torchtpu canary: the Buildkite pipeline that tests torch-tpu and
# tpu-sync-torch nightlies (TORCHTPU_NIGHTLY=1 in its bootstrap.sh).
DEFAULT_BUILDKITE_ORG = "vllm"
DEFAULT_VLLM_PIPELINE = "vllm-torchtpu-torchtpu-nightly"
# States in which Buildkite still changes a build; "blocked" is left out on
# purpose: a build waiting on a block step never finishes on its own.
BUILDKITE_UNFINISHED_STATES = frozenset({
    "accepted",
    "assigned",
    "canceling",
    "creating",
    "failing",
    "limited",
    "limiting",
    "pending",
    "running",
    "scheduled",
    "started",
    "waiting",
})

# The sglang-torchtpu remote-wheel workflow: layers a wheel over the latest
# nightly image and runs feature validation and perf against it.
DEFAULT_SGLANG_REPO = "sgl-project/sglang-torchtpu"
DEFAULT_SGLANG_WORKFLOW = "nightly-test-tpu-remote-wheel.yml"

LKG_FILE = "lkg.version"
VERIFIED_FILE = "verified_commits.csv"
VERIFIED_COLUMNS = (
    "timestamp",
    "tpu_sync_commit",
    "tpu_sync_torch_version",
    "vllm_torchtpu_build",
    "sglang_torchtpu_run",
)

# Where each downstream repository pins tpu-sync-torch.
DOWNSTREAM_PIN_FILES = {
    "vllm": ("pyproject.toml",),
    "sglang": (
        "python/pyproject_tpu.toml",
        "requirements/tpu_stack_excludes.txt",
    ),
}
DOWNSTREAM_REPOS = {
    "vllm": "vllm-project/vllm-torchtpu",
    "sglang": DEFAULT_SGLANG_REPO,
}
_PIN_RE = re.compile(r"tpu[-_]sync[-_]torch==[0-9][0-9A-Za-z.+!-]*")
_DEV_STAMP_RE = re.compile(r"\.dev(\d{14})$")
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")

POLL_SECONDS = 60
_UTC = datetime.timezone.utc


class Error(Exception):
  """A failure the caller should report rather than a bug."""


# --- HTTP -------------------------------------------------------------------


def _request(method, url, *, token=None, payload=None, accept=None):
  """Performs an HTTP request and returns the decoded JSON body (or None)."""
  data = None
  headers = {"User-Agent": "tpu-sync-golden-commit"}
  if accept:
    headers["Accept"] = accept
  if token:
    headers["Authorization"] = f"Bearer {token}"
  if payload is not None:
    data = json.dumps(payload).encode()
    headers["Content-Type"] = "application/json"
  request = urllib.request.Request(
      url, data=data, method=method, headers=headers
  )
  try:
    with urllib.request.urlopen(request, timeout=120) as response:
      body = response.read()
  except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:500]
    raise Error(f"{method} {url} failed with HTTP {e.code}: {detail}") from e
  except urllib.error.URLError as e:
    raise Error(f"{method} {url} failed: {e.reason}") from e
  if not body:
    return None
  return json.loads(body)


def _github(path, *, token, method="GET", payload=None, params=None):
  url = f"{GITHUB_API_URL}{path}"
  if params:
    url += "?" + urllib.parse.urlencode(params)
  return _request(
      method,
      url,
      token=token,
      payload=payload,
      accept="application/vnd.github+json",
  )


def _buildkite(path, *, token, method="GET", payload=None):
  return _request(
      method, f"{BUILDKITE_API_URL}{path}", token=token, payload=payload
  )


def _require_token(name):
  token = os.environ.get(name, "").strip()
  if not token:
    raise Error(f"{name} is not set")
  return token


# --- Output -----------------------------------------------------------------


def emit(outputs):
  """Prints |outputs| as JSON and appends them to $GITHUB_OUTPUT if set."""
  print(json.dumps(outputs, indent=2, sort_keys=True))
  github_output = os.environ.get("GITHUB_OUTPUT")
  if github_output:
    with open(github_output, "a", encoding="utf-8") as f:
      for key, value in outputs.items():
        f.write(f"{key}={value}\n")


def _log(message):
  print(message, file=sys.stderr, flush=True)


def _now():
  return datetime.datetime.now(_UTC)


def _parse_github_time(text):
  return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
      tzinfo=_UTC
  )


# --- resolve ----------------------------------------------------------------


def dev_stamp(version):
  """Returns the UTC time stamped into a .devYYYYMMDDHHMMSS version, or None."""
  match = _DEV_STAMP_RE.search(version)
  if not match:
    return None
  try:
    return datetime.datetime.strptime(match.group(1), "%Y%m%d%H%M%S").replace(
        tzinfo=_UTC
    )
  except ValueError:
    return None


def latest_dev_version(releases):
  """Picks the newest nightly among the releases of the PyPI project.

  A nightly is a .devYYYYMMDDHHMMSS version with at least one file that is not
  yanked. The newest is the one with the latest stamp; the base version breaks
  ties, since a version bump on main never moves the stamp backwards.

  Args:
    releases: The "releases" object of the PyPI JSON API: version to files.

  Returns:
    The newest nightly version.

  Raises:
    Error: The project has no nightly.
  """
  candidates = []
  for version, files in releases.items():
    stamp = dev_stamp(version)
    if stamp is None or not files:
      continue
    if all(f.get("yanked") for f in files):
      continue
    base = version[: version.rfind(".dev")]
    candidates.append((stamp, _version_key(base), version))
  if not candidates:
    raise Error(f"no .dev release of {PYPI_PROJECT} on PyPI")
  return max(candidates)[2]


def _version_key(base):
  return tuple(int(p) if p.isdigit() else p for p in base.split("."))


def match_nightly_run(runs, stamp, window=NIGHTLY_MATCH_WINDOW):
  """Picks the nightly run that stamped a wheel version.

  Args:
    runs: Runs of the nightly workflow on main, as the GitHub API lists them.
    stamp: The time the wheel version was stamped.
    window: How far from the stamp a run may have been created.

  Returns:
    The run on main created closest to the stamp within the window, as the
    GitHub API lists it, or None.
  """
  best = None
  for run in runs:
    if run.get("head_branch") != "main":
      continue
    created = _parse_github_time(run["created_at"])
    distance = abs(created - stamp)
    if distance > window:
      continue
    if best is None or distance < best[0]:
      best = (distance, run)
  return best[1] if best else None


def find_nightly_run(repo, version, token):
  """Finds the commit and run of the nightly that built a wheel version.

  Args:
    repo: The GitHub repository of the nightlies, "owner/name".
    version: The wheel version.
    token: A GitHub token for the Actions API, or None for anonymous access.

  Returns:
    The (commit SHA, run URL) of the nightly: from the
    nightly-manifest-<version> artifact when the nightly left one, else from
    the run created closest to the version's stamp.

  Raises:
    Error: The version is not a nightly, or no run matches it.
  """
  artifacts = _github(
      f"/repos/{repo}/actions/artifacts",
      token=token,
      params={"name": f"{MANIFEST_ARTIFACT_PREFIX}{version}", "per_page": 5},
  )
  for artifact in artifacts.get("artifacts", []):
    run = artifact.get("workflow_run") or {}
    if run.get("head_sha"):
      _log(f"nightly manifest found: run {run['id']} at {run['head_sha']}")
      return (
          run["head_sha"],
          f"https://github.com/{repo}/actions/runs/{run['id']}",
      )
  stamp = dev_stamp(version)
  if stamp is None:
    raise Error(f"{version} is not a .devYYYYMMDDHHMMSS nightly version")
  _log("no nightly manifest; matching the nightly run by its start time")
  runs = _github(
      f"/repos/{repo}/actions/workflows/{NIGHTLY_WORKFLOW}/runs",
      token=token,
      params={"branch": "main", "per_page": 100},
  ).get("workflow_runs", [])
  run = match_nightly_run(runs, stamp)
  if run is None:
    raise Error(
        f"no run of {NIGHTLY_WORKFLOW} on main within {NIGHTLY_MATCH_WINDOW}"
        f" of {stamp.isoformat()} ({version})"
    )
  return run["head_sha"], run["html_url"]


def cmd_resolve(args):
  """The resolve subcommand: the candidate version and its commit."""
  token = os.environ.get("GITHUB_TOKEN", "").strip() or None
  version = args.version
  if not version:
    releases = _request("GET", PYPI_JSON_URL).get("releases", {})
    version = latest_dev_version(releases)
    _log(f"newest {PYPI_PROJECT} nightly on PyPI: {version}")
  sha, run_url = find_nightly_run(args.repo, version, token)
  emit({
      "tpu_sync_torch_version": version,
      "tpu_sync_commit": sha,
      "nightly_run_url": run_url,
  })


# --- vllm -------------------------------------------------------------------


def vllm_build_env(version, torch_tpu_version=None, lanes=None):
  """Builds the environment of a canary build that tests only tpu-sync-torch.

  TORCHTPU_NIGHTLY=1 makes setup_docker_env.sh layer the named wheels over the
  base image; TORCHTPU_NIGHTLY_LEG=tpu-sync runs the lanes on the image whose
  only change is tpu-sync-torch. NIGHTLY=1 runs every lane, including the
  nightly-only tests; the verify lane pushes nothing without
  KUBE_OWNS_NIGHTLY, which only the scheduled nightly sets.

  Args:
    version: The tpu-sync-torch nightly to layer over the base image.
    torch_tpu_version: The torch-tpu nightly of the other leg, which is built
      but not tested; the newest when None.
    lanes: A CI_LANES value to run a subset of the lanes; every lane when None.

  Returns:
    The build environment, variable to value.
  """
  env = {
      "TORCHTPU_NIGHTLY": "1",
      "TORCHTPU_NIGHTLY_LEG": "tpu-sync",
      "TPU_SYNC_TORCH_VERSION_OVERRIDE": version,
      "NIGHTLY": "1",
  }
  if torch_tpu_version:
    env["TORCH_TPU_VERSION_OVERRIDE"] = torch_tpu_version
  if lanes:
    env["CI_LANES"] = lanes
  return env


def _wait(deadline, what):
  if _now() >= deadline:
    raise Error(f"timed out waiting for {what}")
  time.sleep(POLL_SECONDS)


def cmd_vllm(args):
  """The vllm subcommand: start the canary build, or find it, and wait."""
  token = _require_token("BUILDKITE_API_TOKEN")
  base = f"/organizations/{args.org}/pipelines/{args.pipeline}/builds"
  if args.build_number:
    number = args.build_number
    build = _buildkite(f"{base}/{number}", token=token)
  else:
    build = _buildkite(
        base,
        token=token,
        method="POST",
        payload={
            "commit": "HEAD",
            "branch": args.branch,
            "message": (
                f"tpu-sync golden candidate: tpu-sync-torch=={args.version}"
            ),
            "env": vllm_build_env(
                args.version, args.torch_tpu_version, args.lanes
            ),
            "meta_data": {"tpu_sync_torch_version": args.version},
        },
    )
    number = build["number"]
    _log(f"started {build['web_url']}")
  emit({"vllm_build_number": number, "vllm_build_url": build["web_url"]})
  if args.no_wait:
    return
  deadline = _now() + datetime.timedelta(minutes=args.timeout_minutes)
  while build["state"] in BUILDKITE_UNFINISHED_STATES:
    _log(f"build {number}: {build['state']}")
    _wait(deadline, f"Buildkite build {build['web_url']}")
    build = _buildkite(f"{base}/{number}", token=token)
  emit({"vllm_build_state": build["state"]})
  if build["state"] != "passed":
    raise Error(
        f"vllm-torchtpu canary {build['web_url']} ended {build['state']}"
    )


# --- sglang -----------------------------------------------------------------


def sglang_inputs(version, ref="main", only="all"):
  """Builds the remote-wheel workflow's inputs for a tpu-sync-torch version.

  The workflow installs its wheel input with pip, so a requirement string
  names the tpu-sync-torch nightly on PyPI; the only input picks the suites.

  Args:
    version: The tpu-sync-torch nightly to test.
    ref: The sglang-torchtpu ref to test it on.
    only: The workflow's "only" input: all, feature-validation, perf, ...

  Returns:
    The workflow inputs, name to value.
  """
  return {"ref": ref, "wheel": f"{PYPI_PROJECT}=={version}", "only": only}


def pick_dispatched_run(runs, dispatched_at, known_ids=()):
  """Picks the run that a workflow_dispatch of ours created.

  GitHub returns nothing from a dispatch, so the run is the newest
  workflow_dispatch run created at or after the dispatch (less a minute of
  clock skew) that was not there before.

  Args:
    runs: The recent runs of the workflow, as the GitHub API lists them.
    dispatched_at: When the dispatch was sent.
    known_ids: The IDs of the runs that existed before the dispatch.

  Returns:
    The run, as the GitHub API lists it, or None if none has appeared yet.
  """
  since = dispatched_at - datetime.timedelta(minutes=1)
  matches = [
      run
      for run in runs
      if run.get("event") == "workflow_dispatch"
      and run["id"] not in known_ids
      and _parse_github_time(run["created_at"]) >= since
  ]
  if not matches:
    return None
  return max(matches, key=lambda run: run["created_at"])


def cmd_sglang(args):
  """The sglang subcommand: dispatch the workflow, or find its run, and wait."""
  token = _require_token("SGLANG_GITHUB_TOKEN")
  runs_path = f"/repos/{args.repo}/actions/workflows/{args.workflow}/runs"
  deadline = _now() + datetime.timedelta(minutes=args.timeout_minutes)
  if args.run_id:
    run = _github(f"/repos/{args.repo}/actions/runs/{args.run_id}", token=token)
  else:
    before = _github(
        runs_path,
        token=token,
        params={"event": "workflow_dispatch", "per_page": 20},
    ).get("workflow_runs", [])
    known_ids = {run["id"] for run in before}
    dispatched_at = _now()
    _github(
        f"/repos/{args.repo}/actions/workflows/{args.workflow}/dispatches",
        token=token,
        method="POST",
        payload={
            "ref": args.ref,
            "inputs": sglang_inputs(args.version, args.ref, args.only),
        },
    )
    _log(
        f"dispatched {args.workflow} on {args.repo} for"
        f" {PYPI_PROJECT}=={args.version}"
    )
    run = None
    while run is None:
      time.sleep(15)
      runs = _github(
          runs_path,
          token=token,
          params={"event": "workflow_dispatch", "per_page": 20},
      ).get("workflow_runs", [])
      run = pick_dispatched_run(runs, dispatched_at, known_ids)
      if run is None and _now() >= dispatched_at + datetime.timedelta(
          minutes=5
      ):
        raise Error(f"no run of {args.workflow} appeared after the dispatch")
    _log(f"run {run['id']}: {run['html_url']}")
  emit({"sglang_run_id": run["id"], "sglang_run_url": run["html_url"]})
  if args.no_wait:
    return
  while run["status"] != "completed":
    _log(f"run {run['id']}: {run['status']}")
    _wait(deadline, f"GitHub Actions run {run['html_url']}")
    run = _github(f"/repos/{args.repo}/actions/runs/{run['id']}", token=token)
  emit({"sglang_run_conclusion": run["conclusion"]})
  if run["conclusion"] != "success":
    raise Error(
        f"sglang-torchtpu remote-wheel run {run['html_url']} ended"
        f" {run['conclusion']}"
    )


# --- record -----------------------------------------------------------------


def record_golden(root, sha, version, vllm_url, sglang_url, timestamp=None):
  """Writes lkg.version and appends the row to verified_commits.csv.

  The CSV gets its header when it does not exist yet; a row for the same
  commit and version is not added twice.

  Args:
    root: The tpu-sync checkout to write in.
    sha: The full SHA of the golden commit.
    version: The tpu-sync-torch nightly version built from it.
    vllm_url: The vllm-torchtpu canary build that passed.
    sglang_url: The sglang-torchtpu remote-wheel run that passed.
    timestamp: The row's "YYYY-MM-DD HH:MM:SS" UTC time; now when None.

  Returns:
    The paths written.

  Raises:
    Error: The SHA is not a full commit SHA, or the CSV has other columns.
  """
  if not _SHA_RE.match(sha):
    raise Error(f"not a full commit SHA: {sha!r}")
  root = pathlib.Path(root)
  lkg = root / LKG_FILE
  lkg.write_text(sha + "\n", encoding="utf-8")
  verified = root / VERIFIED_FILE
  rows = []
  if verified.exists():
    with verified.open(newline="", encoding="utf-8") as f:
      reader = csv.DictReader(f)
      if reader.fieldnames and tuple(reader.fieldnames) != VERIFIED_COLUMNS:
        raise Error(
            f"{VERIFIED_FILE} has the columns {reader.fieldnames},"
            f" expected {list(VERIFIED_COLUMNS)}"
        )
      rows = list(reader)
  if any(
      r["tpu_sync_commit"] == sha and r["tpu_sync_torch_version"] == version
      for r in rows
  ):
    return [lkg]
  when = timestamp or _now().strftime("%Y-%m-%d %H:%M:%S")
  with verified.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=VERIFIED_COLUMNS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    writer.writerow({
        "timestamp": when,
        "tpu_sync_commit": sha,
        "tpu_sync_torch_version": version,
        "vllm_torchtpu_build": vllm_url,
        "sglang_torchtpu_run": sglang_url,
    })
  return [lkg, verified]


def golden_tag(version, today=None):
  """Names the tag of a golden commit: golden-YYYYMMDD of its nightly.

  Args:
    version: The tpu-sync-torch version of the golden commit.
    today: The date a version without a stamp (a release) is tagged with; now,
      UTC, when None.

  Returns:
    The tag name.
  """
  stamp = dev_stamp(version) or today or _now()
  return f"golden-{stamp.strftime('%Y%m%d')}"


def cmd_record(args):
  """The record subcommand: write the golden record files."""
  written = record_golden(
      args.root, args.sha, args.version, args.vllm_url, args.sglang_url
  )
  emit({
      "golden_tag": golden_tag(args.version),
      "written": " ".join(str(p) for p in written),
  })


# --- bump -------------------------------------------------------------------


def rewrite_pin(text, version):
  """Replaces every tpu-sync-torch==<x> pin in a text.

  Args:
    text: The text of a pin file.
    version: The version to pin.

  Returns:
    The new text and the number of pins replaced.
  """
  return _PIN_RE.subn(
      lambda m: m.group(0).split("==")[0] + "==" + version, text
  )


def bump_downstream(repo_dir, downstream, version):
  """Rewrites the tpu-sync-torch pin files of a downstream checkout.

  Args:
    repo_dir: The checkout of the downstream repository.
    downstream: Which downstream: a key of DOWNSTREAM_PIN_FILES.
    version: The version to pin.

  Returns:
    The pin files that changed, relative to the checkout; empty when the
    checkout pinned the version already.

  Raises:
    Error: The downstream is unknown, or a pin file is missing or has no pin.
  """
  if downstream not in DOWNSTREAM_PIN_FILES:
    raise Error(
        f"unknown downstream {downstream!r}; one of"
        f" {sorted(DOWNSTREAM_PIN_FILES)}"
    )
  changed = []
  for relative in DOWNSTREAM_PIN_FILES[downstream]:
    path = pathlib.Path(repo_dir) / relative
    if not path.exists():
      raise Error(f"{path} does not exist; the pin files of {downstream} moved")
    text = path.read_text(encoding="utf-8")
    new_text, count = rewrite_pin(text, version)
    if count == 0:
      raise Error(f"no tpu-sync-torch pin in {path}")
    if new_text != text:
      path.write_text(new_text, encoding="utf-8")
      changed.append(relative)
  return changed


def cmd_bump(args):
  """The bump subcommand: rewrite a downstream checkout's pin."""
  changed = bump_downstream(args.repo_dir, args.downstream, args.version)
  emit({
      "downstream_repo": DOWNSTREAM_REPOS[args.downstream],
      "changed_files": " ".join(changed),
      "already_pinned": str(not changed).lower(),
  })


# --- main -------------------------------------------------------------------


def build_parser():
  """Builds the command-line parser; each subcommand sets its handler."""
  parser = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
  )
  sub = parser.add_subparsers(dest="command", required=True)

  p = sub.add_parser(
      "resolve", help="pick the candidate version and its commit"
  )
  p.add_argument(
      "--version",
      help=f"{PYPI_PROJECT} nightly to verify (default: newest on PyPI)",
  )
  p.add_argument(
      "--repo", default=DEFAULT_REPO, help="GitHub repository of the nightlies"
  )
  p.set_defaults(func=cmd_resolve)

  p = sub.add_parser(
      "vllm", help="run the vllm-torchtpu canary (BUILDKITE_API_TOKEN)"
  )
  p.add_argument("--version", required=True)
  p.add_argument("--org", default=DEFAULT_BUILDKITE_ORG)
  p.add_argument("--pipeline", default=DEFAULT_VLLM_PIPELINE)
  p.add_argument(
      "--branch", default="main", help="vllm-torchtpu branch to build"
  )
  p.add_argument(
      "--torch-tpu-version",
      help="torch-tpu nightly for the other leg (default: newest)",
  )
  p.add_argument(
      "--lanes",
      help="CI_LANES override, e.g. 'tests integration' (default: all)",
  )
  p.add_argument(
      "--build-number",
      type=int,
      help="wait for this existing build instead of starting one",
  )
  p.add_argument("--timeout-minutes", type=int, default=340)
  p.add_argument(
      "--no-wait", action="store_true", help="start the build and return"
  )
  p.set_defaults(func=cmd_vllm)

  p = sub.add_parser(
      "sglang",
      help=(
          "run the sglang-torchtpu remote-wheel workflow (SGLANG_GITHUB_TOKEN)"
      ),
  )
  p.add_argument("--version", required=True)
  p.add_argument("--repo", default=DEFAULT_SGLANG_REPO)
  p.add_argument("--workflow", default=DEFAULT_SGLANG_WORKFLOW)
  p.add_argument("--ref", default="main", help="sglang-torchtpu ref to test")
  p.add_argument(
      "--only",
      default="all",
      help="the workflow's 'only' input: all, feature-validation, perf, ...",
  )
  p.add_argument(
      "--run-id",
      type=int,
      help="wait for this existing run instead of dispatching one",
  )
  p.add_argument("--timeout-minutes", type=int, default=340)
  p.add_argument(
      "--no-wait", action="store_true", help="dispatch the run and return"
  )
  p.set_defaults(func=cmd_sglang)

  p = sub.add_parser(
      "record", help="write lkg.version and verified_commits.csv"
  )
  p.add_argument("--root", default=".", help="tpu-sync checkout")
  p.add_argument("--sha", required=True)
  p.add_argument("--version", required=True)
  p.add_argument("--vllm-url", required=True)
  p.add_argument("--sglang-url", required=True)
  p.set_defaults(func=cmd_record)

  p = sub.add_parser(
      "bump", help="rewrite the tpu-sync-torch pin of a downstream checkout"
  )
  p.add_argument(
      "--downstream", required=True, choices=sorted(DOWNSTREAM_PIN_FILES)
  )
  p.add_argument("--repo-dir", required=True)
  p.add_argument("--version", required=True)
  p.set_defaults(func=cmd_bump)
  return parser


def main(argv=None):
  """Runs the subcommand named in argv; returns the process exit code."""
  args = build_parser().parse_args(argv)
  try:
    args.func(args)
  except Error as e:
    _log(f"ERROR: {e}")
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
