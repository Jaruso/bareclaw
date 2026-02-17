"""
BareClaw MCP Server – agent-driven development harness.

Wraps the bareclaw CLI so AI agents can build, test, and inspect
the runtime as they develop it. All tools shell out to the binary
or zig build system; no Zig code lives here.

Usage:
    uv run server.py

Register in Claude Desktop (~/Library/Application Support/Claude/claude_desktop_config.json):
    {
      "mcpServers": {
        "bareclaw": {
          "command": "uv",
          "args": ["--directory", "/path/to/bareclaw/mcp", "run", "server.py"]
        }
      }
    }
"""

import subprocess
import sys
import os
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# Resolve the repo root relative to this file (mcp/ is one level below root)
REPO_ROOT = Path(__file__).parent.parent.resolve()
BINARY = REPO_ROOT / "zig-out" / "bin" / "bareclaw"


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 60) -> dict:
    """Run a subprocess and return stdout, stderr, and return code."""
    try:
        result = subprocess.run(
            cmd,
            cwd=str(cwd or REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "returncode": result.returncode,
            "ok": result.returncode == 0,
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": f"Command timed out after {timeout}s",
            "returncode": -1,
            "ok": False,
        }
    except FileNotFoundError as e:
        return {
            "stdout": "",
            "stderr": str(e),
            "returncode": -1,
            "ok": False,
        }


def _format(result: dict) -> str:
    """Format a subprocess result into a readable string."""
    parts = []
    if result["stdout"]:
        parts.append(result["stdout"])
    if result["stderr"]:
        parts.append(f"[stderr]\n{result['stderr']}")
    if not result["ok"]:
        parts.append(f"[exit code: {result['returncode']}]")
    return "\n".join(parts) if parts else "(no output)"


mcp = FastMCP("bareclaw")


# ---------------------------------------------------------------------------
# Build tools
# ---------------------------------------------------------------------------


@mcp.tool()
def build(release: bool = False) -> str:
    """Build the BareClaw Zig binary.

    Args:
        release: If true, build with ReleaseSafe optimization. Defaults to debug.
    """
    cmd = ["zig", "build"]
    if release:
        cmd += ["-Doptimize=ReleaseSafe"]
    result = _run(cmd)
    if result["ok"]:
        return f"Build succeeded. Binary at: {BINARY}\n{_format(result)}"
    return f"Build FAILED.\n{_format(result)}"


@mcp.tool()
def run_tests() -> str:
    """Run all BareClaw Zig unit tests via `zig build test`."""
    result = _run(["zig", "build", "test"])
    if result["ok"]:
        return f"All tests passed.\n{_format(result)}"
    return f"Tests FAILED.\n{_format(result)}"


@mcp.tool()
def binary_exists() -> str:
    """Check whether the bareclaw binary has been built and exists on disk."""
    if BINARY.exists():
        size = BINARY.stat().st_size
        return f"Binary exists: {BINARY} ({size:,} bytes)"
    return f"Binary NOT found at: {BINARY}\nRun build() first."


# ---------------------------------------------------------------------------
# Runtime inspection tools
# ---------------------------------------------------------------------------


@mcp.tool()
def status() -> str:
    """Run `bareclaw status` to inspect the current runtime configuration.

    Shows workspace path, config path, provider, model, and memory backend.
    """
    result = _run([str(BINARY), "status"])
    return _format(result)


@mcp.tool()
def run_agent(prompt: str) -> str:
    """Send a prompt to the BareClaw agent and return its response.

    Runs `bareclaw agent "<prompt>"` as a single-turn interaction.

    Args:
        prompt: The input to send to the agent.
    """
    result = _run([str(BINARY), "agent", prompt], timeout=30)
    return _format(result)


@mcp.tool()
def run_cron() -> str:
    """Run `bareclaw cron` to execute any scheduled tasks once."""
    result = _run([str(BINARY), "cron"])
    return _format(result)


@mcp.tool()
def list_peripherals() -> str:
    """Run `bareclaw peripheral` to list configured hardware peripherals."""
    result = _run([str(BINARY), "peripheral"])
    return _format(result)


@mcp.tool()
def help() -> str:
    """Run `bareclaw` with no arguments to show the CLI usage/help text."""
    result = _run([str(BINARY)])
    return _format(result)


# ---------------------------------------------------------------------------
# Source inspection tools
# ---------------------------------------------------------------------------


@mcp.tool()
def list_source_files() -> str:
    """List all Zig source files in the src/ directory with their sizes."""
    src_dir = REPO_ROOT / "src"
    if not src_dir.exists():
        return "src/ directory not found."
    lines = []
    for f in sorted(src_dir.glob("*.zig")):
        size = f.stat().st_size
        lines.append(f"{f.name:30s} {size:>6,} bytes")
    return "\n".join(lines) if lines else "No .zig files found in src/"


@mcp.tool()
def read_source_file(filename: str) -> str:
    """Read the contents of a Zig source file from src/.

    Args:
        filename: The filename within src/ (e.g. "agent.zig", "main.zig").
    """
    path = REPO_ROOT / "src" / filename
    if not path.exists():
        return f"File not found: src/{filename}"
    if not path.suffix == ".zig":
        return "Only .zig files are supported."
    return path.read_text()


@mcp.tool()
def repo_structure() -> str:
    """Show the top-level directory structure of the BareClaw repository."""
    lines = []
    for item in sorted(REPO_ROOT.iterdir()):
        if item.name.startswith(".") or item.name in ("zig-out", ".zig-cache"):
            continue
        if item.is_dir():
            lines.append(f"{item.name}/")
            for child in sorted(item.iterdir()):
                if not child.name.startswith("."):
                    lines.append(f"  {child.name}")
        else:
            lines.append(item.name)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Config inspection
# ---------------------------------------------------------------------------


@mcp.tool()
def read_config() -> str:
    """Read the current BareClaw config file (~/.bareclaw/config.toml)."""
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if not config_path.exists():
        return "Config file not found. Run `bareclaw onboard` or `bareclaw status` to initialize."
    return config_path.read_text()


@mcp.tool()
def run_smoke_tests() -> str:
    """Run the BareClaw smoke test suite (no Discord needed).

    Checks: binary exists, status works, zig unit tests pass,
    Ollama is reachable, agent round-trip responds.
    """
    script = REPO_ROOT / "tests" / "smoke.sh"
    result = _run(["bash", str(script)], timeout=60)
    return _format(result)


@mcp.tool()
def run_integration_test_discord(channel_id: str = "1473381266047893596") -> str:
    """Run the full Discord integration test.

    Starts the bot, sends a real message via Discord REST API,
    waits for the bot to reply, verifies the reply arrived.

    Args:
        channel_id: Discord channel ID to use for the test.
    """
    script = REPO_ROOT / "tests" / "integration_discord.sh"
    import os
    env = os.environ.copy()
    env["CHANNEL_ID"] = channel_id
    result = _run(["bash", str(script)], timeout=120)
    return _format(result)


@mcp.tool()
def config_set(key: str, value: str) -> str:
    """Set a config value and persist it to ~/.bareclaw/config.toml.

    Args:
        key: Config key to set. One of: default_provider, default_model,
             memory_backend, fallback_providers, api_key,
             discord_token, telegram_token.
        value: The value to set.
    """
    result = _run([str(BINARY), "config", "set", key, value])
    return _format(result)


@mcp.tool()
def config_get() -> str:
    """Show all current config values (secrets are masked)."""
    result = _run([str(BINARY), "config", "get"])
    return _format(result)


@mcp.tool()
def workspace_contents() -> str:
    """List files in the BareClaw workspace directory (~/.bareclaw/workspace/)."""
    workspace = Path.home() / ".bareclaw" / "workspace"
    if not workspace.exists():
        return "Workspace directory does not exist yet."
    lines = []
    for item in sorted(workspace.rglob("*")):
        rel = item.relative_to(workspace)
        if item.is_file():
            lines.append(str(rel))
    return "\n".join(lines) if lines else "Workspace exists but is empty."


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
