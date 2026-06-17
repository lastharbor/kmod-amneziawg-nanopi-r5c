#!/usr/bin/env bash
#
# Build amneziawg.ko (with I1/CPS support) for the FriendlyWRT / FriendlyElec
# vendor kernel 6.1.141 used on the NanoPi R5C (RK3568, aarch64).
#
# Works both on a normal Linux build host (CI, native aarch64 or cross) and,
# with the right toolchain, on the router itself.
#
set -euo pipefail

# ---- configuration (override via env) ---------------------------------------
KREL="${KREL:-6.1.141}"
KERNEL_REPO="${KERNEL_REPO:-friendlyarm/kernel-rockchip}"
KERNEL_BRANCH="${KERNEL_BRANCH:-nanopi6-v6.1.y}"
AWG_REPO="${AWG_REPO:-https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git}"
AWG_REF="${AWG_REF:-2a6e1a02ac024f54a23e18f894a279b7f870b8fb}"
AWG_VERSION="${AWG_VERSION:-1.0.20260611}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$ROOT/build}"
JOBS="$(nproc 2>/dev/null || echo 2)"
mkdir -p "$WORK"

m() { make ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} ARCH="$ARCH" "$@"; }

echo "==> 1/6  Fetch kernel source ($KERNEL_REPO@$KERNEL_BRANCH)"
if [ ! -f "$WORK/kernel/Makefile" ]; then
	if [ ! -f "$WORK/kernel.tar.gz" ]; then
		curl -fL --retry 3 --retry-delay 5 -o "$WORK/kernel.tar.gz" \
			"https://github.com/$KERNEL_REPO/archive/refs/heads/$KERNEL_BRANCH.tar.gz"
	fi
	mkdir -p "$WORK/kernel"
	tar xzf "$WORK/kernel.tar.gz" -C "$WORK/kernel" --strip-components=1
fi
SRCVER="$(m -C "$WORK/kernel" -s kernelversion)"
echo "    kernel source version: $SRCVER (target: $KREL)"
case "$SRCVER" in
	"$KREL"*) : ;;
	*) echo "WARNING: kernel source version ($SRCVER) != target ($KREL)"; ;;
esac

echo "==> 2/6  Apply kernel .config + firmware Module.symvers"
zcat "$ROOT/config/config.gz" > "$WORK/kernel/.config"
cp "$ROOT/config/Module.symvers" "$WORK/kernel/Module.symvers"

echo "==> 3/6  Prepare kernel tree for external modules"
m -C "$WORK/kernel" olddefconfig
m -C "$WORK/kernel" -j"$JOBS" modules_prepare
# modules_prepare must not clobber the CRCs we extracted from the running router
cp "$ROOT/config/Module.symvers" "$WORK/kernel/Module.symvers"

echo "==> 4/6  Fetch AmneziaWG module source ($AWG_REF) + patches"
if [ ! -d "$WORK/awg/.git" ]; then
	git clone "$AWG_REPO" "$WORK/awg"
fi
git -C "$WORK/awg" fetch --all --tags --quiet || true
git -C "$WORK/awg" checkout -f "$AWG_REF"
git -C "$WORK/awg" reset --hard --quiet "$AWG_REF"
for p in "$ROOT"/patches/*.patch; do
	[ -e "$p" ] || continue
	echo "    applying $(basename "$p")"
	git -C "$WORK/awg" apply "$p"
done

echo "==> 5/6  Build amneziawg.ko"
m -C "$WORK/awg/src" -j"$JOBS" \
	KERNELDIR="$WORK/kernel" \
	WIREGUARD_VERSION="$AWG_VERSION" \
	module
KO="$WORK/awg/src/amneziawg.ko"
"${CROSS_COMPILE}strip" --strip-debug "$KO" 2>/dev/null || strip --strip-debug "$KO" 2>/dev/null || true
cp "$KO" "$WORK/amneziawg.ko"
echo "    -> $WORK/amneziawg.ko ($(wc -c <"$WORK/amneziawg.ko") bytes)"
modinfo "$WORK/amneziawg.ko" 2>/dev/null | grep -E '^(version|vermagic|depends)' || true

echo "==> 6/6  Package .ipk"
KREL="$KREL" AWG_VERSION="$AWG_VERSION" KO="$WORK/amneziawg.ko" "$ROOT/package.sh"

echo "==> Done."
