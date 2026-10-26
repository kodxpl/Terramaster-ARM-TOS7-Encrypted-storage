# luks-kit — LUKS on TOS 7 md RAID

This solution is able to encrypt whole TOS storage pools at the RAID level:

    md RAID (TOS) -> LUKS (cryptN) -> LVM PV/VG/LV (TOS) -> btrfs

Once unlocked at boot, TOS manages the pools and volumes as normal:
volume create/extend, RAID repair and rebuild all work from the TOS UI.
The full procedure is in the runbook "TOS 7 LUKS-on-RAID Runbook".
Additionally once disk needs replacement it can be done directly from TOS UI.
mdadm will rebuild RAID with all required setup already.
This script is not intended to migrate already filled in Volumes. 
Keep in mind it will wipe them! It is intended to be used only for new or additional empty Storage Pools.

## Files

| File | Purpose |
| --- | --- |
| `luks-kit-install.sh` | Installs/updates everything in `/opt/lvmshim` and `luks-pools.service`. Never touches a disk. Safe to re-run. |
| `/opt/lvmshim/pools.conf` | md UUIDs of encrypted pools, one per line |
| `/opt/lvmshim/settings.conf` | `UNLOCK_TIMEOUT` (0 = wait forever), `UNLOCK_WEB_PORT` (8443) |
| `/root/luks-pools/<md-uuid>-header.img` | LUKS header backups — keep copies off the NAS |

## Quick start

1. Enable SSH in TOS (Control Panel). `systemctl is-enabled ssh.service` must print `enabled`.
2. `scp -P 9222 luks-kit-install.sh user@<IP>:/root/` then run it on the NAS: `/root/luks-kit-install.sh`
3. `systemctl enable luks-pools.service`
4. `/opt/lvmshim/check.sh` → `RESULT: ALL CHECKS PASSED`

## Encrypt a new pool

1. TOS UI: create the pool. Wait until the RAID sync is finished.
2. Find its array: `for d in /dev/md[0-9]*; do echo "$d: $(pvs --noheadings -o vg_name,vg_tags,lv_count $d 2>/dev/null)"; done`
   (never md8/md9 — those are TOS system arrays)
3. `/opt/lvmshim/convert-pool.sh /dev/mdN` — destroys data on that array, asks for `YES` and a passphrase
4. `/opt/lvmshim/check.sh`, create the volume in the UI, reboot, unlock, `check.sh` again
5. Copy the new header backup off the NAS

## Every boot

The NAS waits before TOS mounts storage. Unlock with any one of:

- Browser: `https://<IP>:8443` (self-signed certificate; compare the fingerprint the installer printed)
- SSH: `/opt/lvmshim/unlock.sh`
- USB stick labelled `NASKEY` with key files `<md-uuid with ':' as '-'>.key` (optional, unattended)

A pool whose disks are all removed is skipped. Insert or remove encrypted disks only with the NAS powered off.

## Commands

| Command | What it does |
| --- | --- |
| `/opt/lvmshim/check.sh` | Read-only health check, PASS/FAIL per item |
| `/opt/lvmshim/unlock.sh` | Unlock all pools interactively |
| `/opt/lvmshim/convert-pool.sh /dev/mdN` | Encrypt an empty TOS pool |
| `/opt/lvmshim/install-shims.sh` | Re-apply the tool shims (also runs at every boot) |
| `/opt/lvmshim/remove-shims.sh` | Restore original tools — encrypted pools stop working in TOS |

## Rules

- Never click repair, initialize, remount or delete on an encrypted pool while `check.sh` shows a FAIL.
- Never name a mapping `luks-mdN`; the kit always uses `cryptN`.
- After a TOS firmware update: re-run the installer, then `check.sh`. Plug in the NASKEY stick for the first boot after an update.
- After changing a passphrase: refresh the header backup and delete older copies.
