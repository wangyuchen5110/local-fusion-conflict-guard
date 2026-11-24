"""Expose the Windows Fusion guard to local stdio MCP clients."""

import argparse
import json
import os
import shutil
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
$message = [Console]::In.ReadToEnd() | ConvertFrom-Json
$arguments = @{}
foreach ($property in $message.params.PSObject.Properties) {
    $arguments[$property.Name] = $property.Value
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
            "Claim all intended paths before reading for edit. Only edit after "
            "claim returns ok=true. Renew before expiry and release on completion. "
            "If several agents share this connection, supply a distinct stable "
            "agent label per task on every claim and release."
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
            )
        if proc.returncode not in (0, 2):
            raise ValueError(proc.stderr.decode("utf-8", "replace").strip() or "Guard failed")
        return [json.loads(line) for line in proc.stdout.decode("utf-8-sig").splitlines() if line.strip()]

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
    ) -> dict[str, Any]:
        """Claim or renew project paths. On ok=false, stop and inspect conflicts."""
        if any(not path.strip() for path in paths):
            raise ValueError("Each claim path must be nonempty.")
        record, = await invoke("claim", Agent=owner(agent), Path=paths, Mode=mode, TtlSeconds=ttl_seconds)
        return record

    @server.tool()
    async def release(agent: AgentName | None = None) -> dict[str, Any]:
        """Release all paths claimed by this connection with the same agent label."""
        record, = await invoke("release", Agent=owner(agent))
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
