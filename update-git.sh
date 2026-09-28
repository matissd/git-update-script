#!/usr/bin/env bash
#
# update-git.sh — fetch, pull and update submodules for every git repository
# found underneath a directory.
#
# Directories are walked recursively until a .git entry is found; that directory
# is treated as a repository and is not descended into any further, so nested
# repositories and submodules are never visited on their own — a repository's
# submodules are updated by the repository itself.
#
# Usage:
#   ./update-git.sh                  # scan the directory the script lives in
#   ./update-git.sh /some/path       # scan a specific directory
#   ./update-git.sh -d 1 /some/path  # only look at the immediate children
#
# Options:
#   -d, --max-depth N  Stop descending after N levels below the target
#                      directory (0 = the target itself only). Unlimited
#                      by default.
#   -h, --help         Show this help text.

set -uo pipefail

MAX_DEPTH=-1
TARGET=""

usage() {
    # Print the leading comment block (everything up to the first blank line
    # after the shebang), stripped of its '#' markers.
    sed -n '3,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//;s/^#$//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--max-depth)
            if [ $# -lt 2 ]; then
                echo "$1 needs a value." >&2
                exit 2
            fi
            case "$2" in
                ''|*[!0-9]*) echo "Not a number: $2" >&2; exit 2 ;;
            esac
            MAX_DEPTH="$2"
            shift
            ;;
        -r|--recursive) : ;;   # accepted for compatibility; now the default
        -h|--help)      usage; exit 0 ;;
        -*)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "Only one directory may be given." >&2
                exit 2
            fi
            TARGET="$1"
            ;;
    esac
    shift
done

# Default to the directory this script lives in, so it works no matter where
# it is called from and no paths need to be hardcoded.
if [ -z "$TARGET" ]; then
    TARGET="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ ! -d "$TARGET" ]; then
    echo "Not a directory: $TARGET" >&2
    exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

command -v git >/dev/null 2>&1 || { echo "git is not installed." >&2; exit 1; }

# Colours only when writing to a terminal.
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m'); RESET=$(printf '\033[0m')
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

# ---------------------------------------------------------------- collect repos
# Walk down from the target, stopping at the first .git found on each branch of
# the tree: that directory is the repository root, and anything below it (nested
# repos, submodule checkouts) belongs to it rather than to us.
repos=()

collect_repos() {
    local dir="$1" depth="$2" entry

    # .git is a directory in a normal clone, a file in a worktree/submodule.
    if [ -e "$dir/.git" ]; then
        repos+=("$dir")
        return
    fi

    if [ "$MAX_DEPTH" -ge 0 ] && [ "$depth" -ge "$MAX_DEPTH" ]; then
        return
    fi

    for entry in "$dir"/*/; do
        entry="${entry%/}"
        [ -d "$entry" ] || continue      # no match: the glob stayed literal
        [ -L "$entry" ] && continue      # don't follow symlinks into cycles
        collect_repos "$entry" "$((depth + 1))"
    done
}

collect_repos "$TARGET" 0

if [ "${#repos[@]}" -eq 0 ]; then
    echo "No git repositories found in $TARGET"
    exit 0
fi

IFS=$'\n' repos=($(printf '%s\n' "${repos[@]}" | sort)); unset IFS

echo "${BOLD}Updating ${#repos[@]} repositor$([ "${#repos[@]}" -eq 1 ] && echo y || echo ies) in $TARGET${RESET}"

updated=(); skipped=(); failed=()

# ------------------------------------------------------------------ update loop
for repo in "${repos[@]}"; do
    name="${repo#"$TARGET"/}"
    [ "$name" = "$TARGET" ] && name="$(basename "$TARGET")"
    printf '\n%s==> %s%s\n' "$BLUE$BOLD" "$name" "$RESET"

    # A submodule is updated through its superproject, not on its own.
    if [ -n "$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null)" ]; then
        echo "  ${YELLOW}skipped: submodule of another repository${RESET}"
        skipped+=("$name (submodule)")
        continue
    fi

    # Uncommitted changes make a pull messy — report and move on.
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
        echo "  ${YELLOW}skipped: working tree has local changes${RESET}"
        git -C "$repo" status --short | sed 's/^/    /'
        skipped+=("$name (dirty)")
        continue
    fi

    if ! git -C "$repo" fetch --all --prune --tags; then
        echo "  ${RED}fetch failed${RESET}"
        failed+=("$name (fetch)")
        continue
    fi

    branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -z "$branch" ]; then
        echo "  ${YELLOW}skipped pull: detached HEAD${RESET}"
        skipped+=("$name (detached HEAD)")
    elif ! git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        echo "  ${YELLOW}skipped pull: '$branch' has no upstream${RESET}"
        skipped+=("$name (no upstream)")
    elif ! git -C "$repo" pull --ff-only; then
        echo "  ${RED}pull failed (branch '$branch' has diverged?)${RESET}"
        failed+=("$name (pull)")
        continue
    fi

    if [ -f "$repo/.gitmodules" ]; then
        if ! git -C "$repo" submodule update --init --recursive; then
            echo "  ${RED}submodule update failed${RESET}"
            failed+=("$name (submodules)")
            continue
        fi
    fi

    updated+=("$name")
done

# ---------------------------------------------------------------------- summary
printf '\n%s---- summary ----%s\n' "$BOLD" "$RESET"
printf '%sup to date: %d%s\n' "$GREEN" "${#updated[@]}" "$RESET"
for r in "${skipped[@]}"; do printf '%sskipped:%s %s\n' "$YELLOW" "$RESET" "$r"; done
for r in "${failed[@]}";  do printf '%sfailed:%s  %s\n' "$RED"    "$RESET" "$r"; done

[ "${#failed[@]}" -eq 0 ] || exit 1
