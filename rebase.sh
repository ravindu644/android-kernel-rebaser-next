#!/usr/bin/env bash
# rebase.sh - visualize "what did the OEM do?" via per-folder git history
# Copyright (C) 2026 ravindu644 <droidcasts@protonmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[+]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[x]${NC} $*"  >&2; exit 1; }

command -v rsync &>/dev/null || die "rsync not found"
command -v git   &>/dev/null || die "git not found"

get_kver() {
    local mf="$1/Makefile"
    [[ -f "$mf" ]] || return 1
    local v p s
    v=$(awk -F' *= *' '/^VERSION/{print $2;exit}'    "$mf")
    p=$(awk -F' *= *' '/^PATCHLEVEL/{print $2;exit}' "$mf")
    s=$(awk -F' *= *' '/^SUBLEVEL/{print $2;exit}'   "$mf")
    [[ -n "$v" && -n "$p" && -n "$s" ]] && echo "${v}.${p}.${s}" || return 1
}

ask_path() {
    local label="$1" need_ver="${2:-}" path ver
    while true; do
        read -rp "Path to $label kernel source: " path
        path=$(realpath -m "$path" 2>/dev/null) || { warn "Bad path"; continue; }
        [[ -d "$path" ]]         || { warn "Not a directory"; continue; }
        ver=$(get_kver "$path")  || { warn "Missing/unreadable Makefile"; continue; }
        [[ -z "$need_ver" || "$ver" == "$need_ver" ]] \
                                 || { warn "Version mismatch: got $ver, need $need_ver"; continue; }
        info "$label -> $path [$ver]"
        echo "$path|$ver"
        return 0
    done
}

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --ack <path>    Path to ACK kernel source"
    echo "  --oem <path>    Path to OEM kernel source"
    echo "  --depth <num>   Sync depth (number or 'deepest', default: 1)"
    echo "  -h, --help      Show this help"
    exit 1
}

# Default values
ACK_PATH=""
OEM_PATH=""
DEPTH=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ack) ACK_PATH="$2"; shift 2 ;;
        --oem) OEM_PATH="$2"; shift 2 ;;
        --depth) DEPTH="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) warn "Unknown option: $1"; usage ;;
    esac
done

if [[ -n "$ACK_PATH" && -n "$OEM_PATH" ]]; then
    ACK_PATH=$(realpath -m "$ACK_PATH")
    OEM_PATH=$(realpath -m "$OEM_PATH")
    [[ -d "$ACK_PATH" ]] || die "ACK path is not a directory"
    [[ -d "$OEM_PATH" ]] || die "OEM path is not a directory"
    ACK_VER=$(get_kver "$ACK_PATH") || die "ACK: Missing/unreadable Makefile"
    OEM_VER=$(get_kver "$OEM_PATH") || die "OEM: Missing/unreadable Makefile"
    [[ "$ACK_VER" == "$OEM_VER" ]] || die "Version mismatch: ACK=$ACK_VER, OEM=$OEM_VER"
    info "ACK -> $ACK_PATH [$ACK_VER]"
    info "OEM -> $OEM_PATH [$OEM_VER]"
else
    # Fallback to interactive
    IFS='|' read -r ACK_PATH ACK_VER <<< "$(ask_path "ACK")"
    IFS='|' read -r OEM_PATH _       <<< "$(ask_path "OEM" "$ACK_VER")"
    read -rp "Sync depth (number or 'deepest') [1]: " DEPTH
    [[ -z "$DEPTH" ]] && DEPTH=1
fi

if [[ "$DEPTH" == "deepest" ]]; then
    info "Calculating maximum depth..."
    # Find true maximum depth
    DEPTH=$(find "$OEM_PATH" -type d -printf '%d\n' | sort -rn | head -1)
    info "Deepest level found: $DEPTH"
fi

ACK_NAME=$(basename "$ACK_PATH")
REBASED="${ACK_PATH%/*}/${ACK_NAME}-rebased"
[[ -e "$REBASED" ]] && die "$REBASED already exists"

# -rlpt = recursive, symlinks, preserve times -- no perms/owner
RSYNC="rsync -rlpt"

info "Cloning ACK -> $REBASED ..."
$RSYNC "$ACK_PATH/" "$REBASED/"

cd "$REBASED" || die "cd failed"

# ignore filemode changes globally for this repo
git config core.fileMode false

# init fresh repo if ACK had no .git
git rev-parse --git-dir &>/dev/null || { git init -q && git add -Af && git commit -q -m "ack: baseline $ACK_VER"; }

# 1. Sync root files at depth 0
info "Syncing OEM root files..."
$RSYNC --delete --exclude='.git' --exclude='*/' "$OEM_PATH/" "$REBASED/"
git add -Af
git diff --cached --quiet || git commit -q -m "root: OEM root-level changes"

# 2. Iterate through levels BOTTOM-UP (Deepest First)
for (( i=DEPTH; i>=1; i-- )); do
    info "Processing Level $i ..."
    
    declare -A LEVEL_DIRS
    while IFS= read -r -d '' d; do
        rel_path="${d#$OEM_PATH/}"
        rel_path="${rel_path#$REBASED/}"
        [[ "$rel_path" == "." || "$rel_path" == ".git"* ]] && continue
        LEVEL_DIRS["$rel_path"]=1
    done < <(find "$OEM_PATH" "$REBASED" -mindepth "$i" -maxdepth "$i" -type d -not -path '*/.*' -print0)

    mapfile -t SORTED_DIRS < <(printf '%s\n' "${!LEVEL_DIRS[@]}" | sort)

    for rel_d in "${SORTED_DIRS[@]}"; do
        # In bottom-up mode, we sync the directory RECURSIVELY.
        # But we must exclude sub-directories that were ALREADY committed.
        # However, to keep it simple: we sync the dir and its files. 
        # Since sub-dirs are already committed, git will see no changes there.
        # We just need to ensure we don't 'delete' files that should be there.
        
        if [[ -d "$OEM_PATH/$rel_d" ]]; then
            info "  Syncing $rel_d/ ..."
            mkdir -p "$REBASED/$rel_d"
            $RSYNC --delete --exclude='.git' --exclude='*/' "$OEM_PATH/$rel_d/" "$REBASED/$rel_d/"
            (cd "$REBASED/$rel_d" && git add -Af .)
        else
            # OEM deleted it - but only if it's empty (already handled by children)
            if [[ -e "$REBASED/$rel_d" ]]; then
                 rm -rf "$REBASED/$rel_d"
                 git add -u "$rel_d"
            fi
        fi
        
        git diff --cached --quiet || git commit -q -m "${rel_d}: OEM changes"
    done
done

info "Done -> $REBASED"
git log --oneline
