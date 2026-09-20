#!/usr/bin/env python3
"""Export (or check) the public ABI arrays from a completed forge build."""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
for name in ("HighRollToken", "HighRoll"):
    artifact = json.loads((root / "out" / f"{name}.sol" / f"{name}.json").read_text())
    output = root / "docs" / "abi" / f"{name}.json"
    rendered = json.dumps(artifact["abi"], indent=2) + "\n"
    if "--check" in sys.argv:
        if output.read_text() != rendered:
            raise SystemExit(f"Stale ABI: {output}")
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered)
