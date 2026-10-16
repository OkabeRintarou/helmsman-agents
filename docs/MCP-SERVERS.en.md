# MCP servers

## Editor

Configure MCP servers in the secrets section of an Agent's edit panel. Cards support stdio (command, one argument per line, environment, working directory), http and sse (URL, headers). JSON mode and cards edit the same configuration; an untouched section is not submitted. Names use ASCII letters, digits, underscores and hyphens, up to 64 characters, unique ignoring case; helmsman is reserved.

Fixed environment and header values are write-only and reopen as “Already set”. Unknown extension fields are hidden too: only their keys appear, with deletion or JSON replacement available. Public tools and timeout extensions with valid types remain editable. “••••••” in JSON preserves the stored value, including after renaming the original card. Keep secrets out of arguments and URLs.

## Local variables

Use `${env:NAME}` to reference a variable on the execution machine, such as `Bearer ${env:GITHUB_PAT}`. The server stores the literal reference and never resolves it. Set variables in the daemon's `daemon.env` or the Agent environment; Agent overrides win, and an empty string counts as set. `HELMSMAN_*` references are prohibited. Resolution happens before CLI startup. A missing variable drops only that server and records the variable name in a warning event. All four CLIs share these rules.

## Templates

- Remote GitHub: https://api.githubcopilot.com/mcp/, requires GITHUB_PAT.
- Local GitHub container: docker + ghcr.io/github/github-mcp-server, requires GITHUB_PAT.
- Playwright: npx @playwright/mcp@latest.
- filesystem: npx -y @modelcontextprotocol/server-filesystem; replace the directory placeholder.
- fetch: uvx mcp-server-fetch.
- Context7: https://mcp.context7.com/mcp.

## Import

Paste Claude/Cursor/Copilot mcpServers JSON, VS Code servers JSON, a single JSON entry (provide its name), Codex config.toml, or a claude/codex mcp add command. Preview, add the cards, then save. `${VAR}` becomes `${env:VAR}`; defaults are ignored with a warning and unsupported input references are left empty. Existing names require confirmation to overwrite; cards can also be renamed.

## Personal definitions

“Personal settings → My MCP servers” manages your definitions (up to 32, 8 KB each). Your Agents can select up to 16 references across workspaces. Updates apply to the next claimed run; already claimed runs retain their configuration. Remove references from active Agents before deleting a definition; archived Agents do not prevent deletion. Renaming takes effect on the next run and is rejected when it conflicts with an Agent's own server. Other users and API/MCP tokens cannot manage personal definitions.

For legacy name collisions, the agent-owned server wins. The summary labels the personal definition as inactive without blocking a run. Supporting daemons also emit a warning event; older daemons still claim the run, with value-free structured server logging.

## Local checks

The “Local check” action on an Agent's detail page checks its PATH for executables, whether referenced variables are set and whether the CLI supports the transport. It runs no program and makes no network request. Results go only to the requesting page and contain no values. Checks are limited to one per Agent per 10 seconds, with a 10-second timeout. Unbound/offline runtimes and old daemons explain why checks are unavailable. Codex does not support sse.

Runs with local references require the daemon protocol version supporting MCP environment references. Older daemons leave them queued with daemon_outdated; configurations without references keep their existing behavior. Owners and administrators see masked detail summaries; other members see names only.
