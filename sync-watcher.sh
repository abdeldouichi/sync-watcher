#!/usr/bin/env bash
#
# sync-watcher.sh — One-way filesystem synchronization daemon
#
# Watches a SOURCE directory for changes and mirrors them into a TARGET
# directory using rsync. Synchronization is strictly one-way:
#
#         SOURCE  ───────────────▶  TARGET
#         (source of truth)         (mirror / replica)
#
# Any change made directly inside TARGET (create/modify/delete) is never
# propagated back to SOURCE and, thanks to `rsync --delete`, is reconciled
# back to match SOURCE on the next sync. SOURCE always wins.
#
# Design goals: reliability, maintainability, safety.
#
# ------------------------------------------------------------------------- #
# DESIGN DECISIONS (summary — see the full comparison at the bottom / README):
#
#  * `set -euo pipefail` + IFS hardening              -> fail fast, no silent
#                                                         word-splitting bugs.
#  * All logic lives in small, single-purpose funcs   -> testable, readable.
#  * `readonly` constants, UPPER_CASE naming          -> clear intent.
#  * `flock` on a dedicated lock file                 -> robust single-instance
#                                                         guard (kernel-managed,
#                                                         auto-released on death;
#                                                         no stale-PID problem).
#  * `trap` on EXIT/INT/TERM/HUP                       -> guaranteed cleanup.
#  * Dependency pre-flight check                       -> clear early failure.
#  * Config files auto-created & validated            -> self-healing setup.
#  * rsync runs ONLY after a real inotify event        -> no wasted syncs.
#  * .syncignore (gitignore-style) exclusions          -> applied uniformly to
#                                                         initial sync, every
#                                                         incremental sync, and
#                                                         the watcher itself.
# ------------------------------------------------------------------------- #

set -euo pipefail
# Harden word-splitting: only split on newline/tab, never on spaces.
IFS=$'\n\t'

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

# A stable process name so the script is easy to identify (e.g. in `ps`,
# `pgrep`, logs) and so the lock file has a predictable, collision-free name.
readonly PROCESS_NAME="sync-watcher"

# Base directory for per-user runtime/config state. HOME is preferred over the
# fragile "/home/$USER" assumption (works for root, custom homes, containers…).
readonly BASE_DIR="${HOME:?HOME is not set}"

# Configuration files: one path per file, plain text, human-editable.
readonly SOURCE_CONFIG="${BASE_DIR}/.${PROCESS_NAME}.source.path"
readonly TARGET_CONFIG="${BASE_DIR}/.${PROCESS_NAME}.target.path"

# Lock file used by flock for the single-instance guard.
# Placed in a runtime dir when available, otherwise falls back to HOME.
readonly LOCK_DIR="${XDG_RUNTIME_DIR:-$BASE_DIR}"
readonly LOCK_FILE="${LOCK_DIR}/${PROCESS_NAME}.lock"

# File descriptor number reserved for the flock lock.
readonly LOCK_FD=200

# inotify events that should trigger a re-sync.
readonly INOTIFY_EVENTS="modify,create,delete,move,attrib"

# rsync options for efficient, incremental, faithful one-way mirroring:
#   -a        archive mode (recurse + preserve perms/times/symlinks/owner…)
#   --delete  remove TARGET files that no longer exist in SOURCE (mirror)
#   -h        human-readable numbers in output
#   --partial keep partially transferred files to speed up resumes
readonly RSYNC_OPTS=(-a --delete -h --partial)

# Required external commands.
readonly REQUIRED_COMMANDS=(rsync inotifywait flock)

# --------------------------------------------------------------------------- #
# .syncignore configuration
# --------------------------------------------------------------------------- #
# User-editable ignore file, gitignore-style. Optional: if absent, nothing is
# excluded and behavior is identical to previous versions (backward compatible).
readonly SYNCIGNORE_FILE="${BASE_DIR}/.syncignore"

# Generated, rsync-native filter file translated from SYNCIGNORE_FILE. It lives
# in a private runtime location and is regenerated on every startup so it can
# never drift from the user's .syncignore. Cleaned up by the EXIT trap.
# Declared and assigned separately so mktemp's exit status is not masked.
RSYNC_RULES_FILE=""
RSYNC_RULES_FILE="$(mktemp -t "${PROCESS_NAME}.rules.XXXXXX")"
readonly RSYNC_RULES_FILE

# Root-anchored directory names (leading-slash patterns like "/node_modules")
# are additionally pruned from the inotify watch tree via @<path>, which — unlike
# a regex exclude — prevents an inotify watch from being allocated at all. This
# is the only mechanism that reduces the kernel watch count and avoids hitting
# fs.inotify.max_user_watches on trees with huge dirs (node_modules, target…).
INOTIFY_PRUNE_DIRS=()   # populated from .syncignore (root-anchored dir patterns)
INOTIFY_EXCLUDE_REGEX=""  # POSIX ERE built from .syncignore for --exclude
SYNCIGNORE_ACTIVE=false   # true once at least one rule is loaded

# --------------------------------------------------------------------------- #
# Runtime globals (populated after validation)
# --------------------------------------------------------------------------- #
SOURCE_PATH=""
TARGET_PATH=""

# --------------------------------------------------------------------------- #
# Logging helpers
# --------------------------------------------------------------------------- #
# Structured, timestamped, level-tagged messages.
#
# ALL log output goes to STDERR (fd 2), never stdout. This is deliberate:
# several functions (e.g. resolve_directory) return their result by writing it
# to stdout via command substitution `$(...)`. If logging also wrote to stdout,
# log lines would be captured into the returned value and corrupt it. Keeping
# logs on stderr cleanly separates "human output" from "function return values".

_log() {
    # $1 = level, remaining args = message
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s [%-5s] [%s] %s\n' "$ts" "$level" "$PROCESS_NAME" "$*" >&2
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }

# --------------------------------------------------------------------------- #
# Cleanup / signal handling
# --------------------------------------------------------------------------- #
# A single trap covers normal exit and interrupting signals so lock files and
# transient resources are always released, even on unexpected termination.

cleanup() {
    # Capture the exit status BEFORE running any command that would overwrite $?.
    local exit_code=$?

    # Release the lock explicitly (the kernel also does this on process death,
    # but being explicit avoids surprises and lets us remove the file).
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
    fi
    # Best-effort removal of the lock file. Harmless if another guarded run
    # recreated it; flock semantics do not depend on the file's existence.
    rm -f "$LOCK_FILE" 2>/dev/null || true

    # Remove the generated rsync rules file (temporary resource).
    rm -f "$RSYNC_RULES_FILE" 2>/dev/null || true

    log_info "Exiting (status ${exit_code})."
    exit "$exit_code"
}

# INT/TERM/HUP are trapped so the EXIT trap runs a clean shutdown path.
trap cleanup EXIT
trap 'log_warn "Received interrupt signal."; exit 130' INT
trap 'log_warn "Received termination signal."; exit 143' TERM
trap 'log_warn "Received hangup signal."; exit 129' HUP

# --------------------------------------------------------------------------- #
# Dependency validation
# --------------------------------------------------------------------------- #

check_dependencies() {
    local missing=()
    local cmd
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required command(s): ${missing[*]}"
        log_error "Install them and retry. On Debian/Ubuntu:"
        log_error "  sudo apt-get install rsync inotify-tools util-linux"
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
# Single-instance guard (flock)
# --------------------------------------------------------------------------- #
# We open the lock file on a dedicated FD and take a NON-blocking exclusive
# lock. If another instance already holds it, flock fails and we exit
# gracefully with a clear message. The kernel releases the lock automatically
# if the process dies, so there is no stale-PID problem like with naive PID
# files.

acquire_lock() {
    # Open (create) the lock file bound to LOCK_FD for the whole script.
    # The `eval` is required to use a variable as the FD number.
    eval "exec ${LOCK_FD}>\"\$LOCK_FILE\""

    if ! flock -n "$LOCK_FD"; then
        log_error "Another instance of '${PROCESS_NAME}' is already running."
        log_error "Lock held on: ${LOCK_FILE}"
        # Exit 0-adjacent but distinct: refuse to start, but not a crash.
        exit 1
    fi

    log_info "Acquired single-instance lock: ${LOCK_FILE}"
}

# --------------------------------------------------------------------------- #
# Configuration management
# --------------------------------------------------------------------------- #

# Ensure a config file exists; create an empty one if it does not.
ensure_config_file() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_info "Creating configuration file: ${config_file}"
        : > "$config_file"        # create/truncate to empty, safely
    fi
}

# Read the single stored path from a config file (may be empty), trimming
# surrounding whitespace.
read_config_path() {
    local config_file="$1"
    local value=""
    if [[ -f "$config_file" ]]; then
        # Read first line only; tolerate missing trailing newline.
        IFS= read -r value < "$config_file" || true
    fi
    # Trim leading/trailing whitespace.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Persist a validated path back to its config file.
write_config_path() {
    local config_file="$1"
    local path_value="$2"
    printf '%s\n' "$path_value" > "$config_file"
    log_info "Saved path to ${config_file}: ${path_value}"
}

# Validate that a path is a non-empty, existing directory.
is_valid_directory() {
    local path_value="$1"
    [[ -n "$path_value" && -d "$path_value" ]]
}

# Resolve a configured directory: load from config, validate, and — if
# invalid or missing — prompt the user until a valid directory is provided,
# then persist it. Echoes the final validated absolute-ish path.
#
# $1 = label (e.g. "SOURCE"), $2 = config file, $3 = prompt text
resolve_directory() {
    local label="$1"
    local config_file="$2"
    local prompt_text="$3"
    local path_value

    ensure_config_file "$config_file"
    path_value="$(read_config_path "$config_file")"

    if is_valid_directory "$path_value"; then
        log_info "${label} directory: ${path_value}"
        printf '%s' "$path_value"
        return 0
    fi

    log_warn "${label} path in ${config_file} is empty or does not exist."

    # Interactive prompt loop. Requires a TTY; abort clearly if none.
    if [[ ! -t 0 ]]; then
        log_error "${label} path is invalid and no interactive terminal is available to prompt."
        exit 1
    fi

    while ! is_valid_directory "$path_value"; do
        # `read` from /dev/tty to work even when stdin is otherwise redirected.
        read -r -p "${prompt_text}: " path_value < /dev/tty || {
            log_error "Failed to read ${label} path from terminal."
            exit 1
        }
        # Expand a leading ~ for convenience.
        path_value="${path_value/#\~/$HOME}"

        if ! is_valid_directory "$path_value"; then
            log_warn "'${path_value}' is not a valid directory. Please try again."
        fi
    done

    write_config_path "$config_file" "$path_value"
    log_info "${label} directory: ${path_value}"
    printf '%s' "$path_value"
}

# Guarantee SOURCE and TARGET are different to avoid a destructive self-sync.
assert_distinct_paths() {
    # Normalize with realpath when available for a robust comparison.
    local src="$1" dst="$2"
    if command -v realpath >/dev/null 2>&1; then
        src="$(realpath -m -- "$src")"
        dst="$(realpath -m -- "$dst")"
    fi
    if [[ "$src" == "$dst" ]]; then
        log_error "SOURCE and TARGET resolve to the same directory: ${src}"
        log_error "Refusing to run to avoid data loss."
        exit 1
    fi
    # Prevent TARGET being nested inside SOURCE (would cause recursive copies).
    case "$dst/" in
        "$src"/*)
            log_error "TARGET (${dst}) is inside SOURCE (${src}). Refusing to run."
            exit 1
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# .syncignore parsing and translation
# --------------------------------------------------------------------------- #
# The user writes gitignore-style rules in $HOME/.syncignore. We translate them
# into two consistent representations so ALL sync operations honor them:
#
#   1. RSYNC_RULES_FILE  -> consumed by `rsync --exclude-from`. Handles the
#      actual file transfer (initial + every incremental sync). rsync's own C
#      filter engine matches efficiently and, crucially, PRUNES excluded
#      directories from its scan (no descent) when we emit `/dir/***`.
#
#   2. INOTIFY_EXCLUDE_REGEX + INOTIFY_PRUNE_DIRS -> consumed by inotifywait so
#      the watcher does not wake up (and trigger a needless sync) for events on
#      ignored files, and does not even allocate watches for large ignored dirs.
#
# Both are derived from the SAME source file, guaranteeing consistent behavior.
#
# NOTE ON SEMANTICS: We implement a pragmatic subset of gitignore. rsync uses
# "first match wins" whereas git uses "last match wins", so negation (`!`) rules
# are emitted BEFORE their excludes (two-pass) to approximate the intent.
# See the README "Known limitations" section for details.

# Escape a literal string for safe inclusion in a POSIX extended regex (ERE).
# Escapes ERE metacharacters that may legitimately appear in path literals.
# Glob wildcards (* ? **) are NOT touched here; the caller substitutes them.
escape_for_ere() {
    # Bracket class ordering matters: a literal ] must appear first, and the
    # escaped backslash \\ must appear last, to keep the class well-formed.
    printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

# Convert a single gitignore-style glob into a POSIX ERE fragment for
# inotifywait --exclude. inotifywait matches the regex against the FULL path,
# so unanchored patterns get a leading ".*/" and every fragment ends with
# "(/.*)?" so a directory pattern also matches everything beneath it.
glob_to_ere() {
    local glob="$1"
    local anchored=false
    if [[ "$glob" == /* ]]; then
        anchored=true
        glob="${glob#/}"
    fi
    glob="${glob%/}"   # drop any trailing slash (directory marker)

    # Protect glob wildcards with unlikely text placeholders, escape the rest
    # as literals, then substitute the ERE equivalents back in.
    glob="${glob//\*\*/@@DBLSTAR@@}"     # ** -> placeholder
    glob="${glob//\*/@@STAR@@}"          # *  -> placeholder
    glob="${glob//\?/@@QMARK@@}"         # ?  -> placeholder
    glob="$(escape_for_ere "$glob")"
    glob="${glob//@@DBLSTAR@@/.*}"       # ** -> .*    (crosses slashes)
    glob="${glob//@@STAR@@/[^/]*}"       # *  -> [^/]* (within one component)
    glob="${glob//@@QMARK@@/[^/]}"       # ?  -> single non-slash char

    if [[ "$anchored" == true ]]; then
        printf '%s' "$(escape_for_ere "$SOURCE_PATH")/${glob}(/.*)?"
    else
        printf '%s' ".*/${glob}(/.*)?"
    fi
}

# Parse $HOME/.syncignore and populate RSYNC_RULES_FILE, INOTIFY_EXCLUDE_REGEX,
# and INOTIFY_PRUNE_DIRS. Backward compatible: a missing or empty file leaves
# the rules file empty and SYNCIGNORE_ACTIVE false (syncs everything).
load_syncignore() {
    : > "$RSYNC_RULES_FILE"   # always start from a clean, empty rules file

    if [[ ! -f "$SYNCIGNORE_FILE" ]]; then
        log_info "No .syncignore found at ${SYNCIGNORE_FILE}; syncing everything."
        return 0
    fi

    log_info "Loading ignore rules from ${SYNCIGNORE_FILE}"

    local -a include_rules=()   # negation (!) -> rsync '+ ' (emitted first)
    local -a exclude_rules=()   # normal      -> rsync '- '
    local -a ere_parts=()       # regex fragments for inotifywait
    local line raw pattern is_negated

    while IFS= read -r line || [[ -n "$line" ]]; do
        raw="${line%$'\r'}"                    # strip trailing CR (CRLF files)
        # Skip full-line comments (leading #, optionally indented).
        [[ "$raw" =~ ^[[:space:]]*# ]] && continue
        # Trim surrounding whitespace.
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [[ -z "$raw" ]] && continue            # skip blank lines

        is_negated=false
        if [[ "$raw" == '!'* ]]; then
            is_negated=true
            raw="${raw#!}"
        fi
        pattern="$raw"

        if [[ "$is_negated" == true ]]; then
            include_rules+=("+ ${pattern}")
            continue   # negated patterns are never pruned from the watch tree
        fi

        # Root-anchored directory-style pattern without wildcards
        # (e.g. /node_modules, /target, /.git): emit the triple-star form so
        # rsync excludes the dir AND skips descending into it, and register the
        # directory for inotify @<path> pruning (no watch allocated at all).
        if [[ "$pattern" == /* && "$pattern" != *'*'* ]]; then
            local bare="${pattern#/}"; bare="${bare%/}"
            if [[ -d "${SOURCE_PATH}/${bare}" ]]; then
                exclude_rules+=("- /${bare}/***")
                INOTIFY_PRUNE_DIRS+=("@${SOURCE_PATH}/${bare}")
            else
                exclude_rules+=("- ${pattern}")   # file or not-yet-created dir
            fi
        else
            exclude_rules+=("- ${pattern}")
        fi

        ere_parts+=("$(glob_to_ere "$pattern")")
    done < "$SYNCIGNORE_FILE"

    # Two-pass emit: negations (includes) FIRST so rsync's first-match-wins
    # lets them override the excludes that follow.
    local rule
    {
        printf '%s\n' "# Generated by ${PROCESS_NAME} from ${SYNCIGNORE_FILE}"
        for rule in "${include_rules[@]:-}"; do [[ -n "$rule" ]] && printf '%s\n' "$rule"; done
        for rule in "${exclude_rules[@]:-}"; do [[ -n "$rule" ]] && printf '%s\n' "$rule"; done
    } > "$RSYNC_RULES_FILE"

    # Join regex fragments into one alternation for inotifywait --exclude.
    if (( ${#ere_parts[@]} > 0 )); then
        local IFS='|'
        INOTIFY_EXCLUDE_REGEX="${ere_parts[*]}"
    fi

    if (( ${#include_rules[@]} + ${#exclude_rules[@]} > 0 )); then
        SYNCIGNORE_ACTIVE=true
        log_info "Ignore rules active: ${#exclude_rules[@]} exclude, ${#include_rules[@]} negation, ${#INOTIFY_PRUNE_DIRS[@]} pruned dir(s)."
    else
        log_info ".syncignore contained no effective rules; syncing everything."
    fi
}

# --------------------------------------------------------------------------- #
# Synchronization
# --------------------------------------------------------------------------- #
# IMPORTANT one-way semantics:
#   We sync "SOURCE/" (trailing slash => copy the CONTENTS of SOURCE) into
#   "TARGET". Combined with --delete, TARGET becomes an exact mirror of
#   SOURCE. Nothing is ever read from TARGET into SOURCE, so edits made in
#   TARGET cannot flow back — and are reverted on the next event.

run_sync() {
    log_info "Synchronization started: ${SOURCE_PATH}/ -> ${TARGET_PATH}"

    # We deliberately do NOT let a transient rsync failure kill the daemon;
    # we log it and keep watching. `set -e` is locally suspended around rsync.
    #
    # Build the rsync argument list, adding --exclude-from only when the user
    # has active .syncignore rules. This keeps the common (no-ignore) path
    # identical to previous versions for full backward compatibility.
    local -a rsync_args=("${RSYNC_OPTS[@]}")
    if [[ "$SYNCIGNORE_ACTIVE" == true ]]; then
        rsync_args+=(--exclude-from="$RSYNC_RULES_FILE")
    fi

    local rc=0
    rsync "${rsync_args[@]}" -- "${SOURCE_PATH}/" "${TARGET_PATH}/" || rc=$?

    if (( rc == 0 )); then
        log_info "Synchronization completed successfully."
    else
        log_error "Synchronization failed (rsync exit code ${rc}). Continuing to watch."
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Watch loop
# --------------------------------------------------------------------------- #
# rsync runs ONLY when inotifywait reports a real filesystem event, so there
# are no polling loops and no unnecessary synchronizations.

start_watcher() {
    log_info "Watcher starting. Monitoring '${SOURCE_PATH}' for events: ${INOTIFY_EVENTS}"

    # Perform an initial sync so TARGET matches SOURCE immediately at startup.
    run_sync

    # Assemble the inotifywait argument list. Ignore rules are applied here so
    # the watcher never wakes up for events on ignored paths:
    #   * @<path> entries prune large ignored directories from the watch tree
    #     entirely (no inotify watch allocated -> avoids the watch-count limit).
    #   * --exclude <regex> filters out events for ignored files at any depth.
    local -a inotify_args=(--quiet --recursive
                           --event "$INOTIFY_EVENTS"
                           --format '%w%f %e')

    if [[ "$SYNCIGNORE_ACTIVE" == true ]]; then
        if (( ${#INOTIFY_PRUNE_DIRS[@]} > 0 )); then
            inotify_args+=("${INOTIFY_PRUNE_DIRS[@]}")
            log_info "Pruning ${#INOTIFY_PRUNE_DIRS[@]} ignored director(y/ies) from the watch tree."
        fi
        if [[ -n "$INOTIFY_EXCLUDE_REGEX" ]]; then
            inotify_args+=(--exclude "$INOTIFY_EXCLUDE_REGEX")
        fi
    fi

    # `inotifywait` blocks until a (non-excluded) event occurs, then returns.
    # We loop, syncing once per detected event batch.
    while inotifywait "${inotify_args[@]}" "$SOURCE_PATH"; do
        run_sync
    done
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

main() {
    log_info "Starting ${PROCESS_NAME}."

    check_dependencies
    acquire_lock

    SOURCE_PATH="$(resolve_directory "SOURCE" "$SOURCE_CONFIG" \
                    "Please enter the SOURCE directory to watch")"
    TARGET_PATH="$(resolve_directory "TARGET" "$TARGET_CONFIG" \
                    "Please enter the TARGET directory to sync into")"

    assert_distinct_paths "$SOURCE_PATH" "$TARGET_PATH"

    # Load ignore rules AFTER the source path is known (the source path is used
    # to anchor patterns and to detect which ignored entries are directories).
    load_syncignore

    start_watcher
}

main "$@"
