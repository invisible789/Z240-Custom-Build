#!/usr/bin/env bash
# publish-logs.sh <workdir> <mode> <conclusion>
#
# Publishes a run report to the "ci-logs" branch of this repository so it can be read with a plain
# git fetch, no Actions login needed:
#
#   LATEST.txt                      one-line pointer to the newest run
#   runs/<id>-<mode>/RUN.txt        run metadata and conclusion
#   runs/<id>-<mode>/*.log          step logs (tails; full logs stay in the run's artifact)
#
# History is kept (one commit per run); the push is retried if another run pushed first.
# Needs GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SHA in the environment.
set -uo pipefail

W="${1:?usage: publish-logs.sh <workdir> <mode> <conclusion>}"
MODE="${2:?}"
CONCLUSION="${3:?}"
RUN="${GITHUB_RUN_ID:?}"
REPO="${GITHUB_REPOSITORY:?}"
# PUBLISH_URL overrides the remote (used only for testing against a local bare repository)
URL="${PUBLISH_URL:-https://x-access-token:${GITHUB_TOKEN:?}@github.com/${REPO}}"
TAIL_LINES="${TAIL_LINES:-1500}"

R="$(mktemp -d)"
OUT="$R/runs/${RUN}-${MODE}"
mkdir -p "$OUT"

# Logs: tails only, so a huge build log cannot bloat the branch
for f in sources.txt feeds.log defconfig.log pre-check.log selected-packages.txt qosmate-staged.txt \
         download.log tools-install.log kernel-prepare.log package-prepare.log post-check.log; do
    [ -f "$W/$f" ] && tail -n "$TAIL_LINES" "$W/$f" > "$OUT/$f"
done
if [ -f "$W/build.log" ]; then
    tail -n "$TAIL_LINES" "$W/build.log" > "$OUT/build-tail.log"
    grep -nE 'error:|Error [0-9]+|\*\*\*|undefined reference|No rule to make target|Package .* is missing dependencies' \
        "$W/build.log" | tail -n 150 > "$OUT/build-errors.log" || true
    echo "build.log lines: $(wc -l < "$W/build.log")" >> "$OUT/RUN.txt"
fi
# Per-package build logs of failed packages (OpenWrt writes them under logs/ when a package fails)
if [ -d "$W/openwrt/logs" ]; then
    (cd "$W/openwrt" && find logs -type f -name '*.txt' | head -n 40 | while read -r f; do
        mkdir -p "$OUT/openwrt-logs/$(dirname "$f")"
        tail -n 300 "$f" > "$OUT/openwrt-logs/$f"
    done)
fi
[ -f "$W/summary.txt" ] && cp "$W/summary.txt" "$OUT/summary.txt"

{
    echo "run        $RUN"
    echo "mode       $MODE"
    echo "result     $CONCLUSION"
    echo "finished   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "trigger    ${GITHUB_EVENT_NAME:-?} ${GITHUB_REF_NAME:-?}"
    echo "repo sha   ${GITHUB_SHA:-?}"
    echo "run url    https://github.com/${REPO}/actions/runs/${RUN}"
} >> "$OUT/RUN.txt"

LATEST="$(printf 'run=%s mode=%s result=%s finished=%s dir=runs/%s-%s' \
    "$RUN" "$MODE" "$CONCLUSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN" "$MODE")"

# Add to the existing branch history, retrying if another run pushed in between
for attempt in 1 2 3 4 5; do
    rm -rf "$R/repo"
    if git ls-remote --exit-code --heads "$URL" ci-logs >/dev/null 2>&1; then
        git clone -q --depth 1 --branch ci-logs "$URL" "$R/repo" || { sleep 5; continue; }
    else
        git init -q -b ci-logs "$R/repo"
        git -C "$R/repo" remote add origin "$URL"
    fi
    mkdir -p "$R/repo/runs"
    rm -rf "$R/repo/runs/${RUN}-${MODE}"
    cp -r "$OUT" "$R/repo/runs/${RUN}-${MODE}"
    printf '%s\n' "$LATEST" > "$R/repo/LATEST.txt"
    # Keep only the 15 newest run directories
    ls -1dt "$R/repo"/runs/*/ 2>/dev/null | tail -n +16 | xargs -r rm -rf
    git -C "$R/repo" config user.email "ci@users.noreply.github.com"
    git -C "$R/repo" config user.name "ci"
    git -C "$R/repo" add -A
    git -C "$R/repo" commit -q -m "logs: run $RUN ($MODE, $CONCLUSION)" || true
    if git -C "$R/repo" push -q origin ci-logs; then
        echo "published logs to branch ci-logs: runs/${RUN}-${MODE}"
        exit 0
    fi
    echo "push to ci-logs failed (attempt $attempt), retrying"
    sleep $((attempt * 4))
done
echo "could not publish logs to ci-logs" >&2
exit 1
