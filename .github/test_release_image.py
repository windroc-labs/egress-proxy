"""Exercise release_image.py on synthetic OCI layouts and a patched subprocess.run; no
Docker, registry or network."""

import base64
import contextlib
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import release_image

INDEX = "application/vnd.oci.image.index.v1+json"
MANIFEST = "application/vnd.oci.image.manifest.v1+json"
CONFIG = "application/vnd.oci.image.config.v1+json"
GZIP_LAYER = "application/vnd.oci.image.layer.v1.tar+gzip"

VERSION = "1.2.3"
REVISION = "0123456789abcdef0123456789abcdef01234567"
CONTRACT = "1"
# Assembled so this file holds no token-shaped literal.
TOKEN = "gh" + "s_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"


def labels(**override):
    result = {
        "org.opencontainers.image.version": VERSION,
        "org.opencontainers.image.revision": REVISION,
        "org.opencontainers.image.source": "https://github.com/windroc/egress-proxy",
        "io.windroc.egress-proxy.contract": CONTRACT,
    }
    result.update(override)
    return {k: v for k, v in result.items() if v is not None}


class Layout:
    """Writes an OCI image layout like `buildx --output type=oci,tar=false`."""

    def __init__(self, root):
        self.root = Path(root)
        (self.root / "blobs" / "sha256").mkdir(parents=True)

    def blob(self, data, media_type, **extra):
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        (self.root / "blobs" / "sha256" / digest[7:]).write_bytes(data)
        return {"mediaType": media_type, "digest": digest, "size": len(data), **extra}

    def layer(self, files, media_type=GZIP_LAYER):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w") as tar:
            for path, content in files.items():
                info = tarfile.TarInfo(path)
                info.size = len(content)
                tar.addfile(info, io.BytesIO(content))
        data = raw.getvalue()
        if media_type.endswith("+gzip"):
            data = gzip.compress(data, mtime=0)
        return self.blob(data, media_type)

    def image(self, platform, files, image_labels, history=None, media_type=GZIP_LAYER):
        os_name, arch = platform.split("/")
        config = {
            "architecture": arch,
            "os": os_name,
            "config": {"Labels": image_labels, "Env": ["PATH=/usr/bin"]},
            "history": history or [{"created_by": "COPY /proxy /proxy # buildkit"}],
            "rootfs": {"type": "layers", "diff_ids": []},
        }
        manifest = {
            "schemaVersion": 2,
            "mediaType": MANIFEST,
            "config": self.blob(json.dumps(config).encode(), CONFIG),
            "layers": [self.layer(files, media_type)],
        }
        return self.blob(json.dumps(manifest).encode(), MANIFEST,
                         platform={"architecture": arch, "os": os_name})

    def finish(self, manifests, annotations=None):
        index = {"schemaVersion": 2, "mediaType": INDEX, "manifests": manifests}
        if annotations:
            index["annotations"] = annotations
        top = self.blob(json.dumps(index).encode(), INDEX)
        (self.root / "index.json").write_text(json.dumps(
            {"schemaVersion": 2, "mediaType": INDEX, "manifests": [top]}))
        (self.root / "oci-layout").write_text('{"imageLayoutVersion": "1.0.0"}')
        return top["digest"]


GOOD_FILES = {"proxy": b"\x7fELF binary", "smokescreen": b"\x7fELF go", "etc/passwd": b"root:x:0:0"}


def build_layout(root, files=None, platforms=("linux/amd64", "linux/arm64"),
                 image_labels=None, history=None, annotations=None, media_type=GZIP_LAYER,
                 per_platform=None):
    layout = Layout(root)
    manifests = []
    for platform in platforms:
        f = dict(GOOD_FILES if files is None else files)
        if per_platform and platform in per_platform:
            f.update(per_platform[platform])
        manifests.append(layout.image(platform, f, labels() if image_labels is None else image_labels,
                                      history, media_type))
    return layout.finish(manifests, annotations)


def run_main(*argv, env=None):
    """release_image.main's exit code, stdout and stderr."""
    out, err = io.StringIO(), io.StringIO()
    environ = {k: v for k, v in os.environ.items() if k not in ("EGRESS_RELEASE_TOKEN", "GITHUB_ACTOR")}
    environ.update(env or {})
    with mock.patch.dict(os.environ, environ, clear=True), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = release_image.main(list(argv))
    return code, out.getvalue(), err.getvalue()


def completed(args, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(args, returncode, stdout, stderr)


class VersionTests(unittest.TestCase):
    def test_release_tag(self):
        self.assertEqual(run_main("version", "refs/tags/v1.2.3")[:2], (0, "1.2.3\n"))
        self.assertEqual(run_main("version", "refs/tags/v0.10.0")[:2], (0, "0.10.0\n"))

    def test_not_a_release_tag(self):
        for ref in ("refs/tags/v1.2", "refs/tags/v1.2.3-rc.1", "refs/tags/v01.2.3",
                    "refs/heads/v1.2.3", "refs/tags/1.2.3", "refs/tags/v1.2.3\n"):
            with self.subTest(ref=ref):
                code, out, err = run_main("version", ref)
                self.assertEqual(code, 1)
                self.assertEqual(out, "")
                self.assertIn(f"FAIL version: {ref} is not a release tag vX.Y.Z", err)


class ContractTests(unittest.TestCase):
    def compose(self, text):
        path = Path(self.enterContext(tempfile.TemporaryDirectory())) / "compose.yaml"
        path.write_text(text)
        return str(path)

    def test_repo_compose(self):
        self.assertEqual(run_main("contract")[:2], (0, "1\n"))

    def test_quoted_and_bare(self):
        for value in ('"2"', "2"):
            path = self.compose(f"services:\n  proxy:\n    labels:\n      windroc.egress.contract: {value}\n")
            self.assertEqual(run_main("contract", "--compose", path)[:2], (0, "2\n"))

    def test_missing_or_ambiguous(self):
        for text in ("services: {}\n",
                     "    windroc.egress.contract: \"1\"\n    windroc.egress.contract: \"2\"\n",
                     "    windroc.egress.contract: \"v1\"\n"):
            with self.subTest(text=text):
                code, _, err = run_main("contract", "--compose", self.compose(text))
                self.assertEqual(code, 1)
                self.assertIn("FAIL contract:", err)


class OnMainTests(unittest.TestCase):
    def check(self, returncode, stderr=b""):
        with mock.patch.object(subprocess, "run", return_value=completed([], returncode, b"", stderr)) as run:
            result = run_main("on-main", REVISION)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0],
                         ["git", "merge-base", "--is-ancestor", REVISION, "origin/main"])
        return result

    def test_ancestor(self):
        self.assertEqual(self.check(0)[0], 0)

    def test_not_on_main(self):
        code, _, err = self.check(1)
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL main: {REVISION} is not on main", err)

    def test_git_error(self):
        code, _, err = self.check(128, b"fatal: Not a valid object name origin/main")
        self.assertEqual(code, 1)
        self.assertIn("FAIL main: git merge-base exited 128: fatal: Not a valid object name origin/main", err)


class DigestTests(unittest.TestCase):
    def test_index_digest(self):
        root = self.enterContext(tempfile.TemporaryDirectory())
        digest = build_layout(root)
        self.assertEqual(run_main("digest", root)[:2], (0, digest + "\n"))


class CheckTests(unittest.TestCase):
    def layout(self, **kwargs):
        root = self.enterContext(tempfile.TemporaryDirectory())
        build_layout(root, **kwargs)
        return root

    def check(self, root, env=None):
        return run_main("check", root, "--version", VERSION, "--revision", REVISION,
                        "--contract", CONTRACT, env=env)

    def assert_fails(self, result, *fragments):
        code, _, err = result
        self.assertEqual(code, 1, err)
        self.assertTrue(err.startswith("FAIL check: "), err)
        for fragment in fragments:
            self.assertIn(fragment, err)
        return err

    def test_clean_layout(self):
        code, out, err = self.check(self.layout())
        self.assertEqual(code, 0, err)
        self.assertIn("ok check linux/amd64", out)
        self.assertIn("ok check linux/arm64", out)

    def test_clean_layout_uncompressed_layers(self):
        root = self.layout(media_type="application/vnd.oci.image.layer.v1.tar")
        self.assertEqual(self.check(root)[0], 0)

    def test_platforms(self):
        for platforms in (("linux/amd64",), ("linux/amd64", "linux/arm64", "unknown/unknown"),
                          ("linux/amd64", "linux/amd64", "linux/arm64")):
            with self.subTest(platforms=platforms):
                self.assert_fails(self.check(self.layout(platforms=platforms)),
                                  "platforms", "want linux/amd64, linux/arm64")

    def test_labels(self):
        cases = {
            "org.opencontainers.image.version": "1.2.4",
            "org.opencontainers.image.revision": "f" * 40,
            "io.windroc.egress-proxy.contract": "2",
            "org.opencontainers.image.source": None,
        }
        for key, value in cases.items():
            with self.subTest(key=key):
                self.assert_fails(self.check(self.layout(image_labels=labels(**{key: value}))), key)

    def test_forbidden_paths(self):
        for path in ("src/main.rs", "app/lib.rs", "Cargo.toml", "x/Cargo.lock", "rust-toolchain.toml",
                     "Dockerfile", ".git/config", "a/.github/ci.yml", "tests/run.sh", "target/x",
                     "root/.docker/config.json", "run/auth.json", "root/.git-credentials", "root/.netrc"):
            with self.subTest(path=path):
                err = self.assert_fails(self.check(self.layout(per_platform={"linux/arm64": {path: b"x"}})),
                                        "linux/arm64", path)
                self.assertNotIn("linux/amd64", err)

    def test_allowed_runtime_paths(self):
        files = dict(GOOD_FILES, **{"opt/egress/compose.yaml": b"x", "opt/egress/start.sh": b"x",
                                    "usr/share/doc/srcpkg/copyright": b"x"})
        self.assertEqual(self.check(self.layout(files=files))[0], 0)

    def test_token_in_layer_content(self):
        err = self.assert_fails(self.check(self.layout(files=dict(GOOD_FILES, **{"etc/x": b"t=" + TOKEN.encode()}))),
                                "etc/x", "credential")
        self.assertNotIn(TOKEN, err)

    def test_pat_in_layer_content(self):
        pat = "github" + "_pat_" + "A" * 30
        err = self.assert_fails(self.check(self.layout(files=dict(GOOD_FILES, **{"etc/x": pat.encode()}))), "etc/x")
        self.assertNotIn(pat, err)

    def test_token_in_history(self):
        err = self.assert_fails(self.check(self.layout(history=[{"created_by": f"RUN echo {TOKEN}"}])), "credential")
        self.assertNotIn(TOKEN, err)

    def test_source_path_in_history(self):
        for created_by in ("COPY proxy/src /src", "COPY Cargo.toml ./", "ADD .git /x", "COPY main.rs /"):
            with self.subTest(created_by=created_by):
                self.assert_fails(self.check(self.layout(history=[{"created_by": created_by}])), "history")

    def test_token_in_index_annotation(self):
        err = self.assert_fails(self.check(self.layout(annotations={"x": TOKEN})), "index", "credential")
        self.assertNotIn(TOKEN, err)

    def test_release_token_forms(self):
        secret = "opaque-secret-value-123"
        forms = {
            "raw": secret.encode(),
            "authfile": base64.b64encode(f"bot:{secret}".encode()),
            "x-access-token": base64.b64encode(f"x-access-token:{secret}".encode()),
        }
        env = {"EGRESS_RELEASE_TOKEN": secret, "GITHUB_ACTOR": "bot"}
        for name, content in forms.items():
            with self.subTest(form=name):
                root = self.layout(files=dict(GOOD_FILES, **{"etc/leak": b'{"auth":"' + content + b'"}'}))
                err = self.assert_fails(self.check(root, env), "etc/leak", "credential")
                self.assertNotIn(secret, err)
                self.assertNotIn(content.decode(), err)
        self.assertEqual(self.check(self.layout(), env)[0], 0)

    def test_corrupt_blob(self):
        root = self.layout()
        blobs = sorted((Path(root) / "blobs" / "sha256").iterdir(), key=lambda p: p.stat().st_size)
        blobs[-1].write_bytes(blobs[-1].read_bytes() + b"x")
        self.assert_fails(self.check(root), "digest mismatch")

    def test_unsupported_layer_media_type(self):
        root = self.layout(media_type="application/vnd.oci.image.layer.v1.tar+zstd")
        self.assert_fails(self.check(root), "unsupported layer media type")

    def test_not_a_layout(self):
        root = self.enterContext(tempfile.TemporaryDirectory())
        self.assert_fails(self.check(root), "index.json")


if __name__ == "__main__":
    unittest.main()
