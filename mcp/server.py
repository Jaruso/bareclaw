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


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 60, env: dict | None = None) -> dict:
    """Run a subprocess and return stdout, stderr, and return code."""
    try:
        result = subprocess.run(
            cmd,
            cwd=str(cwd or REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
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
    """Run the BareClaw smoke test suite. No Discord required.

    USE THIS after every non-trivial code change to verify nothing broke.
    Checks: binary exists, status works, zig unit tests pass,
    Ollama is reachable, agent round-trip responds.
    Fast (~15s). Always run before run_integration_test_discord.
    """
    script = REPO_ROOT / "tests" / "smoke.sh"
    result = _run(["bash", str(script)], timeout=90)
    return _format(result)


@mcp.tool()
def run_integration_test_discord() -> str:
    """Run the full Discord end-to-end integration test.

    USE THIS to validate the Discord channel feature end-to-end.
    Starts the bot, sends a real @mention via webhook to #testing,
    waits for the bot to reply via Ollama, verifies the reply arrived.
    Requires: Ollama running, discord_token + discord_webhook in config.
    Slower (~30s). Run after smoke tests pass.

    Bot token resolution order:
      1. DISCORD_TEST_TOKEN in .env (integration test token, preferred)
      2. DISCORD_BOT_TOKEN in environment
      3. discord_token in ~/.bareclaw/config.toml
    """
    script = REPO_ROOT / "tests" / "integration_discord.sh"
    env = os.environ.copy()
    env["BINARY"] = str(BINARY)

    # Load .env from the repo root and inject DISCORD_TEST_TOKEN so the
    # integration test uses the dev bot token regardless of what personal
    # token is set in config.toml.
    dot_env = REPO_ROOT / ".env"
    if dot_env.exists():
        for line in dot_env.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            env.setdefault(key, val)  # don't override vars already in env

    result = _run(["bash", str(script)], timeout=120, env=env)
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


# ---------------------------------------------------------------------------
# T2-6/T2-7: Agent introspection and memory management tools
# ---------------------------------------------------------------------------


@mcp.tool()
def agent_status() -> str:
    """Return agent runtime status: workspace path, memory entry count, policy.

    Calls the built-in agent_status tool via a single-turn agent run.
    Useful for checking the health of the agent's working state.
    """
    result = _run([str(BINARY), "mcp", "call", "bareclaw", "agent_status"], timeout=15)
    # Fallback: call via bareclaw agent (single-turn) if mcp call not available
    if not result["ok"]:
        result = _run([str(BINARY), "agent", "call agent_status tool and show the result"], timeout=30)
    return _format(result)


@mcp.tool()
def audit_log_read(n: int = 50) -> str:
    """Read the last N lines of the BareClaw audit log.

    The audit log records every tool call with a unix timestamp, tool name,
    and detail string. Useful for debugging what the agent did.

    Args:
        n: Number of lines to return (default: 50).
    """
    audit_path = Path.home() / ".bareclaw" / "workspace" / "audit.log"
    if not audit_path.exists():
        return "(audit log not yet created)"
    lines = audit_path.read_text().splitlines()
    tail = lines[-n:] if len(lines) > n else lines
    return "\n".join(tail) if tail else "(audit log is empty)"


@mcp.tool()
def memory_list_keys() -> str:
    """List all keys stored in BareClaw's memory backend.

    Returns the logical key name (filename without .md extension) for each
    memory entry stored in ~/.bareclaw/workspace/memory/.
    """
    memory_dir = Path.home() / ".bareclaw" / "workspace" / "memory"
    if not memory_dir.exists():
        return "(no memory directory yet)"
    keys = sorted(
        f.stem for f in memory_dir.glob("*.md") if f.is_file()
    )
    if not keys:
        return "(no memory entries)"
    return "\n".join(keys)


@mcp.tool()
def memory_delete_prefix(prefix: str) -> str:
    """Delete all memory entries whose key starts with the given prefix.

    Useful for cleaning up session transcripts or bulk-removing related entries.

    Args:
        prefix: Key prefix to match (e.g. "session/" deletes all session entries).
    """
    memory_dir = Path.home() / ".bareclaw" / "workspace" / "memory"
    if not memory_dir.exists():
        return f"deleted 0 entries (no memory directory)"
    deleted = 0
    for f in list(memory_dir.glob("*.md")):
        if f.stem.startswith(prefix):
            f.unlink()
            deleted += 1
    return f"deleted {deleted} memory entries with prefix '{prefix}'"


@mcp.tool()
def doctor() -> str:
    """Run `bareclaw doctor` to check health of all subsystems.

    Checks workspace writability, config file, API key, audit log, and cron tasks.
    """
    result = _run([str(BINARY), "doctor"])
    return _format(result)


# ---------------------------------------------------------------------------
# MCP server management tools
# ---------------------------------------------------------------------------


@mcp.tool()
def mcp_list_servers() -> str:
    """List all configured MCP servers that BareClaw knows about.

    MCP servers extend BareClaw with external tools (e.g. AutoTrader, custom bots).
    """
    result = _run([str(BINARY), "mcp", "list-servers"])
    return _format(result)


@mcp.tool()
def mcp_list_tools(server: str = "") -> str:
    """List all tools available from configured MCP servers.

    Connects to each server, runs tools/list, and displays the results.

    Args:
        server: Filter to a specific server by name. If empty, lists all servers.
    """
    cmd = [str(BINARY), "mcp", "list-tools"]
    if server:
        cmd.append(server)
    result = _run(cmd, timeout=30)
    return _format(result)


@mcp.tool()
def mcp_call_tool(server: str, tool: str, args_json: str = "{}") -> str:
    """Call a specific tool on a configured MCP server.

    Useful for testing MCP server connectivity and tool responses.

    Args:
        server: The server name as configured (e.g. "autotrader").
        tool: The tool name to call (e.g. "get_balance").
        args_json: JSON object of arguments, e.g. '{"symbol": "AAPL"}'.
    """
    result = _run([str(BINARY), "mcp", "call", server, tool, args_json], timeout=30)
    return _format(result)


@mcp.tool()
def mcp_add_server(name: str, command: str) -> str:
    """Add or update an MCP server in BareClaw's config.

    Appends the server to the mcp_servers config key. If a server with the
    same name exists, it is replaced.

    Args:
        name: Short identifier for this server (e.g. "autotrader").
        command: Full command to launch the server (e.g. "trader mcp serve").
    """
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if not config_path.exists():
        return "Config file not found. Run bareclaw status first."

    content = config_path.read_text()

    # Parse existing mcp_servers value.
    import re
    match = re.search(r'^mcp_servers\s*=\s*"(.*?)"', content, re.MULTILINE)
    if match:
        existing = match.group(1)
        # Remove any existing entry with the same name.
        entries = [e for e in existing.split("|") if e and not e.startswith(f"{name}=")]
        entries.append(f"{name}={command}")
        new_val = "|".join(entries)
        new_content = content[:match.start()] + f'mcp_servers = "{new_val}"' + content[match.end():]
    else:
        # No mcp_servers line yet — append it.
        new_content = content.rstrip() + f'\nmcp_servers = "{name}={command}"\n'

    config_path.write_text(new_content)
    return f"✓ Added MCP server '{name}' → {command}\n  Saved to {config_path}"


@mcp.tool()
def mcp_remove_server(name: str) -> str:
    """Remove an MCP server from BareClaw's config by name.

    Args:
        name: The server name to remove (e.g. "autotrader").
    """
    config_path = Path.home() / ".bareclaw" / "config.toml"
    if not config_path.exists():
        return "Config file not found."

    content = config_path.read_text()

    import re
    match = re.search(r'^mcp_servers\s*=\s*"(.*?)"', content, re.MULTILINE)
    if not match:
        return f"No mcp_servers configured. Nothing to remove."

    existing = match.group(1)
    entries = [e for e in existing.split("|") if e and not e.startswith(f"{name}=")]
    removed = len(existing.split("|")) - len(entries)
    if removed == 0:
        return f"Server '{name}' not found in mcp_servers."

    new_val = "|".join(entries)
    new_content = content[:match.start()] + f'mcp_servers = "{new_val}"' + content[match.end():]
    config_path.write_text(new_content)
    return f"✓ Removed MCP server '{name}'. Remaining: {new_val or '(none)'}"


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
