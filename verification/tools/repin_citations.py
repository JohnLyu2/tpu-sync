#!/usr/bin/env python3
"""Re-pin `file:line` citations in the verification corpus from one tpu-sync
commit to another.

    tools/repin_citations.py OLD NEW [--apply] [--skip SRC:LINE ...] [SOURCE ...]

Run from `verification/`. Default sources: `TpuSyncVerify/**/*.lean` and
`docs/**/*.md`. OLD and NEW are any two tpu-sync revisions known to the
enclosing git repository (e.g. `01ffa3d upstream-main-2026-10-06`).

For every citation, the cited OLD line range is mapped through
`git diff -U0 OLD NEW -- <file>` and one report line is printed:

    SRC:LINE  path  old -> new  STATUS

    same    file unchanged, or nothing changed before the cited lines
    shift   the range moved by a constant offset
    grown   pure insertions landed inside the range, which was widened
    CHECK   the range overlaps modified or deleted lines; the printed new
            range is a guess — re-read the code and fix by hand
    skip    left alone: unknown or external file, ambiguous basename, a line
            that names another commit (e.g. `b68161a`), or --skip

With --apply, `same`/`shift`/`grown` citations are rewritten in place; a
citation with any CHECK element is left untouched as a whole. The preamble
sentence that names the commit is *not* rewritten — change it by hand once the
report is clean, and record the re-check in `docs/transfer/prefill_decode.md`
(see `docs/conventions.md`).

Recognised forms (the number must follow a colon):

    `alias:N`  `alias:N-M`  `alias:N, M, P-Q`   alias = short name in ALIASES,
                                                or a basename / path in the
                                                tpu-sync tree at OLD
    `.cc:N`  `.h:N`                              the source module's default
                                                pair (DEFAULTS)
    `:N`  (backtick, colon, digits)              the file of the previous
                                                citation in the same source

Not recognised, fix by hand after --apply:
  * a bare backticked range after a comma: `recv.cc:385-388`, `651-653`
    (grep for `\\`[0-9]+-[0-9]+\\``);
  * the tail of a list that wraps onto the next line: `mgr.cc:1551-1554,`
    newline `1595-1606` (grep for lines starting with digits, and for
    citations ending in a comma).
"""

import argparse
import collections
import os
import re
import subprocess
import sys

ALIASES = {
    "recv.cc": "tpu_sync/core/transfer_receive_session.cc",
    "recv.h": "tpu_sync/core/transfer_receive_session.h",
    "send.cc": "tpu_sync/core/transfer_send_session.cc",
    "send.h": "tpu_sync/core/transfer_send_session.h",
    "mgr.cc": "tpu_sync/core/kv_cache_manager_with_transfer.cc",
    "mgr.h": "tpu_sync/core/kv_cache_manager_with_transfer.h",
    "bt.cc": "tpu_sync/transport/block_transport.cc",
    "bt.h": "tpu_sync/transport/block_transport.h",
    "send_drain_test.cc":
        "tpu_sync/core/kv_cache_manager_with_transfer_send_drain_test.cc",
    "control_test.cc":
        "tpu_sync/core/kv_cache_manager_with_transfer_control_test.cc",
}

# Files cited by basename that are not part of the tpu-sync tree.
EXTERNAL = {"tpu_connector.py"}

# Unqualified `.cc` / `.h` per source module: the stem of the default pair.
RECV = "tpu_sync/core/transfer_receive_session"
SEND = "tpu_sync/core/transfer_send_session"
DEFAULTS = {
    "TpuSyncVerify/Transfer/PrefillDecode/Receive.lean": RECV,
    "TpuSyncVerify/Transfer/PrefillDecode/ReceivePoll.lean": RECV,
    # Session.lean: recv by default; the send column of its field table and
    # any `send` paragraph must be checked by hand in the report.
    "TpuSyncVerify/Transfer/Session.lean": RECV,
    "TpuSyncVerify/Transfer/PrefillDecode/Send.lean": SEND,
    # prefill_decode.md: rows about `Send.*` theorems cite send.cc — check.
    "docs/transfer/prefill_decode.md": RECV,
}

# File assumed by a bare `:N` citation when no explicit citation precedes it
# in the source (the controller module cites raiden_controller.cc throughout).
CTRL = "tpu_sync/core/controller/raiden_controller.cc"
BARE_DEFAULTS = {
    "TpuSyncVerify/Controller/ReadRemote.lean": CTRL,
    "docs/controller/read_remote.md": CTRL,
}

HEX7 = re.compile(r"\b[0-9a-f]{7}\b")
NUM_ELEM = r"\d+(?:\s*[-\u2013]\s*\d+)?"
NUMS = r":(?P<nums>" + NUM_ELEM + r"(?:\s*,\s*" + NUM_ELEM + r")*)"
TOKEN = r"(?P<tok>(?:[\w./-]*/)?[\w-]+\.(?:cc|h|py|proto))[ `]*"
UNQ = r"(?P<unq>`\.(?:cc|h))"
BARE = r"(?P<bare>`)"
CITE = re.compile(r"(?:" + TOKEN + r"|" + UNQ + r"|" + BARE + r")" + NUMS)
ELEM = re.compile(NUM_ELEM)


def git(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, capture_output=True,
                          text=True, check=True).stdout


def find_repo(start):
    d = os.path.abspath(start)
    while d != "/":
        if os.path.isdir(os.path.join(d, ".git")):
            return d
        d = os.path.dirname(d)
    sys.exit("not inside a git repository")


class Mapper:
    def __init__(self, repo, old, new):
        self.repo, self.old, self.new = repo, old, new
        # Short hash of OLD, so that a tag or branch name works for the
        # "line names another commit" rule as well.
        self.old_short = git(repo, "rev-parse", "--short=7", old).strip()
        self.by_base = collections.defaultdict(list)
        self.paths = set()
        for p in git(repo, "ls-tree", "-r", "--name-only", old).splitlines():
            if p.startswith("tpu_sync/"):
                self.paths.add(p)
                self.by_base[os.path.basename(p)].append(p)
        self._hunks = {}

    def hunks(self, path):
        if path not in self._hunks:
            out = git(self.repo, "diff", "-U0", self.old, self.new, "--", path)
            hs = []
            for m in re.finditer(
                    r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", out, re.M):
                a = int(m.group(1))
                b = int(m.group(2)) if m.group(2) is not None else 1
                c = int(m.group(3))
                d = int(m.group(4)) if m.group(4) is not None else 1
                hs.append((a, b, c, d))
            self._hunks[path] = hs
        return self._hunks[path]

    def resolve(self, tok):
        """Return (path | None, reason)."""
        if tok in ALIASES:
            return ALIASES[tok], ""
        if tok in EXTERNAL:
            return None, "external"
        if "/" in tok:
            cands = [p for p in self.paths if p == tok or p.endswith("/" + tok)]
            if len(cands) == 1:
                return cands[0], ""
            return None, "unknown-path" if not cands else "ambiguous"
        cands = self.by_base.get(tok, [])
        if len(cands) == 1:
            return cands[0], ""
        if not cands:
            return None, "unknown"
        if all(not self.hunks(p) for p in cands):
            return cands[0], ""  # ambiguous, but no candidate changed
        return None, "ambiguous"

    def remap(self, path, lo, hi):
        off, grow, touched = 0, 0, False
        for a, b, c, d in self.hunks(path):
            if b > 0:
                r_lo, r_hi = a, a + b - 1
                if r_hi < lo:
                    off += d - b
                elif r_lo > hi:
                    pass
                else:
                    touched = True
                    grow += d - b
            else:  # pure insertion after OLD line a
                if a < lo:
                    off += d
                elif a < hi:
                    grow += d
        if touched:
            return "CHECK", lo + off, hi + off + grow
        if grow:
            return "grown", lo + off, hi + off + grow
        if off:
            return "shift", lo + off, hi + off
        return "same", lo, hi


def fmt(lo, hi):
    return str(lo) if lo == hi else f"{lo}-{hi}"


def process(src, rel, mapper, skips, apply):
    text = open(src, encoding="utf-8").read()
    lines = text.split("\n")
    default = DEFAULTS.get(rel)
    prev_path = BARE_DEFAULTS.get(rel)
    counts = collections.Counter()
    out_lines = []
    for lineno, line in enumerate(lines, 1):
        others = set(HEX7.findall(line)) - {mapper.old_short}
        others = {h for h in others if not h.isdigit()}
        skip_line = (rel, lineno) in skips or bool(others)
        # Phase 1, left to right: resolve each citation (the bare `:N` form
        # needs the previous citation's file) and decide its new numbers.
        edits = []  # (start, end, replacement) within `line`
        for m in CITE.finditer(line):
            tok, unq, nums = m.group("tok"), m.group("unq"), m.group("nums")
            if tok:
                path, why = mapper.resolve(tok)
                label = tok
            elif unq:
                ext = unq[2:]  # "cc" or "h"
                path = f"{default}.{ext}" if default else None
                why = "no-default"
                label = f".{ext}"
            else:
                path, why, label = prev_path, "no-previous", "(prev)"
            if path is None:
                counts["skip"] += 1
                print(f"{rel}:{lineno}  {label}:{nums}  skip({why})")
                continue
            if tok or unq:
                prev_path = path
            if skip_line:
                counts["skip"] += 1
                reason = "other-commit" if others else "--skip"
                print(f"{rel}:{lineno}  {path}:{nums}  skip({reason})")
                continue
            elems = []
            for e in ELEM.finditer(nums):
                ns = [int(x) for x in re.split(r"\s*[-\u2013]\s*", e.group(0))]
                lo, hi = ns[0], ns[-1]
                st, nlo, nhi = mapper.remap(path, lo, hi)
                elems.append((e, st, lo, hi, nlo, nhi))
            worst = ("CHECK" if any(s == "CHECK" for _, s, *_ in elems)
                     else "grown" if any(s == "grown" for _, s, *_ in elems)
                     else "shift" if any(s == "shift" for _, s, *_ in elems)
                     else "same")
            counts[worst] += 1
            old_s = ", ".join(fmt(lo, hi) for _, _, lo, hi, _, _ in elems)
            new_s = ", ".join(fmt(nlo, nhi) for _, _, _, _, nlo, nhi in elems)
            tag = f"  via {label}" if not tok else ""
            if worst == "same":
                print(f"{rel}:{lineno}  {path}:{old_s}  same{tag}")
            else:
                print(f"{rel}:{lineno}  {path}:{old_s} -> {new_s}  {worst}{tag}")
            if worst in ("shift", "grown"):
                # Rebuild the nums group with new numbers, keeping separators.
                pieces, last = [], 0
                for e, st, lo, hi, nlo, nhi in elems:
                    pieces.append(nums[last:e.start()])
                    if lo != hi:
                        sep = e.group(0)[len(str(lo)):-len(str(hi))]
                        pieces.append(f"{nlo}{sep}{nhi}")
                    else:
                        pieces.append(str(nlo))
                    last = e.end()
                pieces.append(nums[last:])
                edits.append((m.start("nums"), m.end("nums"), "".join(pieces)))
        # Phase 2, right to left: splice, so earlier edits never move later spans.
        new_line = line
        if apply:
            for s, t, rep in sorted(edits, reverse=True):
                new_line = new_line[:s] + rep + new_line[t:]
        out_lines.append(new_line)
    if apply:
        new_text = "\n".join(out_lines)
        if new_text != text:
            open(src, "w", encoding="utf-8").write(new_text)
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--skip", action="append", default=[],
                    metavar="SRC:LINE", help="leave this source line alone")
    ap.add_argument("sources", nargs="*")
    args = ap.parse_args()

    here = os.getcwd()
    repo = find_repo(here)
    mapper = Mapper(repo, args.old, args.new)
    skips = set()
    for s in args.skip:
        f, n = s.rsplit(":", 1)
        skips.add((f, int(n)))

    sources = args.sources
    if not sources:
        for root, exts in (("TpuSyncVerify", (".lean",)), ("docs", (".md",))):
            for dp, _, fns in os.walk(root):
                sources += [os.path.join(dp, f) for f in sorted(fns)
                            if f.endswith(exts)]
    total = collections.Counter()
    for src in sorted(sources):
        rel = os.path.relpath(src, here)
        total.update(process(src, rel, mapper, skips, args.apply))
    print("\n# totals:", dict(total), "(applied)" if args.apply else "(dry run)")


if __name__ == "__main__":
    main()
