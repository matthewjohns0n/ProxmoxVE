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

# Variables
VENUS_IMAGE_URL="https://updates.victronenergy.com/feeds/venus/release/images/raspberrypi4/venus-image-large-raspberrypi4.wic.gz"
TEMP_DIR=$(mktemp -d)
GEN_MAC=$(echo '00 60 2f'$(od -An -N3 -t xC /dev/urandom) | sed -e 's/ /:/g' | tr '[:lower:]' '[:upper:]')
NEXTID=$(pvesh get /cluster/nextid)
RANDOM_UUID=$(cat /proc/sys/kernel/random/uuid)

# Styling
BL="\e[36m"
RD="\e[31m"
GN="\e[32m"
YW="\e[33m"
CL="\e[0m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
BOLD="\e[1m"
DIM="\e[2m"
DGN="${BL}${BOLD}"
BGN="${GN}${BOLD}"
RD1="${RD}${DIM}"
HOLD="-"
TAB="    "
BFR="\\r\\033[K"

# Labels for output
VMOS="VenusOS"
CONTAINERID="ID: "
CONTAINERTYPE="Type: "
DISKSIZE="Disk: "
DISKFORMAT="Format: "
HOSTNAME="Hostname: "
OS="OS: "
CPUCORE="CPU: "
RAMSIZE="RAM: "
BRIDGE="Bridge: "
MACADDRESS="MAC: "
GATEWAY="Gateway: "
CREATING="Creating "

# Trap handlers
trap cleanup EXIT
trap 'post_update_to_api "failed" "INTERRUPTED"' SIGINT
trap 'post_update_to_api "failed" "TERMINATED"' SIGTERM

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  post_update_to_api "failed" "$command"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root."
    echo -e "\nExiting..."
    sleep 2
    exit
  fi
}

function pve_check() {
  if ! pveversion | grep -Eq "pve-manager/[8](\.[0-9]+)*"; then
    msg_error "${CROSS}${RD}This version of Proxmox Virtual Environment is not supported"
    echo -e "Requires Proxmox Virtual Environment Version 8.0 or later."
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
      fi
    fi
  fi
}

function exit-script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

function check_arm_packages() {
  msg_info "Checking for ARM emulation packages"
  if ! dpkg -l | grep -q "pve-edk2-firmware-aarch64"; then
    msg_info "Installing pve-edk2-firmware-aarch64 package"
    apt update >/dev/null 2>&1
    apt install -y pve-edk2-firmware-aarch64 >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      msg_error "Failed to install ARM emulation packages"
      echo -e "Please install manually with: apt install pve-edk2-firmware-aarch64"
      exit 1
    fi
    msg_ok "ARM emulation packages installed"
  else
    msg_ok "ARM emulation packages already installed"
  fi
}

function default_settings() {
  VMID="$NEXTID"
  FORMAT=",efitype=4m,format=raw"
  DISK_SIZE="4G"
  DISK_CACHE=""
  HN="venusrpi"
  CORE_COUNT="2"
  RAM_SIZE="1024"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating a VenusOS ARM VM using the above default settings${CL}"
}

function advanced_settings() {
  if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $NEXTID --title "VM ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VMID" ]; then
      VMID="$NEXTID"
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
    else
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
    fi
  else
    exit-script
  fi

  if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GB" 8 58 4 --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$DISK_SIZE" ]; then
      DISK_SIZE="4G"
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
    else
      if ! [[ $DISK_SIZE =~ ^[0-9]+$ ]]; then
        DISK_SIZE="4G"
        echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
      else
        DISK_SIZE="${DISK_SIZE}G"
        echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
      fi
    fi
  else
    exit-script
  fi

  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 venusrpi --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VM_NAME ]; then
      HN="venusrpi"
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    else
      HN=$(echo ${VM_NAME,,} | tr -d ' ')
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    fi
  else
    exit-script
  fi

  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 2 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $CORE_COUNT ]; then
      CORE_COUNT="2"
      echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
    else
      echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
    fi
  else
    exit-script
  fi

  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 1024 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $RAM_SIZE ]; then
      RAM_SIZE="1024"
      echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
    else
      echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
    fi
  else
    exit-script
  fi

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then
      BRG="vmbr0"
      echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
    else
      echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
    fi
  else
    exit-script
  fi

  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 $GEN_MAC --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC1 ]; then
      MAC="$GEN_MAC"
      echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
    else
      MAC="$MAC1"
      echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
    fi
  else
    exit-script
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create the VM?" 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating a VenusOS ARM VM with advanced settings${CL}"
  else
    exit-script
  fi
}

function download_venus_image() {
  msg_info "[SKIPPING] Downloading VenusOS image"
  # wget -q --show-progress $VENUS_IMAGE_URL -O $TEMP_DIR/venus.wic.gz
  # if [ $? -ne 0 ]; then
  #   msg_error "Failed to download VenusOS image"
  #   echo -e "Please check your internet connection or the image URL"
  #   exit 1
  # fi
  # msg_ok "VenusOS image downloaded"

  msg_info "Extracting VenusOS image"
  cp /var/lib/vz/template/iso/venus/venus-image-large-raspberrypi4.wic $TEMP_DIR/venus.wic
  # gunzip -f $TEMP_DIR/venus.wic.gz
  if [ $? -ne 0 ]; then
    msg_error "Failed to extract VenusOS image"
    exit 1
  fi
  msg_ok "VenusOS image extracted"
}

function create_vm() {
  msg_info "Creating ARM VM with ID ${VMID}"

  qm create $VMID \
    --name $HN \
    --memory $RAM_SIZE \
    --arch aarch64 \
    --cores $CORE_COUNT \
    --net0 virtio,bridge=$BRG,macaddr=$MAC \
    --serial0 socket \
    --vga serial0 \
    --boot order=scsi0 \
    --ostype l26 \
    --machine virt \
    --bios ovmf

  if [ $? -ne 0 ]; then
    msg_error "Failed to create VM"
    exit 1
  fi
  msg_ok "VM created successfully"

  msg_info "Creating EFI disk"
  qm set $VMID --efidisk0 local-lvm:1,efitype=4m,format=raw
  if [ $? -ne 0 ]; then
    msg_error "Failed to create EFI disk"
    exit 1
  fi
  msg_ok "EFI disk created"

  msg_info "Importing VenusOS disk"
  qm importdisk $VMID $TEMP_DIR/venus.wic local-lvm
  if [ $? -ne 0 ]; then
    msg_error "Failed to import VenusOS disk"
    exit 1
  fi
  msg_ok "VenusOS disk imported"

  msg_info "Attaching disk to VM"
  qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0
  if [ $? -ne 0 ]; then
    msg_error "Failed to attach disk to VM"
    exit 1
  fi
  msg_ok "Disk attached to VM"

  msg_info "Resizing disk to $DISK_SIZE"
  qm resize $VMID scsi0 $DISK_SIZE
  if [ $? -ne 0 ]; then
    msg_error "Failed to resize disk"
    exit 1
  fi
  msg_ok "Disk resized"
}

function add_description() {
  local desc="<div style=\"font-family: 'Courier New', Courier, monospace;\">"
  desc+="                    _    _                       ____  _____\n"
  desc+="                   | |  | |                     / __ \/ ____|\n"
  desc+="                   | |  | | ___ _ __  _   _ ___| |  | | (___\n"
  desc+="                   | |  | |/ _ \\ '_ \\| | | / __| |  | |\\___ \\\n"
  desc+="                   | |__| |  __/ | | | |_| \\__ \\ |__| |____) |\n"
  desc+="                    \\____/ \\___|_| |_|\\__,_|___/\\____/|_____/\n"
  desc+="                           Victron Energy Venus OS\n"
  desc+="</div>\n\n"
  desc+="<p>This VM is running the VenusOS image emulating a Raspberry Pi 4 (ARM architecture) on x86 hardware.</p>\n\n"
  desc+="<p>VenusOS is the operating system used by Victron Energy for their GX devices. This install allows monitoring and control of Victron Energy products using a web-based remote console or VRM portal.</p>\n\n"
  desc+="<p><b>Important Notes:</b></p>\n"
  desc+="<ul>\n"
  desc+="  <li>After booting, wait a few minutes and then access the web interface at the VM's IP address in your browser</li>\n"
  desc+="  <li>The VRM Portal ID is derived from the MAC address</li>\n"
  desc+="  <li>ARM emulation on x86 can be slow - this is normal</li>\n"
  desc+="  <li>For additional help, visit: <a href='https://community.victronenergy.com/'>https://community.victronenergy.com/</a></li>\n"
  desc+="</ul>\n\n"
  desc+="<p><b>Original image:</b> <a href='https://updates.victronenergy.com/feeds/venus/release/images/raspberrypi4/'>https://updates.victronenergy.com/feeds/venus/release/images/raspberrypi4/</a></p>"

  qm set "$VMID" -description "$desc" >/dev/null
  msg_ok "Added VM description"
}

function start_vm() {
  if [ "$START_VM" == "yes" ]; then
    msg_info "Starting VenusOS VM"
    qm start $VMID
    msg_ok "Started VenusOS VM"
  fi
}

# Script starts here
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

header_info
check_root
pve_check
ssh_check
check_arm_packages

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "VenusOS ARM VM" --yesno "This will create a new VenusOS ARM VM emulating a Raspberry Pi 4.\n\nWould you like to use the default settings?" 12 58; then
  default_settings
else
  advanced_settings
fi

download_venus_image
create_vm
add_description
start_vm

post_update_to_api "done" "none"

msg_ok "VenusOS ARM VM setup completed!\n"
echo -e "Access the VenusOS web interface by navigating to the VM's IP address in your browser\n"
echo -e "For more information, visit: https://community.victronenergy.com/questions/270322/notes-for-installing-venus-os-on-a-raspberry-pi-ze.html"
echo -e "You can also find information at: https://github.com/victronenergy/venus/wiki/raspberrypi-install-venus-image"
