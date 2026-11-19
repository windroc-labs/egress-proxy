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
import re
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import yaml

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
        "org.opencontainers.image.source": "https://github.com/windroc-labs/egress-proxy",
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


def single_layout(root, platform, top="manifest", image_labels=None, files=None, variant=None):
    """A one-platform layout like `buildx --platform=<platform> --output type=oci,tar=false`:
    index.json names the image manifest itself (`top="manifest"`) or an index of only it."""
    layout = Layout(root)
    descriptor = layout.image(platform, dict(GOOD_FILES if files is None else files),
                              labels() if image_labels is None else image_labels)
    if variant:
        manifest = json.loads((layout.root / "blobs" / "sha256" / descriptor["digest"][7:]).read_bytes())
        config_path = layout.root / "blobs" / "sha256" / manifest["config"]["digest"][7:]
        config = dict(json.loads(config_path.read_bytes()), variant=variant)
        manifest["config"] = layout.blob(json.dumps(config).encode(), CONFIG)
        descriptor = layout.blob(json.dumps(manifest).encode(), MANIFEST)
    descriptor.pop("platform", None)
    if top == "index":
        index = {"schemaVersion": 2, "mediaType": INDEX, "manifests": [descriptor]}
        descriptor = layout.blob(json.dumps(index).encode(), INDEX)
    (layout.root / "index.json").write_text(json.dumps({"schemaVersion": 2, "manifests": [descriptor]}))
    (layout.root / "oci-layout").write_text('{"imageLayoutVersion": "1.0.0"}')
    return descriptor


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


OLD = "f" * 40


class FakeGit:
    """Stands in for git behind subprocess.run: `tags` maps a tag to its commit, `ancestors`
    holds the commits that are ancestors of REVISION, `errors` maps a git subcommand to its
    (exit code, stderr)."""

    def __init__(self, tags=(), ancestors=(), errors=None):
        self.tags = dict(tags)
        self.ancestors = set(ancestors)
        self.errors = errors or {}
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append(list(args))
        if args[0] != "git":
            raise AssertionError(f"unexpected command {args}")
        if args[1] in self.errors:
            return completed(args, self.errors[args[1]][0], b"", self.errors[args[1]][1])
        if args[1:] == ["tag", "--list"]:
            return completed(args, 0, "".join(f"{tag}\n" for tag in self.tags).encode())
        if args[1] == "rev-parse":
            return completed(args, 0, self.tags[args[-1].removesuffix("^{commit}")].encode() + b"\n")
        if args[1:3] == ["merge-base", "--is-ancestor"]:
            return completed(args, 0 if args[3] in self.ancestors and args[4] == REVISION else 1)
        raise AssertionError(f"unexpected command {args}")


class NextVersionTests(unittest.TestCase):
    def next(self, git):
        with mock.patch.object(subprocess, "run", side_effect=git):
            return run_main("next-version", REVISION)

    def test_patch_bump_of_the_highest_release_tag(self):
        # Only vX.Y.Z counts, compared as numbers; v0.1.0 published nothing and still counts.
        git = FakeGit(tags={"v0.1.0": "a" * 40, "v0.1.10": OLD, "v0.1.9": "b" * 40, "v0.2.0-rc.1": "c" * 40,
                            "v01.0.0": "d" * 40, "v1.0": "e" * 40, "latest": "e" * 40},
                      ancestors={OLD})
        self.assertEqual(self.next(git)[:2], (0, "0.1.11\n"))
        self.assertIn(["git", "rev-parse", "--verify", "v0.1.10^{commit}"], git.calls)
        self.assertIn(["git", "merge-base", "--is-ancestor", OLD, REVISION], git.calls)

    def test_first_release(self):
        git = FakeGit(tags={"latest": OLD})
        self.assertEqual(self.next(git)[:2], (0, "0.1.0\n"))
        self.assertEqual(git.calls, [["git", "tag", "--list"]])

    def test_already_released(self):
        # A re-run after the Release: the commit already carries the highest version.
        code, out, err = self.next(FakeGit(tags={"v0.1.1": REVISION}))
        self.assertEqual((code, out), (1, ""))
        self.assertIn(f"FAIL version: {REVISION} is already released as v0.1.1", err)

    def test_older_than_the_last_release(self):
        # A late re-run of an older commit must not publish it under a newer version.
        code, out, err = self.next(FakeGit(tags={"v0.1.1": OLD}))
        self.assertEqual((code, out), (1, ""))
        self.assertIn(f"FAIL version: v0.1.1 ({OLD}) is not an ancestor of {REVISION}", err)

    def test_git_errors(self):
        for command, expected in (("tag", "git tag exited 128: fatal: boom"),
                                  ("rev-parse", "git rev-parse exited 128: fatal: boom"),
                                  ("merge-base", "git merge-base exited 128: fatal: boom")):
            with self.subTest(command=command):
                code, _, err = self.next(FakeGit(tags={"v0.1.1": OLD}, ancestors={OLD},
                                                 errors={command: (128, b"fatal: boom")}))
                self.assertEqual(code, 1)
                self.assertIn(f"FAIL version: {expected}", err)


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
                     "Dockerfile", ".git/config", "a/.git/HEAD", "a/.github/ci.yml", "tests/run.sh",
                     "./target/x", "/src/x",
                     "root/.docker/config.json", "run/auth.json", "root/.git-credentials", "root/.netrc"):
            with self.subTest(path=path):
                err = self.assert_fails(self.check(self.layout(per_platform={"linux/arm64": {path: b"x"}})),
                                        "linux/arm64", path)
                self.assertNotIn("linux/amd64", err)

    def test_allowed_runtime_paths(self):
        # usr/src: distroless ships it (empty); src, tests and target count only at the root.
        files = dict(GOOD_FILES, **{"opt/egress/compose.yaml": b"x", "opt/egress/start.sh": b"x",
                                    "usr/share/doc/srcpkg/copyright": b"x", "usr/src/": b"",
                                    "usr/lib/python3/tests/x": b"x", "usr/lib/target/x": b"x"})
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


class CombineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.out = self.tmp / "out"

    def single(self, name, platform, **kwargs):
        root = self.tmp / name
        single_layout(root, platform, **kwargs)
        return str(root)

    def combine(self, *roots):
        return run_main("combine", str(self.out), *roots)

    def test_combined_layout_passes_check(self):
        # buildx names the manifest itself or a one-entry index; combine takes both.
        amd = self.single("amd", "linux/amd64")
        arm = self.single("arm", "linux/arm64", top="index", variant="v8",
                          files=dict(GOOD_FILES, arch=b"arm64"))
        code, out, err = self.combine(amd, arm)
        self.assertEqual(code, 0, err)
        self.assertIn(f"ok combine {self.out}", out)
        index = json.loads(release_image.Layout(self.out).blob(release_image.Layout(self.out).index_descriptor()))
        self.assertEqual([m["platform"] for m in index["manifests"]],
                         [{"architecture": "amd64", "os": "linux"},
                          {"architecture": "arm64", "os": "linux", "variant": "v8"}])
        code, out, err = run_main("check", str(self.out), "--version", VERSION, "--revision", REVISION,
                                  "--contract", CONTRACT)
        self.assertEqual(code, 0, err)
        self.assertIn("ok check linux/arm64", out)
        # Only the referenced blobs: the arm64 layout's own one-entry index is not carried over.
        blobs = {p.name for p in (self.out / "blobs" / "sha256").iterdir()}
        self.assertEqual(len(blobs), 1 + 2 * 3)

    def test_order_does_not_matter(self):
        amd = self.single("amd", "linux/amd64")
        arm = self.single("arm", "linux/arm64")
        self.assertEqual(self.combine(arm, amd)[0], 0)
        digest = run_main("digest", str(self.out))[1]
        other = self.tmp / "other"
        self.assertEqual(run_main("combine", str(other), amd, arm)[0], 0)
        self.assertEqual(run_main("digest", str(other))[1], digest)

    def test_same_platform_twice(self):
        code, _, err = self.combine(self.single("a", "linux/amd64"), self.single("b", "linux/amd64"))
        self.assertEqual(code, 1)
        self.assertIn("FAIL combine:", err)
        self.assertIn("linux/amd64 twice", err)

    def test_more_than_one_image(self):
        root = self.tmp / "multi"
        build_layout(root)
        code, _, err = self.combine(str(root))
        self.assertEqual(code, 1)
        self.assertIn("FAIL combine:", err)
        self.assertIn("exactly one image", err)

    def test_corrupt_blob(self):
        amd = self.single("amd", "linux/amd64")
        blobs = sorted((Path(amd) / "blobs" / "sha256").iterdir(), key=lambda p: p.stat().st_size)
        blobs[-1].write_bytes(blobs[-1].read_bytes() + b"x")
        code, _, err = self.combine(amd)
        self.assertEqual(code, 1)
        self.assertIn("digest mismatch", err)

    def test_out_exists(self):
        self.out.mkdir()
        code, _, err = self.combine(self.single("amd", "linux/amd64"))
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL combine: {self.out} already exists", err)


REPO = "ghcr.io/windroc-labs/egress-proxy"
INDEX_RAW = b'{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
INDEX_DIGEST = "sha256:" + hashlib.sha256(INDEX_RAW).hexdigest()
NOT_FOUND = b"FATA[0001] Error parsing image name: reading manifest 1.2.3 in ghcr.io/windroc-labs/egress-proxy: manifest unknown"


class FakeTools:
    """Stands in for skopeo, gh and docker behind subprocess.run: `registry` maps
    `<repo>:<tag>` to raw index bytes, `configs` maps an arch to its image labels."""

    def __init__(self, registry=None, configs=None, copy_writes=None, inspect_error=None,
                 copy_rc=0, gh_view=(1, b"release not found"), gh_create_rc=0, tags=None, gh_api_error=None):
        self.registry = dict(registry or {})
        self.configs = configs or {"amd64": labels(), "arm64": labels()}
        self.copy_writes = copy_writes
        self.inspect_error = inspect_error
        self.copy_rc = copy_rc
        self.gh_view = gh_view
        self.gh_create_rc = gh_create_rc
        self.tags = dict(tags or {})
        self.gh_api_error = gh_api_error
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append(list(args))
        tool = args[0]
        if tool == "skopeo" and args[1] == "inspect":
            ref = args[-1].removeprefix("docker://")
            if self.inspect_error:
                return completed(args, 1, b"", self.inspect_error)
            if "--config" in args:
                arch = args[args.index("--override-arch") + 1]
                return completed(args, 0, json.dumps({"config": {"Labels": self.configs[arch]}}).encode())
            if ref not in self.registry:
                return completed(args, 1, b"", NOT_FOUND)
            return completed(args, 0, self.registry[ref])
        if tool == "skopeo" and args[1] == "copy":
            if self.copy_rc == 0:
                self.registry[args[-1].removeprefix("docker://")] = self.copy_writes
            return completed(args, self.copy_rc, b"", b"copy failed" if self.copy_rc else b"")
        if tool == "gh" and args[1:3] == ["release", "view"]:
            return completed(args, self.gh_view[0], b"", self.gh_view[1])
        if tool == "gh" and args[1] == "api":
            if self.gh_api_error:
                return completed(args, 1, b"", self.gh_api_error)
            if args[2:5] == ["--method", "POST", "repos/{owner}/{repo}/git/refs"]:
                tag, sha = args[6].removeprefix("ref=refs/tags/"), args[8].removeprefix("sha=")
                if tag in self.tags:
                    return completed(args, 1, b"", b"gh: Reference already exists (HTTP 422)")
                self.tags[tag] = sha
                return completed(args, 0, b"{}")
            tag = args[2].removeprefix("repos/{owner}/{repo}/git/ref/tags/")
            if tag in self.tags:
                return completed(args, 0, self.tags[tag].encode() + b"\n")
            return completed(args, 1, b"", b"gh: Not Found (HTTP 404)")
        if tool == "gh" and args[1:3] == ["release", "create"]:
            return completed(args, self.gh_create_rc, b"", b"" if self.gh_create_rc == 0 else b"HTTP 422")
        if tool == "docker":
            return completed(args, 0)
        raise AssertionError(f"unexpected command {args}")

    def ran(self, *prefix):
        return [c for c in self.calls if c[:len(prefix)] == list(prefix)]


def with_tools(tools, *argv, env=None):
    with mock.patch.object(subprocess, "run", side_effect=tools):
        return run_main(*argv, env=env)


class BuildTests(unittest.TestCase):
    def test_build_args(self):
        out_dir = Path(self.enterContext(tempfile.TemporaryDirectory())) / "layout"
        tools = FakeTools()
        code, _, err = with_tools(tools, "build", "--version", VERSION, "--revision", REVISION,
                                  "--contract", CONTRACT, "--platform", "linux/arm64", "--out", str(out_dir))
        self.assertEqual(code, 0, err)
        (args,) = tools.ran("docker", "buildx", "build")
        self.assertIn("--platform=linux/arm64", args)
        self.assertIn("--provenance=false", args)
        self.assertIn("--sbom=false", args)
        for key, value in labels().items():
            self.assertIn(f"--label={key}={value}", args)
        self.assertIn(f"--output=type=oci,dest={out_dir},tar=false", args)
        self.assertEqual(args[-1], str(release_image.REPO_ROOT))

    def test_out_exists(self):
        out_dir = self.enterContext(tempfile.TemporaryDirectory())
        tools = FakeTools()
        code, _, err = with_tools(tools, "build", "--version", VERSION, "--revision", REVISION,
                                  "--contract", CONTRACT, "--platform", "linux/amd64", "--out", out_dir)
        self.assertEqual(code, 1)
        self.assertIn("FAIL build:", err)
        self.assertEqual(tools.calls, [])

    def test_build_fails(self):
        out_dir = Path(self.enterContext(tempfile.TemporaryDirectory())) / "layout"
        with mock.patch.object(subprocess, "run", return_value=completed([], 1)):
            code, _, err = run_main("build", "--version", VERSION, "--revision", REVISION,
                                    "--contract", CONTRACT, "--platform", "linux/amd64", "--out", str(out_dir))
        self.assertEqual(code, 1)
        self.assertIn("FAIL build: docker buildx build exited 1", err)

    def test_one_release_platform(self):
        out_dir = Path(self.enterContext(tempfile.TemporaryDirectory())) / "layout"
        for platform in ("linux/amd64,linux/arm64", "linux/386"):
            with self.subTest(platform=platform), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as raised:
                run_main("build", "--version", VERSION, "--revision", REVISION, "--contract", CONTRACT,
                         "--platform", platform, "--out", str(out_dir))
            self.assertEqual(raised.exception.code, 2)


class RegistryAbsentTests(unittest.TestCase):
    def absent(self, tools):
        return with_tools(tools, "registry-absent", "--repo", REPO, "--version", VERSION,
                          "--authfile", "/tmp/auth.json")

    def test_absent(self):
        tools = FakeTools()
        code, out, err = self.absent(tools)
        self.assertEqual(code, 0, err)
        self.assertIn(f"ok registry {REPO}:{VERSION} does not exist yet", out)
        self.assertEqual(tools.calls, [["skopeo", "inspect", "--raw", "--authfile", "/tmp/auth.json",
                                        f"docker://{REPO}:{VERSION}"]])

    def test_not_found_wordings(self):
        for stderr in (b"manifest unknown", b"name unknown: repository name not known", b"404 Not Found"):
            with self.subTest(stderr=stderr):
                self.assertEqual(self.absent(FakeTools(inspect_error=stderr))[0], 0)

    def test_exists(self):
        code, _, err = self.absent(FakeTools(registry={f"{REPO}:{VERSION}": INDEX_RAW}))
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL registry: {REPO}:{VERSION} already exists ({INDEX_DIGEST})", err)

    def test_registry_error(self):
        code, _, err = self.absent(FakeTools(inspect_error=b"denied: permission_denied: read_package"))
        self.assertEqual(code, 1)
        self.assertIn("FAIL registry: skopeo inspect exited 1: denied: permission_denied: read_package", err)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.root = self.enterContext(tempfile.TemporaryDirectory())
        self.digest = build_layout(self.root)
        self.raw = (Path(self.root) / "blobs" / "sha256" / self.digest[7:]).read_bytes()

    def publish(self, tools, *extra):
        return with_tools(tools, "publish", self.root, "--repo", REPO, "--version", VERSION, *extra)

    def test_publish(self):
        tools = FakeTools(copy_writes=self.raw)
        code, out, err = self.publish(tools, "--authfile", "/tmp/auth.json")
        self.assertEqual(code, 0, err)
        self.assertIn(f"ok publish {REPO}:{VERSION} {self.digest}", out)
        (copy,) = tools.ran("skopeo", "copy")
        self.assertEqual(copy, ["skopeo", "copy", "--all", "--preserve-digests", "--authfile", "/tmp/auth.json",
                                f"oci:{self.root}", f"docker://{REPO}:{VERSION}"])
        inspects = tools.ran("skopeo", "inspect", "--raw")
        self.assertEqual(len(inspects), 2)
        self.assertLess(tools.calls.index(inspects[0]), tools.calls.index(copy))
        self.assertEqual(len(tools.ran("skopeo", "inspect", "--config")), 2)

    def test_insecure_local_registry(self):
        tools = FakeTools(copy_writes=self.raw)
        code, _, err = with_tools(tools, "publish", self.root, "--repo", "localhost:5000/egress-proxy",
                                  "--version", "0.0.0", "--insecure")
        self.assertEqual(code, 0, err)
        (copy,) = tools.ran("skopeo", "copy")
        self.assertIn("--dest-tls-verify=false", copy)
        for c in tools.ran("skopeo", "inspect"):
            self.assertIn("--tls-verify=false", c)

    def test_exists_with_other_content(self):
        tools = FakeTools(registry={f"{REPO}:{VERSION}": INDEX_RAW})
        code, _, err = self.publish(tools)
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL publish: {REPO}:{VERSION} already exists ({INDEX_DIGEST})", err)
        self.assertEqual(tools.ran("skopeo", "copy"), [])
        self.assertEqual(tools.ran("skopeo", "inspect", "--config"), [])

    def test_rerun_with_same_content(self):
        tools = FakeTools(registry={f"{REPO}:{VERSION}": self.raw})
        code, out, err = self.publish(tools)
        self.assertEqual(code, 0, err)
        self.assertIn(f"ok publish {REPO}:{VERSION} already holds {self.digest}", out)
        self.assertEqual(tools.ran("skopeo", "copy"), [])
        self.assertEqual(len(tools.ran("skopeo", "inspect", "--config")), 2)

    def test_registry_error_before_copy(self):
        tools = FakeTools(inspect_error=b"unauthorized: authentication required")
        code, _, err = self.publish(tools)
        self.assertEqual(code, 1)
        self.assertIn("FAIL publish: skopeo inspect exited 1: unauthorized", err)
        self.assertEqual(tools.ran("skopeo", "copy"), [])

    def test_copy_fails(self):
        tools = FakeTools(copy_rc=1)
        code, _, err = self.publish(tools)
        self.assertEqual(code, 1)
        self.assertIn("FAIL publish: skopeo copy exited 1: copy failed", err)

    def test_digest_mismatch(self):
        tools = FakeTools(copy_writes=INDEX_RAW)
        code, _, err = self.publish(tools)
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL publish: {REPO}:{VERSION} is {INDEX_DIGEST}, want {self.digest}", err)

    def test_registry_labels_differ(self):
        tools = FakeTools(copy_writes=self.raw,
                          configs={"amd64": labels(), "arm64": labels(**{"org.opencontainers.image.version": "9.9.9"})})
        code, _, err = self.publish(tools)
        self.assertEqual(code, 1)
        self.assertIn("FAIL publish:", err)
        self.assertIn("org.opencontainers.image.version", err)


class ReleaseTests(unittest.TestCase):
    def test_absent(self):
        tools = FakeTools()
        code, _, err = with_tools(tools, "release-absent", "--tag", "v1.2.3")
        self.assertEqual(code, 0, err)
        self.assertEqual(tools.calls, [["gh", "release", "view", "v1.2.3"]])

    def test_exists(self):
        code, _, err = with_tools(FakeTools(gh_view=(0, b"")), "release-absent", "--tag", "v1.2.3")
        self.assertEqual(code, 1)
        self.assertIn("FAIL release: v1.2.3 already exists", err)

    def test_gh_error(self):
        code, _, err = with_tools(FakeTools(gh_view=(1, b"HTTP 401: Bad credentials")),
                                  "release-absent", "--tag", "v1.2.3")
        self.assertEqual(code, 1)
        self.assertIn("FAIL release: gh release view exited 1: HTTP 401: Bad credentials", err)

    def create(self, tools):
        return with_tools(tools, "release-create", "--version", VERSION, "--contract", CONTRACT,
                          "--digest", INDEX_DIGEST, "--revision", REVISION, "--repo", REPO)

    def test_create(self):
        tools = FakeTools()
        code, out, err = self.create(tools)
        self.assertEqual(code, 0, err)
        # The tag is made here, at the built commit, before the Release that verifies it.
        self.assertEqual(tools.calls[0], ["gh", "api", "--method", "POST", "repos/{owner}/{repo}/git/refs",
                                          "-f", "ref=refs/tags/v1.2.3", "-f", f"sha={REVISION}"])
        self.assertEqual(tools.tags, {"v1.2.3": REVISION})
        self.assertIn(f"ok tag v1.2.3 {REVISION}", out)
        (args,) = tools.ran("gh", "release", "create")
        self.assertEqual(args[:8], ["gh", "release", "create", "v1.2.3", "--verify-tag", "--title", "v1.2.3", "--notes"])
        notes = args[8]
        for fragment in (f"`{VERSION}`", f"`{CONTRACT}`", f"`{REPO}:{VERSION}`", INDEX_DIGEST,
                         f"docker pull {REPO}@{INDEX_DIGEST}", "`linux/amd64`", "`linux/arm64`", REVISION):
            self.assertIn(fragment, notes)

    def test_create_fails(self):
        code, _, err = self.create(FakeTools(gh_create_rc=1))
        self.assertEqual(code, 1)
        self.assertIn("FAIL release: gh release create exited 1: HTTP 422", err)

    def test_rerun_with_tag_at_the_commit(self):
        # "Re-run failed jobs" after the tag was made but the Release was not.
        tools = FakeTools(tags={"v1.2.3": REVISION})
        code, out, err = self.create(tools)
        self.assertEqual(code, 0, err)
        self.assertIn(f"ok tag v1.2.3 already at {REVISION}", out)
        self.assertEqual(len(tools.ran("gh", "release", "create")), 1)

    def test_tag_at_another_commit(self):
        tools = FakeTools(tags={"v1.2.3": OLD})
        code, _, err = self.create(tools)
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL release: tag v1.2.3 exists at {OLD}, want {REVISION}", err)
        self.assertEqual(tools.ran("gh", "release", "create"), [])

    def test_tag_api_error(self):
        tools = FakeTools(gh_api_error=b"gh: Resource not accessible by integration (HTTP 403)")
        code, _, err = self.create(tools)
        self.assertEqual(code, 1)
        self.assertIn("FAIL release: cannot create tag v1.2.3: gh: Resource not accessible by integration (HTTP 403)", err)
        self.assertEqual(tools.ran("gh", "release", "create"), [])


GITHUB = Path(__file__).parent


def load(path):
    data = yaml.safe_load((GITHUB / path).read_text())
    # YAML 1.1 reads the key `on` as True.
    data["on"] = data.pop(True, data.get("on"))
    return data


def step_env(step):
    return step.get("env") or {}


NATIVE = [{"arch": "amd64", "runner": "ubuntu-24.04"}, {"arch": "arm64", "runner": "ubuntu-24.04-arm"}]


def assert_native_matrix(test, job):
    """Each platform built in parallel on a runner of its own architecture."""
    test.assertEqual(job["strategy"]["matrix"], {"include": NATIVE})
    test.assertEqual(job["runs-on"], "${{ matrix.runner }}")
    test.assertEqual(job["permissions"], {"contents": "read"})
    (build,) = (s for s in job["steps"] if s.get("uses") == "./.github/actions/build-image")
    test.assertEqual(build["with"]["platform"], "linux/${{ matrix.arch }}")
    (upload,) = (s for s in job["steps"] if s.get("uses", "").startswith("actions/upload-artifact@"))
    return build, upload


def combine_step(test, job, prefix):
    """The step that combines both platforms' artifacts `<prefix><arch>` and checks the result."""
    (download,) = (s for s in job["steps"] if s.get("uses", "").startswith("actions/download-artifact@"))
    test.assertEqual(download["with"]["pattern"], prefix + "*")
    (step,) = (s for s in job["steps"] if "release_image.py combine" in s.get("run", ""))
    run = step["run"]
    for arch in ("amd64", "arm64"):
        test.assertIn(f'"$RUNNER_TEMP/layouts/{prefix}{arch}"', run)
    test.assertLess(run.index("release_image.py combine"), run.index("release_image.py check"))
    test.assertIn("EGRESS_RELEASE_TOKEN", step_env(step))
    return step


class WorkflowTests(unittest.TestCase):
    def test_ci_is_callable_with_image_job(self):
        ci = load("workflows/ci.yml")
        self.assertIn("workflow_call", ci["on"])
        self.assertIn("image", ci["jobs"]["ci"]["needs"])
        self.assertIn("image-build", ci["jobs"]["ci"]["needs"])
        build, upload = assert_native_matrix(self, ci["jobs"]["image-build"])
        self.assertEqual(build["with"]["version"], "0.0.0")
        # Distinct from release.yml's `layout-<arch>`: a release run holds both.
        self.assertEqual(upload["with"]["name"], "ci-layout-${{ matrix.arch }}")
        image = ci["jobs"]["image"]
        self.assertEqual(image["needs"], "image-build")
        self.assertEqual(image["permissions"], {"contents": "read"})
        self.assertRegex(image["services"]["registry"]["image"], r"@sha256:[0-9a-f]{64}$")
        combine_step(self, image, "ci-layout-")
        publish = [s for s in image["steps"] if "release_image.py publish" in s.get("run", "")]
        self.assertEqual(len(publish), 1)
        self.assertIn("--repo localhost:5000/egress-proxy", publish[0]["run"])
        self.assertIn("--insecure", publish[0]["run"])

    def test_lint_runs_every_github_test(self):
        lint = load("workflows/ci.yml")["jobs"]["lint"]
        self.assertTrue(any("-p 'test_*.py'" in s.get("run", "") for s in lint["steps"]))

    def test_build_image_action(self):
        action = load("actions/build-image/action.yml")
        self.assertEqual(action["runs"]["using"], "composite")
        self.assertEqual(set(action["inputs"]), {"version", "revision", "platform", "out"})
        steps = action["runs"]["steps"]
        # Native runners: no QEMU.
        uses = [s["uses"].split("@")[0] for s in steps if "uses" in s]
        self.assertEqual(uses, ["docker/setup-buildx-action"])
        (buildx,) = (s for s in steps if "uses" in s)
        self.assertRegex(buildx["with"]["driver-opts"], r"@sha256:[0-9a-f]{64}$")
        self.assertRegex(buildx["with"]["version"], r"^v\d+\.\d+\.\d+$")
        (build,) = (s for s in steps if "release_image.py build" in s.get("run", ""))
        self.assertIn('--platform "$PLATFORM"', build["run"])
        self.assertFalse(any("EGRESS_RELEASE_TOKEN" in step_env(s) for s in steps))


def runs(job):
    return [s.get("run", "") for s in job["steps"]]


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.wf = load("workflows/release.yml")
        self.jobs = self.wf["jobs"]

    def test_release_gated_on_ci(self):
        self.assertEqual(set(self.wf["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(self.wf["on"]["push"]["branches"], ["main"])
        self.assertEqual(self.wf["permissions"], {"contents": "read"})
        # One release at a time, in push order, never cancelled mid-publish.
        self.assertEqual(self.wf["concurrency"], {"group": "release", "cancel-in-progress": False})
        self.assertEqual(self.jobs["checks"]["uses"], "./.github/workflows/ci.yml")
        self.assertEqual(self.jobs["prepare"]["needs"], "checks")
        self.assertEqual(self.jobs["build"]["needs"], "prepare")
        build, upload = assert_native_matrix(self, self.jobs["build"])
        self.assertEqual(upload["with"]["name"], "layout-${{ matrix.arch }}")
        self.assertEqual(sorted(self.jobs["publish"]["needs"]), ["build", "prepare"])
        # No `if`: each job runs only when every job it needs succeeded.
        for name in ("prepare", "build", "publish"):
            self.assertNotIn("if", self.jobs[name], name)
        self.assertEqual(set(self.jobs), {"checks", "prepare", "build", "publish"})

    def test_prepare_guards(self):
        prepare = self.jobs["prepare"]
        self.assertEqual(prepare["permissions"], {"contents": "read", "packages": "read"})
        self.assertEqual(prepare["steps"][0]["with"]["fetch-depth"], 0)
        script = "\n".join(runs(prepare))
        for command in ("release_image.py next-version", "release_image.py on-main", "release_image.py contract",
                        "release_image.py release-absent", "release_image.py registry-absent"):
            self.assertIn(command, script)
        self.assertEqual({s["uses"].split("@")[0] for s in prepare["steps"] if "uses" in s}, {"actions/checkout"})

    def test_release_only_when_the_image_changes(self):
        """The push paths are the image's build context, read from .dockerignore (whose
        `!` lines are all it lets in), plus .dockerignore itself; tests under proxy/ are in
        the context but not in the binary, so they never release on their own."""
        allowed = [line[1:] for line in (GITHUB.parent / ".dockerignore").read_text().splitlines()
                   if line.startswith("!")]
        self.assertIn("Dockerfile", allowed)
        want = [".dockerignore"] + [p + "**" if p.endswith("/") else p for p in allowed] + ["!proxy/tests/**"]
        self.assertEqual(self.wf["on"]["push"]["paths"], want)

    def test_ci_concurrency_apart_from_release(self):
        # Called by release.yml, github.workflow is "release": ci.yml's own run on the same
        # push to main must not cancel the release's checks.
        group = load("workflows/ci.yml")["concurrency"]["group"]
        self.assertIn("${{ github.workflow }}", group)
        self.assertIn("${{ github.ref }}", group)

    def test_publish_steps_unconditional(self):
        for step in self.jobs["publish"]["steps"][:-1]:
            self.assertNotIn("if", step, step)
        names = [s["uses"].split("@")[0] if "uses" in s else re.search(r"release_image\.py (\S+)", s["run"]).group(1)
                 for s in self.jobs["publish"]["steps"][1:-1]]
        self.assertEqual(names, ["actions/download-artifact", "combine", "publish", "release-create"])
        combine_step(self, self.jobs["publish"], "layout-")

    def test_write_job_trust(self):
        publish = self.jobs["publish"]
        self.assertEqual(publish["permissions"], {"contents": "write", "packages": "write"})
        self.assertEqual({s["uses"].split("@")[0] for s in publish["steps"] if "uses" in s},
                         {"actions/checkout", "actions/download-artifact"})
        self.assertFalse(any("pip" in r for r in runs(publish)))
        with_token = [s for s in publish["steps"] if "EGRESS_RELEASE_TOKEN" in step_env(s)]
        self.assertEqual(len(with_token), 1)
        self.assertIn("release_image.py check", with_token[0]["run"])

    def test_credential_scope(self):
        for name, job in self.jobs.items():
            for step in job.get("steps", []):
                run = step.get("run", "")
                if "skopeo login" in run:
                    self.assertIn(name, ("prepare", "publish"))
                    self.assertLess(run.index("trap 'rm -f \"$auth\"' EXIT"), run.index("skopeo login"), name)
                    self.assertIn("--password-stdin", run)
        cleanup = [s for s in self.jobs["publish"]["steps"] if s.get("if") == "always()"]
        self.assertEqual(len(cleanup), 1)
        self.assertIn("rm -f", cleanup[0]["run"])


if __name__ == "__main__":
    unittest.main()
