#!/usr/bin/env bash
#
# Package a prebuilt amneziawg.ko into an OpenWrt .ipk that installs correctly
# on the FriendlyWRT vendor image (kernel 6.1.141, NanoPi R5C).
#
# Notes specific to this firmware:
#   * opkg's DB advertises a different kernel (6.6.110) than the running one
#     (6.1.141), so we deliberately DO NOT add a `kernel (= ...)` dependency.
#   * depmod segfaults on this image, so the module is loaded by a tiny init
#     script (/etc/init.d/amneziawg) instead of relying on modules.dep.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KREL="${KREL:-6.1.141}"
AWG_VERSION="${AWG_VERSION:-1.0.20260611}"
PKG_RELEASE="${PKG_RELEASE:-1}"
ARCH_PKG="${ARCH_PKG:-aarch64_generic}"
KO="${KO:-$ROOT/build/amneziawg.ko}"
OUT="${OUT:-$ROOT/dist}"

[ -f "$KO" ] || { echo "ERROR: module not found: $KO"; exit 1; }
mkdir -p "$OUT"
VER="${AWG_VERSION}-r${PKG_RELEASE}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/data/lib/modules/$KREL" "$T/data/etc/init.d" "$T/control"

cp "$KO" "$T/data/lib/modules/$KREL/amneziawg.ko"
chmod 0644 "$T/data/lib/modules/$KREL/amneziawg.ko"
# bake the kernel release into the loader
sed "s/^KREL=.*/KREL=\"$KREL\"/" "$ROOT/files/etc/init.d/amneziawg" > "$T/data/etc/init.d/amneziawg"
chmod 0755 "$T/data/etc/init.d/amneziawg"

ISIZE="$(du -sb "$T/data" | cut -f1)"
cat > "$T/control/control" <<EOF
Package: kmod-amneziawg
Version: $VER
Source: amnezia-vpn/amneziawg-linux-kernel-module
Section: kernel
Architecture: $ARCH_PKG
Installed-Size: $ISIZE
Description: AmneziaWG kernel module $AWG_VERSION (I1/CPS) for FriendlyWRT
 kernel $KREL on NanoPi R5C (RK3568). Built out-of-tree against the
 FriendlyElec vendor kernel; loaded via /etc/init.d/amneziawg because
 depmod segfaults on this image.
EOF

cat > "$T/control/conffiles" <<EOF
/etc/init.d/amneziawg
EOF

cat > "$T/control/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/amneziawg enable 2>/dev/null
/etc/init.d/amneziawg start 2>/dev/null
exit 0
EOF

cat > "$T/control/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/amneziawg stop 2>/dev/null
/etc/init.d/amneziawg disable 2>/dev/null
exit 0
EOF
chmod 0755 "$T/control/postinst" "$T/control/prerm"

echo "2.0" > "$T/debian-binary"

( cd "$T/data"    && tar --numeric-owner --owner=0 --group=0 -czf ../data.tar.gz ./* )
( cd "$T/control" && tar --numeric-owner --owner=0 --group=0 -czf ../control.tar.gz ./* )
IPK="$OUT/kmod-amneziawg_${VER}_${ARCH_PKG}.ipk"
( cd "$T" && tar --numeric-owner --owner=0 --group=0 -czf "$IPK" debian-binary control.tar.gz data.tar.gz )

echo "packaged: $IPK"
ls -la "$IPK"
