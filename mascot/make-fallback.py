"""Regenerate compact fallback data, retaining only tiers up to 44 columns.

Usage: python -I make-fallback.py input-mascot.json output-mascot.json
The source can be the original five-tier file or the current compact file.
Retained frames are preserved exactly; running this again is safe.
"""
import json
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:3])
data = json.loads(source.read_text(encoding="utf-8-sig"))
tiers = [tier for tier in data["tiers"] if int(tier["cols"]) <= 44]
assert tiers and all(tier["frames"] for tier in tiers), "No usable fallback frames"
data["tiers"] = sorted(tiers, key=lambda tier: int(tier["cols"]), reverse=True)
destination.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print(f"Wrote {len(tiers)} tiers; {destination.stat().st_size:,} bytes")
