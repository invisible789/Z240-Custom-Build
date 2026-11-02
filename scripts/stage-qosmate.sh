#!/usr/bin/env bash
# stage-qosmate.sh <workdir>
#
# Bakes QoSmate into the image by writing into <workdir>/openwrt/files/ the exact file set that
# QoSmate's own updater leaves on a device after "service qosmate update -v snapshot":
#   - every file the QoSmate init script lists for BACKEND and FRONTEND (taken from the init script
#     itself via its print_file_list action, after applying the repos' file_fixups.txt/dir_fixups.txt)
#   - VERSION / UPD_CHANNEL stamped into the init script and into settings.js (UI_VERSION / UI_UPD_CHANNEL)
#   - /etc/qosmate.d/backend_reg.md5 and frontend_reg.md5 (md5 registers the init script verifies at start)
#
# Why not the upstream OpenWrt Makefiles: they were last updated in early 2025 and do not install the
# stats backend (luci.qosmate_stats), the autorate scripts, the .dist files or qosmate-defaults, and the
# updater has no "package" channel. With a VERSION of "dev" the init script would try to self-update from
# GitHub on first start and replace what was built in.
#
# Nothing is staged under /etc/config/qosmate: like a normal install, the first "service qosmate start"
# creates it from /etc/qosmate.d/qosmate-defaults.
set -euo pipefail

W="${1:?usage: stage-qosmate.sh <workdir>}"
W="$(cd "$W" && pwd)"
B="$W/src/qosmate"
F="$W/src/luci-app-qosmate"
OUT="$W/openwrt/files"
DIST="$W/qosmate-dist"

die() { echo "stage-qosmate: $*" >&2; exit 1; }

[ -d "$B/.git" ] && [ -d "$F/.git" ] && [ -d "$W/openwrt" ] || die "run fetch-sources.sh first"

rm -rf "$DIST" "$OUT"
mkdir -p "$DIST/BACKEND" "$DIST/FRONTEND" "$OUT"

# What the updater unpacks from the GitHub tarball: the repository tree without .git
git -C "$B" archive HEAD | tar -x -C "$DIST/BACKEND"
git -C "$F" archive HEAD | tar -x -C "$DIST/FRONTEND"

# Same semantics as fixup_paths() in the QoSmate init script
apply_fixups() {
    local type="$1" file="$2" dist="$3" line from to
    [ -s "$file" ] || return 0
    while IFS='' read -r line || [ -n "$line" ]; do
        case "$line" in
            "#"*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        from="${line%%=*}"; from="${from%/}"
        to="${line#*=}";    to="${to%/}"
        if [ -z "$from" ] || [ "$from" = / ] || [ -z "$to" ]; then
            die "invalid fixup line: '$line'"
        fi
        if [ ! -e "$dist$from" ]; then
            echo "warning: $dist$from does not exist (skipped, as the updater does)" >&2
            continue
        fi
        case "$type" in
            dir)
                mkdir -p "$dist$to"
                mv "$dist$from"/* "$dist$to/"
                ;;
            file)
                mkdir -p "$(dirname "$dist$to")"
                mv "$dist$from" "$dist$to"
                ;;
        esac
    done < "$file"
}

for comp in BACKEND FRONTEND; do
    apply_fixups dir  "$DIST/$comp/dir_fixups.txt"  "$DIST/$comp"
    apply_fixups file "$DIST/$comp/file_fixups.txt" "$DIST/$comp"
done

# File lists come from the init script itself (the updater queries the new init script the same way)
INIT="$DIST/BACKEND/etc/init.d/qosmate"
[ -f "$INIT" ] || die "init script missing from backend dist: $INIT"
list() { (cd "$W" && env -i PATH="$PATH" sh "$INIT" print_file_list "$1" "$2"); }

BACKEND_FILES="$(list BACKEND ALL)"
BACKEND_EXEC="$(list BACKEND EXEC)"
FRONTEND_FILES="$(list FRONTEND ALL)"
FRONTEND_EXEC="$(list FRONTEND EXEC)"
[ -n "$BACKEND_FILES" ] && [ -n "$BACKEND_EXEC" ] && [ -n "$FRONTEND_FILES" ] && [ -n "$FRONTEND_EXEC" ] ||
    die "print_file_list returned an empty list (upstream changed the init script interface?)"

# Version and update channel: what "update -v snapshot" would record for these commits
B_SHA="$(git -C "$B" rev-parse HEAD)"
F_SHA="$(git -C "$F" rev-parse HEAD)"
CHANNEL=snapshot

count_lines() { grep -cE "$1" "$2" || true; }

stamp_backend() {
    local file="$DIST/BACKEND/etc/init.d/qosmate"
    [ "$(count_lines '^[[:space:]]*VERSION[[:space:]]*=' "$file")" = 1 ] ||
        die "expected exactly one VERSION= line in the init script"
    [ "$(count_lines '^[[:space:]]*UPD_CHANNEL[[:space:]]*=' "$file")" = 1 ] ||
        die "expected exactly one UPD_CHANNEL= line in the init script"
    sed -i -E "/^[[:space:]]*VERSION[[:space:]]*=/{s/.*/VERSION=\"$B_SHA\"/;}
               /^[[:space:]]*UPD_CHANNEL[[:space:]]*=/{s/.*/UPD_CHANNEL=\"$CHANNEL\"/;}" "$file"
    grep -q "^VERSION=\"$B_SHA\"" "$file" && grep -q "^UPD_CHANNEL=\"$CHANNEL\"" "$file" ||
        die "failed to stamp the backend version"
}

stamp_frontend() {
    local file="$DIST/FRONTEND/www/luci-static/resources/view/qosmate/settings.js"
    [ -f "$file" ] || die "settings.js missing from frontend dist"
    [ "$(count_lines '^[[:space:]]*const UI_VERSION[[:space:]]*=' "$file")" = 1 ] ||
        die "expected exactly one UI_VERSION line in settings.js"
    [ "$(count_lines '^[[:space:]]*const UI_UPD_CHANNEL[[:space:]]*=' "$file")" = 1 ] ||
        die "expected exactly one UI_UPD_CHANNEL line in settings.js"
    sed -i -E "/^[[:space:]]*const UI_VERSION[[:space:]]*=/{s/.*/const UI_VERSION = '$F_SHA';/;}
               /^[[:space:]]*const UI_UPD_CHANNEL[[:space:]]*=/{s/.*/const UI_UPD_CHANNEL = '$CHANNEL';/;}" "$file"
    grep -q "^const UI_VERSION = '$F_SHA';" "$file" && grep -q "^const UI_UPD_CHANNEL = '$CHANNEL';" "$file" ||
        die "failed to stamp the frontend version"
}

stamp_backend
stamp_frontend

install_files() {
    local dist="$1" files="$2" execs="$3" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$dist$f" ] || die "listed file is not in the repository: $f"
        install -D -m 0644 "$dist$f" "$OUT$f"
    done <<< "$files"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$OUT$f" ] || die "executable file is not among the staged files: $f"
        chmod 0755 "$OUT$f"
    done <<< "$execs"
}

# md5 register, same format the updater writes: "<md5>  /absolute/path"
make_reg() {
    local dist="$1" files="$2" reg="$3"
    mkdir -p "$(dirname "$OUT$reg")"
    (cd "$dist" && printf '%s\n' "$files" | sed -e '/^$/d' -e 's~^/~~' | xargs -d '\n' md5sum) |
        sed -E 's~^([0-9a-f]{32})  ~\1  /~' > "$OUT$reg"
    [ -s "$OUT$reg" ] || die "empty md5 register: $reg"
}

install_files "$DIST/BACKEND"  "$BACKEND_FILES"  "$BACKEND_EXEC"
install_files "$DIST/FRONTEND" "$FRONTEND_FILES" "$FRONTEND_EXEC"

grep -q 'backend_reg.md5'  "$INIT" || die "init script no longer mentions backend_reg.md5"
grep -q 'frontend_reg.md5' "$INIT" || die "init script no longer mentions frontend_reg.md5"
make_reg "$DIST/BACKEND"  "$BACKEND_FILES"  /etc/qosmate.d/backend_reg.md5
make_reg "$DIST/FRONTEND" "$FRONTEND_FILES" /etc/qosmate.d/frontend_reg.md5

# Self-check: the same md5sum -c the init script runs at start
for reg in backend_reg.md5 frontend_reg.md5; do
    (cd "$OUT" && sed -E 's~  /~  ~' "etc/qosmate.d/$reg" | md5sum -c --quiet -) ||
        die "md5 register $reg does not match the staged files"
done

{
    echo "backend  $B_SHA ($CHANNEL)"
    echo "frontend $F_SHA ($CHANNEL)"
    echo
    (cd "$OUT" && find . -type f -printf '%m %p\n' | sort -k2)
} > "$W/qosmate-staged.txt"

echo "QoSmate staged into $OUT"
echo "  backend  $B_SHA ($CHANNEL)"
echo "  frontend $F_SHA ($CHANNEL)"
cat "$W/qosmate-staged.txt" | sed -n '4,$p'
