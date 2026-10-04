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
# Same charset guard as fork-watch.sh: the id feeds a jobs-registry path and
# the short-id title fallbacks, so a malformed value (a hook misfire) must be
# rejected before anything is read or written.
case "$sid" in *[!0-9a-f-]*) exit 0 ;; esac

tacsafe() {
  # tac glues an unterminated last line onto the previous one ("a\nb"
  # reverses to "ba"), and the glued record is invalid JSON — a crash-torn
  # tail would silently lose the newest conversation entries (same guard
  # as fork-watch.sh). sed '$a\' guarantees a final newline.
  # Fast path (see fork-watch.sh): plain tac on a seekable file streams
  # from the end; only a torn file pays the full-read sed pipe.
  if [ -z "$(tail -c1 "$1" 2>/dev/null)" ]; then
    tac "$1" 2>/dev/null
    return
  fi
  sed -e '$a\' "$1" 2>/dev/null | tac
}

# head -1: -m1 caps matching LINES, not matches — a line carrying a second
# nested "uuid" key would print both and poison the variable with a newline.
first=$(grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' "$tpath" | head -1 | grep -oE '[0-9a-f-]{36}')
last=$(tacsafe "$tpath" | grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' | head -1 | grep -oE '[0-9a-f-]{36}')
[ -n "$first" ] && [ -n "$last" ] || exit 0

pdir=$(dirname "$tpath")
successor=$(grep -l "\"uuid\":\"$first\"" "$pdir"/*.jsonl 2>/dev/null | grep -v -F "$tpath" | xargs -d '\n' -r grep -l "\"uuid\":\"$last\"" 2>/dev/null | head -1)
if [ -z "$successor" ]; then
  # The raw tail can be a junk entry minted in this file alone (attachment,
  # system-reminder-only user entry, "No response requested." filler) — no
  # successor ever holds it. Retry on the last CONVERSATION uuid.
  rlast=$(tacsafe "$tpath" | jq --unbuffered -Rr 'fromjson? | select(.type=="user" or .type=="assistant") | select(.uuid != null) | (.message.content | if type=="string" then . else (.[0].text // .[0].type // "") end) as $t | select(($t | startswith("<system-reminder>") | not) and ($t != "No response requested.")) | .uuid' 2>/dev/null | head -1)
  if [ -n "$rlast" ] && [ "$rlast" != "$last" ]; then
    successor=$(grep -l "\"uuid\":\"$first\"" "$pdir"/*.jsonl 2>/dev/null | grep -v -F "$tpath" | xargs -d '\n' -r grep -l "\"uuid\":\"$rlast\"" 2>/dev/null | head -1)
  fi
fi
[ -n "$successor" ] || exit 0

# The successor must be strictly AHEAD, not an identical twin: a twin also
# holds our first and last uuid, but twins keep one unmarked copy (the
# sweep's keeper election judges them) — marking the ending twin here could
# leave EVERY copy of the conversation deletion-safe ([Old Fork] from this
# hook next to the sweep's [Dup] on the other twin, or [Old Fork] on both
# when twins end back to back). Ahead = the successor's last CONVERSATION
# uuid does not exist in this file; the raw tail may be junk minted in the
# successor alone, so the conversation uuid is the truth-teller — the same
# doctrine as the sweep's twin arm.
slast=$(tacsafe "$successor" | jq --unbuffered -Rr 'fromjson? | select(.type=="user" or .type=="assistant") | select(.uuid != null) | (.message.content | if type=="string" then . else (.[0].text // .[0].type // "") end) as $t | select(($t | startswith("<system-reminder>") | not) and ($t != "No response requested.")) | .uuid' 2>/dev/null | head -1)
[ -n "$slast" ] || slast=$(tacsafe "$successor" | grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' | head -1 | grep -oE '[0-9a-f-]{36}')
if [ -n "$slast" ] && grep -qF "\"uuid\":\"$slast\"" "$tpath"; then
  exit 0
fi

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

mark_row() {
  # Called AFTER the title verdict landed (or already stood): title first,
  # row second, the same order as the sweeps' copy arm — a failed title
  # append must never strand a row-only [Old Fork] no heal revisits.
jfile="$HOME/.claude/jobs/${sid:0:8}/state.json"
if [ -f "$jfile" ]; then
  # A row serving ANOTHER session keeps its name: after a row repair or an
  # alien migration .sessionId no longer matches the folder, and this
  # verdict belongs to the ENDED session, not to whoever the row serves
  # now — same guard as fork-watch.sh set_job_marker.
  rsid=$(jq -r '.sessionId // empty' "$jfile" 2>/dev/null) || rsid=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq -r '.sessionId // empty' 2>/dev/null)
  if [ -n "$rsid" ] && [ "$rsid" != "$sid" ]; then
    return 0
  fi
  # Staleness token BEFORE the name read: a daemon rename landing between a
  # later stat and this read would go undetected and be clobbered.
  m1=$(stat -c '%.Y' "$jfile" 2>/dev/null)
  # Lone-surrogate retry, read and write side (same tolerance as
  # fork-watch.sh): jq 1.6 rejects the \udXXX escape a well-formed JSON
  # writer emits when truncating text mid-emoji, and the row must not become
  # permanently exempt from the supersede write.
  jname=$(jq -r '.name // empty' "$jfile" 2>/dev/null) || jname=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq -r '.name // empty' 2>/dev/null)
  jbase=$(strip_markers "$jname")
  [ -z "$jbase" ] && jbase="${sid:0:8}"
  # The "←" left-press tag rides along on marker upgrades (same contract as
  # fork-watch.sh set_job_marker): a name already tagged keeps the tag inside
  # the replacement marker. Only a real arrow MARKER carries it — a user
  # name that merely begins with the arrow text is a name, never tagged.
  case "$jname" in
    "[←Old Fork] "*|"[←Stub] "*|"[←Dead] "*|"[←Dup] "*|"[←Dup?] "*) jnew="[←Old Fork] $jbase" ;;
    *) jnew="[Old Fork] $jbase" ;;
  esac
  if [ "$jnew" != "$jname" ]; then
    jtmp="$jfile.tmp.$$"
    if jq --arg n "$jnew" '.name = $n' "$jfile" > "$jtmp" 2>/dev/null \
      || sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq --arg n "$jnew" '.name = $n' > "$jtmp" 2>/dev/null; then
      # The redirection minted jtmp under the umask; the row file is the
      # daemon's and may be 0600 — the swap must not loosen it.
      chmod --reference="$jfile" "$jtmp" 2>/dev/null
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
}

# grep narrows the transcript to candidate lines before jq parses them: a full
# jq pass over a large transcript is slow, and one malformed line would stop
# jq mid-stream and lose a title that sits further down.
# Flattened to one line like fork-watch.sh's readers: a title holding a raw
# newline would otherwise read as its LAST line only (tail -1), and the
# supersede write below would mint "[Old Fork] <second half>".
old_title=$(grep -F '"type":"custom-title"' "$tpath" 2>/dev/null | jq -r 'select(.type=="custom-title") | .customTitle // empty | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")' 2>/dev/null | tail -1)
if [ -z "$old_title" ]; then
  old_title=$(grep -F '"type":"ai-title"' "$tpath" 2>/dev/null | jq -r 'select(.type=="ai-title") | .aiTitle // empty | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")' 2>/dev/null | tail -1)
fi
base_title=$(strip_markers "$old_title")
if [ -n "$base_title" ]; then
  new_title="[Old Fork] $base_title"
else
  # Same fallback convention as fork-watch.sh retitle: the short session id.
  # A minted phrase ("superseded by ...") would survive a later heal as a
  # title that reads human and is never recognized as a tool write, blocking
  # row-name sync on this transcript forever.
  new_title="[Old Fork] ${sid:0:8}"
fi
if [ "$new_title" != "$old_title" ]; then
  mt=$(stat -c %y "$tpath" 2>/dev/null)
  # Torn-tail guard (see fork-watch.sh append_custom_title): >> onto an
  # unterminated final line would corrupt that entry for every line-based
  # reader and hide this very title from the scanners.
  [ -n "$(tail -c1 "$tpath" 2>/dev/null)" ] && printf '\n' >> "$tpath"
  # Append failure (a read-only transcript) exits WITHOUT the row write:
  # the title verdict must back every row verdict.
  jq -cn --arg t "$new_title" --arg s "$sid" '{type:"custom-title",customTitle:$t,sessionId:$s}' >> "$tpath" || exit 0
  [ -n "$mt" ] && touch -m -d "$mt" "$tpath"
fi
mark_row
exit 0
