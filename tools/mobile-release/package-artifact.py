#!/usr/bin/env python3

"""Create a deterministic nodejs-mobile release archive with provenance."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import zipfile


FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
RESERVED_NAMES = {"runtime-manifest.json", "SHA256SUMS"}


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def zip_info(name, mode):
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | mode) << 16
    return info


def add_path(archive, path, name):
    executable = bool(path.stat().st_mode & 0o111)
    with path.open("rb") as source, archive.open(
        zip_info(name, 0o755 if executable else 0o644), "w"
    ) as target:
        shutil.copyfileobj(source, target, length=1024 * 1024)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target", required=True, choices=("android", "ios"))
    parser.add_argument("--flavor", required=True, choices=("full", "lite"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--upstream-ref", required=True)
    parser.add_argument("--upstream-commit", required=True)
    parser.add_argument("--build-run-id", required=True)
    parser.add_argument("--android-ndk-revision")
    parser.add_argument("--android-api")
    return parser.parse_args()


def main():
    args = parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if not source.is_dir():
        raise SystemExit(f"artifact directory does not exist: {source}")
    if output.suffix != ".zip":
        raise SystemExit("output must use the .zip extension")
    if args.target == "android" and (
        not args.android_ndk_revision or not args.android_api
    ):
        raise SystemExit("Android packages require NDK revision and API level")

    paths = sorted(
        (path for path in source.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(source).as_posix(),
    )
    if not paths:
        raise SystemExit(f"artifact directory is empty: {source}")
    collisions = [
        path.relative_to(source).as_posix()
        for path in paths
        if path.relative_to(source).as_posix() in RESERVED_NAMES
    ]
    if collisions:
        raise SystemExit(
            "artifact uses reserved release metadata path(s): "
            + ", ".join(collisions)
        )

    files = []
    for path in paths:
        files.append(
            {
                "path": path.relative_to(source).as_posix(),
                "sha256": sha256_file(path),
                "size": path.stat().st_size,
            }
        )

    manifest = {
        "schemaVersion": 1,
        "release": {"version": args.version},
        "artifact": {"target": args.target, "flavor": args.flavor},
        "source": {
            "repository": args.repository,
            "commit": args.source_commit,
            "upstream": {
                "ref": args.upstream_ref,
                "commit": args.upstream_commit,
            },
        },
        "build": {
            "workflow": ".github/workflows/build-mobile.yml",
            "runId": args.build_run_id,
            "url": (
                f"https://github.com/{args.repository}/actions/runs/"
                f"{args.build_run_id}"
            ),
        },
        "files": files,
    }
    if args.target == "android":
        manifest["toolchain"] = {
            "androidNdkRevision": args.android_ndk_revision,
            "minimumApi": int(args.android_api),
        }

    manifest_bytes = (
        json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    checksums = "".join(
        f"{entry['sha256']}  {entry['path']}\n" for entry in files
    )
    checksums += f"{manifest_hash}  runtime-manifest.json\n"

    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for path in paths:
            add_path(archive, path, path.relative_to(source).as_posix())
        archive.writestr(zip_info("runtime-manifest.json", 0o644), manifest_bytes)
        archive.writestr(
            zip_info("SHA256SUMS", 0o644), checksums.encode("utf-8")
        )

    print(f"packed {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
