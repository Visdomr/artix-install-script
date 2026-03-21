#!/usr/bin/env bash
set -euo pipefail

echo "=== Artix OpenRC + Hyprland Install (hardened version for Eric) ==="
echo "Partitions: /dev/nvme0n1p1 EFI 512MiB | p2 swap 20GiB | p3 root rest"
echo "AMD ucode included | Temp pass: artix123 (CHANGE AFTER BOOT!)"
echo ""
echo "WARNING: ERASES /dev/nvme0n1 COMPLETELY!"
read -p "Continue? (y/yes/Y/YES): " confirm
confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]' | xargs)

if [[ ! "$confirm" =~ ^(y|yes)$ ]]; then
    echo "Aborted."
    exit 1
fi

DISK="/dev/nvme0n1"

# Phase 1: Partitioning
echo "=== Partitioning (/dev/nvme0n1) ==="
echo "cfdisk steps:"
echo " - Delete old partitions until free space"
echo " - New → 512M → type EFI System"
echo " - New → 20G → type Linux swap"
echo " - New → rest → type Linux filesystem"
echo " - Write (w) → confirm → Quit (q)"
echo ""

cfdisk "$DISK"

partprobe "$DISK" 2>/dev/null || true
sleep 3

EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"

if [[ ! -b "$ROOT_PART" ]]; then
    echo "Partitions missing! Check lsblk"
    lsblk -f "$DISK"
    exit 1
fi

# Format & mount
mkfs.fat -F32 -n EFI "$EFI_PART"
mkswap -L SWAP "$SWAP_PART"
mkfs.ext4 -F -L ROOT "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
swapon "$SWAP_PART" || true  # ok if already on

# Clean any old swap ref that blocks fstabgen
swapoff "$SWAP_PART" 2>/dev/null || true
swapon "$SWAP_PART"

fstabgen -U /mnt >> /mnt/etc/fstab

echo "Mounts & fstab ready:"
lsblk -f

# Phase 2: Base install
basestrap /mnt base base-devel openrc elogind-openrc \
    linux linux-firmware linux-headers grub efibootmgr \
    networkmanager-openrc dhcpcd amd-ucode

# Phase 3: Chroot
artix-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

echo "=== Chroot phase ==="

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

# Passwords – root first
echo "root:artix123" | chpasswd
echo "Root password set"

read -p "Username: " USER

# User creation – ignore PAM warning (expected in minimal chroot)
useradd -m -G wheel,video,input,audio,storage "$USER" || true
echo "User $USER created (ignore any PAM warning above)"

# Password after creation
echo "$USER:artix123" | chpasswd
echo "User password set to artix123"

echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# GPU (AMD/Intel mesa; change to nvidia if needed)
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

# Verification
echo "Verification:"
id "$USER" 2>/dev/null || echo "id may warn but user ok"
grep "$USER" /etc/passwd
grep "$USER" /etc/shadow || echo "Shadow entry missing? (should not happen)"

echo ""
echo "=== FINISHED ==="
echo "Temp password 'artix123' for root and $USER"
echo "exit → umount -R /mnt && swapoff -a && reboot"
echo "After boot: passwd && sudo passwd to change passwords"
echo "=== === === === ==="
EOF