"""Black-box Windows CLI tests. Uses only Python's standard library."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


BACKEND = Path(__file__).resolve().parents[1] / "scripts" / "fusion-guard.ps1"


@unittest.skipUnless(os.name == "nt", "The CLI requires PowerShell on Windows")
class AgentOnboardingTest(unittest.TestCase):
    def setUp(self):
        self.shell = shutil.which("pwsh") or shutil.which("powershell")
        self.assertIsNotNone(self.shell, "PowerShell is required")
        sandbox = tempfile.TemporaryDirectory(prefix="fusion onboarding ")
        self.addCleanup(sandbox.cleanup)
        self.root = Path(sandbox.name)
        self.project = self.root / "shared project"
        self.cwd = self.root / "other working directory"
        self.cwd.mkdir()
        self.guard = self.install(self.project / ".agents" / "skills" / "local-fusion-conflict-guard")

    def install(self, directory):
        target = directory / "scripts" / BACKEND.name
        target.parent.mkdir(parents=True)
        return Path(shutil.copyfile(BACKEND, target))

    def run_cli(self, *args, guard=None, cwd=None):
        return subprocess.run(
            [self.shell, "-NoProfile", "-NonInteractive", "-File", str(guard or self.guard), *args],
            cwd=cwd or self.cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=30,
        )

    def call(self, *args, guard=None, cwd=None, code=0):
        proc = self.run_cli(*args, guard=guard, cwd=cwd)
        self.assertEqual(proc.returncode, code, (proc.stdout, proc.stderr))
        return json.loads(proc.stdout)

    def test_join_from_independent_processes_and_handoff(self):
        first = self.call("join")
        second = self.call("join")
        self.assertEqual(first["kind"], "joined")
        self.assertTrue(first["ok"])
        self.assertNotEqual(first["agent"], second["agent"])
        self.assertTrue(Path(first["project"]).samefile(self.project))
        self.assertTrue(Path(first["guard"]).samefile(self.guard))

        path = "src/main file.py"
        owned = self.call("claim", "-Agent", first["agent"], "-Path", path)
        self.assertTrue(owned["ok"])
        blocked = self.call("claim", "-Agent", second["agent"], "-Path", path, code=2)
        self.assertFalse(blocked["ok"])
        self.assertEqual(blocked["conflicts"][0]["agent"], first["agent"])
        self.assertEqual(self.call("release", "-Agent", first["agent"])["released"], 1)
        self.assertTrue(self.call("claim", "-Agent", second["agent"], "-Path", path)["ok"])
        self.assertFalse((self.cwd / ".codex").exists())

    def test_first_claim_allocates_an_owner_for_renew_and_release(self):
        path = "notes.txt"
        first = self.call("claim", "-Path", path, "-TtlSeconds", "30")
        owner = first["agent"]
        self.assertTrue(owner.strip())
        self.assertEqual(first["claims"][0]["agent"], owner)
        blocked = self.call("claim", "-Path", path, code=2)
        self.assertNotEqual(blocked["agent"], owner)
        self.assertEqual(blocked["conflicts"][0]["agent"], owner)
        self.assertNotEqual(self.run_cli("release").returncode, 0)
        self.assertEqual([c["agent"] for c in self.call("status")["claims"]], [owner])

        renewed = self.call("claim", "-Agent", owner, "-Path", path, "-TtlSeconds", "600")
        # Both expiry strings use the same fixed-width UTC representation.
        self.assertGreater(renewed["claims"][0]["expiresAt"], first["claims"][0]["expiresAt"])
        self.assertEqual(self.call("release", "-Agent", owner)["released"], 1)
        self.assertEqual(self.call("status")["claims"], [])

    def test_explicit_root_and_standalone_cwd(self):
        explicit = self.root / "explicit project"
        explicit.mkdir()
        report = self.call("join", "-Project", str(explicit), "-Agent", "named-task")
        self.assertTrue(Path(report["project"]).samefile(explicit))
        self.assertEqual(report["agent"], "named-task")

        standalone = self.install(self.root / "local-fusion-conflict-guard")
        claim = self.call("claim", "-Path", "standalone.txt", guard=standalone)
        self.assertTrue(Path(claim["project"]).samefile(self.cwd))
        self.assertEqual(self.call("status")["claims"], [])

    def test_agents_start_from_download_and_share_one_project_copy(self):
        download = self.root / "extracted download"
        shutil.copytree(
            BACKEND.parents[1], download,
            ignore=shutil.ignore_patterns(".git", ".venv", "__pycache__", ".codex", ".agents", "tests"),
        )
        start = download / "start.ps1"
        with ThreadPoolExecutor(max_workers=2) as workers:
            ambient = workers.submit(self.call, guard=start)
            explicit = workers.submit(self.call, "-Project", str(self.cwd), guard=start, cwd=self.root)
            first, second = ambient.result(), explicit.result()
        installed = Path(first["guard"])
        expected = self.cwd / ".agents" / "skills" / "local-fusion-conflict-guard"
        self.assertTrue(installed.samefile(expected / "scripts" / BACKEND.name))
        self.assertTrue(installed.samefile(second["guard"]))
        self.assertNotEqual(first["agent"], second["agent"])
        self.assertEqual(first["kind"], "joined")
        self.assertTrue(Path(first["project"]).samefile(self.cwd))
        self.assertTrue(Path(second["project"]).samefile(self.cwd))

        # A later launch reuses this exact installation without rewriting files.
        before = installed.stat().st_mtime_ns
        again = self.call(guard=start)
        self.assertTrue(installed.samefile(again["guard"]))
        self.assertEqual(installed.stat().st_mtime_ns, before)
        modified = expected / "SKILL.md"
        modified.write_text("Locally customized instructions.", encoding="utf-8")
        self.assertNotEqual(self.run_cli(guard=start).returncode, 0)
        self.assertEqual(modified.read_text(encoding="utf-8"), "Locally customized instructions.")

        download.rename(self.root / "archived download")
        path = "feature.py"
        claim = self.call("claim", "-Agent", first["agent"], "-Path", path, guard=installed, cwd=self.root)
        self.assertTrue(claim["ok"])
        denied = self.call("claim", "-Agent", second["agent"], "-Path", path, guard=installed, code=2)
        self.assertEqual(denied["conflicts"][0]["agent"], first["agent"])
        self.assertEqual(self.call("release", "-Agent", first["agent"], guard=installed)["released"], 1)


if __name__ == "__main__":
    unittest.main()
