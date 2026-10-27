"""Release steps for the egress-proxy image (release.yml and ci.yml's `image` job): the tag's
version, the label contract version, and the checks of the built OCI image layout (the
image labels and NFR-5: no source, tests or credential in anything published).

Stdlib only: it runs in the release job that holds write permissions, which installs
nothing. Each subcommand prints `ok <step> ...` lines, or `FAIL <step>: <detail>` on stderr
and exits 1; usage errors exit 2. External tools run through subprocess.run.
"""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE = "https://github.com/windroc/egress-proxy"
PLATFORMS = ("linux/amd64", "linux/arm64")

INDEX_TYPES = {"application/vnd.oci.image.index.v1+json",
               "application/vnd.docker.distribution.manifest.list.v2+json"}
LAYER_MODES = {
    "application/vnd.oci.image.layer.v1.tar": "r:",
    "application/vnd.oci.image.layer.v1.tar+gzip": "r:gz",
    "application/vnd.docker.image.rootfs.diff.tar.gzip": "r:gz",
}

# NFR-5: what must never be in a published image. Runtime files (compose, start.sh) are
# allowed; this repo's source, tests, build output and VCS, and credential files, are not.
FORBIDDEN_NAMES = {"Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "Dockerfile",
                   "auth.json", ".git-credentials", ".netrc"}
FORBIDDEN_DIRS = {".git", ".github", "src", "tests", "target"}
TOKEN_RE = re.compile(rb"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}")
VERSION_RE = re.compile(r"refs/tags/v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))")
CONTRACT_RE = re.compile(r'^\s+windroc\.egress\.contract:\s*"?(\d+)"?\s*$', re.MULTILINE)


class Fail(Exception):
    def __init__(self, step, detail):
        super().__init__(f"FAIL {step}: {detail}")


def run(args, stdin=None):
    """The tool's CompletedProcess, output as bytes; never raises on a non-zero exit."""
    return subprocess.run(args, input=stdin, capture_output=True, check=False)


def stderr_text(result):
    return result.stderr.decode(errors="replace").strip()


def image_labels(version, revision, contract):
    return {
        "org.opencontainers.image.version": version,
        "org.opencontainers.image.revision": revision,
        "org.opencontainers.image.source": SOURCE,
        "io.windroc.egress-proxy.contract": contract,
    }


def forbidden_path(path):
    """Why `path` must not be published, or None."""
    parts = [p for p in path.split("/") if p not in ("", ".")]
    if not parts:
        return None
    if parts[-1].endswith(".rs"):
        return "source file"
    if parts[-1] in FORBIDDEN_NAMES or parts[-2:] == [".docker", "config.json"]:
        return "forbidden file"
    if FORBIDDEN_DIRS.intersection(parts):
        return "forbidden directory"
    return None


def secret_forms():
    """The byte strings of the job token (EGRESS_RELEASE_TOKEN) that must not be published:
    the token and the base64 user:token forms a registry authfile stores."""
    token = os.environ.get("EGRESS_RELEASE_TOKEN", "")
    if not token:
        return []
    users = {os.environ.get("GITHUB_ACTOR", ""), "x-access-token"} - {""}
    return [token.encode()] + [base64.b64encode(f"{u}:{token}".encode()) for u in sorted(users)]


def has_credential(data, secrets):
    return bool(TOKEN_RE.search(data)) or any(s in data for s in secrets)


class Layout:
    """An OCI image layout directory; every blob read is checked against its digest."""

    def __init__(self, root):
        self.root = Path(root)

    def blob(self, descriptor):
        digest = descriptor.get("digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise Fail("check", f"bad digest {digest!r}")
        try:
            data = (self.root / "blobs" / "sha256" / digest[7:]).read_bytes()
        except OSError as error:
            raise Fail("check", f"blob {digest}: {error.strerror}") from None
        if "sha256:" + hashlib.sha256(data).hexdigest() != digest:
            raise Fail("check", f"blob {digest}: digest mismatch")
        return data

    def index_descriptor(self):
        try:
            top = json.loads((self.root / "index.json").read_text())
        except (OSError, ValueError) as error:
            raise Fail("check", f"cannot read {self.root}/index.json: {error}") from None
        manifests = top.get("manifests", [])
        if len(manifests) != 1 or manifests[0].get("mediaType") not in INDEX_TYPES:
            raise Fail("check", f"{self.root}/index.json must hold exactly one image index")
        return manifests[0]


def platform_of(descriptor):
    platform = descriptor.get("platform", {})
    return f"{platform.get('os', 'unknown')}/{platform.get('architecture', 'unknown')}"


def check_layer(layout, platform, descriptor, secrets):
    """Checks every file of one layer; returns the number of entries."""
    mode = LAYER_MODES.get(descriptor.get("mediaType"))
    where = f"{platform} {descriptor.get('digest')}"
    if mode is None:
        raise Fail("check", f"{where}: unsupported layer media type {descriptor.get('mediaType')}")
    data = layout.blob(descriptor)
    count = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tar:
            for member in tar:
                count += 1
                reason = forbidden_path(member.name)
                if reason:
                    raise Fail("check", f"{where}: {reason} {member.name}")
                if has_credential(member.name.encode(), secrets):
                    raise Fail("check", f"{where}: credential in a file name")
                if member.isfile():
                    content = tar.extractfile(member).read()
                    if has_credential(content, secrets):
                        raise Fail("check", f"{where}: credential in {member.name}")
    except (tarfile.TarError, OSError, EOFError) as error:
        raise Fail("check", f"{where}: unreadable layer: {error}") from None
    return count


def check_history(platform, digest, config):
    for entry in config.get("history", []):
        for word in re.findall(r"[^\s\"'=:,;()\[\]{}]+", entry.get("created_by", "")):
            if forbidden_path(word):
                raise Fail("check", f"{platform} {digest}: history names a source path {word}")


def check_layout(root, version, revision, contract):
    """Checks the layout at `root`; returns the lines to print. Raises Fail."""
    layout = Layout(root)
    secrets = secret_forms()
    top = layout.index_descriptor()
    index_bytes = layout.blob(top)
    if has_credential(index_bytes, secrets):
        raise Fail("check", f"index {top['digest']}: credential in the index")
    index = json.loads(index_bytes)
    manifests = index.get("manifests", [])
    found = sorted(platform_of(m) for m in manifests)
    if found != sorted(PLATFORMS):
        raise Fail("check", f"index {top['digest']}: platforms {', '.join(found) or 'none'}, "
                            f"want {', '.join(PLATFORMS)}")
    want = image_labels(version, revision, contract)
    lines = []
    for descriptor in manifests:
        platform = platform_of(descriptor)
        manifest_bytes = layout.blob(descriptor)
        if has_credential(manifest_bytes, secrets):
            raise Fail("check", f"{platform} {descriptor['digest']}: credential in the manifest")
        manifest = json.loads(manifest_bytes)
        config_bytes = layout.blob(manifest["config"])
        if has_credential(config_bytes, secrets):
            raise Fail("check", f"{platform} {manifest['config']['digest']}: credential in the image config")
        config = json.loads(config_bytes)
        check_history(platform, manifest["config"]["digest"], config)
        have = (config.get("config") or {}).get("Labels") or {}
        for key, value in want.items():
            if have.get(key) != value:
                raise Fail("check", f"{platform} {manifest['config']['digest']}: label {key} is "
                                    f"{have.get(key)!r}, want {value!r}")
        entries = sum(check_layer(layout, platform, layer, secrets) for layer in manifest.get("layers", []))
        lines.append(f"ok check {platform} {descriptor['digest']}: "
                     f"{len(manifest.get('layers', []))} layers, {entries} entries, labels match")
    lines.append(f"ok check index {top['digest']}")
    return lines


def cmd_version(args):
    match = VERSION_RE.fullmatch(args.ref)
    if not match:
        raise Fail("version", f"{args.ref} is not a release tag vX.Y.Z")
    print(match.group(1))


def cmd_contract(args):
    try:
        text = Path(args.compose).read_text()
    except OSError as error:
        raise Fail("contract", f"cannot read {args.compose}: {error.strerror}") from None
    found = CONTRACT_RE.findall(text)
    if len(found) != 1:
        raise Fail("contract", f"{args.compose}: want exactly one windroc.egress.contract label "
                               f"with a numeric value, found {len(found)}")
    print(found[0])


def cmd_on_main(args):
    result = run(["git", "merge-base", "--is-ancestor", args.commit, "origin/main"])
    if result.returncode == 1:
        raise Fail("main", f"{args.commit} is not on main")
    if result.returncode != 0:
        raise Fail("main", f"git merge-base exited {result.returncode}: {stderr_text(result)}")
    print(f"ok main {args.commit}")


def cmd_digest(args):
    print(Layout(args.layout).index_descriptor()["digest"])


def cmd_check(args):
    for line in check_layout(args.layout, args.version, args.revision, args.contract):
        print(line)


def parser():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("version", help="print X.Y.Z of a refs/tags/vX.Y.Z ref")
    s.add_argument("ref")
    s.set_defaults(func=cmd_version)

    s = sub.add_parser("contract", help="print the label contract version from compose.yaml")
    s.add_argument("--compose", default=str(REPO_ROOT / "compose.yaml"))
    s.set_defaults(func=cmd_contract)

    s = sub.add_parser("on-main", help="fail unless the commit is on origin/main")
    s.add_argument("commit")
    s.set_defaults(func=cmd_on_main)

    s = sub.add_parser("digest", help="print the layout's index digest")
    s.add_argument("layout")
    s.set_defaults(func=cmd_digest)

    s = sub.add_parser("check", help="check the layout's platforms, labels and contents")
    s.add_argument("layout")
    for flag in ("--version", "--revision", "--contract"):
        s.add_argument(flag, required=True)
    s.set_defaults(func=cmd_check)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except Fail as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
