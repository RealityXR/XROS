FROM archlinux
RUN pacman-key --init
RUN pacman-key --populate
RUN pacman -Syu --noconfirm
RUN pacman -S sudo --noconfirm
RUN pacman -S fastfetch --noconfirm
RUN pacman -S vi --noconfirm
RUN pacman -S vim --noconfirm
RUN pacman -S neovim --noconfirm
RUN pacman -S nano --noconfirm
RUN pacman -S xorg-xwayland --noconfirm
RUN pacman -S git --noconfirm
RUN pacman -S base-devel --noconfirm
RUN pacman -S go --noconfirm
WORKDIR /tmp/
RUN git clone https://aur.archlinux.org/yay.git
RUN chmod 0777 /tmp/yay/
RUN useradd -d /tmp tmp
RUN echo 'tmp ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
USER tmp
WORKDIR /tmp/yay/
ENV GOFLAGS="-buildvcs=false"
RUN yes | makepkg -si
WORKDIR /tmp/

USER root
RUN rm -rf /tmp/*
RUN userdel tmp
RUN sed '/^tmp/d' < /etc/sudoers > /tmp/sudoers
RUN mv /tmp/sudoers /etc/sudoers
WORKDIR /