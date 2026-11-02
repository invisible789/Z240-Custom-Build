#!/usr/bin/env bash
# check.sh pre|post <openwrt-dir>
#
#   pre   after feeds + make defconfig + stage-qosmate: pins, feeds, .config, QoSmate file set
#   post  after the full build: image, package manifest, rootfs
#
# Every check runs; failures are collected, not fatal. Exit status 0 only if all passed.
#
# Environment (set by the workflow, all optional):
#   SOURCES_FILE    sources.txt written by fetch-sources.sh   (default: <openwrt-dir>/../sources.txt)
#   DEFCONFIG_LOG   output of "make defconfig"                (default: <openwrt-dir>/../defconfig.log)
set -u

STAGE="${1:?usage: check.sh pre|post <openwrt-dir>}"
DIR="${2:?usage: check.sh pre|post <openwrt-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(dirname "$HERE")"
DIFFCONFIG="$BUNDLE/z240.diffconfig"
cd "$DIR" || { echo "no such dir: $DIR"; exit 2; }
DIR="$PWD"
SOURCES_FILE="${SOURCES_FILE:-$DIR/../sources.txt}"
DEFCONFIG_LOG="${DEFCONFIG_LOG:-$DIR/../defconfig.log}"

fail=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fail=1; }
info() { echo "  info  $*"; }
# Each check runs in a subshell: a check that blows up (unset variable, missing tool) is a FAIL with its
# output shown, never an abort of the whole script.
chk() {
    local d="$1" out; shift
    if out="$( ( "$@" ) 2>&1 )"; then
        ok "$d"
    else
        bad "$d"
        [ -n "$out" ] && printf '%s\n' "$out" | head -n 5 | sed 's/^/          | /'
    fi
}
has_glob() { compgen -G "$1" >/dev/null; }

# Packages the diffconfig asks for / forbids
wanted_pkgs()   { sed -n 's/^CONFIG_PACKAGE_\([^=]*\)=y$/\1/p' "$DIFFCONFIG"; }
unwanted_pkgs() { sed -n 's/^# CONFIG_PACKAGE_\(.*\) is not set$/\1/p' "$DIFFCONFIG"; }

# REQUIRED_PACKAGES of the QoSmate init script (the packages it checks with apk at start)
qosmate_required() {
    local init="$DIR/files/etc/init.d/qosmate"
    [ -f "$init" ] || return 1
    sed -n 's/^REQUIRED_PACKAGES="\(.*\)"$/\1/p' "$init" | tr ' ' '\n' | sed '/^$/d'
}

# md5 register verification against a root directory (what the init script's md5sum -c does on a device)
verify_reg() {
    local root="$1" reg="$2"
    [ -s "$root/etc/qosmate.d/$reg" ] || return 1
    (cd "$root" && sed -E 's~  /~  ~' "etc/qosmate.d/$reg" | md5sum -c --quiet -)
}

qosmate_files_present() {
    local root="$1" init f comp n=0
    init="$root/etc/init.d/qosmate"
    [ -f "$init" ] || { echo "init script not found: $init"; return 1; }
    for comp in BACKEND FRONTEND; do
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n=$((n + 1))
            [ -f "$root$f" ] || { echo "missing: $f"; return 1; }
        done < <(cd "$DIR" && env -i PATH="$PATH" sh "$init" print_file_list "$comp" ALL)
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ -x "$root$f" ] || { echo "not executable: $f"; return 1; }
        done < <(cd "$DIR" && env -i PATH="$PATH" sh "$init" print_file_list "$comp" EXEC)
    done
    [ "$n" -gt 0 ]
}

case "$STAGE" in
pre)
  echo "[pre] pinned sources"
  if [ -s "$SOURCES_FILE" ]; then
      while read -r name sha rest; do
          [ -n "$name" ] || continue
          case "$sha" in
              [0-9a-f]*) [ "${#sha}" = 40 ] && ok "$name -> $sha" || bad "$name has no 40-char commit: '$sha'" ;;
              *) bad "$name has no commit in sources.txt" ;;
          esac
      done < "$SOURCES_FILE"
  else
      bad "sources.txt not found ($SOURCES_FILE)"
  fi
  chk "kernel version is defined for x86" grep -q '^KERNEL_PATCHVER:=' target/linux/x86/Makefile
  info "$(grep -m1 '^KERNEL_PATCHVER:=' target/linux/x86/Makefile)"

  echo "[pre] feeds"
  chk "feeds.conf links the pinned feeds" grep -q '^src-link luci ' feeds.conf
  for p in luci; do chk "feed package $p (luci)" test -e "package/feeds/luci/$p"; done
  for p in luci-app-aria2 luci-app-adblock luci-app-unbound luci-app-minidlna luci-lib-jsonc; do
      chk "feed package $p" test -e "package/feeds/luci/$p"
  done
  for p in vsftpd chrony unbound aria2 minidlna adblock nvme-cli libnvme jq coreutils; do
      chk "feed package $p" test -e "package/feeds/packages/$p"
  done

  echo "[pre] make defconfig output"
  if [ -f "$DEFCONFIG_LOG" ]; then
      # "feeds install -a" brings in thousands of packages we do not select, and upstream feeds routinely
      # print Kconfig warnings/errors for some of them (missing deps, recursive deps). Those are reported
      # as info. Only a message that mentions a package we request is a failure; the per-package
      # ".config selects it" checks below are the real guarantee.
      mine="$( { wanted_pkgs; qosmate_required; } 2>/dev/null | sort -u )"
      mentioned=0
      while IFS= read -r p; do
          [ -n "$p" ] || continue
          esc="$(printf '%s' "$p" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
          if hits="$(grep -E "PACKAGE_${esc}([^A-Za-z0-9_+.-]|\$)|/${esc}/Makefile|'${esc}'" "$DEFCONFIG_LOG")"; then
              bad "make defconfig reports a problem involving requested package $p"
              printf '%s\n' "$hits" | head -n 3 | sed 's/^/          | /'
              mentioned=1
          fi
      done <<< "$mine"
      [ "$mentioned" = 0 ] && ok "make defconfig reported nothing about the requested packages"
      n_dep="$(grep -cE 'which does not exist' "$DEFCONFIG_LOG" || true)"
      n_rec="$(grep -cE 'recursive dependency detected' "$DEFCONFIG_LOG" || true)"
      info "unrelated upstream feed warnings (packages we do not select): $n_dep missing-dependency, $n_rec recursive-dependency"
      n="$(grep -ciE 'unmet direct dependencies' "$DEFCONFIG_LOG" || true)"
      info "kconfig 'unmet direct dependencies' warnings: $n"
  else
      info "no defconfig log ($DEFCONFIG_LOG)"
  fi

  echo "[pre] .config: target and image set"
  if [ -f .config ]; then
      chk "target x86/64 generic" grep -q '^CONFIG_TARGET_x86_64_DEVICE_generic=y' .config
      chk "ext4 root filesystem images" grep -q '^CONFIG_TARGET_ROOTFS_EXT4FS=y' .config
      chk "squashfs images off" bash -c '! grep -q "^CONFIG_TARGET_ROOTFS_SQUASHFS=y" .config'
      chk "EFI (GRUB) images on" grep -q '^CONFIG_GRUB_EFI_IMAGES=y' .config
      chk "images are gzip-compressed" grep -q '^CONFIG_TARGET_IMAGES_GZIP=y' .config
      info "boot partition: $(grep '^CONFIG_TARGET_KERNEL_PARTSIZE=' .config | cut -d= -f2) MiB, rootfs partition: $(grep '^CONFIG_TARGET_ROOTFS_PARTSIZE=' .config | cut -d= -f2) MiB"
      chk "Intel igb driver (i350) is in the image" grep -q '^CONFIG_PACKAGE_kmod-igb=y' .config
      chk "PPPoE support (WAN) is in the image" grep -q '^CONFIG_PACKAGE_ppp-mod-pppoe=y' .config
      chk "apk is the package manager" grep -q '^CONFIG_USE_APK=y' .config

      echo "[pre] .config: requested packages (from z240.diffconfig)"
      while read -r p; do
          [ -n "$p" ] || continue
          chk "package $p selected" grep -q "^CONFIG_PACKAGE_${p}=y" .config
      done < <(wanted_pkgs)
      while read -r p; do
          [ -n "$p" ] || continue
          chk "package $p NOT selected" bash -c '! grep -q "^CONFIG_PACKAGE_$1=y" .config' _ "$p"
      done < <(unwanted_pkgs)

      echo "[pre] .config: pulled in by the requested packages"
      for p in aria2 unbound-daemon adblock minidlna luci-base uhttpd; do
          chk "dependency $p selected" grep -q "^CONFIG_PACKAGE_${p}=y" .config
      done
  else
      bad ".config not found (run make defconfig first)"
  fi

  echo "[pre] QoSmate: staged file set (files/)"
  if [ -d files ]; then
      chk "init script stamped with a commit and channel 'snapshot'" bash -c 'grep -qE "^VERSION=\"[0-9a-f]{40}\"" files/etc/init.d/qosmate && grep -q "^UPD_CHANNEL=\"snapshot\"" files/etc/init.d/qosmate'
      chk "LuCI settings.js stamped" bash -c "grep -qE \"^const UI_VERSION = '[0-9a-f]{40}';\" files/www/luci-static/resources/view/qosmate/settings.js"
      chk "every file the init script lists is staged, executables are +x" qosmate_files_present "$DIR/files"
      chk "backend md5 register matches" verify_reg "$DIR/files" backend_reg.md5
      chk "frontend md5 register matches" verify_reg "$DIR/files" frontend_reg.md5
      chk "default config is staged (restored to /etc/config/qosmate on first start)" test -s files/etc/qosmate.d/qosmate-defaults
      chk "stats backend is staged (Statistics and Rules pages)" test -x files/usr/libexec/rpcd/luci.qosmate_stats
      if [ -f .config ]; then
          echo "[pre] QoSmate: REQUIRED_PACKAGES from its init script are in .config"
          reqs="$(qosmate_required)"
          if [ -n "$reqs" ]; then
              for p in $reqs; do
                  chk "required package $p selected" grep -q "^CONFIG_PACKAGE_${p}=y" .config
              done
          else
              bad "could not read REQUIRED_PACKAGES from files/etc/init.d/qosmate"
          fi
      fi
  else
      bad "files/ not found (run stage-qosmate.sh)"
  fi
  ;;

post)
  T=bin/targets/x86/64
  echo "[post] build output ($T)"
  img="$(ls $T/*generic-ext4-combined-efi.img.gz 2>/dev/null | head -1)"
  if [ -n "$img" ]; then
      ok "EFI image: $(basename "$img")"
      chk "image is larger than 15 MB" test "$(stat -c %s "$img")" -gt 15000000
      info "size: $(stat -c %s "$img") bytes"
      (cd "$T" && sha256sum "$(basename "$img")" | tee SHA256SUMS.z240 | sed 's/^/  info  /')
  else
      bad "no *generic-ext4-combined-efi.img.gz in $T"
  fi
  chk "legacy-boot image present" has_glob "$T/*generic-ext4-combined.img.gz"
  chk "no squashfs image" bash -c '! compgen -G "$1/*squashfs*" >/dev/null' _ "$T"

  man="$(ls $T/*generic.manifest 2>/dev/null | head -1)"
  if [ -n "$man" ]; then
      echo "[post] package manifest ($(basename "$man"))"
      info "$(grep -m1 '^kernel - ' "$man")"
      while read -r p; do
          [ -n "$p" ] || continue
          chk "manifest has $p" grep -q "^${p} - " "$man"
      done < <(wanted_pkgs)
      while read -r p; do
          [ -n "$p" ] || continue
          chk "manifest has no $p" bash -c '! grep -q "^$1 - " "$2"' _ "$p" "$man"
      done < <(unwanted_pkgs)
      for p in aria2 unbound-daemon adblock minidlna; do
          chk "manifest has dependency $p" grep -q "^${p} - " "$man"
      done
      reqs="$(qosmate_required)"
      if [ -n "$reqs" ]; then
          for p in $reqs; do
              chk "manifest has QoSmate requirement $p" grep -q "^${p} - " "$man"
          done
      fi
  else
      bad "no manifest in $T"
  fi

  root="$(ls -d build_dir/target-*/root-x86 2>/dev/null | head -1)"
  if [ -n "$root" ]; then
      echo "[post] rootfs ($root)"
      root="$DIR/$root"
      info "rootfs size: $(du -sm "$root" | cut -f1) MiB"
      chk "QoSmate files are in the rootfs, executables are +x" qosmate_files_present "$root"
      chk "backend md5 register matches the rootfs" verify_reg "$root" backend_reg.md5
      chk "frontend md5 register matches the rootfs" verify_reg "$root" frontend_reg.md5
      chk "init script stamped in the rootfs" bash -c 'grep -qE "^VERSION=\"[0-9a-f]{40}\"" "$1/etc/init.d/qosmate"' _ "$root"
      chk "stock QoSmate config is not shipped (created on first start)" test ! -e "$root/etc/config/qosmate"
  else
      info "rootfs dir not found (not fatal; manifest checks above still apply)"
  fi
  ;;

*)
  echo "usage: check.sh pre|post <openwrt-dir>"
  exit 2
  ;;
esac

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL CHECKS PASSED ($STAGE)"
else
    echo "CHECKS FAILED ($STAGE)"
fi
exit "$fail"
