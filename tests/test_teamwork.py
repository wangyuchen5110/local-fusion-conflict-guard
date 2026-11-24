"""Exercise a shared task through two independent MCP servers and the CLI."""

import asyncio
import codecs
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_mcp import SCRIPTS, open_session


@unittest.skipUnless(os.name == "nt", "The shared guard runs on Windows")
class TeamworkTest(unittest.IsolatedAsyncioTestCase):
    async def tool(self, client, name, **args):
        response = await client.call_tool(name, args)
        self.assertFalse(response.isError, response.content)
        if response.structuredContent is not None:
            return response.structuredContent
        return json.loads(response.content[0].text)

    def cli(self, project, command, *options):
        shell = shutil.which("pwsh") or shutil.which("powershell")
        result = subprocess.run(
            [shell, "-NoProfile", "-NonInteractive", "-File", str(SCRIPTS / "fusion-guard.ps1"),
             command, "-Project", project, *options],
            capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        return json.loads(result.stdout)

    async def test_agents_see_each_others_work_as_they_start(self):
        with tempfile.TemporaryDirectory(prefix="fusion team intentions ") as project:
            async with open_session(project) as api, open_session(project) as tests:
                api_path = "src/login.py"
                test_path = "tests/login.py"
                api_work = {"path": api_path, "task": "login", "message": "update login API"}
                test_work = {"path": test_path, "task": "login", "message": "exercise the login API"}
                keys = ("agent", "path", "task", "message")

                def work_items(rows):
                    return [{key: row[key] for key in keys} for row in rows]

                first = await self.tool(api, "claim", paths=[api_path], task=api_work["task"],
                                        message=api_work["message"])
                self.assertTrue(first["ok"])
                api_work["agent"] = first["agent"]
                joined = await asyncio.to_thread(self.cli, project, "join")
                self.assertEqual(work_items(joined["peers"]), [api_work])

                parallel = await self.tool(tests, "claim", paths=[test_path], task=test_work["task"],
                                           message=test_work["message"])
                self.assertTrue(parallel["ok"])
                test_work["agent"] = parallel["agent"]
                self.assertNotEqual(api_work["agent"], test_work["agent"])
                self.assertEqual(work_items(parallel["peers"]), [api_work])

                # A renewal while editing carries the original intent and shows the new teammate.
                renewed = await self.tool(api, "claim", paths=[api_path])
                self.assertEqual(work_items(renewed["claims"]), [api_work])
                self.assertEqual(work_items(renewed["peers"]), [test_work])
                blocked = await self.tool(tests, "claim", paths=[api_path])
                self.assertFalse(blocked["ok"])
                self.assertEqual(work_items(blocked["conflicts"]), [api_work])

                board = await self.tool(tests, "board", task="login")
                status = await self.tool(api, "status")
                self.assertCountEqual(work_items(board["activeWork"]), [api_work, test_work])
                self.assertCountEqual(work_items(status["claims"]), [api_work, test_work])
                # Both starts were announced without explicit posts. Conflict and renewal stay quiet.
                self.assertEqual(len(board["events"]), 2)
                for event, work in zip(board["events"], (api_work, test_work)):
                    self.assertEqual((event["agent"], event["kind"], event["source"]),
                                     (work["agent"], "plan", "claim"))
                    self.assertEqual(event["paths"], [work["path"]])
                    self.assertIn(work["message"], event["message"])
                await self.tool(api, "release")
                still_working = await self.tool(tests, "claim", paths=[test_path])
                self.assertEqual(still_working["peers"], [])
                late = await asyncio.to_thread(self.cli, project, "join")
                self.assertEqual(work_items(late["peers"]), [test_work])

    async def test_two_clients_agree_on_a_contract_edit_and_handoff_to_cli(self):
        with tempfile.TemporaryDirectory(prefix="fusion teamwork ") as project:
            path = Path(project) / "feature.py"
            original = (b'def response(n):\r\n    return {"SERVER_KEY": n}\r\n'
                        b'def consume(data):\r\n    return data["CLIENT_KEY"]\r\n'
                        b'assert response(7) == {"total": 7} and consume(response(7)) == 7\r\n')
            path.write_bytes(codecs.BOM_UTF8 + original)
            task = "response-contract"
            async with open_session(project) as api, open_session(project) as ui:
                listing = await api.list_tools()
                self.assertTrue({"post", "board", "edit"} <= {tool.name for tool in listing.tools})
                question = (await self.tool(ui, "post", task=task, kind="question",
                                            message="Which response key should the UI consume?"))["event"]
                received = await self.tool(api, "board", task=task)
                self.assertEqual(received["events"], [question])

                waiting = asyncio.create_task(self.tool(ui, "board", task=task,
                                                        after=question["seq"], wait_seconds=8))
                try:
                    answer = (await self.tool(api, "post", task=task, to=question["agent"],
                                              kind="handoff", message="total"))["event"]
                finally:
                    incoming = await waiting
                self.assertEqual(incoming["events"], [answer])
                self.assertEqual(answer["to"], question["agent"])
                self.assertNotEqual(answer["agent"], question["agent"])

                # Each client owns part of the SAME file. The consumer uses the peer's answer.
                producer, consumer = await asyncio.gather(
                    self.tool(api, "edit", path=path.name, old_text="SERVER_KEY", new_text="total"),
                    self.tool(ui, "edit", path=path.name, old_text="CLIENT_KEY",
                              new_text=incoming["events"][0]["message"]),
                )
                self.assertTrue(producer["ok"], producer)
                self.assertTrue(consumer["ok"], consumer)
                expected = original.replace(b"SERVER_KEY", b"total").replace(b"CLIENT_KEY", b"total")
                self.assertEqual(path.read_bytes(), codecs.BOM_UTF8 + expected)

                # A late third participant can read the conversation and verify the integrated result.
                history = await asyncio.to_thread(self.cli, project, "board", "-Task", task)
                self.assertEqual([e["seq"] for e in history["events"]], [question["seq"], answer["seq"]])
                check = await asyncio.to_thread(subprocess.run, [sys.executable, "-I", path],
                                                capture_output=True, timeout=10)
                self.assertEqual(check.returncode, 0, check.stderr)
                done = await asyncio.to_thread(self.cli, project, "post", "-Task", task, "-Agent",
                                               "reviewer", "-Kind", "done", "-Message", "Contract verified")

                # Cursor-based reads deliver exactly the remaining messages.
                page = await self.tool(ui, "board", task=task, after=question["seq"], limit=1)
                self.assertTrue(page["hasMore"])
                self.assertEqual([e["seq"] for e in page["events"]], [answer["seq"]])
                tail = await self.tool(ui, "board", task=task, after=page["nextAfter"], limit=1)
                self.assertFalse(tail["hasMore"])
                self.assertEqual(tail["events"][0]["seq"], done["event"]["seq"])
                summary = next(t for t in tail["tasks"] if t["task"] == task)
                self.assertCountEqual(summary["participants"], [question["agent"], answer["agent"], "reviewer"])
                self.assertEqual(summary["lastKind"], "done")
                quiet = await self.tool(ui, "board", task=task, after=tail["nextAfter"], wait_seconds=1)
                self.assertEqual(quiet["events"], [])

    async def test_conflicting_edits_preserve_the_file_and_respect_claims(self):
        with tempfile.TemporaryDirectory(prefix="fusion colliding edits ") as project:
            target = Path(project) / "same.txt"
            target.write_bytes(b"aaa current")
            async with open_session(project) as a, open_session(project) as b:
                ambiguous = await self.tool(a, "edit", path=target.name, old_text="aa", new_text="one")
                self.assertEqual(ambiguous["reason"], "ambiguous")
                self.assertEqual(target.read_bytes(), b"aaa current")

                claim = await self.tool(a, "claim", paths=[target.name])
                self.assertTrue(claim["ok"])
                blocked = await self.tool(b, "edit", path=target.name, old_text="current", new_text="other")
                self.assertEqual(blocked["reason"], "claimed")
                self.assertEqual(target.read_bytes(), b"aaa current")
                await self.tool(a, "release")

                first, second = await asyncio.gather(
                    self.tool(a, "edit", path=target.name, old_text="current", new_text="left"),
                    self.tool(b, "edit", path=target.name, old_text="current", new_text="right"),
                )
                self.assertCountEqual([first["kind"], second["kind"]], ["edited", "edit-conflict"])
                loser = second if first["ok"] else first
                self.assertEqual(loser["reason"], "stale")
                self.assertEqual(target.read_bytes(), b"aaa left" if first["ok"] else b"aaa right")


if __name__ == "__main__":
    unittest.main()
