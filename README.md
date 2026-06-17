# kmod-amneziawg for NanoPi R5C (FriendlyWRT, kernel 6.1.141)

Out-of-tree build of the **upstream** [AmneziaWG kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
(`amneziawg.ko`, version `1.0.20260611`, **with `I1`/CPS support**) for the
**FriendlyElec vendor kernel `6.1.141`** that ships on the NanoPi R5C
(RK3568, `aarch64`) running FriendlyWRT.

The stock/community `kmod-amneziawg` packages do not work on this image:

* the OpenWrt feed targets a different kernel (`6.6.110`), and
* older repacked modules lack `I1` (Custom Protocol Signature), so
  `awg setconf` fails with `Invalid argument` on configs that use `I1`.

This repo builds a module that **loads cleanly and accepts `I1`**.

## How it works (the tricky bits)

1. **Kernel source** — `friendlyarm/kernel-rockchip@nanopi6-v6.1.y` (exactly `6.1.141`).
2. **`config/config.gz`** — the kernel `.config` taken from the running router
   (`/proc/config.gz`).
3. **`config/Module.symvers`** — the symbol **CRCs extracted from the running
   firmware**. The kernel is built with `CONFIG_MODVERSIONS`, so a module needs
   matching CRCs or `insmod` rejects it. A normal `Module.symvers` only exists
   after a full kernel build, and `__crc_*` are stripped from `/proc/kallsyms`.
   Instead we harvested the CRCs from every `*.ko` already on the device:

   ```sh
   for f in /lib/modules/$(uname -r)/*.ko; do modprobe --dump-modversions "$f"; done \
     | awk '!seen[$2]++{print $1"\t"$2"\tvmlinux\tEXPORT_SYMBOL\t"}' > Module.symvers
   ```

   This yields ~8600 symbols with correct CRCs and is what makes the module
   loadable on this exact kernel.
4. **`patches/0001-compat-timer_delete-vendor-6.1.x.patch`** — the June-2026
   module assumes `timer_delete()` / `timer_delete_sync()` were backported into
   stable `6.1.84`/`6.1.91`. The FriendlyElec vendor kernel labels itself
   `6.1.141` but does **not** carry that backport, so the patch extends the
   compat shims to cover it.
5. **Packaging** — see "Firmware-specific install" below.

## Build locally

```sh
./build.sh        # downloads kernel, prepares tree, builds module, makes .ipk
# result: dist/kmod-amneziawg_1.0.20260611-r1_aarch64_generic.ipk
```

Overridable via env: `AWG_REF`, `AWG_VERSION`, `KERNEL_BRANCH`, `KREL`,
`ARCH`, `CROSS_COMPILE`, `PKG_RELEASE`.

## CI

`.github/workflows/build.yml` runs on a **native `ubuntu-24.04-arm` runner**
(no cross-compile, matches the target arch and the on-device build). The kernel
tarball is cached, so only the first run pays the download cost. Tagging
`v*` publishes the `.ipk` as a GitHub Release.

## Install on the router

### From the opkg feed (GitHub Pages)

```sh
echo 'src/gz awg_nanopi https://lastharbor.github.io/kmod-amneziawg-nanopi-r5c' >> /etc/opkg/customfeeds.conf
opkg update
opkg install --force-depends kmod-amneziawg
```

### From a downloaded .ipk

```sh
opkg install --force-depends kmod-amneziawg_1.0.20260611-r1_aarch64_generic.ipk
```

`--force-depends` is required because opkg's DB lists kernel `6.6.110` while the
device actually runs `6.1.141`; the package intentionally carries no
`kernel (= ...)` dependency for the same reason.

### Firmware-specific install details

* The module is installed to `/lib/modules/6.1.141/amneziawg.ko`.
* `depmod` **segfaults** on this vendor image, so the package ships
  `/etc/init.d/amneziawg` (START=19, before `netifd`) which `insmod`s the module
  and its dependencies (`udp_tunnel`, `ip6_udp_tunnel`,
  `libchacha20poly1305`, `libcurve25519_generic`) in the right order at boot.
  `postinst` enables and starts it automatically.

### Verify

```sh
lsmod | grep amneziawg
dmesg | grep -i 'amneziawg.*loaded'
awg --version
```

## Runtime / UCI

The userspace side (`amneziawg-tools`, `luci-proto-amneziawg`) is provided by
existing packages. A client interface that **does not hijack the default
gateway** uses `route_allowed_ips '0'`, `defaultroute '0'`, `nohostroute '1'`,
`peerdns '0'` on the `interface` section.

## Limitations

This package is intentionally built for **one specific firmware image**. Be
aware of the following before using it:

1. **Locked to the exact kernel build (`6.1.141`).** The module's
   `vermagic` is `6.1.141 SMP mod_unload modversions aarch64`. It will only load
   on a kernel with that exact vermagic. Any FriendlyWRT/FriendlyElec firmware
   update that changes the kernel version *or rebuilds it differently* will make
   the module refuse to load.

2. **CRCs are harvested from *your current* running firmware.** Because the
   kernel uses `CONFIG_MODVERSIONS`, `config/Module.symvers` contains symbol CRCs
   taken from the modules already on the device. If a firmware update changes any
   exported symbol's signature, `insmod` fails with
   *"disagrees about version of symbol …"*. **After any firmware update you must
   rebuild** (re-export `config.gz` and `Module.symvers` from the new image).

3. **`Module.symvers` is a subset (~8600 symbols), not the full kernel table.**
   It only covers symbols that some on-device module imports. If a future
   AmneziaWG version references an exported symbol that *no* shipped module uses,
   that symbol's CRC will be missing and the build/load will fail until the table
   is regenerated. (For symbols seen with more than one CRC, the first is kept.)

4. **`depmod` segfaults on this vendor image.** Therefore the module is **not**
   in `modules.dep`: `modprobe amneziawg` will not work the usual way. Loading is
   done by the bundled `/etc/init.d/amneziawg`, which `insmod`s a *hardcoded*
   dependency list (`udp_tunnel`, `ip6_udp_tunnel`, `libchacha20poly1305`,
   `libcurve25519_generic`). If those dependency modules are renamed/moved in a
   future image, the loader must be updated.

5. **Install requires `--force-depends`, and opkg cannot verify compatibility.**
   opkg's DB advertises kernel `6.6.110` while the device actually runs `6.1.141`,
   so the package deliberately has **no `kernel (= …)` dependency**. As a result
   opkg will happily install it on an incompatible image — it simply won't load.

6. **The kernel source is fetched from the moving `nanopi6-v6.1.y` branch HEAD**,
   not pinned to the firmware's exact build commit. ABI consistency relies on the
   harvested CRCs plus currently-matching headers. If FriendlyElec changes that
   branch, re-verify the build (set `KERNEL_BRANCH`/a commit explicitly if needed).

7. **Userspace tools are not bundled.** Only `amneziawg.ko` is shipped. You still
   need `amneziawg-tools` (`awg`/`awg-quick`) and, for the LuCI/UCI protocol,
   `luci-proto-amneziawg` — these come from separate packages.

8. **Out-of-tree, unsigned module.** Loading it sets the kernel `O` (out-of-tree)
   taint flag. It is built with a different toolchain than the original kernel and
   relies on `modversions`/`vermagic` compatibility rather than a matching
   compiler. This works in practice on this image but is not vendor-supported.

In short: **treat this as a per-image build.** It is verified working on the
current NanoPi R5C FriendlyWRT image with kernel `6.1.141`; for any other kernel
or after a firmware upgrade, rebuild from this repo with that image's
`config.gz` and `Module.symvers`.

## License

This project is licensed under **GPL-2.0** (see [`LICENSE`](LICENSE)), matching
the upstream AmneziaWG / WireGuard kernel module it builds. The build and
packaging scripts in this repository are also released under GPL-2.0.

The compiled `amneziawg.ko` is a derivative of the GPL-2.0 upstream module
([amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)).
