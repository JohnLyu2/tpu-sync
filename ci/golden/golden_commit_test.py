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

"""Tests for golden_commit.py: the pure functions behind each subcommand."""

import datetime
import pathlib
import tempfile
import unittest

from ci.golden import golden_commit

_UTC = datetime.timezone.utc


def _run(run_id, created_at, branch="main", event="workflow_dispatch"):
  return {
      "id": run_id,
      "created_at": created_at,
      "head_branch": branch,
      "head_sha": f"{run_id:040x}",
      "html_url": f"https://github.com/google/tpu-sync/actions/runs/{run_id}",
      "event": event,
  }


class DevStampTest(unittest.TestCase):

  def test_parses_nightly_stamp(self):
    self.assertEqual(
        golden_commit.dev_stamp("0.0.1.dev20261013083150"),
        datetime.datetime(2026, 10, 13, 8, 31, 50, tzinfo=_UTC),
    )

  def test_rejects_release_and_bad_stamps(self):
    self.assertIsNone(golden_commit.dev_stamp("0.1.0"))
    self.assertIsNone(golden_commit.dev_stamp("0.0.1.dev2026"))
    self.assertIsNone(golden_commit.dev_stamp("0.0.1.dev20261399000000"))


class LatestDevVersionTest(unittest.TestCase):

  def test_picks_newest_stamp_and_skips_yanked_and_releases(self):
    releases = {
        "0.0.1": [{"yanked": False}],
        "0.0.1.dev20261012084241": [{"yanked": False}],
        "0.0.1.dev20261013083150": [{"yanked": False}],
        "0.0.1.dev20261014083000": [{"yanked": True}],
        "0.0.2.dev20261010000000": [{"yanked": False}],
        "0.0.1.dev20261015000000": [],
    }
    self.assertEqual(
        golden_commit.latest_dev_version(releases), "0.0.1.dev20261013083150"
    )

  def test_base_version_breaks_ties(self):
    releases = {
        "0.0.2.dev20261013083150": [{}],
        "0.0.10.dev20261013083150": [{}],
    }
    self.assertEqual(
        golden_commit.latest_dev_version(releases), "0.0.10.dev20261013083150"
    )

  def test_no_nightly_is_an_error(self):
    with self.assertRaises(golden_commit.Error):
      golden_commit.latest_dev_version({"0.0.1": [{}]})


class MatchNightlyRunTest(unittest.TestCase):

  def test_picks_closest_main_run_inside_window(self):
    stamp = datetime.datetime(2026, 10, 13, 8, 0, 5, tzinfo=_UTC)
    runs = [
        _run(1, "2026-10-12T08:00:02Z"),
        _run(2, "2026-10-13T08:00:01Z", branch="feature"),
        _run(3, "2026-10-13T08:00:02Z"),
        _run(4, "2026-10-13T08:15:00Z"),
    ]
    self.assertEqual(golden_commit.match_nightly_run(runs, stamp)["id"], 3)

  def test_none_outside_window(self):
    stamp = datetime.datetime(2026, 10, 13, 8, 0, 0, tzinfo=_UTC)
    self.assertIsNone(
        golden_commit.match_nightly_run(
            [_run(1, "2026-10-13T09:00:00Z")], stamp
        )
    )


class VllmBuildEnvTest(unittest.TestCase):

  def test_tests_only_the_tpu_sync_leg(self):
    env = golden_commit.vllm_build_env("0.0.1.dev20261013083150")
    self.assertEqual(env["TORCHTPU_NIGHTLY"], "1")
    self.assertEqual(env["TORCHTPU_NIGHTLY_LEG"], "tpu-sync")
    self.assertEqual(
        env["TPU_SYNC_TORCH_VERSION_OVERRIDE"], "0.0.1.dev20261013083150"
    )
    self.assertEqual(env["NIGHTLY"], "1")
    self.assertNotIn("KUBE_OWNS_NIGHTLY", env)
    self.assertNotIn("TORCH_TPU_VERSION_OVERRIDE", env)
    self.assertNotIn("CI_LANES", env)

  def test_optional_overrides(self):
    env = golden_commit.vllm_build_env(
        "1", torch_tpu_version="0.1.1.dev1", lanes="tests"
    )
    self.assertEqual(env["TORCH_TPU_VERSION_OVERRIDE"], "0.1.1.dev1")
    self.assertEqual(env["CI_LANES"], "tests")


class SglangTest(unittest.TestCase):

  def test_inputs_name_the_pypi_requirement(self):
    self.assertEqual(
        golden_commit.sglang_inputs("0.0.1.dev20261013083150", only="perf"),
        {
            "ref": "main",
            "wheel": "tpu-sync-torch==0.0.1.dev20261013083150",
            "only": "perf",
        },
    )

  def test_pick_dispatched_run_ignores_old_known_and_other_events(self):
    dispatched_at = datetime.datetime(2026, 10, 13, 9, 0, 0, tzinfo=_UTC)
    runs = [
        _run(10, "2026-10-13T08:00:00Z"),
        _run(11, "2026-10-13T08:59:30Z"),
        _run(12, "2026-10-13T09:00:10Z", event="schedule"),
        _run(13, "2026-10-13T09:00:20Z"),
        _run(14, "2026-10-13T09:00:30Z"),
    ]
    picked = golden_commit.pick_dispatched_run(
        runs, dispatched_at, known_ids={11, 14}
    )
    self.assertEqual(picked["id"], 13)
    self.assertIsNone(
        golden_commit.pick_dispatched_run(runs[:1], dispatched_at)
    )


class RecordGoldenTest(unittest.TestCase):

  def setUp(self):
    super().setUp()
    self.root = pathlib.Path(tempfile.mkdtemp())
    self.sha = "110ebcef084232816c9e30d3ce2ee27f47062055"

  def test_writes_lkg_and_creates_csv_with_header(self):
    written = golden_commit.record_golden(
        self.root,
        self.sha,
        "0.0.1.dev20261013083150",
        "https://bk/1",
        "https://gh/2",
        "2026-10-20 16:00:00",
    )
    self.assertEqual(
        [p.name for p in written], ["lkg.version", "verified_commits.csv"]
    )
    self.assertEqual((self.root / "lkg.version").read_text(), self.sha + "\n")
    self.assertEqual(
        (self.root / "verified_commits.csv").read_text(),
        "timestamp,tpu_sync_commit,tpu_sync_torch_version,"
        "vllm_torchtpu_build,sglang_torchtpu_run\n"
        f"2026-10-20 16:00:00,{self.sha},0.0.1.dev20261013083150,"
        "https://bk/1,https://gh/2\n",
    )

  def test_appends_and_does_not_duplicate(self):
    args = (
        self.root,
        self.sha,
        "0.0.1.dev20261013083150",
        "https://bk/1",
        "https://gh/2",
        "2026-10-20 16:00:00",
    )
    golden_commit.record_golden(*args)
    golden_commit.record_golden(*args)
    other = "f" * 40
    golden_commit.record_golden(
        self.root,
        other,
        "0.0.1.dev20261020083150",
        "b",
        "s",
        "2026-10-27 16:00:00",
    )
    lines = (self.root / "verified_commits.csv").read_text().splitlines()
    self.assertEqual(len(lines), 3)
    self.assertTrue(lines[2].startswith(f"2026-10-27 16:00:00,{other},"))
    self.assertEqual((self.root / "lkg.version").read_text(), other + "\n")

  def test_rejects_short_sha_and_foreign_header(self):
    with self.assertRaises(golden_commit.Error):
      golden_commit.record_golden(self.root, "abc123", "v", "b", "s")
    (self.root / "verified_commits.csv").write_text(
        "timestamp,vllm_commit_hash\n"
    )
    with self.assertRaises(golden_commit.Error):
      golden_commit.record_golden(self.root, self.sha, "v", "b", "s")

  def test_golden_tag_dates_the_nightly(self):
    today = datetime.datetime(2026, 10, 21, tzinfo=_UTC)
    self.assertEqual(
        golden_commit.golden_tag("0.0.1.dev20261013083150", today),
        "golden-20261013",
    )
    self.assertEqual(
        golden_commit.golden_tag("0.1.0", today), "golden-20261021"
    )


class BumpTest(unittest.TestCase):

  def test_rewrite_pin_keeps_spelling(self):
    old = "0.0.1.dev20261012084241"
    new = "0.0.1.dev20261013083150"
    text, count = golden_commit.rewrite_pin(
        f'    "tpu-sync-torch=={old}",\ntpu_sync_torch==0.0.1.dev1 # x\n', new
    )
    self.assertEqual(count, 2)
    self.assertEqual(
        text, f'    "tpu-sync-torch=={new}",\ntpu_sync_torch=={new} # x\n'
    )

  def test_bump_downstream_rewrites_every_pin_file(self):
    root = pathlib.Path(tempfile.mkdtemp())
    for relative in golden_commit.DOWNSTREAM_PIN_FILES["sglang"]:
      path = root / relative
      path.parent.mkdir(parents=True, exist_ok=True)
      path.write_text(
          "torch_tpu==0.2.0\ntpu-sync-torch==0.0.1.dev20261013083150\n"
      )
    changed = golden_commit.bump_downstream(
        root, "sglang", "0.0.1.dev20261020083150"
    )
    self.assertEqual(
        changed, list(golden_commit.DOWNSTREAM_PIN_FILES["sglang"])
    )
    for relative in changed:
      self.assertIn(
          "tpu-sync-torch==0.0.1.dev20261020083150",
          (root / relative).read_text(),
      )
    self.assertEqual(
        golden_commit.bump_downstream(
            root, "sglang", "0.0.1.dev20261020083150"
        ),
        [],
    )

  def test_bump_downstream_fails_without_a_pin(self):
    root = pathlib.Path(tempfile.mkdtemp())
    (root / "pyproject.toml").write_text('dependencies = ["torch"]\n')
    with self.assertRaises(golden_commit.Error):
      golden_commit.bump_downstream(root, "vllm", "0.0.1.dev1")


if __name__ == "__main__":
  unittest.main()
