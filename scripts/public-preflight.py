#!/usr/bin/env python3
"""Check the tracked public-source scope; this is not a complete secret scanner."""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
files = [Path(p) for p in subprocess.check_output(
    ["git", "ls-files", "-z"], cwd=root).decode().split("\0") if p]
problems = []
required = {"LICENSE", "README.md", "SECURITY.md", "CONTRIBUTING.md",
            "THIRD_PARTY_NOTICES.md", "docs/PRIVACY.md", "docs/LIMITATIONS.md",
            "docs/VALIDATION.md", ".github/workflows/ci.yml"}
problems.extend(f"Missing tracked document: {p}" for p in sorted(required - {str(p) for p in files}))
patterns = {
    "absolute personal path": re.compile(r"/" + "Users/" + r"[^/\s]+/"),
    "private signing team": re.compile(r"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"),
    "API token": re.compile(r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}"),
    "AWS key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
}
for path in files:
    if path.parts[0] in {"Legacy", "LocalLibrary", "FactoryWork", "Secrets", "DerivedData", ".build"}:
        problems.append(f"Private/generated directory: {path}")
    if path.suffix.lower() in {".epub", ".key", ".p12", ".mobileprovision", ".sqlite", ".db"}:
        problems.append(f"Private/binary data type: {path}")
    if path.name == ".env" or path.name.startswith(".env.") and path.name != ".env.example":
        problems.append(f"Environment secrets file: {path}")
    data = (root / path).read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        continue
    for label, pattern in patterns.items():
        if pattern.search(text):
            problems.append(f"{label}: {path}")
for path in ["Package.resolved", "Worldbook.xcworkspace/xcshareddata/swiftpm/Package.resolved",
             "Worldbook.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]:
    pins = json.loads((root / path).read_text())["pins"]
    if {pin["identity"] for pin in pins} != {"zipfoundation"}:
        problems.append(f"Unexpected dependency scope: {path}")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"Public source scope passed: {len(files)} tracked files. Run a dedicated secret scanner before release.")
