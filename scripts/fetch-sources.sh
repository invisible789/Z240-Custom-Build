#!/usr/bin/env bash
# fetch-sources.sh <workdir>
#
# Fetches every pinned input from pins.env into <workdir>:
#   openwrt/                     OpenWrt at OPENWRT_REF; feeds.conf links the two pinned feeds below
#   src/packages, src/luci       the packages and luci feeds (src-link in feeds.conf)
#   src/qosmate                  QoSmate backend
#   src/luci-app-qosmate         QoSmate LuCI frontend
#   sources.txt                  the commit each input resolved to
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
W="${1:?usage: fetch-sources.sh <workdir>}"
mkdir -p "$W"
W="$(cd "$W" && pwd)"

# shellcheck source=../pins.env
. "$ROOT/pins.env"

: > "$W/sources.txt"

fetch_pin() {
    local name="$1" url="$2" ref="$3" dest="$4" try sha
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$url"
    for try in 1 2 3; do
        if git -C "$dest" fetch -q --depth 1 origin "$ref"; then
            break
        fi
        if [ "$try" = 3 ]; then
            echo "FAILED to fetch $name: $url @ $ref" >&2
            exit 1
        fi
        echo "fetch of $name failed (try $try), retrying" >&2
        sleep $((try * 5))
    done
    git -C "$dest" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
    sha="$(git -C "$dest" rev-parse HEAD)"
    printf '%-18s %s  (%s @ %s)\n' "$name" "$sha" "$url" "$ref" | tee -a "$W/sources.txt"
}

fetch_pin openwrt          "$OPENWRT_REPO"      "$OPENWRT_REF"      "$W/openwrt"
fetch_pin packages         "$PACKAGES_REPO"     "$PACKAGES_REF"     "$W/src/packages"
fetch_pin luci             "$LUCI_REPO"         "$LUCI_REF"         "$W/src/luci"
fetch_pin qosmate          "$QOSMATE_REPO"      "$QOSMATE_REF"      "$W/src/qosmate"
fetch_pin luci-app-qosmate "$LUCI_QOSMATE_REPO" "$LUCI_QOSMATE_REF" "$W/src/luci-app-qosmate"

# Only the two feeds this build needs, linked from the pinned checkouts above.
cat > "$W/openwrt/feeds.conf" <<EOF
src-link packages $W/src/packages
src-link luci $W/src/luci
EOF

echo
echo "feeds.conf:"
cat "$W/openwrt/feeds.conf"
