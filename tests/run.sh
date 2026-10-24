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
BW_CRYPTTAB_FILES="$work/crypttab"
: >"$work/crypttab"
reason() { printf '%s' "$1" >"$work/cmdline"; BW_CMDLINE_FILE="$work/cmdline" bw_hibernate_unprotected_reason; }

check "omarchy default is protected" "" \
  "$(reason 'cryptdevice=PARTUUID=x:root root=/dev/mapper/root resume=/dev/mapper/root resume_offset=1 quiet')"
check "no hibernation" "hibernation is not set up" \
  "$(reason 'cryptdevice=PARTUUID=x:root root=/dev/mapper/root quiet')"
check "key file unlock" "the disk may unlock without a typed password" \
  "$(reason 'cryptdevice=PARTUUID=x:root cryptkey=rootfs:/key resume=/dev/mapper/root')"
check "systemd unlock may use TPM" "the disk may unlock without a typed password" \
  "$(reason 'rd.luks.name=abc=root root=/dev/mapper/root resume=/dev/mapper/root')"
echo 'root UUID=abc none tpm2-device=auto' >"$work/crypttab"
check "TPM in crypttab" "the disk may unlock without a typed password" \
  "$(reason 'cryptdevice=PARTUUID=x:root resume=/dev/mapper/root')"
: >"$work/crypttab"
unset BW_SKIP_DEVICE_CHECK
check "unencrypted resume device" "the hibernation image is not on an encrypted disk" \
  "$(reason 'resume=/dev/null')"

# --- Which sleep is coming? ---------------------------------------------------
action() { printf '%s\n' "$@" | bw_sleep_action_from_journal; }
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

echo "$pass passed, $failed failed"
(( failed == 0 ))
