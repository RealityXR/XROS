#!/usr/bin/bash
cd tmp
docker save archlinux -o arch.tar
tar -xf arch.tar
tar -xf \
    $(find ./arch/blobs/sha256 -type f -size +100M | tr -d '\n') \
    -C $( getent passwd "$USER" | cut -d: -f6 )

arch-chroot $( getent passwd "$USER" | cut -d: -f6 )

pacman-key --init
pacman-key --populate
pacman -Syu --noconfirm
pacman -S sudo --noconfirm
pacman -S fastfetch --noconfirm
pacman -S vi --noconfirm
pacman -S vim --noconfirm
pacman -S neovim --noconfirm
pacman -S nano --noconfirm
pacman -S xorg-xwayland --noconfirm
pacman -S git --noconfirm
pacman -S base-devel --noconfirm
pacman -S go --noconfirm
cd /tmp/
git clone https://aur.archlinux.org/yay.git
chmod 0777 /tmp/yay/
useradd -d /tmp tmp
echo 'tmp ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
su tmp
cd /tmp/yay/
export GOFLAGS="-buildvcs=false"
yes | makepkg -si
cd /tmp/

sudo su
rm -rf /tmp/*
userdel tmp
sed '/^tmp/d' < /etc/sudoers > /tmp/sudoers
mv /tmp/sudoers /etc/sudoers
cd /
