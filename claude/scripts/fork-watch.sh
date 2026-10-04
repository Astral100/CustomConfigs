#!/bin/bash
# SessionStart hook: warn on EVERY fork — a newly-seen session id that inherited
# a conversation from another session file (clear/compact rollover,
# backgrounding, resume-forks, --fork-session). Fork direction comes from the
# daemon roster when available (authoritative); the uuid-overlap heuristic is
# the fallback for in-process rollovers, retries only for clear/compact (the
# sources whose file is written moments late), and is skipped for
# source=resume, where a restarted old session could otherwise mark its own
# child as parent.
# On a materialized fork the PARENT session is renamed to
# "[Old Fork] <title> - forked on HH:MM dd.mm.yyyy by <first 4 chars of new
# session id>"; re-forking never stacks markers or "forked on" suffixes.
#
# Markers ("[Old Fork] ", "[Stub] ", "[Dead] ", "[Dup] ", "[Dup?] ") are
# mutually exclusive states: setting one replaces any other, and a mark that
# no longer holds is healed off on a later session start. "[Dup?] " is the
# PROVISIONAL dup verdict — written from roster info alone before the settle
# wait so a fresh fork shows its status at once; unlike the others it does NOT
# mean "safe to delete", and the same run's content sweeps upgrade or heal it.
# The hook never deletes anything: the fork copies the conversation in full,
# but the parent's subagents/ folder is NOT copied, so deletion stays manual.
#
# Beyond markers, two name-keeping sweeps run: row-name sync copies a
# user-given agents-view name into the transcript that backs the row, and
# stranded-name rescue donates a name left on a dead shell back to the parent
# transcript its conversation lives in. See README "Name keeping".

# Snapshotted once: the run lasts about a second and every age check tolerates
# far more drift than that.
NOW=$(date +%s)

# Name-sync records: for every transcript whose title this tool wrote (row-name
# sync, stranded-name rescue), the title it wrote. Its own last write is the
# one custom title a later sync may replace — anything else is a name a person
# set from inside a session and stays untouched.
sync_dir="$HOME/.claude/fork-watch-name-sync"

# Set whenever THIS run lands a write (marker, title, repair). The rescue and
# repair skip gates compare file mtimes against the sweep stamp, but the
# tool's own writes restore idle mtimes on purpose — so a verdict written
# this run (a [Stub] mark minting a rescue donor, a [Dead] mark minting a
# repair candidate) would otherwise be invisible to the very gates that run
# moments later, deferring the donation/repair until an unrelated write.
DIRTY=
# Set when THIS run appends any transcript title. Title writes restore idle
# mtimes, yet they change same-title GROUP membership — the copy-dup group
# skip must not trust mtimes alone on a run that renamed something.
DIRTY_T=
# Set when the NAME sweeps (sync, rescue) land a title. They run AFTER the
# copy-dup judgment, and a landed name can JOIN its transcript into another
# same-title group holding the same conversation — a membership no judgment
# has seen, and one no later run would see either: the append restores the
# idle mtime, so the group skip holds until a group MEMBER is written. A
# second judgment pass runs at the end of the sweep when this is set.
NAMES_LANDED=
# Set when the roster file EXISTS but cannot be parsed even after the
# surrogate strip. Every live-session protection keys off the roster, so a
# run without it would read every worker as dead — [Dead] marks and row
# repairs would hit live sessions. Fail closed: no sweeps at all.
ROSTER_BAD=
# Set when a project directory EXISTS but cannot be both read and searched
# (permission damage): every transcript in it drops out of the globs, and
# absence-of-a-transcript is a load-bearing signal — the dead sweep, the
# at-rest dup arms, repair candidacy and rescue donors all act on it — so
# an invisible directory would put deletion-safe [Dead] on live rows (and
# chmod moves no mtime, so no gate revisits them until the next sweep after
# the permissions return). The round-11 unreadable-FILE doctrine one level
# up (D16). Fail closed like ROSTER_BAD: no sweeps, no stamp.
PROJ_BAD=

# "--sweep-only": run the marker sweeps without a session context — invoked by
# the claude() shell wrapper right before the agents view opens, because the
# view snapshots job names once at open and a hook started in parallel loses
# that race. No stdin, no fork detection, no seen-marker.
sweep_only=
if [ "$1" = "--sweep-only" ]; then
  sweep_only=1
  sid= src= tpath=
else
  IFS=$'\x1f' read -r sid src tpath < <(jq -r --arg us $'\x1f' '[(.session_id // ""), (.source // ""), (.transcript_path // "")] | join($us)' 2>/dev/null)
  case "$sid" in
    *[!0-9a-f-]*|"") exit 0 ;;
  esac

  seen_dir="$HOME/.claude/fork-watch-seen"
  mkdir -p "$seen_dir"
  marker="$seen_dir/$sid"
  find "$seen_dir" -type f -mtime +30 -delete 2>/dev/null
fi

parse_markers() {
  # Sets PM_BASE ($1 without any leading markers), PM_OLDFORK (non-empty when
  # the stripped markers included "[Old Fork] ") and PM_ARROW (non-empty when
  # any stripped marker carried the "←" left-press tag — a best-guess note
  # that the session was minted by backgrounding a live session, preserved
  # across marker upgrades by set_job_marker and dropped on heal).
  PM_BASE="$1" PM_OLDFORK= PM_ARROW=
  local changed=1
  while [ -n "$changed" ]; do
    changed=
    case "$PM_BASE" in
      "[Old Fork] "*) PM_BASE=${PM_BASE#"[Old Fork] "}; PM_OLDFORK=1; changed=1 ;;
      "[←Old Fork] "*) PM_BASE=${PM_BASE#"[←Old Fork] "}; PM_OLDFORK=1; PM_ARROW=1; changed=1 ;;
      "[Stub] "*) PM_BASE=${PM_BASE#"[Stub] "}; changed=1 ;;
      "[←Stub] "*) PM_BASE=${PM_BASE#"[←Stub] "}; PM_ARROW=1; changed=1 ;;
      "[Dead] "*) PM_BASE=${PM_BASE#"[Dead] "}; changed=1 ;;
      "[←Dead] "*) PM_BASE=${PM_BASE#"[←Dead] "}; PM_ARROW=1; changed=1 ;;
      "[Dup] "*) PM_BASE=${PM_BASE#"[Dup] "}; changed=1 ;;
      "[←Dup] "*) PM_BASE=${PM_BASE#"[←Dup] "}; PM_ARROW=1; changed=1 ;;
      "[Dup?] "*) PM_BASE=${PM_BASE#"[Dup?] "}; changed=1 ;;
      "[←Dup?] "*) PM_BASE=${PM_BASE#"[←Dup?] "}; PM_ARROW=1; changed=1 ;;
    esac
  done
  # A base that is only a bare marker token is inherited marker text, not a
  # real name: Claude Code seeds a new session's ai-title from a marked name,
  # so the marker string itself can end up as the whole title.
  case "$PM_BASE" in
    "[Old Fork]"|"[Stub]"|"[Dead]"|"[Dup]"|"[Dup?]") PM_BASE= ;;
    "[←Old Fork]"|"[←Stub]"|"[←Dead]"|"[←Dup]"|"[←Dup?]") PM_BASE= ;;
  esac
}

session_shaped() {
  # True when $1 is exactly the 8-4-4-4-12 session-id shape in the hook id
  # charset. A stray non-session file next to the transcripts (a manual
  # "<sid>-copy.jsonl" backup) must never join duplicate judgment: it could
  # win a keeper election by mtime — or read as AHEAD and supersede — and
  # the REAL session plus its row would take the deletion-safe mark while
  # the stray kept the name (D16).
  case "$1" in
    *[!0-9a-f-]*|"") return 1 ;;
  esac
  case "$1" in
    ????????-????-????-????-????????????) return 0 ;;
  esac
  return 1
}

pid_matches_start() {
  # $1 = pid, $2 = expected /proc starttime ticks ("" accepts any live pid).
  # Guards against a recycled pid belonging to an unrelated process.
  # $2 is saved before set -- replaces the positional parameters: comparing
  # against $2 afterwards would read the process's ppid field, never match,
  # and silently declare every recorded worker dead.
  local line rest want="$2"
  # A non-numeric pid (malformed roster) must read dead — "." or "" would
  # otherwise pass the /proc directory test and look alive forever.
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$1" ] || return 1
  [ -n "$want" ] || return 0
  line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  rest=${line##*) }
  set -- $rest
  [ "${20}" = "$want" ]
}

# One-pass caches. Every helper used to spawn its own jq/grep per call; at
# 66 transcripts x ~6 spawns that cost ~10s per run on WSL, and both the view
# and the resume picker read names once at open — the sweep must be fast
# enough to finish before launch. Loaded once by the main flow.
declare -A R_PID R_PST R_LSRC R_MODE R_FORK R_TS
declare -A J_SEEN J_NAME J_SID J_MTIME J_MTIMEF J_NSRC J_RSID
declare -A T_SEEN T_TITLE T_HASUUID T_MTIME T_HASCT T_HOT T_AIT
declare -A LU_SEEN LU_VAL
declare -A LR_SEEN LR_VAL

# The exact suffix shape rename_parent mints (" - forked on HH:MM dd.mm.yyyy
# by xxxx"). Strips match ONLY this shape: a user-chosen name that happens to
# contain " - forked on " is a name, not residue, and must survive heals.
# "????" (exactly the 4 short-id characters), not "*": a trailing-anything
# glob would also eat a user name that merely STARTS with the minted shape
# ("... by abcd (final)" is a name, not residue).
forksuf=' - forked on [0-9][0-9]:[0-9][0-9] [0-9][0-9].[0-9][0-9].[0-9][0-9][0-9][0-9] by ????'

load_roster() {
  # Single jq over the roster; .workers is an OBJECT keyed by the 8-char id.
  # Fields are joined with the US separator (0x1f, bash side $'\x1f'), not
  # @tsv: tab is IFS whitespace in bash, so empty fields (a missing procStart,
  # a nameless job) would collapse and shift the columns.
  local roster="$HOME/.claude/daemon/roster.json" k pid pst lsrc mode isfork ts prog out
  # A MISSING roster legitimately means "no daemon" (fail open). A PRESENT
  # but zero-byte one is a torn truncate-then-write state: jq reads it as
  # empty output with exit 0, which would load an empty roster without
  # tripping the parse-failure guard below — every worker dead, fail open.
  # A legitimate empty roster is '{"workers":{}}', never 0 bytes.
  [ -f "$roster" ] || return 0
  [ -s "$roster" ] || { ROSTER_BAD=1; return 0; }
  # Fields are flattened to single-line before the join: jq -r emits a raw
  # newline for a \n escape inside a value, which would shear the record and
  # shift every later field (and a literal US byte would do the same).
  prog='.workers | to_entries[] | [.key, (.value.pid // ""), (.value.procStart // ""), (.value.dispatch.launch.sessionId // ""), (.value.dispatch.launch.mode // ""), ((.value.dispatch.launch.fork // "") | tostring), (.value.startedAt // 0)] | map(tostring | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")) | join($us)'
  # jq 1.6 rejects a lone-surrogate \udXXX escape — and a well-formed JSON
  # writer emits exactly that when it truncates display text mid-emoji. The
  # roster parse failing closed would load an EMPTY roster and silently void
  # every live-session protection, so the parse is retried with surrogate
  # escapes stripped: only display text can carry them, never the pids,
  # paths and timestamps this loader extracts.
  out=$(jq -r --arg us $'\x1f' "$prog" "$roster" 2>/dev/null) || out=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$roster" | jq -r --arg us $'\x1f' "$prog" 2>/dev/null) || { ROSTER_BAD=1; return 0; }
  while IFS=$'\x1f' read -r k pid pst lsrc mode isfork ts; do
    [ -n "$k" ] || continue
    R_PID[$k]=$pid; R_PST[$k]=$pst; R_LSRC[$k]=$lsrc; R_MODE[$k]=$mode; R_FORK[$k]=$isfork; R_TS[$k]=$ts
  done <<EOF
$out
EOF
}

load_jobs() {
  # Single jq (and single stat) over every jobs-registry state.json. One
  # malformed file aborts a multi-file jq run, so on failure every file is
  # re-read alone and only the bad one is dropped.
  local jqprog f name jsid nsrc rsid short out line mt mtf
  # $fn: the surrogate retry below reads from a pipe, where jq 1.6 reports
  # input_filename as "<stdin>" — the caller passes the real path there.
  # The same single-line flattening as load_roster: a NAME holding a real
  # newline (the view accepts pasted text) would otherwise shear the record —
  # J_SID and J_NSRC load empty and the row sits silently exempt from every
  # sweep, while the name's second half becomes a bogus J_SEEN key.
  jqprog='[(if $fn == "" then input_filename else $fn end), (.name // ""), (.sessionId // ""), (.nameSource // ""), (.resumeSessionId // "")] | map(tostring | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")) | join($us)'
  set -- "$HOME"/.claude/jobs/*/state.json
  [ -e "$1" ] || return 0
  # %.Y (nanosecond mtime) is the cache-staleness token set_job_marker checks
  # before writing; %Y feeds the dead sweep's settle guard. The stat runs
  # BEFORE the jq that reads the names: the token must never be newer than
  # the data, or a daemon rewrite landing between the two would slip past
  # the guard and be clobbered by the stale name. A rewrite the other way
  # round (after the stat, before the jq) only makes the token look stale,
  # which costs a re-read, never a lost name.
  while read -r mt mtf f; do
    [ -n "$f" ] || continue
    short=${f%/state.json}; short=${short##*/}
    J_MTIME[$short]=$mt; J_MTIMEF[$short]=$mtf
  done < <(stat -c '%Y %.Y %n' "$@" 2>/dev/null)
  if ! out=$(jq -r --arg us $'\x1f' --arg fn "" "$jqprog" "$@" 2>/dev/null); then
    out=""
    for f in "$@"; do
      # Lone-surrogate retry per file (see load_roster): without it the one
      # bad row silently drops from the cache — permanently exempt from
      # every marker, heal and repair while the daemon can still read it.
      line=$(jq -r --arg us $'\x1f' --arg fn "" "$jqprog" "$f" 2>/dev/null) \
        || line=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$f" | jq -r --arg us $'\x1f' --arg fn "$f" "$jqprog" 2>/dev/null) \
        || continue
      out="$out$line"$'\n'
    done
  fi
  while IFS=$'\x1f' read -r f name jsid nsrc rsid; do
    [ -n "$f" ] || continue
    short=${f%/state.json}; short=${short##*/}
    J_SEEN[$short]=1; J_NAME[$short]=$name; J_SID[$short]=$jsid
    J_NSRC[$short]=$nsrc; J_RSID[$short]=$rsid
  done <<EOF
$out
EOF
}

scan_transcripts() {
  # Collects every project transcript and scans them in one pass. The current
  # session's own file is left unscanned so later checks on it always hit the
  # live file, not a stale snapshot.
  local files=() pdirx f
  for pdirx in "$HOME"/.claude/projects/*/; do
    for f in "$pdirx"*.jsonl; do
      [ -e "$f" ] || continue
      [ "$f" = "$tpath" ] && continue
      files+=("$f")
      T_SEEN[$f]=1
    done
  done
  [ ${#files[@]} -gt 0 ] || return 0
  scan_files "${files[@]}"
}

scan_files() {
  # $@ = transcript paths. One pass: uuid presence (one grep -l), mtimes (one
  # stat), display titles (one grep -H piped through awk+jq — awk wraps each
  # candidate line as {"f":file,"l":line} so a single jq can both filter out
  # message lines that merely contain the marker text and extract the title;
  # real title lines are short, so awk drops over-long matches early — they
  # are message lines jq would filter anyway). Also re-scans files that
  # settled after an in-flight write (settle_hot_files).
  local f ftype tval mt
  while IFS= read -r f; do
    [ -n "$f" ] && T_HASUUID[$f]=1
  done < <(grep -l '"uuid":"' "$@" 2>/dev/null)
  while read -r mt f; do
    [ -n "$f" ] && T_MTIME[$f]=$mt
  done < <(stat -c '%Y %n' "$@" 2>/dev/null)
  while IFS=$'\x1f' read -r f ftype tval; do
    [ -n "$f" ] || continue
    if [ "$ftype" = "custom-title" ]; then
      if [ -n "$tval" ]; then
        T_TITLE[$f]=$tval; T_HASCT[$f]=1
      else
        # An EMPTY custom-title reverts to the automatic title. The live
        # reader (file_title) falls back the same way; the cache must agree,
        # or retitle/sync would treat the file as having no title at all.
        # (A title line MISSING its field is a different case: the jq select
        # above drops it entirely, matching the live readers' "// empty" —
        # null is ignored, only a PRESENT empty string means revert.)
        unset "T_HASCT[$f]"
        T_TITLE[$f]=${T_AIT[$f]}
      fi
    else
      T_AIT[$f]=$tval
      if [ -z "${T_HASCT[$f]}" ]; then
        T_TITLE[$f]=$tval
      fi
    fi
  done < <(grep -H -E '"type":"(custom-title|ai-title)"' "$@" 2>/dev/null | awk 'length($0) < 4096 { i=index($0,":"); printf "{\"f\":\"%s\",\"l\":%s}\n", substr($0,1,i-1), substr($0,i+1) }' | jq -Rr --arg us $'\x1f' 'fromjson? | select((.l.type=="custom-title" and (.l.customTitle != null)) or (.l.type=="ai-title" and (.l.aiTitle != null))) | [.f, .l.type, (.l.customTitle // .l.aiTitle // "")] | map(tostring | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")) | join($us)')
}

settle_hot_files() {
  # In-flight writes are waited out rather than skipped. A daemon flush is a
  # sub-second burst that clusters around exactly the moments sweeps run —
  # the same keypress (view open, client exit) triggers both the writer and
  # the reader — so polling every 100ms catches the write's end almost
  # immediately and the marks still land on the first open. Each file settles
  # on its own: quiet for 3 consecutive polls = settled; changed on 5 polls =
  # a genuinely streaming session -> T_HOT at once, never marked this run. A
  # streaming session must not hold the poll loop, or every view open would
  # stall the full cap while any session is active. Settled files are
  # re-scanned so no torn read survives.
  local f hot=() i sz mtf name
  local -A sig=() quiet=() changes=() left=() seen=()
  for f in "${!T_SEEN[@]}"; do
    [ -n "${T_MTIME[$f]}" ] || continue
    [ $((NOW - T_MTIME[$f])) -lt 5 ] && hot+=("$f")
  done
  [ ${#hot[@]} -gt 0 ] || return 0
  while read -r sz mtf name; do
    [ -n "$name" ] || continue
    sig[$name]="$sz $mtf"; left[$name]=1
  done < <(stat -c '%s %.Y %n' "${hot[@]}" 2>/dev/null)
  for ((i = 0; i < 30; i++)); do
    [ ${#left[@]} -gt 0 ] || break
    sleep 0.1
    seen=()
    while read -r sz mtf name; do
      [ -n "$name" ] || continue
      seen[$name]=1
      [ -n "${left[$name]}" ] || continue
      if [ "${sig[$name]}" = "$sz $mtf" ]; then
        quiet[$name]=$(( ${quiet[$name]:-0} + 1 ))
        [ "${quiet[$name]}" -ge 3 ] && unset "left[$name]"
      else
        sig[$name]="$sz $mtf"; quiet[$name]=0
        changes[$name]=$(( ${changes[$name]:-0} + 1 ))
        if [ "${changes[$name]}" -ge 5 ]; then
          T_HOT[$name]=1; unset "left[$name]"
        fi
      fi
    done < <(stat -c '%s %.Y %n' "${hot[@]}" 2>/dev/null)
    for f in "${!left[@]}"; do
      # A file deleted mid-poll produces no stat line; nothing to wait for.
      [ -n "${seen[$f]}" ] || unset "left[$f]"
    done
  done
  # Cap hit with stragglers: intermittent writers that neither settled nor
  # crossed the change threshold — still being written, skip this run.
  for f in "${!left[@]}"; do T_HOT[$f]=1; done
  for f in "${hot[@]}"; do
    unset "T_HASUUID[$f]" "T_HASCT[$f]" "T_AIT[$f]" "LU_SEEN[$f]" "LU_VAL[$f]" "LR_SEEN[$f]" "LR_VAL[$f]"
    T_TITLE[$f]=
  done
  scan_files "${hot[@]}"
}

worker_live() {
  # $1 = session id. True only when a live worker process holds the session
  # open right now (conversation in memory).
  local k=${1:0:8}
  [ -n "${R_PID[$k]}" ] && pid_matches_start "${R_PID[$k]}" "${R_PST[$k]}"
}

job_alive() {
  # $1 = session id. True when the daemon can still serve the session: a live
  # worker pid, OR a roster entry whose launch-source transcript still exists —
  # the daemon respawns such rows on entry, so they are enterable even with a
  # dead pid and no own transcript. A daemon restart clears the roster; only
  # then does a transcript-less row become truly dead.
  local k=${1:0:8}
  worker_live "$1" && return 0
  [ -n "${R_LSRC[$k]}" ] && [ -e "${R_LSRC[$k]}" ]
}

has_uuids() {
  # $1 = transcript path. True when the file exists and holds real message
  # uuids. Cache-first; a file created after the scan is grepped live.
  [ -e "$1" ] || return 1
  # EXISTING but unreadable (permission damage): every scanner sees nothing
  # and "no transcript" would turn straight into a deletion-safe [Dead] on
  # the row — chmod moves no mtime, so no gate ever revisits it. Benefit
  # of the doubt: unreadable counts as real; every consumer fails toward
  # no-mark or heal in this direction.
  [ -r "$1" ] || return 0
  if [ -n "${T_SEEN[$1]}" ]; then
    [ -n "${T_HASUUID[$1]}" ]
    return
  fi
  grep -q '"uuid":"' "$1" 2>/dev/null
}

real_transcript_exists() {
  # $@ = glob matches for a session's transcript. True when any of them holds
  # real message uuids — checking only the first match would miss a session
  # whose transcript sits in a second project directory.
  local pf
  for pf in "$@"; do
    has_uuids "$pf" && return 0
  done
  return 1
}

set_job_marker() {
  # $1 = session id, $2 = marker ("" heals). Replaces any existing markers on
  # the job-registry name; no-op when the name already matches. Aborts when
  # the daemon rewrote the file mid-flight, so its newer state is not lost.
  local short="${1:0:8}" jfile="$HOME/.claude/jobs/${1:0:8}/state.json" jname jnew jtmp m1 m2 mark rowsid
  # Only session-shaped ids may touch a row: callers derive $1 from file
  # names, and a stray non-session file (a manual "<sid>-copy.jsonl"
  # backup) must never resolve to the REAL session's row via its first 8
  # characters and mark it.
  case "$1" in *[!0-9a-f-]*|"") return 1 ;; esac
  [ -f "$jfile" ] || return 1
  # A row serving ANOTHER session must not take a transcript-derived
  # verdict: after a row repair or an alien migration .sessionId no longer
  # matches the folder, so a verdict judged on the folder's OLD transcript
  # (those callers pass the transcript's full id) would land on a row —
  # possibly live — that serves someone else. Heals ("") stay
  # unrestricted, and row-own verdicts (8-char callers: the dead, dup and
  # provisional sweeps judged THIS row) are exempt.
  if [ -n "$2" ] && [ ${#1} -gt 8 ]; then
    if [ -n "${J_SEEN[$short]}" ]; then
      rowsid=${J_SID[$short]}
    else
      rowsid=$(jq -r '.sessionId // empty' "$jfile" 2>/dev/null) || rowsid=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq -r '.sessionId // empty' 2>/dev/null)
    fi
    if [ -n "$rowsid" ] && [ "$rowsid" != "$1" ]; then
      return 1
    fi
  fi
  # The staleness token is taken BEFORE the name is read (cached or live): a
  # token stat'd after the read would miss a daemon rename landing in the
  # gap, and the guarded write below would clobber it with the stale name.
  m1=$(stat -c '%.Y' "$jfile" 2>/dev/null)
  if [ -n "${J_SEEN[$short]}" ]; then
    jname="${J_NAME[$short]}"
  else
    jname=$(jq -r '.name // empty' "$jfile" 2>/dev/null) || jname=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq -r '.name // empty' 2>/dev/null)
  fi
  parse_markers "$jname"
  # The "←" left-press tag rides along on marker upgrades: a name already
  # tagged keeps the tag inside whatever marker replaces the old one; healing
  # ("" marker) drops it with everything else.
  mark="$2"
  if [ -n "$mark" ] && [ -n "$PM_ARROW" ]; then
    case "$mark" in "[←"*) ;; *) mark="[←${mark#\[}" ;; esac
  fi
  # A nameless job (failed bg handoff shells have no name) gets its short id
  # as the base, so several marked rows stay tellable apart.
  [ -z "$PM_BASE" ] && [ -n "$mark" ] && PM_BASE="${1:0:8}"
  jnew="$mark$PM_BASE"
  [ "$jnew" = "$jname" ] && return 0
  if [ -n "${J_SEEN[$short]}" ] && [ "$m1" != "${J_MTIMEF[$short]}" ]; then
    # The daemon rewrote the file after the cache was loaded; re-derive from
    # the file so its newer name is not clobbered by a stale cache entry.
    jname=$(jq -r '.name // empty' "$jfile" 2>/dev/null) || jname=$(sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq -r '.name // empty' 2>/dev/null)
    parse_markers "$jname"
    mark="$2"
    if [ -n "$mark" ] && [ -n "$PM_ARROW" ]; then
      case "$mark" in "[←"*) ;; *) mark="[←${mark#\[}" ;; esac
    fi
    [ -z "$PM_BASE" ] && [ -n "$mark" ] && PM_BASE="${1:0:8}"
    jnew="$mark$PM_BASE"
    [ "$jnew" = "$jname" ] && return 0
  fi
  jtmp="$jfile.tmp.$$"
  # Write-side lone-surrogate retry (see load_roster): jq 1.6 cannot rewrite
  # a file carrying the escape, and aborting forever would leave the row
  # permanently unmarkable. The retry strips the escapes, which the daemon
  # tolerates (its own parser accepts the file either way).
  if ! jq --arg n "$jnew" '.name = $n' "$jfile" > "$jtmp" 2>/dev/null \
    && ! sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq --arg n "$jnew" '.name = $n' > "$jtmp" 2>/dev/null; then
    rm -f "$jtmp"
    return 1
  fi
  # The redirection minted jtmp under the umask (0644 typically); the row
  # file is the daemon's and may be 0600 — the swap must not loosen it.
  chmod --reference="$jfile" "$jtmp" 2>/dev/null
  m2=$(stat -c '%.Y' "$jfile" 2>/dev/null)
  if [ "$m1" != "$m2" ]; then
    rm -f "$jtmp"
    return 1
  fi
  if mv "$jtmp" "$jfile"; then
    # J_MTIME is deliberately NOT refreshed: it stands for "last daemon
    # write" in the settle guards, and a row the dead sweep just marked must
    # still count as settled so repair can run in the same pass.
    J_SEEN[$short]=1; J_NAME[$short]="$jnew"
    J_MTIMEF[$short]=$(stat -c '%.Y' "$jfile" 2>/dev/null)
    DIRTY=1
  else
    rm -f "$jtmp"
  fi
}

repair_job_row() {
  # $1 = registry folder (short), $2 = new session id, $3 = that session's
  # transcript path, $4 = healed name. One atomic rewrite repointing a dead
  # shell row at the transcript its conversation survives in, with
  # set_job_marker's staleness guard: abort when the daemon rewrote the file
  # mid-flight (the next sweep retries).
  local short="$1" jfile="$HOME/.claude/jobs/$1/state.json" jtmp m1 m2
  [ -f "$jfile" ] || return 1
  m1=$(stat -c '%.Y' "$jfile" 2>/dev/null)
  if [ -n "${J_SEEN[$short]}" ] && [ "$m1" != "${J_MTIMEF[$short]}" ]; then
    return 1
  fi
  jtmp="$jfile.tmp.$$"
  if ! jq --arg s "$2" --arg p "$3" --arg n "$4" '.sessionId=$s | .resumeSessionId=$s | .linkScanPath=$p | .linkScanOffset=0 | .name=$n' "$jfile" > "$jtmp" 2>/dev/null \
    && ! sed 's/\\u[dD][89a-fA-F][0-9a-fA-F][0-9a-fA-F]//g' "$jfile" | jq --arg s "$2" --arg p "$3" --arg n "$4" '.sessionId=$s | .resumeSessionId=$s | .linkScanPath=$p | .linkScanOffset=0 | .name=$n' > "$jtmp" 2>/dev/null; then
    rm -f "$jtmp"
    return 1
  fi
  # Keep the daemon's file mode (see set_job_marker).
  chmod --reference="$jfile" "$jtmp" 2>/dev/null
  m2=$(stat -c '%.Y' "$jfile" 2>/dev/null)
  if [ "$m1" != "$m2" ]; then
    rm -f "$jtmp"
    return 1
  fi
  if mv "$jtmp" "$jfile"; then
    J_NAME[$short]="$4"; J_SID[$short]="$2"; J_RSID[$short]="$2"
    J_MTIMEF[$short]=$(stat -c '%.Y' "$jfile" 2>/dev/null)
    J_MTIME[$short]=$(stat -c '%Y' "$jfile" 2>/dev/null)
    DIRTY=1
  else
    rm -f "$jtmp"
  fi
}

append_custom_title() {
  # $1 = transcript path, $2 = new title. Appends a custom-title entry.
  # For a file idle over 60s the original mtime is restored afterwards:
  # bumping it would promote the file in recency ordering, which is what
  # "claude --continue" resumes by. A hot file (written within 60s, likely an
  # active session) is never backdated — stomping a concurrent write's mtime
  # backwards would hide the active session from --continue instead.
  local f="$1" fid mt mtY
  # Never recreate a file deleted since the scan: >> would mint a title-only
  # stub out of wreckage the user just removed.
  [ -f "$f" ] || return 1
  fid=${f##*/}; fid=${fid%.jsonl}
  read -r mtY mt < <(stat -c '%Y %y' "$f" 2>/dev/null)
  # A crash-torn file can end WITHOUT a newline on a line that is still
  # valid JSON; >> would glue the title onto it — corrupting that entry
  # for every line-based reader AND hiding the title from the scanners
  # (the mark would then never heal). Terminate the file first.
  [ -n "$(tail -c1 "$f" 2>/dev/null)" ] && printf '\n' >> "$f"
  jq -cn --arg t "$2" --arg s "$fid" '{type:"custom-title",customTitle:$t,sessionId:$s}' >> "$f" || return 1
  DIRTY=1
  DIRTY_T=1
  if [ -n "${T_SEEN[$f]}" ]; then
    T_TITLE[$f]="$2"; T_HASCT[$f]=1
  fi
  if [ -n "$mt" ] && [ -n "$mtY" ] && [ $((NOW - mtY)) -gt 60 ]; then
    touch -m -d "$mt" "$f"
  fi
}

file_title() {
  # Prints the display title of transcript $1: last custom-title, else ai-title.
  # Cache-first (filled by scan_transcripts); a file the scan did not cover is
  # read live — grep narrows the transcript to candidate lines before jq
  # parses them, and the select() drops message lines that merely contain the
  # marker text.
  if [ -n "${T_SEEN[$1]}" ]; then
    printf '%s' "${T_TITLE[$1]}"
    return
  fi
  local t
  # The same single-line flattening as the scan cache: a title holding a raw
  # newline would otherwise read as its LAST line here (tail -1) while the
  # cache reads the flattened whole — two different names for one file.
  t=$(grep -F '"type":"custom-title"' "$1" 2>/dev/null | jq -r 'select(.type=="custom-title") | .customTitle // empty | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")' 2>/dev/null | tail -1)
  if [ -z "$t" ]; then
    t=$(grep -F '"type":"ai-title"' "$1" 2>/dev/null | jq -r 'select(.type=="ai-title") | .aiTitle // empty | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")' 2>/dev/null | tail -1)
  fi
  printf '%s' "$t"
}

ai_title_of() {
  # Prints the last ai-title of transcript $1. The scan cache keeps only the
  # EFFECTIVE title (custom first); this live read is for the rare checks that
  # must know what the automatic name was — sync/rescue candidates and shells,
  # never bulk paths.
  grep -F '"type":"ai-title"' "$1" 2>/dev/null | jq -r 'select(.type=="ai-title") | .aiTitle // empty | gsub("[\\n\\r]"; " ") | gsub("\u001f"; " ")' 2>/dev/null | tail -1
}

tacsafe() {
  # tac on a file whose last line lacks a newline GLUES that line onto the
  # previous one ("a\nb" reverses to "ba"): the glued record is invalid
  # JSON, so the conversation-tail reader silently loses the newest one or
  # two entries — a crash-torn file then reads as a twin of a sibling it
  # has actually diverged from. sed '$a\' guarantees a final newline.
  # Fast path: plain tac on a seekable FILE streams from the end without
  # reading the rest — the property last_real_uuid's cost rests on — while
  # the sed pipe forces a full read into tac's buffer (measured 0.07s vs
  # 0.03s on a 12MB transcript). Only a file whose last byte is not a
  # newline (the torn case the guard exists for) pays the pipe.
  if [ -z "$(tail -c1 "$1" 2>/dev/null)" ]; then
    tac "$1" 2>/dev/null
    return
  fi
  sed -e '$a\' "$1" 2>/dev/null | tac
}

last_uuid() {
  # Prints the last message uuid of transcript $1. Memoized — title appends
  # add no uuid lines, so a cached value stays correct for the whole run.
  if [ -n "${LU_SEEN[$1]}" ]; then
    printf '%s' "${LU_VAL[$1]}"
    return
  fi
  local u
  # -m1 caps matching LINES, not matches: a line carrying a second nested
  # "uuid" key would print both and poison $u with an embedded newline.
  u=$(tacsafe "$1" | grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' | head -1)
  u=${u#'"uuid":"'}; u=${u%'"'}
  LU_SEEN[$1]=1; LU_VAL[$1]=$u
  printf '%s' "$u"
}

last_real_uuid() {
  # Prints the last CONVERSATION uuid of transcript $1: user/assistant entries
  # only, skipping the junk Claude Code also gives uuids to — attachments,
  # user entries holding only a system-reminder (rename notifications), and
  # "No response requested." assistant fillers. Fork copies gain such junk
  # without the conversation moving, so twin-vs-superseded verdicts compare
  # these, not the raw last uuid. Memoized, and reads from the file's END:
  # tac streams lines newest-first, jq --unbuffered emits the first match
  # immediately, and head -1 then kills the pipe — so the cost is the length
  # of the junk tail, not the file size (a full-file jq parse costs ~200ms on
  # a 10MB transcript; this stays sub-millisecond).
  if [ -n "${LR_SEEN[$1]}" ]; then
    printf '%s' "${LR_VAL[$1]}"
    return
  fi
  local u
  u=$(tacsafe "$1" | jq --unbuffered -Rr 'fromjson? | select(.type=="user" or .type=="assistant") | select(.uuid != null) | (.message.content | if type=="string" then . else (.[0].text // .[0].type // "") end) as $t | select(($t | startswith("<system-reminder>") | not) and ($t != "No response requested.")) | .uuid' 2>/dev/null | head -1)
  LR_SEEN[$1]=1; LR_VAL[$1]=$u
  printf '%s' "$u"
}

is_liveish() {
  # $1 = transcript path. True when the session has a live worker, or when
  # the file was still being streamed to after the settle wait (T_HOT). There
  # is no recency window for scanned files: settle_hot_files already waited
  # out any in-flight write, so a settled file is judged immediately and
  # marks land on the first open. A file outside the scan (only the current
  # session's own) keeps a 60s recency guard.
  local fid mt lk
  # The current session's own transcript is live BY DEFINITION — this hook is
  # running inside that session. The sweeps that write titles all skip $tpath
  # explicitly; this covers the judgment paths that keep the file as group
  # EVIDENCE but must never mark it (the copy-dup arms), honoring D6 at the
  # definition level.
  [ -n "$tpath" ] && [ "$1" = "$tpath" ] && return 0
  fid=${1##*/}; fid=${fid%.jsonl}
  worker_live "$fid" && return 0
  # The roster is keyed by the row FOLDER, which after a row repair (or an
  # odd migration) need not match the session id: a live worker whose launch
  # source is this transcript is serving it all the same.
  for lk in "${!R_LSRC[@]}"; do
    [ "${R_LSRC[$lk]}" = "$1" ] || continue
    worker_live "$lk" && return 0
  done
  if [ -n "${T_SEEN[$1]}" ]; then
    [ -n "${T_HOT[$1]}" ]
    return
  fi
  mt=$(stat -c %Y "$1" 2>/dev/null) || return 1
  [ $((NOW - mt)) -lt 60 ]
}

retitle() {
  # $1 = transcript path, $2 = marker ("" heals). Appends a custom-title with
  # any existing markers replaced; no-op when the title already matches.
  local f="$1" title new fid
  title=$(file_title "$f")
  [ -n "$title" ] || return 1
  parse_markers "$title"
  # Healing also drops a stale "- forked on ..." suffix: the session is no
  # longer superseded, so the fork annotation no longer applies.
  [ -z "$2" ] && PM_BASE=${PM_BASE%%$forksuf}
  # An empty base (the whole title was marker text) gets the short session id,
  # so the result never reads as a sweep mark and stays tellable apart.
  if [ -z "$PM_BASE" ]; then
    fid=${f##*/}; fid=${fid%.jsonl}
    PM_BASE=${fid:0:8}
  fi
  new="$2$PM_BASE"
  [ "$new" = "$title" ] && return 0
  append_custom_title "$f" "$new"
}

heal_if_marked() {
  # $1 = transcript path, $2 = session id. Strips any marker from the
  # transcript title and the job-registry name; leaves unmarked names alone.
  case "$(file_title "$1")" in
    "[Dup] "*|"[Dup?] "*|"[Old Fork] "*|"[Stub] "*|"[Dead] "*|"[←Dup] "*|"[←Dup?] "*|"[←Old Fork] "*|"[←Stub] "*|"[←Dead] "*)
      retitle "$1" ""
      set_job_marker "$2" ""
      return
      ;;
  esac
  # A provisional "[Dup?] " lives on the job row only (transcripts are never
  # retitled provisionally), so a clean title must not keep it alive.
  case "${J_NAME[${2:0:8}]}" in
    "[Dup?] "*|"[←Dup?] "*) set_job_marker "$2" "" ;;
  esac
}

roster_fork_source() {
  # Prints the parent transcript path when THIS session is a daemon resume-
  # fork per the roster — the authoritative fork direction. Requires the
  # launch to be a real fork of another session's transcript.
  local k=${sid:0:8} lsrc
  [ "${R_MODE[$k]}" = "resume" ] || return 1
  [ "${R_FORK[$k]}" = "true" ] || return 1
  lsrc=${R_LSRC[$k]}
  [ -n "$lsrc" ] || return 1
  case "$lsrc" in
    *"/$sid.jsonl") return 1 ;;
  esac
  printf '%s' "$lsrc"
}

find_parent() {
  # $1 = probe attempts. Fallback parent detection for in-process rollovers
  # (clear/compact) that never touch the roster; those callers retry, because
  # the copied history may be written a moment after session start. A plain
  # startup probes once so new sessions never wait on the sleep loop.
  # Prints the parent transcript path on success. Direction-blind by nature,
  # so the caller must not use it for resumes.
  [ -n "$tpath" ] || return 1
  local tries="$1" probe="" i pdir pfile
  for ((i = 0; i < tries; i++)); do
    [ "$i" -gt 0 ] && sleep 0.4
    if [ -e "$tpath" ]; then
      probe=$(grep -m1 -oE '"uuid":"[0-9a-f-]{36}"' "$tpath" | head -1 | grep -oE '[0-9a-f-]{36}')
      [ -n "$probe" ] && break
    fi
  done
  [ -n "$probe" ] || return 1
  pdir=${tpath%/*}
  # Parent = another file that also holds our first message uuid; forks copy
  # history, so several files may match — the true parent was written moments
  # before the fork, hence: newest match wins.
  pfile=$(grep -l "\"uuid\":\"$probe\"" "$pdir"/*.jsonl 2>/dev/null | grep -v -F "$tpath" | xargs -d '\n' -r ls -t 2>/dev/null | head -1)
  [ -n "$pfile" ] || return 1
  printf '%s' "$pfile"
}

rename_parent() {
  # $1 = parent transcript path. Prints the parent's new name on success.
  local pfile="$1" old_title new_title stamp
  old_title=$(file_title "$pfile")
  parse_markers "$old_title"
  old_title="$PM_BASE"
  # Strip an accumulated suffix from an earlier fork, so titles never grow
  # "- forked on A - forked on B" chains.
  old_title=${old_title%%$forksuf}
  stamp=$(date '+%H:%M %d.%m.%Y')
  if [ -z "$old_title" ]; then
    # Fallback base = the parent's short id, same convention as retitle: a
    # bare "forked on ..." phrase would survive the heal as a title that
    # reads human and is never recognized as this tool's own write, blocking
    # row-name sync on that transcript forever.
    old_title=${pfile##*/}; old_title=${old_title%.jsonl}; old_title=${old_title:0:8}
  fi
  new_title="[Old Fork] $old_title - forked on $stamp by ${sid:0:4}"
  append_custom_title "$pfile" "$new_title" || return 1
  printf '%s' "$new_title"
}

sweep_transcripts() {
  # Classify every transcript in every project.
  # - A file with a title but zero message uuids belongs to a session that
  #   never processed a prompt: while the daemon can still serve it, it is a
  #   healthy attachable fork (the conversation sits in the process; the file
  #   is written lazily) — heal any leftover mark. Once unservable it is a
  #   husk -> "[Stub] ".
  # - A real transcript wrongly marked "[Stub] " is healed.
  # - A real transcript marked "[Old Fork] " whose last CONVERSATION message
  #   no longer exists in any sibling has diverged past its fork — no longer
  #   superseded, healed back. Junk tails (entries minted in this file alone)
  #   are never grounds to heal.
  local pdirx f fid mt title last rlast pmax line mf mu g pats hcfiles rfiles mtitle
  for pdirx in "$HOME"/.claude/projects/*/; do
    # Content-driven checks (stub heals, bare tokens, divergence heals) are
    # skipped when nothing in the project was written since the last completed
    # sweep ($sm): their verdicts depend only on file contents, which the
    # previous sweep already judged. Time- and roster-driven husk logic below
    # still runs every sweep.
    pmax=0
    for f in "$pdirx"*.jsonl; do
      [ -e "$f" ] || continue
      mt=${T_MTIME[$f]}
      [ -n "$mt" ] || mt=$NOW
      [ "$mt" -gt "$pmax" ] && pmax=$mt
    done
    # A DELETION moves no surviving file's mtime, but it orphans tails: the
    # divergence heals below must run or a deleted keeper leaves a
    # deletion-safe mark on the ONLY remaining copy. The directory mtime
    # moves on create, delete and rename — fold it in (D8).
    mt=$(stat -c %Y "$pdirx" 2>/dev/null) && [ "$mt" -gt "$pmax" ] && pmax=$mt
    local -A HC_LAST=()
    hcfiles=()
    for f in "$pdirx"*.jsonl; do
      [ -e "$f" ] || continue
      [ "$f" = "$tpath" ] && continue
      fid=${f##*/}; fid=${fid%.jsonl}
      if has_uuids "$f"; then
        [ "$pmax" -lt "$sm" ] && continue
        title=$(file_title "$f")
        case "$title" in
          "[Stub] "*|"[←Stub] "*|"[Dead] "*|"[←Dead] "*)
            # [Stub]/[Dead] are both impossible on a transcript holding real
            # uuids: [Stub] means title-only husk, [Dead] is a ROW-only
            # verdict this tool never writes to titles — a [Dead]-prefixed
            # TITLE is inherited marker text (Claude Code seeds a fork's
            # ai-title from the marked row name it was launched from).
            retitle "$f" ""
            set_job_marker "$fid" ""
            ;;
          "[Old Fork]"|"[Stub]"|"[Dead]"|"[Dup]"|"[Dup?]"|"[←Old Fork]"|"[←Stub]"|"[←Dead]"|"[←Dup]"|"[←Dup?]")
            # The whole title is a bare marker token (inherited marker text on
            # a working session): replace it with the short id so it cannot be
            # mistaken for a sweep mark.
            retitle "$f" ""
            ;;
          "[Old Fork] "*|"[Dup] "*|"[Dup?] "*|"[←Old Fork] "*|"[←Dup] "*|"[←Dup?] "*)
            # Divergence heals are judged in one batched pass after the loop.
            last=$(last_uuid "$f")
            [ -n "$last" ] || continue
            HC_LAST[$f]=$last
            hcfiles+=("$f")
            ;;
        esac
        continue
      fi
      mt=${T_MTIME[$f]}
      [ -n "$mt" ] || mt=$(stat -c %Y "$f" 2>/dev/null) || continue
      [ $((NOW - mt)) -lt 60 ] && continue
      # Markers mean "safe to delete". A servable title-only session is a
      # working entry point and stays unmarked; only an unservable husk file
      # (would open empty) gets "[Stub] ". Job rows are the dead sweep's
      # domain — this sweep touches transcript titles only.
      # is_liveish too: a live worker rostered under ANOTHER folder can be
      # serving this transcript as its launch source (repaired/alien rows) —
      # such a husk is attachable and must not read [Stub].
      if job_alive "$fid" || is_liveish "$f"; then
        retitle "$f" ""
      else
        retitle "$f" "[Stub] "
      fi
    done
    # Batched divergence heals: ONE grep per project with every marked tail
    # as a pattern (-o prints just the matched tokens) instead of one
    # full-directory grep per marked file. A tail found in a sibling means
    # the conversation lives on — the mark stays.
    [ ${#hcfiles[@]} -gt 0 ] || continue
    pats=""
    for f in "${hcfiles[@]}"; do
      pats="$pats\"uuid\":\"${HC_LAST[$f]}\""$'\n'
    done
    local -A alive=()
    while IFS= read -r line; do
      mf=${line%%:*}
      mu=${line#*:}; mu=${mu#'"uuid":"'}; mu=${mu%'"'}
      [ -n "$mf" ] && [ -n "$mu" ] || continue
      # Only an UNMARKED holder keeps a mark alive (D15): a sibling that is
      # itself deletion-safe-marked is no keeper, and a set of copies
      # holding only each other's tails must heal — e.g. two marked copies
      # of one conversation whose unmarked keeper was deleted, sitting in
      # DIFFERENT title groups (an end-hook [Old Fork] next to a renamed
      # copy), where the copy sweep can never re-elect. The hook's own
      # live file counts as a keeper whatever its title says.
      if [ "$mf" != "$tpath" ]; then
        mtitle=$(file_title "$mf")
        parse_markers "$mtitle"
        [ "$PM_BASE" = "$mtitle" ] || continue
      fi
      alive[$mu]="${alive[$mu]}$mf"$'\n'
    done < <(printf '%s' "$pats" | grep -HoF -f /dev/stdin "$pdirx"*.jsonl 2>/dev/null)
    # An orphaned raw tail is re-judged on the conversation tail (a junk tail
    # — an entry minted in this file alone — is always orphaned, and healing
    # on one would re-mark and re-heal on every sweep). Only a conversation
    # tail no sibling holds means the session truly diverged -> heal.
    rfiles=()
    local -A HC_RLAST=()
    for f in "${hcfiles[@]}"; do
      last=${HC_LAST[$f]}
      g=${alive[$last]//"$f"$'\n'/}
      [ -n "$g" ] && continue
      rlast=$(last_real_uuid "$f")
      if [ -n "$rlast" ] && [ "$rlast" != "$last" ]; then
        HC_RLAST[$f]=$rlast
        rfiles+=("$f")
      else
        fid=${f##*/}; fid=${fid%.jsonl}
        retitle "$f" ""
        set_job_marker "$fid" ""
      fi
    done
    [ ${#rfiles[@]} -gt 0 ] || continue
    pats=""
    for f in "${rfiles[@]}"; do
      pats="$pats\"uuid\":\"${HC_RLAST[$f]}\""$'\n'
    done
    local -A ralive=()
    while IFS= read -r line; do
      mf=${line%%:*}
      mu=${line#*:}; mu=${mu#'"uuid":"'}; mu=${mu%'"'}
      [ -n "$mf" ] && [ -n "$mu" ] || continue
      # Same unmarked-holder rule as the raw-tail pass above (D15).
      if [ "$mf" != "$tpath" ]; then
        mtitle=$(file_title "$mf")
        parse_markers "$mtitle"
        [ "$PM_BASE" = "$mtitle" ] || continue
      fi
      ralive[$mu]="${ralive[$mu]}$mf"$'\n'
    done < <(printf '%s' "$pats" | grep -HoF -f /dev/stdin "$pdirx"*.jsonl 2>/dev/null)
    for f in "${rfiles[@]}"; do
      rlast=${HC_RLAST[$f]}
      g=${ralive[$rlast]//"$f"$'\n'/}
      [ -n "$g" ] && continue
      fid=${f##*/}; fid=${fid%.jsonl}
      retitle "$f" ""
      set_job_marker "$fid" ""
    done
  done
}

sweep_dups() {
  # Twin at-rest forks: two or more enterable fork shells resumed from the
  # SAME parent transcript, none of which has its own conversation yet, are
  # identical duplicates in the agents view. All but the newest get "[Dup] ";
  # the mark heals itself once a twin diverges, dies, or stands alone.
  # The parent is deliberately NOT marked: nothing has diverged, and it may
  # be the user's active window.
  local filtered parent short ts dups jname hpf htitle hmarked
  filtered=""
  for short in "${!R_MODE[@]}"; do
    [ "${R_MODE[$short]}" = "resume" ] || continue
    parent=${R_LSRC[$short]}
    # Sanitize before the live-bonus arithmetic below: a fractional or
    # malformed startedAt is an expansion error that aborts this loop and
    # silently drops the whole run's twin-dup verdicts.
    ts=${R_TS[$short]:-0}; ts=${ts%%.*}
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    [ -n "$parent" ] || continue
    if real_transcript_exists "$HOME"/.claude/projects/*/"$short"-????-????-????-????????????.jsonl; then continue; fi
    job_alive "$short" || continue
    # A twin with a live worker outranks any merely-respawnable husk when
    # choosing which twin keeps the unmarked name.
    if worker_live "$short"; then ts=$((ts + 10000000000000)); fi
    filtered="$filtered$parent"$'\t'"$short"$'\t'"$ts"$'\n'
  done
  # Newest per parent keeps its name; the rest are the duplicates.
  dups=$(printf '%s' "$filtered" | sort -t $'\t' -k1,1 -k3,3nr | awk -F '\t' '{ if ($1 == prev) print $2; prev = $1 }' | tr '\n' ' ')
  # An at-rest fork is also redundant when another job row already carries its
  # parent's conversation (a materialized copy containing the parent's last
  # message): entering the shell would only open an outdated re-fork.
  local pl rl jshort2 jsid2 pf
  while IFS=$'\t' read -r parent short ts; do
    [ -n "$parent" ] && [ -n "$short" ] || continue
    case " $dups " in
      *" $short "*) continue ;;
    esac
    [ -f "$parent" ] || continue
    pl=$(last_uuid "$parent")
    [ -n "$pl" ] || continue
    # Judge by the conversation tail when the raw tail is junk (the same
    # doctrine as the twin/supersede arms): junk minted on the parent AFTER
    # a carrier copied it would otherwise hide the redundancy forever.
    rl=$(last_real_uuid "$parent")
    [ -n "$rl" ] || rl=$pl
    for jshort2 in "${!J_SEEN[@]}"; do
      [ "$jshort2" = "$short" ] && continue
      jsid2=${J_SID[$jshort2]}
      [ -n "$jsid2" ] || continue
      for pf in "$HOME"/.claude/projects/*/"$jsid2".jsonl; do
        if [ -e "$pf" ] && { grep -qF "\"uuid\":\"$pl\"" "$pf" || { [ "$rl" != "$pl" ] && grep -qF "\"uuid\":\"$rl\"" "$pf"; }; }; then
          dups="$dups$short "
          break 2
        fi
      done
    done
  done <<EOF
$filtered
EOF
  # Same-target rows: several rows pointing at ONE conversation — a pointer
  # row whose resumeSessionId names another session, or an alien row whose
  # folder no longer matches its own session id after a fork migration — are
  # the same entry twice in the agents view; renaming or entering the extra
  # one acts on a ghost. The row that holds the live worker, else the row
  # that IS the session (folder matches the target id), else the newest,
  # keeps its name; the extra pointer/alien rows get "[Dup] ". Row-level
  # only: the shared transcript is the real conversation and is never marked
  # for this. The heal is the existing not-in-dups arm below: a pointer or
  # alien row never has a transcript under its own folder prefix.
  local jsid rsid tgt cls best tshort centry ebkey eckey eunm ets
  local -A tgt_rows=()
  for short in "${!J_SEEN[@]}"; do
    case "${J_NAME[$short]}" in
      "[Dead] "*|"[Stub] "*|"[←Dead] "*|"[←Stub] "*) continue ;;
    esac
    jsid=${J_SID[$short]}
    rsid=${J_RSID[$short]}
    tgt=$rsid
    [ -n "$tgt" ] || tgt=$jsid
    [ -n "$tgt" ] || continue
    if [ -n "$rsid" ] && [ "$rsid" != "$jsid" ]; then
      # A pointer row that has materialized its own transcript is a diverged
      # or copied conversation — sweep_copy_dups' domain, not a same-entry
      # duplicate.
      if [ -n "$jsid" ] && real_transcript_exists "$HOME"/.claude/projects/*/"$jsid".jsonl; then
        continue
      fi
      cls=extra
    elif [ -n "$jsid" ] && [ "$short" != "${jsid:0:8}" ]; then
      cls=extra
    else
      cls=native
    fi
    real_transcript_exists "$HOME"/.claude/projects/*/"$tgt".jsonl || continue
    tgt_rows[$tgt]="${tgt_rows[$tgt]}$short/$cls "
  done
  for tgt in "${!tgt_rows[@]}"; do
    set -- ${tgt_rows[$tgt]}
    [ $# -ge 2 ] || continue
    best=""
    for centry in "$@"; do
      tshort=${centry%/*}
      # Both keys: the roster is keyed by the row FOLDER, which after a row
      # repair no longer matches the session id — a repaired row's running
      # worker must still win the election or the live row gets [Dup].
      if worker_live "$tshort" || { [ -n "${J_SID[$tshort]}" ] && worker_live "${J_SID[$tshort]}"; }; then
        best=$tshort
        break
      fi
    done
    if [ -z "$best" ]; then
      for centry in "$@"; do
        [ "${centry#*/}" = "native" ] && { best=${centry%/*}; break; }
      done
    fi
    if [ -z "$best" ]; then
      # Rank only by inputs no sweep mutates: J_MTIME is bumped by this
      # tool's own marker writes, so electing by it swaps keeper and [Dup]
      # on alternating runs. Unmarked beats marked (keeps last run's verdict
      # stable), then roster startedAt (the first arm's ordering, so the two
      # arms never disagree), then the folder name.
      ebkey=""
      for centry in "$@"; do
        tshort=${centry%/*}
        parse_markers "${J_NAME[$tshort]}"
        if [ "$PM_BASE" = "${J_NAME[$tshort]}" ]; then eunm=1; else eunm=0; fi
        ets=${R_TS[$tshort]:-0}; ets=${ets%%.*}
        case "$ets" in ''|*[!0-9]*) ets=0 ;; esac
        eckey=$(printf '%d/%020d/%s' "$eunm" "$ets" "$tshort")
        if [ -z "$ebkey" ] || [[ "$eckey" > "$ebkey" ]]; then ebkey=$eckey; best=$tshort; fi
      done
    fi
    for centry in "$@"; do
      tshort=${centry%/*}
      [ "$tshort" = "$best" ] && continue
      # Only extra rows are markable; folder names are unique, so a second
      # native row cannot exist and the session's own row is never marked.
      [ "${centry#*/}" = "extra" ] || continue
      dups="$dups$tshort "
    done
  done
  for short in "${!J_SEEN[@]}"; do
    jname=${J_NAME[$short]}
    case " $dups " in
      *" $short "*)
        # Final safety net: a deletion-safe [Dup] never lands on a row whose
        # worker is live RIGHT NOW (either roster key) — e.g. two live
        # at-rest forks of one parent are redundant, but both stay unmarked
        # while they run. An already-marked row keeps its old verdict.
        if worker_live "$short" || { [ -n "${J_SID[$short]}" ] && worker_live "${J_SID[$short]}"; }; then
          :
        else
          set_job_marker "$short" "[Dup] "
        fi
        ;;
      *)
        case "$jname" in
          "[Dup] "*|"[←Dup] "*)
            if ! real_transcript_exists "$HOME"/.claude/projects/*/"$short"-????-????-????-????????????.jsonl; then
              # At-rest shell whose twin/carrier verdict no longer holds.
              set_job_marker "$short" ""
            else
              # Materialized row: its [Dup] echoed a same-title group verdict
              # on the transcript. When the transcript's effective title no
              # longer carries a marker (an in-session /rename, or a heal
              # whose row half aborted on a daemon race), that group is gone
              # — and no sweep ever revisits the row: the copy sweep only
              # judges groups of two or more same-title members. A row-level
              # [Dup] outliving its title verdict is healed here (D15).
              # EVERY copy is judged, not just the first glob match: the
              # session's transcript can sit in a second project directory,
              # and one marked copy means the verdict still stands there.
              hmarked=
              for hpf in "$HOME"/.claude/projects/*/"$short"-????-????-????-????????????.jsonl; do
                [ -e "$hpf" ] || continue
                has_uuids "$hpf" || continue
                htitle=$(file_title "$hpf")
                parse_markers "$htitle"
                [ "$PM_BASE" = "$htitle" ] || { hmarked=1; break; }
              done
              [ -z "$hmarked" ] && set_job_marker "$short" ""
            fi
            ;;
          "[Old Fork] "*|"[←Old Fork] "*)
            # Same stranded-row doctrine as the [Dup] arm above (D15):
            # every row [Old Fork] is written title-first (handle_fork,
            # the end hook, the copy sweep), so a row whose real
            # transcript's effective title carries NO marker has outlived
            # its verdict — an in-session /rename, or a heal whose row
            # half aborted on a daemon rewrite — and no other sweep ever
            # revisits it: the divergence heals judge titles, the dead
            # sweep heals only [Dead]. EVERY copy is judged; one marked
            # copy keeps the verdict. An at-rest row (no real transcript)
            # is the dead sweep's domain and keeps its mark here.
            if real_transcript_exists "$HOME"/.claude/projects/*/"$short"-????-????-????-????????????.jsonl; then
              hmarked=
              for hpf in "$HOME"/.claude/projects/*/"$short"-????-????-????-????????????.jsonl; do
                [ -e "$hpf" ] || continue
                has_uuids "$hpf" || continue
                htitle=$(file_title "$hpf")
                parse_markers "$htitle"
                [ "$PM_BASE" = "$htitle" ] || { hmarked=1; break; }
              done
              [ -z "$hmarked" ] && set_job_marker "$short" ""
            fi
            ;;
          "[Dup?] "*|"[←Dup?] "*)
            # Provisional rows: heal at-rest shells here; a materialized
            # [Dup?] belongs to provisional expiry — healing it here would
            # undo a same-run provisional mark (that sweep runs first).
            if ! real_transcript_exists "$HOME"/.claude/projects/*/"$short"-????-????-????-????????????.jsonl; then
              set_job_marker "$short" ""
            fi
            ;;
        esac
        ;;
    esac
  done
}

sweep_copy_dups() {
  # Materialized copies: a fork copies the whole conversation into a new file,
  # so several real transcripts can hold the same conversation (they share the
  # title and message uuids). Within each same-title group: a file whose tail
  # is contained in a longer sibling is superseded -> "[Old Fork] "; identical
  # twins keep one unmarked and the cold rest get "[Dup] ". Live/streaming
  # files (worker, or still being written after the settle wait) are never
  # marked.
  local pdirx f g title fl gl fid newest_cold newest_cold_key ctitle cunm ckey mt liveish_twin n gmax dmt
  for pdirx in "$HOME"/.claude/projects/*/; do
    # Deletion signal (D8): removing a group member moves no surviving
    # mtime, yet it can demand a re-election — a deleted keeper leaves every
    # remaining twin marked. The directory mtime is the only tell.
    dmt=$(stat -c %Y "$pdirx" 2>/dev/null) || dmt=0
    declare -A CD_GROUP=()
    for f in "$pdirx"*.jsonl; do
      [ -e "$f" ] || continue
      # Only session-shaped files join a group (see session_shaped): the
      # round-11 guard kept strays off ROWS, but a stray group member
      # could still outrank the real session in the election or the
      # containment matrix — it is out of judgment entirely now.
      fid=${f##*/}; fid=${fid%.jsonl}
      session_shaped "$fid" || continue
      has_uuids "$f" || continue
      title=$(file_title "$f")
      [ -n "$title" ] || continue
      parse_markers "$title"
      PM_BASE=${PM_BASE%%$forksuf}
      [ -n "$PM_BASE" ] || continue
      CD_GROUP[$PM_BASE]="${CD_GROUP[$PM_BASE]}$f"$'\n'
    done
    for title in "${!CD_GROUP[@]}"; do
      local files=()
      mapfile -t files <<< "${CD_GROUP[$title]}"
      n=0; gmax=0
      for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        mt=${T_MTIME[$f]}
        [ -n "$mt" ] || mt=$NOW
        [ "$mt" -gt "$gmax" ] && gmax=$mt
      done
      [ "$n" -ge 2 ] || continue
      # No member written since the last completed sweep AND no title write
      # this run: the verdicts are content-only and already landed — skip.
      # A title the run itself wrote (a heal, a synced or rescued name)
      # changes group membership without moving any mtime, so it must void
      # the skip like a disk write would.
      [ "$gmax" -lt "$sm" ] && [ "$dmt" -lt "$sm" ] && [ -z "$DIRTY_T" ] && continue
      # Containment matrix: ONE grep per file, fed every sibling raw tail as a
      # fixed pattern (-o prints just the matched uuid tokens, so multi-MB
      # message lines never hit the pipe) — n spawns instead of n^2 pairwise
      # greps, which dominated the sweep on real trees.
      local pats=""
      local -A tails=() contains=()
      for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        fl=$(last_uuid "$f")
        [ -n "$fl" ] || continue
        tails[$f]=$fl
        pats="$pats\"uuid\":\"$fl\""$'\n'
      done
      for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        while IFS= read -r gl; do
          gl=${gl#'"uuid":"'}; gl=${gl%'"'}
          [ -n "$gl" ] && contains[$f$'\x1f'$gl]=1
        done < <(printf '%s' "$pats" | grep -oF -f /dev/stdin "$f" 2>/dev/null)
      done
      local -A twinset=()
      for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        fl=${tails[$f]}
        [ -n "$fl" ] || continue
        local superseded="" mutual="" hit="" rf rg
        for g in "${files[@]}"; do
          [ -n "$g" ] && [ "$g" != "$f" ] || continue
          if [ -n "${contains[$g$'\x1f'$fl]}" ]; then
            hit=1
            gl=${tails[$g]}
            if [ -n "$gl" ] && [ -n "${contains[$f$'\x1f'$gl]}" ]; then
              mutual=1
            else
              # Raw uuids say g is ahead — but when g's extra entries are only
              # junk, the conversations are identical and this is a twin pair,
              # not a supersede: re-judge on conversation uuids.
              rf=$(last_real_uuid "$f")
              rg=$(last_real_uuid "$g")
              if [ -n "$rf" ] && [ -n "$rg" ] && grep -qF "\"uuid\":\"$rf\"" "$g" && grep -qF "\"uuid\":\"$rg\"" "$f"; then
                mutual=1
              else
                superseded=1
              fi
            fi
          fi
        done
        if [ -z "$hit" ]; then
          # The raw tail matched no sibling — but a junk tail (an entry minted
          # in this file alone) always looks that way, hiding both twinship
          # and a genuine supersede: retry the scan on the conversation tail.
          rf=$(last_real_uuid "$f")
          if [ -n "$rf" ] && [ "$rf" != "$fl" ]; then
            for g in "${files[@]}"; do
              [ -n "$g" ] && [ "$g" != "$f" ] || continue
              grep -qF "\"uuid\":\"$rf\"" "$g" || continue
              rg=$(last_real_uuid "$g")
              if [ -n "$rg" ] && grep -qF "\"uuid\":\"$rg\"" "$f"; then
                mutual=1
              else
                superseded=1
              fi
            done
          fi
        fi
        if [ -n "$superseded" ]; then
          if ! is_liveish "$f"; then
            fid=${f##*/}; fid=${fid%.jsonl}
            retitle "$f" "[Old Fork] " && set_job_marker "$fid" "[Old Fork] "
          fi
        elif [ -n "$mutual" ]; then
          twinset[$f]=1
        fi
      done
      # Identical twins: if any is live/hot it is the keeper and every cold
      # twin is redundant; among only-cold twins the newest keeps its name.
      # Supersede outranks twinship, so a superseded file is never in the set.
      [ ${#twinset[@]} -gt 0 ] || continue
      # Cold keeper: unmarked beats marked FIRST (keeps last run's verdict
      # stable — a [Dup] append on a file idle under 60s bumps its mtime on
      # disk, so ranking by mtime alone flips keeper and [Dup] on the next
      # run), then mtime, then the path as a fixed tiebreak. Same doctrine
      # as the row elections: never rank by an input our own writes mutate.
      liveish_twin=""; newest_cold=""; newest_cold_key=""
      for f in "${!twinset[@]}"; do
        if is_liveish "$f"; then
          liveish_twin=1
        else
          mt=${T_MTIME[$f]}
          [ -n "$mt" ] || mt=$(stat -c %Y "$f" 2>/dev/null) || mt=0
          ctitle=$(file_title "$f")
          parse_markers "$ctitle"
          if [ "$PM_BASE" = "$ctitle" ]; then cunm=1; else cunm=0; fi
          ckey=$(printf '%d/%020d/%s' "$cunm" "$mt" "$f")
          if [ -z "$newest_cold" ] || [[ "$ckey" > "$newest_cold_key" ]]; then
            newest_cold_key=$ckey; newest_cold="$f"
          fi
        fi
      done
      for f in "${!twinset[@]}"; do
        fid=${f##*/}; fid=${fid%.jsonl}
        if is_liveish "$f" || { [ -z "$liveish_twin" ] && [ "$f" = "$newest_cold" ]; }; then
          # The kept twin (live/hot, or the newest cold one) must not carry a
          # stale marker from a run where it was not the keeper — otherwise a
          # twin pair whose mtime order flipped ends up with BOTH marked.
          heal_if_marked "$f" "$fid"
          continue
        fi
        retitle "$f" "[Dup] " && set_job_marker "$fid" "[Dup] "
      done
    done
    unset CD_GROUP
  done
}

sweep_row_repair() {
  # A user-named row judged unservable ([Dead]/[Stub]) whose conversation
  # survives in a parent transcript is repaired instead of left as wreckage:
  # the row is repointed at the parent (sessionId, resumeSessionId,
  # linkScanPath) and its name healed, so the agents view gets its named,
  # enterable entry back. Verified live 2026-10-02: a repointed row respawns
  # and opens the parent conversation. Only user-named rows are repaired —
  # unnamed dead shells stay plain deletion candidates — and never when
  # another servable row already reaches the parent (that would mint a
  # same-target duplicate on purpose). Runs right after sweep_dead_jobs, so
  # a shell is judged and repaired in the same run. Content-only facts, so
  # an unchanged tree since the last completed sweep is skipped.
  local f short sid base mt pd pmax=0 cands="" pats="" line pf tgt title ptsid pmt pmark pkey eligible
  local -A C_BASE=() PARENT=() PARENT_KEY=() TGTS=()
  for f in "${!T_SEEN[@]}"; do
    mt=${T_MTIME[$f]}
    [ -n "$mt" ] && [ "$mt" -gt "$pmax" ] && pmax=$mt
  done
  for short in "${!J_SEEN[@]}"; do
    mt=${J_MTIME[$short]}
    [ -n "$mt" ] && [ "$mt" -gt "$pmax" ] && pmax=$mt
  done
  # Candidacy depends on job_alive, which the roster drives — its change
  # must void the skip like any content change.
  mt=$(stat -c %Y "$HOME/.claude/daemon/roster.json" 2>/dev/null) && [ "$mt" -gt "$pmax" ] && pmax=$mt
  # Directory mtimes too (D8): a DELETED row folder or transcript, or a
  # file moved in with an old mtime, changes candidacy and blockers with
  # no surviving file mtime moving. Costs at most a delayed-skip, never a
  # wrong write.
  for pd in "$HOME"/.claude/projects/*/ "$HOME/.claude/jobs/"; do
    mt=$(stat -c %Y "$pd" 2>/dev/null) || continue
    [ "$mt" -gt "$pmax" ] && pmax=$mt
  done
  # Every servable row's resume target; a parent someone already reaches is
  # never a repair target. Unservable rows do not count as reaching anything
  # (a dead pointer must not block its own repair).
  for short in "${!J_SEEN[@]}"; do
    case "${J_NAME[$short]}" in
      "[Dead] "*|"[←Dead] "*|"[Stub] "*|"[←Stub] "*) continue ;;
    esac
    tgt=${J_RSID[$short]}
    [ -n "$tgt" ] || tgt=${J_SID[$short]}
    [ -n "$tgt" ] && TGTS[$tgt]="${TGTS[$tgt]}$short "
  done
  for short in "${!J_SEEN[@]}"; do
    case "${J_NAME[$short]}" in
      "[Dead] "*|"[←Dead] "*|"[Stub] "*|"[←Stub] "*) ;;
      *) continue ;;
    esac
    [ "${J_NSRC[$short]}" = "user" ] || continue
    # Mirror the dead sweep's judgment at repair time: a freshly written row
    # may be mid-respawn, and a servable session may carry a stale [Dead]
    # mark the settle-guarded dead sweep has not healed yet — repointing
    # either would hijack a live row from the daemon.
    mt=${J_MTIME[$short]}
    [ -n "$mt" ] || continue
    [ $((NOW - mt)) -lt 300 ] && continue
    sid=${J_SID[$short]}
    [ -n "$sid" ] || continue
    # Check both keys: the roster is keyed by the row FOLDER, and after a
    # repair the folder no longer matches the session id.
    job_alive "$sid" && continue
    job_alive "$short" && continue
    real_transcript_exists "$HOME"/.claude/projects/*/"$sid".jsonl && continue
    parse_markers "${J_NAME[$short]}"
    [ -n "$PM_BASE" ] || continue
    [ "$PM_BASE" = "$short" ] && continue
    C_BASE[$short]=$PM_BASE
    cands="$cands$mt"$'\t'"$short"$'\n'
  done
  [ -n "$cands" ] || return 0
  # The verdict is not purely content-driven: a row BECOMES eligible by
  # aging past the 300s settle guard with no write at all. Skip the grep on
  # an unchanged tree only when no candidate crossed that line since the
  # last completed sweep.
  # DIRTY: a [Dead] mark THIS run mints a candidate the mtime gate cannot
  # see (J_MTIME keeps the daemon's write time by design).
  if [ "$pmax" -lt "$sm" ] && [ -z "$DIRTY" ]; then
    eligible=""
    while IFS=$'\t' read -r mt short; do
      [ -n "$short" ] || continue
      [ "$mt" -ge $((sm - 300)) ] && { eligible=1; break; }
    done <<< "$cands"
    if [ -z "$eligible" ]; then
      # A PARENT also becomes eligible with no write at all, by aging past
      # the hour-silence guard. Which transcript is a parent is unknown
      # until the grep below, so any transcript crossing the hour line
      # since the last completed sweep voids the skip.
      for f in "${!T_SEEN[@]}"; do
        mt=${T_MTIME[$f]}
        [ -n "$mt" ] || continue
        if [ "$mt" -le $((NOW - 3600)) ] && [ "$mt" -gt $((sm - 3600)) ]; then
          eligible=1
          break
        fi
      done
    fi
    [ -n "$eligible" ] || return 0
  fi
  # ONE grep over all projects resolves every candidate's parent at once,
  # exactly like the name rescue: the parent is the file holding the
  # continued-in record naming the candidate's session.
  for short in "${!C_BASE[@]}"; do
    pats="$pats\"continuedInSessionId\":\"${J_SID[$short]}\""$'\n'
  done
  while IFS= read -r line; do
    pf=${line%%:*}
    tgt=${line##*continuedInSessionId\":\"}; tgt=${tgt%\"}
    [ -n "$pf" ] && [ -n "$tgt" ] || continue
    # Fork copies carry the record too: an unmarked holder (the keeper of
    # its group) beats any merely newer, possibly superseded copy.
    mt=${T_MTIME[$pf]}; [ -n "$mt" ] || mt=0
    pmark=0
    title=$(file_title "$pf")
    parse_markers "$title"
    [ "$PM_BASE" = "$title" ] && pmark=1
    pkey=$(printf '%d/%020d' "$pmark" "$mt")
    if [ -z "${PARENT[$tgt]}" ] || [[ "$pkey" > "${PARENT_KEY[$tgt]}" ]]; then
      PARENT[$tgt]=$pf; PARENT_KEY[$tgt]=$pkey
    fi
  done < <(printf '%s' "$pats" | grep -HoF -f /dev/stdin "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null)
  # Newest candidate first: when two dead shells trace to one parent, the
  # freshest name wins the row and the older shell stays dead wreckage.
  while IFS=$'\t' read -r mt short; do
    [ -n "$short" ] || continue
    pf=${PARENT[${J_SID[$short]}]}
    [ -n "$pf" ] && [ -e "$pf" ] || continue
    [ "$pf" = "$tpath" ] && continue
    is_liveish "$pf" && continue
    # An hour of silence before repointing: an interactive CLI session held
    # open in a terminal has no row and no roster entry, and when idle it
    # looks exactly like a cold transcript — entering a row repointed at it
    # would resume it in a second process. Recent writes are the only tell.
    pmt=${T_MTIME[$pf]}; [ -n "$pmt" ] || pmt=0
    [ $((NOW - pmt)) -lt 3600 ] && continue
    has_uuids "$pf" || continue
    # Only an unmarked parent: a superseded copy or shell is never the live
    # end of the chain, and repointing at it would resurrect stale history.
    title=$(file_title "$pf")
    parse_markers "$title"
    [ "$PM_BASE" = "$title" ] || continue
    ptsid=${pf##*/}; ptsid=${ptsid%.jsonl}
    [ -n "${TGTS[$ptsid]}" ] && continue
    if repair_job_row "$short" "$ptsid" "$pf" "${C_BASE[$short]}"; then
      TGTS[$ptsid]="$short "
    fi
  done < <(printf '%s' "$cands" | sort -t $'\t' -k1,1nr)
}

sweep_name_sync() {
  # A rename made in the agents view lands on the JOB ROW only — the
  # transcript keeps its old title, so a fork migration or a dying row takes
  # the name to its grave while the conversation lives on under an automatic
  # title. This sweep copies every user-given row name (nameSource "user",
  # markers stripped) into the transcript that backs the row, as a normal
  # custom-title append. It never overwrites a name set from inside a
  # session: an existing custom title is only replaced when it is this
  # tool's own last write (recorded under fork-watch-name-sync/) or a mere
  # echo of the automatic ai-title (a heal or marker append carries no user
  # intent). A marked transcript keeps its verdict; the name lands on a
  # later run, once the mark heals.
  #
  # Several user-named rows can back ONE transcript (the twin-row bug this
  # tool exists for), and each row's write would count as "own last write"
  # to the other — two rows taking turns rewriting the title on every sweep.
  # So one deterministic winner is elected per transcript before anything is
  # written: the row whose OWN session the transcript is beats any shell or
  # pointer backing it, an unmarked row beats a marked one (a marked row is
  # the deletion-safe ghost), then the newest, then the larger folder name.
  local short base tfile pf title fid syncf marked own ets skey
  local -A S_BASE=() S_KEY=()
  for short in "${!J_SEEN[@]}"; do
    [ "${J_NSRC[$short]}" = "user" ] || continue
    parse_markers "${J_NAME[$short]}"
    base="$PM_BASE"
    [ -n "$base" ] || continue
    [ "$base" = "$short" ] && continue
    marked=1
    [ "$base" = "${J_NAME[$short]}" ] && marked=0
    # The backing transcript: the row's own session, else its resume target,
    # else the roster launch source (an at-rest shell whose conversation
    # still lives with the parent).
    tfile=""
    for pf in "$HOME"/.claude/projects/*/"${J_SID[$short]}".jsonl \
              "$HOME"/.claude/projects/*/"${J_RSID[$short]:-${J_SID[$short]}}".jsonl \
              "${R_LSRC[$short]}"; do
      [ -n "$pf" ] && [ -e "$pf" ] || continue
      has_uuids "$pf" && { tfile="$pf"; break; }
    done
    [ -n "$tfile" ] || continue
    fid=${tfile##*/}; fid=${fid%.jsonl}
    own=0
    [ "${J_SID[$short]}" = "$fid" ] && own=1
    # Rank only by inputs no sweep mutates: J_MTIME is bumped by this tool's
    # own marker writes, so the recency tier uses roster startedAt (0 when
    # absent) and falls through to the folder name, like the dup election.
    ets=${R_TS[$short]:-0}; ets=${ets%%.*}
    case "$ets" in ''|*[!0-9]*) ets=0 ;; esac
    skey=$(printf '%d/%d/%020d/%s' "$own" $((1 - marked)) "$ets" "$short")
    if [ -z "${S_BASE[$tfile]}" ] || [[ "$skey" > "${S_KEY[$tfile]}" ]]; then
      S_BASE[$tfile]=$base
      S_KEY[$tfile]=$skey
    fi
  done
  for tfile in "${!S_BASE[@]}"; do
    [ "$tfile" = "$tpath" ] && continue
    is_liveish "$tfile" && continue
    base=${S_BASE[$tfile]}
    title=$(file_title "$tfile")
    [ "$title" = "$base" ] && continue
    parse_markers "$title"
    [ "$PM_BASE" = "$title" ] || continue
    fid=${tfile##*/}; fid=${fid%.jsonl}
    syncf="$sync_dir/$fid"
    if [ -n "${T_HASCT[$tfile]}" ] && [ "$(cat "$syncf" 2>/dev/null)" != "$title" ]; then
      # Replaceable: an ai-title echo, or the short-id fallback retitle mints
      # for bare-token titles — a tool write that never reaches the sync
      # record, not an in-session rename.
      parse_markers "$(ai_title_of "$tfile")"
      [ "$PM_BASE" = "$title" ] || [ "$title" = "${fid:0:8}" ] || continue
    fi
    if append_custom_title "$tfile" "$base"; then
      mkdir -p "$sync_dir"
      printf '%s' "$base" > "$syncf"
      NAMES_LANDED=1
    fi
  done
}

sweep_name_rescue() {
  # A fork that dies before its first prompt strands the user's name on an
  # unservable shell — a judged title-only stub transcript, or a user-named
  # job row with no real transcript — while the conversation the name was
  # meant for sits one step up: in the parent transcript whose continued-in
  # record points at the shell. Donate the stranded base name to a parent
  # that has no user-set custom title; the newest donor wins. A donor custom
  # title that only echoes the shell's automatic ai-title is sweep residue,
  # not a user name, and is never donated. Content-only facts, so an
  # unchanged tree since the last completed sweep is skipped.
  local f short sid base mt pd pmax=0 donors="" pats="" line pf tgt title fid pmark pkey
  local -A D_BASE=() PARENT=() PARENT_KEY=()
  for f in "${!T_SEEN[@]}"; do
    mt=${T_MTIME[$f]}
    [ -n "$mt" ] && [ "$mt" -gt "$pmax" ] && pmax=$mt
  done
  for short in "${!J_SEEN[@]}"; do
    mt=${J_MTIME[$short]}
    [ -n "$mt" ] && [ "$mt" -gt "$pmax" ] && pmax=$mt
  done
  # Row donors depend on job_alive, which the roster drives — its change
  # must void the skip like any content change.
  mt=$(stat -c %Y "$HOME/.claude/daemon/roster.json" 2>/dev/null) && [ "$mt" -gt "$pmax" ] && pmax=$mt
  # Directory mtimes too (D8): deletions and old-mtime move-ins change
  # donor/parent facts with no file mtime moving (see sweep_row_repair).
  for pd in "$HOME"/.claude/projects/*/ "$HOME/.claude/jobs/"; do
    mt=$(stat -c %Y "$pd" 2>/dev/null) || continue
    [ "$mt" -gt "$pmax" ] && pmax=$mt
  done
  # DIRTY: a verdict THIS run (a [Stub] mark) can mint a donor without any
  # mtime moving — title appends restore idle mtimes on purpose.
  [ "$pmax" -lt "$sm" ] && [ -z "$DIRTY" ] && return 0
  # Shell donors: a marked title-only transcript whose custom-title base
  # differs from its ai-title base — that surplus is the user's name,
  # inherited from the row that minted the shell.
  for f in "${!T_SEEN[@]}"; do
    [ -n "${T_HASCT[$f]}" ] || continue
    [ -n "${T_HASUUID[$f]}" ] && continue
    [ -n "${T_HOT[$f]}" ] && continue
    parse_markers "${T_TITLE[$f]}"
    [ -n "$PM_BASE" ] || continue
    [ "$PM_BASE" = "${T_TITLE[$f]}" ] && continue
    sid=${f##*/}; sid=${sid%.jsonl}
    [ "$PM_BASE" = "${sid:0:8}" ] && continue
    base="$PM_BASE"
    parse_markers "$(ai_title_of "$f")"
    [ "$PM_BASE" = "$base" ] && continue
    D_BASE[$sid]=$base
    mt=${T_MTIME[$f]}; [ -n "$mt" ] || mt=0
    donors="$donors$mt"$'\t'"$sid"$'\n'
  done
  # Row donors: a user-named row whose session has no real transcript and is
  # no longer servable.
  for short in "${!J_SEEN[@]}"; do
    [ "${J_NSRC[$short]}" = "user" ] || continue
    sid=${J_SID[$short]}
    [ -n "$sid" ] || continue
    [ -n "${D_BASE[$sid]}" ] && continue
    real_transcript_exists "$HOME"/.claude/projects/*/"$sid".jsonl && continue
    job_alive "$sid" && continue
    # Folder key too: a live worker on a repaired/alien row keeps its name.
    job_alive "$short" && continue
    parse_markers "${J_NAME[$short]}"
    [ -n "$PM_BASE" ] || continue
    [ "$PM_BASE" = "$short" ] && continue
    D_BASE[$sid]=$PM_BASE
    mt=${J_MTIME[$short]}; [ -n "$mt" ] || mt=0
    donors="$donors$mt"$'\t'"$sid"$'\n'
  done
  [ -n "$donors" ] || return 0
  # ONE grep over all projects resolves every donor's parent at once: the
  # parent is the file holding the continued-in record naming the donor
  # (several files can carry it via fork copies — the newest wins, any of
  # them holds the conversation).
  for sid in "${!D_BASE[@]}"; do
    pats="$pats\"continuedInSessionId\":\"$sid\""$'\n'
  done
  while IFS= read -r line; do
    pf=${line%%:*}
    tgt=${line##*continuedInSessionId\":\"}; tgt=${tgt%\"}
    [ -n "$pf" ] && [ -n "${D_BASE[$tgt]}" ] || continue
    # Fork copies carry the record too: an unmarked holder (the keeper of
    # its group) beats any merely newer, possibly superseded copy.
    mt=${T_MTIME[$pf]}; [ -n "$mt" ] || mt=0
    pmark=0
    title=$(file_title "$pf")
    parse_markers "$title"
    [ "$PM_BASE" = "$title" ] && pmark=1
    pkey=$(printf '%d/%020d' "$pmark" "$mt")
    if [ -z "${PARENT[$tgt]}" ] || [[ "$pkey" > "${PARENT_KEY[$tgt]}" ]]; then
      PARENT[$tgt]=$pf; PARENT_KEY[$tgt]=$pkey
    fi
  done < <(printf '%s' "$pats" | grep -HoF -f /dev/stdin "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null)
  while IFS=$'\t' read -r mt sid; do
    [ -n "$sid" ] || continue
    pf=${PARENT[$sid]}
    [ -n "$pf" ] && [ -e "$pf" ] || continue
    [ "$pf" = "$tpath" ] && continue
    # Same live-target skip as sync and repair: a parent held open by a live
    # worker (idle, not just hot) is the session's own to name.
    is_liveish "$pf" && continue
    has_uuids "$pf" || continue
    base=${D_BASE[$sid]}
    title=$(file_title "$pf")
    [ "$title" = "$base" ] && continue
    parse_markers "$title"
    [ "$PM_BASE" = "$title" ] || continue
    fid=${pf##*/}; fid=${fid%.jsonl}
    if [ -n "${T_HASCT[$pf]}" ]; then
      # A dead shell only ever FILLS a name, never replaces one: donor
      # mtimes are bumped by this tool's own [Dead] marking, so "newer
      # donor" is an artifact, and a name synced from a living row must
      # always outrank wreckage. Only an echo of the automatic ai-title
      # (a heal or marker append) is replaceable.
      parse_markers "$(ai_title_of "$pf")"
      # The short-id fallback title is this tool's own unrecorded mint, not
      # an in-session rename — replaceable like an ai echo.
      [ "$PM_BASE" = "$title" ] || [ "$title" = "${fid:0:8}" ] || continue
    fi
    if append_custom_title "$pf" "$base"; then
      mkdir -p "$sync_dir"
      printf '%s' "$base" > "$sync_dir/$fid"
      NAMES_LANDED=1
    fi
  done < <(printf '%s' "$donors" | sort -t $'\t' -k1,1nr)
}

sweep_provisional_dups() {
  # Immediate provisional verdicts, written right after the caches load and
  # before the settle wait (~0.3s into the run instead of ~5s), so a fresh
  # fork's row shows its likely status in the agents view at once. Roster only:
  # a resume-fork spawned AFTER the last completed sweep ($sm) whose parent
  # transcript still exists is almost certainly a redundant shell -> "[Dup?] ".
  # The mark is NOT deletion-safe: the same run's content sweeps replace it
  # with a real verdict or heal it (shell keepers via sweep_dups' heal arm,
  # materialized keepers via heal_if_marked), and one that escaped both (a
  # fork that diverged before judgment) expires here on the next full sweep. The after-$sm gate keeps a healed keeper from being
  # re-marked on every run; the 120s cap bounds the flicker window when a
  # worker respawn refreshes startedAt.
  local short jname lsrc fresh ts pshort pmt
  for short in "${!J_SEEN[@]}"; do
    jname=${J_NAME[$short]}
    fresh=
    if [ "${R_MODE[$short]}" = "resume" ] && [ "${R_FORK[$short]}" = "true" ]; then
      lsrc=${R_LSRC[$short]}
      case "$lsrc" in
        *"/${J_SID[$short]}.jsonl") lsrc= ;;
      esac
      ts=${R_TS[$short]:-0}; ts=${ts%%.*}
      case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
      # Future bound: a startedAt ahead of the clock (a unit drift to µs/ns
      # epoch after a daemon format change) would read "fresh" on EVERY run —
      # the [Dup?] would re-land forever instead of expiring within the 120s
      # cap. Garbage freshness fails safe to "not fresh" (D9).
      if [ -n "$lsrc" ] && [ -e "$lsrc" ] \
        && [ "$ts" -gt $((sm * 1000)) ] \
        && [ "$ts" -lt $((NOW * 1000 + 60000)) ] \
        && [ $((NOW * 1000 - ts)) -lt 120000 ]; then
        fresh=1
      fi
    fi
    if [ -n "$fresh" ]; then
      parse_markers "$jname"
      # Only unmarked rows: a real verdict ("[Dup] ", "[Old Fork] ", ...) from
      # an earlier run must never be downgraded to a provisional one.
      if [ "$PM_BASE" = "$jname" ]; then
        # "←" left-press best guess: the parent was live around the mint (a
        # roster entry of its own — presence, not worker_live: a dead-pid
        # roster row still means recently live — or its transcript written
        # within 5 min before the mint). The fork backgrounded an ACTIVE
        # session, the ← ghost pattern, rather than resuming a cold one. A
        # fork of a session quit moments earlier is mistagged; display-only.
        pshort=${lsrc##*/}; pshort=${pshort%.jsonl}; pshort=${pshort:0:8}
        pmt=$(stat -c %Y "$lsrc" 2>/dev/null) || pmt=0
        if [ -n "${R_PID[$pshort]}" ] || [ "$pmt" -gt $((ts / 1000 - 300)) ]; then
          set_job_marker "$short" "[←Dup?] "
        else
          set_job_marker "$short" "[Dup?] "
        fi
      fi
    else
      case "$jname" in
        "[Dup?] "*|"[←Dup?] "*) set_job_marker "$short" "" ;;
      esac
    fi
  done
}

sweep_dead_jobs() {
  # A jobs-registry row whose session has no transcript in any project and no
  # live daemon worker can never be entered again ("no saved transcript") ->
  # "[Dead] ". A live worker keeps a transcript-less row healthy (attachable
  # fork shell), healing any wrong mark; "[Old Fork] " survives healing.
  # Rows whose transcript exists are the transcript sweep's domain and only
  # get a stray "[Dead] " healed. Nothing is deleted.
  local short jmt jsid jname healmark
  for short in "${!J_SEEN[@]}"; do
    # Settle guard: a freshly written job may still be spawning its worker.
    jmt=${J_MTIME[$short]}
    [ -n "$jmt" ] || continue
    [ $((NOW - jmt)) -lt 300 ] && continue
    jsid=${J_SID[$short]}
    [ -n "$jsid" ] || continue
    jname=${J_NAME[$short]}
    parse_markers "$jname"
    if [ -n "$PM_OLDFORK" ]; then healmark="[Old Fork] "; else healmark=""; fi
    # A title-only husk file does not count as a transcript: the row would
    # still open empty, so it is judged by servability like a missing file.
    # Marker writes target $short, the registry folder that is actually being
    # iterated — not a prefix of $jsid, which need not match the folder name.
    if real_transcript_exists "$HOME"/.claude/projects/*/"$jsid".jsonl; then
      case "$jname" in
        "[Dead] "*|"[←Dead] "*) set_job_marker "$short" "$healmark" ;;
      esac
      continue
    fi
    # Both roster keys: the roster is keyed by the row FOLDER, which after a
    # row repair (or an alien migration) need not match the session id — a
    # live worker under the folder key must keep the row off [Dead].
    if job_alive "$jsid" || job_alive "$short"; then
      case "$jname" in
        "[Dead] "*|"[Stub] "*|"[←Dead] "*|"[←Stub] "*) set_job_marker "$short" "$healmark" ;;
      esac
      continue
    fi
    set_job_marker "$short" "[Dead] "
  done
}

handle_fork() {
  # $1 = parent transcript path of a materialized fork. Marks and renames the
  # parent, then emits the systemMessage warning.
  local pfile="$1" pid renamed msg
  pid=${pfile##*/}; pid=${pid%.jsonl}
  # Title verdict FIRST, row only on success (the copy sweep's order): a
  # failed rename (read-only transcript) must not strand a row-level
  # [Old Fork] with no title verdict backing it — no heal revisits that.
  if renamed=$(rename_parent "$pfile"); then
    set_job_marker "$pid" "[Old Fork] "
    msg="FORK (source: ${src:-unknown}): NEW session file ${sid:0:8}... inherited the conversation from ${pid:0:8}... The old session was renamed to \"$renamed\" - this new session keeps the short name. The old file is a duplicate of this conversation; only its subagents/ folder holds anything unique."
  else
    msg="FORK (source: ${src:-unknown}): NEW session file ${sid:0:8}... inherited the conversation from ${pid:0:8}... (and its name, if set). The parent could not be renamed - run /rename to keep sessions tellable apart."
  fi
  jq -cn --arg m "$msg" '{systemMessage:$m}'
}

sweeps_current() {
  # The stamp proves a sweep ran; it does not prove nothing happened since.
  # Writes that can change a verdict void the skip: a roster change, a project
  # directory change (a transcript appeared, vanished or was renamed —
  # materialized fork copies arrive this way), or a write to a transcript or
  # job of a session with NO live worker (a daemon flush of an exited
  # session). Live sessions are exempt: a live row is never marked, the
  # daemon rewrites a running job's state.json every few seconds, and a live
  # transcript's growth cannot create containment that did not exist when the
  # file appeared (new files are caught by the directory mtime). Names are
  # read once at view open and the settle wait exists precisely so marks land
  # on the first open after a write ends: when in doubt, sweep.
  # Strict comparison: mtimes are whole seconds, so a write in the SAME
  # second as the stamp must count as newer — the cost is at most one
  # redundant sweep right after an eventful one.
  local mt f fid lk
  while read -r mt f; do
    [ -n "$f" ] || continue
    [ "$mt" -lt "$sm" ] && continue
    case "$f" in
      *.jsonl)
        [ "$f" = "$tpath" ] && continue
        fid=${f##*/}; fid=${fid%.jsonl}
        worker_live "$fid" && continue
        # A live worker under another roster key (repaired/alien row) writing
        # its launch-source transcript is a live session's own write too.
        for lk in "${!R_LSRC[@]}"; do
          [ "${R_LSRC[$lk]}" = "$f" ] && worker_live "$lk" && continue 2
        done
        ;;
      */state.json)
        fid=${f%/state.json}; fid=${fid##*/}
        worker_live "$fid" && continue
        ;;
    esac
    return 1
  done < <(stat -c '%Y %n' "$HOME"/.claude/projects/*/ "$HOME"/.claude/projects/*/*.jsonl "$HOME"/.claude/jobs/*/state.json "$HOME"/.claude/daemon/roster.json 2>/dev/null)
  return 0
}

# Sweeps run first: the agents view reads job names once at open, racing this
# hook — the marks must land before find_parent's probe wait. A sweep stamp
# under 30s old means another run just swept (the claude() wrapper sweeps
# right before opening the view, then the view's own SessionStart hook fires
# moments later): if nothing was written since, the marks are current and the
# sweeps and their scans are skipped — a sweep-only run then exits before
# even the roster load, while hook mode still loads the roster for the fork
# detection below. Any write since the stamp voids the skip.
sweep_stamp="$HOME/.claude/fork-watch-sweep-stamp"
sm=$(stat -c %Y "$sweep_stamp" 2>/dev/null) || sm=0
# A stamp AHEAD of the clock (the clock stepped back since it was written —
# a WSL resync after Windows sleep does this) would make every mtime read
# "before the last sweep": sweeps_current stays true and the content gates
# all skip, suppressing every mark until real time catches up. Fail safe to
# "never swept", the same doctrine as the provisional future bound (D9).
[ "$sm" -gt "$NOW" ] && sm=0
# The roster is loaded before the skip decision: sweeps_current needs
# worker_live for its live-session exemptions, and hook-mode fork detection
# needs it either way.
load_roster
# Permission probe for the projects tree (see PROJ_BAD above). The root
# first: unreadable there hides every project at once; then each project
# directory (listing needs read, stat/open inside needs search).
pbroot="$HOME/.claude/projects"
if [ -d "$pbroot" ] && { [ ! -r "$pbroot" ] || [ ! -x "$pbroot" ]; }; then
  PROJ_BAD=1
else
  for pbroot in "$pbroot"/*/; do
    [ -d "$pbroot" ] || continue
    { [ -r "$pbroot" ] && [ -x "$pbroot" ]; } || { PROJ_BAD=1; break; }
  done
fi
if [ -n "$ROSTER_BAD" ] || [ -n "$PROJ_BAD" ]; then
  # The roster exists but would not parse even with surrogates stripped (a
  # torn daemon write, a format change), or a project directory cannot be
  # entered. Either way the sweeps would judge against a world with every
  # worker dead or whole conversations invisible: [Dead] marks and row
  # repairs would hit LIVE sessions. Fail closed — no sweeps, no stamp; the
  # next run with a readable roster and traversable projects sweeps
  # normally. Hook-mode fork detection below stays: it degrades to the
  # uuid heuristic, which fails toward "no warning".
  :
elif [ $((NOW - sm)) -lt 30 ] && sweeps_current; then
  [ -n "$sweep_only" ] && exit 0
else
  load_jobs
  sweep_provisional_dups
  scan_transcripts
  settle_hot_files
  sweep_transcripts
  sweep_dead_jobs
  sweep_row_repair
  sweep_dups
  # Copy-dups are judged BEFORE the name sweeps: a landed name re-titles one
  # member of a same-title group, and renaming first would split the group
  # before judgment, silently losing the duplicate verdict (round-5
  # regression). Same-run heals (the transcript sweep, earlier) are what
  # DIRTY_T voids the group skip for.
  sweep_copy_dups
  sweep_name_sync
  sweep_name_rescue
  # A landed name can also JOIN a group (round 6): when the synced/rescued
  # title equals the title of another transcript holding the same
  # conversation, the two form a judgeable group the pass above never saw —
  # and no later run sees it either, because the append restored the idle
  # mtime and the group skip only yields when a group MEMBER is written. So
  # judge once more after the names. Safe where the round-5 reorder was not:
  # every verdict already landed, the renames only touched unmarked keepers,
  # and judgment is idempotent — this pass only adds verdicts for the new
  # membership (DIRTY_T is set by the very writes that require it).
  [ -n "$NAMES_LANDED" ] && sweep_copy_dups
  # Stamped with the run's NOW snapshot, not the finish time: every verdict
  # above was judged against NOW, so a later run's "since the stamp" checks
  # (the hour/settle crossing windows) must measure from the judgment time —
  # an end-time stamp would hide anything that crossed during the run.
  touch -m -d "@$NOW" "$sweep_stamp" 2>/dev/null
fi

[ -n "$sweep_only" ] && exit 0

if [ ! -e "$marker" ]; then
  if rsrc=$(roster_fork_source); then
    if [ -n "$tpath" ] && has_uuids "$tpath"; then
      # Materialized daemon fork: the roster names the parent authoritatively.
      [ -f "$rsrc" ] && handle_fork "$rsrc"
    else
      rshort=${rsrc##*/}
      msg="FORK (source: ${src:-unknown}): this session ${sid:0:8}... is a fresh fork shell resumed from ${rshort:0:8}... The conversation still lives with the parent; this shell copies it once a prompt is sent. Twin forks of the same parent are marked [Dup] in the agents view."
      jq -cn --arg m "$msg" '{systemMessage:$m}'
    fi
  elif [ "$src" != "resume" ]; then
    # uuid heuristic only for non-resume sources: on a resume it could pick
    # this session's own child and invert the fork direction.
    if [ "$src" = "clear" ] || [ "$src" = "compact" ]; then tries=5; else tries=1; fi
    if pfile=$(find_parent "$tries"); then
      handle_fork "$pfile"
    fi
  fi
fi
touch "$marker"
exit 0
