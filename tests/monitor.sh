#!/bin/bash

# Drives bin/sleep-monitor through simulated sleeps with fake dbus-monitor,
# systemd-inhibit, journalctl and lock script. Run: tests/monitor.sh

set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 failed=0
fake=$work/bin
mkdir -p "$fake" "$work/omarchy/bin" "$work/etc/mkinitcpio.conf.d"

check() {
  if [[ $3 == "$2" ]]; then pass=$((pass + 1))
  else failed=$((failed + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# Journal: one JSON entry per line; the cursor is the line count.
cat >"$fake/journalctl" <<'SH'
#!/bin/bash
entries=$WORK/journal
touch "$entries"
if [[ " $* " == *" --show-cursor "* ]]; then echo "-- cursor: $(wc -l <"$entries")"; exit; fi
after=0
while (( $# )); do [[ $1 == --after-cursor ]] && after=$2; shift; done
tail -n +"$((after + 1))" "$entries"
SH
# The inhibitor logs take/release so the order can be checked.
cat >"$fake/systemd-inhibit" <<'SH'
#!/bin/bash
echo take >>"$WORK/events"
trap 'echo release >>"$WORK/events"; exit 0' TERM
sleep infinity & wait
echo release >>"$WORK/events"
SH
cat >"$work/omarchy/bin/omarchy-system-sleep-lock" <<'SH'
#!/bin/bash
echo "lock${1:+ budget}" >>"$WORK/events"
SH
# dbus-monitor plays the scenario: each step may edit the journal or the
# sleep clock, then emits a PrepareForSleep value.
cat >"$fake/dbus-monitor" <<'SH'
#!/bin/bash
source "$WORK/scenario"
sleep 1
SH
chmod +x "$fake"/* "$work/omarchy/bin"/*

printf '%s' 'cryptdevice=PARTUUID=x:root resume=/dev/mapper/root' >"$work/cmdline"
echo 'HOOKS=(base udev autodetect block encrypt filesystems)' >"$work/etc/mkinitcpio.conf"

announce() { echo "{\"MESSAGE_ID\":\"9e7066279dc8403da79ce4b1a69064b2\",\"ACTION\":\"$1\"}" >>"$WORK/journal"; }
run() {
  : >"$work/events"; : >"$work/journal"; echo 100 >"$work/slept"
  { declare -f announce; cat; } >"$work/scenario"
  WORK=$work PATH="$fake:$PATH" OMARCHY_PATH="$work/omarchy" \
    BW_CMDLINE_FILE="$work/cmdline" BW_MKINITCPIO_DIR="$work/etc" BW_KEYFILE="$work/none" \
    BW_SKIP_DEVICE_CHECK=1 BW_TEST_SLEPT_FILE="$work/slept" \
    timeout 10 "$repo/bin/sleep-monitor" >/dev/null 2>&1
  sleep 0.3
  paste -sd' ' "$work/events"
}

check "suspend locks, then re-arms" "take lock budget release take release" "$(run <<'S'
sleep 0.3; announce suspend; echo "   boolean true"
sleep 0.3; echo "   boolean false"
S
)"

check "hibernate skips the lock" "take release take release" "$(run <<'S'
sleep 0.3; announce hibernate; echo "   boolean true"
sleep 0.3; echo 500 >"$WORK/slept"; echo "   boolean false"
S
)"

check "failed hibernate locks on return" "take release take lock release" "$(run <<'S'
sleep 0.3; announce hibernate; echo "   boolean true"
sleep 0.3; echo "   boolean false"
S
)"

check "stale hibernate is not trusted" "take release take lock lock budget release take release" "$(run <<'S'
sleep 0.3; announce hibernate; echo "   boolean true"
sleep 0.3; echo "   boolean false"
sleep 0.3; echo "   boolean true"
sleep 0.3; echo 500 >"$WORK/slept"; echo "   boolean false"
S
)" 
# ^ the first return locks (no sleep time), the second sleep has no fresh
#   announcement, so it is treated as unknown and locks too.

check "no announcement locks" "take lock budget release take release" "$(run <<'S'
sleep 0.3; echo "   boolean true"
sleep 0.3; echo "   boolean false"
S
)"

check "hibernate while unprotected locks" "take lock budget release take release" "$(
  echo 'HOOKS=(base systemd sd-encrypt)' >"$work/etc/mkinitcpio.conf"
  run <<'S'
sleep 0.3; announce hibernate; echo "   boolean true"
sleep 0.3; echo 500 >"$WORK/slept"; echo "   boolean false"
S
  echo 'HOOKS=(base udev autodetect block encrypt filesystems)' >"$work/etc/mkinitcpio.conf"
)"

echo "$pass passed, $failed failed"
(( failed == 0 ))
