#!/usr/bin/env bash
set -euo pipefail

echo "=== Artix + Hyprland installer – conflict-fixed edition ==="
echo "Partitions: /dev/nvme0n1 p1=512M EFI | p2=20G swap | p3=rest root"
echo "Temp password: artix123 (change after boot!)"
echo ""
echo "WARNING: WILL ERASE /dev/nvme0n1"
read -p "Type YES to continue: " confirm
if [[ "${confirm^^}" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

DISK="/dev/nvme0n1"

# Partitioning
echo -e "\ncfdisk: delete all → New 512M EFI System → New 20G Linux swap → New rest Linux filesystem → w → q\n"
cfdisk "$DISK"

partprobe "$DISK" || true
sleep 4

EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"

[[ -b "$ROOT_PART" ]] || { echo "Partitions missing"; lsblk; exit 1; }

mkfs.fat -F32 -n EFI "$EFI_PART"   || true
mkswap -L SWAP "$SWAP_PART"        || true
mkfs.ext4 -F -L ROOT "$ROOT_PART"  || true

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
swapon "$SWAP_PART" || true

# Create /etc early
mkdir -p /mnt/etc
chown root:root /mnt/etc
chmod 755 /mnt/etc

fstabgen -U /mnt >> /mnt/etc/fstab || true
cat /mnt/etc/fstab

# Base
basestrap /mnt base base-devel openrc elogind-openrc \
    linux linux-firmware linux-headers grub efibootmgr amd-ucode \
    networkmanager-openrc dhcpcd || true

# Chroot
artix-chroot /mnt /bin/bash <<'CHROOT' || true
set -euo pipefail

echo "=== Chroot ==="

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

echo "root:artix123" | chpasswd || true

read -r -p "Your username: " USER

useradd -m -G wheel,video,input,audio,storage "$USER" || true
echo "$USER:artix123" | chpasswd || true

echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg || true

# Fix conflict: remove old xorg-server-common if present
pacman -Rdd --noconfirm xorg-server-common || true

# Install packages – split to avoid conflict
pacman -S --noconfirm --needed mesa vulkan-radeon vulkan-intel \
    networkmanager networkmanager-openrc bluez bluez-openrc blueman \
    pipewire pipewire-openrc pipewire-alsa pipewire-pulse wireplumber wireplumber-openrc \
    qt5-wayland qt6-wayland polkit-gnome grim slurp wl-clipboard brightnessctl pavucontrol \
    ttf-jetbrains-mono-nerd noto-fonts ttf-font-awesome alacritty thunar firefox || true

pacman -S --noconfirm --overwrite '*' hyprland xdg-desktop-portal-hyprland \
    waybar hyprpaper hyprlock hypridle mako fuzzel || true

rc-update add NetworkManager default bluetoothd default dbus default || true

su - "$USER" -c "rc-update --user add pipewire default"   || true
su - "$USER" -c "rc-update --user add wireplumber default" || true

read -p "Install SDDM? [y/N] " sddm
if [[ "$sddm" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm sddm sddm-openrc || true
    rc-update add sddm default || true
else
    echo '[[ -z $DISPLAY && $(tty) = /dev/tty1 ]] && exec Hyprland' >> /home/"$USER"/.bash_profile
fi

chown -R "$USER:$USER" /home/"$USER" || true

echo "=== FINISHED ==="
echo "Temp pass artix123 for root and $USER"
echo "exit → umount -R /mnt && swapoff -a && reboot"
echo "After boot: passwd && sudo passwd"
CHROOT

echo "Script done. Now:"
echo "umount -R /mnt && swapoff -a && reboot"