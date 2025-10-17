#!/bin/bash
#
# Arch Linux Installation Script
#
#
# Usage: ./install.sh [config-file]
#

set -euo pipefail

# ============================================================================
# COLORS & UI FUNCTIONS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

step() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}▶ $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}

input_prompt() {
    local prompt="$1"
    local default="$2"
    local result
    
    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " result
        echo "${result:-$default}"
    else
        read -p "$prompt: " result
        echo "$result"
    fi
}

# ============================================================================
# CONFIGURATION VARIABLES (can be overridden by config file)
# ============================================================================

HOSTNAME=""
TIMEZONE=""
LOCALE="en_US.UTF-8"
KEYMAP=""
TARGET_DISK=""
SWAP_SIZE="auto"
ROOT_FS="ext4"
USERNAME=""
USER_PASSWORD=""
ROOT_PASSWORD=""
BOOTLOADER="grub"  # or "systemd-boot"
INSTALL_WIFI=true
INSTALL_BASE_DEVEL=true

# ============================================================================
# LOAD CONFIG FILE (if provided)
# ============================================================================

CONFIG_FILE="${1:-}"

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    info "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
    CONFIG_MODE="auto"
else
    info "No config file provided - interactive mode"
    CONFIG_MODE="interactive"
fi

# ============================================================================
# ROOT CHECK
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# ============================================================================
# DETECT UEFI/BIOS
# ============================================================================

if [[ -d /sys/firmware/efi/efivars ]]; then
    UEFI_MODE=1
    info "UEFI mode detected"
else
    UEFI_MODE=0
    info "BIOS mode detected"
fi

# ============================================================================
# START LOGGING
# ============================================================================

LOG_FILE="install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

info "Installation started at $(date)"
info "Log file: $LOG_FILE"

# ============================================================================
# STEP 1: KEYBOARD LAYOUT
# ============================================================================

step "Step 1: Keyboard Layout"

if [[ -z "$KEYMAP" ]]; then
    echo "Common keymaps: us, de, fr, es, it, uk"
    KEYMAP=$(input_prompt "Enter keyboard layout" "us")
fi

info "Loading keymap: $KEYMAP"
loadkeys "$KEYMAP"
success "Keymap loaded"

# ============================================================================
# STEP 2: NETWORK CONFIGURATION
# ============================================================================

step "Step 2: Network Configuration"

info "Testing internet connection..."
if ping -c 1 -W 2 archlinux.org &>/dev/null; then
    success "Internet connection available"
else
    warning "No internet connection detected"
    
    if confirm "Configure network now?"; then
        echo ""
        echo "Network options:"
        echo "  1) Ethernet (DHCP)"
        echo "  2) WiFi"
        read -p "Select option: " net_choice
        
        case $net_choice in
            1)
                info "Available interfaces:"
                ip link show | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://'
                
                iface=$(input_prompt "Enter interface name" "")
                info "Configuring $iface with DHCP..."
                ip link set "$iface" up
                dhcpcd "$iface"
                sleep 3
                ;;
            2)
                info "Available wireless interfaces:"
                iw dev | grep Interface | awk '{print $2}'
                
                iface=$(input_prompt "Enter wireless interface" "wlan0")
                ip link set "$iface" up
                
                info "Scanning networks..."
                iwctl station "$iface" scan
                sleep 2
                iwctl station "$iface" get-networks
                
                ssid=$(input_prompt "Enter SSID" "")
                read -sp "Enter password: " password
                echo ""
                
                info "Connecting to $ssid..."
                iwctl --passphrase "$password" station "$iface" connect "$ssid"
                sleep 5
                ;;
        esac
        
        if ping -c 1 -W 2 archlinux.org &>/dev/null; then
            success "Internet connected"
        else
            error "Still no internet - continuing anyway"
        fi
    fi
fi

# Sync time
info "Synchronizing system clock..."
timedatectl set-ntp true
success "System clock synchronized"

# ============================================================================
# STEP 3: DISK PARTITIONING
# ============================================================================

step "Step 3: Disk Partitioning"

info "Available disks:"
lsblk -dno NAME,SIZE,TYPE | grep disk | nl -w2 -s") "
echo ""

if [[ -z "$TARGET_DISK" ]]; then
    read -p "Enter disk number or path (e.g., /dev/sda): " disk_input
    
    if [[ "$disk_input" =~ ^[0-9]+$ ]]; then
        TARGET_DISK="/dev/$(lsblk -dno NAME | grep -v loop | sed -n "${disk_input}p")"
    else
        TARGET_DISK="$disk_input"
    fi
fi

info "Selected disk: $TARGET_DISK"
echo ""
lsblk "$TARGET_DISK"
echo ""

warning "ALL DATA ON $TARGET_DISK WILL BE DESTROYED!"
if ! confirm "Continue with partitioning?"; then
    error "Installation aborted"
    exit 1
fi

# Determine partition naming
if [[ "$TARGET_DISK" =~ nvme ]]; then
    PART_PREFIX="${TARGET_DISK}p"
else
    PART_PREFIX="${TARGET_DISK}"
fi

# Calculate swap size
if [[ "$SWAP_SIZE" == "auto" ]]; then
    ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if [ "$ram_mb" -lt 2048 ]; then
        SWAP_SIZE="$((ram_mb * 2))M"
    elif [ "$ram_mb" -lt 8192 ]; then
        SWAP_SIZE="${ram_mb}M"
    else
        SWAP_SIZE="$((ram_mb / 2))M"
    fi
    info "Calculated swap size: $SWAP_SIZE"
fi

# Wipe disk
info "Wiping disk signatures..."
wipefs -af "$TARGET_DISK"
sgdisk --zap-all "$TARGET_DISK"
success "Disk wiped"

# Partition based on UEFI or BIOS
if [[ "$UEFI_MODE" -eq 1 ]]; then
    info "Creating GPT partitions (UEFI)..."
    
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
    sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"SWAP" "$TARGET_DISK"
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" "$TARGET_DISK"
    
    EFI_PART="${PART_PREFIX}1"
    SWAP_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
    
    success "GPT partitions created"
else
    info "Creating MBR partitions (BIOS)..."
    
    (
        echo o
        echo n; echo p; echo 1; echo; echo "+${SWAP_SIZE}"
        echo t; echo 82
        echo n; echo p; echo 2; echo; echo
        echo w
    ) | fdisk "$TARGET_DISK"
    
    SWAP_PART="${PART_PREFIX}1"
    ROOT_PART="${PART_PREFIX}2"
    
    success "MBR partitions created"
fi

# Wait for kernel to recognize partitions
sleep 2
partprobe "$TARGET_DISK"
sleep 1

# Format partitions
info "Formatting partitions..."

if [[ "$UEFI_MODE" -eq 1 ]]; then
    mkfs.fat -F32 "$EFI_PART"
    success "EFI partition formatted"
fi

mkswap "$SWAP_PART"
swapon "$SWAP_PART"
success "Swap partition formatted and enabled"

case "$ROOT_FS" in
    ext4)
        mkfs.ext4 -F "$ROOT_PART"
        ;;
    btrfs)
        mkfs.btrfs -f "$ROOT_PART"
        ;;
    xfs)
        mkfs.xfs -f "$ROOT_PART"
        ;;
esac
success "Root partition formatted ($ROOT_FS)"

# Mount partitions
info "Mounting partitions..."
mount "$ROOT_PART" /mnt

if [[ "$UEFI_MODE" -eq 1 ]]; then
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
fi

success "Partitions mounted"

# ============================================================================
# STEP 4: INSTALL BASE SYSTEM
# ============================================================================

step "Step 4: Installing Base System"

BASE_PKGS="base linux linux-firmware"

if [[ "$INSTALL_BASE_DEVEL" == true ]]; then
    BASE_PKGS="$BASE_PKGS base-devel"
fi

if [[ "$INSTALL_WIFI" == true ]]; then
    BASE_PKGS="$BASE_PKGS wpa_supplicant wireless_tools iw"
fi

# Detect CPU and add microcode
cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
case "$cpu_vendor" in
    GenuineIntel)
        BASE_PKGS="$BASE_PKGS intel-ucode"
        info "Intel CPU detected - adding intel-ucode"
        ;;
    AuthenticAMD)
        BASE_PKGS="$BASE_PKGS amd-ucode"
        info "AMD CPU detected - adding amd-ucode"
        ;;
esac

info "Installing base system packages..."
info "Packages: $BASE_PKGS"
pacstrap /mnt $BASE_PKGS

success "Base system installed"

# Generate fstab
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
success "fstab generated"

# ============================================================================
# STEP 5: SYSTEM CONFIGURATION
# ============================================================================

step "Step 5: System Configuration"

# Get configuration values if not set
if [[ -z "$TIMEZONE" ]]; then
    echo "Example: Europe/Berlin, America/New_York, Asia/Tokyo"
    TIMEZONE=$(input_prompt "Enter timezone" "Europe/Berlin")
fi

if [[ -z "$LOCALE" ]]; then
    LOCALE=$(input_prompt "Enter locale" "en_US.UTF-8")
fi

if [[ -z "$HOSTNAME" ]]; then
    HOSTNAME=$(input_prompt "Enter hostname" "archlinux")
fi

# Configure timezone
info "Setting timezone to $TIMEZONE..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
arch-chroot /mnt hwclock --systohc
success "Timezone configured"

# Configure locale
info "Configuring locale ($LOCALE)..."
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
success "Locale configured"

# Set console keymap
info "Setting console keymap..."
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
success "Console keymap set"

# Set hostname
info "Setting hostname to $HOSTNAME..."
echo "$HOSTNAME" > /mnt/etc/hostname

cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
success "Hostname configured"

# Configure pacman
info "Configuring pacman..."
sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /mnt/etc/pacman.conf

if confirm "Enable multilib repository (32-bit support)?"; then
    sed -i '/\[multilib\]/,/Include/s/^#//' /mnt/etc/pacman.conf
    success "Multilib enabled"
fi

# Generate initramfs
info "Generating initramfs..."
arch-chroot /mnt mkinitcpio -P
success "Initramfs generated"

# ============================================================================
# STEP 6: USERS & PASSWORDS
# ============================================================================

step "Step 6: Users and Passwords"

# Root password
info "Setting root password..."
if [[ -n "$ROOT_PASSWORD" ]]; then
    echo "root:${ROOT_PASSWORD}" | arch-chroot /mnt chpasswd
    success "Root password set from config"
else
    arch-chroot /mnt passwd root
    success "Root password set"
fi

# Create user
if [[ -z "$USERNAME" ]]; then
    USERNAME=$(input_prompt "Enter username" "")
fi

info "Creating user: $USERNAME..."
arch-chroot /mnt useradd -m -G wheel,audio,video,storage,optical,power -s /bin/bash "$USERNAME"

if [[ -n "$USER_PASSWORD" ]]; then
    echo "${USERNAME}:${USER_PASSWORD}" | arch-chroot /mnt chpasswd
    success "User password set from config"
else
    info "Setting password for $USERNAME..."
    arch-chroot /mnt passwd "$USERNAME"
    success "User password set"
fi

# Configure sudo
info "Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
chmod 440 /mnt/etc/sudoers.d/wheel
success "Sudo configured for wheel group"

# ============================================================================
# STEP 7: INSTALL ADDITIONAL PACKAGES
# ============================================================================

step "Step 7: Additional Packages"

EXTRA_PKGS="networkmanager vim nano tmux htop git openssh"

if confirm "Install additional packages? ($EXTRA_PKGS)"; then
    info "Installing packages..."
    arch-chroot /mnt pacman -S --noconfirm $EXTRA_PKGS
    success "Additional packages installed"
fi

# Enable NetworkManager
if arch-chroot /mnt pacman -Q networkmanager &>/dev/null; then
    info "Enabling NetworkManager..."
    arch-chroot /mnt systemctl enable NetworkManager
    success "NetworkManager enabled"
fi

# Enable SSH (if installed)
if arch-chroot /mnt pacman -Q openssh &>/dev/null; then
    if confirm "Enable SSH service?"; then
        arch-chroot /mnt systemctl enable sshd
        success "SSH enabled"
    fi
fi

# ============================================================================
# STEP 8: BOOTLOADER
# ============================================================================

step "Step 8: Bootloader Installation"

if [[ "$BOOTLOADER" == "systemd-boot" ]] && [[ "$UEFI_MODE" -eq 1 ]]; then
    info "Installing systemd-boot..."
    
    arch-chroot /mnt bootctl install
    
    # Create loader config
    cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF
    
    # Get root UUID
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    
    # Detect microcode
    MICROCODE=""
    if arch-chroot /mnt pacman -Q intel-ucode &>/dev/null; then
        MICROCODE="initrd /intel-ucode.img"
    elif arch-chroot /mnt pacman -Q amd-ucode &>/dev/null; then
        MICROCODE="initrd /amd-ucode.img"
    fi
    
    # Create boot entry
    cat > /mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
${MICROCODE}
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw
EOF
    
    # Create fallback entry
    cat > /mnt/boot/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
${MICROCODE}
initrd  /initramfs-linux-fallback.img
options root=UUID=${ROOT_UUID} rw
EOF
    
    success "systemd-boot installed"
    
elif [[ "$BOOTLOADER" == "grub" ]] || [[ "$UEFI_MODE" -eq 0 ]]; then
    info "Installing GRUB..."
    
    if [[ "$UEFI_MODE" -eq 1 ]]; then
        arch-chroot /mnt pacman -S --noconfirm grub efibootmgr
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    else
        arch-chroot /mnt pacman -S --noconfirm grub
        arch-chroot /mnt grub-install --target=i386-pc "$TARGET_DISK"
    fi
    
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    success "GRUB installed"
fi

# ============================================================================
# STEP 9: FINAL CONFIGURATION
# ============================================================================

step "Step 9: Final Configuration"

# Create basic user config files
info "Creating user configuration files..."

cat >> /mnt/home/$USERNAME/.bashrc <<'EOF'

# Custom aliases
alias ll='ls -lah'
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias search='pacman -Ss'

# Colored ls
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Better prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF

arch-chroot /mnt chown -R $USERNAME:$USERNAME /home/$USERNAME
success "User configuration created"

# Enable time sync
info "Enabling time synchronization..."
arch-chroot /mnt systemctl enable systemd-timesyncd
success "Time sync enabled"

# ============================================================================
# INSTALLATION COMPLETE
# ============================================================================

step "Installation Complete!"

echo ""
echo "┌────────────────────────────────────────────────────────┐"
echo "│                                                        │"
echo "│  ✓ System installed successfully                      │"
echo "│                                                        │"
echo "│  Next steps:                                          │"
echo "│    1. Exit this script                                │"
echo "│    2. Unmount: umount -R /mnt                         │"
echo "│    3. Reboot: reboot                                  │"
echo "│    4. Remove installation media                       │"
echo "│    5. Login as: $USERNAME                             │"
echo "│                                                        │"
echo "│  Installation log: $LOG_FILE                          │"
echo "│                                                        │"
echo "└────────────────────────────────────────────────────────┘"
echo ""

if confirm "Unmount and reboot now?"; then
    info "Syncing filesystems..."
    sync
    
    info "Unmounting partitions..."
    umount -R /mnt
    swapoff -a
    
    success "System ready to reboot"
    echo ""
    info "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi

info "Installation finished. Manual reboot required."
