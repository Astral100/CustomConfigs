#!/bin/bash
# Apply repo settings to this machine — interactive and conflict-aware.
# Never overwrites silently: existing, differing targets get a diff + prompt,
# and a timestamped backup is taken before every overwrite.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_USER="${WIN_USER:-Astral100}"
WIN_HOME="/mnt/c/Users/$WIN_USER"
# Prefer stable Windows Terminal over Preview if both are installed.
WT_DIR="$(ls -d "$WIN_HOME/AppData/Local/Packages/"Microsoft.WindowsTerminal_*/LocalState 2>/dev/null | grep -v Preview | head -1)"
[ -n "$WT_DIR" ] || WT_DIR="$(ls -d "$WIN_HOME/AppData/Local/Packages/"Microsoft.WindowsTerminal*/LocalState 2>/dev/null | head -1)"
BACKUP_DIR="$REPO/.backups/$(date +%Y%m%d-%H%M%S)"
# Prompts read /dev/tty directly: plain stdin may be redirected inside loops.
INTERACTIVE=1; ( : < /dev/tty ) 2>/dev/null || INTERACTIVE=0

note()  { printf '  %s\n' "$*"; }
warn()  { printf 'CONFLICT: %s\n' "$*"; }

backup() { # backup <target-file>
  local rel; rel="$(echo "$1" | tr '/:' '__')"
  mkdir -p "$BACKUP_DIR"
  cp "$1" "$BACKUP_DIR/$rel" && note "backup -> .backups/${BACKUP_DIR##*/}/$rel"
}

# ask "<label>" — returns 0 to overwrite, 1 to skip. Non-interactive always skips.
ask() {
  [ "$INTERACTIVE" = 1 ] || { note "non-interactive: skipping $1"; return 1; }
  local a
  while true; do
    read -r -p "  $1 — [o]verwrite / [s]kip: " a < /dev/tty || return 1
    case "$a" in o|O) return 0;; s|S) return 1;; esac
  done
}

show_diff() { # show_diff <current> <new> — args may be process substitutions (read once)
  local out n
  out="$(diff -u "$1" "$2")"
  n="$(printf '%s\n' "$out" | wc -l)"
  printf '%s\n' "$out" | sed 's/^/    /' | head -60
  [ "$n" -gt 60 ] && note "... diff truncated ($((n - 60)) more lines)"
}

install_file() { # install_file <src: repo-relative or absolute> <abs-target> [sudo] [label]
  local src dst use_sudo label SUDO=""
  case "$1" in /*) src="$1";; *) src="$REPO/$1";; esac
  dst="$2"; use_sudo="${3:-}"; label="${4:-$2}"
  [ "$use_sudo" = sudo ] && SUDO="sudo"
  if [ ! -f "$src" ]; then note "not in repo, skipping: $1"; return; fi
  if [ ! -f "$dst" ]; then
    $SUDO mkdir -p "$(dirname "$dst")"
    $SUDO cp "$src" "$dst" && echo "installed: $label"
    return
  fi
  if cmp -s "$src" "$dst"; then echo "up to date: $label"; return; fi
  echo "differs: $label"
  show_diff "$dst" "$src"
  if ask "$label"; then
    backup "$dst"
    $SUDO cp "$src" "$dst" && echo "overwrote: $label"
  else
    echo "skipped: $label"
  fi
}

echo "== Windows Terminal =="
if ! command -v jq >/dev/null; then
  note "jq not installed — skipping Windows Terminal (sudo apt install jq)"
elif [ -n "$WT_DIR" ] && [ -f "$WT_DIR/settings.json" ] && [ -f "$REPO/windows-terminal/settings.json" ]; then
  # WT accepts JSONC (comments, trailing commas) which jq cannot parse — run both
  # sides through the sanitizer first; if a side still won't parse, skip loudly
  # instead of silently degrading to a whole-file replace.
  sanitize() { # sanitize <src> <dst>
    if command -v python3 >/dev/null; then
      python3 "$REPO/lib/jsonc-to-json.py" "$1" > "$2" 2>/dev/null || cp "$1" "$2"
    else
      cp "$1" "$2"
    fi
  }
  TSAN="$(mktemp)"; RSAN="$(mktemp)"
  sanitize "$WT_DIR/settings.json" "$TSAN"
  sanitize "$REPO/windows-terminal/settings.json" "$RSAN"
  if ! jq empty "$TSAN" 2>/dev/null; then
    warn "machine settings.json is not valid JSON even after JSONC cleanup — merge impossible; skipping, port the actions/keybindings blocks by hand"
  elif ! jq empty "$RSAN" 2>/dev/null; then
    warn "repo windows-terminal/settings.json is not valid JSON even after JSONC cleanup — merge impossible; skipping, fix the saved file"
  else
    cmp -s "$WT_DIR/settings.json" "$TSAN" || \
      note "machine settings.json has JSONC extras (comments/trailing commas) — an overwrite rewrites it as plain JSON"
    # Keybinding collision check: same keys bound to a different action id on this
    # machine. On overwrite the repo binding wins for those keys.
    CONFLICTS="$(jq -n --slurpfile r "$RSAN" --slurpfile t "$TSAN" '
      [ ($r[0].keybindings // [])[] as $rk
        | (($t[0].keybindings // [])[] | select(.keys == $rk.keys and .id != $rk.id)
           | "\(.keys): machine has \(.id), repo has \($rk.id)") ]')"
    if [ "$(echo "$CONFLICTS" | jq 'length')" -gt 0 ]; then
      warn "Windows Terminal keybindings differ for the same keys (repo wins on overwrite):"
      echo "$CONFLICTS" | jq -r '.[] | "    " + .'
    fi
    # Merge instead of whole-file replace: profile lists are machine-specific
    # (generated GUIDs), so only actions, keybindings, copyFormatting and
    # defaultProfile are ported; everything else stays as the machine has it.
    MERGED="$(mktemp)"
    jq -n --slurpfile r "$RSAN" --slurpfile t "$TSAN" '
      $t[0] as $m | $r[0] as $rp
      | ($m.actions // []) as $ma
      | ($m.keybindings // []) as $mk
      | ($rp.keybindings // []) as $rk
      | $m
      | .actions = ($ma + [ ($rp.actions // [])[] | . as $a
                            | select(($ma | map(.id == $a.id) | any) | not) ])
      | .keybindings = ([ $mk[] | . as $k
                          | select(($rk | map(.keys == $k.keys) | any) | not) ] + $rk)
      | .copyFormatting = ($rp.copyFormatting // .copyFormatting)
      | .defaultProfile = ($rp.defaultProfile // .defaultProfile)
    ' > "$MERGED"
    if [ ! -s "$MERGED" ]; then
      warn "Windows Terminal merge failed — skipping (nothing changed)"
    elif [ "$(jq -S . "$MERGED")" = "$(jq -S . "$TSAN")" ]; then
      echo "up to date: Windows Terminal settings"
    else
      echo "differs: Windows Terminal settings (merged: actions/keybindings/globals only)"
      # Diff key-sorted jq renderings of both sides — comparing the machine's
      # native formatting against jq output would drown the real change in noise.
      show_diff <(jq -S . "$TSAN") <(jq -S . "$MERGED")
      if ask "Windows Terminal settings"; then
        backup "$WT_DIR/settings.json"
        cp "$MERGED" "$WT_DIR/settings.json" && echo "overwrote: Windows Terminal settings"
      else
        echo "skipped: Windows Terminal settings"
      fi
    fi
    rm -f "$MERGED"
  fi
  rm -f "$TSAN" "$RSAN"
else
  note "Windows Terminal not found — skipping"
fi

echo
echo "== PowerShell profiles (both hosts get the same canonical file) =="
for tgt in "$WIN_HOME/Documents/PowerShell/Microsoft.PowerShell_profile.ps1" \
           "$WIN_HOME/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"; do
  # Chord-loss check: PSReadLine chords defined on this machine but absent from the repo copy.
  if [ -f "$tgt" ]; then
    while IFS= read -r chord; do
      grep -qF "$chord" "$REPO/powershell/Microsoft.PowerShell_profile.ps1" || \
        warn "$tgt defines PSReadLine chord '$chord' not present in repo — overwriting loses it"
    done < <(grep -oP "Set-PSReadLineKeyHandler\s+-Chord\s+'[^']+'" "$tgt" 2>/dev/null)
  fi
  install_file powershell/Microsoft.PowerShell_profile.ps1 "$tgt"
done

echo
echo "== Bash (~/.bashrc custom block) =="
MARK_START="# >>> CustomConfigs >>>"
MARK_END="# <<< CustomConfigs <<<"
if [ -f "$REPO/bash/bashrc-custom.sh" ]; then
  BLOCK="$(cat "$REPO/bash/bashrc-custom.sh")"
  HAS_START=0; grep -qxF "$MARK_START" ~/.bashrc && HAS_START=1
  HAS_END=0;   grep -qxF "$MARK_END"   ~/.bashrc && HAS_END=1
  if [ "$HAS_START" = 1 ] && [ "$HAS_END" = 0 ]; then
    warn "~/.bashrc has the start marker but no end marker — block is corrupt; fix it manually, skipping"
  elif [ "$HAS_START" = 1 ]; then
    # Replace existing managed block
    CURRENT="$(sed -n "/^$MARK_START\$/,/^$MARK_END\$/p" ~/.bashrc | sed '1d;$d')"
    if [ "$CURRENT" = "$BLOCK" ]; then
      echo "up to date: ~/.bashrc managed block"
    else
      echo "differs: ~/.bashrc managed block"
      show_diff <(echo "$CURRENT") "$REPO/bash/bashrc-custom.sh"
      if ask "~/.bashrc managed block"; then
        backup ~/.bashrc
        awk -v s="$MARK_START" -v e="$MARK_END" -v f="$REPO/bash/bashrc-custom.sh" '
          $0==s {print; while ((getline line < f) > 0) print line; skip=1; next}
          $0==e {skip=0}
          !skip' ~/.bashrc > ~/.bashrc.tmp && mv ~/.bashrc.tmp ~/.bashrc
        echo "updated: ~/.bashrc managed block"
      fi
    fi
  elif [[ "$(cat ~/.bashrc)" == *"$BLOCK"* ]]; then
    echo "already present (unmarked): ~/.bashrc contains the block content verbatim"
    note "wrap it in '$MARK_START' / '$MARK_END' lines to enable managed updates"
  else
    # Name-clash check: aliases/functions the block defines that already exist in bashrc.
    for name in cf svr br cbf claude; do
      if grep -qE "^\s*(alias $name=|$name\s*\(\)|function $name\b)" ~/.bashrc; then
        warn "~/.bashrc already defines '$name' — appended block will shadow it"
      fi
    done
    if ask "append CustomConfigs block to ~/.bashrc"; then
      backup ~/.bashrc
      { echo ""; echo "$MARK_START"; echo "$BLOCK"; echo "$MARK_END"; } >> ~/.bashrc
      echo "appended: ~/.bashrc managed block (reload with: source ~/.bashrc)"
    fi
  fi
fi

echo
echo "== WSL config =="
# /etc/wsl.conf: value-level check against what the REPO actually carries, then
# install with [user] default rewritten to THIS machine's username (a hardcoded
# foreign username would break WSL login).
if [ -f /etc/wsl.conf ] && [ -f "$REPO/wsl/wsl.conf" ]; then
  while IFS='=' read -r key want; do
    [ "$key" = "default" ] && want="$USER"
    have="$(grep -oP "^\s*$key\s*=\s*\K\S+" /etc/wsl.conf | head -1)"
    [ -n "$have" ] && [ "$have" != "$want" ] && warn "/etc/wsl.conf has $key=$have, repo wants $key=$want"
  done < <(grep -oP '^\s*\K[[:alnum:]_]+\s*=\s*\S+' "$REPO/wsl/wsl.conf" | tr -d '[:blank:]')
fi
if [ -f "$REPO/wsl/wsl.conf" ]; then
  WSLTMP="$(mktemp)"
  sed "s/^default=.*/default=$USER/" "$REPO/wsl/wsl.conf" > "$WSLTMP"
  install_file "$WSLTMP" /etc/wsl.conf sudo "/etc/wsl.conf (default user -> $USER)"
  rm -f "$WSLTMP"
fi
install_file wsl/.wslconfig "$WIN_HOME/.wslconfig"
note "wsl.conf/.wslconfig changes need: wsl --shutdown (from Windows) to take effect"

echo
echo "== Git =="
# Per-key conflict report before the file-level prompt.
if [ -f ~/.gitconfig ] && [ -f "$REPO/git/gitconfig" ]; then
  while IFS='=' read -r key val; do
    cur="$(git config --global --get-all "$key" 2>/dev/null | paste -sd'|' -)"
    rep="$(git config -f "$REPO/git/gitconfig" --get-all "$key" 2>/dev/null | paste -sd'|' -)"
    [ -n "$cur" ] && [ "$cur" != "$rep" ] && warn "gitconfig $key: machine='$cur' repo='$rep'"
  done < <(git config -f "$REPO/git/gitconfig" -l | cut -d= -f1 | sort -u | sed 's/$/=/' )
fi
install_file git/gitconfig ~/.gitconfig
install_file git/ignore ~/.config/git/ignore

echo
echo "== Claude (~/.claude) =="
# keybindings.json is covered by the generic diff prompt — a differing binding
# for the same key shows up directly in the diff.
for f in CLAUDE.md settings.json keybindings.json statusline-command.sh; do
  install_file "claude/$f" ~/.claude/"$f"
done
# Per-file install so local-only files are never deleted. On the original machine
# ~/.claude/skills/* are symlinks into ~/.agents/skills — an overwrite there
# writes THROUGH the symlink into the linked source (same content, intended).
for d in scripts agents skills notes; do
  [ -d "$REPO/claude/$d" ] || continue
  while IFS= read -r -d '' src; do
    rel="${src#"$REPO/claude/"}"
    install_file "claude/$rel" ~/.claude/"$rel"
  done < <(find "$REPO/claude/$d" -type f -print0)
done

echo
echo "Done. Backups (if any) are in: $BACKUP_DIR"
