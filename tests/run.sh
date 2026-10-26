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
echo 'HOOKS=(base udev boot-wake-numpad plymouth keyboard autodetect kms block encrypt filesystems fsck)' \
  >"$work/etc/mkinitcpio.conf.d/zz_numpad.conf"
check "number pad hook is protected" "" "$(reason "$omarchy_cmdline")"
rm "$work/etc/mkinitcpio.conf.d/zz_numpad.conf"
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
helper boot-menu-set 2.5 2>/dev/null
check "half seconds written" "timeout: 2.5 # set by Boot & Wake" "$(sed -n 2p "$conf")"
helper boot-menu-restore 2>/dev/null
rm -f "$work/snapper.log"
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
check "5 seconds refused" "1" "$(helper boot-menu-set 5 2>/dev/null; echo $?)"
check "quarter seconds refused" "1" "$(helper boot-menu-set 1.25 2>/dev/null; echo $?)"
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

# --- Number pad at the password screen ----------------------------------------
# Rebuilds are faked; the log shows whether the hook was in place at the time.
nroot=$work/nroot
mkdir -p "$nroot/boot" "$nroot/etc/mkinitcpio.conf.d"
printf '%s\n' "$omarchy_conf" >"$nroot/boot/limine.conf"
echo 'HOOKS=(base udev plymouth keyboard autodetect block encrypt filesystems)' \
  >"$nroot/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
cat >"$work/bin/limine-mkinitcpio" <<SH
#!/bin/sh
[ -f "$nroot/etc/initcpio/hooks/boot-wake-numpad" ] && echo with >>"$work/rebuild.log" || echo without >>"$work/rebuild.log"
[ ! -f "$work/rebuild-fails" ]
SH
chmod +x "$work/bin/limine-mkinitcpio"
nhelper() { BW_TEST_ROOT="$nroot" PATH="$work/bin:$PATH" "$repo/bin/boot-wake-root" "$@"; }
numpad_files() {
  local f n=0
  for f in initcpio/hooks/boot-wake-numpad initcpio/install/boot-wake-numpad mkinitcpio.conf.d/zz-boot-wake-numpad.conf; do
    [[ -f $nroot/etc/$f ]] && n=$((n + 1))
  done
  echo "$n"
}

rm -f "$work/snapper.log" "$work/rebuild.log"
check "numpad on succeeds" "0" "$(nhelper numpad-on 2>/dev/null; echo $?)"
check "numpad files written" "3" "$(numpad_files)"
check "numpad snapshot first" "1" "$(grep -c create "$work/snapper.log")"
check "numpad image rebuilt with hook" "with" "$(cat "$work/rebuild.log")"
check "numpad on again changes nothing" "0 with" "$(nhelper numpad-on 2>/dev/null; echo $? $(cat "$work/rebuild.log"))"

# The drop-in, read the way mkinitcpio reads it, with the hook paths faked.
hooks_with_dropin() {
  sed "s#/etc/initcpio#$nroot/etc/initcpio#g" "$nroot/etc/mkinitcpio.conf.d/zz-boot-wake-numpad.conf" >"$work/dropin.conf"
  bash -c 'HOOKS=(base udev plymouth keyboard encrypt); source "$1"; source "$1"; echo "${HOOKS[*]}"' _ "$work/dropin.conf"
}
check "hook runs just before plymouth, once" "base udev boot-wake-numpad plymouth keyboard encrypt" "$(hooks_with_dropin)"
rm "$nroot/etc/initcpio/hooks/boot-wake-numpad"
check "missing hook file leaves HOOKS alone" "base udev plymouth keyboard encrypt" "$(hooks_with_dropin)"

rm -f "$work/rebuild.log"
check "numpad off succeeds" "0" "$(nhelper numpad-off 2>/dev/null; echo $?)"
check "numpad files removed" "0" "$(numpad_files)"
check "numpad image rebuilt without hook" "without" "$(cat "$work/rebuild.log")"

rm -f "$work/rebuild.log"
touch "$work/rebuild-fails"
check "failed rebuild refused" "1" "$(nhelper numpad-on 2>/dev/null; echo $?)"
check "failed rebuild undone" "0" "$(numpad_files)"
check "image rebuilt again without hook" "with without" "$(paste -sd' ' "$work/rebuild.log")"
rm "$work/rebuild-fails"

echo 'HOOKS=(base udev keyboard autodetect block encrypt filesystems)' \
  >"$nroot/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
check "no plymouth refused" "1" "$(nhelper numpad-on 2>/dev/null; echo $?)"
echo 'HOOKS=(base systemd plymouth autodetect block sd-encrypt filesystems)' \
  >"$nroot/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
check "systemd image refused" "1" "$(nhelper numpad-on 2>/dev/null; echo $?)"
check "refusals write nothing" "0" "$(numpad_files)"

# The hook itself, run by the startup image's own shell.
echo 'HOOKS=(base udev plymouth keyboard autodetect block encrypt filesystems)' \
  >"$nroot/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
nhelper numpad-on 2>/dev/null
ash=/usr/lib/initcpio/busybox
[[ -x $ash ]] && ash="$ash ash" || ash=sh
vconsole() {
  printf '%s\n' "$@" >"$work/vconsole.conf"
  BW_VCONSOLE="$work/vconsole.conf" $ash -c ". '$nroot/etc/initcpio/hooks/boot-wake-numpad'; run_hook" &&
    paste -sd'|' "$work/vconsole.conf"
}
check "options extended" "KEYMAP=us|XKBLAYOUT=us|XKBOPTIONS=terminate:ctrl_alt_bksp,numpad:mac" \
  "$(vconsole KEYMAP=us XKBLAYOUT=us XKBOPTIONS=terminate:ctrl_alt_bksp)"
check "quoted options extended" "XKBLAYOUT=de|XKBOPTIONS=caps:escape,numpad:mac" \
  "$(vconsole XKBLAYOUT=de 'XKBOPTIONS="caps:escape"')"
check "options added" "XKBLAYOUT=us|XKBOPTIONS=numpad:mac" "$(vconsole XKBLAYOUT=us)"
check "own numpad choice kept" "XKBLAYOUT=us|XKBOPTIONS=numpad:pc" "$(vconsole XKBLAYOUT=us XKBOPTIONS=numpad:pc)"
rm -f "$work/vconsole.conf"
check "no vconsole.conf is fine" "0" \
  "$(BW_VCONSOLE="$work/vconsole.conf" $ash -c ". '$nroot/etc/initcpio/hooks/boot-wake-numpad'; run_hook"; echo $?)"
nhelper numpad-off 2>/dev/null

echo "$pass passed, $failed failed"
(( failed == 0 ))
