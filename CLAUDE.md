# CustomConfigs — agent rules

Context and layout live in README.md — read it before changing anything.

- Direction of truth: live machine → `./save.sh` → repo. Never hand-edit the
  snapshot folders (`windows-terminal/`, `powershell/`, `bash/`, `wsl/`, `git/`,
  `claude/`) — change the live setting, then run `./save.sh`. Hand-edited files
  are only: `save.sh`, `restore.sh`, `lib/jsonc-to-json.py`, `README.md`, this file.
- Never store secrets: no `.credentials.json`, `hosts.yml`, SSH keys, or tokens.
  `save.sh` actively strips them — keep that safety net intact.
- `restore.sh` must stay interactive and conflict-aware: diff + prompt + backup
  before every overwrite. Do not add silent-overwrite or `--force` behavior.
- The Windows username is hardcoded as `Astral100`; scripts accept a `WIN_USER`
  env var override. Run both scripts from WSL.
