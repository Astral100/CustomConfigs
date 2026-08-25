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
| `claude/` | `CLAUDE.md`, `settings.json`, `keybindings.json`, `statusline-command.sh`, `scripts/`, `agents/` (code-reviewer only), `skills/` (hand-kept only), `notes/` | `~/.claude/` |
| `notepad++/` | `config.xml` (word wrap, tab size 4, indent guides, date-time format, ~a dozen prefs), `stylers.xml` (hand-edited colors: current-line, selection, caret) | `%APPDATA%\Notepad++\` |
| `cmder/` | `user-ConEmu.xml` (Consolas 18, custom color table, startup tasks), `settings` (clink: Ctrl+D exits, Esc clears line) | `C:\Program Files\cmder\config\` — the **install dir**, not the user profile |
| `vscode/` | `settings.json` (40+ prefs), `keybindings.json` (5 rebinds), `snippets/`, `extensions.txt` (deduped reinstall list) | `%APPDATA%\Code\User\`; extensions in `%USERPROFILE%\.vscode\extensions\` |
| `obsidian/` | vault settings (`hotkeys.json`, `appearance.json`, `app.json`, `graph.json`, plugin lists), `snippets/` (3 custom CSS), `plugins/` (per-plugin `data.json` — QuickAdd "Bold Line" macro etc.), `vault-scripts/` (`ToggleLineBold.js`) | `Documents\Obsidian Vault\.obsidian\`; scripts in the vault root |
| `lib/` | `jsonc-to-json.py` — JSONC→JSON sanitizer used by both scripts | (repo tooling, not restored anywhere) |

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
  a warning and the usual prompt). WT files may contain JSONC extras (comments,
  trailing commas — WT itself allows them); both sides are run through
  `lib/jsonc-to-json.py` before merging, and if a side still won't parse the WT
  section is skipped loudly — never replaced wholesale. The confirmation diff
  compares key-sorted JSON renderings, so it shows only real changes, not
  formatting noise.
- **Bash**: the block is appended between `# >>> CustomConfigs >>>` /
  `# <<< CustomConfigs <<<` markers and updated in place on later runs. If the
  content already exists unmarked (the original machine), restore reports it and
  leaves it alone — wrap it in the markers by hand to switch to managed updates.
- **wsl.conf**: `[user] default=` is rewritten to the *current* machine's
  username before installing, so a foreign username can never break WSL login.
- **Claude**: per-file, so machine-local extras are never deleted.
- **Notepad++**: close it before overwriting — it rewrites `config.xml` on exit
  and would clobber the restored file.
- **Cmder**: targets live under `C:\Program Files`, where WSL writes can fail
  without elevation — if the copy fails, do it from an admin shell.
- **VS Code**: snippets restore per-file (local extras kept). Extensions are not
  auto-installed; restore reports which IDs from `extensions.txt` are missing and
  prints the `code --install-extension` one-liner to install them.
- **Obsidian**: close it first — it rewrites `.obsidian/*.json` on exit. Snippets
  restore per-file. Plugin `data.json` lands only where the plugin is already
  installed; plugins are not auto-installed — install missing ones inside Obsidian
  (`community-plugins.json` is the list), then re-run restore for their settings.
  The vault path is hardcoded as `Documents\Obsidian Vault`.

## Not stored (on purpose)

- `~/.claude/.credentials.json`, `~/.config/gh/hosts.yml`, `~/.ssh/` — secrets/keys; recreate by hand (`gh auth login`, `ssh-keygen`).
- Windows Terminal profile list — GUIDs are machine-generated; restore merges only actions/keybindings/globals.
- Runtime state: `~/.claude.json`, history, sessions, caches.
- The Matt Pocock skill pack — installed software, reinstallable from its source;
  `save.sh` auto-excludes any skill carrying the pack's `agents/openai.yaml` marker.
- Notepad++ `shortcuts.xml`/`contextMenu.xml`/themes — byte-identical to the
  shipped files on this machine (the macros in shortcuts.xml are stock).
- Cmder `user_profile.cmd/.ps1/.sh` and `user_aliases.cmd` — untouched stock
  templates from the 2020 install.
- Obsidian `workspace.json` and the remember-cursor-position `cursor-positions.json` —
  runtime state; plugin binaries (`main.js`) and the Minimal theme — reinstallable
  from the community store. Note content itself is covered separately by the
  local-backup plugin (zips the vault to Dropbox every 2 h).
- Visual Studio 2022 — no user snippets/templates exist; `CurrentSettings.vssettings`
  is 370 KB of auto-written machine state. (Only deliberate artifact: a 3.7 KB
  fonts-and-colors export in the 17.0 Settings dir — grab by hand if ever wanted.)

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
- `jq` in WSL (used by the `claude()` bash wrapper and by `restore.sh`; the
  Windows Terminal section is skipped with a hint if it's missing).
- `python3` in WSL (optional — runs the JSONC sanitizer; without it, WT files
  containing comments/trailing commas make the WT merge skip instead).
