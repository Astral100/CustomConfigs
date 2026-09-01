## Replies

- In background-job sessions, do not end replies with `result:` status lines. This overrides the harness convention asking for them.
## Commit messages

- Past tense: "Added", "Removed", "Moved" - not "Add"/"Remove"/"Move".
- Each `-` bullet on a single line. Shorten the wording rather than wrapping it.
- For new files, state the end result, not the steps that built it. Narrate steps only for edits to tracked files.

## Workflow

- Explain the intended approach before starting any implementation; no waiting for approval, but the explanation always comes first.
- Do not run build/run/test after every small change. Batch small edits and verify once, or not at all when the change is trivially safe.
- Never commit or push without an explicit request in that message ("commit"/"push"). Reverting, editing, building, verifying, or agreeing on what a commit would contain is not a request to commit it — wait for the direct instruction.
- Exception: artifacts produced while working /wayfinder issues (research findings, specs, glossary/ADR files) may be committed and pushed without a request or prior confirmation.
- Before committing, show the commit message and wait for confirmation.
- Always push after a requested commit. Do not wait to be asked. This applies only to commits already asked for; it is not licence to create one.
- Do not prefix shell commands with `cd`. Use absolute paths where a path is needed.
- Run every destructive file operation (delete, overwrite, clear) as its own command, never inside a compound command line.
