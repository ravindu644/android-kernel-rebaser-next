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

IFS='|' read -r ACK_PATH ACK_VER <<< "$(ask_path "ACK")"
IFS='|' read -r OEM_PATH _       <<< "$(ask_path "OEM" "$ACK_VER")"

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

# root-level files only (no dirs, no .git)
info "Syncing OEM root files ..."
$RSYNC --delete --exclude='.git' --exclude='*/' "$OEM_PATH/" "$REBASED/"
git add -Af
git diff --cached --quiet || git commit -q -m "root: OEM root-level changes"

# union of top-level dirs from both OEM and REBASED
declare -A ALL_DIRS
while IFS= read -r -d '' d; do
    [[ $(basename "$d") == '.git' ]] && continue
    ALL_DIRS["$(basename "$d")"]=1
done < <(find "$OEM_PATH" "$REBASED" -maxdepth 1 -mindepth 1 -type d -print0)

for dname in $(echo "${!ALL_DIRS[@]}" | tr ' ' '\n' | sort); do
    [[ "$dname" == '.git' ]] && continue
    info "Syncing ${dname}/ ..."
    if [[ -d "$OEM_PATH/$dname" ]]; then
        mkdir -p "$REBASED/$dname"
        $RSYNC --delete --exclude='.git' "$OEM_PATH/$dname/" "$REBASED/$dname/"
    else
        # dir exists in ACK but OEM removed it
        rm -rf "${REBASED:?}/$dname"
    fi
    git add -Af "$dname"
    git diff --cached --quiet || git commit -q -m "${dname}: OEM changes"
done

info "Done -> $REBASED"
git log --oneline
