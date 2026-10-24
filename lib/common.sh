# Shared by bin/boot-wake and bin/sleep-monitor. Sourced, never executed.

BW_ID="io.github.cylon58.boot-wake"
BW_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boot-wake"
BW_DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omarchy-sleep-lock.service.d"
BW_DROPIN="$BW_DROPIN_DIR/$BW_ID.conf"

# Tests point these at fixtures.
BW_CMDLINE_FILE="${BW_CMDLINE_FILE:-/proc/cmdline}"
BW_MKINITCPIO_DIR="${BW_MKINITCPIO_DIR:-/etc}"

# logind's "The system will <action> now!" entry, written for D-Bus requests
# such as `systemctl hibernate` before PrepareForSleep goes out.
BW_LOGIND_SLEEP_ID="9e7066279dc8403da79ce4b1a69064b2"

# Prints why skipping the lock after hibernate would be unsafe, or nothing when
# resuming from hibernate always stops at a typed disk password. This is an
# allow-list: only the setup it can fully check passes. That is the classic
# `encrypt` initramfs hook unlocking `cryptdevice=` with no key file, which is
# Omarchy's default. Anything else, or anything it cannot read, is refused.
bw_hibernate_unprotected_reason() {
  local cmdline resume config hooks files
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
    ! timeout 2 lsblk -nso TYPE "$resume" 2>/dev/null | grep -qx crypt; then
    echo "the hibernation image is not on an encrypted disk"
    return
  fi

  # Key files, TPM and security keys unlock without anyone typing. systemd's
  # unlock path (rd.luks / luks.) also tries enrolled TPM and FIDO tokens on
  # its own, which cannot be ruled out without root, so it is not supported.
  if [[ ! $cmdline =~ (^|[[:space:]])cryptdevice= ]] ||
    [[ $cmdline =~ (cryptkey=|luks\.|tpm2|fido2) ]]; then
    echo "the disk may unlock without a typed password"
    return
  fi

  # Read the initramfs hooks the way mkinitcpio does, in a throwaway shell.
  # shellcheck disable=SC2016 # expanded by the inner shell
  config=$(BW_MKINITCPIO_DIR="$BW_MKINITCPIO_DIR" timeout 2 bash -c '
    HOOKS=() FILES=()
    for f in "$BW_MKINITCPIO_DIR/mkinitcpio.conf" "$BW_MKINITCPIO_DIR"/mkinitcpio.conf.d/*.conf; do
      [[ -r $f ]] && source "$f" >/dev/null 2>&1
    done
    printf "HOOKS: %s \nFILES: %s \n" "${HOOKS[*]}" "${FILES[*]}"' 2>/dev/null)
  hooks=$(sed -n 's/^HOOKS:/ /p' <<<"$config")
  files=$(sed -n 's/^FILES:/ /p' <<<"$config")
  if [[ $hooks != *" encrypt "* || $hooks == *" sd-encrypt "* || $hooks == *" systemd "* ]]; then
    echo "the disk may unlock without a typed password"
    return
  fi
  # The encrypt hook silently uses /crypto_keyfile.bin when it is baked in.
  if [[ $files =~ [Kk]ey || -e ${BW_KEYFILE:-/crypto_keyfile.bin} ]]; then
    echo "the disk may unlock without a typed password"
    return
  fi

  # HibernateMode=suspend keeps the machine in RAM after writing the image,
  # so waking needs no disk password at all.
  if [[ -z ${BW_SKIP_DEVICE_CHECK:-} ]] &&
    timeout 2 systemd-analyze cat-config systemd/sleep.conf 2>/dev/null |
      grep -qiE '^[[:space:]]*HibernateMode=.*(suspend|test_resume)'; then
    echo "hibernate is set to stay in memory"
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

# Prints a journal cursor for "now". Announcements are only trusted when they
# come after the cursor taken once the previous sleep finished.
bw_journal_cursor() {
  timeout 1 journalctl --system -q -n0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p'
}

# Prints the newest sleep action logind announced after cursor $1, retrying
# briefly because journald may not have stored it yet. Prints "unknown" when
# nothing can be read, e.g. without permission to read the system journal.
bw_pending_sleep_action() {
  local cursor=$1 action try
  [[ -n $cursor ]] || { echo unknown; return; }
  for (( try = 0; try < 5; try++ )); do
    action=$(timeout 0.5 journalctl --system -q -o json --no-pager \
      --after-cursor "$cursor" SYSLOG_IDENTIFIER=systemd-logind 2>/dev/null |
      bw_sleep_action_from_journal)
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
  [[ -n ${BW_TEST_SLEPT_FILE:-} ]] && { cat "$BW_TEST_SLEPT_FILE"; return; }
  python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)))'
}
