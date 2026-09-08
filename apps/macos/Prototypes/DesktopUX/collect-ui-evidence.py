#!/usr/bin/env python3
"""Collect named prototype screenshots; keep automatic recordings in the ignored run directory."""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

result = Path(sys.argv[1]).resolve()
run = Path(sys.argv[2]).resolve()
attachments = run / "attachments"
evidence = run / "evidence"
evidence.mkdir(parents=True, exist_ok=True)
subprocess.run(
    ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(attachments)],
    check=True,
    stdout=subprocess.DEVNULL,
)
summary = subprocess.check_output(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], text=True
)
(run / "summary.json").write_text(summary)
manifest_path = attachments / "manifest.json"
manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else []
index = []
for test in manifest:
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"]
        match = re.fullmatch(r"([a-z][a-z0-9-]+)_\d+_[A-F0-9-]+\.(png|txt)", name)
        if not match:
            continue
        filename = f"{match[1]}.{match[2]}"
        shutil.copyfile(attachments / attachment["exportedFileName"], evidence / filename)
        index.append({"file": filename, "test": test["testIdentifier"]})
(evidence / "index.json").write_text(json.dumps(index, indent=2) + "\n")
print(f"Named prototype evidence: {evidence}")
