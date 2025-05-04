#!/usr/bin/env bash

# Copyright (c) 2025 matthewjohns0n
# Author: Matt Johnson (matthewjohns0n)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

function header_info {
  cat <<"EOF"
                    _    _                       ____  _____
                   | |  | |                     / __ \/ ____|
                   | |  | | ___ _ __  _   _ ___| |  | | (___
                   | |  | |/ _ \ '_ \| | | / __| |  | |\___ \
                   | |__| |  __/ | | | |_| \__ \ |__| |____) |
                    \____/ \___|_| |_|\__,_|___/\____/|_____/
                           Victron Energy Venus OS

EOF
}
clear
header_info
echo -e "Loading..."
#API VARIABLES
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="venusos-vm"
var_os="venusos"
var_version=" "
DISK_SIZE="32G"
#
GEN_MAC=$(echo '00 60 2f'$(od -An -N3 -t xC /dev/urandom) | sed -e 's/ /:/g' | tr '[:lower:]' '[:upper:]')
USEDID=$(pvesh get /cluster/resources --type vm --output-format yaml | egrep -i 'vmid' | awk '{print substr($2, 1, length($2)-0) }')
NEXTID=$(pvesh get /cluster/nextid)
VENUS_VERSION="v3.40~11"
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "INTERRUPTED"' SIGINT
trap 'post_update_to_api "failed" "TERMINATED"' SIGTERM
function error_exit() {
  trap - ERR
  local reason="Unknown failure occurred."
  local msg="${1:-$reason}"
  local flag="${RD}‼ ERROR ${CL}$EXIT@$LINE"
  post_update_to_api "failed" "unknown"
  echo -e "$flag $msg" 1>&2
  [ ! -z ${VMID-} ] && cleanup_vmid
  exit $EXIT
}
function cleanup_vmid() {
  if $(qm status $VMID &>/dev/null); then
    if [ "$(qm status $VMID | awk '{print $2}')" == "running" ]; then
      qm stop $VMID
    fi
    qm destroy $VMID
  fi
}
function cleanup() {
  popd >/dev/null

  # Move important files to a persistent directory if they exist
  IMAGE_DIR="/var/lib/vz/template/iso/venus"
  mkdir -p $IMAGE_DIR

  if [ -f "$TEMP_DIR/$FILE" ]; then
    msg_info "Saving compressed image to $IMAGE_DIR"
    cp "$TEMP_DIR/$FILE" "$IMAGE_DIR/"
    msg_ok "Saved compressed image to $IMAGE_DIR/$FILE"
  fi

  if [ -f "$TEMP_DIR/$EXTRACTED_FILE" ]; then
    msg_info "Saving extracted image to $IMAGE_DIR"
    cp "$TEMP_DIR/$EXTRACTED_FILE" "$IMAGE_DIR/"
    msg_ok "Saved extracted image to $IMAGE_DIR/$EXTRACTED_FILE"
  fi

  if [ -f "$TEMP_DIR/$QCOW2_FILE" ]; then
    msg_info "Saving qcow2 image to $IMAGE_DIR"
    cp "$TEMP_DIR/$QCOW2_FILE" "$IMAGE_DIR/"
    msg_ok "Saved qcow2 image to $IMAGE_DIR/$QCOW2_FILE"
  fi

  # Remove temporary directory
  rm -rf $TEMP_DIR
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
if ! command -v whiptail &>/dev/null; then
  echo "Installing whiptail..."
  apt-get update &>/dev/null
  apt-get install -y whiptail &>/dev/null
fi
if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "VenusOS VM" --yesno "This will create a New VenusOS VM. Proceed?" 10 58); then
  echo "User selected Yes"
else
  clear
  echo -e "⚠ User exited script \n"
  exit
fi

function check_arm_support() {
  # Check if necessary firmware package is installed
  if ! dpkg -l | grep -q pve-edk2-firmware-aarch64; then
    echo -e "${RD}⚠️  Missing ARM64 firmware package for QEMU${CL}"
    echo -e "${YW}Installing required package: pve-edk2-firmware-aarch64${CL}"
    if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ARM Firmware Missing" --yesno "ARM emulation requires the pve-edk2-firmware-aarch64 package.\nInstall it now?" 10 58); then
      apt-get update
      apt-get install -y pve-edk2-firmware-aarch64
      if [ $? -ne 0 ]; then
        echo -e "${RD}Failed to install ARM firmware. You may need to add testing repository:${CL}"
        echo -e "${YW}echo 'deb http://download.proxmox.com/debian/pve bookworm pvetest' >> /etc/apt/sources.list${CL}"
        echo -e "${YW}apt-get update${CL}"
        if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "Add Testing Repo?" --yesno "Add Proxmox testing repository to install ARM firmware?" 10 58); then
          echo 'deb http://download.proxmox.com/debian/pve bookworm pvetest' >> /etc/apt/sources.list
          apt-get update
          apt-get install -y pve-edk2-firmware-aarch64
          if [ $? -ne 0 ]; then
            echo -e "${RD}Failed to install ARM firmware. Exiting.${CL}"
            exit 1
          fi
        else
          echo -e "${RD}Cannot continue without ARM firmware support. Exiting.${CL}"
          exit 1
        fi
      fi
    else
      echo -e "${RD}Cannot continue without ARM firmware support. Exiting.${CL}"
      exit 1
    fi
  fi
}

function ARCH_CHECK() {
  ARCH=$(dpkg --print-architecture)
  if [[ "$ARCH" == "amd64" ]]; then
    echo -e "\n${YW}Running on AMD64/x86_64 hardware - will emulate ARM architecture for Raspberry Pi image.${CL}\n"
    check_arm_support
  else
    echo -e "\n${GN}Running on $ARCH hardware${CL}\n"
  fi
}

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}
function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}
function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function default_settings() {
  METHOD="default"
  echo -e "${DGN}Using VenusOS Version: ${BGN}${VENUS_VERSION}${CL}"
  echo -e "${DGN}Using Virtual Machine ID: ${BGN}$NEXTID${CL}"
  VMID=$NEXTID
  echo -e "${DGN}Using Hostname: ${BGN}venusos${CL}"
  HN=venusos
  echo -e "${DGN}Allocated Cores: ${BGN}2${CL}"
  CORE_COUNT="2"
  echo -e "${DGN}Allocated RAM: ${BGN}2048${CL}"
  RAM_SIZE="2048"
  echo -e "${DGN}Using Bridge: ${BGN}vmbr0${CL}"
  BRG="vmbr0"
  echo -e "${DGN}Using MAC Address: ${BGN}$GEN_MAC${CL}"
  MAC=$GEN_MAC
  echo -e "${DGN}Using VLAN: ${BGN}Default${CL}"
  VLAN=""
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  MTU=""
  echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
  START_VM="yes"
  echo -e "${BL}Creating a VenusOS VM using the above default settings${CL}"
}
function advanced_settings() {
  METHOD="advanced"
  VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $NEXTID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ -z $VMID ]; then
    VMID="$NEXTID"
    echo -e "${DGN}Virtual Machine: ${BGN}$VMID${CL}"
  else
    if echo "$USEDID" | egrep -q "$VMID"; then
      echo -e "\n🚨  ${RD}ID $VMID is already in use${CL} \n"
      echo -e "Exiting Script \n"
      sleep 2
      exit
    else
      if [ $exitstatus = 0 ]; then echo -e "${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"; fi
    fi
  fi
  VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 venusos --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ -z $VM_NAME ]; then
    HN="venusos"
    echo -e "${DGN}Using Hostname: ${BGN}$HN${CL}"
  else
    if [ $exitstatus = 0 ]; then
      HN=$(echo ${VM_NAME,,} | tr -d ' ')
      echo -e "${DGN}Using Hostname: ${BGN}$HN${CL}"
    fi
  fi
  CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 2 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ -z $CORE_COUNT ]; then
    CORE_COUNT="2"
    echo -e "${DGN}Allocated Cores: ${BGN}$CORE_COUNT${CL}"
  else
    if [ $exitstatus = 0 ]; then echo -e "${DGN}Allocated Cores: ${BGN}$CORE_COUNT${CL}"; fi
  fi
  RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 2048 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ -z $RAM_SIZE ]; then
    RAM_SIZE="2048"
    echo -e "${DGN}Allocated RAM: ${BGN}$RAM_SIZE${CL}"
  else
    if [ $exitstatus = 0 ]; then echo -e "${DGN}Allocated RAM: ${BGN}$RAM_SIZE${CL}"; fi
  fi
  BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ -z $BRG ]; then
    BRG="vmbr0"
    echo -e "${DGN}Using Bridge: ${BGN}$BRG${CL}"
  else
    if [ $exitstatus = 0 ]; then echo -e "${DGN}Using Bridge: ${BGN}$BRG${CL}"; fi
  fi
  MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 $GEN_MAC --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ -z $MAC1 ]; then
    MAC="$GEN_MAC"
    echo -e "${DGN}Using MAC Address: ${BGN}$MAC${CL}"
  else
    if [ $exitstatus = 0 ]; then
      MAC="$MAC1"
      echo -e "${DGN}Using MAC Address: ${BGN}$MAC1${CL}"
    fi
  fi
  VLAN1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Vlan(leave blank for default)" 8 58 --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ $exitstatus = 0 ]; then
    if [ -z $VLAN1 ]; then
      VLAN1="Default" VLAN=""
      echo -e "${DGN}Using Vlan: ${BGN}$VLAN1${CL}"
    else
      VLAN=",tag=$VLAN1"
      echo -e "${DGN}Using Vlan: ${BGN}$VLAN1${CL}"
    fi
  fi
  MTU1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Interface MTU Size (leave blank for default)" 8 58 --title "MTU SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ $exitstatus = 0 ]; then
    if [ -z $MTU1 ]; then
      MTU1="Default" MTU=""
      echo -e "${DGN}Using Interface MTU Size: ${BGN}$MTU1${CL}"
    else
      MTU=",mtu=$MTU1"
      echo -e "${DGN}Using Interface MTU Size: ${BGN}$MTU1${CL}"
    fi
  fi
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 58); then
    echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
    START_VM="yes"
  else
    echo -e "${DGN}Start VM when completed: ${BGN}no${CL}"
    START_VM="no"
  fi
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create VenusOS VM?" --no-button Do-Over 10 58); then
    echo -e "${RD}Creating a VenusOS VM using the above advanced settings${CL}"
  else
    clear
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}
function START_SCRIPT() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    clear
    header_info
    echo -e "${BL}Using Default Settings${CL}"
    default_settings
  else
    clear
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}
ARCH_CHECK
START_SCRIPT
post_to_api_vm

# Set default URL (ARM image)
URL=https://updates.victronenergy.com/feeds/venus/release/images/raspberrypi4/venus-image-large-raspberrypi4.wic.gz

# Define image directory
IMAGE_DIR="/var/lib/vz/template/iso/venus"
mkdir -p $IMAGE_DIR

while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
if [ $((${#STORAGE_MENU[@]} / 3)) -eq 0 ]; then
  echo -e "'Disk image' needs to be selected for at least one storage location."
  die "Unable to detect valid storage location."
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for the VenusOS VM?\n\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."
msg_info "Getting URL for VenusOS Disk Image"
sleep 2
msg_ok "${CL}${BL}${URL}${CL}"

# Check if the file already exists locally
FILE=$(basename $URL)
EXTRACTED_FILE="${FILE%.gz}"
QCOW2_FILE="venus-image-raspberrypi4.qcow2"

# Check in the current directory and persistent directory
if [ -f "$FILE" ]; then
  msg_ok "Found existing download ${CL}${BL}$FILE${CL}"
elif [ -f "$EXTRACTED_FILE" ]; then
  msg_ok "Found existing extracted image ${CL}${BL}$EXTRACTED_FILE${CL}"
elif [ -f "$QCOW2_FILE" ]; then
  msg_ok "Found existing converted image ${CL}${BL}$QCOW2_FILE${CL}"
elif [ -f "$IMAGE_DIR/$FILE" ]; then
  msg_ok "Found existing download in $IMAGE_DIR"
  cp "$IMAGE_DIR/$FILE" .
elif [ -f "$IMAGE_DIR/$EXTRACTED_FILE" ]; then
  msg_ok "Found existing extracted image in $IMAGE_DIR"
  cp "$IMAGE_DIR/$EXTRACTED_FILE" .
elif [ -f "$IMAGE_DIR/$QCOW2_FILE" ]; then
  msg_ok "Found existing converted image in $IMAGE_DIR"
  cp "$IMAGE_DIR/$QCOW2_FILE" .
else
  msg_info "Downloading VenusOS image"
  curl -f#SL -o "$FILE" "$URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${CL}${BL}$FILE${CL}"
fi

# Extract the image if needed
if [ -f "$FILE" ] && [ ! -f "$EXTRACTED_FILE" ] && [ ! -f "$QCOW2_FILE" ]; then
  msg_info "Extracting Disk Image"
  gunzip "$FILE"
  msg_ok "Extracted Disk Image"
fi

# Convert to qcow2 if needed
if [ -f "$EXTRACTED_FILE" ] && [ ! -f "$QCOW2_FILE" ]; then
  msg_info "Converting disk format to qcow2"
  qemu-img convert -f raw -O qcow2 "$EXTRACTED_FILE" "$QCOW2_FILE"
  msg_ok "Converted disk to qcow2 format"
elif [ ! -f "$QCOW2_FILE" ]; then
  msg_error "Required disk image not found. Exiting."
  exit 1
fi

STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs | dir)
  DISK_EXT=".qcow2"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format qcow2"
  ;;
esac

# Simplify to single disk setup
DISK0=vm-${VMID}-disk-0${DISK_EXT:-}
DISK0_REF=${STORAGE}:${DISK_REF:-}${DISK0}

# Create EFI Disk
EFI_DISK=vm-${VMID}-disk-1${DISK_EXT:-}
EFI_DISK_REF=${STORAGE}:${DISK_REF:-}${EFI_DISK}

msg_info "Creating VenusOS VM with ARM emulation (non-UEFI)"
qm create $VMID -cores $CORE_COUNT -memory $RAM_SIZE -name $HN \
  -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

# Allocate main disk for the VM
pvesm alloc $STORAGE $VMID $DISK0 $DISK_SIZE 1>&/dev/null

# Import the disk image
qm importdisk $VMID "$QCOW2_FILE" $STORAGE ${DISK_IMPORT:-} 1>&/dev/null

# Add the disk to the VM
qm set $VMID -scsi0 ${DISK0_REF},size=$DISK_SIZE >/dev/null

# Set machine to virt with specific ARM-compatible options
qm set $VMID -machine virt,gic-version=3 >/dev/null

# Set architecture to aarch64
qm set $VMID -arch aarch64 >/dev/null

# Set CPU to cortex-a72 (RPi4 CPU)
qm set $VMID -cpu cortex-a72 >/dev/null

# Configure serial console for output
qm set $VMID -serial0 socket >/dev/null
qm set $VMID -vga serial0 >/dev/null

msg_ok "Created VenusOS VM ${CL}${BL}(${HN})"

# Manually edit config file for proper ARM emulation
VM_CONFIG="/etc/pve/qemu-server/${VMID}.conf"
if [ -f "$VM_CONFIG" ]; then
  msg_info "Configuring VM for ARM emulation (non-UEFI mode)"

  # Comment out vmgenid if exists
  if grep -q "^vmgenid:" "$VM_CONFIG"; then
    sed -i 's/^vmgenid:/#vmgenid:/g' "$VM_CONFIG"
  fi

  # Remove any bios line if exists
  if grep -q "^bios:" "$VM_CONFIG"; then
    sed -i '/^bios:/d' "$VM_CONFIG"
  fi

  # Remove any boot order
  if grep -q "^boot:" "$VM_CONFIG"; then
    sed -i '/^boot:/d' "$VM_CONFIG"
  fi

  # Remove any efidisk if exists
  if grep -q "^efidisk0:" "$VM_CONFIG"; then
    sed -i '/^efidisk0:/d' "$VM_CONFIG"
  fi

  # Remove cpu line if exists
  if grep -q "^cpu:" "$VM_CONFIG"; then
    sed -i '/^cpu:/d' "$VM_CONFIG"
  fi

  # Ensure arch line exists
  if ! grep -q "^arch:" "$VM_CONFIG"; then
    echo "arch: aarch64" >> "$VM_CONFIG"
  fi

  # Remove any pflash or args settings
  if grep -q "^args:" "$VM_CONFIG"; then
    sed -i '/^args:/d' "$VM_CONFIG"
  fi

  # Add kernel boot parameters to directly boot the disk
  echo "bootdisk: scsi0" >> "$VM_CONFIG"

  msg_ok "VM configuration adjusted for ARM emulation"
fi

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting VenusOS VM"
  qm start $VMID
  msg_ok "Started VenusOS VM"
fi
post_update_to_api "done" "none"
msg_ok "Completed Successfully!\n"
echo -e "\n${BL}Note: Venus OS is now running in ARM emulation mode."
echo -e "The default login for VenusOS is username: 'root' with no password."
echo -e "VM console is available via serial console in Proxmox web interface.${CL}\n"
