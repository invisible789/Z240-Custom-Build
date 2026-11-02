#!/usr/bin/env bash
# dry-run.sh <workdir>
#
# The part of the dry run that goes beyond config checks. Runs after fetch-sources, feeds, stage-qosmate,
# make defconfig and check.sh pre. It does NOT compile the toolchain, kernel or packages. It proves:
#
#   download   every source tarball for the selected config can be fetched and passes its hash check
#   tools      the host tools build (the same ones the full build needs first)
#   kernel     all kernel patches apply to the selected kernel
#   packages   the patches of the requested packages apply on current main (unpack + patch only)
#
# Every stage runs even if an earlier one failed, so one run reports everything.
# Writes <workdir>/summary.txt. Exit status 1 if any stage failed.
set -uo pipefail

W="${1:?usage: dry-run.sh <workdir>}"
W="$(cd "$W" && pwd)"
cd "$W/openwrt" || exit 2
JOBS="$(nproc)"

PATCH_FAIL='Hunk #[0-9]+ FAILED|can.t find file to patch|Patch failed|saving rejects|Failed to apply'
DL_FAIL='Download failed|Hash check failed|Cannot download|All mirrors|download.pl.*(failed|error)'

# Requested packages that carry source and patches (feed path is resolved below)
PREPARE_PKGS="e2fsprogs chrony unbound vsftpd aria2 minidlna nvme-cli libnvme"

: > "$W/summary.txt"
failed=0
say()  { echo "$*" | tee -a "$W/summary.txt"; }
pass() { say "PASS  $1${2:+  ($2)}"; }
miss() { say "FAIL  $1${2:+  ($2)}"; failed=1; }

echo "== download: all sources for the selected config"
if make download -j8 > "$W/download.log" 2>&1; then
    if grep -qE "$DL_FAIL" "$W/download.log"; then
        miss download "$(grep -E "$DL_FAIL" "$W/download.log" | head -n 3 | tr '\n' ';')"
    else
        pass download "$(du -sh dl 2>/dev/null | cut -f1) in dl/"
    fi
else
    miss download "make download failed; see download.log"
fi

echo "== tools: host tools"
if make tools/install -j"$JOBS" > "$W/tools-install.log" 2>&1; then
    pass "host tools"
else
    miss "host tools" "see tools-install.log"
fi

echo "== kernel: patches"
if make target/linux/prepare V=s > "$W/kernel-prepare.log" 2>&1; then
    if grep -qE "$PATCH_FAIL" "$W/kernel-prepare.log"; then
        miss "kernel patches" "$(grep -E "$PATCH_FAIL" "$W/kernel-prepare.log" | head -n 3 | tr '\n' ';')"
    else
        pass "kernel patches" "$(grep -m1 '^KERNEL_PATCHVER:=' target/linux/x86/Makefile)"
    fi
else
    miss "kernel prepare" "see kernel-prepare.log"
fi

echo "== packages: patches of the requested packages"
: > "$W/package-prepare.log"
for p in $PREPARE_PKGS; do
    dir="$(ls -d "package/feeds/packages/$p" "package/feeds/luci/$p" "package/utils/$p" 2>/dev/null | head -n 1)"
    if [ -z "$dir" ]; then
        miss "package $p" "not found in the tree"
        continue
    fi
    {
        echo "=================== $p ($dir)"
    } >> "$W/package-prepare.log"
    if make "$dir/prepare" V=s >> "$W/package-prepare.log" 2>&1; then
        # Look only at this package's section
        if awk -v p="$p" '$0 ~ "^=================== "p" "{f=1;next} /^=================== /{f=0} f' "$W/package-prepare.log" |
            grep -qE "$PATCH_FAIL"; then
            miss "package $p" "patch failure"
        else
            pass "package $p" "sources unpacked and patched"
        fi
    else
        miss "package $p" "prepare failed; see package-prepare.log"
    fi
done

echo
if [ "$failed" -eq 0 ]; then
    say "DRY RUN STAGES: ALL PASSED"
else
    say "DRY RUN STAGES: FAILED"
fi
exit "$failed"
