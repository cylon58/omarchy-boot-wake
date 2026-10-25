# Shared by bin/boot-wake and bin/sleep-monitor. Sourced, never executed.

BW_ID="io.github.cylon58.boot-wake"
BW_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boot-wake"
BW_DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omarchy-sleep-lock.service.d"
BW_DROPIN="$BW_DROPIN_DIR/$BW_ID.conf"
BW_DOCK_UNIT_NAME="boot-wake-dock.service"
BW_DOCK_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$BW_DOCK_UNIT_NAME"

# Tests point these at fixtures.
BW_CMDLINE_FILE="${BW_CMDLINE_FILE:-/proc/cmdline}"
BW_MKINITCPIO_DIR="${BW_MKINITCPIO_DIR:-/etc}"
BW_POWER_DISK_FILE="${BW_POWER_DISK_FILE:-/sys/power/disk}"

# Initramfs hooks known not to unlock a disk on their own. Anything else, such
# as clevis or a TPM hook, could resume without a typed password.
BW_SAFE_HOOKS=" base udev autodetect microcode modconf kms keyboard keymap consolefont
  block encrypt filesystems fsck resume plymouth btrfs-overlayfs lvm2 mdadm_udev usr
  shutdown grub-btrfs-overlayfs "

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

  # Only mkinitcpio is understood. Other generators build their own unlock
  # logic, and a preset can point at a different config.
  if [[ -z ${BW_SKIP_DEVICE_CHECK:-} ]]; then
    if command -v dracut >/dev/null 2>&1 || command -v booster >/dev/null 2>&1; then
      echo "the initramfs may not come from mkinitcpio"
      return
    fi
    if grep -hsE '^[[:space:]]*[A-Za-z0-9_]*_config=' "$BW_MKINITCPIO_DIR"/mkinitcpio.d/*.preset |
      grep -qvE "_config=[\"']?/etc/mkinitcpio.conf[\"']?[[:space:]]*$"; then
      echo "an initramfs preset uses its own config"
      return
    fi
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
  if [[ $hooks != *" encrypt "* ]]; then
    echo "the disk may unlock without a typed password"
    return
  fi
  local hook
  for hook in $hooks; do
    if [[ $BW_SAFE_HOOKS != *[[:space:]]"$hook"[[:space:]]* ]]; then
      echo "the initramfs hook '$hook' may unlock the disk without a typed password"
      return
    fi
  done
  # The encrypt hook silently uses /crypto_keyfile.bin when it is baked in.
  if [[ $files =~ [Kk]ey || -e ${BW_KEYFILE:-/crypto_keyfile.bin} ]]; then
    echo "the disk may unlock without a typed password"
    return
  fi

  # Hibernate must really power off. HibernateMode=suspend or test_resume
  # keeps the machine in RAM, so waking needs no disk password at all.
  local power_disk sleep_conf
  power_disk=$(<"$BW_POWER_DISK_FILE") 2>/dev/null
  if [[ ! $power_disk =~ \[(platform|shutdown|reboot)\] ]]; then
    echo "hibernate is not set to power off"
    return
  fi
  if [[ -z ${BW_SKIP_DEVICE_CHECK:-} ]]; then
    if ! sleep_conf=$(timeout 2 systemd-analyze cat-config systemd/sleep.conf 2>/dev/null) ||
      [[ -z $sleep_conf ]] ||
      grep -qiE '^[[:space:]]*HibernateMode[[:space:]]*=.*(suspend|test_resume)' <<<"$sleep_conf"; then
      echo "hibernate may stay in memory"
      return
    fi
  fi
}

# Maps logind journal entries (JSON lines on stdin) to the sleep actions they
# announce, one per line. Lid and key presses log a plain message; D-Bus
# requests log a structured entry with ACTION. Anything else is ignored.
# With $1 (epoch microseconds), only entries logind wrote within 3 seconds
# before then count, so an old entry stored late is never mistaken for news.
bw_sleep_actions_from_journal() {
  jq -r --arg id "$BW_LOGIND_SLEEP_ID" --arg at "${1:-}" '
    select($at == "" or (
      (._SOURCE_REALTIME_TIMESTAMP // "" | tonumber? // 0) as $t
      | $t >= ($at | tonumber) - 3000000 and $t <= ($at | tonumber) + 1000000))
    | if .MESSAGE_ID == $id and (.ACTION | type) == "string" then .ACTION
      elif (.MESSAGE | type) != "string" then empty
      elif .MESSAGE == "Hibernating..." then "hibernate"
      elif .MESSAGE == "Suspending..." then "suspend"
      elif .MESSAGE == "Hibernating and suspending..." then "hybrid-sleep"
      elif .MESSAGE == "Suspending, then hibernating..." then "suspend-then-hibernate"
      else empty end' 2>/dev/null
}

# logind's own entries only. These fields are set by journald, not the
# sender, so no other program can forge them.
bw_logind_journal() {
  timeout 0.5 journalctl --system -q -o json --no-pager "$@" \
    _SYSTEMD_UNIT=systemd-logind.service _UID=0 2>/dev/null
}

# Prints a journal cursor for "now". Announcements are only trusted when they
# come after the cursor taken once the previous sleep finished.
bw_journal_cursor() {
  timeout 1 journalctl --system -q -n0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p'
}

# Prints the sleep logind announced after cursor $1, for a PrepareForSleep
# received at $2 (epoch microseconds). Prints "hibernate" only when every fresh
# announcement says hibernate; a mix prints "mixed". Retries briefly because
# journald may not have stored it yet, then prints "unknown".
bw_pending_sleep_action() {
  local cursor=$1 at=$2 actions try
  [[ -n $cursor ]] || { echo unknown; return; }
  for (( try = 0; try < 5; try++ )); do
    actions=$(bw_logind_journal --after-cursor "$cursor" | bw_sleep_actions_from_journal "$at" | sort -u)
    if [[ -n $actions ]]; then
      [[ $actions == *$'\n'* ]] && echo mixed || echo "$actions"
      return
    fi
    sleep 0.1
  done
  echo unknown
}

# True when logind reports a hibernate finished after cursor $1. Waits up to
# about two seconds, since the entry may be stored just after the wake signal.
bw_hibernate_finished_since() {
  local try
  for (( try = 0; try < 8; try++ )); do
    bw_logind_journal --after-cursor "$1" |
      jq -e -s 'any(.[]; .MESSAGE == "Operation '"'"'hibernate'"'"' finished.")' >/dev/null 2>&1 &&
      return 0
    sleep 0.25
  done
  return 1
}

# Seconds the machine has spent asleep since boot. It only grows across a real
# suspend or hibernate, which is how a skipped lock is checked afterwards.
bw_slept_seconds() {
  [[ -n ${BW_TEST_SLEPT_FILE:-} ]] && { cat "$BW_TEST_SLEPT_FILE"; return; }
  python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)))'
}
