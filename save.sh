#!/bin/bash
# Snapshot live settings into this repo. Safe to re-run any time; review with git diff.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_USER="${WIN_USER:-Astral100}"
WIN_HOME="/mnt/c/Users/$WIN_USER"
# Prefer stable Windows Terminal over Preview if both are installed.
WT_DIR="$(ls -d "$WIN_HOME/AppData/Local/Packages/"Microsoft.WindowsTerminal_*/LocalState 2>/dev/null | grep -v Preview | head -1)"
[ -n "$WT_DIR" ] || WT_DIR="$(ls -d "$WIN_HOME/AppData/Local/Packages/"Microsoft.WindowsTerminal*/LocalState 2>/dev/null | head -1)"

copy() { # copy <src> <repo-relative-dst>
  local src="$1" dst="$REPO/$2"
  if [ ! -e "$src" ]; then echo "MISSING: $src"; return 1; fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst" && echo "saved: $2"
}

# --- Windows Terminal ---------------------------------------------------------
copy "$WT_DIR/settings.json" windows-terminal/settings.json
# WT accepts JSONC (comments, trailing commas); restore.sh sanitizes before
# merging, so only warn when even the sanitizer can't produce valid JSON.
if command -v jq >/dev/null && [ -f "$REPO/windows-terminal/settings.json" ] \
   && ! jq empty "$REPO/windows-terminal/settings.json" 2>/dev/null; then
  if command -v python3 >/dev/null \
     && python3 "$REPO/lib/jsonc-to-json.py" "$REPO/windows-terminal/settings.json" >/dev/null 2>&1; then
    echo "note: windows-terminal/settings.json has JSONC extras (comments/trailing commas) — restore.sh sanitizes them before merging"
  else
    echo "WARN: windows-terminal/settings.json is not parseable JSON — restore.sh will skip the WT merge"
  fi
fi

# --- PowerShell (canonical = pwsh copy; the two live copies should be identical)
PS_PROFILE="$WIN_HOME/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
WPS_PROFILE="$WIN_HOME/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
SRC_PROFILE="$PS_PROFILE"; [ -f "$PS_PROFILE" ] || SRC_PROFILE="$WPS_PROFILE"
copy "$SRC_PROFILE" powershell/Microsoft.PowerShell_profile.ps1
if [ -f "$WPS_PROFILE" ] && ! cmp -s "$PS_PROFILE" "$WPS_PROFILE"; then
  echo "WARN: PowerShell and WindowsPowerShell profiles differ; saved the PowerShell one."
  echo "      diff: diff \"$PS_PROFILE\" \"$WPS_PROFILE\""
fi

# --- Bash: only the custom tail appended after the stock Ubuntu skel ----------
# Marker lines (added by restore.sh) and leading blanks are stripped so the
# block round-trips cleanly instead of nesting markers on each save/restore.
SKEL=/etc/skel/.bashrc
MARK_START="# >>> CustomConfigs >>>"
MARK_END="# <<< CustomConfigs <<<"
mkdir -p "$REPO/bash"
if [ -f "$SKEL" ] && head -n "$(wc -l < "$SKEL")" ~/.bashrc | cmp -s - "$SKEL"; then
  tail -n +"$(( $(wc -l < "$SKEL") + 1 ))" ~/.bashrc \
    | grep -vxF -e "$MARK_START" -e "$MARK_END" \
    | sed '/./,$!d' > "$REPO/bash/bashrc-custom.sh"
  echo "saved: bash/bashrc-custom.sh (custom tail only)"
else
  cp ~/.bashrc "$REPO/bash/bashrc-full"
  if [ ! -f "$SKEL" ]; then
    echo "WARN: $SKEL not found — cannot split off the stock prefix;"
  else
    echo "WARN: ~/.bashrc no longer starts with the stock skel content;"
  fi
  echo "      saved a FULL copy as bash/bashrc-full — trim it manually."
fi

# --- WSL ----------------------------------------------------------------------
copy /etc/wsl.conf wsl/wsl.conf
copy "$WIN_HOME/.wslconfig" wsl/.wslconfig

# --- Git ----------------------------------------------------------------------
copy ~/.gitconfig git/gitconfig
copy ~/.config/git/ignore git/ignore

# --- Claude -------------------------------------------------------------------
for f in CLAUDE.md settings.json keybindings.json statusline-command.sh; do
  copy ~/.claude/"$f" "claude/$f"
done
# -L dereferences symlinks so the repo holds real files (skills/* point into
# ~/.agents/skills, the fork-watch scripts point into ~/ClaudeBugFixes).
for d in scripts notes; do
  mkdir -p "$REPO/claude/$d"
  rsync -aL --delete ~/.claude/"$d"/ "$REPO/claude/$d/" && echo "saved: claude/$d/"
done
# Agents: keep only code-reviewer — the one definition that's actually used.
# The rest of ~/.claude/agents is Claude-generated tooling (2026-07-29 session),
# never invoked, regenerable on demand. --delete-excluded purges saved copies.
mkdir -p "$REPO/claude/agents"
rsync -aL --delete --delete-excluded --include 'code-reviewer.md' --exclude '*' ~/.claude/agents/ "$REPO/claude/agents/" \
  && echo "saved: claude/agents/ (code-reviewer only)"
# Skills: exclude the Matt Pocock pack (identified by its agents/openai.yaml
# marker) — installed software, reinstallable from its source, not hand-kept
# config. --delete-excluded purges previously saved pack copies from the repo.
# Exception: pack skills with local edits (capture rules reworked 2026-09-03:
# research findings → docs/research/, prototypes → prototypes/ on main) are
# saved so the forked versions survive a pack reinstall.
MODIFIED_PACK_SKILLS=(ask-matt domain-modeling prototype wayfinder)
SKILL_EXCLUDES=(); PACK_COUNT=0
for s in "$HOME"/.claude/skills/*/; do
  if [ -f "$s/agents/openai.yaml" ]; then
    name=$(basename "$s")
    case " ${MODIFIED_PACK_SKILLS[*]} " in *" $name "*) continue ;; esac
    SKILL_EXCLUDES+=(--exclude "/$name/")
    PACK_COUNT=$((PACK_COUNT + 1))
  fi
done
mkdir -p "$REPO/claude/skills"
rsync -aL --delete --delete-excluded "${SKILL_EXCLUDES[@]}" ~/.claude/skills/ "$REPO/claude/skills/" \
  && echo "saved: claude/skills/ ($PACK_COUNT pack skills excluded; kept modified: ${MODIFIED_PACK_SKILLS[*]})"

# --- Notepad++ (only config.xml prefs + hand-edited colors in stylers.xml;
# shortcuts.xml/contextMenu.xml/themes are stock on this machine) --------------
NPP_DIR="$WIN_HOME/AppData/Roaming/Notepad++"
copy "$NPP_DIR/config.xml" notepad++/config.xml
copy "$NPP_DIR/stylers.xml" notepad++/stylers.xml

# --- Cmder (config lives in the INSTALL dir, not the user profile) ------------
CMDER_CFG="/mnt/c/Program Files/cmder/config"
copy "$CMDER_CFG/user-ConEmu.xml" cmder/user-ConEmu.xml
copy "$CMDER_CFG/settings" cmder/settings
# user_profile.* and user_aliases.cmd are untouched stock templates — not saved.

# --- VS Code ------------------------------------------------------------------
VSCODE_USER="$WIN_HOME/AppData/Roaming/Code/User"
copy "$VSCODE_USER/settings.json" vscode/settings.json
copy "$VSCODE_USER/keybindings.json" vscode/keybindings.json
if [ -d "$VSCODE_USER/snippets" ]; then
  mkdir -p "$REPO/vscode/snippets"
  rsync -a --delete "$VSCODE_USER/snippets/" "$REPO/vscode/snippets/" && echo "saved: vscode/snippets/"
elif [ -d "$REPO/vscode/snippets" ]; then
  # Live folder is gone — mirror the deletion so the repo doesn't keep stale snippets.
  rm -rf "$REPO/vscode/snippets" && echo "removed: vscode/snippets/ (live folder no longer exists)"
fi
# Extension IDs (deduped across versions) — a reinstall list, not the binaries.
# Glob loop instead of ls|xargs: a dir name with spaces must not get split.
if [ -d "$WIN_HOME/.vscode/extensions" ]; then
  for d in "$WIN_HOME/.vscode/extensions"/*/; do
    [ -e "$d" ] && basename "$d"
  done | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+.*$//' | sort -u > "$REPO/vscode/extensions.txt" \
    && echo "saved: vscode/extensions.txt ($(wc -l < "$REPO/vscode/extensions.txt") extensions)"
fi

# --- Obsidian (vault settings + CSS snippets + plugin settings + user scripts;
# plugin binaries and the Minimal theme are reinstallable — not saved) ---------
OBS_VAULT="$WIN_HOME/Documents/Obsidian Vault"
OBS_CFG="$OBS_VAULT/.obsidian"
if [ -d "$OBS_CFG" ]; then
  for f in app.json appearance.json community-plugins.json core-plugins.json graph.json hotkeys.json; do
    copy "$OBS_CFG/$f" "obsidian/$f"
  done
  if [ -d "$OBS_CFG/snippets" ]; then
    mkdir -p "$REPO/obsidian/snippets"
    rsync -a --delete "$OBS_CFG/snippets/" "$REPO/obsidian/snippets/" && echo "saved: obsidian/snippets/"
  elif [ -d "$REPO/obsidian/snippets" ]; then
    rm -rf "$REPO/obsidian/snippets" && echo "removed: obsidian/snippets/ (live folder no longer exists)"
  fi
  # Plugin settings only (data.json) — main.js/manifest.json ship with the
  # plugin install; -m prunes plugin dirs that carry no data.json.
  if [ -d "$OBS_CFG/plugins" ]; then
    mkdir -p "$REPO/obsidian/plugins"
    rsync -am --delete --include='*/' --include='data.json' --exclude='*' \
      "$OBS_CFG/plugins/" "$REPO/obsidian/plugins/" && echo "saved: obsidian/plugins/ (data.json only)"
  elif [ -d "$REPO/obsidian/plugins" ]; then
    rm -rf "$REPO/obsidian/plugins" && echo "removed: obsidian/plugins/ (live folder no longer exists)"
  fi
  # Vault-root user scripts (QuickAdd macros run these, e.g. ToggleLineBold.js).
  # --delete mirrors removals, so a script deleted live disappears here too.
  mkdir -p "$REPO/obsidian/vault-scripts"
  rsync -a --delete --exclude='*/' --include='*.js' --exclude='*' \
    "$OBS_VAULT/" "$REPO/obsidian/vault-scripts/" && echo "saved: obsidian/vault-scripts/"
else
  echo "MISSING: $OBS_CFG"
fi

# --- Safety net: secrets must never land in the repo --------------------------
find "$REPO" -path "$REPO/.git" -prune -o \( -name '.credentials.json' -o -name 'hosts.yml' \) -print -exec rm -f {} \; | sed 's/^/REMOVED secret file: /'

echo
echo "Done. Review with: git -C \"$REPO\" diff"
