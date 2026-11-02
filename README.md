# Z240 custom build

OpenWrt **main** for the HP Z240 (x86/64, UEFI, ext4 combined image) with **QoSmate built in**.

## What is in the image
`luci block-mount e2fsprogs kmod-fs-ext4 nvme-cli kmod-nvme libnvme vsftpd luci-app-aria2 chrony-nts ethtool
luci-app-adblock unbound-anchor unbound-checkconf luci-app-unbound unbound-control luci-app-minidlna`
(`z240.diffconfig`), plus everything the x86 `generic` profile ships (igb for the i350, PPPoE, firewall4, apk).

`chrony-nts` replaces `chrony` (they conflict; `chrony-nts` provides it).

## How QoSmate is built in
The OpenWrt `Makefile`s in the QoSmate repositories date from early 2025 and do not install the current file set
(no `luci.qosmate_stats`, autorate scripts, `.dist` files or `qosmate-defaults`). So the build stages the files itself
(`scripts/stage-qosmate.sh`) into `files/`, i.e. the same file set QoSmate's updater leaves on a device after
`service qosmate update -v snapshot`:

- the file lists come from QoSmate's own init script (`print_file_list`), so a new upstream file is picked up automatically;
- `VERSION` / `UPD_CHANNEL` are stamped (commit SHA, `snapshot`), so the init script does not self-update on first start;
- the md5 registers it verifies at start are generated and re-verified at build time;
- `/etc/config/qosmate` is not shipped: like a normal install, it is created from `/etc/qosmate.d/qosmate-defaults`
  on the first `service qosmate start`.

QoSmate's runtime packages (`kmod-sched-cake`, `tc-full`, `ip-full`, `jq`, `coreutils-sleep`, ...) are in the diffconfig,
and `check.sh` fails if a new one appears in upstream's `REQUIRED_PACKAGES`.
It is **not enabled at boot** until you run `service qosmate start` once.

## Pinned inputs
`pins.env` pins OpenWrt, the packages and luci feeds, QoSmate and luci-app-qosmate to commits.
The dry run and the final build read the same file, so a dry run describes exactly what the final build compiles.
To move to newer upstream, edit the SHAs (or put `main`).

## Running it
Either push a branch (this is how it is started without a token) or use Actions -> *Z240 custom build* -> Run workflow.

| Start | What runs |
|---|---|
| push branch `run-dry` | config, pre-checks, source downloads, host tools, kernel and package patch validation. No compile. |
| push branch `run-build` | the same checks, then the full build, post-checks, and the image as an artifact (`z240-custom-build`). |

## Reports
Every run publishes a report to the **`ci-logs`** branch (readable with a plain `git fetch`): `LATEST.txt` points at the
newest run, `runs/<id>-<mode>/` holds `summary.txt`, `pre-check.log`, `post-check.log`, `download.log`,
`kernel-prepare.log`, `package-prepare.log`, `build-errors.log`, `build-tail.log`, `sources.txt` and `selected-packages.txt`.
Full logs are also attached to the run as an artifact.

## Not checked by CI
Whether the image boots and runs on your Z240. Keep the current system and a config backup (`sysupgrade -b`).
