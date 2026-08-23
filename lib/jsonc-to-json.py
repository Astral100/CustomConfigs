#!/usr/bin/env python3
"""Convert JSONC (as Windows Terminal accepts it: // and /* */ comments,
trailing commas, optional BOM) to strict JSON on stdout.
Usage: jsonc-to-json.py <file>. Nonzero exit if the result still isn't valid JSON."""
import sys, json

src = open(sys.argv[1], encoding="utf-8-sig").read()
out = []
i, n = 0, len(src)
in_str = False
while i < n:
    c = src[i]
    if in_str:
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(src[i + 1]); i += 2; continue
        if c == '"':
            in_str = False
        i += 1; continue
    if c == '"':
        in_str = True; out.append(c); i += 1; continue
    if c == "/" and i + 1 < n and src[i + 1] == "/":
        while i < n and src[i] != "\n":
            i += 1
        continue
    if c == "/" and i + 1 < n and src[i + 1] == "*":
        i += 2
        while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
            i += 1
        i += 2; continue
    if c == ",":
        # Trailing comma: look ahead past whitespace/comments for ] or }
        j = i + 1
        while True:
            while j < n and src[j] in " \t\r\n":
                j += 1
            if j + 1 < n and src[j] == "/" and src[j + 1] == "/":
                while j < n and src[j] != "\n":
                    j += 1
                continue
            if j + 1 < n and src[j] == "/" and src[j + 1] == "*":
                j += 2
                while j + 1 < n and not (src[j] == "*" and src[j + 1] == "/"):
                    j += 1
                j += 2
                continue
            break
        if j < n and src[j] in "]}":
            i += 1; continue  # drop it
    out.append(c); i += 1

text = "".join(out)
json.loads(text)  # validate; raises (nonzero exit) if still broken
sys.stdout.write(text)
