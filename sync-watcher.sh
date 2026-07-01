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
    local rc=0
    rsync "${RSYNC_OPTS[@]}" -- "${SOURCE_PATH}/" "${TARGET_PATH}/" || rc=$?

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

    # `inotifywait` blocks until an event occurs, then returns. We loop,
    # syncing once per detected event batch. `--quiet` keeps logs clean.
    while inotifywait --quiet --recursive \
                      --event "$INOTIFY_EVENTS" \
                      --format '%w%f %e' \
                      "$SOURCE_PATH"; do
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

    start_watcher
}

main "$@"
