#!/usr/bin/env python3
"""Package official plugins and generate the release catalogue.

Each `plugins/<name>/` directory becomes `plugin-<name>.zip`, and their
descriptors are collected into `catalog.json` — the index `proxima plugin
install` reads.

SPECS §21.1 has the generator read `version` and `author` from `plugin.json`,
but the descriptor schema (§20) defines neither. Rather than extend a schema
`PluginLoader` already validates, both are synthesised here: `version` from the
release tag, `author` defaulting to `proxima-core`. A descriptor may still
override either.

Usage:
    build_catalog.py --plugins-dir plugins/ --version 1.6.0 \
                     --output dist/catalog.json --zip-dir dist/
"""

import argparse
import hashlib
import json
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPO = "jizzel/proxima"
DOWNLOAD_BASE = f"https://github.com/{REPO}/releases/latest/download"

# Mirrors PluginLoader's validation: a plugin missing any of these is skipped
# at load time, so publishing it would only produce a confusing failure.
REQUIRED_FIELDS = ("name", "description", "executable", "input_schema")


def zip_plugin(plugin_dir: Path, zip_path: Path) -> None:
    """Zips a plugin directory with paths relative to the directory itself."""
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(plugin_dir.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(plugin_dir))


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(plugins_dir: Path, version: str, output: Path, zip_dir: Path) -> int:
    if not plugins_dir.is_dir():
        print(f"error: {plugins_dir} is not a directory", file=sys.stderr)
        return 1

    zip_dir.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)

    entries = []
    for plugin_dir in sorted(p for p in plugins_dir.iterdir() if p.is_dir()):
        descriptor_path = plugin_dir / "plugin.json"
        if not descriptor_path.is_file():
            print(f"skip {plugin_dir.name}: no plugin.json", file=sys.stderr)
            continue

        try:
            descriptor = json.loads(descriptor_path.read_text())
        except json.JSONDecodeError as error:
            print(f"error: {descriptor_path}: {error}", file=sys.stderr)
            return 1

        missing = [f for f in REQUIRED_FIELDS if not descriptor.get(f)]
        if missing:
            print(
                f"error: {descriptor_path} missing {', '.join(missing)}",
                file=sys.stderr,
            )
            return 1

        # The catalogue is keyed by directory name, which is what `plugin
        # install <name>` and the install path both use. The descriptor's
        # `name` is the *tool* name and may legitimately differ.
        name = plugin_dir.name
        zip_path = zip_dir / f"plugin-{name}.zip"
        zip_plugin(plugin_dir, zip_path)

        entries.append(
            {
                "name": name,
                "display_name": descriptor.get("display_name", name),
                "description": descriptor["description"],
                "version": descriptor.get("version", version),
                "risk_level": descriptor.get("risk_level", "confirm"),
                "author": descriptor.get("author", "proxima-core"),
                "tags": descriptor.get("tags", []),
                "download_url": f"{DOWNLOAD_BASE}/plugin-{name}.zip",
                "checksum_sha256": sha256_of(zip_path),
            }
        )
        print(f"packaged {name} -> {zip_path.name}")

    catalog = {
        "version": "1",
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "plugins": entries,
    }
    output.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"wrote {output} with {len(entries)} plugin(s)")
    return 0


def validate(plugins_dir: Path) -> int:
    """Checks every descriptor without packaging — used by CI."""
    if not plugins_dir.is_dir():
        print(f"no {plugins_dir} directory; nothing to validate")
        return 0

    failures = 0
    for plugin_dir in sorted(p for p in plugins_dir.iterdir() if p.is_dir()):
        descriptor_path = plugin_dir / "plugin.json"
        if not descriptor_path.is_file():
            print(f"FAIL {plugin_dir.name}: no plugin.json", file=sys.stderr)
            failures += 1
            continue

        try:
            descriptor = json.loads(descriptor_path.read_text())
        except json.JSONDecodeError as error:
            print(f"FAIL {plugin_dir.name}: {error}", file=sys.stderr)
            failures += 1
            continue

        missing = [f for f in REQUIRED_FIELDS if not descriptor.get(f)]
        if missing:
            print(
                f"FAIL {plugin_dir.name}: missing {', '.join(missing)}",
                file=sys.stderr,
            )
            failures += 1
            continue

        executable = plugin_dir / descriptor["executable"]
        if not executable.is_file():
            print(
                f"FAIL {plugin_dir.name}: executable "
                f"{descriptor['executable']} not found",
                file=sys.stderr,
            )
            failures += 1
            continue

        print(f"ok   {plugin_dir.name}")

    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugins-dir", type=Path, default=Path("plugins"))
    parser.add_argument("--version", default="0.0.0")
    parser.add_argument("--output", type=Path, default=Path("dist/catalog.json"))
    parser.add_argument("--zip-dir", type=Path, default=Path("dist"))
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="check descriptors without packaging (CI)",
    )
    args = parser.parse_args()

    if args.validate_only:
        return validate(args.plugins_dir)
    return build(args.plugins_dir, args.version, args.output, args.zip_dir)


if __name__ == "__main__":
    sys.exit(main())
