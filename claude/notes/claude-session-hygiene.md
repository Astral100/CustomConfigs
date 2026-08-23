# Claude Code session hygiene — duplicate/ghost sessions (2026-08-19, v2.1.235, WSL)

Load this only when working on Claude session tooling.

## Architecture (verified)

- Transcript: `~/.claude/projects/<proj>/<session-id>.jsonl` — forks copy the FULL conversation (all message uuids) into a new file.
- Per-session folder `<session-id>/subagents/` — NOT copied by forks.
- Job registry: `~/.claude/jobs/<first-8-of-session-id>/state.json` — agents view reads THIS; deleting a transcript does not remove the row.
- Daemon roster: `~/.claude/daemon/roster.json` — `workers[].{key: short-id, value.pid}` = live attachable job processes.

## The 3 duplicate/ghost causes

1. Backgrounding or resuming (picker, agents view, parallel window) mints a NEW session id → same conversation as 2+ rows. Original stays under old id.
2. Title-only stub .jsonl: 2 metadata lines (ai-title + agent-name), 0 messages — shell that never processed a prompt; inherits title → same-named duplicate row. A dying job can resurrect a deleted filename as such a stub at shutdown.
3. Jobs row with no transcript + dead worker → un-enterable "no saved transcript" ghost in agents view.

## Tooling built

`~/.claude/scripts/fork-watch.sh` (SessionStart) + `fork-watch-end.sh` (SessionEnd), registered in `~/.claude/settings.json`. Append/rename only, never delete, markers never stacked, wrong marks self-heal. **A marker means "safe to delete"** — working non-duplicate rows are never marked:

- `[Old Fork] ` — transcript superseded by a copy holding the same conversation: roster launch info is authoritative for fork direction (uuid-overlap heuristic only for non-resume sources), and same-title real transcripts whose tail is contained in a longer sibling are marked by the copy sweep. Heals when the session diverges past the fork.
- `[Dup] ` — redundant duplicate: an at-rest twin fork of the same parent (newest/live twin keeps the name), an at-rest shell whose parent conversation another job row already carries (seam rule), or the cold copy of identical same-title twins. Twin-vs-superseded compares CONVERSATION uuids (`last_real_uuid`: user/assistant entries minus system-reminder-only users and "No response requested." fillers) whenever raw tails disagree OR a file's raw tail matches no sibling (a junk tail always looks orphaned) — the junk-superset side self-detects via that retry, supersede outranks twinship, and the marker-heal check and fork-watch-end's successor search use the same conversation-tail fallback so junk can neither hide a duplicate nor cause heal/re-mark churn.
- `[Dead] ` — job row that cannot produce a conversation: no real transcript (title-only husks count as none) and not servable by the daemon (no live worker with matching procStart, no respawnable roster launch source). Nameless rows get their short id as the display base.
- `[Stub] ` — transcript file (resume picker) with a title but zero messages whose session is unservable — it would open empty.

Claude Code seeds a new session's ai-title from a marked name, so bare marker text (a title that is exactly `[Dead]`/`[Dup]`/`[Stub]`/`[Old Fork]`) can become a session's whole name; the sweeps treat such a base as empty and substitute the short session id, so it never reads as a sweep mark. Live/streaming files are never marked, but there is no recency window: `settle_hot_files` polls files written <5s ago every 100ms, each file on its own — quiet 3 consecutive polls = settled + re-scanned, changed on 5 polls = streaming (`T_HOT`, skipped this run) immediately, 3s cap for stragglers — marks land on the first open even when the daemon flushes a file in the same second the sweep runs, and an active session never stalls the poll loop. Transcript appends preserve mtime for files idle >60s (recency ordering is what `claude --continue` resumes by); hot files are never backdated. state.json writes abort if the daemon wrote mid-flight.

Performance: everything is loaded once per run into bash caches (one jq for the roster, one jq+stat for all job files, one grep/awk/jq pipeline for all transcript titles) — was ~10s with per-file spawns. Content-driven verdicts (copy-dup groups, divergence heals) skip anything not written since the last completed sweep (stamp mtime = $sm); same-title groups use a containment matrix (one `grep -oF -f` per file, n not n² spawns); divergence heals batch the same way (one grep per project, HC_LAST/alive maps in sweep_transcripts); `last_real_uuid` reads from the end via `tac | jq --unbuffered | head -1`; settle polling is per-file with a 5-changes streaming early-exit. Steady state on the real ~100MB tree: ~0.5-0.9s full sweep, ~10ms with a fresh stamp. Loader field separators are US `0x1f` passed as `jq --arg us $'\x1f'`, NOT tabs: tab is IFS whitespace, so empty fields (missing procStart, nameless jobs) collapse and shift columns. A sweep stamp (`~/.claude/fork-watch-sweep-stamp`) under 30s old skips the sweeps ONLY when `sweeps_current` confirms nothing was written since it (stat pass over project dirs + transcripts + jobs + roster; live-worker sessions' own transcript/state.json writes exempt — never marked, and a running job's state.json rewrites every few seconds; same-second mtimes count as newer). A post-stamp flush voids the skip so marks land on the first open. True skip ~40ms (roster is now always loaded before the skip decision, for worker_live). `set_job_marker` re-reads a job's name when the file's `%.Y` mtime no longer matches the load-time cache, so a daemon rename during the run is never clobbered. The copy-dups twin keeper is healed of stale markers (a twin pair whose mtime order flips can otherwise end up with BOTH marked). The uuid-probe fallback retries with sleeps only for clear/compact sources; a plain startup probes once, so new sessions start without the 2s wait.

`~/.bashrc`: `claude()` wrapper — `claude agents` auto-scopes to `--cwd "$PWD"`; before `claude agents` and `claude --resume`/`-r` it runs `timeout 10 fork-watch.sh --sweep-only` synchronously, because the view/picker read names once at open and the SessionStart hook always loses that race (marks would show only on the SECOND open). `claude --resume <id>` of a roster-owned session is redirected to the undocumented `claude attach <id>` (foreground resume errors "still running as a background agent" and suggests --fork-session = a fresh duplicate; attach respawns dead workers). The interactive picker's error for such sessions happens inside the TUI and cannot be intercepted — use attach or the agents view there.

## Cleanup recipe

Row removal needs BOTH: transcript file AND `~/.claude/jobs/<first8>/` dir (or Ctrl+X twice in the view). A row with a live roster worker survives until Claude/daemon restart.

## Upstream issues (anthropics/claude-code, verified 2026-08-19)

- Fork-on-background/resume: #82489, #86092, #76493, #85004, #78264, #72012 (all open).
- Title-only stubs: #85404 (CLOSED as completed — v2.1.235 stubs are a regression, comment candidate), #77898, #85875, #82969.
- Ghost "no saved transcript" rows: #81662 (exact error-string match), #79757.

## Resolved incidents

- "Upscaler work" un-enterable after restart: job b35e0282 minted 12:03:14 by user backgrounding (before any script work); never processed a prompt → no transcript → died on restart. Real conversation intact as session 9e170eb4.
