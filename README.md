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

This suite evaluates the model endpoint directly. Testing Open WebUI web search, persistent JARVIS memory, or JARVIS-specific tools will require a separate adapter for those services; the runner does not pretend those integrations exist.
