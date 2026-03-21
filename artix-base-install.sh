#!/usr/bin/env bash
set -euo pipefail

echo "=== Artix + Hyprland installer 2025 – hopefully the last version ==="
echo "This script will:"
echo "  - Partition /dev/nvme0n1 (512M EFI + 20G swap + rest root)"
echo "  - Install base + OpenRC + AMD ucode + Hyprland stack"
echo "  - Use temporary password: artix123"
echo ""
echo "THIS WILL ERASE /dev/nvme0n1 COMPLETELY"
read -p "Type YES to continue: " confirm
if [[ "${confirm^^}" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"

# Partitioning guidance
echo -e "\n=== Partitioning guidance ==="
echo "In cfdisk do exactly this:"
echo "1. Delete all existing partitions until free space only"
echo "2. New → 512M → type → EFI System"
echo "3. New → 20G  → type → Linux swap"
echo "4. New → (rest of space) → type → Linux filesystem"
echo "5. Write changes (w) → confirm → Quit (q)"
echo ""
cfdisk "$DISK"

echo "Refreshing partition table..."
partprobe "$DISK" || true
sleep 4

# Validate partitions exist
if [[ ! -b "$ROOT_PART" ]]; then
    echo "Root partition not found. Check with lsblk"
    lsblk -f
    exit 1
fi

# Format
echo "Formatting partitions..."
mkfs.fat -F32 -n EFI "$EFI_PART"   || true
mkswap -L SWAP "$SWAP_PART"        || true
mkfs.ext4 -F -L ROOT "$ROOT_PART"  || true

# Mount
mount "$ROOT_PART" /mnt               || { echo "Mount root failed"; exit 1; }
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot           || true
swapon "$SWAP_PART"                   || true

# Critical: create /etc early + fix permissions
mkdir -p /mnt/etc
chown root:root /mnt/etc
chmod 755 /mnt/etc

# Generate fstab
echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab || {
    echo "fstabgen failed – trying manual fallback"
    echo "UUID=$(blkid -s UUID -o value $EFI_PART)  /boot  vfat  defaults  0 2" >> /mnt/etc/fstab
    echo "UUID=$(blkid -s UUID -o value $ROOT_PART) /      ext4  defaults  0 1" >> /mnt/etc/fstab
    echo "UUID=$(blkid -s UUID -o value $SWAP_PART) none   swap  defaults  0 0" >> /mnt/etc/fstab
}

cat /mnt/etc/fstab

# Base system
echo "Installing base system..."
basestrap /mnt base base-devel openrc elogind-openrc \
    linux linux-firmware linux-headers grub efibootmgr \
    amd-ucode networkmanager-openrc dhcpcd || true

# Chroot
echo "Entering chroot..."
artix-chroot /mnt /bin/bash <<'CHROOT' || true
set -euo pipefail

echo "=== Inside chroot ==="

# Basic setup
HOSTNAME="artix-hyprland"
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

# Passwords – root first
echo "root:artix123" | chpasswd || echo "root password failed – try manually later"

read -r -p "Your username: " USERNAME

# User creation – ignore PAM error
useradd -m -G wheel,video,input,audio,storage "$USERNAME" || true
echo "$USERNAME:artix123" | chpasswd || echo "User password step failed – try passwd after boot"

echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg || true

# Packages
pacman -S --noconfirm --needed mesa vulkan-radeon vulkan-intel \
    networkmanager networkmanager-openrc \
    pipewire pipewire-openrc pipewire-alsa pipewire-pulse wireplumber wireplumber-openrc \
    hyprland xdg-desktop-portal-hyprland waybar hyprpaper hyprlock hypridle \
    mako fuzzel qt5-wayland qt6-wayland polkit-gnome grim slurp wl-clipboard \
    brightnessctl pavucontrol ttf-jetbrains-mono-nerd noto-fonts ttf-font-awesome \
    alacritty thunar firefox blueman bluez bluez-openrc || true

rc-update add NetworkManager default bluetoothd default dbus default || true

su - "$USERNAME" -c "rc-update --user add pipewire default"   || true
su - "$USERNAME" -c "rc-update --user add wireplumber default" || true

# Optional SDDM
read -p "Install SDDM login manager? [y/N]: " sddm
if [[ "$sddm" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm sddm sddm-openrc || true
    rc-update add sddm default || true
else
    echo '[[ -z $DISPLAY && $(tty) = /dev/tty1 ]] && exec Hyprland' >> /home/"$USERNAME"/.bash_profile
fi

chown -R "$USERNAME:$USERNAME" /home/"$USERNAME" || true

echo ""
echo "========================================"
echo "Installation reached the end."
echo "Temporary password: artix123"
echo "Commands to finish:"
echo "  exit"
echo "  umount -R /mnt"
echo "  swapoff -a"
echo "  reboot"
echo ""
echo "After boot → login → passwd (your user) → sudo passwd (root)"
echo "========================================"
CHROOT

echo "Script finished (or chroot exited). Now run:"
echo "umount -R /mnt && swapoff -a && reboot"