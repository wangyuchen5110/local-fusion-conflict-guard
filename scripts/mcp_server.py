"""Expose the Windows Fusion guard to local stdio MCP clients."""

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Annotated, Any, Literal
from uuid import uuid4

import anyio
from mcp.server.fastmcp import FastMCP
from pydantic import Field


GUARD = Path(__file__).resolve().with_name("fusion-guard.ps1")
# Read argument data from stdin. Only this constant is interpreted as PowerShell.
BRIDGE = r"""
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$raw = [Console]::In.ReadToEnd()
if ($PSVersionTable.PSEdition -eq 'Core') {
    # PowerShell 7's default JSON parser converts ISO text to DateTime, even inside arrays.
    # Its bundled Json.NET can preserve strings on versions predating -DateKind.
    $settings = [Newtonsoft.Json.JsonSerializerSettings]::new()
    $settings.DateParseHandling = 'None'
    $message = [Newtonsoft.Json.JsonConvert]::DeserializeObject($raw, [System.Dynamic.ExpandoObject], $settings)
    $keys = $message.params.psbase.Keys
} else {
    $message = $raw | ConvertFrom-Json
    $keys = $message.params.PSObject.Properties.Name
}
$arguments = @{}
foreach ($key in $keys) {
    $arguments[$key] = $message.params.$key
}
& $message.script @arguments
exit $LASTEXITCODE
"""

AgentName = Annotated[str, Field(min_length=1, max_length=120)]
Seconds = Annotated[int, Field(ge=1, le=15)]
LeaseSeconds = Annotated[int, Field(ge=15, le=86400)]


def build_server(project: Path, shell: str) -> FastMCP:
    session = f"mcp-{uuid4().hex}"
    server = FastMCP(
        "local-fusion-conflict-guard",
        instructions=(
            "First read board.activeWork. Use the same task name for a common goal, "
            "and include task and message (what you are changing and why) in claim. "
            "Inspect peers on every claim. Read board at work boundaries or wait "
            "with its cursor, and post questions, progress and handoffs. "
            "Use edit for an exact change inside a shared UTF-8 file. "
            "For whole-file writes with other tools, claim the paths, reread, "
            "renew before expiry and release when finished. "
            "Before any operation on the Fusion UI, acquire its foreground lease "
            "with fusion_ui_acquire and check ok. The lease is shared across projects "
            "for this Windows user on this machine. Keep related UI steps together, "
            "renew before expiry, and release with fusion_ui_release after the batch. "
            "If busy or the lease expires, leave Fusion untouched (including activation) "
            "until you acquire it again. Continue offline work while waiting. "
            "If several agents share this connection, supply a distinct stable "
            "agent label per participant on post, edit, claim, release and Fusion UI leases."
        ),
    )

    def owner(agent: str | None) -> str:
        return session if agent is None else f"{session}/{agent}"

    async def invoke(command: str, **params: Any) -> list[dict[str, Any]]:
        request = {
            "script": str(GUARD),
            "params": {"Command": command, "Project": str(project), **params},
        }
        with anyio.fail_after(45):
            proc = await anyio.run_process(
                [shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", BRIDGE],
                input=json.dumps(request).encode("ascii"),
                check=False,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        if proc.returncode not in (0, 2):
            raise ValueError(proc.stderr.decode("utf-8", "replace").strip() or "Guard failed")
        return [json.loads(line) for line in proc.stdout.decode("utf-8-sig").splitlines() if line.strip()]

    @server.tool()
    async def board(
        task: str | None = None,
        after: Annotated[int, Field(ge=0, le=9223372036854775807)] = 0,
        limit: Annotated[int, Field(ge=1, le=200)] = 50,
        wait_seconds: Annotated[int, Field(ge=0, le=15)] = 0,
    ) -> dict[str, Any]:
        """See who is doing what (activeWork), read task messages, or wait from nextAfter for updates."""
        params = {"Task": task} if task is not None else {}
        record, = await invoke("board", After=after, Limit=limit, WaitSeconds=wait_seconds, **params)
        return record

    @server.tool()
    async def post(
        task: str,
        message: str,
        kind: Literal["plan", "progress", "question", "handoff", "done"] = "progress",
        to: str | None = None,
        agent: AgentName | None = None,
    ) -> dict[str, Any]:
        """Post to a shared task. All participants can read and reply, including addressed notes."""
        params = {"To": to} if to is not None else {}
        record, = await invoke("post", Agent=owner(agent), Task=task, Message=message, Kind=kind, **params)
        return record

    @server.tool()
    async def edit(
        path: str,
        old_text: Annotated[str, Field(min_length=1)],
        new_text: str,
        agent: AgentName | None = None,
    ) -> dict[str, Any]:
        """Co-edit one UTF-8 file: replace a unique literal in its latest content; inspect ok on return."""
        record, = await invoke("edit", Agent=owner(agent), Path=[path], OldText=old_text, NewText=new_text)
        return record

    @server.tool()
    async def status() -> dict[str, Any]:
        """List active file and directory claims for this server's project."""
        record, = await invoke("status")
        return record

    @server.tool()
    async def claim(
        paths: Annotated[list[str], Field(min_length=1)],
        mode: Literal["file", "tree"] = "file",
        ttl_seconds: LeaseSeconds = 600,
        agent: AgentName | None = None,
        task: str | None = None,
        message: str | None = None,
    ) -> dict[str, Any]:
        """Announce your task and intent while claiming paths. Inspect peers and any blocking conflicts."""
        if any(not path.strip() for path in paths):
            raise ValueError("Each claim path must be nonempty.")
        intent = {}
        if task is not None:
            intent["Task"] = task
        if message is not None:
            intent["Message"] = message
        record, = await invoke("claim", Agent=owner(agent), Path=paths, Mode=mode, TtlSeconds=ttl_seconds, **intent)
        return record

    @server.tool()
    async def release(agent: AgentName | None = None) -> dict[str, Any]:
        """Release all paths claimed by this connection with the same agent label."""
        record, = await invoke("release", Agent=owner(agent))
        return record

    @server.tool()
    async def fusion_ui_status() -> dict[str, Any]:
        """Read the Fusion foreground lease shared across projects for this Windows user and machine."""
        record, = await invoke("fusion-ui-status")
        return record

    @server.tool()
    async def fusion_ui_acquire(
        agent: AgentName | None = None,
        task: str | None = None,
        message: str | None = None,
        ttl_seconds: LeaseSeconds = 600,
    ) -> dict[str, Any]:
        """Acquire or renew before any Fusion UI action. Check ok before activating Fusion or changing documents."""
        intent = {}
        if task is not None:
            intent["Task"] = task
        if message is not None:
            intent["Message"] = message
        record, = await invoke("fusion-ui-acquire", Agent=owner(agent), TtlSeconds=ttl_seconds, **intent)
        return record

    @server.tool()
    async def fusion_ui_release(agent: AgentName | None = None) -> dict[str, Any]:
        """Release this participant's foreground lease after finishing the related Fusion UI steps."""
        record, = await invoke("fusion-ui-release", Agent=owner(agent))
        return record

    @server.tool()
    async def watch_changes(seconds: Seconds = 3) -> dict[str, Any]:
        """Observe up to 100 filesystem events during a new 1–15 second window."""
        records = await invoke("watch", DurationSeconds=seconds, MaxEvents=100, IntervalSeconds=1)
        events = [r for r in records if r["kind"] != "watch-started"]
        return {"project": str(project), "events": events, "limit_reached": len(events) >= 100}

    return server


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True, help="Shared working tree")
    args = parser.parse_args()
    project = args.project.resolve()
    if not project.is_dir():
        parser.error("--project must name an existing directory")
    shell = shutil.which("pwsh") or shutil.which("powershell.exe")
    if os.name != "nt" or not shell:
        parser.error("The shared guard requires PowerShell on Windows")
    build_server(project, shell).run(transport="stdio")


if __name__ == "__main__":
    main()
