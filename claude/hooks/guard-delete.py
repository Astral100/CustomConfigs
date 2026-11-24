#!/usr/bin/env python3
"""PreToolUse hook: auto-allow deletes inside a `tmp` folder, ask for everything else."""
import json, os, re, shlex, sys

# A deleter counts only where a program name goes: start of a command (after a
# separator, newline or `$(`), optionally behind wrappers like sudo/xargs/env.
WRAPPER = r'(?:sudo|doas|xargs|exec|command|env|nohup|time|nice|timeout\s+(?:-\S+\s+)*\S+)'
DELETER = r'(?:\S*/)?(?:rm|rmdir|unlink|shred)(?=\s|$|[;&|)])'
DELETE_CMD = re.compile(
    # Quotes count as a command start too: in shell-run text (`bash -c 'rm x'`) they open a command.
    r'(?:^|[;&|(\n{`\'"]|\$\()\s*(?:' + WRAPPER + r'\s+(?:-\S+(?:\s+[^-\s]\S*)?\s+|\w+=\S*\s+)*)*' + DELETER
    + r'|-exec(?:dir)?\s+' + DELETER
    + r'|(?:^|[;&|(\n])\s*(?:sudo\s+)?(?:find\b[^;&|\n]*\s-delete\b|git\s+(?:-C\s+\S+\s+)?clean\b)',
    re.M,
)
# Specific enough to check in the raw text (they usually sit inside `python -c "..."`).
DELETE_API = re.compile(r'shutil\.rmtree|os\.(?:remove|unlink|rmdir)\(|Remove-Item')
# Commands whose quoted/heredoc text gets executed, so it must not be stripped.
RUNS_TEXT = re.compile(r'(?:^|[;&|(\s])(?:bash|sh|zsh|dash|ksh|eval|ssh|su)(?=\s|$)', re.M)
HEREDOC = re.compile(r'<<-?\s*([\'"]?)([A-Za-z_]\w*)\1[^\n]*\n(.*?)^\s*\2\s*$', re.S | re.M)
SIMPLE_DELETERS = {"rm", "rmdir", "unlink"}


def strip_quotes(s):
    """Blank out quoted text, keeping `$(...)`/backticks inside double quotes."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            out.append(s[i:i + 2]); i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            out.append("''"); i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            body = s[i + 1:j]
            out.append(f'"{body}"' if "$(" in body or "`" in body else '""'); i = j + 1
        else:
            out.append(c); i += 1
    return "".join(out)


def code_text(cmd):
    """The command with message text (heredoc bodies, quoted strings) removed."""
    stripped = strip_quotes(HEREDOC.sub("", cmd))
    # A shell/eval/ssh in the code itself may execute the stripped text: judge all of it.
    return cmd if RUNS_TEXT.search(stripped) else stripped


def is_delete(cmd):
    return bool(DELETE_CMD.search(code_text(cmd)) or DELETE_API.search(cmd))


def decide(decision, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


# Folder names that mark temp space anywhere in a path (case-insensitive).
# Claude Code's scratchpad lives at /tmp/claude-<uid>/<project>/<session>/scratchpad.
TEMP_NAMES = {"tmp", "temp", ".tmp", "scratchpad"}

# System temp roots: anything inside is fine, but never wipe the root itself.
SYSTEM_TEMP_ROOTS = {os.path.realpath(p) for p in ("/tmp", "/var/tmp", os.environ.get("TMPDIR") or "/tmp")}


def inside_tmp(path, cwd):
    real = os.path.realpath(os.path.join(cwd, os.path.expanduser(path)))
    if real in SYSTEM_TEMP_ROOTS:
        return False
    if any(real.startswith(root + os.sep) for root in SYSTEM_TEMP_ROOTS):
        return True
    return any(part.lower() in TEMP_NAMES for part in real.split(os.sep))


data = json.load(sys.stdin)
cmd = data.get("tool_input", {}).get("command", "")
cwd = data.get("cwd") or os.getcwd()

if not is_delete(cmd):
    sys.exit(0)  # not a delete: normal permission flow

ask = lambda why: decide("ask", f"Delete needs approval ({why}): {cmd}")

# Anything we can't reason about statically goes to the user.
if re.search(r'[;&|`$<>\n(){}]', cmd):
    ask("compound command, variable or redirect")
try:
    tokens = shlex.split(cmd)
except ValueError:
    ask("could not parse")
if not tokens or os.path.basename(tokens[0]) not in SIMPLE_DELETERS:
    ask("not a plain rm/rmdir/unlink")

paths, end_of_flags = [], False
for t in tokens[1:]:
    if not end_of_flags and t == "--":
        end_of_flags = True
    elif not end_of_flags and t.startswith("-"):
        continue
    else:
        paths.append(t)

if not paths:
    ask("no target paths")
outside = [p for p in paths if not inside_tmp(p, cwd)]
if outside:
    ask("outside tmp: " + ", ".join(outside))
decide("allow", "All delete targets are inside a tmp folder")
