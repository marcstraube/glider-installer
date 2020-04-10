#!/bin/bash

# |_|●|_|    glider-installer 1.0: Bash install script for Arch Linux
# |_|_|●|    Author:  Marc Straube <email@marcstraube.de>
# |●|●|●|    License: This software is free under the GPLv2

set -o errexit
set -o nounset

### Install variables

# The following variables are only needed, if you want to setup a
# wireless connection.
#
wifi_ssid=""
wifi_password=""

# Set this value if you have multiple wireless devices and want to use a
# specific one. Otherwise the first device will be used.
#
wifi_device=""

# The disk where the system gets installed. Be warned that the whole
# disk will be wiped!
#
disk="/dev/sda"

# Set to true if the disk should be shredded.
shred_disk="true"

# Iterations of disk shredding. Only needed if shred_disk="true".
shred_iterations=1

# Needed for disks which put a prefix between disk name and partition
# number, e.g. nvme disk /dev/nvme0n1 needs partiton_prefix="p".
#
partition_prefix=""

# normal: Unencrypted installation with LVM
# encrypted: Encrypted installation with LVM on LUKS
# encrypted_boot: Encrypted installation with LVM on LUKS and encrypted
#                 boot partition
#
install_type="encrypted_boot"

# Only needed if install_type is encrypted or encrypted_boot.
luks_password="luks"

# Name for the LVM group
vgname="vg_root"

# LVM volume sizes
#
# root_size and swap_size are mandatory.
#
# root_size should be at least 4GB, because this setup will already use
# about 2GB.
#
# Because this installation uses a swap volume for hibernation,
# swap_size should be at least the size of your RAM, but it is
# recommended to use even more. See https://itsfoss.com/swap-size/ for
# more information on the topic.
#
# If you do not want a volume for /var, /var/log and /var/log/audit just
# keep the values empty. If home_size is empty, the volume will fill the
# rest of the volume group.
#
root_size="4GB"
swap_size="1GB"
var_size=""
log_size=""
audit_size=""
home_size=""

# Set to true if you want to install multilib packages.
multilib="true"

# Editor
editor="neovim"

# Additional packages
additional_packages="ansible"

# Localization
timezone="Europe/Berlin"
locale="de_DE.UTF-8"
keymap="de-latin1-nodeadkeys"
font="eurlatgr"

# Network
hostname="glider"
domain="local"

# User configuration
root_password="toor"


########################################################################
#############   !Do not change anything after this line!   #############
########################################################################
network_type="wired"
efi_partition="${disk}${partition_prefix}1"
boot_partition="${disk}${partition_prefix}2"
root_partition="${disk}${partition_prefix}3"

set_keymap() {
  printf "Setting keymap.\n"

  loadkeys de-latin1
}

check_network() {
  printf "Checking network connection.\n"
  
  if [[ "${wifi_ssid}" != "" && "${wifi_password}" != ""  ]]; then
    if [ "${wifi_device}" == "" ]; then
      detect_wifi_device_name
    fi
    
    if [ "${wifi_device}" != "" ]; then
      connect_wifi
    fi
  fi

  for ((i=1; i<=3; i++)); do
    if [[ $(ping -c 1 archlinux.org) ]]; then
      return
    else
      sleep 5
    fi
  done

  printf "No network connection possible. Exiting.\n"
  exit 1
}

detect_wifi_device_name() {
  local count=0
  
  for dev in `ls /sys/class/net`; do
    if [[ -d "/sys/class/net/${dev}/wireless" && ${count} == 0 ]]; then
      wifi_device="${dev}"
      count=$((count+1))
    fi
  done
}

get_wifi_udev_name() {
  local udev_name="$(udevadm test-builtin net_id /sys/class/net/${wifi_device} | grep 'ID_NET_NAME_PATH')"
  echo ${udev_name/*=/}
}

connect_wifi() {
  printf "Connecting to wifi network ${wifi_ssid}.\n"

  wpa_passphrase ${wifi_ssid} ${wifi_password} > /etc/wpa_supplicant/wpa_supplicant-$(get_wifi_udev_name).conf
  wpa_supplicant -i ${wifi_device} -D wext -c /etc/wpa_supplicant/wpa_supplicant-$(get_wifi_udev_name).conf -B
  dhcpcd ${wifi_device}
  network_type="wifi"
}

update_system_clock() {
  printf "Updating system clock.\n"

  timedatectl set-ntp true
}

is_efi() {
  if [ -d /sys/firmware/efi/efivars ]; then
    return 0
  else
    return 1
  fi
}

shred_disk() {
  printf "Shredding disk.\n"

  shred -n ${shred_iterations} -v ${disk}
}

partition_disk() {
  printf "Partitioning disk.\n"

  sgdisk -Z ${disk}
  wipefs -a ${disk}

  case "${install_type}" in
    normal)
      local boot_partition_code="8300"
      local root_partition_code="8e00"
    ;;
    encrypted|encrypted_boot)
      local boot_partition_code="8309"
      local root_partition_code="8309"
    ;;
  esac

  if is_efi; then
    sgdisk -n 0:0:+550MiB -t 0:ef00 -c 0:"EFI system partition" ${disk}
  else
    sgdisk -n 0:0:+1MiB -t 0:ef02 -c 0:"BIOS boot partition" ${disk}
  fi

  sgdisk -n 0:0:+500MiB -t 0:${boot_partition_code} -c 0:"Boot" ${disk}
  sgdisk -n 0:0:0 -t 0:${root_partition_code} -c 0:"Linux" ${disk}
  partprobe ${disk}
}

encrypt_disk() {
  printf "Encrypting disk.\n"

  if [ "${install_type}" == "encrypted_boot" ]; then
    # at the moment only luks1 is supported for encrypted boot; see https://wiki.archlinux.org/index.php/GRUB#Encrypted_/boot
    # luks2 is only supported in git master; see https://savannah.gnu.org/bugs/?55093
    echo "${luks_password}" | cryptsetup -c aes-xts-plain64 -s 512 -h sha512 --use-random --type luks1 -y luksFormat ${boot_partition}
    echo "${luks_password}" | cryptsetup luksOpen ${boot_partition} crypto_boot
  fi

  echo "${luks_password}" | cryptsetup -c aes-xts-plain64 -s 512 -h sha512 --use-random -y luksFormat ${root_partition}
  echo "${luks_password}" | cryptsetup luksOpen ${root_partition} crypto_root
}

create_lvm() {
  printf "Creating LVM.\n"

  case "${install_type}" in
    normal)
      pvcreate ${root_partition}
      vgcreate ${vgname} ${root_partition}
    ;;
    encrypted|encrypted_boot)
      pvcreate /dev/mapper/crypto_root
      vgcreate ${vgname} /dev/mapper/crypto_root
    ;;
  esac

  lvcreate -L ${root_size} -n root ${vgname}
  lvcreate -L ${swap_size} -n swap ${vgname}

  if [ "${var_size}" != "" ]; then
    lvcreate -L ${var_size} -n var ${vgname}
  fi

  if [ "${log_size}" != "" ]; then
    lvcreate -L ${log_size} -n log ${vgname}
  fi

  if [ "${audit_size}" != "" ]; then
    lvcreate -L ${audit_size} -n audit ${vgname}
  fi

  if [ "${home_size}" != "" ]; then
    lvcreate -L ${home_size} -n home ${vgname}
  else
    lvcreate -l 100%FREE -n home ${vgname}
  fi
}

format_partitions() {
  printf "Formating partitions.\n"

  if is_efi; then
    mkfs.fat -F32 ${efi_partition}
  fi

  case "${install_type}" in
    normal|encrypted)
      mkfs.ext4 ${boot_partition} -L boot
    ;;
    encrypted_boot)
      mkfs.ext4 /dev/mapper/crypto_boot -L boot
    ;;
  esac

  mkfs.ext4 /dev/${vgname}/root -L root
  mkswap /dev/${vgname}/swap -L swap

  if [ "${var_size}" != "" ]; then
    mkfs.ext4 /dev/${vgname}/var -L var
  fi

  if [ "${log_size}" != "" ]; then
    mkfs.ext4 /dev/${vgname}/log -L log
  fi

  if [ "${audit_size}" != "" ]; then
    mkfs.ext4 /dev/${vgname}/audit -L audit
  fi

  mkfs.ext4 /dev/${vgname}/home -L home
}

mount_partitions() {
  printf "Mounting partitions.\n"

  mount /dev/${vgname}/root /mnt

  if is_efi; then
    mkdir /mnt/efi
    mount ${efi_partition} /mnt/efi
  fi

  mkdir /mnt/{boot,home}

  case "${install_type}" in
    normal|encrypted)
      mount ${boot_partition} /mnt/boot
    ;;
    encrypted_boot)
      mount /dev/mapper/crypto_boot /mnt/boot
    ;;
  esac

  swapon /dev/${vgname}/swap

  if [ "${var_size}" != "" ]; then
    mkdir -p /mnt/var
    mount /dev/${vgname}/var /mnt/var
  fi

  if [ "${log_size}" != "" ]; then
    mkdir -p /mnt/var/log
    mount /dev/${vgname}/log /mnt/var/log
  fi

  if [ "${audit_size}" != "" ]; then
    mkdir -p /mnt/var/log/audit
    mount /dev/${vgname}/audit /mnt/var/log/audit
  fi

  mount /dev/${vgname}/home /mnt/home
}

install_system() {
  printf "Installing system.\n"

  local packages="base base-devel linux linux-firmware lvm2 man-db man-pages texinfo grub dhcpcd ${editor} ${additional_packages}"

  if is_efi; then
    packages+=" efibootmgr"
  fi

  if [ "${network_type}" == "wifi" ]; then
    packages+=" wpa_supplicant"
  fi

  if [[ $(lscpu | grep 'Intel') ]]; then
    packages+=' intel-ucode'
  elif [[ $(lscpu | grep 'AMD') ]]; then
    packages+=' amd-ucode'
  fi

  if [ "${multilib}" = "true" ]; then
    sed -e 's/^#\[multilib]/\[multilib]/g' \
        -e '/^\[multilib]/{N;s/\n#/\n/}' -i /etc/pacman.conf
  fi

  pacstrap /mnt ${packages}

  if [ "${multilib}" = "true" ]; then
    sed -e 's/^#\[multilib]/\[multilib]/g' \
        -e '/^\[multilib]/{N;s/\n#/\n/}' -i /mnt/etc/pacman.conf
  fi
}

generate_fstab() {
  printf "Generating fstab.\n"

  genfstab -U /mnt >> /mnt/etc/fstab
}

install_wifi_config() {
  printf "Installing wifi config.\n"

  cp /etc/wpa_supplicant/wpa_supplicant-$(get_wifi_udev_name).conf \
     /mnt/etc/wpa_supplicant/wpa_supplicant-$(get_wifi_udev_name).conf
}

chroot_install() {
  printf "Chrooting.\n"

  cp ${0} /mnt/install.sh
  arch-chroot /mnt ./install.sh chroot
}

set_timezone() {
  printf "Setting timezone to ${timezone}.\n"

  ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime

  timedatectl set-local-rtc 1    # Set the hwclock to UTC
  hwclock --systohc
}

set_localization() {
  printf "Localizing system.\n"

  sed -r "s/^#(en_US.UTF-8.*)$/\1/g" -i /etc/locale.gen
  sed -r "s/^#(${locale}.*)$/\1/g" -i /etc/locale.gen
  locale-gen
  echo "LANG=${locale}" >> /etc/locale.conf
  echo "LC_COLLATE=C" >> /etc/locale.conf
  echo "KEYMAP=${keymap}" >> /etc/vconsole.conf
  echo "FONT=${font}" >> /etc/vconsole.conf
}

config_network() {
    printf "Configuring network.\n"

    echo "${hostname}" > /etc/hostname
    echo "127.0.0.1    localhost" >> /etc/hosts
    echo "127.0.1.1    ${hostname}.${domain}     ${hostname}" >> /etc/hosts
    echo "" >> /etc/hosts
    echo "::1          localhost ip6-localhost ip6-loopback" >> /etc/hosts
    echo "fe00::0      ip6-localnet" >> /etc/hosts
    echo "ff00::0      ip6-mcastprefix" >> /etc/hosts
    echo "ff02::1      ip6-allnodes" >> /etc/hosts
    echo "ff02::2      ip6-allrouters" >> /etc/hosts
    echo "ff02::3      ip6-allhosts" >> /etc/hosts
}

enable_network_services() {
  printf "Enabling network services.\n"
  
  ln -sf /usr/lib/systemd/system/dhcpcd.service \
         /etc/systemd/system/multi-user.target.wants/dhcpcd.service

  if [[ "${wifi_ssid}" != "" && "${wifi_password}" != ""  ]]; then
    if [ "${wifi_device}" == "" ]; then
      detect_wifi_device_name
    fi
  fi
  
  if [ "${wifi_device}" != "" ]; then
    ln -sf /usr/lib/systemd/system/wpa_supplicant@.service \
           /etc/systemd/system/multi-user.target.wants/wpa_supplicant@$(get_wifi_udev_name).service
  fi
}

create_crypto_keyfile() {
  printf "Creating crypto keyfile.\n"

  dd bs=512 count=4 if=/dev/random of=/crypto_keyfile.bin iflag=fullblock
  chmod 000 /crypto_keyfile.bin
  echo "${luks_password}" | cryptsetup luksAddKey ${boot_partition} /crypto_keyfile.bin
  echo "${luks_password}" | cryptsetup luksAddKey ${root_partition} /crypto_keyfile.bin
}

create_initramfs() {
  local encrypt_hook=""

  if [ "${install_type}" == "encrypted_boot" ]; then
    sed "s/^FILES.*/FILES=(\/crypto_keyfile.bin)/" -i /etc/mkinitcpio.conf
  fi

  if [[ "${install_type}" == "encrypted" || "${install_type}" == "encrypted_boot" ]]; then
    encrypt_hook="sd-encrypt "
  fi

  sed "s/^HOOKS.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block ${encrypt_hook}sd-lvm2 filesystems fsck)/" -i /etc/mkinitcpio.conf

  mkinitcpio -P

  if [ "${install_type}" == "encrypted_boot" ]; then
    chmod 600 /boot/initramfs-*.img
  fi
}

create_crypttab() {
    echo "crypto_boot UUID=$(blkid -s UUID -o value ${boot_partition}) /crypto_keyfile.bin luks" >> /etc/crypttab
}

set_root_password() {
  printf "Setting root password \n"

  echo -en "${root_password}\n${root_password}" | passwd
}

install_bootloader() {
  printf "Installing boot loader.\n"

  local uuid=$(blkid | grep "${root_partition}" | cut -d \" -f 2)

  case "${install_type}" in
    normal)
      cmdline="root=\/dev\/${vgname}\/root resume=\/dev\/${vgname}\/swap"
    ;;
    encrypted)
      cmdline="rd.luks.name=${uuid}=crypto_root root=\/dev\/${vgname}\/root resume=\/dev\/${vgname}\/swap"
    ;;
    encrypted_boot)
      sed "s/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/" -i /etc/default/grub
      cmdline="rd.luks.name=${uuid}=crypto_root rd.luks.key=${uuid}=\/crypto_keyfile.bin root=\/dev\/${vgname}\/root resume=\/dev\/${vgname}\/swap"
    ;;
  esac

  sed "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"${cmdline}\"/" -i /etc/default/grub

  if is_efi; then
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Arch Linux" --recheck
  else
    grub-install --target=i386-pc ${disk} --recheck
  fi

  grub-mkconfig -o /boot/grub/grub.cfg
}

umount_disk() {
  printf "Unmounting disks \n"

  umount -R /mnt
  swapoff -a
}

finish() {
  printf "Installation finished. You can now reboot the system. \n"
}

setup() {
  set_keymap
  check_network
  update_system_clock

  if [ "${shred_disk}" == "true" ]; then
	shred_disk
  fi

  partition_disk

  if [[ "${install_type}" == "encrypted" || "${install_type}" == "encrypted_boot" ]]; then
	encrypt_disk
  fi

  create_lvm
  format_partitions
  mount_partitions
  install_system
  generate_fstab

  if [ "${network_type}" == "wifi" ]; then
    install_wifi_config
  fi

  chroot_install
  umount_disk
  finish
}

setup_chroot() {
  set_timezone
  set_localization

  if [ "${install_type}" == "encrypted_boot" ]; then
	create_crypto_keyfile
  fi

  config_network
  enable_network_services
  create_initramfs

  if [ "${install_type}" == "encrypted_boot" ]; then
	create_crypttab
  fi

  set_root_password
  install_bootloader
}

val=${1:-}
case "${val}" in
    chroot)
        setup_chroot ;;
    *)
        setup ;;
esac
