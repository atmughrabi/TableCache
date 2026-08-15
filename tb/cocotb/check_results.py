"""Return nonzero when a cocotb JUnit result contains failures."""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "results.xml")
    if not path.is_file():
        print(f"cocotb results missing: {path}", file=sys.stderr)
        return 1

    root = ET.parse(path).getroot()
    tests = list(root.iter("testcase"))
    failed = [
        test for test in tests
        if test.find("failure") is not None or test.find("error") is not None
    ]

    if not tests:
        print(f"cocotb results contain no tests: {path}", file=sys.stderr)
        return 1
    if all(test.find("skipped") is not None for test in tests):
        print(f"cocotb results contain only skipped tests: {path}", file=sys.stderr)
        return 1
    if failed:
        names = ", ".join(
            f"{test.get('classname', '')}.{test.get('name', '')}".strip(".")
            for test in failed
        )
        print(f"cocotb failures: {names}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
