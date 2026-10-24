# Shared by bin/boot-wake and bin/sleep-monitor. Sourced, never executed.

BW_ID="io.github.cylon58.boot-wake"
BW_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boot-wake"
BW_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}/boot-wake"
BW_SKIP_MARKER="$BW_RUNTIME_DIR/skipped-lock"
BW_DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omarchy-sleep-lock.service.d"
BW_DROPIN="$BW_DROPIN_DIR/$BW_ID.conf"

# Tests point these at fixtures.
BW_CMDLINE_FILE="${BW_CMDLINE_FILE:-/proc/cmdline}"
BW_CRYPTTAB_FILES="${BW_CRYPTTAB_FILES:-/etc/crypttab /etc/crypttab.initramfs}"

# logind's "The system will <action> now!" entry, written for D-Bus requests
# such as `systemctl hibernate` before PrepareForSleep goes out.
BW_LOGIND_SLEEP_ID="9e7066279dc8403da79ce4b1a69064b2"

# Prints why skipping the lock after hibernate would be unsafe, or nothing when
# resuming from hibernate always stops at a typed disk password.
bw_hibernate_unprotected_reason() {
  local cmdline resume
  cmdline=$(<"$BW_CMDLINE_FILE")

  if [[ ! $cmdline =~ (^|[[:space:]])resume=([^[:space:]]+) ]]; then
    echo "hibernation is not set up"
    return
  fi
  resume=${BASH_REMATCH[2]}
  case $resume in
    UUID=*) resume=/dev/disk/by-uuid/${resume#UUID=} ;;
    PARTUUID=*) resume=/dev/disk/by-partuuid/${resume#PARTUUID=} ;;
    LABEL=*) resume=/dev/disk/by-label/${resume#LABEL=} ;;
  esac

  if [[ -z ${BW_SKIP_DEVICE_CHECK:-} ]] &&
    ! lsblk -nso TYPE "$resume" 2>/dev/null | grep -qx crypt; then
    echo "the hibernation image is not on an encrypted disk"
    return
  fi

  # A key file, TPM or security key can unlock the disk without anyone typing
  # a password, and systemd's own unlock path (rd.luks) tries enrolled TPM and
  # FIDO tokens on its own, which cannot be ruled out without root.
  if [[ $cmdline =~ (cryptkey=|rd\.luks|tpm2|fido2) ]]; then
    echo "the disk may unlock without a typed password"
    return
  fi
  # shellcheck disable=SC2086 # word-split list of paths
  if grep -qsE 'tpm2-device|fido2-device|pkcs11-uri' $BW_CRYPTTAB_FILES; then
    echo "the disk may unlock without a typed password"
    return
  fi
}

# Maps one logind journal entry (JSON lines on stdin) to the sleep action it
# announces. Lid and key presses log a plain message; D-Bus requests log a
# structured entry with ACTION. Anything else is ignored.
bw_sleep_action_from_journal() {
  jq -r --arg id "$BW_LOGIND_SLEEP_ID" '
    if .MESSAGE_ID == $id and (.ACTION | type) == "string" then .ACTION
    elif (.MESSAGE | type) != "string" then empty
    elif .MESSAGE == "Hibernating..." then "hibernate"
    elif .MESSAGE == "Suspending..." then "suspend"
    elif .MESSAGE == "Hibernating and suspending..." then "hybrid-sleep"
    elif .MESSAGE == "Suspending, then hibernating..." then "suspend-then-hibernate"
    else empty end' 2>/dev/null | tail -n1
}

# Prints the sleep action logind announced in the few seconds before $1 (epoch
# seconds), retrying briefly because journald may not have stored it yet.
# Prints "unknown" when no announcement can be read, e.g. without permission
# to read the system journal.
bw_pending_sleep_action() {
  local since=$(( $1 - 5 )) action try
  for (( try = 0; try < 10; try++ )); do
    action=$(journalctl --system -b -q -o json --no-pager --since "@$since" \
      SYSLOG_IDENTIFIER=systemd-logind 2>/dev/null | bw_sleep_action_from_journal)
    if [[ -n $action ]]; then
      echo "$action"
      return
    fi
    sleep 0.1
  done
  echo unknown
}

# Seconds the machine has spent asleep since boot. It only grows across a real
# suspend or hibernate, which is how a skipped lock is checked afterwards.
bw_slept_seconds() {
  python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)))'
}
