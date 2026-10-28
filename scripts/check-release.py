#!/usr/bin/env python3
"""Validate the single release version across bumpversion and the app bundle."""
import argparse
import configparser
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parent.parent


def validate(tag=None):
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ValueError("VERSION must be a stable SemVer, for example 0.1.1")
    config = configparser.ConfigParser()
    config.read(ROOT / ".bumpversion.cfg")
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    values = [config["bumpversion"]["current_version"], info["CFBundleShortVersionString"], info["CFBundleVersion"]]
    if any(value != version for value in values):
        raise ValueError("VERSION, bumpversion, and both bundle version fields must match")
    if tag is not None and tag != "v" + version:
        raise ValueError(f"Release tag must be v{version}, got {tag!r}")
    return version


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    print(validate(parser.parse_args().tag))
