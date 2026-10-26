# TOS 7 LUKS-on-RAID Runbook

Here a bit longer version of Readme.md.
TerraMaster TOS 7: each encrypted pool runs md RAID → LUKS → LVM (PV/VG/LV) → btrfs, managed from the TOS UI once unlocked. Kit: `luks-kit-install.sh` version 2026-10-25 (`cat /opt/lvmshim/VERSION`). Run every command as root over SSH. After each part, `/opt/lvmshim/check.sh` must end with ALL CHECKS PASSED before you continue.

## How it works

TOS creates the RAID array; we encrypt the whole array and put TOS's own LVM metadata back on top, with identical UUIDs and tags. An open array `/dev/mdN` is always mapped as `/dev/mapper/cryptN`, so the md number can be anything (md1, md2, md127).

TOS would otherwise see a LUKS header where it expects a PV, so the kit makes four things look unencrypted to TOS:

| What TOS checks | Who checks it | How the kit handles it |
| --- | --- | --- |
| `blkid -o value -s TYPE /dev/mdN` | mntdata at boot (legacy-volume path if not LVM2\_member) | `blkid` shim reports LVM2\_member |
| `lsblk -o FSTYPE /dev/mdN` and the `lsblk --json` tree | StorageManager | `lsblk` shim hides the crypt layer |
| `pvs`, `pvdisplay`, `lvs`, `pvresize` on `/dev/mdN` | both | LVM shim translates `/dev/mdN` ↔ `/dev/mapper/cryptN` |
| `device =` hint in `/etc/lvm/backup/<vg>` | StorageManager maps VG → md from it | LVM shim rewrites the hint to `/dev/mdN` after every LVM command |

Two rules follow from this. The crypt mapping must never be named `luks-mdN` or anything else TOS could read as an md name; the kit always uses `cryptN`. And TOS must never see a pool locked: the boot unit holds TOS's storage start until every pool is unlocked, by default for as long as it takes.

A third rule comes from LUKS itself: the encrypted device uses 4 KiB sectors, so the LVM data area must start on a 4 KiB boundary. TOS sometimes picks an odd start (65535 sectors on a USB disk), so `convert-pool.sh` rounds it up to a 1 MiB boundary, and `check.sh` verifies it.

Files: everything lives in `/opt/lvmshim`. Pools are listed by md UUID in `/opt/lvmshim/pools.conf`. Header backups and a copy of the installer live in `/root/luks-pools`.

## Before you start — enable SSH

TOS ships with SSH turned off. The browser unlock page (Part B) works without SSH, but SSH is needed to install the kit and is the fallback if the page fails.

1. In the TOS web UI, open Control Panel and turn on the SSH service (under the network or terminal services settings). Keep the default port 9222 unless you change it everywhere below.
2. From your PC, log in once and confirm you get a root prompt (`#`): `ssh user@<TNAS-IP> -p 9222`.
3. Confirm SSH starts on its own at boot:

```bash
systemctl is-enabled ssh.service      # must print: enabled
```

If it prints anything else, turn SSH off and on again in the UI and repeat. check.sh tests this too (`SSH enabled at boot`), and Part D repeats the check after every firmware update, since an update may switch SSH off again.

## Part A — Install, update, or bring encrypted disks to a fresh TOS

The installer only writes files; it never touches a disk. It is safe to run again at any time and keeps `pools.conf`, `settings.conf` and the unlock-page certificate. It backs up the old kit to `/root/lvmshim.bak.<date>` first.

**A1. Install or update the kit.** Copy the installer from your PC, then run it on the NAS:

```bash
scp -P 9222 luks-kit-install.sh user@<TNAS-IP>:/root/        # on the PC
bash /root/luks-kit-install.sh                    # on the NAS
```

It ends with `Kit version 2026-10-25 installed to /opt/lvmshim` and prints the unlock page's certificate fingerprint. For a plain update, continue with A5.

**A2. Fresh TOS (clean install) with existing encrypted disks.** A clean install forgets the encrypted pools. Install the kit first with the encrypted disks **out** of the NAS, never the other way round: TOS would otherwise meet a locked array it does not know, and treat it as broken or free.

```bash
cat /proc/mdstat                 # md numbers in use (typically md0, md8, md9)
```

**A3. Register each encrypted pool** (still with its disks out). Per pool you need its md UUID (from `pools.conf` of the old system, or `mdadm --examine --scan` once the disks are in) and a free md number:

```bash
U=3e033ecb:be2ac055:8fb58c9b:dc4787bd                       # this pool's md UUID
echo "$U" >> /opt/lvmshim/pools.conf
echo "ARRAY /dev/md1 metadata=1.2 UUID=$U" >> /etc/mdadm/mdadm.conf   # free md number
cp <your copy>/<header>.img /root/luks-pools/${U//:/-}-header.img        # if you have it
systemctl enable luks-pools.service
```

**A4. Gate, then insert the disks.** `/opt/lvmshim/check.sh` reports the pool as skipped (disks not in the NAS). Then power off, insert the encrypted disks in their bays, power on, unlock (Part B). TOS rediscovers the pool and its volumes from their LVM tags. If the header backup was lost, make a new one now: `cryptsetup luksHeaderBackup /dev/mdN --header-backup-file /root/luks-pools/<md-uuid>-header.img`.

**A5. Gate.** `/opt/lvmshim/check.sh` must end with `RESULT: ALL CHECKS PASSED`. A FAIL line names what is wrong. Then reboot once and unlock through the browser page: the NAS must wait until you type the passphrase yourself.

**A6. Keep copies off the NAS:** `/root/luks-pools/*-header.img`, `/root/luks-pools/luks-kit-install.sh`, `/opt/lvmshim/pools.conf`, and your passphrase.

## Part B — Every boot

The NAS boots until SSH and the network are up, then waits before TOS mounts any storage. By default it waits as long as it takes (`UNLOCK_TIMEOUT=0` in `/opt/lvmshim/settings.conf`); nothing on the disks changes while it waits. Unlock by any one of three routes:

| Route | How | Needs |
| --- | --- | --- |
| Browser | Open `https://TNAS-IP:8443` (or the NAS IP), type the passphrase, press Unlock | Any device on your network |
| SSH | `ssh user@<TNAS-IP> -p 9222`, then `/opt/lvmshim/unlock.sh` | SSH enabled |
| USB key stick | Plugged in before power-on; unlocks with no input | The NASKEY stick (below) |

After the unlock, TOS starts its storage by itself; the normal web UI comes up about a minute later. Optional: `/opt/lvmshim/check.sh` → ALL CHECKS PASSED.

**The browser page.** It runs only during the boot wait and stops once every pool is open, so port 8443 is closed the rest of the time. It uses a self-signed certificate, so the browser warns on the first visit. Compare the SHA-256 fingerprint shown in the browser's certificate details with the one the installer printed (or `openssl x509 -noout -fingerprint -sha256 -in /opt/lvmshim/tls/cert.pem`), then accept it. The passphrase is tried on every locked pool; pools with another passphrase stay locked, so submit again for those. A wrong passphrase costs about 3 seconds per attempt.

**Unattended boot (optional).** Format a USB stick with the label `NASKEY` and, per pool, create a key file named after the md UUID with `:` replaced by `-`, then add it as a second LUKS key slot:

```bash
U=3e033ecb:be2ac055:8fb58c9b:dc4787bd; K=/path/to/usb/${U//:/-}.key
dd if=/dev/urandom of=$K bs=64 count=1
cryptsetup luksAddKey /dev/md1 $K
```

With the stick plugged in, the pools unlock at boot by themselves. Anyone holding the stick can unlock the data, so keep it away from the NAS when it is not needed.

**Running without the encrypted pool's disks.** A pool whose disks are all out of the NAS is skipped: the boot does not wait for it (kit version of 2026-10-19 or later; `check.sh` reports it as skipped). TOS starts with the other pools and shows the encrypted pool as missing its disks; click nothing on it. To bring it back: power off, reinsert the drives in the same bays, power on and unlock. If only some of a pool's disks are present, the boot still waits, and the unlock opens the array degraded. An older kit waits forever instead; end that wait over SSH with `pkill -f wait-unlock.sh`.

To restore the old behaviour of powering off after a time limit, set `UNLOCK_TIMEOUT=1800` (seconds) in `settings.conf`.

## Part C — Encrypt a new pool

A pool can only be encrypted while it is empty: the conversion wipes the array. Each step ends with a gate; do not go on past a STOP or a FAIL.

**C1. Create the pool in the TOS UI** (RAID level, disks) but **no volume**. Wait until the initial sync is finished: `cat /proc/mdstat` shows no `resync`/`recovery` line for it.

**C2. Find which md array TOS created.** Do not assume md1 or md2:

```bash
cat /etc/volume/storage.conf
for d in /dev/md[0-9]*; do echo "$d: $(pvs --noheadings -o vg_name,vg_tags,lv_count $d 2>/dev/null)"; done
```

The new array is the one whose VG tag matches the new pool's `[tag]` in `storage.conf` and whose LV count is 0. md8 and md9 are TOS system arrays; never use them. Note the device, for example `/dev/md2`.

**C3. Gate before.** `/opt/lvmshim/check.sh` → ALL CHECKS PASSED (existing pools are fine).

**C4. Convert.**

```bash
/opt/lvmshim/convert-pool.sh /dev/md2        # your device from C2
```

The script first runs its own pre-checks (array idle and not degraded, one PV, zero volumes, VG registered as a TOS pool, mdadm config entry present) and stops with `STOP: …` without changing anything if one fails. It then prints a summary and asks you to type `YES`. cryptsetup asks for `YES` again and the new passphrase twice, then the passphrase once more to open it. Before it finishes it rounds the LVM data start up to a 1 MiB boundary and creates and removes a small test volume, so a pool that cannot hold volumes fails here instead of in the UI. It ends with `DONE: /dev/md2 is now LUKS-encrypted`.

If it stops with `mdadm config does not list …`, TOS has not yet written the new array to its mdadm config: reboot once (TOS rewrites it at every boot) or add the line yourself with `echo "ARRAY /dev/mdN metadata=1.2 UUID=<uuid>" >> /etc/mdadm/mdadm.conf` (`mdadm --detail --export /dev/mdN` shows the UUID). Using the same passphrase for all pools lets one submission on the unlock page open them all.

If it stops after `== encrypting`, StorageManager may still be stopped: run `systemctl start StorageManager`, do not touch the pool in the UI, and send the output for analysis.

**C5. Gate after.** `/opt/lvmshim/check.sh` → ALL CHECKS PASSED, now listing the new pool. Reload Storage Manager in the browser: the new pool is normal, with all its disks.

**C6. Create the volume in the UI**, then `/opt/lvmshim/check.sh` again: the new line `volume vgN/lvN mounted on /VolumeN` must PASS.

**C7. Reboot test.** Reboot, run `/opt/lvmshim/unlock.sh` (it now asks once per pool), then `/opt/lvmshim/check.sh`. Write and read back a test file on the new volume.

**C8. Copy the new header backup off the NAS:** `/root/luks-pools/<md-uuid>-header.img`.

## Part D — Routine operations

After every operation below, run `/opt/lvmshim/check.sh` and expect ALL CHECKS PASSED.

| Operation | How | Status |
| --- | --- | --- |
| Create, resize or delete a volume | TOS UI, as normal | Tested (create, extend) |
| Disk failure or replacement | TOS UI repair; wait for the resync to finish, then check | Tested (fail, re-add, resync) |
| Expand a pool (more or larger disks) | TOS UI; afterwards also confirm `cryptsetup status cryptN` shows the larger size | Untested |
| Change or add a passphrase | `cryptsetup luksChangeKey /dev/mdN` or `luksAddKey`, then refresh the header backup (below) | Standard LUKS |
| Delete an encrypted pool | Delete its volumes in the UI; `vgchange -an vgN; cryptsetup close cryptN`; remove its UUID from `pools.conf`; then delete the pool in the UI | Untested |

**Refresh a header backup** after any key change, otherwise check.sh reports `header differs`:

```bash
U=<md uuid>; F=/root/luks-pools/${U//:/-}-header.img
rm -f $F && cryptsetup luksHeaderBackup /dev/mdN --header-backup-file $F
```

Copy the new file off the NAS.

**Before a TOS firmware update.** The update may reset `/opt`, the root filesystem or systemd units, and it reboots on its own. Prepare so that a reset does not leave a pool locked in front of TOS:

1. Copy the installer to a data volume as well: `mkdir -p /Volume1/@luks-kit && cp /root/luks-pools/* /Volume1/@luks-kit/`.
2. Plug in the NASKEY USB stick (Part B) for the first boot after the update. If the update switched SSH off or removed Python or the certificate, the browser page or SSH may be unavailable for that boot; the stick still unlocks it. Run the update while you can watch it.
3. If the boot waits as usual, unlock and run check.sh. A FAIL on shims or the unit: run `bash /Volume1/@luks-kit/luks-kit-install.sh`, then check.sh again.
4. If the boot did NOT wait (the web UI shows an encrypted pool as damaged), do not click anything in the UI and follow E1.

**Debug logging** (only for troubleshooting): `touch /opt/lvmshim/DEBUG` logs every call TOS makes through the shims, with output, to `/root/luks-pools/calls.log`; `rm /opt/lvmshim/DEBUG` turns it off.

## Part E — Recovery

In every case: do not click repair, initialize, remount or delete on an encrypted pool in the UI while something is wrong.

**E1. TOS booted with a pool still locked** (UI shows “RAID is corrupted”, or a stray StoragePoolN/VolumeN appeared). Earlier tests showed TOS then runs `tune2fs`/`e2fsck` on the array; both refuse to write to a LUKS header, so data is safe, but TOS adds bogus config entries.

```bash
[ -x /opt/lvmshim/unlock.sh ] || bash /Volume1/@luks-kit/luks-kit-install.sh
/opt/lvmshim/unlock.sh
for u in $(grep -vE '^[[:space:]]*(#|$)' /opt/lvmshim/pools.conf); do
  for f in storage.conf volume.conf; do
    awk -v s="[$u]" '/^\[/{skip=($0==s)} !skip' /etc/volume/$f > /tmp/$f && cat /tmp/$f > /etc/volume/$f
  done
done
systemctl is-enabled luks-pools.service || systemctl enable luks-pools.service
```

Then reboot, unlock normally and run check.sh.

**E2. Pool unlocked but shown as “RAID is corrupted, 0/N disks”.** Usually a stale device hint:

```bash
vgcfgbackup; grep -H 'device = ' /etc/lvm/backup/*; systemctl restart StorageManager
```

Every hint must read `/dev/mdN`, never `/dev/mapper/…`.

**E3. LUKS header damaged** (unlock fails with the right passphrase, check.sh reports `header differs`). With the array assembled and not opened:

```bash
cryptsetup luksHeaderRestore /dev/mdN --header-backup-file /root/luks-pools/<md-uuid>-header.img
```

**E4. Read the data without TOS** (for example, disks in a Linux PC). Volumes are btrfs with the data in subvolume `@`:

```bash
mdadm --assemble --scan
cryptsetup open /dev/mdN cryptN
vgchange -ay
mount -o subvol=@ /dev/vgN/lvN /mnt
```

**E5. Remove the kit.** Only once no pool in `pools.conf` holds data you need through TOS: `systemctl disable luks-pools.service; /opt/lvmshim/remove-shims.sh`. Encrypted pools then stay readable only by E4.

## Known limits

- **Reverse-engineered.** This works because of how TOS 7 (TOS\_ARM2.0\_6.0.587) probes storage. A firmware update can change that; treat every update as Part D's checklist.
- **Proven on the NAS:** conversion by hand (md1) and by `convert-pool.sh` (md2, single USB disk); unlock at boot over SSH and the browser page; pools and volumes shown healthy; volume create and extend from the UI; RAID disk failure, re-add and 5 h resync with TOS's automatic `pvresize`; clean TOS install adopting an encrypted pool; booting with an encrypted pool's disks removed.
- **Untested:** pool expansion (more or larger disks), pool deletion, behaviour across a TOS firmware update.
- **Only empty pools can be converted.** Existing data would have to be moved off and back.
- **Never insert encrypted disks into a running NAS**, or into a TOS that does not have them in `pools.conf`: power off, insert, power on, unlock.
- **Old header backups keep old passphrases valid.** After changing a passphrase, delete every older copy of that pool's header backup, including the ones off the NAS.
- **Not an App Center app.** TOS 7 store apps may not run as root or write to `/etc` or `/usr`; this kit needs both, so it stays an SSH-installed kit.
- **Volume1 / StoragePool1 stays unencrypted**: it holds TOS apps, the home folders and the kit copy in `@luks-kit`; keep it that way.

## Changes

| Kit version | Change |
| --- | --- |
| 2026-10-25 | Version stamp in `/opt/lvmshim/VERSION`, shown by `check.sh` |
| 2026-10-19 | `convert-pool.sh` 4K-aligns the LVM data start and test-creates a volume; `check.sh` checks alignment |
| 2026-10-19 | Unlock page redirects after each attempt, so a reloaded tab can never resend the passphrase |
| 2026-10-19 | Pools whose disks are all removed are skipped at boot instead of waited for |
| 2026-10-18 | Generic kit: pools by md UUID, `cryptN` naming, browser unlock page, wait without time limit, `check.sh`, `convert-pool.sh` |
