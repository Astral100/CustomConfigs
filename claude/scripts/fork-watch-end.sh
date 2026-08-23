#!/bin/bash
# SessionEnd hook: mark abandoned duplicates. When a session ends and BOTH its
# first and last message uuids exist in another transcript of the same project,
# its whole conversation lives on elsewhere — this copy is the old one. Prefix
# its own job-registry name and transcript title with "[Old Fork] " (never
# stacked). A session whose tail messages exist nowhere else is never marked.

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[ -n "$sid" ] && [ -n "$tpath" ] && [ -e "$tpath" ] || exit 0

first=$(grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' "$tpath" | grep -oE '[0-9a-f-]{36}')
last=$(tac "$tpath" | grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' | grep -oE '[0-9a-f-]{36}')
[ -n "$first" ] && [ -n "$last" ] || exit 0

pdir=$(dirname "$tpath")
successor=$(grep -l "\"uuid\":\"$first\"" "$pdir"/*.jsonl 2>/dev/null | grep -v -F "$tpath" | xargs -r grep -l "\"uuid\":\"$last\"" 2>/dev/null | head -1)
if [ -z "$successor" ]; then
  # The raw tail can be a junk entry minted in this file alone (attachment,
  # system-reminder-only user entry, "No response requested." filler) — no
  # successor ever holds it. Retry on the last CONVERSATION uuid.
  rlast=$(tac "$tpath" 2>/dev/null | jq --unbuffered -Rr 'fromjson? | select(.type=="user" or .type=="assistant") | select(.uuid != null) | (.message.content | if type=="string" then . else (.[0].text // .[0].type // "") end) as $t | select(($t | startswith("<system-reminder>") | not) and ($t != "No response requested.")) | .uuid' 2>/dev/null | head -1)
  if [ -n "$rlast" ] && [ "$rlast" != "$last" ]; then
    successor=$(grep -l "\"uuid\":\"$first\"" "$pdir"/*.jsonl 2>/dev/null | grep -v -F "$tpath" | xargs -r grep -l "\"uuid\":\"$rlast\"" 2>/dev/null | head -1)
  fi
fi
[ -n "$successor" ] || exit 0

strip_markers() {
  # Prints $1 without any leading "[Old Fork] "/"[Stub] "/"[Dead] " markers.
  local s="$1" changed=1
  while [ -n "$changed" ]; do
    changed=
    case "$s" in
      "[Old Fork] "*) s=${s#"[Old Fork] "}; changed=1 ;;
      "[Stub] "*) s=${s#"[Stub] "}; changed=1 ;;
      "[Dead] "*) s=${s#"[Dead] "}; changed=1 ;;
      "[Dup] "*) s=${s#"[Dup] "}; changed=1 ;;
      "[Dup?] "*) s=${s#"[Dup?] "}; changed=1 ;;
      "[←Old Fork] "*) s=${s#"[←Old Fork] "}; changed=1 ;;
      "[←Stub] "*) s=${s#"[←Stub] "}; changed=1 ;;
      "[←Dead] "*) s=${s#"[←Dead] "}; changed=1 ;;
      "[←Dup] "*) s=${s#"[←Dup] "}; changed=1 ;;
      "[←Dup?] "*) s=${s#"[←Dup?] "}; changed=1 ;;
    esac
  done
  # A base that is only a bare marker token is inherited marker text, not a
  # real name — callers already substitute the short id / fallback title.
  case "$s" in
    "[Old Fork]"|"[Stub]"|"[Dead]"|"[Dup]"|"[Dup?]") s= ;;
    "[←Old Fork]"|"[←Stub]"|"[←Dead]"|"[←Dup]"|"[←Dup?]") s= ;;
  esac
  printf '%s' "$s"
}

jfile="$HOME/.claude/jobs/${sid:0:8}/state.json"
if [ -f "$jfile" ]; then
  jname=$(jq -r '.name // empty' "$jfile" 2>/dev/null)
  jbase=$(strip_markers "$jname")
  [ -z "$jbase" ] && jbase="${sid:0:8}"
  # The "←" left-press tag rides along on marker upgrades (same contract as
  # fork-watch.sh set_job_marker): a name already tagged keeps the tag inside
  # the replacement marker.
  case "$jname" in
    "[←"*) jnew="[←Old Fork] $jbase" ;;
    *) jnew="[Old Fork] $jbase" ;;
  esac
  if [ "$jnew" != "$jname" ]; then
    jtmp="$jfile.tmp.$$"
    m1=$(stat -c '%.Y' "$jfile" 2>/dev/null)
    if jq --arg n "$jnew" '.name = $n' "$jfile" > "$jtmp" 2>/dev/null; then
      m2=$(stat -c '%.Y' "$jfile" 2>/dev/null)
      # Abort when the daemon rewrote the file mid-flight, so its newer state
      # is not lost — same write discipline as fork-watch.sh set_job_marker.
      if [ "$m1" = "$m2" ]; then
        mv "$jtmp" "$jfile" || rm -f "$jtmp"
      else
        rm -f "$jtmp"
      fi
    else
      rm -f "$jtmp"
    fi
  fi
fi

# grep narrows the transcript to candidate lines before jq parses them: a full
# jq pass over a large transcript is slow, and one malformed line would stop
# jq mid-stream and lose a title that sits further down.
old_title=$(grep -F '"type":"custom-title"' "$tpath" 2>/dev/null | jq -r 'select(.type=="custom-title") | .customTitle // empty' 2>/dev/null | tail -1)
if [ -z "$old_title" ]; then
  old_title=$(grep -F '"type":"ai-title"' "$tpath" 2>/dev/null | jq -r 'select(.type=="ai-title") | .aiTitle // empty' 2>/dev/null | tail -1)
fi
base_title=$(strip_markers "$old_title")
if [ -n "$base_title" ]; then
  new_title="[Old Fork] $base_title"
else
  new_title="[Old Fork] superseded by $(basename "$successor" .jsonl | cut -c1-4)"
fi
[ "$new_title" = "$old_title" ] && exit 0
mt=$(stat -c %y "$tpath" 2>/dev/null)
jq -cn --arg t "$new_title" --arg s "$sid" '{type:"custom-title",customTitle:$t,sessionId:$s}' >> "$tpath"
[ -n "$mt" ] && touch -m -d "$mt" "$tpath"
exit 0
