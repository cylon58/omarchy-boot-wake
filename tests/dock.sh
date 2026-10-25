#!/bin/bash

# Drives bin/dock-guard through simulated docks and sleeps with fake
# dbus-monitor, systemd-inhibit and busctl. Run: tests/dock.sh

set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 failed=0
fake=$work/bin
mkdir -p "$fake" "$work/drm/card1-eDP-1" "$work/drm/card1-DP-7"
echo connected >"$work/drm/card1-eDP-1/status"

check() {
  if [[ $3 == "$2" ]]; then pass=$((pass + 1))
  else failed=$((failed + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# logind's Docked property comes from a file the scenario edits.
cat >"$fake/busctl" <<'SH'
#!/bin/bash
cat "$WORK/docked"
SH
cat >"$fake/systemd-inhibit" <<'SH'
#!/bin/bash
echo take >>"$WORK/events"
trap 'echo release >>"$WORK/events"' EXIT
trap 'exit 0' TERM
sleep infinity & wait
SH
# dbus-monitor plays the scenario; `mark` notes the time in the event log.
cat >"$fake/dbus-monitor" <<'SH'
#!/bin/bash
dock() { echo "b $1" >"$WORK/docked"; }
cable() { echo "$1" >"$WORK/drm/card1-DP-7/status"; }
mark() { echo "$1" >>"$WORK/events"; }
source "$WORK/scenario"
sleep 0.5
SH
chmod +x "$fake"/*

run() {
  : >"$work/events"; echo "b false" >"$work/docked"
  echo disconnected >"$work/drm/card1-DP-7/status"
  cat >"$work/scenario"
  WORK=$work PATH="$fake:$PATH" BW_DRM_DIR="$work/drm" BW_DOCK_POLL=0.2 BW_DOCK_GRACE=2 \
    timeout 20 "$repo/bin/dock-guard" >/dev/null 2>&1
  sleep 0.3
  paste -sd' ' "$work/events"
}

check "never docked holds nothing" "" "$(run <<'S'
sleep 0.5; echo "   boolean true"
sleep 0.3; echo "   boolean false"
S
)"

check "docked holds the lid" "take docked release" "$(run <<'S'
dock true; sleep 0.6; mark docked
S
)"

check "undocking while awake releases at once" "take release undocked" "$(run <<'S'
dock true; sleep 0.6
dock false; sleep 0.6; mark undocked
S
)"

check "dock back soon after waking: held throughout" "take back release" "$(run <<'S'
dock true; sleep 0.6; echo "   boolean true"
dock false; sleep 0.5; echo "   boolean false"
sleep 1; dock true; sleep 0.5; mark back
S
)"

check "dock never returns: released after the grace period" "take waiting release gone" "$(run <<'S'
dock true; sleep 0.6; echo "   boolean true"
dock false; sleep 0.5; echo "   boolean false"
sleep 1; mark waiting
sleep 2; mark gone
S
)"

check "undocking after the dock came back releases at once" "take release undocked" "$(run <<'S'
dock true; sleep 0.6; echo "   boolean true"
dock false; sleep 0.5; echo "   boolean false"
sleep 0.5; dock true; sleep 0.5
dock false; sleep 0.6; mark undocked
S
)"

# The lock screen powers the monitors off: logind stops calling it docked,
# but the cable is still in.
check "monitors switched off: still held" "take dark release" "$(run <<'S'
dock true; cable connected; sleep 0.6
dock false; sleep 3; mark dark
S
)"

check "monitor cable pulled releases at once" "take release unplugged" "$(run <<'S'
cable connected; sleep 0.6
cable disconnected; sleep 0.6; mark unplugged
S
)"

check "held across a long sleep" "take asleep release" "$(run <<'S'
dock true; sleep 0.6; echo "   boolean true"
dock false; sleep 3; mark asleep
S
)"

# The guard must keep running through quiet stretches, not just one poll.
check "survives idle time" "take later release" "$(run <<'S'
sleep 3; dock true; sleep 0.6; mark later
S
)"

echo "$pass passed, $failed failed"
(( failed == 0 ))
