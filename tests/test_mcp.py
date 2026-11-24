"""Run on Windows with the server dependencies installed: python -m unittest discover -s tests."""

import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import asynccontextmanager
from datetime import timedelta
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


@asynccontextmanager
async def open_session(project):
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(SCRIPTS / "mcp_server.py"), "--project", str(project)],
    )
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer, read_timeout_seconds=timedelta(seconds=45)) as session:
            await session.initialize()
            yield session


@unittest.skipUnless(os.name == "nt", "The shared PowerShell guard runs on Windows")
class SharedGuardTest(unittest.IsolatedAsyncioTestCase):
    async def tool(self, session, name, **arguments):
        result = await session.call_tool(name, arguments)
        self.assertFalse(result.isError, result.content)
        if result.structuredContent is not None:
            return result.structuredContent
        return json.loads(result.content[0].text)

    def cli(self, project, *arguments, expected_code=0):
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        self.assertIsNotNone(powershell, "A PowerShell executable is required")
        command, *options = arguments
        completed = subprocess.run(
            [
                powershell, "-NoProfile", "-NonInteractive", "-File",
                str(SCRIPTS / "fusion-guard.ps1"), command, "-Project", str(project), *options,
            ],
            capture_output=True,
            timeout=40,
        )
        self.assertEqual(completed.returncode, expected_code, (completed.stdout, completed.stderr))

    async def test_competing_agents_and_cli_share_one_registry(self):
        with tempfile.TemporaryDirectory(prefix="fusion 项目 ") as project:
            async with open_session(project) as a, open_session(project) as b:
                tools = {tool.name for tool in (await a.list_tools()).tools}
                self.assertTrue({"claim", "release", "status"} <= tools)
                contested = "src/共用 file.ts"
                a_result, b_result = await asyncio.gather(
                    self.tool(a, "claim", paths=[contested]),
                    self.tool(b, "claim", paths=[contested]),
                )
                self.assertCountEqual([a_result["kind"], b_result["kind"]],
                                      ["claim-accepted", "claim-conflict"])
                winner, loser = (a, b) if a_result["ok"] else (b, a)

                unrelated = "other/待编辑.ts"
                denied = await self.tool(loser, "claim", paths=[unrelated, contested])
                self.assertFalse(denied["ok"])
                claims = (await self.tool(loser, "status"))["claims"]
                self.assertEqual([c["path"] for c in claims], [contested])
                self.assertEqual(denied["conflicts"][0]["agent"], claims[0]["agent"])

                accepted = await self.tool(loser, "claim", paths=[unrelated])
                self.assertTrue(accepted["ok"])
                await asyncio.to_thread(self.cli, project, "claim", "-Agent", "cli-test",
                                        "-Path", contested, expected_code=2)
                self.assertTrue((await self.tool(winner, "release"))["ok"])
                await asyncio.to_thread(self.cli, project, "claim", "-Agent", "cli-test",
                                        "-Path", contested)
                cli_block = await self.tool(loser, "claim", paths=[contested])
                self.assertFalse(cli_block["ok"])
                self.assertEqual(cli_block["conflicts"][0]["agent"], "cli-test")
                await asyncio.to_thread(self.cli, project, "release", "-Agent", "cli-test")
                self.assertTrue((await self.tool(loser, "claim", paths=[contested]))["ok"])
                self.assertEqual((await self.tool(loser, "release"))["released"], 2)
                self.assertEqual((await self.tool(winner, "status"))["claims"], [])

    async def test_two_named_agents_on_one_server(self):
        with tempfile.TemporaryDirectory(prefix="fusion shared host ") as project:
            async with open_session(project) as session:
                shared = "main.ts"
                first = await self.tool(session, "claim", agent="task-a", paths=[shared])
                conflict = await self.tool(session, "claim", agent="task-b", paths=[shared])
                self.assertTrue(first["ok"])
                self.assertFalse(conflict["ok"])
                await self.tool(session, "release", agent="task-b")
                self.assertEqual(len((await self.tool(session, "status"))["claims"]), 1)
                await self.tool(session, "release", agent="task-a")
                self.assertTrue((await self.tool(session, "claim", agent="task-b", paths=[shared]))["ok"])

    async def test_watch_reports_claimed_path_and_finishes_on_quiet_project(self):
        with tempfile.TemporaryDirectory(prefix="fusion watch ") as project:
            target = Path(project) / "watched.txt"
            async with open_session(project) as session:
                claimed = await self.tool(session, "claim", paths=[target.name])
                self.assertTrue(claimed["ok"])
                watch = asyncio.create_task(self.tool(session, "watch_changes", seconds=2))
                while not watch.done():
                    with target.open("a", encoding="utf-8") as stream:
                        stream.write("x")
                    await asyncio.sleep(0.15)
                events = (await watch)["events"]
                holders = [c["agent"] for e in events if e.get("path") == target.name
                           for c in e["activeClaims"]]
                self.assertIn(claimed["claims"][0]["agent"], holders)
                quiet = await self.tool(session, "watch_changes", seconds=1)
                self.assertEqual(quiet["events"], [])


if __name__ == "__main__":
    unittest.main()
