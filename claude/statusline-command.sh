#!/bin/bash
# Status line: project | model | context-window gauge | 5-hour session usage.

input=$(cat)

IFS=$'\t' read -r cwd model pct tokens size session_pct week_pct session_reset week_reset effort < <(printf '%s' "$input" | jq -r '[
  (.workspace.current_dir // ""),
  (.model.display_name // "?"),
  (.context_window.used_percentage // 0),
  (.context_window.total_input_tokens // 0),
  (.context_window.context_window_size // 0),
  (.rate_limits.five_hour.used_percentage // 0 | ceil),
  (.rate_limits.seven_day.used_percentage // 0 | ceil),
  (.rate_limits.five_hour.resets_at // 0),
  (.rate_limits.seven_day.resets_at // 0),
  (.effort.level // "")
] | @tsv')

project=$(basename "$cwd")
reset=$'\033[0m'
blue=$'\033[38;5;153m'

color_for() {
  local p=$1
  if [ "$p" -ge 80 ]; then
    printf '\033[31m'
  elif [ "$p" -ge 50 ]; then
    printf '\033[33m'
  else
    printf '\033[32m'
  fi
}

repeat() {
  local char=$1 count=$2 out="" i
  for ((i = 0; i < count; i++)); do
    out+="$char"
  done
  printf '%s' "$out"
}

commafy() {
  printf '%s' "$1" | sed -E ':a;s/([0-9]+)([0-9]{3})/\1,\2/;ta'
}

until_reset() {
  local target=$1 now
  now=$(date +%s)
  local left=$((target - now))
  if [ "$target" -le 0 ] || [ "$left" -le 0 ]; then
    printf 'now'
    return
  fi
  local days=$((left / 86400))
  local hours=$(((left % 86400) / 3600))
  local mins=$(((left % 3600) / 60))
  if [ "$days" -gt 0 ]; then
    printf '%dd%dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh%dm' "$hours" "$mins"
  else
    printf '%dm' "$mins"
  fi
}

width=20
filled=$((pct * width / 100))
empty=$((width - filled))
bar="$(repeat '#' "$filled")$(repeat '-' "$empty")"
ctx_color=$(color_for "$pct")
session_color=$(color_for "$session_pct")
week_color=$(color_for "$week_pct")

model_display="$model"
if [ -n "$effort" ]; then
  model_display="$model ($effort)"
fi

printf '%s | %s%s%s | Context: %s[%s] %s%%%s (%s/%s) | Session: %s%s%%%s (%s) | Week: %s%s%%%s (%s)' \
  "$project" "$blue" "$model_display" "$reset" \
  "$ctx_color" "$bar" "$pct" "$reset" \
  "$(commafy "$tokens")" "$(commafy "$size")" \
  "$session_color" "$session_pct" "$reset" "$(until_reset "$session_reset")" \
  "$week_color" "$week_pct" "$reset" "$(until_reset "$week_reset")"
