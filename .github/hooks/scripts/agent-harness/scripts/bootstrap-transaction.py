#!/usr/bin/env python3
"""Bootstrap preflight, private staging, and gap-free directory publication.

The hooks directory (or its first absent ancestor) is the atomic publication
unit. Existing AGENTS is never edited; an absent seed is separately linked
before publication and removed on publication failure. This is not a
multi-path filesystem transaction or a native Beads transaction. Bootstrap
instances share an advisory directory lock; unrelated editors must be idle.
"""
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


class BootstrapError(Exception):
    pass


MARKER = "agent-harness bundle v1\n"
# Keep byte-identical to templates/AGENTS.md and the scaffold in
# .apm/skills/init/SKILL.md. tests/test_hooks.py::IdentityScaffoldTests enforces it.
SEED = """<!-- PROJECT-OWNED:BEGIN -->
<!-- Project identity, purpose, domain constraints, and local preferences.
     This region belongs to the consuming project, not agent-harness. -->
<!-- PROJECT-OWNED:END -->

<!-- HARNESS-OWNED:BEGIN -->
Shared procedures are the agent-harness instruction files in `.github/instructions/`.
<!-- HARNESS-OWNED:END -->
"""
DESCRIPTOR = {
    "version": 1,
    "hooks": {
        event: [{
            "type": "command",
            "bash": f'bash ".github/hooks/scripts/agent-harness/session-{name}.sh"',
            "cwd": ".",
            "timeoutSec": timeout,
        }]
        for event, name, timeout in (("sessionStart", "start", 15), ("sessionEnd", "end", 30))
    },
}
REQUIRED = (
    "session-start.sh", "session-end.sh", "scripts/bootstrap-project.sh",
    "scripts/bootstrap-transaction.py", "scripts/consumer-common.sh",
    "scripts/bd.sh", "scripts/beads-common.sh", "scripts/beads-server.sh",
    "scripts/handoff-common.sh", "scripts/session-handoff.sh",
    "scripts/install-git-hooks.sh", "scripts/git-hooks/prepare-commit-msg-session-id.sh",
    "scripts/setup-labels.sh", "scripts/update-dashboard.sh", "scripts/dashboard-edit.py",
)


def exists(path):
    return os.path.lexists(path)


def require_kind(path, directory=False):
    if not exists(path):
        return
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        raise BootstrapError(f"refusing to deploy through symlink: {path}")
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(mode):
        kind = "directory" if directory else "regular file"
        raise BootstrapError(f"destination/source collision: expected {kind}: {path}")


def fingerprint(path, reject_links=False):
    """Read-only witness including names, modes, identity, and file contents."""
    if not exists(path):
        return None
    result = {}

    def visit(entry):
        info = entry.lstat()
        mode = info.st_mode
        witness = (mode, info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns)
        if stat.S_ISLNK(mode):
            if reject_links:
                raise BootstrapError(f"refusing to deploy through symlink: {entry}")
            value = os.readlink(entry)
        elif stat.S_ISDIR(mode):
            value = None
            for child in sorted(entry.iterdir()):
                visit(child)
        elif stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with entry.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            value = digest.digest()
        else:
            raise BootstrapError(f"unsupported filesystem object: {entry}")
        result[str(entry.relative_to(path))] = witness, value

    visit(path)
    return result


def directory_identity(path):
    if not exists(path):
        return None
    require_kind(path, directory=True)
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_mode


def descriptor_owned(path):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(), object_pairs_hook=unique_object)
        commands = [value["hooks"][event][0]["bash"] for event in ("sessionStart", "sessionEnd")]
    except (ValueError, KeyError, IndexError, TypeError) as error:
        raise BootstrapError(f"existing descriptor is not owned by this bootstrap: {path}: {error}") from error
    for prefix in ("bash ", ""):
        if commands == [
            f'{prefix}".github/hooks/scripts/agent-harness/session-{name}.sh"'
            for name in ("start", "end")
        ]:
            return
    raise BootstrapError(f"existing descriptor is not owned by this bootstrap; left unchanged: {path}")


class AtomicDirectories:
    """One kernel operation, never rename-old/rename-new with a missing-path gap."""
    def __init__(self):
        self.libc = ctypes.CDLL(None, use_errno=True)
        if sys.platform == "darwin" and hasattr(self.libc, "renamex_np"):
            self.function = self.libc.renamex_np
            self.function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            self.platform = "darwin"
        elif sys.platform.startswith("linux") and hasattr(self.libc, "renameat2"):
            self.function = self.libc.renameat2
            self.function.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint,
            ]
            self.platform = "linux"
        else:
            raise BootstrapError("atomic directory publication requires macOS renamex_np or Linux renameat2; no unsafe fallback")
        self.function.restype = ctypes.c_int

    def publish(self, staged, destination, replace):
        source = os.fsencode(staged)
        target = os.fsencode(destination)
        if self.platform == "darwin":
            status = self.function(source, target, 2 if replace else 4)  # SWAP / EXCL
        else:
            status = self.function(-100, source, -100, target, 2 if replace else 1)
        if status != 0:
            code = ctypes.get_errno()
            raise OSError(code, f"atomic directory publication failed (no fallback): {os.strerror(code)}", str(destination))


@contextlib.contextmanager
def publication_signals():
    # Record successful publication before delivering pending cancellation.
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


@contextlib.contextmanager
def consumer_lock(target):
    # Lock the existing directory inode: no lock-file writes during preflight.
    descriptor = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BootstrapError("another bootstrap holds the consumer directory lock") from error
        yield
    finally:
        os.close(descriptor)


def bundle_ignore(directory, names):
    return [name for name in names if name.endswith((".json", ".pyc")) or
            name in ("__pycache__", ".agent-harness-bundle")]


def preflight(bundle, target, force, init_beads, skip_agents, environment):
    require_kind(bundle, directory=True)
    if not bundle.is_dir():
        raise BootstrapError(f"source bundle is absent: {bundle}")
    source_state = fingerprint(bundle, reject_links=True)
    for name in REQUIRED:
        path = bundle / name
        require_kind(path)
        if not path.is_file():
            raise BootstrapError(f"required runtime asset is absent: {path}")

    github = target / ".github"
    hooks = github / "hooks"
    scripts = hooks / "scripts"
    destination = scripts / "agent-harness"
    descriptor = hooks / "agent-harness-hooks.json"
    agents = target / "AGENTS.md"
    ancestors = {path: directory_identity(path) for path in (target, github, hooks, scripts, destination)}
    # Validate every destination even for repeat/self-invocation without copy.
    if exists(destination):
        fingerprint(destination, reject_links=True)
        if bundle != destination:
            marker = destination / ".agent-harness-bundle"
            require_kind(marker)
            if not marker.is_file() or marker.read_bytes() != MARKER.encode():
                raise BootstrapError(f"bundle exists and is not a marked harness bundle: {destination}")
            if not force:
                for name in REQUIRED:
                    if not (destination / name).is_file():
                        raise BootstrapError(f"installed bundle is incomplete; use --force to refresh: {destination / name}")
    require_kind(descriptor)
    if exists(descriptor):
        descriptor_owned(descriptor)
    require_kind(agents)
    # A known source path must not replace a directory with a file or vice versa.
    for source in bundle.rglob("*"):
        relative = source.relative_to(bundle)
        require_kind(destination / relative, directory=source.is_dir())

    store = target / ".beads"
    need_init = False
    native_bd = None
    if init_beads:
        require_kind(store, directory=True)
        overrides = sorted(key for key in environment if
                           key in ("BEADS_DIR", "BEADS_DB", "BD_DB") or key.startswith("BEADS_DOLT_"))
        if overrides:
            raise BootstrapError("unset routing overrides before explicit initialization: " + ", ".join(overrides))
        if not exists(store):
            native_bd = shutil.which("bd", path=environment.get("PATH", ""))
            if native_bd is None:
                raise BootstrapError("required command not found: bd (explicit --init-beads)")
            native_bd = str(Path(native_bd).resolve(strict=True))
            need_init = True

    copy_bundle = bundle != destination and (force or not exists(destination))
    change_hooks = copy_bundle or not exists(descriptor)
    seed_agents = not skip_agents and not exists(agents)
    # Publishing the first absent ancestor avoids creating destination parents
    # before the complete staged tree is ready.
    publication_root = github if not exists(github) else hooks
    root_state = fingerprint(publication_root)
    if (change_hooks or seed_agents) and not os.access(target, os.W_OK | os.X_OK):
        raise BootstrapError(f"consumer root is not writable/searchable: {target}")
    if change_hooks and not os.access(publication_root.parent, os.W_OK | os.X_OK):
        raise BootstrapError(f"publication parent is not writable/searchable: {publication_root.parent}")
    if copy_bundle:
        for parent in (hooks, scripts):
            if exists(parent) and not os.access(parent, os.W_OK | os.X_OK):
                raise BootstrapError(f"staged destination parent would not be writable/searchable: {parent}")
    atomic = AtomicDirectories() if change_hooks else None
    if change_hooks:
        devices = {target.stat().st_dev, publication_root.parent.stat().st_dev}
        if exists(publication_root):
            devices.add(publication_root.stat().st_dev)
        if len(devices) != 1:
            raise BootstrapError("staging and publication must be on the same filesystem")

    return {
        "destination": destination, "descriptor": descriptor, "agents": agents,
        "copy_bundle": copy_bundle, "change_hooks": change_hooks, "seed_agents": seed_agents,
        "publication_root": publication_root, "root_state": root_state,
        "agents_state": fingerprint(agents), "source_state": source_state,
        "ancestors": ancestors, "atomic": atomic, "need_init": need_init, "native_bd": native_bd,
    }


def remove_private_stage(path):
    # copytree preserves read-only modes. Cleanup may add owner permissions
    # only inside this exact private directory, never in the consumer tree.
    def retry(function, name, error):
        if not isinstance(error[1], PermissionError):
            raise error[1]
        candidate = Path(name)
        parent = candidate.parent
        if parent == path or path in parent.parents:
            os.chmod(parent, stat.S_IMODE(parent.stat().st_mode) | 0o700)
        if candidate.is_dir() and not candidate.is_symlink():
            os.chmod(candidate, stat.S_IMODE(candidate.stat().st_mode) | 0o700)
        function(name)
    shutil.rmtree(path, onerror=retry)


def deploy(bundle, target, *, force=False, dry_run=False, init_beads=False,
           skip_agents=False, environment=None):
    environment = dict(os.environ if environment is None else environment)
    bundle, target = Path(bundle), Path(target)
    with consumer_lock(target):
        plan = preflight(bundle, target, force, init_beads, skip_agents, environment)
        if dry_run:
            print("Dry run: preflight passed; no staging, native commands, or writes.")
            return
        stage = None
        seeded_identity = None
        committed = False
        try:
            if plan["change_hooks"] or plan["seed_agents"]:
                stage = Path(tempfile.mkdtemp(prefix=".agent-harness-bootstrap-", dir=target))
            if plan["change_hooks"]:
                staged_root = stage / "publication"
                root = plan["publication_root"]
                if exists(root):
                    shutil.copytree(root, staged_root, symlinks=True)
                else:
                    staged_root.mkdir(mode=0o755)
                staged_bundle = staged_root / plan["destination"].relative_to(root)
                if plan["copy_bundle"]:
                    if staged_bundle.exists():
                        remove_private_stage(staged_bundle)
                    staged_bundle.parent.mkdir(parents=True, exist_ok=True)
                    # Copies every runtime asset, including Python helpers, with
                    # Copilot JSON exclusions and subdirectories preserved.
                    shutil.copytree(bundle, staged_bundle, ignore=bundle_ignore)
                    (staged_bundle / ".agent-harness-bundle").write_text(MARKER)
                staged_descriptor = staged_root / plan["descriptor"].relative_to(root)
                if not staged_descriptor.exists():
                    staged_descriptor.parent.mkdir(parents=True, exist_ok=True)
                    staged_descriptor.write_text(json.dumps(DESCRIPTOR, indent=2) + "\n")
            if plan["seed_agents"]:
                (stage / "AGENTS.md").write_text(SEED)

            if fingerprint(bundle, reject_links=True) != plan["source_state"]:
                raise BootstrapError("source bundle changed during staging; nothing published")
            for path, identity in plan["ancestors"].items():
                if directory_identity(path) != identity:
                    raise BootstrapError(f"consumer destination changed during staging: {path}")
            if fingerprint(plan["publication_root"]) != plan["root_state"]:
                raise BootstrapError("consumer hooks changed during staging; nothing published")
            if fingerprint(plan["agents"]) != plan["agents_state"]:
                raise BootstrapError("AGENTS.md changed during staging; nothing published")
            if plan["need_init"] and exists(target / ".beads"):
                raise BootstrapError("Beads store appeared during staging; nothing published")

            with publication_signals():
                if plan["seed_agents"]:
                    os.link(stage / "AGENTS.md", plan["agents"])
                    info = plan["agents"].stat()
                    seeded_identity = info.st_dev, info.st_ino
                if plan["change_hooks"]:
                    plan["atomic"].publish(staged_root, plan["publication_root"],
                                           replace=plan["root_state"] is not None)
                committed = True
        except (Exception, KeyboardInterrupt) as error:
            if committed:
                raise BootstrapError(f"runtime committed before subsequent failure: {error}; inspect before retrying") from error
            raise
        finally:
            try:
                if not committed and seeded_identity is not None:
                    info = plan["agents"].lstat()
                    if (info.st_dev, info.st_ino) != seeded_identity:
                        raise BootstrapError("publication failed; AGENTS seed was concurrently replaced, refusing to remove it")
                    plan["agents"].unlink()
            finally:
                if stage is not None:
                    try:
                        remove_private_stage(stage)
                    except OSError as error:
                        state = "runtime committed" if committed else "runtime not published"
                        raise BootstrapError(f"{state}; private staging cleanup failed at {stage}: {error}") from error

        if plan["need_init"]:
            print("Runtime published. Explicit bd init is a separate, nontransactional operation.", flush=True)
            if exists(target / ".beads"):
                raise BootstrapError("runtime committed; a Beads store appeared before native init; no init attempted")
            try:
                result = subprocess.run(
                    [plan["native_bd"], "init", "--non-interactive", "--skip-agents"],
                    cwd=target, env=environment, check=False,
                )
            except (OSError, BootstrapError, KeyboardInterrupt) as error:
                raise BootstrapError(
                    f"runtime committed; bd init did not finish: {error}; native state may partially exist; "
                    "no native rollback attempted, inspect before retrying"
                ) from error
            if result.returncode:
                raise BootstrapError(
                    f"runtime committed; bd init failed (exit {result.returncode}); native state may partially exist; "
                    "no native rollback attempted, inspect before retrying"
                )
    print("Runtime bundle deployment complete. Existing project identity is unchanged.")
    print("WARNING: skills, personas, and instructions were not installed; this is not a fully configured agent-harness package.")
    print("Next: run apm install in a consumer that declares agent-harness in apm.yml to install its declared dependencies and primitives.")
    print("Validate the existing store with the bundled bd.sh context --json before enabling hooks.")


def main():
    if sys.version_info < (3, 9):
        raise BootstrapError("Python 3.9+ is required for transactional bootstrap")
    if len(sys.argv) != 7 or any(value not in ("0", "1") for value in sys.argv[3:]):
        raise BootstrapError("invoke bootstrap-project.sh, not the internal transaction helper")

    def interrupted(number, frame):
        raise BootstrapError(f"bootstrap interrupted by signal {number}; native initialization, if started, is not rolled back")

    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    deploy(Path(sys.argv[1]), Path(sys.argv[2]), force=sys.argv[3] == "1",
           dry_run=sys.argv[4] == "1", init_beads=sys.argv[5] == "1", skip_agents=sys.argv[6] == "1")


if __name__ == "__main__":
    try:
        main()
    except (BootstrapError, OSError, KeyboardInterrupt) as error:
        print(f"Agent harness: {error or 'bootstrap interrupted'}", file=sys.stderr)
        sys.exit(1)
