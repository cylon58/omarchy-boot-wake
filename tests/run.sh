#!/bin/bash

# Unprivileged tests for the decision logic and the boot config editor.
# Run: tests/run.sh

set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 failed=0

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual == "$expected" ]]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

# shellcheck source=../lib/common.sh
source "$repo/lib/common.sh"

# --- Is skipping the lock after hibernate safe? -------------------------------
BW_SKIP_DEVICE_CHECK=1
BW_MKINITCPIO_DIR="$work/etc"
BW_KEYFILE="$work/crypto_keyfile.bin"
mkdir -p "$work/etc/mkinitcpio.conf.d"
initramfs() { printf '%s\n' "$@" >"$work/etc/mkinitcpio.conf"; }
reason() { printf '%s' "$1" >"$work/cmdline"; BW_CMDLINE_FILE="$work/cmdline" bw_hibernate_unprotected_reason; }
omarchy_cmdline='cryptdevice=PARTUUID=x:root root=/dev/mapper/root resume=/dev/mapper/root resume_offset=1 quiet'

# Omarchy's real layout: a base file, then a drop-in that replaces HOOKS.
initramfs 'MODULES=()' 'FILES=()' 'HOOKS=(base systemd autodetect block filesystems)'
echo 'HOOKS=(base udev plymouth keyboard autodetect kms block encrypt filesystems fsck)' \
  >"$work/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
check "omarchy default is protected" "" "$(reason "$omarchy_cmdline")"
check "no hibernation" "hibernation is not set up" \
  "$(reason 'cryptdevice=PARTUUID=x:root root=/dev/mapper/root quiet')"
check "key file on cmdline" "the disk may unlock without a typed password" \
  "$(reason 'cryptdevice=PARTUUID=x:root cryptkey=rootfs:/key resume=/dev/mapper/root')"
check "systemd unlock may use TPM" "the disk may unlock without a typed password" \
  "$(reason 'rd.luks.name=abc=root root=/dev/mapper/root resume=/dev/mapper/root')"
check "luks. without rd. prefix" "the disk may unlock without a typed password" \
  "$(reason 'luks.uuid=abc cryptdevice=PARTUUID=x:root resume=/dev/mapper/root')"

echo 'FILES+=(/crypto_keyfile.bin)' >"$work/etc/mkinitcpio.conf.d/zz_key.conf"
check "keyfile baked into initramfs" "the disk may unlock without a typed password" "$(reason "$omarchy_cmdline")"
rm "$work/etc/mkinitcpio.conf.d/zz_key.conf"
touch "$BW_KEYFILE"
check "default keyfile present" "the disk may unlock without a typed password" "$(reason "$omarchy_cmdline")"
rm "$BW_KEYFILE"

echo 'HOOKS=(base systemd autodetect block sd-encrypt filesystems)' >"$work/etc/mkinitcpio.conf.d/zz_sd.conf"
check "sd-encrypt refused" "the disk may unlock without a typed password" "$(reason "$omarchy_cmdline")"
rm "$work/etc/mkinitcpio.conf.d/zz_sd.conf"
rm "$work/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
check "hooks unreadable or missing encrypt" "the disk may unlock without a typed password" "$(reason "$omarchy_cmdline")"
echo 'HOOKS=(base udev autodetect block encrypt filesystems)' >"$work/etc/mkinitcpio.conf.d/omarchy_hooks.conf"

unset BW_SKIP_DEVICE_CHECK
check "unencrypted resume device" "the hibernation image is not on an encrypted disk" \
  "$(reason 'cryptdevice=PARTUUID=x:root resume=/dev/null')"

# --- Which sleep is coming? ---------------------------------------------------
action() { printf '%s\n' "$@" | bw_sleep_actions_from_journal | tail -n1; }
id=$BW_LOGIND_SLEEP_ID

check "menu hibernate" "hibernate" \
  "$(action '{"MESSAGE":"hibernate requested from client"}' "{\"MESSAGE_ID\":\"$id\",\"ACTION\":\"hibernate\",\"MESSAGE\":\"The system will hibernate now!\"}")"
check "menu suspend" "suspend" "$(action "{\"MESSAGE_ID\":\"$id\",\"ACTION\":\"suspend\",\"MESSAGE\":\"x\"}")"
check "lid suspend" "suspend" "$(action '{"MESSAGE":"Suspending..."}')"
check "key hibernate" "hibernate" "$(action '{"MESSAGE":"Hibernating..."}')"
check "suspend-then-hibernate" "suspend-then-hibernate" "$(action '{"MESSAGE":"Suspending, then hibernating..."}')"
check "hybrid sleep" "hybrid-sleep" "$(action '{"MESSAGE":"Hibernating and suspending..."}')"
check "latest wins" "suspend" "$(action '{"MESSAGE":"Hibernating..."}' '{"MESSAGE":"Suspending..."}')"
check "binary message ignored" "" "$(action '{"MESSAGE":[27,91]}')"
check "nothing announced" "" "$(action '{"MESSAGE":"Lid closed."}')"

# --- Boot menu editor ---------------------------------------------------------
mkdir -p "$work/root/boot" "$work/bin"
printf '#!/bin/sh\necho "snapper $*" >>"%s/snapper.log"\n' "$work" >"$work/bin/snapper"
chmod +x "$work/bin/snapper"
helper() { BW_TEST_ROOT="$work/root" PATH="$work/bin:$PATH" "$repo/bin/boot-wake-root" "$@"; }
conf=$work/root/boot/limine.conf
omarchy_conf=$'### Read more\n#timeout: 3\ndefault_entry: 2\n\n/+Omarchy\n  //linux\n    protocol: efi'

printf '%s\n' "$omarchy_conf" >"$conf"
helper boot-menu-set 1 2>/dev/null
check "commented timeout replaced" "timeout: 1 # set by Boot & Wake" "$(sed -n 2p "$conf")"
check "rest of config untouched" "$(printf '%s\n' "$omarchy_conf" | sed 2d)" "$(sed 2d "$conf")"
check "snapshot taken first" "1" "$(grep -c 'create' "$work/snapper.log")"
check "ESP backup kept" "$omarchy_conf" "$(cat "$conf.boot-wake.bak")"
helper boot-menu-set 1 2>/dev/null
helper boot-menu-restore 2>/dev/null
check "restore is exact after repeat" "$omarchy_conf" "$(cat "$conf")"
check "backup removed after restore" "no" "$([[ -e $conf.boot-wake.bak ]] && echo yes || echo no)"

printf 'default_entry: 2\n/+Omarchy\n' >"$conf"
helper boot-menu-set 2 2>/dev/null
check "missing timeout added" $'timeout: 2 # set by Boot & Wake\ndefault_entry: 2\n/+Omarchy' "$(cat "$conf")"
helper boot-menu-restore 2>/dev/null
check "added line removed on restore" $'default_entry: 2\n/+Omarchy' "$(cat "$conf")"

printf '%s\n' "$omarchy_conf" >"$conf"
check "bad seconds refused" "1" "$(helper boot-menu-set 0 2>/dev/null; echo $?)"
check "config unchanged after refusal" "$omarchy_conf" "$(cat "$conf")"

printf '#!/bin/sh\nexit 1\n' >"$work/bin/snapper"
check "no snapshot, no change" "1" "$(helper boot-menu-set 1 2>/dev/null; echo $?)"
check "config unchanged without snapshot" "$omarchy_conf" "$(cat "$conf")"
printf '#!/bin/sh\necho "snapper $*" >>"%s/snapper.log"\n' "$work" >"$work/bin/snapper"

# Root rolled back past the change: the saved line is gone, the ESP backup is not.
helper boot-menu-set 1 2>/dev/null
rm -rf "$work/root/var/lib/boot-wake"
helper boot-menu-restore 2>/dev/null
check "restore falls back to ESP backup" "$omarchy_conf" "$(cat "$conf")"

mkdir -p "$work/root/etc"
echo 'ENABLE_ENROLL_LIMINE_CONFIG = "yes"' >"$work/root/etc/limine-entry-tool.conf"
check "enrolled config refused" "1" "$(helper boot-menu-set 1 2>/dev/null; echo $?)"
check "enrolled config untouched" "$omarchy_conf" "$(cat "$conf")"
rm "$work/root/etc/limine-entry-tool.conf"

mkdir -p "$work/root/sys/firmware/efi/efivars"
printf '\x06\x00\x00\x00\x01' >"$work/root/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
check "Secure Boot refused" "1" "$(helper boot-menu-set 1 2>/dev/null; echo $?)"
check "Secure Boot config untouched" "$omarchy_conf" "$(cat "$conf")"
printf '\x06\x00\x00\x00\x00' >"$work/root/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
check "Secure Boot off is allowed" "0" "$(helper boot-menu-set 1 2>/dev/null; echo $?)"
helper boot-menu-restore 2>/dev/null

# The Limine tools say the ESP is /efi: edit that file, not /boot.
echo 'ESP_PATH="/efi"' >"$work/root/etc/default-limine"
mkdir -p "$work/root/etc/default" "$work/root/efi"
mv "$work/root/etc/default-limine" "$work/root/etc/default/limine"
printf '%s\n' "$omarchy_conf" >"$work/root/efi/limine.conf"
helper boot-menu-set 1 2>/dev/null
check "ESP_PATH followed" "timeout: 1 # set by Boot & Wake" "$(sed -n 2p "$work/root/efi/limine.conf")"
check "other limine.conf untouched" "$omarchy_conf" "$(cat "$conf")"
helper boot-menu-restore 2>/dev/null
check "ESP_PATH restore" "$omarchy_conf" "$(cat "$work/root/efi/limine.conf")"

echo "$pass passed, $failed failed"
(( failed == 0 ))
