#!/bin/bash
#
# Arch Linux Installation Script - Interactive TUI
# Single-file, menu-driven, error-resistant
#
# Usage: ./install.sh [config-file]
#

set -uo pipefail

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

# ============================================================================
# TUI FUNCTIONS (using whiptail)
# ============================================================================

msgbox() {
    whiptail --title "$1" --msgbox "$2" 20 70
}

yesno() {
    whiptail --title "$1" --yesno "$2" 10 60
}

inputbox() {
    local title="$1"
    local prompt="$2"
    local default="$3"
    whiptail --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
}

menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    whiptail --title "$title" --menu "$prompt" 20 70 10 "$@" 3>&1 1>&2 2>&3
}

gauge() {
    whiptail --title "$1" --gauge "$2" 8 70 0
}

# ============================================================================
# CONFIGURATION VARIABLES
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
BOOTLOADER="systemd-boot"
INSTALL_WIFI=true
INSTALL_BASE_DEVEL=true

# Step tracking
STEP_KEYBOARD=0
STEP_NETWORK=0
STEP_PARTITION=0
STEP_BASEINSTALL=0
STEP_CONFIGURE=0
STEP_USERS=0
STEP_PACKAGES=0
STEP_BOOTLOADER=0

# ============================================================================
# LOAD CONFIG FILE (if provided)
# ============================================================================

CONFIG_FILE="${1:-}"
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    msgbox "Config Loaded" "Configuration loaded from:\n$CONFIG_FILE"
fi

# ============================================================================
# ROOT CHECK
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# ============================================================================
# DETECT UEFI/BIOS
# ============================================================================

if [[ -d /sys/firmware/efi/efivars ]]; then
    UEFI_MODE=1
    BOOT_MODE="UEFI"
else
    UEFI_MODE=0
    BOOT_MODE="BIOS"
fi

# ============================================================================
# LOGGING
# ============================================================================

LOG_FILE="install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

# ============================================================================
# STEP FUNCTIONS
# ============================================================================

step_keyboard() {
    while true; do
        KEYMAP=$(inputbox "Keyboard Layout" "Enter keyboard layout (e.g., us, de, fr, es):" "${KEYMAP:-us}")
        
        if [[ -z "$KEYMAP" ]]; then
            msgbox "Error" "Keyboard layout cannot be empty!"
            continue
        fi
        
        if loadkeys "$KEYMAP" 2>/dev/null; then
            STEP_KEYBOARD=1
            msgbox "Success" "Keymap '$KEYMAP' loaded successfully!"
            return 0
        else
            msgbox "Error" "Invalid keymap: $KEYMAP\n\nPlease try again."
        fi
    done
}

step_network() {
    if ping -c 1 -W 2 archlinux.org &>/dev/null; then
        if yesno "Network Status" "Internet connection detected!\n\nConnection is working. Continue?"; then
            timedatectl set-ntp true
            STEP_NETWORK=1
            return 0
        fi
    fi
    
    local choice=$(menu "Network Configuration" "Choose network setup method:" \
        "1" "Ethernet (DHCP)" \
        "2" "WiFi (iwctl)" \
        "3" "Skip (no internet)" \
        "4" "Test connection")
    
    case $choice in
        1)
            local interfaces=$(ip -br link | awk '$1 !~ /^lo/ {print $1}' | grep -v wl)
            local iface_array=()
            while IFS= read -r iface; do
                iface_array+=("$iface" "Ethernet")
            done <<< "$interfaces"
            
            if [[ ${#iface_array[@]} -eq 0 ]]; then
                msgbox "Error" "No ethernet interfaces found!"
                return 1
            fi
            
            local iface=$(menu "Select Interface" "Choose ethernet interface:" "${iface_array[@]}")
            
            if [[ -n "$iface" ]]; then
                ip link set "$iface" up
                dhcpcd "$iface" &
                sleep 3
                
                if ping -c 1 -W 2 archlinux.org &>/dev/null; then
                    timedatectl set-ntp true
                    STEP_NETWORK=1
                    msgbox "Success" "Network configured successfully!"
                    return 0
                else
                    msgbox "Error" "Failed to get internet connection."
                    return 1
                fi
            fi
            ;;
            
        2)
            local wifi_ifaces=$(ip -br link | awk '$1 ~ /^wl/ {print $1}')
            if [[ -z "$wifi_ifaces" ]]; then
                msgbox "Error" "No wireless interfaces found!"
                return 1
            fi
            
            local iface=$(echo "$wifi_ifaces" | head -1)
            ip link set "$iface" up
            sleep 2
            
            iwctl station "$iface" scan
            sleep 3
            
            local networks=$(iwctl station "$iface" get-networks | tail -n +5 | awk '{print $1}' | grep -v "^$")
            local net_array=()
            while IFS= read -r net; do
                [[ -n "$net" ]] && net_array+=("$net" "WiFi")
            done <<< "$networks"
            
            if [[ ${#net_array[@]} -eq 0 ]]; then
                msgbox "Error" "No networks found!"
                return 1
            fi
            
            local ssid=$(menu "Select Network" "Choose WiFi network:" "${net_array[@]}")
            
            if [[ -n "$ssid" ]]; then
                local password=$(inputbox "WiFi Password" "Enter password for '$ssid':" "")
                
                iwctl --passphrase "$password" station "$iface" connect "$ssid" 2>&1 | tee -a "$LOG_FILE"
                sleep 5
                
                if ping -c 1 -W 2 archlinux.org &>/dev/null; then
                    timedatectl set-ntp true
                    STEP_NETWORK=1
                    msgbox "Success" "WiFi connected successfully!"
                    return 0
                else
                    msgbox "Error" "Failed to connect to WiFi."
                    return 1
                fi
            fi
            ;;
            
        3)
            if yesno "Skip Network" "Continue without internet?\n\nSome features may not work."; then
                STEP_NETWORK=1
                return 0
            fi
            return 1
            ;;
            
        4)
            if ping -c 3 archlinux.org; then
                msgbox "Connection Test" "Internet connection is working!"
            else
                msgbox "Connection Test" "No internet connection detected."
            fi
            return 1
            ;;
    esac
}

step_partition() {
    # Show available disks
    local disks=$(lsblk -dno NAME,SIZE,TYPE | grep disk)
    local disk_array=()
    local i=1
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        disk_array+=("/dev/$name" "$size")
        ((i++))
    done <<< "$disks"
    
    TARGET_DISK=$(menu "Select Disk" "WARNING: Selected disk will be WIPED!\n\nChoose installation disk:" "${disk_array[@]}")
    
    if [[ -z "$TARGET_DISK" ]]; then
        msgbox "Error" "No disk selected!"
        return 1
    fi
    
    # Show disk info
    local disk_info=$(lsblk "$TARGET_DISK")
    if ! yesno "Confirm Disk" "Selected disk: $TARGET_DISK\n\n$disk_info\n\nALL DATA WILL BE DESTROYED!\n\nContinue?"; then
        return 1
    fi
    
    # Swap size
    SWAP_SIZE=$(inputbox "Swap Size" "Enter swap size (e.g., 8G, 4G, or 'auto'):" "${SWAP_SIZE:-auto}")
    
    if [[ "$SWAP_SIZE" == "auto" ]]; then
        local ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
        if [ "$ram_mb" -lt 2048 ]; then
            SWAP_SIZE="$((ram_mb * 2))M"
        elif [ "$ram_mb" -lt 8192 ]; then
            SWAP_SIZE="${ram_mb}M"
        else
            SWAP_SIZE="$((ram_mb / 2))M"
        fi
    fi
    
    # Filesystem
    ROOT_FS=$(menu "Filesystem" "Choose root filesystem:" \
        "ext4" "Stable, reliable" \
        "btrfs" "Advanced features" \
        "xfs" "High performance")
    
    # Partition naming
    if [[ "$TARGET_DISK" =~ nvme ]]; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="${TARGET_DISK}"
    fi
    
    # Wipe disk
    (
        echo "0"; echo "# Wiping disk..."
        wipefs -af "$TARGET_DISK" &>/dev/null
        echo "20"; echo "# Clearing partition table..."
        sgdisk --zap-all "$TARGET_DISK" &>/dev/null
        echo "40"; echo "# Creating partitions..."
        
        if [[ "$UEFI_MODE" -eq 1 ]]; then
            sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$TARGET_DISK" &>/dev/null
            sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"SWAP" "$TARGET_DISK" &>/dev/null
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" "$TARGET_DISK" &>/dev/null
            
            EFI_PART="${PART_PREFIX}1"
            SWAP_PART="${PART_PREFIX}2"
            ROOT_PART="${PART_PREFIX}3"
        else
            (
                echo o
                echo n; echo p; echo 1; echo; echo "+${SWAP_SIZE}"
                echo t; echo 82
                echo n; echo p; echo 2; echo; echo
                echo w
            ) | fdisk "$TARGET_DISK" &>/dev/null
            
            SWAP_PART="${PART_PREFIX}1"
            ROOT_PART="${PART_PREFIX}2"
        fi
        
        echo "60"; echo "# Waiting for kernel..."
        sleep 2
        partprobe "$TARGET_DISK"
        sleep 1
        
        echo "70"; echo "# Formatting partitions..."
        
        if [[ "$UEFI_MODE" -eq 1 ]]; then
            mkfs.fat -F32 "$EFI_PART" &>/dev/null
        fi
        
        mkswap "$SWAP_PART" &>/dev/null
        swapon "$SWAP_PART" &>/dev/null
        
        case "$ROOT_FS" in
            ext4) mkfs.ext4 -F "$ROOT_PART" &>/dev/null ;;
            btrfs) mkfs.btrfs -f "$ROOT_PART" &>/dev/null ;;
            xfs) mkfs.xfs -f "$ROOT_PART" &>/dev/null ;;
        esac
        
        echo "90"; echo "# Mounting partitions..."
        mount "$ROOT_PART" /mnt
        
        if [[ "$UEFI_MODE" -eq 1 ]]; then
            mkdir -p /mnt/boot
            mount "$EFI_PART" /mnt/boot
        fi
        
        echo "100"; echo "# Done!"
        sleep 1
    ) | gauge "Partitioning" "Preparing disk..."
    
    STEP_PARTITION=1
    msgbox "Success" "Disk partitioned and mounted successfully!\n\nRoot: $ROOT_PART ($ROOT_FS)\nSwap: $SWAP_PART ($SWAP_SIZE)\n$([ "$UEFI_MODE" -eq 1 ] && echo "EFI: $EFI_PART")"
    return 0
}

step_baseinstall() {
    if ! mountpoint -q /mnt; then
        msgbox "Error" "Root partition not mounted!\n\nPlease complete partitioning first."
        return 1
    fi
    
    local BASE_PKGS="base linux linux-firmware"
    
    if yesno "Base Devel" "Install base-devel group?\n\n(Compilers and build tools - recommended)"; then
        BASE_PKGS="$BASE_PKGS base-devel"
    fi
    
    if yesno "WiFi Support" "Install wireless tools?"; then
        BASE_PKGS="$BASE_PKGS wpa_supplicant wireless_tools iw"
    fi
    
    # Detect CPU
    local cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    case "$cpu_vendor" in
        GenuineIntel)
            BASE_PKGS="$BASE_PKGS intel-ucode"
            ;;
        AuthenticAMD)
            BASE_PKGS="$BASE_PKGS amd-ucode"
            ;;
    esac
    
    msgbox "Installing" "Installing base system...\n\nPackages: $BASE_PKGS\n\nThis may take several minutes.\nCheck the terminal for progress."
    
    if pacstrap /mnt $BASE_PKGS; then
        genfstab -U /mnt >> /mnt/etc/fstab
        STEP_BASEINSTALL=1
        msgbox "Success" "Base system installed successfully!"
        return 0
    else
        msgbox "Error" "Base system installation failed!\n\nCheck the log file:\n$LOG_FILE"
        return 1
    fi
}

step_configure() {
    # Timezone
    TIMEZONE=$(inputbox "Timezone" "Enter timezone (e.g., Europe/Berlin, America/New_York):" "${TIMEZONE:-Europe/Berlin}")
    
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    arch-chroot /mnt hwclock --systohc
    
    # Locale
    LOCALE=$(inputbox "Locale" "Enter locale:" "${LOCALE:-en_US.UTF-8}")
    
    echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen &>/dev/null
    echo "LANG=$LOCALE" > /mnt/etc/locale.conf
    
    # Hostname
    HOSTNAME=$(inputbox "Hostname" "Enter hostname:" "${HOSTNAME:-archlinux}")
    
    echo "$HOSTNAME" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
    
    # Console keymap
    echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
    
    # Pacman config
    sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /mnt/etc/pacman.conf
    
    if yesno "Multilib" "Enable multilib repository?\n\n(32-bit support)"; then
        sed -i '/\[multilib\]/,/Include/s/^#//' /mnt/etc/pacman.conf
    fi
    
    # Initramfs
    arch-chroot /mnt mkinitcpio -P &>/dev/null
    
    STEP_CONFIGURE=1
    msgbox "Success" "System configured!\n\nTimezone: $TIMEZONE\nLocale: $LOCALE\nHostname: $HOSTNAME"
    return 0
}

step_users() {
    # Root password
    while true; do
        local pass1=$(inputbox "Root Password" "Enter root password:" "")
        local pass2=$(inputbox "Root Password" "Confirm root password:" "")
        
        if [[ "$pass1" == "$pass2" ]] && [[ -n "$pass1" ]]; then
            echo "root:${pass1}" | arch-chroot /mnt chpasswd
            break
        else
            msgbox "Error" "Passwords don't match or are empty!\n\nPlease try again."
        fi
    done
    
    # Username
    while true; do
        USERNAME=$(inputbox "Username" "Enter username:" "${USERNAME:-user}")
        
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        else
            msgbox "Error" "Invalid username!\n\nUse lowercase letters, numbers, - and _"
        fi
    done
    
    arch-chroot /mnt useradd -m -G wheel,audio,video,storage,optical,power -s /bin/bash "$USERNAME"
    
    # User password
    while true; do
        local pass1=$(inputbox "User Password" "Enter password for $USERNAME:" "")
        local pass2=$(inputbox "User Password" "Confirm password:" "")
        
        if [[ "$pass1" == "$pass2" ]] && [[ -n "$pass1" ]]; then
            echo "${USERNAME}:${pass1}" | arch-chroot /mnt chpasswd
            break
        else
            msgbox "Error" "Passwords don't match or are empty!\n\nPlease try again."
        fi
    done
    
    # Sudo
    echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
    chmod 440 /mnt/etc/sudoers.d/wheel
    
    STEP_USERS=1
    msgbox "Success" "User created!\n\nUsername: $USERNAME\nGroups: wheel, audio, video, storage, optical, power"
    return 0
}

step_packages() {
    local EXTRA_PKGS="networkmanager vim nano tmux htop git openssh"
    
    if yesno "Additional Packages" "Install additional packages?\n\n$EXTRA_PKGS"; then
        msgbox "Installing" "Installing packages...\n\nCheck terminal for progress."
        
        if arch-chroot /mnt pacman -S --noconfirm $EXTRA_PKGS; then
            arch-chroot /mnt systemctl enable NetworkManager &>/dev/null
            
            if yesno "SSH" "Enable SSH service?"; then
                arch-chroot /mnt systemctl enable sshd &>/dev/null
            fi
            
            msgbox "Success" "Packages installed successfully!"
        else
            msgbox "Warning" "Some packages failed to install.\n\nContinuing anyway..."
        fi
    fi
    
    # User config
    cat >> /mnt/home/$USERNAME/.bashrc <<'EOF'

alias ll='ls -lah'
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias ls='ls --color=auto'
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF
    
    arch-chroot /mnt chown -R $USERNAME:$USERNAME /home/$USERNAME
    arch-chroot /mnt systemctl enable systemd-timesyncd &>/dev/null
    
    STEP_PACKAGES=1
    return 0
}

step_bootloader() {
    if [[ "$UEFI_MODE" -eq 1 ]]; then
        BOOTLOADER=$(menu "Bootloader" "Choose bootloader (UEFI):" \
            "systemd-boot" "Simple, fast" \
            "grub" "Feature-rich")
    else
        BOOTLOADER="grub"
        msgbox "Bootloader" "BIOS mode detected.\n\nUsing GRUB bootloader."
    fi
    
    if [[ "$BOOTLOADER" == "systemd-boot" ]] && [[ "$UEFI_MODE" -eq 1 ]]; then
        arch-chroot /mnt bootctl install &>/dev/null
        
        cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF
        
        local ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        local MICROCODE=""
        
        if arch-chroot /mnt pacman -Q intel-ucode &>/dev/null; then
            MICROCODE="initrd /intel-ucode.img"
        elif arch-chroot /mnt pacman -Q amd-ucode &>/dev/null; then
            MICROCODE="initrd /amd-ucode.img"
        fi
        
        cat > /mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
${MICROCODE}
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw
EOF
        
        cat > /mnt/boot/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
${MICROCODE}
initrd  /initramfs-linux-fallback.img
options root=UUID=${ROOT_UUID} rw
EOF
        
        STEP_BOOTLOADER=1
        msgbox "Success" "systemd-boot installed successfully!"
        
    else
        if [[ "$UEFI_MODE" -eq 1 ]]; then
            arch-chroot /mnt pacman -S --noconfirm grub efibootmgr &>/dev/null
            arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB &>/dev/null
        else
            arch-chroot /mnt pacman -S --noconfirm grub &>/dev/null
            arch-chroot /mnt grub-install --target=i386-pc "$TARGET_DISK" &>/dev/null
        fi
        
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg &>/dev/null
        
        STEP_BOOTLOADER=1
        msgbox "Success" "GRUB installed successfully!"
    fi
    
    return 0
}

# ============================================================================
# MAIN MENU
# ============================================================================

main_menu() {
    while true; do
        local status_text="Installation Progress:\n\n"
        status_text+="[$([ $STEP_KEYBOARD -eq 1 ] && echo "✓" || echo " ")] 1. Keyboard Layout\n"
        status_text+="[$([ $STEP_NETWORK -eq 1 ] && echo "✓" || echo " ")] 2. Network Configuration\n"
        status_text+="[$([ $STEP_PARTITION -eq 1 ] && echo "✓" || echo " ")] 3. Disk Partitioning\n"
        status_text+="[$([ $STEP_BASEINSTALL -eq 1 ] && echo "✓" || echo " ")] 4. Base System Installation\n"
        status_text+="[$([ $STEP_CONFIGURE -eq 1 ] && echo "✓" || echo " ")] 5. System Configuration\n"
        status_text+="[$([ $STEP_USERS -eq 1 ] && echo "✓" || echo " ")] 6. Users & Passwords\n"
        status_text+="[$([ $STEP_PACKAGES -eq 1 ] && echo "✓" || echo " ")] 7. Additional Packages\n"
        status_text+="[$([ $STEP_BOOTLOADER -eq 1 ] && echo "✓" || echo " ")] 8. Bootloader\n"
        
        local choice=$(menu "Arch Installation - $BOOT_MODE Mode" "$status_text\nSelect step:" \
            "1" "Keyboard Layout" \
            "2" "Network Configuration" \
            "3" "Disk Partitioning" \
            "4" "Base System Installation" \
            "5" "System Configuration" \
            "6" "Users & Passwords" \
            "7" "Additional Packages" \
            "8" "Bootloader" \
            "9" "Finish & Reboot" \
            "0" "Exit")
        
        case $choice in
            1) step_keyboard ;;
            2) step_network ;;
            3) step_partition ;;
            4) step_baseinstall ;;
            5) step_configure ;;
            6) step_users ;;
            7) step_packages ;;
            8) step_bootloader ;;
            9)
                if [[ $STEP_BOOTLOADER -eq 1 ]]; then
                    if yesno "Finish Installation" "Installation complete!\n\nUnmount partitions and reboot now?"; then
                        sync
                        umount -R /mnt &>/dev/null
                        swapoff -a &>/dev/null
                        msgbox "Done" "System ready!\n\nRemoving installation media and rebooting in 5 seconds..."
                        sleep 5
                        reboot
                    fi
                else
                    msgbox "Warning" "Not all steps completed!\n\nPlease complete the bootloader step first."
                fi
                ;;
            0)
                if yesno "Exit" "Exit installation?\n\nProgress will be saved."; then
                    exit 0
                fi
                ;;
            *)
                exit 0
                ;;
        esac
    done
}

# ============================================================================
# START
# ============================================================================

clear
msgbox "Arch Linux Installer" "Welcome to the Arch Linux Installation Script!\n\nBoot Mode: $BOOT_MODE\nLog File: $LOG_FILE\n\nPress OK to continue..."

main_menu
