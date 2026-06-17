#!/usr/bin/env bash
#
# Generate an opkg package feed (Packages / Packages.gz + a landing page)
# from the built .ipk(s) in dist/. Output goes to public/ for GitHub Pages.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST:-$ROOT/dist}"
PUB="${PUB:-$ROOT/public}"
PAGES_URL="${PAGES_URL:-https://lastharbor.github.io/kmod-amneziawg-nanopi-r5c}"

[ -n "$(ls "$DIST"/*.ipk 2>/dev/null)" ] || { echo "ERROR: no .ipk in $DIST"; exit 1; }

rm -rf "$PUB"
mkdir -p "$PUB"
cp "$DIST"/*.ipk "$PUB"/

cd "$PUB"
: > Packages
for ipk in *.ipk; do
	ctrl="$(tar -xzOf "$ipk" control.tar.gz | tar -xzO ./control)"
	size="$(wc -c < "$ipk")"
	sha="$(sha256sum "$ipk" | cut -d' ' -f1)"
	# control fields first (drop any blank lines), then feed-specific fields
	printf '%s\n' "$ctrl" | sed '/^[[:space:]]*$/d' >> Packages
	printf 'Filename: %s\n' "$ipk" >> Packages
	printf 'Size: %s\n' "$size" >> Packages
	printf 'SHA256sum: %s\n' "$sha" >> Packages
	printf '\n' >> Packages
done
gzip -fk Packages

VER="$(awk -F': ' '/^Version:/{print $2; exit}' Packages)"

cat > index.html <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>kmod-amneziawg for NanoPi R5C (FriendlyWRT 6.1.141)</title>
<style>
 body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:820px;margin:2rem auto;padding:0 1rem;line-height:1.55;color:#1b1f23}
 code,pre{background:#f6f8fa;border-radius:6px}
 pre{padding:1rem;overflow:auto}
 code{padding:.15em .35em}
 h1{font-size:1.6rem} a{color:#0969da}
 .pill{display:inline-block;background:#0969da;color:#fff;border-radius:999px;padding:.1rem .6rem;font-size:.8rem}
</style>
</head>
<body>
<h1>kmod-amneziawg <span class="pill">$VER</span></h1>
<p>AmneziaWG kernel module (with <strong>I1/CPS</strong>) for the FriendlyElec
vendor kernel <code>6.1.141</code> on the NanoPi R5C (RK3568, aarch64).</p>

<h2>Install as an opkg feed</h2>
<pre>echo 'src/gz awg_nanopi $PAGES_URL' >> /etc/opkg/customfeeds.conf
opkg update
opkg install --force-depends kmod-amneziawg</pre>

<h2>Or install the .ipk directly</h2>
<pre>opkg install --force-depends $PAGES_URL/$(ls *.ipk | head -1)</pre>
<p><code>--force-depends</code> is required: opkg's DB advertises kernel 6.6.110
while the device runs 6.1.141, so the package carries no <code>kernel(=)</code>
dependency on purpose.</p>

<p>Source &amp; build details:
<a href="https://github.com/lastharbor/kmod-amneziawg-nanopi-r5c">github.com/lastharbor/kmod-amneziawg-nanopi-r5c</a></p>
</body>
</html>
HTML

echo "feed generated in $PUB:"
ls -la "$PUB"
echo "--- Packages ---"; cat Packages
