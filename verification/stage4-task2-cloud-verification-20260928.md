# Stage 4 Task 2 — Cloud GitHub MCP verification (supplementary)

Date: 2026-09-28
Environment: Claude Code cloud session (hosted GitHub MCP), not the local v1.12.1 `--read-only --toolsets=repos` setup.
Status: **Supplementary evidence only. Does not close Stage 4 Task 2.**

## Results

| # | Capability | Target | Tool | Result |
|---|---|---|---|---|
| 1 | Repository search | GitHub-wide | `search_repositories` | **PASS** — `github/github-mcp-server`, "GitHub's official MCP Server", default branch `main` |
| 2 | File read | `github/github-mcp-server/README.md` | `get_file_contents` | **NOT RUN** — access denied: repo not attached to session |
| 2′ | File read (stand-in) | `tlphillips200101-lang/jarvis/README.md` | `get_file_contents` | **PASS** — first H1 `# JARVIS AutoTester`, blob SHA `1385682a1e89af5991dd5edc724c67b751985076` |
| 3 | Commit/history lookup | `github/github-mcp-server` | `list_commits` | **NOT RUN** — access denied: repo not attached to session |
| 3′ | Commit/history lookup (stand-in) | `tlphillips200101-lang/jarvis` default branch | `list_commits` | **PASS** — `c0341d5` "Add VS Code JARVIS tasks"; `8ecf04c` "Initial JARVIS health and regression suite" |
| 4 | Code-example retrieval | `github/github-mcp-server` | `search_code` | **PASS** — `get_file_contents` found in `pkg/github/repositories.go`, `pkg/github/minimal_types.go`, `pkg/github/repositories_test.go` (`assert.Equal(t, "get_file_contents", tool.Name)`) |

Every check that ran produced a final answer from the MCP result, with no redundant Grep/Read verification afterwards. The application failure from local Attempts 1–2 (no final answer before `max_turns`) did not come back.

## Why checks 2 and 3 were not run on the frozen target

- Session GitHub MCP scope was `tlphillips200101-lang/jarvis` only.
- Adding the repo read-only gives anonymous git clone/fetch only. It does not cover the GitHub MCP tools.
- Attaching it with credentials, which the MCP tools need, was denied by the session permission check. The denial was not worked around.
- A plain git clone was not used as a substitute, because it would not exercise the MCP.

## Side effects

- GitHub writes: 0
- Repositories attached: 0
- Local (Windows) config, reports and checkpoint: untouched
- Task 1 regression: not run
- Stage 4 Task 3: not started

## Next step

Re-run checks 2 and 3 with the frozen prompts on the local read-only MCP setup. Claude must answer once the MCP result has the H1 and the "connects" sentence, rather than doing extra verification. Alternatively, approve attaching `github/github-mcp-server` in a cloud session and re-run them there, using read calls only.
