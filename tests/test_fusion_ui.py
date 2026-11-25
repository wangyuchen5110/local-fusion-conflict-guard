"""Exercise the shared Fusion UI lease across projects without opening Fusion."""

import asyncio
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_mcp import SCRIPTS, open_session


@unittest.skipUnless(os.name == "nt", "Fusion UI coordination runs on Windows")
class FusionUiTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="fusion ui coordination ")
        self.addCleanup(temp.cleanup)
        base = Path(temp.name).resolve()
        self.first, self.second = base / "project one", base / "project two"
        cli_profile = base / "cli local app data"
        mcp_profile = base / "mcp local app data"
        for directory in (self.first, self.second, cli_profile, mcp_profile):
            directory.mkdir()
        self.cli_env = dict(os.environ, LOCALAPPDATA=str(cli_profile))
        self.mcp_env = {"LOCALAPPDATA": str(mcp_profile)}
        self.scripts = Path(shutil.copytree(SCRIPTS, base / "scripts"))
        # Preserve the production directory decision, but keep every lease inside this test.
        # Distinct production paths map to distinct temporary registries, exposing split ownership.
        lease = self.scripts / "fusion-ui.ps1"
        lease.rename(self.scripts / "fusion-ui-production.ps1")
        lease.write_text("""
. (Join-Path $PSScriptRoot 'fusion-ui-production.ps1')
$script:productionLeaseDirectory = ${function:Get-FusionUiLeaseDirectory}
function Get-FusionUiLeaseDirectory {
    $resolved = [IO.Path]::GetFullPath((& $script:productionLeaseDirectory)).ToUpperInvariant()
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($resolved)) }
    finally { $hash.Dispose() }
    return [IO.Path]::Combine($PSScriptRoot, 'test-state', [BitConverter]::ToString($digest))
}
""", encoding="ascii")

    def mcp_session(self, project):
        return open_session(project, scripts=self.scripts, env=self.mcp_env)

    async def cli(self, project, command, *options, shell=None):
        shell = shell or shutil.which("pwsh") or shutil.which("powershell")
        proc = await asyncio.to_thread(
            subprocess.run,
            [shell, "-NoProfile", "-NonInteractive", "-File", str(self.scripts / "fusion-guard.ps1"),
             command, "-Project", str(project), *options],
            capture_output=True, timeout=40, env=self.cli_env,
        )
        self.assertIn(proc.returncode, (0, 2), (proc.stdout, proc.stderr))
        result = json.loads(proc.stdout)
        self.assertEqual(proc.returncode, 0 if result["ok"] else 2)
        return result

    async def tool(self, session, name, **arguments):
        result = await session.call_tool(name, arguments)
        self.assertFalse(result.isError, result.content)
        if result.structuredContent is not None:
            return result.structuredContent
        return json.loads(result.content[0].text)

    async def test_concurrent_projects_share_one_foreground_lease(self):
        # Two instances of the same kind of agent may choose the same local name.
        args = ("-Agent", "designer", "-Task", "check design", "-TtlSeconds", "120")
        results = await asyncio.gather(
            self.cli(self.first, "fusion-ui-acquire", *args, shell=shutil.which("powershell")),
            self.cli(self.second, "fusion-ui-acquire", *args),
        )
        self.assertCountEqual([r["ok"] for r in results], [True, False])
        winner, other = (self.first, self.second) if results[0]["ok"] else (self.second, self.first)
        holder = next(r["holder"] for r in results if r["ok"])
        self.assertEqual((holder["agent"], Path(holder["project"])), ("designer", winner))
        self.assertEqual(next(r["holder"] for r in results if not r["ok"]), holder)
        colleague = await self.cli(winner, "fusion-ui-acquire", "-Agent", "reviewer")
        self.assertFalse(colleague["ok"])
        self.assertEqual(colleague["holder"], holder)
        wrong = await self.cli(other, "fusion-ui-release", "-Agent", "designer")
        self.assertFalse(wrong["ok"])
        self.assertEqual(wrong["holder"], holder)
        renewed = await self.cli(winner, "fusion-ui-acquire", "-Agent", "designer", "-TtlSeconds", "300")
        self.assertTrue(renewed["ok"])
        self.assertEqual(renewed["holder"]["acquiredAt"], holder["acquiredAt"])
        self.assertEqual(renewed["holder"]["task"], "check design")
        self.assertGreater(renewed["holder"]["expiresAt"], holder["expiresAt"])
        self.assertEqual((await self.cli(other, "fusion-ui-status"))["holder"], renewed["holder"])

    async def test_same_agent_label_in_two_mcp_sessions_requires_handoff(self):
        async with self.mcp_session(self.first) as a, self.mcp_session(self.first) as b:
            label = {"agent": "designer"}
            turns = await asyncio.gather(
                self.tool(a, "fusion_ui_acquire", **label),
                self.tool(b, "fusion_ui_acquire", **label),
            )
            self.assertCountEqual([turn["ok"] for turn in turns], [True, False])
            holder, waiting = (a, b) if turns[0]["ok"] else (b, a)
            self.assertEqual(turns[0]["holder"], turns[1]["holder"])
            # Releasing file claims must never hand off a live Fusion window.
            await self.tool(holder, "release", **label)
            self.assertFalse((await self.tool(waiting, "fusion_ui_acquire", **label))["ok"])
            self.assertTrue((await self.tool(holder, "fusion_ui_release", **label))["ok"])
            next_turn = await self.tool(waiting, "fusion_ui_acquire", **label)
            self.assertTrue(next_turn["ok"])
            self.assertNotEqual(next_turn["holder"]["agent"], turns[0]["holder"]["agent"])
            self.assertTrue((await self.tool(waiting, "fusion_ui_release", **label))["ok"])

    async def test_mcp_with_different_localappdata_shares_cli_turn_and_handoff(self):
        active = await self.cli(self.first, "fusion-ui-acquire", "-Agent", "cad-session")
        self.assertTrue(active["ok"])
        model_notes = self.second / "notes.txt"
        model_notes.write_text("pending", encoding="utf-8")
        async with self.mcp_session(self.second) as partner:
            refused = await self.tool(partner, "fusion_ui_acquire")
            self.assertFalse(refused["ok"])
            self.assertEqual(refused["holder"], active["holder"])
            self.assertEqual((await self.tool(partner, "fusion_ui_status"))["holder"], active["holder"])
            self.assertFalse((await self.tool(partner, "fusion_ui_release"))["ok"])
            updated = await self.tool(partner, "edit", path="notes.txt", old_text="pending", new_text="reviewed")
            self.assertTrue(updated["ok"])
            self.assertEqual(model_notes.read_text(encoding="utf-8"), "reviewed")
            note = await self.tool(partner, "post", task="design", message="Review complete")
            self.assertIn(note["event"], (await self.tool(partner, "board", task="design"))["events"])

            released = await self.cli(self.first, "fusion-ui-release", "-Agent", "cad-session")
            self.assertTrue(released["ok"])
            self.assertIsNone(released["holder"])
            takeover = await self.tool(partner, "fusion_ui_acquire")
            self.assertTrue(takeover["ok"])
            self.assertEqual(Path(takeover["holder"]["project"]), self.second)
            self.assertNotEqual(takeover["holder"]["agent"], "cad-session")
            old_release = await self.cli(self.first, "fusion-ui-release", "-Agent", "cad-session")
            self.assertFalse(old_release["ok"])
            self.assertEqual(old_release["holder"], takeover["holder"])
            self.assertTrue((await self.tool(partner, "fusion_ui_release"))["ok"])
            self.assertIsNone((await self.cli(self.first, "fusion-ui-status"))["holder"])
            self.assertTrue((await self.tool(partner, "fusion_ui_acquire", ttl_seconds=15))["ok"])

        # The MCP process exited holding the turn. Other sessions can recover after its deadline.
        await asyncio.sleep(15.1)
        self.assertIsNone((await self.cli(self.first, "fusion-ui-status"))["holder"])
        self.assertTrue((await self.cli(self.first, "fusion-ui-acquire", "-Agent", "cad-session"))["ok"])

    async def test_owner_can_release_after_worktree_is_moved(self):
        shell = shutil.which("powershell")
        acquired = await self.cli(self.first, "fusion-ui-acquire", "-Agent", "designer", shell=shell)
        self.assertTrue(acquired["ok"])
        original = Path(acquired["holder"]["project"])
        original.rename(self.first.with_name("moved project"))

        self.assertEqual((await self.cli(original, "fusion-ui-status"))["holder"], acquired["holder"])
        rejected = await self.cli(original, "fusion-ui-release", "-Agent", "reviewer", shell=shell)
        self.assertFalse(rejected["ok"])
        self.assertEqual(rejected["holder"], acquired["holder"])
        for action in (["fusion-ui-acquire", "-Agent", "designer"], ["claim", "-Path", "test.txt"]):
            proc = await asyncio.to_thread(
                subprocess.run,
                [shell, "-NoProfile", "-NonInteractive", "-File", str(self.scripts / "fusion-guard.ps1"),
                 *action, "-Project", str(original)],
                env=self.cli_env, capture_output=True, timeout=40,
            )
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertFalse(original.exists())
        self.assertTrue((await self.cli(original, "fusion-ui-release", "-Agent", "designer"))["ok"])
        self.assertTrue((await self.cli(self.second, "fusion-ui-acquire", "-Agent", "reviewer"))["ok"])


if __name__ == "__main__":
    unittest.main()
