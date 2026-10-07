# JARVIS Full Regression Test Suite

Run `Run-JARVIS-Full-Test.cmd`, paste an Open WebUI API token when prompted, and wait for the HTML dashboard to open. The token is held only in process memory and is never saved.

The suite refuses to run unless Open WebUI is on localhost and the configured model ID is exactly `jarvis`. It sends prompts through Open WebUI so the real JARVIS model configuration and enabled integrations can respond. It never updates models or prompts and contains no code that accesses `C:\JARVIS-Restore\data`.

Reports are written to `C:\JARVIS-Codex\Tests` as timestamped JSON and HTML files. If `Tests\baseline.json` exists, every test is marked as new, regressed, fixed, unchanged pass, or unchanged fail.

## Accept a known-good run as the baseline

```powershell
.\run-full-tests.ps1 -AcceptBaseline
```

Only use this after reviewing the run. It does not modify Open WebUI.

## Add Vision tests

1. Copy a reusable `.png`, `.jpg`, `.jpeg`, or `.webp` file into `Tests\vision`.
2. Add a test object to `Tests\vision\manifest.json`:

```json
{
  "id": "vision-example",
  "name": "Read an error dialog",
  "image": "error-dialog.png",
  "prompt": "Read the main error message in this screenshot.",
  "assertions": [{ "type": "contains", "values": ["expected words"] }],
  "critical": false
}
```

No fabricated Vision test is included. Until a real image is added, the dashboard shows Vision as not configured.

## Assertion types

- `exact`: the trimmed response must exactly match `value`.
- `contains`: every string in `values` must appear, case-insensitively.
- `containsAny`: at least one string in `values` must appear.
- `regex`: the response must match `value` as a regular expression.

Tool-use tests ask JARVIS to identify the tools it used. This makes tool sequencing auditable in the saved raw response. Exact tool availability and names still depend on the real `jarvis` model configuration in Open WebUI.

## Run a single Stage 4 spec

`stage4\run-spec.ps1` runs one spec file, such as `stage4\memory-fallback.json`, through the same Open WebUI connection. It uses `full-config.json`, keeps the same safety checks (localhost only, model ID exactly `jarvis`), and grades assertions the same way as this suite.

```powershell
.\stage4\run-spec.ps1 -SpecPath .\stage4\memory-fallback.json
```

In VS Code, run the **JARVIS: Run Stage 4 Spec** task instead.

Unlike the full suite, it also takes read-only snapshots of the `jarvis` model record and your saved memories before and after the prompt, and fails if either changed. Gates it cannot check from this repo are reported as NOT VERIFIED. The result is PASS, FAIL, or INCOMPLETE (exit 0, 1, or 2), and a JSON report is written next to the suite's reports. See the main `README.md` for details.
