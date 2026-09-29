#!/usr/bin/env python3
"""Publish the three models to Hugging Face and pin the app's manifest to them.

For each model in app/Resources/models.json this uploads the built model
directory together with its license and card from models/<directory>/, into
the repository <namespace>/privacyflow-<directory>. It then writes each file's
URL into the manifest, pinned to the exact commit the upload created, so a
later change to the repository can never change what the app installs.

Every file is checked against the manifest's size and SHA-256 before anything
is uploaded: the manifest is what the app verifies downloads against, so
publishing files that disagree with it would ship an app that cannot install.

Run it from the worker's environment, which has huggingface_hub, after
logging in with a write token (`hf auth login`):

    worker/.venv/bin/python scripts/publish-models.py --namespace <name> --models <dir>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "app" / "Resources" / "models.json"
EXTRAS = ROOT / "models"


def sha256_of(path: pathlib.Path) -> str:
    """The hex SHA-256 of one file, read in chunks so multi-gigabyte weights stay out of memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_against_manifest(model: dict, source: pathlib.Path) -> None:
    """Refuse to publish a model whose files differ from what the manifest pins."""
    for entry in model["files"]:
        path = source / entry["path"]
        if not path.is_file():
            raise SystemExit(f"{path} is listed in models.json but does not exist")
        if path.stat().st_size != entry["bytes"]:
            raise SystemExit(f"{path} is {path.stat().st_size} bytes; models.json says {entry['bytes']}")
        if sha256_of(path) != entry["sha256"]:
            raise SystemExit(f"{path} does not match its SHA-256 in models.json")


def stage(model: dict, source: pathlib.Path, staging: pathlib.Path) -> pathlib.Path:
    """Assemble one repository's contents: the pinned files plus the license and card.

    Only files the manifest lists are taken from the build, so nothing stray in
    a build directory is ever published. Files are hard-linked where possible.
    """
    extras = EXTRAS / model["directory"]
    if not (extras / "LICENSE").is_file():
        raise SystemExit(f"{extras / 'LICENSE'} is missing; every published model carries its license")

    target = staging / model["directory"]
    for entry in model["files"]:
        destination = target / entry["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            destination.hardlink_to(source / entry["path"])
        except OSError:
            shutil.copy2(source / entry["path"], destination)
    for extra in extras.iterdir():
        if (target / extra.name).exists():
            raise SystemExit(f"{extra} would overwrite a model file of the same name")
        shutil.copy2(extra, target / extra.name)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--namespace", required=True, help="Hugging Face user or organisation")
    parser.add_argument("--models", required=True, type=pathlib.Path,
                        help="directory holding one built directory per model")
    arguments = parser.parse_args()

    from huggingface_hub import HfApi

    manifest = json.loads(MANIFEST.read_text())
    for model in manifest["models"]:
        check_against_manifest(model, arguments.models / model["directory"])

    api = HfApi()
    with tempfile.TemporaryDirectory(dir=arguments.models) as staging_directory:
        for model in manifest["models"]:
            repository = f"{arguments.namespace}/privacyflow-{model['directory']}"
            folder = stage(model, arguments.models / model["directory"], pathlib.Path(staging_directory))
            api.create_repo(repository, repo_type="model", exist_ok=True)
            commit = api.upload_folder(repo_id=repository, repo_type="model", folder_path=folder,
                                       commit_message="Publish for PrivacyFlow")
            revision = commit.oid
            for entry in model["files"]:
                entry["url"] = f"https://huggingface.co/{repository}/resolve/{revision}/{entry['path']}"
            print(f"{repository} at {revision}")

    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Pinned {MANIFEST.relative_to(ROOT)} to the published revisions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
