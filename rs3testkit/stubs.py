"""Read id tables (id.Font, id.Component, id.NPC, ...) from a local clone of
the community LuaLS stubs: https://github.com/FriendlyDevelopment/runescape-api-stubs

That repo has no licence, so the kit never copies its files. Instead it
reads the `csvs/` folder of a clone you made yourself:

    git clone --depth 1 https://github.com/FriendlyDevelopment/runescape-api-stubs
    rs3test run plugin spec --ids ../runescape-api-stubs     (or set RS3_API_STUBS)

Each CSV row is `number,NAME[,extra columns]`. A table is parsed the first
time a spec looks a name up in it, and kept for the rest of the run.
"""

from __future__ import annotations

import csv
import os
from pathlib import Path

ENV = "RS3_API_STUBS"


class StubIds:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.csv_dir = self.root / "csvs"
        if not self.csv_dir.is_dir():
            raise FileNotFoundError(
                f"{self.root} has no csvs/ folder; point --ids at a clone of "
                "https://github.com/FriendlyDevelopment/runescape-api-stubs")
        self.kinds = sorted(p.stem for p in self.csv_dir.glob("*.csv"))
        self._by_name: dict[str, dict[str, int]] = {}
        self._by_number: dict[str, dict[int, str]] = {}
        self.lookups = 0
        self.revision = self._revision()

    def _revision(self) -> str:
        """The clone's commit, for the run summary (where the ids came from)."""
        head = self.root / ".git" / "HEAD"
        try:
            ref = head.read_text(encoding="utf-8").strip()
            if ref.startswith("ref: "):
                ref_file = self.root / ".git" / ref[5:]
                if ref_file.is_file():
                    return ref_file.read_text(encoding="utf-8").strip()[:7]
                packed = self.root / ".git" / "packed-refs"
                for line in packed.read_text(encoding="utf-8").splitlines():
                    if line.endswith(ref[5:]):
                        return line.split()[0][:7]
            return ref[:7]
        except OSError:
            return "unknown"

    def _load(self, kind: str) -> None:
        if kind in self._by_name:
            return
        names: dict[str, int] = {}
        numbers: dict[int, str] = {}
        path = self.csv_dir / f"{kind}.csv"
        if path.is_file():
            with path.open(encoding="utf-8", newline="") as f:
                for row in csv.reader(f):
                    if len(row) < 2:
                        continue
                    try:
                        number = int(row[0])
                    except ValueError:
                        continue
                    name = row[1].strip()
                    if name and name not in names:
                        names[name] = number
                        numbers.setdefault(number, name)
        self._by_name[kind] = names
        self._by_number[kind] = numbers

    def number(self, kind: str, name: str) -> int | None:
        self.lookups += 1
        self._load(kind)
        return self._by_name[kind].get(name)

    def name(self, kind: str, number: int) -> str | None:
        self.lookups += 1
        self._load(kind)
        return self._by_number[kind].get(int(number))


_cache: dict[Path, StubIds] = {}


def open_stubs(path: str | Path | None) -> StubIds | None:
    """The stub ids at `path`, else $RS3_API_STUBS, else None. Cached per path
    so several spec files in one run parse each CSV once."""
    path = path or os.environ.get(ENV)
    if not path:
        return None
    key = Path(path).resolve()
    if key not in _cache:
        _cache[key] = StubIds(key)
    return _cache[key]
