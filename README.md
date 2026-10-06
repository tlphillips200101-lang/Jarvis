# JARVIS AutoTester

JARVIS AutoTester evaluates local models through LM Studio's OpenAI-compatible API. It is local-only, needs no OpenAI API key, installs no packages, and never reads or changes `C:\JARVIS-Restore\data`.

## Run the full suite

```powershell
powershell -ExecutionPolicy Bypass -File .\run-tests.ps1
```

Reports are saved as both JSON and easy-to-read HTML files under `reports`.

## Useful commands

```powershell
# Show all available tests
.\run-tests.ps1 -ListTests

# Run selected tests
.\run-tests.ps1 -TestId connection,memory,tool-calling

# Test one or more loaded models
.\run-tests.ps1 -Model qwen/qwen3-32b,qwen3-14b
```

## Included evaluations

- LM Studio connectivity and exact instruction following
- Arithmetic accuracy
- Valid structured JSON
- Multi-turn memory
- Native OpenAI-compatible tool calling
- Current date grounding using the computer's verified local date
- BLS/live-data honesty when tools are unavailable

Edit `tests.json` to add test cases and `config.json` to adjust models, timeout, token limits, and temperature. The runner refuses any LM Studio URL that is not localhost.

## Important scope

This suite evaluates the model endpoint directly. It does not test Open WebUI web search, persistent JARVIS memory, or JARVIS-specific tools, and the runner does not pretend those integrations exist. To test JARVIS through Open WebUI, see [Run a Stage 4 spec](#run-a-stage-4-spec) below.

## Run a Stage 4 spec

`stage4\run-spec.ps1` runs one spec file, such as `stage4\memory-fallback.json`, through Open WebUI against the exact `jarvis` model. It uses `full-config.json`, refuses any Open WebUI URL that is not localhost, and prompts for an Open WebUI API token (or reads `OPENWEBUI_API_TOKEN`).

```powershell
.\stage4\run-spec.ps1 -SpecPath .\stage4\memory-fallback.json
```

In VS Code, run the **JARVIS: Run Stage 4 Spec** task instead.

The runner grades the response against the spec's assertions. It takes read-only snapshots of the `jarvis` model record and your saved memories before and after the prompt, and fails if either changed. Gates it cannot check from this repo, such as the Task 1 tests in the JARVIS codebase, are reported as NOT VERIFIED, never as passed. The result is PASS (exit 0), FAIL (exit 1), or INCOMPLETE (exit 2), and a JSON report is written to `Tests`.

`stage4\memory-fallback.json` is a supplementary check, not Stage 4 Task 2. The authoritative Stage 4 record is `verification\stage4-final-status-20261005.md`.
