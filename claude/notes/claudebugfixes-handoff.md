# Handoff: Claude Code session-hygiene tooling (ClaudeBugFixes)

Written 2026-08-19 by a session rooted in `/mnt/d/Video Upscaling/SeedVr` (the work drifted; the natural home for the next session is `~/ClaudeBugFixes`).

## What this project is

Client-side tooling that marks duplicate/ghost Claude Code sessions (v2.1.235, WSL2 Ubuntu-22.04) so cleanup is a glance. Two hooks + a `claude()` bashrc wrapper. **A marker means "safe to delete"; working non-duplicate sessions are NEVER marked.**

- Repo: https://github.com/Astral100/ClaudeBugFixes — local clone `~/ClaudeBugFixes`
- Architecture, marker semantics, design notes: `~/ClaudeBugFixes/README.md`
- Current state and next actions: `~/ClaudeBugFixes/PLAN.md`
- Deep implementation notes (load only when working on this tooling): `~/.claude/notes/claude-session-hygiene.md`
- Hooks are SYMLINKED from `~/.claude/scripts/` into the repo — edit repo files, changes are live.
- Tests: `~/ClaudeBugFixes/tests/fwtest.sh` (33 assertions + 3 stability passes), then `tests/staletest.sh`. Run fwtest first; both green as of head.

## State

- Everything is committed and pushed through `07c73ad` (linked README issue refs). History: `eae3f6e` base → `40f6f16` junk-tail judgment + performance round → `1f386f3` attach redirect in wrapper → `07c73ad`.
- **UNVERIFIED:** the local `~/ClaudeBugFixes` may still be at `1f386f3` with an uncommitted README byte-identical to `07c73ad` — the user was syncing (`git fetch` + `git reset --hard origin/master`) when the session ended. Check `git -C ~/ClaudeBugFixes status` first; if dirty-but-identical, the reset is safe.

## Environment gotchas (hard-won)

- The Bash sandbox could not write the home dir; the user added `permissions.additionalDirectories: ["/home/astral100/ClaudeBugFixes"]` to `~/.claude/settings.json`, so repo git ops work in place now. Network to github.com needed a fresh approval prompt in the last session — if denied silently, ask the user to approve or run the command themselves.
- The user often pastes commands into a REAL terminal: never give a leading `!` for terminal use (bash NOT operator — silently kills `&&` chains), and prefer single unchained commands.
- Git identity is configured repo-locally in `~/ClaudeBugFixes`; commits require showing the message and getting confirmation FIRST, then always push. Past-tense message style, single-line bullets.
- `sudo`/apt and anything interactive: the user runs it, agent verifies after ("check").

## Recent discoveries worth knowing

- Undocumented CLI: `claude attach <8-char-short-id>` (also `claude logs`, `claude stop`) — attaches/respawns roster-owned sessions; the resume picker's "still running as a background agent" error is pure UX, capability exists. The wrapper now redirects `claude --resume <full-id>` to attach for roster-owned sessions.
- `claude --continue` picks by transcript recency and skips roster-owned sessions → it opened the `[Old Fork]` copy `2df713fc` and the daemon forked it into a NEW dup `539af004` (roster: mode=resume fork=true src=2df713fc). Real-world confirmation of the bug family.
- Roster ownership (`~/.claude/daemon/roster.json`) outlives dead worker pids; clears only on daemon restart.

## Open items (in rough priority)

1. Verify local repo sync (see State).
2. Optional wrapper guard: make `claude --continue`/`-c` warn or refuse when the session it would open carries a `[Old Fork]`/`[Dup]`/`[Stub]` title — would have prevented the 539af004 incident. User showed interest, not yet requested.
3. Optional upstream comment on anthropics/claude-code#82489: one-line fork repro (resume, press ←, duplicate appears; daemon death before prompt leaves title-only stub), cross-ref #85404, plus the attach-vs-picker UX point. Draft ideas in PLAN.md "Next". OUTWARD-FACING — needs explicit user approval before posting.
4. Optional performance lever 2: persistent uuid cache (path+size+mtime keyed) to cut the ~2.2s stampless full sweep to ~1s. Lever 1 (batched heal greps) is done. User deferred.
5. User-side cleanup candidates (all marked, deletion-safe): `539af004` (dup of a dup), `2df713fc`/`9e170eb4` ([Old Fork] copies), `a6ffb67c` row+husk (CoinFlipper project). Deletion recipe in README.
6. Portability caveat if ever publicised: scripts assume GNU userland (tac, stat -c, grep -f /dev/stdin); most upstream reporters are on macOS.

## Suggested skills

- Read `~/.claude/notes/claude-session-hygiene.md` before touching the sweep logic (standing instruction: only load it for session-tooling work).
- `/code-review` on any non-trivial change to `fork-watch.sh` before offering a commit.
- `/wait-what` if an explanation of roster/fork mechanics doesn't land — re-pitch in the README's vocabulary (sweep, stamp, marker, roster, jobs registry).
- `/grill-with-docs` only if the user starts a genuinely new feature idea for the tooling.

## Working-style constraints (from the user's global CLAUDE.md and memory — respect them)

- Explain the approach before implementing; no approval gate, but explanation first.
- Never commit/push without an explicit request in that message; show the commit message and wait for confirmation.
- Extremely concise replies; answer first; bullets; sacrifice grammar for concision.
- No gratuitous line wrapping; delete non-actionable log lines; markers/conventions per repo CLAUDE.md are authoritative.
