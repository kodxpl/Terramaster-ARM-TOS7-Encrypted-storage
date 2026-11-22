# luks-kit — LUKS on TOS 7 md RAID

Version 2026-11-22 · TerraMaster TOS 7 (tested on F4-212, TOS_ARM2.0_6.0.587)

Encrypts whole TOS storage pools at the RAID level:

    md RAID (TOS) -> LUKS (cryptN) -> LVM PV/VG/LV (TOS) -> btrfs

Once unlocked at boot, TOS manages the pools and volumes as normal:
volume create/extend, RAID repair and rebuild all work from the TOS UI.
The full procedure is in the runbook "TOS 7 LUKS-on-RAID Runbook".

## Files

| File | Purpose |
| --- | --- |
| `luks-kit-install.sh` | Installs/updates everything in `/opt/lvmshim` and `luks-pools.service`. Never touches a disk. Safe to re-run. |
| `/opt/lvmshim/pools.conf` | md UUIDs of encrypted pools, one per line |
| `/opt/lvmshim/settings.conf` | `UNLOCK_TIMEOUT` (0 = wait forever), `UNLOCK_WEB_PORT` (8443) |
| `/root/luks-pools/<md-uuid>-header.img` | LUKS header backups — keep copies off the NAS |

## Menu

Run `tnas-luks` (installed as `/usr/local/sbin/tnas-luks` → `/opt/lvmshim/tnas-luks.sh`):

| Option | What it does |
| --- | --- |
| 1 List pools | Every data array: TOS pool name, RAID level, disks, encrypted/locked state, volumes and mount points |
| 2 Health check | Runs `check.sh` |
| 3 Unlock | Runs `unlock.sh` |
| 4 Encrypt an empty pool | Offers only unencrypted TOS pools with no volume, then runs `convert-pool.sh` |
| 5 Register an existing encrypted pool | After a clean TOS install: adds it to `pools.conf` and the mdadm config, restores its header backup |
| 6 Decommission an encrypted pool | Refuses while it has volumes; closes it, optional crypto-erase, stops and unregisters it; then power off and pull the disks |
| 7 Passphrases and key files | Change/add a passphrase, add a NASKEY USB key file, remove a key slot; refreshes the header backup after each change |
| 8 Header backups | Creates missing backups, refreshes outdated ones |
| 9 Boot unlock settings | Unlock timeout and unlock-page port |

## Quick start

1. Enable SSH in TOS (Control Panel). `systemctl is-enabled ssh.service` must print `enabled`.
2. `scp luks-kit-install.sh grzes@TNAS:/root/` then on the NAS: `bash /root/luks-kit-install.sh`
3. `systemctl enable luks-pools.service`
4. `/opt/lvmshim/check.sh` → `RESULT: ALL CHECKS PASSED`

## Encrypt a new pool

1. TOS UI: create the pool, **no volume**. Wait until the RAID sync is finished.
2. Find its array: `for d in /dev/md[0-9]*; do echo "$d: $(pvs --noheadings -o vg_name,vg_tags,lv_count $d 2>/dev/null)"; done`
   (never md8/md9 — those are TOS system arrays)
3. `/opt/lvmshim/convert-pool.sh /dev/mdN` — destroys data on that array, asks for `YES` and a passphrase
4. `/opt/lvmshim/check.sh`, create the volume in the UI, reboot, unlock, `check.sh` again
5. Copy the new header backup off the NAS

## Every boot

The NAS waits before TOS mounts storage. Unlock with any one of:

- Browser: `https://TNAS:8443` (self-signed certificate; compare the fingerprint the installer printed)
- SSH: `/opt/lvmshim/unlock.sh`
- USB stick labelled `NASKEY` with key files `<md-uuid with ':' as '-'>.key` (optional, unattended)

A pool whose disks are all removed is skipped. Insert or remove encrypted disks only with the NAS powered off.

## Commands

| Command | What it does |
| --- | --- |
| `tnas-luks` | The menu above |
| `/opt/lvmshim/check.sh` | Read-only health check, PASS/FAIL per item |
| `/opt/lvmshim/unlock.sh` | Unlock all pools interactively |
| `/opt/lvmshim/convert-pool.sh /dev/mdN` | Encrypt an empty TOS pool |
| `/opt/lvmshim/install-shims.sh` | Re-apply the tool shims (also runs at every boot) |
| `/opt/lvmshim/remove-shims.sh` | Restore original tools — encrypted pools stop working in TOS |

## Remove an encrypted pool

1. TOS UI: delete its shared folders and volume(s), keep the pool.
2. `tnas-luks` → 6, pick the pool, optionally crypto-erase, type its array name.
3. Power off, pull its disks, power on, delete the pool in the TOS UI (shown as missing its disks).

## Rules

- Never click repair, initialize, remount or delete on an encrypted pool while `check.sh` shows a FAIL.
- Never name a mapping `luks-mdN`; the kit always uses `cryptN`.
- After a TOS firmware update: re-run the installer, then `check.sh`. Plug in the NASKEY stick for the first boot after an update.
- After changing a passphrase: refresh the header backup and delete older copies.
