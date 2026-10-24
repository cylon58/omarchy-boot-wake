# Boot & Wake

Opt-in fixes for how an Omarchy machine starts and wakes. Every fix starts
off, turns on with one switch, and turns off just as easily.

| Fix | What it does | Needs admin |
|---|---|---|
| **No second password after hibernate** | Waking from hibernate asks for the disk password and then for the lock screen password. The disk password already proves it's you, so this skips the lock screen for hibernate only. | No |
| **Shorter boot menu** | The Limine menu waits 1 second instead of 5. Press any arrow key during that second to reach snapshots. | Yes |

## Install

```sh
omarchy plugin add https://github.com/cylon58/omarchy-boot-wake.git --enable
omarchy-shell shell summon io.github.cylon58.boot-wake
```

Then flip the switches you want. Installing and enabling the plugin changes
nothing on its own.

There is also a command line:

```sh
~/.config/omarchy/plugins/io.github.cylon58.boot-wake/bin/boot-wake status
~/.config/omarchy/plugins/io.github.cylon58.boot-wake/bin/boot-wake enable hibernate-unlock
~/.config/omarchy/plugins/io.github.cylon58.boot-wake/bin/boot-wake disable hibernate-unlock
```

## Safety

**No second password after hibernate** only turns on when it can confirm that
waking from hibernate stops at a typed disk password:

- the hibernation image is on a LUKS-encrypted device, and
- the disk is unlocked by the classic `encrypt` initramfs hook from
  `cryptdevice=`, with no key file (`cryptkey=`, `/crypto_keyfile.bin`, or a
  key in mkinitcpio `FILES`). systemd-based unlocking (`sd-encrypt`,
  `rd.luks`) is refused because it can use TPM or FIDO tokens on its own.
  Every initramfs hook must be on a short list of hooks that cannot unlock a
  disk (so `clevis` and similar are refused), the image must come from
  mkinitcpio's standard config, and
- hibernate really powers off (`HibernateMode` does not keep it in memory).

These checks run again at every hibernate, so a change made since login
counts.

Normal sleep, hybrid sleep and suspend-then-hibernate still lock as before.
It only trusts logind's own announcement (checked by journal fields no other
program can set) of the sleep starting right now, written within the last
three seconds; any other kind of sleep announced alongside it means it locks.
When the machine comes back it confirms with logind that a hibernate really
finished and time really passed; otherwise it locks at once. If it ever loses
its hold on the "lock before sleep" guard, it restarts itself. If it can't tell which kind of sleep is starting (for
example because your user can't read the system journal), it locks. If a
hibernate fails and the session comes straight back, it locks the moment the
machine returns. If you remove the
plugin without turning the fix off, Omarchy's own lock-before-sleep takes over
again automatically.

**Shorter boot menu** asks for your password, then:

1. takes a Snapper root snapshot, and stops if that fails;
2. keeps a copy of `/boot/limine.conf` as `/boot/limine.conf.boot-wake.bak`
   (the boot partition is not covered by snapshots);
3. takes the same boot-partition lock the Limine tools use, changes only the
   `timeout:` line, checks that nothing else differs, and flushes the change
   to disk before reporting success.

It refuses to run when Secure Boot is on or Limine config enrolment
(`ENABLE_ENROLL_LIMINE_CONFIG`) is set, because editing an enrolled config
stops the machine booting. It edits the `limine.conf` on the ESP named by
`ESP_PATH` in `/etc/default/limine` (default `/boot`).

Turning it off puts back the exact original line and removes the backup.
`omarchy refresh limine` resets the whole file to Omarchy's default.

## How it works

- The hibernate fix adds a user systemd drop-in,
  `~/.config/systemd/user/omarchy-sleep-lock.service.d/io.github.cylon58.boot-wake.conf`,
  that runs `bin/sleep-monitor` in place of Omarchy's sleep monitor. It holds
  the same delay inhibitor and calls Omarchy's own lock script. The only
  difference is that it reads logind's announcement of the coming sleep from
  the journal and skips the lock when that sleep is a plain hibernate.
- The boot menu fix runs `bin/boot-wake-root` through `pkexec`. It records
  the original timeout line in `/var/lib/boot-wake/`.

Note: like any plugin that uses `pkexec`, the admin step runs a script from
your plugin folder, which your user account can edit.

## Requirements

Omarchy Quattro, `jq`, `python3`, `pkexec`, and Snapper with a `root` config
for the boot menu fix. Your user needs to be able to read the system journal
for the hibernate fix (members of `wheel` can on Omarchy).

## Remove

Turn the fixes off first, then remove the plugin:

```sh
P=~/.config/omarchy/plugins/io.github.cylon58.boot-wake
$P/bin/boot-wake disable hibernate-unlock
$P/bin/boot-wake disable boot-menu
omarchy plugin remove io.github.cylon58.boot-wake
```

## Tests

```sh
tests/run.sh       # safety checks and the boot menu editor
tests/monitor.sh   # simulated sleeps through the sleep monitor
```

## License

MIT
