# CustomConfigs

Personal settings that live scattered across Windows and WSL, collected in one repo.
Only real customizations are stored — no defaults, no machine state, no secrets.

## Layout

| Folder | Contents | Live location |
|---|---|---|
| `windows-terminal/` | `settings.json` snapshot (real deltas: Ctrl+Z→undo action, Ctrl+PgUp/PgDn tab nav, default profile, `copyFormatting: none`, hidden VS profiles) | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_*\LocalState\` |
| `powershell/` | One canonical profile (PSReadLine chords, `cf`/`svr`/`br`, OSC 9;9 cwd prompt) | `Documents\PowerShell\` **and** `Documents\WindowsPowerShell\` (identical copies) |
| `bash/` | `bashrc-custom.sh` — only the custom tail appended after stock Ubuntu skel (PATH, nvm, `claude()` wrapper, aliases, OSC 9;9) | end of `~/.bashrc` |
| `wsl/` | `wsl.conf` (systemd, default user), `.wslconfig` (guiApplications=false) | `/etc/wsl.conf`, `C:\Users\<user>\.wslconfig` |
| `git/` | `gitconfig` (autocrlf, gh credential helper), global `ignore` | `~/.gitconfig`, `~/.config/git/ignore` |
| `claude/` | `CLAUDE.md`, `settings.json`, `keybindings.json`, `statusline-command.sh`, `scripts/`, `agents/`, `skills/`, `notes/` | `~/.claude/` |

## Usage

Run from WSL (both scripts reach Windows files via `/mnt/c`):

```bash
./save.sh      # snapshot live settings INTO the repo, then review + commit
./restore.sh   # apply repo settings TO this machine (interactive, conflict-aware)
```

`restore.sh` never overwrites silently: every existing, differing target gets a
diff + overwrite/skip prompt, a timestamped backup lands in `.backups/` before any
overwrite, and area-specific conflict checks run first (Windows Terminal key
collisions, PSReadLine chords that would be lost, bash alias/function name clashes,
per-key gitconfig differences, wsl.conf value mismatches).

Area-specific restore behavior:

- **Windows Terminal**: merges — only actions, keybindings, `copyFormatting` and
  `defaultProfile` are ported; the machine's profile list (generated GUIDs) is
  never touched. On a key bound differently on both sides, the repo wins (after
  a warning and the usual prompt).
- **Bash**: the block is appended between `# >>> CustomConfigs >>>` /
  `# <<< CustomConfigs <<<` markers and updated in place on later runs. If the
  content already exists unmarked (the original machine), restore reports it and
  leaves it alone — wrap it in the markers by hand to switch to managed updates.
- **wsl.conf**: `[user] default=` is rewritten to the *current* machine's
  username before installing, so a foreign username can never break WSL login.
- **Claude**: per-file, so machine-local extras are never deleted.

## Not stored (on purpose)

- `~/.claude/.credentials.json`, `~/.config/gh/hosts.yml`, `~/.ssh/` — secrets/keys; recreate by hand (`gh auth login`, `ssh-keygen`).
- Windows Terminal profile list — GUIDs are machine-generated; restore merges only actions/keybindings/globals.
- Runtime state: `~/.claude.json`, history, sessions, caches.

Note: on the original machine `~/.claude/skills/*` are symlinks into `~/.agents/skills/`;
`save.sh` dereferences them so the repo stores real files. `restore.sh` writes real
directories under `~/.claude/skills/` on a fresh machine (no symlink layer needed).

## Caveats

- `git/gitconfig` carries `core.autocrlf = true` (suits the Windows-drive workflow
  where `/mnt/d` repos are shared with Windows tools). On a pure-Linux machine that
  setting CRLF-corrupts checked-out shell scripts (`bad interpreter: /bin/bash^M`) —
  consider `autocrlf = input` there before restoring. This repo protects its own
  files either way via `.gitattributes` (`eol=lf`).

## Dependencies on a fresh machine

- PSReadLine module (ships with PowerShell 5.1+/7; profile assumes it).
- nvm at `~/.nvm` (bashrc block sources it if present — safe when missing).
- `jq` in WSL (used by the `claude()` bash wrapper and by `restore.sh`).
