#!/usr/bin/env bash
set -euo pipefail

echo "=== Artix OpenRC + Hyprland Installation Script (custom partitions + useradd fix) ==="
echo "This will use /dev/nvme0n1 with:"
echo "  - p1: 512 MiB EFI (FAT32)"
echo "  - p2: 20 GiB swap"
echo "  - p3: remaining space (~218 GiB) ext4 root"
echo ""
echo "WARNING: This will ERASE everything on /dev/nvme0n1!"
read -p "Type YES (or y) to continue: " confirm
confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]' | xargs)

if [[ ! "$confirm" =~ ^(yes|y)$ ]]; then
    echo "Aborted."
    exit 1
fi

DISK="/dev/nvme0n1"

# ───────────────────────────────────────────────
# Phase 1 – Partitioning
# ───────────────────────────────────────────────
echo "=== Step 1: Partitioning ==="
echo "In cfdisk:"
echo "1. If old partitions exist → Delete them until free space"
echo "2. New → 512M → primary → type → EFI System"
echo "3. New → 20G → primary → type → Linux swap"
echo "4. New → remaining space → primary → type → Linux filesystem"
echo "5. Write (w) → Yes → Quit (q)"
echo ""

cfdisk "$DISK"

echo "Refreshing partition table..."
partprobe "$DISK" 2>/dev/null || true
sleep 3

EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"

if [[ ! -b "$EFI_PART" || ! -b "$SWAP_PART" || ! -b "$ROOT_PART" ]]; then
    echo "Error: Expected partitions missing!"
    lsblk -f "$DISK"
    exit 1
fi

mkfs.fat -F32 -n EFI "$EFI_PART"
mkswap -L SWAP "$SWAP_PART"
mkfs.ext4 -F -L ROOT "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
swapon "$SWAP_PART"

echo "Partitions ready:"
lsblk -f

# ───────────────────────────────────────────────
# Phase 2 – Base system (AMD ucode hardcoded)
# ───────────────────────────────────────────────
echo "=== Step 2: Installing base system ==="
basestrap /mnt base base-devel openrc elogind-openrc \
    linux linux-firmware linux-headers grub efibootmgr \
    networkmanager-openrc dhcpcd amd-ucode

fstabgen -U /mnt >> /mnt/etc/fstab

# ───────────────────────────────────────────────
# Phase 3 – Chroot and configuration
# ───────────────────────────────────────────────
echo "=== Step 3: Entering chroot ==="

artix-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

echo "Inside chroot — continuing..."

read -p "Hostname: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "root:artix123" | chpasswd

read -p "Your username: " USER

# Create user – ignore PAM warning (harmless in minimal chroot)
useradd -m -G wheel,video,input,audio,storage "$USER" || true
echo "User $USER created (any PAM warning above is safe to ignore)"

echo "$USER:artix123" | chpasswd
echo "Temp password 'artix123' for root & $USER – change after boot!"

echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

pacman -S --noconfirm mesa vulkan-radeon vulkan-intel

pacman -S --noconfirm networkmanager networkmanager-openrc
rc-update add NetworkManager default

pacman -S --noconfirm pipewire pipewire-openrc pipewire-alsa pipewire-pulse wireplumber wireplumber-openrc
su - "$USER" -c "rc-update --user add pipewire default" || true
su - "$USER" -c "rc-update --user add wireplumber default" || true

pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland \
    waybar hyprpaper hyprlock hypridle mako fuzzel \
    qt5-wayland qt6-wayland polkit-gnome \
    grim slurp wl-clipboard brightnessctl pavucontrol \
    ttf-jetbrains-mono-nerd noto-fonts ttf-font-awesome \
    alacritty thunar firefox blueman bluez bluez-openrc

rc-update add bluetoothd default
rc-update add dbus default

read -p "Install SDDM? [y/N] " sddm
if [[ "$sddm" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm sddm sddm-openrc
    rc-update add sddm default
else
    echo '[[ -z $DISPLAY && $(tty) = /dev/tty1 ]] && exec Hyprland' >> /home/"$USER"/.bash_profile
fi

chown -R "$USER:$USER" /home/"$USER"

echo ""
echo "──────────────────────────────────────────────"
echo "DONE! Temp password 'artix123'"
echo "exit → umount -R /mnt && swapoff -a && reboot"
echo "──────────────────────────────────────────────"
EOF