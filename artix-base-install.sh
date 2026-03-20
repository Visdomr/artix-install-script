#!/usr/bin/env bash
set -euo pipefail

echo "=== Artix OpenRC → Hyprland Full Install Script ==="
echo "Run this as root from the LIVE base-openrc ISO"
echo ""

# ───────────────────────────────────────────────
#  Phase 0 — Networking (most important part!)
# ───────────────────────────────────────────────
echo "=== Step 0: Networking ==="
echo "List of network interfaces:"
ip -c link show

echo ""
read -p "Enter wired interface name (e.g. enp3s0, eth0) or leave empty for Wi-Fi → " WIRED_IFACE

if [[ -n "$WIRED_IFACE" ]]; then
    echo "Starting DHCP on $WIRED_IFACE ..."
    dhcpcd "$WIRED_IFACE" || true
else
    echo "Wi-Fi mode selected"
    read -p "Enter wireless interface name (usually wlan0) → " WLAN_IFACE
    : "${WLAN_IFACE:=wlan0}"

    rfkill unblock wifi || true
    ip link set "$WLAN_IFACE" up || true

    echo "Scanning Wi-Fi networks..."
    connmanctl enable wifi 2>/dev/null || true
    connmanctl scan wifi

    echo ""
    connmanctl services
    echo ""
    read -p "Copy-paste the FULL service name of your network (wifi_xxxx...) → " SERVICE

    connmanctl agent on
    connmanctl connect "$SERVICE"
fi

echo -n "Testing internet... "
if ping -c 1 -W 4 8.8.8.8 &>/dev/null; then
    echo "OK"
else
    echo "FAILED — please fix networking manually and re-run script"
    exit 1
fi

pacman -Syy
echo ""

# ───────────────────────────────────────────────
#  Phase 1 — Partitioning & mounting (interactive)
# ───────────────────────────────────────────────
echo "=== Step 1: Partition your disk ==="
echo "Use cfdisk, fdisk, gdisk, etc."
echo "Example layout (UEFI):"
echo "  /dev/nvme0n1p1  512M  EFI system (type EF00)"
echo "  /dev/nvme0n1p2  rest  Linux filesystem"
echo ""
read -p "Which disk are you installing to? (e.g. /dev/nvme0n1) → " DISK
cfdisk "$DISK"   # or fdisk/gdisk — do your partitions now

echo ""
lsblk -f
echo ""
read -p "EFI partition (fat32)  → " EFI_PART
read -p "Root partition (ext4) → " ROOT_PART

mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F -L ROOT "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ───────────────────────────────────────────────
#  Phase 2 — basestrap base system
# ───────────────────────────────────────────────
echo "=== Step 2: Installing base system (OpenRC) ==="

basestrap /mnt base base-devel openrc elogind-openrc \
    linux linux-firmware linux-headers grub efibootmgr \
    dhcpcd connman-openrc networkmanager-openrc

# Optional: add microcode
read -p "Add CPU microcode? [i]intel [a]amd [n]o → " micro
case "$micro" in
    i|I) basestrap /mnt intel-ucode ;;
    a|A) basestrap /mnt amd-ucode ;;
esac

fstabgen -U /mnt >> /mnt/etc/fstab

# ───────────────────────────────────────────────
#  Phase 3 — chroot & run the rest inside
# ───────────────────────────────────────────────
echo "=== Step 3: Entering chroot ==="

artix-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

echo "Inside chroot — continuing installation..."

# Basic config
read -p "Hostname → " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Locale & time
ln -sf /usr/share/zoneinfo/$(tzselect) /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Root password
echo "Set root password"
passwd

# User
read -p "Your username → " USER
useradd -m -G wheel,video,input,audio,storage "$USER"
echo "Set password for $USER"
passwd "$USER"

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

# Bootloader (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# ── GPU ────────────────────────────────────────
echo "GPU driver?"
select drv in "mesa (intel/amd)" "nvidia" "nvidia-open" "skip"; do
    case $drv in
        "mesa (intel/amd)") pacman -S --noconfirm mesa vulkan-intel vulkan-radeon ;;
        "nvidia")           pacman -S --noconfirm nvidia nvidia-utils ;;
        "nvidia-open")      pacman -S --noconfirm nvidia-open ;;
        *) break ;;
    esac
    break
done

# ── Network in installed system ────────────────
pacman -S --noconfirm networkmanager networkmanager-openrc
rc-update add NetworkManager default

# ── Audio (PipeWire) ───────────────────────────
pacman -S --noconfirm pipewire pipewire-openrc pipewire-alsa pipewire-pulse wireplumber wireplumber-openrc
su "$USER" -c "rc-update --user add pipewire default"
su "$USER" -c "rc-update --user add wireplumber default"

# ── Hyprland & basics ──────────────────────────
pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland \
    waybar hyprpaper hyprlock hypridle mako fuzzel \
    qt5-wayland qt6-wayland polkit-gnome \
    grim slurp wl-clipboard brightnessctl pavucontrol \
    ttf-jetbrains-mono-nerd noto-fonts ttf-font-awesome \
    alacritty thunar firefox blueman bluez bluez-openrc

rc-update add bluetoothd default
rc-update add dbus default

# Optional SDDM
read -p "Install SDDM login manager? (y/N) " sddm
if [[ "$sddm" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm sddm sddm-openrc
    rc-update add sddm default
else
    # Auto-start Hyprland from tty1
    echo '[[ -z $DISPLAY && $(tty) = /dev/tty1 ]] && exec Hyprland' >> /home/"$USER"/.bash_profile
fi

chown -R "$USER:$USER" /home/"$USER"

echo ""
echo "──────────────────────────────────────────────"
echo "Installation finished!"
echo "Commands to exit & reboot:"
echo "  exit                  # leave chroot"
echo "  umount -R /mnt"
echo "  reboot"
echo "──────────────────────────────────────────────"

EOF
