<!--
  README for sync-watcher
  Replace all <PLACEHOLDER> values (marked clearly) with your real project data,
  e.g. GitHub org/repo, author name, license year, and contact details.
-->

<div align="center">

# 🔄 sync-watcher

**A production-grade, one-way filesystem synchronization daemon for Linux.**

Watches a source directory and mirrors every change into a target directory in real time — safely, reliably, and with zero wasted work.

<!-- Badges: replace <OWNER>/<REPO> with your GitHub path -->
[![Shell](https://img.shields.io/badge/shell-Bash%204%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=gnu)](https://www.shellcheck.net/)
[![Platform](https://img.shields.io/badge/platform-Linux-blue?logo=linux&logoColor=white)](#prerequisites)
[![License](https://img.shields.io/badge/license-MIT-informational)](#license)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg)](#contributing)

</div>

---

## Table of Contents

- [Overview](#overview)
- [Why sync-watcher?](#why-sync-watcher)
- [Features](#features)
- [How It Works (Architecture)](#how-it-works-architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Ignoring Files (`.syncignore`)](#ignoring-files-syncignore)
- [Usage](#usage)
- [Examples](#examples)
- [Project Structure](#project-structure)
- [Development Workflow](#development-workflow)
- [Testing](#testing)
- [Deployment](#deployment)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Overview

**sync-watcher** is a single, self-contained Bash script that continuously watches a
**source** directory for filesystem events and mirrors those changes into a **target**
directory using [`rsync`](https://rsync.samba.org/). It is designed for scenarios where
you need a target location to always reflect the exact state of a source location — for
example, keeping a live backup, feeding a build/deploy directory, or replicating a working
tree to a mounted volume.

Synchronization is **strictly one-way**:

```
        SOURCE  ───────────────▶  TARGET
     (source of truth)          (mirror / replica)
```

Changes made *directly* inside the target — creating, editing, or deleting files — are
**never** propagated back to the source. On the next detected event they are reconciled
away so the target once again matches the source exactly. **The source always wins.**

> [!NOTE]
> This project targets **Linux** because it relies on the kernel's `inotify` subsystem via
> `inotifywait`. See [Prerequisites](#prerequisites) for platform notes.

---

## Why sync-watcher?

Naïve sync scripts commonly suffer from a handful of well-known problems. sync-watcher was
built specifically to avoid them:

| Common problem                                            | How sync-watcher solves it                                              |
| --------------------------------------------------------- | ----------------------------------------------------------------------- |
| Polling wastes CPU and adds latency                       | Event-driven via `inotifywait` — rsync runs **only** on a real event    |
| Multiple copies of the script clobber each other          | Robust single-instance guard using `flock` (kernel-managed lock)        |
| Stale PID/lock files after a crash                        | `flock` locks auto-release on process death — no stale-PID problem      |
| Lock/temp files left behind on unexpected exit            | Guaranteed cleanup via `trap` on `EXIT`/`INT`/`TERM`/`HUP`              |
| Accidental two-way sync corrupts the source               | Enforced one-way semantics + guards against `SOURCE == TARGET`/nesting  |
| Hard-coded paths break in containers or for other users   | Paths stored in auto-created config files; prompts if missing/invalid   |
| Silent failures from unquoted variables                   | `set -euo pipefail`, hardened `IFS`, and **ShellCheck-clean** code      |

---

## Features

- ✅ **Real-time, event-driven sync** — reacts instantly to `create`, `modify`, `delete`, `move`, and `attrib` events; never polls.
- ✅ **Strictly one-way** — target is an exact mirror of source; target-side edits never flow back.
- ✅ **Single-instance execution** — `flock`-based lock prevents concurrent runs; a second launch exits gracefully with a clear message.
- ✅ **Self-healing configuration** — config files are created automatically; invalid/missing paths trigger an interactive prompt and are saved back.
- ✅ **`.syncignore` exclusions** — gitignore-style ignore rules, applied consistently to the initial sync, every incremental sync, **and** the file watcher; ignored directories are pruned from the watch tree for efficiency.
- ✅ **Safe by default** — refuses to run if source and target are identical or nested, preventing destructive/recursive copies.
- ✅ **Robust cleanup** — `trap` guarantees lock release on any exit path.
- ✅ **Dependency pre-flight checks** — verifies `rsync`, `inotifywait`, and `flock` are installed before starting, with install hints.
- ✅ **Structured logging** — timestamped, level-tagged (`INFO`/`WARN`/`ERROR`) messages on `stderr`.
- ✅ **Efficient incremental transfers** — uses `rsync -a --delete --partial` for fast, faithful mirroring.
- ✅ **ShellCheck-clean & tested** — passes `bash -n` and ShellCheck with zero warnings.

---

## How It Works (Architecture)

sync-watcher is organized into small, single-purpose functions. The high-level flow is:

```
                     ┌──────────────────────────────────────────┐
                     │                  main()                   │
                     └──────────────────────────────────────────┘
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                               ▼                                ▼
 check_dependencies()           acquire_lock()               resolve_directory()  ×2
 (rsync/inotifywait/flock)   (flock -n on LOCK_FD)      (load → validate → prompt → save)
        │                               │                                │
        └───────────────────────────────┴───────────────────────────────┘
                                        │
                             assert_distinct_paths()
                                        │
                                        ▼
                               start_watcher()
                                        │
                    ┌───────────────────┴────────────────────┐
                    ▼                                         ▼
              run_sync()  (initial)              while inotifywait ...; do run_sync(); done
                                                              │
                                                              ▼
                                              rsync -a --delete SOURCE/ TARGET/
```

### Key design decisions

| Decision                                       | Rationale                                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `#!/usr/bin/env bash` + `set -euo pipefail`    | Fail fast; portable interpreter lookup.                                                   |
| `IFS=$'\n\t'`                                  | Prevents accidental word-splitting on spaces in paths.                                    |
| `flock` on a dedicated file descriptor         | Kernel-managed exclusive lock; auto-released on death (no stale locks).                   |
| All logs to `stderr`                           | Functions return values via `stdout` (`$(...)`); keeping logs on `stderr` avoids corrupting captured return values. |
| `rsync SOURCE/ TARGET/` **with** `--delete`    | Trailing slash copies *contents*; `--delete` makes target an exact mirror (one-way).      |
| Sync only inside the `inotifywait` loop        | No timers/polling → no unnecessary synchronizations.                                      |
| `trap cleanup EXIT` + signal traps             | Guarantees lock/temp cleanup on every exit path.                                          |

> [!IMPORTANT]
> The trailing slash on `SOURCE/` is intentional and load-bearing. It tells rsync to copy the
> **contents** of the source into the target, rather than nesting the source directory itself
> inside the target.

---

## Prerequisites

| Requirement       | Notes                                                                 |
| ----------------- | --------------------------------------------------------------------- |
| **OS**            | Linux (uses the `inotify` kernel subsystem).                          |
| **Bash**          | Version 4+ (uses arrays, `[[ ]]`, and other Bash features).           |
| **`rsync`**       | The transfer engine.                                                  |
| **`inotifywait`** | Provided by the `inotify-tools` package.                              |
| **`flock`**       | Provided by `util-linux` (present on virtually all Linux distros).    |

Install the runtime dependencies:

```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y rsync inotify-tools util-linux

# Fedora / RHEL / CentOS
sudo dnf install -y rsync inotify-tools util-linux

# Arch Linux
sudo pacman -S --needed rsync inotify-tools util-linux
```

> [!NOTE]
> **macOS / Windows:** `inotify` is Linux-specific. On macOS, consider `fswatch`; on Windows,
> use **WSL2** (a Linux environment) to run this script unchanged. Native macOS/Windows support
> is out of scope. *(Placeholder: remove or adapt if you add cross-platform support.)*

---

## Installation

```bash
# 1. Clone the repository  (replace <OWNER>/<REPO> with your GitHub path)
git clone https://github.com/<OWNER>/<REPO>.git
cd <REPO>

# 2. Make the script executable
chmod +x sync-watcher.sh

# 3. (Optional) Install it onto your PATH
sudo install -m 0755 sync-watcher.sh /usr/local/bin/sync-watcher
```

After the optional step you can invoke it simply as `sync-watcher`.

---

## Configuration

sync-watcher stores the source and target paths in two plain-text config files in your home
directory (one path per file). They are **created automatically** on first run.

| File                              | Purpose                          |
| --------------------------------- | -------------------------------- |
| `~/.sync-watcher.source.path`     | Absolute path of the **source**. |
| `~/.sync-watcher.target.path`     | Absolute path of the **target**. |
| `~/.syncignore`                   | Optional gitignore-style exclude rules — see [Ignoring Files](#ignoring-files-syncignore). |

**Resolution logic for each path:**

1. Read the path from its config file (whitespace is trimmed).
2. If it is a valid, existing directory → use it.
3. Otherwise → prompt interactively (a leading `~` is expanded) until a valid directory is entered.
4. Save the validated path back to the config file for next time.

You can pre-seed the config non-interactively (useful for automation):

```bash
echo "/path/to/source" > ~/.sync-watcher.source.path
echo "/path/to/target" > ~/.sync-watcher.target.path
```

### Tunable constants

These live near the top of `sync-watcher.sh` and can be edited to taste:

| Constant          | Default                                   | Description                                   |
| ----------------- | ----------------------------------------- | --------------------------------------------- |
| `PROCESS_NAME`    | `sync-watcher`                            | Process/lock identity.                        |
| `INOTIFY_EVENTS`  | `modify,create,delete,move,attrib`        | Events that trigger a sync.                   |
| `RSYNC_OPTS`      | `-a --delete -h --partial`                | rsync behavior (archive + mirror).            |
| `LOCK_FILE`       | `$XDG_RUNTIME_DIR` or `$HOME`             | Location of the flock lock file.              |
| `SYNCIGNORE_FILE` | `~/.syncignore`                           | Location of the ignore-rules file.            |

---

## Ignoring Files (`.syncignore`)

You can exclude files and directories from synchronization with a
**`.syncignore`** file located at:

```text
$HOME/.syncignore
```

The syntax closely follows **`.gitignore`** semantics. The file is **optional** —
if it does not exist, everything under the source is synchronized (fully backward
compatible).

> [!IMPORTANT]
> Ignore rules are applied **consistently everywhere**: the initial sync at
> startup, every incremental sync, and the file watcher itself. The watcher will
> not even wake up for events on ignored files, and large ignored directories are
> pruned from the watch tree entirely (see [How it works](#how-it-works-internally)).

### Example `.syncignore`

```gitignore
# Comments start with '#'. Blank lines are ignored.

# Ignore version-control and build/dependency directories (root-anchored)
/.git
/target
/node_modules

# Ignore all compressed archives, at any depth
**/*.tar.gz

# Ignore all log files, anywhere
*.log

# Ignore environment files
.env

# ...but keep this one specific log (negation / re-include)
!important.log
```

### Supported pattern syntax

| Pattern            | Meaning                                                                                     | Example matches                          |
| ------------------ | ------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `name`             | Matches a file or directory named `name` **at any depth**.                                  | `.env`, `src/.env`                       |
| `*.ext`            | Matches any file ending in `.ext` at any depth (`*` does **not** cross `/`).                 | `a.log`, `src/b.log`                     |
| `**/pattern`       | `**` matches across directory boundaries (any depth).                                       | `**/*.tar.gz` → `x.tar.gz`, `d/x.tar.gz` |
| `/name`            | **Leading slash** anchors to the source root only.                                          | `/target` → top-level `target/` only     |
| `name/`            | **Trailing slash** matches directories only.                                                | `build/`                                 |
| `?`                | Matches exactly one non-`/` character.                                                      | `file?.txt` → `file1.txt`                |
| `# comment`        | A line beginning with `#` is a comment.                                                     | —                                        |
| `!pattern`         | **Negation** — re-include a path that an earlier pattern excluded.                          | `!important.log`                         |

### Example use cases

| Goal                                                | Rules                                        |
| --------------------------------------------------- | -------------------------------------------- |
| Skip Node.js dependencies                           | `/node_modules`                              |
| Skip Rust/Java build output                         | `/target`                                    |
| Never copy secrets                                  | `.env`<br>`*.pem`<br>`**/secrets/*`          |
| Skip logs but keep one audit log                    | `*.log`<br>`!audit.log`                      |
| Skip all archives regardless of location            | `**/*.tar.gz`<br>`**/*.zip`                  |
| Skip a VCS directory and avoid watching it          | `/.git`                                      |

### How it works internally

On startup (after the source directory is known) sync-watcher reads
`~/.syncignore` once and translates it into two consistent representations, both
derived from the *same* source of truth:

1. **An rsync filter file** (`--exclude-from`). rsync's own C filter engine
   performs the matching during its directory scan, so it is fast and — for
   root-anchored directories — it **prunes the entire subtree** (emitted as the
   rsync `/<dir>/***` idiom), never descending into it.
2. **An `inotifywait` filter**. Root-anchored ignored directories are excluded
   from the watch tree via `@<path>`, which prevents an inotify watch from being
   allocated at all — the only mechanism that actually reduces the kernel watch
   count and helps avoid the `fs.inotify.max_user_watches` limit. A POSIX ERE
   `--exclude` regex, built from the same patterns, filters out events for
   ignored files at any depth so the watcher never triggers a needless sync.

> [!NOTE]
> The `.syncignore` file is read **once at startup**. If you edit it, restart
> sync-watcher for the changes to take effect.

### Known limitations

sync-watcher implements a **pragmatic subset** of gitignore semantics via rsync's
filter engine. Be aware of the following:

- **Match-order semantics differ.** Git uses “last match wins”; rsync uses “first
  match wins.” To make negation (`!`) behave intuitively, all `!` rules are
  emitted **before** the excludes they override. Complex, deeply-nested negation
  stacks may not translate perfectly.
- **No per-subdirectory ignore cascade.** Only the single `~/.syncignore` file is
  read; nested `.gitignore`/`.syncignore` files inside the tree are not honored.
- **No global excludes file** (git's `core.excludesFile`) is consulted.
- **`@<path>` pruning applies to directories that exist at startup.** A
  root-anchored ignored directory created *after* startup is still excluded from
  the transfer by rsync, but is not pruned from the watch tree until the next
  restart.
- **Edits require a restart** (the file is parsed once at startup).

---

## Usage

```bash
# Run in the foreground (logs stream to your terminal via stderr)
./sync-watcher.sh
```

On first launch it will prompt for the source and target directories if they are not yet
configured, then perform an initial sync and begin watching.

```text
Usage: ./sync-watcher.sh

  Watches the configured SOURCE directory and mirrors changes into TARGET.
  Paths are read from (and saved to):
    ~/.sync-watcher.source.path
    ~/.sync-watcher.target.path

  The script runs in the foreground until interrupted (Ctrl+C) or terminated.
```

**Stopping:** press `Ctrl+C`. The `trap` handlers release the lock and clean up before exit.

---

## Examples

### Basic run

```console
$ ./sync-watcher.sh
2026-07-01 11:09:00 [INFO ] [sync-watcher] Starting sync-watcher.
2026-07-01 11:09:00 [INFO ] [sync-watcher] Acquired single-instance lock: /run/user/1000/sync-watcher.lock
2026-07-01 11:09:00 [INFO ] [sync-watcher] SOURCE directory: /home/user/project
2026-07-01 11:09:00 [INFO ] [sync-watcher] TARGET directory: /mnt/backup/project
2026-07-01 11:09:00 [INFO ] [sync-watcher] Watcher starting. Monitoring '/home/user/project' for events: modify,create,delete,move,attrib
2026-07-01 11:09:00 [INFO ] [sync-watcher] Synchronization started: /home/user/project/ -> /mnt/backup/project
2026-07-01 11:09:00 [INFO ] [sync-watcher] Synchronization completed successfully.
```

### Single-instance guard in action

```console
$ ./sync-watcher.sh   # second terminal, while the first is still running
2026-07-01 11:10:12 [ERROR] [sync-watcher] Another instance of 'sync-watcher' is already running.
2026-07-01 11:10:12 [ERROR] [sync-watcher] Lock held on: /run/user/1000/sync-watcher.lock
```

### One-way behavior

```console
# A file created directly in the TARGET is reverted on the next sync,
# and never appears in the SOURCE:
$ echo "rogue" > /mnt/backup/project/rogue.txt
$ touch /home/user/project/README.md      # triggers a sync
# ...target/rogue.txt is removed; source is untouched.
```

### Excluding files with `.syncignore`

```console
$ cat ~/.syncignore
/node_modules
/target
*.log
!important.log

$ ./sync-watcher.sh
... [INFO ] [sync-watcher] Loading ignore rules from /home/user/.syncignore
... [INFO ] [sync-watcher] Ignore rules active: 3 exclude, 1 negation, 2 pruned dir(s).
... [INFO ] [sync-watcher] Pruning 2 ignored director(y/ies) from the watch tree.
... [INFO ] [sync-watcher] Synchronization completed successfully.
# node_modules/, target/, and *.log files are skipped; important.log is kept.
```

### Run as a background service (quick & dirty)

```bash
nohup ./sync-watcher.sh > ~/sync-watcher.log 2>&1 &
```

For a proper long-running service, see [Deployment](#deployment).

---

## Project Structure

```text
<REPO>/
├── sync-watcher.sh        # The main (and only required) script
├── README.md              # This file
├── .syncignore.example    # Optional: sample ignore rules to copy to ~/.syncignore
├── LICENSE                # License text (see License section)
├── tests/                 # Optional: test scripts  (placeholder)
│   └── test_sync.sh
└── docs/                  # Optional: extended docs   (placeholder)
```

> [!NOTE]
> The tool is intentionally a **single self-contained script**. The `tests/` and `docs/`
> directories are optional/suggested and marked as placeholders — add them if your workflow
> needs them.

---

## Development Workflow

1. **Fork & clone** the repository.
2. **Create a branch:** `git checkout -b feat/my-improvement`.
3. **Edit** `sync-watcher.sh`, keeping functions small and single-purpose.
4. **Lint & format** before every commit (see below).
5. **Test** your change (see [Testing](#testing)).
6. **Commit** using clear, conventional messages (e.g. `fix: release lock on SIGTERM`).
7. **Open a Pull Request** describing the change and how you verified it.

### Linting & static analysis

```bash
# Syntax check
bash -n sync-watcher.sh

# Static analysis (highly recommended — the project is kept ShellCheck-clean)
shellcheck sync-watcher.sh

# Optional: auto-format
shfmt -w -i 4 sync-watcher.sh
```

Install the tools:

```bash
sudo apt-get install -y shellcheck        # Debian/Ubuntu
# shfmt: https://github.com/mvdan/sh
```

---

## Testing

There is no unit-test framework requirement for a Bash tool of this size; the recommended
approach is a **functional smoke test** using temporary directories. A minimal example:

```bash
#!/usr/bin/env bash
set -euo pipefail

export HOME="$(mktemp -d)"
SRC="$(mktemp -d)"; DST="$(mktemp -d)"
echo "$SRC" > "$HOME/.sync-watcher.source.path"
echo "$DST" > "$HOME/.sync-watcher.target.path"
echo "hello" > "$SRC/a.txt"

./sync-watcher.sh > "$HOME/log" 2>&1 &
PID=$!; sleep 2

# Initial sync copied the file?
[[ -f "$DST/a.txt" ]] && echo "PASS: initial sync"

# One-way: rogue target file is reverted, source untouched?
echo "rogue" > "$DST/rogue.txt"; touch "$SRC/a.txt"; sleep 2
[[ ! -e "$DST/rogue.txt" ]] && echo "PASS: one-way revert"
[[ ! -e "$SRC/rogue.txt" ]] && echo "PASS: no backflow"

kill "$PID"; rm -rf "$HOME" "$SRC" "$DST"
```

This project has been verified to pass exactly these checks, plus:

- ✅ `bash -n` (no syntax errors)
- ✅ ShellCheck v0.10 (zero warnings)
- ✅ Single-instance guard (second launch exits gracefully)
- ✅ Incremental create/modify/delete propagation

> [!TIP]
> Place your test scripts under `tests/` and wire them into CI (see below).

### Continuous Integration (suggested)

Create `.github/workflows/ci.yml`:

```yaml
name: CI
on: [push, pull_request]
jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: sudo apt-get update && sudo apt-get install -y rsync inotify-tools shellcheck
      - name: Syntax check
        run: bash -n sync-watcher.sh
      - name: ShellCheck
        run: shellcheck sync-watcher.sh
      - name: Functional test
        run: bash tests/test_sync.sh   # placeholder: add your test
```

---

## Deployment

For unattended, always-on operation, run sync-watcher as a **systemd user service**.

Create `~/.config/systemd/user/sync-watcher.service`:

```ini
[Unit]
Description=One-way filesystem sync watcher
After=default.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sync-watcher
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Enable and manage it:

```bash
systemctl --user daemon-reload
systemctl --user enable --now sync-watcher.service

# Follow logs
journalctl --user -u sync-watcher.service -f

# Keep it running after logout (optional)
sudo loginctl enable-linger "$USER"
```

> [!NOTE]
> Because config paths are stored in the user's `$HOME`, run this as a **user** service (not a
> system service) so paths and permissions resolve correctly. Adapt if you need a system-wide
> deployment. *(Placeholder: adjust `ExecStart` path if you did not install to `/usr/local/bin`.)*

---

## Troubleshooting

| Symptom                                                        | Likely cause & fix                                                                                          |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `Another instance of 'sync-watcher' is already running.`       | Expected — another copy holds the lock. Stop it first, or that's the guard working as intended.             |
| `Missing required command(s): ...`                             | Install the listed dependencies (see [Prerequisites](#prerequisites)).                                      |
| Changes in a **subdirectory** aren't syncing                   | Ensure you're on a real Linux `inotify` filesystem (some network/FUSE mounts don't emit inotify events).    |
| `Failed to add watch ... upper limit ... reached`              | Raise the inotify watch limit: `sudo sysctl fs.inotify.max_user_watches=524288` (persist in `/etc/sysctl.conf`). |
| Target file re-appears after you delete it there               | Expected — sync is one-way; delete it in the **source** instead.                                            |
| `SOURCE and TARGET resolve to the same directory`              | Point them at distinct directories; the tool refuses identical/nested paths to prevent data loss.           |
| Prompt appears every run                                       | The configured path is invalid; enter a valid directory once and it will be saved.                          |
| A file you expected to be ignored is still synced              | Check `~/.syncignore` syntax; remember it is read **once at startup** — restart after editing. Verify anchoring (`/name` = root only vs `name` = any depth). |
| `important.log`-style negation not taking effect               | Ensure the `!` rule targets the same path the exclude matched; complex negation stacks are a known limitation. |
| Nothing happens on a network share                             | Many NFS/SMB/FUSE mounts don't deliver inotify events reliably; sync-watcher needs local inotify support.    |

Enable more verbose insight by watching the logs (they already print each sync start/finish and every error).

---

## FAQ

**Is this a two-way sync tool?**
No — and deliberately so. It is strictly source → target. For bidirectional sync, use a tool like [Unison](https://www.cis.upenn.edu/~bcpierce/unison/) or [Syncthing](https://syncthing.net/).

**Does it handle very large directory trees?**
Yes, `rsync` transfers incrementally. Be mindful of the inotify watch limit for trees with very many subdirectories (see Troubleshooting).

**Does it preserve permissions, timestamps, and symlinks?**
Yes — `rsync -a` (archive mode) preserves them.

**Can I watch multiple source/target pairs?**
Run multiple copies with different `PROCESS_NAME`/config values, or extend the script. Each instance has its own lock.

**How do I exclude files from syncing?**
Create a `~/.syncignore` file using gitignore-style patterns. See [Ignoring Files](#ignoring-files-syncignore). It is optional and fully backward compatible.

**Are `.syncignore` changes picked up automatically?**
No — the file is parsed once at startup. Restart sync-watcher after editing it.

**Does it support `.gitignore`-style negation (`!`)?**
Yes, with a caveat: because rsync uses “first match wins” (git uses “last match wins”), negation rules are emitted before their excludes. Simple cases like `*.log` + `!keep.log` work as expected; very complex negation stacks may not. See [Known limitations](#known-limitations).

---

## Contributing

Contributions are welcome! To keep quality high:

1. Open an issue describing the bug or proposal before large changes.
2. Keep the script **ShellCheck-clean** and formatted with `shfmt -i 4`.
3. Preserve the **one-way** guarantee and single-instance guard — add a test if you touch them.
4. Write clear commit messages and PR descriptions, including how you verified the change.
5. Update this README when behavior or configuration changes.

Please also review our Code of Conduct. *(Placeholder: add a `CODE_OF_CONDUCT.md`, e.g. the [Contributor Covenant](https://www.contributor-covenant.org/).)*

---

## License

This project is licensed under the **MIT License** — see the [`LICENSE`](LICENSE) file for details.

```text
Copyright (c) <YEAR> <YOUR NAME OR ORGANIZATION>   <!-- Placeholder -->

Permission is hereby granted, free of charge, to any person obtaining a copy...
```

> *(Placeholder: replace `<YEAR>` and `<YOUR NAME OR ORGANIZATION>`, or swap in a different
> license such as Apache-2.0 or GPL-3.0 and update the badge above accordingly.)*

---

## Acknowledgments

- [rsync](https://rsync.samba.org/) — the reliable, efficient file-transfer engine at the core of this tool.
- [inotify-tools](https://github.com/inotify-tools/inotify-tools) — `inotifywait`, powering event-driven watching.
- [util-linux](https://github.com/util-linux/util-linux) — `flock`, providing the robust locking primitive.
- [ShellCheck](https://www.shellcheck.net/) — for keeping the code honest.
- The Bash community's collected [best practices](https://mywiki.wooledge.org/BashGuide) and pitfalls guides.

<div align="center">

---

Made with ❤️ and a healthy respect for `set -euo pipefail`.
<!-- Placeholder: add author/contact/links here -->

</div>
