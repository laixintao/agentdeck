#!/usr/bin/env python3
"""Install only AgentDeck's passive Hermes hooks; retain a byte-for-byte backup."""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import time

import yaml  # Uses Hermes' own Python environment, which already requires PyYAML.


def install(home: Path, source: Path, destination: Path):
    config = home / "config.yaml"
    original = config.read_text() if config.exists() else ""
    value = yaml.safe_load(original) or {}
    if not isinstance(value, dict):
        raise ValueError("config.yaml must contain a YAML mapping")
    hooks = value.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be a YAML mapping")
    command = shlex.join([str(destination), "hermes-hook"])
    for name in ["pre_llm_call", "post_llm_call", "on_human_input_request", "on_human_input_resolved"]:
        entries = hooks.setdefault(name, [])
        if not isinstance(entries, list):
            raise ValueError(f"hooks.{name} must be a list")
        # Retain unrelated hook entries and their ordering. Installation is idempotent.
        entries[:] = [entry for entry in entries if not (isinstance(entry, dict) and entry.get("command") == command)]
        entries.append({"command": command, "timeout": 10})
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if source.resolve() != destination.resolve():
        shutil.copy2(source, destination)
    destination.chmod(0o700)
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = None
    if config.exists():
        backup = home / f"config.yaml.agentdeck-backup-{time.time_ns()}"
        shutil.copy2(config, backup)
        backup.chmod(0o600)
    fd, temporary = tempfile.mkstemp(prefix=".agentdeck-", dir=home)
    try:
        with os.fdopen(fd, "w") as file:
            yaml.safe_dump(value, file, allow_unicode=True, sort_keys=False)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps({"config": str(config), "backup": str(backup) if backup else None}))


if __name__ == "__main__":
    install(Path(sys.argv[1]).expanduser(), Path(sys.argv[2]), Path(sys.argv[3]))
