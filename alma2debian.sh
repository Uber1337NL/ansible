#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Remote AlmaLinux 8 -> Debian 13 (trixie) parallel install in existing LUKS+LVM
# - Keeps AlmaLinux UEFI entry as fallback
# - Installs Debian into new LVs inside VG 'almalinux' (inside existing LUKS)
# - Secure Boot friendly: installs Debian shim/grub signed into EFI/debian
# - Uses BootNext for one-time test boot into Debian
#
# REQUIREMENTS (on AlmaLinux):
#   - docker working
#   - VG 'almalinux' exists and has enough free space
#   - /boot and /boot/efi mounted (as in your system)
#   - SSH_PUB_KEY variable set on line 44 (for root login to Debian)
#
# OPTIONAL (hardcoded in this script):
#   AUTO_REBOOT="0" or "1"   # reboot at the end
#   FORCE="0" or "1"         # overwrite existing debian_* LVs if they exist
#
# Randy ten Have @ DHL 2026-04-29 - https://github.com/Uber1337NL
###############################################################################

### ====== User-tunable config ======
SUITE="trixie"                     # Debian 13
MIRROR="http://deb.debian.org/debian"
ARCH="amd64"

VG="almalinux"

# Just for basics we need root, swap and repo. Adjust sizes as needed (total must fit in free space of VG).
LV_ROOT="debian_root"
LV_SWAP="debian_swap"
LV_REPO="debian_repo"

SIZE_ROOT="${SIZE_ROOT:-40G}"
SIZE_SWAP="${SIZE_SWAP:-4G}"
SIZE_REPO="${SIZE_REPO:-6G}"

MNT_ROOT="/mnt/debian"
MNT_REPO="/mnt/local_repo"

# Hardcode your public key here (single line, no trailing spaces).
SSH_PUB_KEY="<SSH_PUB_KEY>"

# Optional manual override for the LUKS container block device (example: /dev/nvme0n1p3).
LUKS_DEV="${LUKS_DEV:-}"

IPV4_ADDR="192.168.1.101/24"
IPV4_GW="192.168.1.1"
DNS1="192.168.1.1"

AUTO_REBOOT="0"
FORCE="0"

### ====== Derived values ======
ESP_DEV="$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)"
BOOT_DEV="$(findmnt -n -o SOURCE /boot 2>/dev/null || true)"
DISK="/dev/$(lsblk -ndo pkname "$ESP_DEV" 2>/dev/null || true)"
ESP_PARTNUM="$(lsblk -ndo PARTNUM "$ESP_DEV" 2>/dev/null || true)"

if [[ -z "$LUKS_DEV" ]]; then
  # First PV belonging to the target VG is typically the unlocked LUKS mapping.
  LUKS_DEV="$(pvs --noheadings -o pv_name --select "vg_name=$VG" 2>/dev/null | awk 'NR==1{gsub(/^ +| +$/,"",$0); print; exit}')"
fi

# Get UUIDs we reference in crypttab and fstab.
LUKS_UUID="$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null || true)"
ESP_UUID="$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)"
BOOT_UUID="$(blkid -s UUID -o value "$BOOT_DEV" 2>/dev/null || true)"

NET_IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
MAC_ADDR="$(cat "/sys/class/net/${NET_IFACE}/address" 2>/dev/null || true)"
HOSTNAME="$(tr -d ':' < "/sys/class/net/${NET_IFACE}/address" 2>/dev/null || true)"

if [[ -z "$SSH_PUB_KEY" ]]; then
  echo "ERROR: SSH_PUB_KEY is empty. Set it in this script."
  exit 1
fi

if [[ -z "$ESP_DEV" || -z "$BOOT_DEV" || -z "$ESP_PARTNUM" || -z "$DISK" ]]; then
  echo "ERROR: Could not detect disk/ESP/boot devices from mounted /boot and /boot/efi"
  exit 1
fi

if [[ -z "$LUKS_DEV" || -z "$LUKS_UUID" ]]; then
  echo "ERROR: Could not detect LUKS/PV device UUID (set LUKS_DEV manually)."
  exit 1
fi

if [[ -z "$NET_IFACE" || -z "$MAC_ADDR" || -z "$HOSTNAME" ]]; then
  echo "ERROR: Could not detect active network interface MAC address"
  exit 1
fi

echo "== Config summary =="
echo "Host:        $HOSTNAME (MAC: $MAC_ADDR)"
echo "Debian:      $SUITE"
echo "VG:          $VG"
echo "LVs:         $LV_ROOT ($SIZE_ROOT), $LV_SWAP ($SIZE_SWAP), $LV_REPO ($SIZE_REPO)"
echo "IP:          $IPV4_ADDR  GW: $IPV4_GW  DNS: $DNS1"
echo "NIC:         $NET_IFACE"
echo "Disk:        $DISK (ESP part: $ESP_PARTNUM)"
echo "LUKS dev:    $LUKS_DEV"
echo "ESP UUID:    $ESP_UUID"
echo "BOOT UUID:   $BOOT_UUID"
echo "LUKS UUID:   $LUKS_UUID"
echo

### ====== Helpers ======
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_mounts() {
  set +e
  umount -R "$MNT_ROOT" >/dev/null 2>&1 || true
  umount "$MNT_REPO" >/dev/null 2>&1 || true
  set -e
}
trap cleanup_mounts EXIT

need_cmd docker
need_cmd vgs
need_cmd lvs
need_cmd lvcreate
need_cmd mkfs.ext4
need_cmd mkswap
need_cmd mount
need_cmd mountpoint
need_cmd findmnt
need_cmd efibootmgr
need_cmd lsblk
need_cmd blkid
need_cmd pvs
need_cmd ip
need_cmd awk

# Sanity: secure boot likely enabled; ensure Alma shim entry exists
efibootmgr -v | grep -q "AlmaLinux.*\\\\EFI\\\\almalinux\\\\shimx64\.efi" || \
  echo "WARN: AlmaLinux shim entry not found exactly as expected in efibootmgr -v (continuing)."

# Ensure /boot and /boot/efi mounted (we bind-mount them into Debian)
mountpoint -q /boot || die "/boot is not mounted"
mountpoint -q /boot/efi || die "/boot/efi is not mounted"

# Ensure VG exists
vgs "$VG" >/dev/null 2>&1 || die "VG '$VG' not found"

# Create or reuse LVs
create_lv() {
  local lv="$1" size="$2"
  if lvs "/dev/$VG/$lv" >/dev/null 2>&1; then
    if [[ "$FORCE" == "1" ]]; then
      echo "FORCE=1: Removing existing LV $VG/$lv"
      lvremove -y "/dev/$VG/$lv"
    else
      die "LV $VG/$lv already exists. Set FORCE=1 to overwrite."
    fi
  fi
  echo "Creating LV $VG/$lv size $size"
  lvcreate -y -L "$size" -n "$lv" "$VG"
}

echo "== Creating LVs =="
create_lv "$LV_ROOT" "$SIZE_ROOT"
create_lv "$LV_SWAP" "$SIZE_SWAP"
create_lv "$LV_REPO" "$SIZE_REPO"

echo "== Formatting LVs =="
mkfs.ext4 -F "/dev/$VG/$LV_ROOT"
mkswap -f "/dev/$VG/$LV_SWAP"
mkfs.ext4 -F "/dev/$VG/$LV_REPO"

echo "== Mounting target root and repo =="
mkdir -p "$MNT_ROOT" "$MNT_REPO"
mount "/dev/$VG/$LV_ROOT" "$MNT_ROOT"
mount "/dev/$VG/$LV_REPO" "$MNT_REPO"

# Bind-mount boot partitions so Debian installs kernel/initrd and EFI files correctly
mkdir -p "$MNT_ROOT/boot" "$MNT_ROOT/boot/efi" "$MNT_ROOT/srv/repo"
mount --bind /boot "$MNT_ROOT/boot"
mount --bind /boot/efi "$MNT_ROOT/boot/efi"
mount --bind "$MNT_REPO" "$MNT_ROOT/srv/repo"

###############################################################################
# Step A: Build a small local APT repo (MAIN only) with "extras" (kernel/ssh/etc)
###############################################################################
echo "== Building local APT repo in $MNT_REPO (MAIN only, small core set) =="

cat > /root/debian-seeds.txt << 'EOF'
linux-image-amd64
shim-signed
grub-efi-amd64-signed
cryptsetup
cryptsetup-initramfs
lvm2
clevis
clevis-luks
clevis-tpm2
tpm2-tools
openssh-server
sudo
efibootmgr
ca-certificates
curl
EOF

docker run --rm --privileged \
  -e SUITE="$SUITE" -e ARCH="$ARCH" -e MIRROR="$MIRROR" \
  -v "$MNT_REPO:/repo" \
  -v /root/debian-seeds.txt:/seeds.txt:ro \
  debian:trixie bash -euxo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates dpkg-dev apt-ftparchive

    mkdir -p /repo/pool /repo/dists/${SUITE}/main/binary-${ARCH} /repo/.cache/apt-archives

    cat > /etc/apt/apt.conf.d/99localcache << EOF
Dir::Cache::archives "/repo/.cache/apt-archives";
Acquire::Languages "none";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

    echo "deb ${MIRROR} ${SUITE} main" > /etc/apt/sources.list
    apt-get update

    xargs -a /seeds.txt apt-get -y --download-only install

    find /repo/.cache/apt-archives -maxdepth 1 -type f -name "*.deb" -exec cp -n {} /repo/pool/ \;

    cd /repo
    dpkg-scanpackages -m pool /dev/null | gzip -9c > dists/${SUITE}/main/binary-${ARCH}/Packages.gz
    apt-ftparchive release dists/${SUITE} > dists/${SUITE}/Release
  '

echo "Repo OK: $(ls -lh "$MNT_REPO/dists/$SUITE/main/binary-amd64/Packages.gz" | awk "{print \$5}") Packages.gz"

###############################################################################
# Step B: debootstrap (minbase) into the new Debian root (small network usage)
###############################################################################
echo "== Debootstrap Debian (minbase) into $MNT_ROOT =="

docker run --rm --privileged \
  -v "$MNT_ROOT:/target" \
  debian:trixie bash -euxo pipefail -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends debootstrap ca-certificates
    debootstrap --arch=$ARCH --variant=minbase $SUITE /target $MIRROR
  "

###############################################################################
# Step C: Configure Debian in chroot + install extras from local repo
###############################################################################
echo "== Configuring Debian (chroot) =="

# Prepare chroot mounts
mount --bind /dev  "$MNT_ROOT/dev"
mount --bind /proc "$MNT_ROOT/proc"
mount --bind /sys  "$MNT_ROOT/sys"

# Put resolver for apt inside chroot now
cat > "$MNT_ROOT/etc/resolv.conf" << EOF
nameserver $DNS1
EOF

chroot "$MNT_ROOT" /bin/bash -euxo pipefail -c "
  export DEBIAN_FRONTEND=noninteractive

  echo '$HOSTNAME' > /etc/hostname

  # APT: prefer local repo, keep mirror as fallback (main only)
  cat > /etc/apt/sources.list << EOF
deb [trusted=yes] file:/srv/repo $SUITE main
deb $MIRROR $SUITE main
EOF

  apt-get update

  # Install core packages (prefer local repo; if LTE is down and local has all, this still works)
  apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    shim-signed grub-efi-amd64-signed \
    cryptsetup cryptsetup-initramfs lvm2 \
    clevis clevis-luks clevis-tpm2 tpm2-tools \
    openssh-server sudo efibootmgr ca-certificates curl

  # SSH key for root
  install -d -m 0700 /root/.ssh
  cat > /root/.ssh/authorized_keys << EOF
$SSH_PUB_KEY
EOF
  chmod 0600 /root/.ssh/authorized_keys

  # Static networking with systemd-networkd (interface-name independent; match by MAC)
  install -d -m 0755 /etc/systemd/network
  cat > /etc/systemd/network/10-wired.network << EOF
[Match]
MACAddress=$MAC_ADDR

[Network]
Address=$IPV4_ADDR
Gateway=$IPV4_GW
DNS=$DNS1
EOF

  systemctl enable systemd-networkd
  systemctl enable systemd-resolved || true

  # Keep resolv.conf simple (static) to avoid surprises on first boot
  cat > /etc/resolv.conf << EOF
nameserver $DNS1
EOF

  # crypttab: open existing LUKS container so LVM (VG almalinux) becomes available at boot
  # Note: clevis token already exists in LUKS header; packages should add initramfs integration.
  cat > /etc/crypttab << EOF
luks-$LUKS_UUID UUID=$LUKS_UUID none luks,discard
EOF

  # fstab: mount our new root LV, existing /boot and /boot/efi, swap, and local repo
  cat > /etc/fstab << EOF
/dev/mapper/$VG-$LV_ROOT   /         ext4  defaults          0  1
UUID=$BOOT_UUID            /boot     xfs   defaults          0  2
UUID=$ESP_UUID             /boot/efi vfat  umask=0077        0  2
/dev/mapper/$VG-$LV_SWAP   none      swap  sw                0  0
/dev/mapper/$VG-$LV_REPO   /srv/repo  ext4 defaults,nofail   0  2
EOF

  # Rebuild initramfs (must include cryptsetup+lvm+clevis bits)
  update-initramfs -u -k all

  # Sanity check: ensure clevis bits are present in initramfs; abort hard if not
  KVER=\$(ls -1 /boot/vmlinuz-* | sed 's#.*/vmlinuz-##' | sort -V | tail -1)
  echo \"Using kernel: \$KVER\"
  lsinitramfs /boot/initrd.img-\$KVER | grep -Ei 'clevis' >/dev/null

  # Install Debian signed EFI loader into ESP under EFI/debian without touching NVRAM
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --no-nvram
  update-grub
"

echo "== Creating UEFI NVRAM entry for Debian (if not exists) =="

# Ensure Debian EFI files exist on ESP
test -f /boot/efi/EFI/debian/shimx64.efi || die "Missing /boot/efi/EFI/debian/shimx64.efi"
test -f /boot/efi/EFI/debian/grubx64.efi || echo "WARN: /boot/efi/EFI/debian/grubx64.efi not found (may still be ok depending on layout)."

# Create entry if absent
if ! efibootmgr -v | grep -q "Debian.*\\\\EFI\\\\debian\\\\shimx64\.efi"; then
  efibootmgr --create --disk "$DISK" --part "$ESP_PARTNUM" --label "Debian" --loader '\EFI\debian\shimx64.efi' --verbose
fi

# Get Debian bootnum
DEB_BOOTNUM="$(efibootmgr -v | awk '
  $0 ~ /^Boot[0-9A-Fa-f]{4}\*/ && $0 ~ /Debian/ && $0 ~ /\\EFI\\debian\\shimx64\.efi/ {
    gsub(/^Boot/,"",$1); gsub(/\*/,"",$1); print $1; exit
  }'
)"

[[ -n "$DEB_BOOTNUM" ]] || die "Could not determine Debian boot entry number."

echo "Debian UEFI entry: Boot$DEB_BOOTNUM"
echo
echo "== Setting BootNext to Debian for ONE-TIME test boot (fallback remains AlmaLinux) =="
efibootmgr --bootnext "$DEB_BOOTNUM"

echo
echo "SUCCESS. Next boot will try Debian once."
echo "If Debian fails, power-cycle -> firmware should use normal BootOrder (AlmaLinux fallback entry remains)."
echo
echo "To reboot now:  set AUTO_REBOOT=1 in this script and re-run, or run: reboot"
if [[ "$AUTO_REBOOT" == "1" ]]; then
  reboot
fi
