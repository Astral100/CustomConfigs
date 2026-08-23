export PATH="$HOME/.local/bin:$PATH"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# Scope "claude agents" to the current folder; plain "claude" is unchanged.
# The agents view and the resume picker read names/titles once at open, so the
# marker sweep must finish BEFORE launch — the SessionStart hook loses that race.
claude() {
  if [ "$1" = "agents" ]; then
    shift
    timeout 10 bash "$HOME/.claude/scripts/fork-watch.sh" --sweep-only 2>/dev/null
    command claude agents --cwd "$PWD" "$@"
  elif [ "$1" = "--resume" ] || [ "$1" = "-r" ]; then
    timeout 10 bash "$HOME/.claude/scripts/fork-watch.sh" --sweep-only 2>/dev/null
    # A foreground resume of a roster-owned session errors ("still running as
    # a background agent") and suggests --fork-session, which mints a
    # duplicate. The daemon can attach (and respawn a dead worker) instead:
    # redirect explicit-id resumes to `claude attach` unless a fork was
    # asked for.
    case "$2" in
      [0-9a-f]*-*)
        case " $* " in
          *" --fork-session "*) ;;
          *)
            if jq -e --arg k "${2:0:8}" '.workers[$k] != null' "$HOME/.claude/daemon/roster.json" >/dev/null 2>&1; then
              command claude attach "${2:0:8}"
              return
            fi
            ;;
        esac
        ;;
    esac
    command claude "$@"
  else
    command claude "$@"
  fi
}

# Report cwd to Windows Terminal (OSC 9;9) so duplicate-tab/split-pane keep the folder.
PROMPT_COMMAND=${PROMPT_COMMAND:+"$PROMPT_COMMAND; "}'printf "\e]9;9;%s\e\\" "$(wslpath -w "$PWD")"'
