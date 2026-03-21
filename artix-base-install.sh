#!/usr/bin/env bash
set -euo pipefail

echo "=== Artix OpenRC → Hyprland Full Install Script (FIXED VERSION) ==="
echo "Run this as root from the LIVE base-openrc ISO"
echo ""

# ───────────────────────────────────────────────
#  Phase 0 — Networking (same as before)
# ───────────────────────────────────────────────
#echo "=== Step 0: Networking ==="
#ip -c link show
#echo ""
#read -p "Wired interface (e.g. enp3s0) or press Enter for Wi-Fi → " WIRED_IFACE

#if [[ -n "$WIRED_IFACE" ]]; then
    #dhcpcd "$WIRED_IFACE" || true
#else
    #echo "Wi-Fi mode"
    #read -p "Wireless interface (usually wlan0) → " WLAN_IFACE
    #: "${WLAN_IFACE:=wlan0}"
    #rfkill unblock wifi || true
    #ip link set "$WLAN_IFACE" up || true
    #connmanctl enable wifi 2>/dev/null || true
    #connmanctl scan wifi
    #echo ""
    #connmanctl services
    #echo ""
    #read -p "Copy-paste FULL service name (wifi_...) → " SERVICE
    #connmanctl agent on
    #connmanctl connect "$SERVICE"
#fi

echo -n "Testing internet... "
ping -c 1 -W 4 8.8.8.8 &>/dev/null && echo "OK" || { echo "FAILED"; exit 1; }
pacman -Syy

# ───────────────────────────────────────────────
#  Phase 1 — Partitioning (FIXED + SWAP SUPPORT)
# ───────────────────────────────────────────────
echo "=== Step 1: Partition your disk (NOW WITH SWAP) ==="
echo "Your setup: 238 GB total for root + swap, 16 GB RAM"
echo "Recommended in cfdisk:"
echo "   • p1: EFI     512M–1G     (type EF00)"
echo "   • p2: Swap    8 GB (no hibernation) or 18–20 GB (with hibernation)"
echo "   • p3: Root    the rest (~210–220 GB)"
echo ""
read -p "Disk to install on? (e.g. /dev/nvme0n1) → " DISK
cfdisk "$DISK"

echo "Refreshing partition table..."
partprobe "$DISK" 2>/dev/null || true
sleep 3
echo "Current partitions:"
lsblk -f -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

echo ""
echo "Enter FULL paths (script will auto-fix if you forget /dev/)"
read -p "EFI partition  (e.g. /dev/nvme0n1p1) → " EFI_PART
read -p "Swap partition (e.g. /dev/nvme0n1p2) or leave EMPTY for no swap → " SWAP_PART
read -p "Root partition (e.g. /dev/nvme0n1p3) → " ROOT_PART

# Auto-add /dev/ if user forgets (this fixes your exact error)
for var in EFI_PART ROOT_PART SWAP_PART; do
    val="${!var}"
    if [[ -n "$val" && ! "$val" == /dev/* ]]; then
        declare "$var=/dev/$val"
    fi
done

# Format & mount
mkfs.fat -F32 "$EFI_PART"
if [[ -n "$SWAP_PART" ]]; then
    echo "Creating swap on $SWAP_PART"
    mkswap -L SWAP "$SWAP_PART"
    swapon "$SWAP_PART"
fi
mkfs.ext4 -F -L ROOT "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "✅ Partitions formatted and mounted successfully!"

# ───────────────────────────────────────────────
#  Phase 2 — basestrap base system
# ───────────────────────────────────────────────
echo "=== Step 2: Installing base system ==="
basestrap /mnt base base-devel openrc elogind-openrc \
    linux linux-firmware linux-headers grub efibootmgr \
    dhcpcd connman-openrc networkmanager-openrc

read -p "Add CPU microcode? [i]ntel [a]md [n]o → " micro
case "$micro" in
    i|I) basestrap /mnt intel-ucode ;;
    a|A) basestrap /mnt amd-ucode ;;
esac

fstabgen -U /mnt >> /mnt/etc/fstab

# ───────────────────────────────────────────────
#  Phase 3 — chroot & finish install (unchanged except swap is now automatic)
# ───────────────────────────────────────────────
echo "=== Step 3: Entering chroot ==="

artix-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
echo "Inside chroot — continuing..."

# (rest of the chroot script is identical to previous version)
read -p "Hostname → " HOSTNAME
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
passwd

read -p "Your username → " USER
useradd -m -G wheel,video,input,audio,storage "$USER"
passwd "$USER"
echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# GPU
echo "GPU driver?"
select drv in "mesa (intel/amd)" "nvidia" "nvidia-open" "skip"; do
    case $drv in
        "mesa (intel/amd)") pacman -S --noconfirm mesa vulkan-intel vulkan-radeon ;;
        "nvidia")           pacman -S --noconfirm nvidia nvidia-utils ;;
        "nvidia-open")      pacman -S --noconfirm nvidia-open ;;
    esac
    break
done

# Network, Audio, Hyprland, etc. (same as before — abbreviated here for space)
pacman -S --noconfirm networkmanager networkmanager-openrc
rc-update add NetworkManager default
pacman -S --noconfirm pipewire pipewire-openrc pipewire-alsa pipewire-pulse wireplumber wireplumber-openrc
su "$USER" -c "rc-update --user add pipewire default"
su "$USER" -c "rc-update --user add wireplumber default"

pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland waybar hyprpaper hyprlock hypridle mako fuzzel \
    qt5-wayland qt6-wayland polkit-gnome grim slurp wl-clipboard brightnessctl pavucontrol \
    ttf-jetbrains-mono-nerd noto-fonts ttf-font-awesome alacritty thunar firefox blueman bluez bluez-openrc

rc-update add bluetoothd default
rc-update add dbus default

read -p "Install SDDM login manager? (y/N) " sddm
if [[ "$sddm" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm sddm sddm-openrc
    rc-update add sddm default
else
    echo '[[ -z $DISPLAY && $(tty) = /dev/tty1 ]] && exec Hyprland' >> /home/"$USER"/.bash_profile
fi

chown -R "$USER:$USER" /home/"$USER"

echo ""
echo "──────────────────────────────────────────────"
echo "INSTALLATION COMPLETE!"
echo "Type: exit"
echo "Then: umount -R /mnt"
echo "Then: reboot"
echo "──────────────────────────────────────────────"
EOF