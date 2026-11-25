"""Exercise the shared Fusion UI lease across projects without opening Fusion."""

import asyncio
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_mcp import SCRIPTS, open_session


@unittest.skipUnless(os.name == "nt", "Fusion UI coordination runs on Windows")
class FusionUiTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="fusion ui coordination ")
        self.addCleanup(temp.cleanup)
        base = Path(temp.name).resolve()
        self.first, self.second = base / "project one", base / "project two"
        user_state = base / "local app data"
        for directory in (self.first, self.second, user_state):
            directory.mkdir()
        # Both the stdio MCP transport and the CLI inherit this isolated user registry.
        env = patch.dict(os.environ, {"LOCALAPPDATA": str(user_state)})
        env.start()
        self.addCleanup(env.stop)

    async def cli(self, project, command, *options, shell=None):
        shell = shell or shutil.which("pwsh") or shutil.which("powershell")
        proc = await asyncio.to_thread(
            subprocess.run,
            [shell, "-NoProfile", "-NonInteractive", "-File", str(SCRIPTS / "fusion-guard.ps1"),
             command, "-Project", str(project), *options],
            capture_output=True, timeout=40,
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
        async with open_session(self.first) as a, open_session(self.first) as b:
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

    async def test_mcp_can_work_while_waiting_and_take_over_from_cli(self):
        active = await self.cli(self.first, "fusion-ui-acquire", "-Agent", "cad-session")
        self.assertTrue(active["ok"])
        model_notes = self.second / "notes.txt"
        model_notes.write_text("pending", encoding="utf-8")
        async with open_session(self.second) as partner:
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


if __name__ == "__main__":
    unittest.main()
