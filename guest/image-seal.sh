#!/usr/bin/env bash
# Turn a freshly set-up VM into Portalistic's ready-made Linux image (host/build-image.sh runs
# this in the image VM, as root, after setup-guest.sh). Leaves out what VMs don't need, and
# everything that belongs to one Mac or one user, then powers the VM off:
#   * build tools, headers and test programs (the kit's ready-made builds replace them);
#   * the compressed copy of the x86 system (fex-emu-rootfs-fedora, 1.8 GB): Steam's FEX runs
#     games on the unpacked one in /usr/share/guestos/fex-mesa, and FEX's own settings point there;
#   * documentation, translations other than English, package caches, logs, crash dumps;
#   * the build user and its home, Steam's folder (/s), cloud-init's record of this boot, the
#     machine ID and the SSH host keys: a new VM makes its own at its first start.
#
#   sudo bash image-seal.sh            slim it down, then seal and power off (in the background,
#                                      once the calling ssh session is gone)
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
BUILD_USER="${SUDO_USER:?run via sudo from the build user}"

info "Removing build tools, headers and test programs…"
mapfile -t devel < <(rpm -qa --qf '%{NAME}\n' | grep -E -- '-devel$|^(gcc|gcc-c\+\+|cpp|make|vulkan-headers|mesa-demos|vkmark|llvm18-libs|podman|kernel-devel|glslang|spirv-tools|cmake|meson|ninja-build|compsize|erofs-utils)$' | sort -u)
if (( ${#devel[@]} )); then
  echo "  ${devel[*]}"
  dnf remove -y -q "${devel[@]}" >/dev/null
fi

info "Removing the compressed x86 system (games use the unpacked one)…"
if [[ -d /usr/share/guestos/fex-mesa/usr/lib64 ]] && rpm -q fex-emu-rootfs-fedora >/dev/null 2>&1; then
  dnf remove -y -q fex-emu-rootfs-fedora >/dev/null
fi

info "Documentation, translations, caches, logs…"
mkdir -p /etc/dnf
grep -q '^tsflags=nodocs' /etc/dnf/dnf.conf 2>/dev/null || { grep -q '^\[main\]' /etc/dnf/dnf.conf 2>/dev/null || echo '[main]' >> /etc/dnf/dnf.conf; echo 'tsflags=nodocs' >> /etc/dnf/dnf.conf; }
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/gtk-doc
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en' ! -name 'en_US' ! -name 'en_GB' ! -name 'C*' -exec rm -rf {} +
dnf clean all -q >/dev/null 2>&1 || true
rm -rf /var/cache/dnf /var/cache/libdnf5/* /var/lib/systemd/coredump/* /var/tmp/* /tmp/* 2>/dev/null || true
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
# keep the journal small in every VM made from this image
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/50-portalistic.conf

# The rest runs as a system service once this ssh session has ended (removing the build user
# ends it). From /usr/local/sbin: SELinux lets systemd run programs there, not from /root.
# Its output goes to the VM's console (serial.log in the image VM's Lima folder on the Mac).
SEAL=/usr/local/sbin/portalistic-seal-final
cat > "$SEAL" <<EOF
#!/bin/bash
exec >/dev/console 2>&1
echo "portalistic-seal: removing $BUILD_USER, sealing, powering off"
sleep 3
loginctl disable-linger "$BUILD_USER" 2>/dev/null || true
loginctl terminate-user "$BUILD_USER" 2>/dev/null || true
sleep 2
pkill -KILL -u "$BUILD_USER" 2>/dev/null || true
sleep 1
userdel -r "$BUILD_USER" || userdel -f "$BUILD_USER" || echo "portalistic-seal: userdel failed"
rm -rf "/home/$BUILD_USER" /s /var/lib/steamos-bottle /etc/sudoers.d/90-lima-users /root/.bash_history
rm -f /etc/udev/rules.d/70-steamos-bottle.rules /etc/modules-load.d/steamos-bottle.conf
cloud-init clean --logs --seed >/dev/null 2>&1 || rm -rf /var/lib/cloud
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/systemd/random-seed
rm -rf /var/log/journal/* /var/log/*.log /var/log/cloud-init* 2>/dev/null
rm -f "$SEAL"
echo "portalistic-seal: done, powering off"
sync
fstrim -av >/dev/null 2>&1 || true
systemctl poweroff
EOF
chmod 700 "$SEAL"
restorecon "$SEAL" 2>/dev/null || true
rm -f /root/portalistic-seal-final.sh
systemd-run --unit=portalistic-seal --collect "$SEAL" >/dev/null
info "Sealing in the background; the VM powers off in a few seconds."
