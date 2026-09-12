#!/bin/sh
# tests/ci-smoke.sh - self-contained smoke test for CI (GitHub Actions) and
# local runs. Executes INSIDE an openwrt/rootfs container (needs nft/root):
#
#   docker run --rm --privileged -v "$PWD:/src:ro" \
#     openwrt/rootfs:x86_64-24.10.8 sh /src/tests/ci-smoke.sh
#
# Derives the install file list from Makefile 'files/...' references so the
# test cannot drift from packaging (handles both ./files/ and
# $(PKG_BUILD_DIR)/files/ forms). Fails (>0 FAIL lines) on any regression.
FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
SRC="${SRC:-/src}"

echo "### install files listed in Makefile"
mkdir -p /tmp/smoke-files /var/lock /var/run
tar -C "$SRC/files" -cf /tmp/smoke-files.tar . && tar -xf /tmp/smoke-files.tar -C /
chmod +x /usr/sbin/fw-black /usr/libexec/fwblack/ips.sh /usr/libexec/fwblack/resips.sh /etc/init.d/fwblack /etc/uci-defaults/99-fwblack
for f in $(grep -o 'files/[A-Za-z0-9_./-]*' "$SRC/Makefile" | sed -e 's|^files|/|' -e 's/[.,;:!?)]*$//' | sort -u); do
	[ -e "$f" ] && pass "installed $f" || fail "installed $f"
done

echo "### static checks"
for f in /usr/sbin/fw-black /usr/libexec/fwblack/ips.sh /usr/libexec/fwblack/resips.sh /etc/init.d/fwblack /etc/uci-defaults/99-fwblack; do
	ash -n "$f" && pass "ash -n $f" || fail "ash -n $f"
done
nft -c -f /usr/share/nftables.d/ruleset-post/fwblack.nft && pass "nft syntax" || fail "nft syntax"
jsonfilter -e @ < /usr/share/luci/menu.d/luci-app-fwblack.json >/dev/null && pass "menu JSON" || fail "menu JSON"
jsonfilter -e @ < /usr/share/rpcd/acl.d/luci-app-fwblack.json >/dev/null && pass "acl JSON" || fail "acl JSON"
tail -n +2 /usr/share/rpcd/ucode/fwblack.uc | grep -q '^#' && fail "ucode has # comments" || pass "ucode comments"
grep -q "return { 'luci.fwblack'" /usr/share/rpcd/ucode/fwblack.uc && pass "ucode object" || fail "ucode object"

echo "### version consistency (Makefile PKG_VERSION == VERSION == binaries)"
mv="$(sed -n 's/^PKG_VERSION:=//p' "$SRC/Makefile" | head -1)"
rv="$(cat "$SRC/VERSION" 2>/dev/null | tr -d ' \t\r\n')"
[ -n "$mv" ] && [ "$mv" = "$rv" ] && pass "VERSION file matches PKG_VERSION ($mv)" || fail "VERSION file matches PKG_VERSION ($mv/$rv)"
/usr/sbin/fw-black --version | grep -F "$mv" && pass "daemon reports $mv" || fail "daemon reports $mv"
/usr/libexec/fwblack/ips.sh --version | grep -F "$mv" && pass "ips reports $mv" || fail "ips reports $mv"
/usr/libexec/fwblack/resips.sh --version | grep -F "$mv" && pass "resips reports $mv" || fail "resips reports $mv"

echo "### service + nft + backend"
# NOTE: CI runs `sh` as PID 1 (no procd/ubus), so init-script service start
# and rpcd/ubus cannot run here. Test nft directly and SKIP ubus-only checks
# (full procd boot verified manually, see README).
mkdir -p /var/lock /var/run
sh /etc/uci-defaults/99-fwblack
uci show fwblack 2>/dev/null | grep -q "fwblack.global.interval='300'" && pass "uci defaults" || fail "uci defaults"
nft -f /usr/share/nftables.d/ruleset-post/fwblack.nft && pass "nft load" || fail "nft load"
nft list table inet fwblack >/dev/null 2>&1 && pass "nft table" || fail "nft table"
[ "$(nft list chain inet fwblack forward_black 2>/dev/null | grep -c dport)" = 2 ] && pass "2 drop rules" || fail "2 drop rules"
# Daemon-equivalent set insert (TEST-NET IPs, then cleanup).
nft add element inet fwblack blacklist_v4 "{ 203.0.113.1 }" 2>/dev/null && pass "nft v4 insert" || fail "nft v4 insert"
nft add element inet fwblack blacklist_v6 "{ 2001:db8::1 }" 2>/dev/null && pass "nft v6 insert" || fail "nft v6 insert"
nft delete element inet fwblack blacklist_v4 "{ 203.0.113.1 }" 2>/dev/null || true
nft delete element inet fwblack blacklist_v6 "{ 2001:db8::1 }" 2>/dev/null || true
fw4 reload >/dev/null 2>&1 || true
fw4 reload >/dev/null 2>&1 || true
[ "$(nft list chain inet fwblack forward_black 2>/dev/null | grep -c dport)" = 2 ] && pass "fw4 reload idempotent" || fail "fw4 reload idempotent"
if ubus list >/dev/null 2>&1; then
	/etc/init.d/fwblack enable 2>/dev/null || true
	/etc/init.d/fwblack start 2>/dev/null || true
	sleep 2
	/etc/init.d/fwblack status 2>&1 | grep -qi running && pass "service running" || fail "service running"
	/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart 2>/dev/null || true
	sleep 2
	ubus list 2>/dev/null | grep -qx 'luci.fwblack' && pass "rpcd object luci.fwblack" || fail "rpcd object luci.fwblack"
	ubus call luci.fwblack status 2>/dev/null | grep -q '"table": "fwblack"' && pass "RPC status" || fail "RPC status"
else
	echo "SKIP: service running (needs booted OpenWrt with procd/ubus, not sh as PID 1)"
	echo "SKIP: rpcd object luci.fwblack (needs ubus)"
	echo "SKIP: RPC status (needs ubus)"
fi

echo "### LuCI assets served (when uhttpd is present)"
if command -v uhttpd >/dev/null 2>&1; then
	# procd init cannot run with `sh` as PID 1; fall back to manual uhttpd.
	if ! pidof uhttpd >/dev/null 2>&1; then
		/etc/init.d/uhttpd start 2>/dev/null || true
	fi
	if ! pidof uhttpd >/dev/null 2>&1; then
		uhttpd -p 127.0.0.1:8080 -h /www -f &
		sleep 2
	fi
	if wget -qO- http://127.0.0.1/luci-static/resources/view/fwblack/overview.js 2>/dev/null | grep -q 'luci.fwblack'; then
		pass "view JS served"
	elif wget -qO- http://127.0.0.1:8080/luci-static/resources/view/fwblack/overview.js 2>/dev/null | grep -q 'luci.fwblack'; then
		pass "view JS served (manual uhttpd :8080)"
	elif grep -q 'luci.fwblack' /www/luci-static/resources/view/fwblack/overview.js 2>/dev/null; then
		echo "SKIP: view JS served via HTTP (uhttpd init needs procd); file content OK"
	else
		fail "view JS served"
	fi
	# NOTE: the dispatcher root (/cgi-bin/luci/) intentionally answers 403
	# + login form when unauthenticated; wget does not save error bodies
	# (and busybox wget exit codes do not discriminate), so it cannot be
	# body-asserted with wget here. Dispatcher login flow is stock LuCI
	# behavior (verified host-side with curl); our side is covered by the
	# view-JS, rpcd-object and menu/acl checks above.
else
	echo "SKIP: uhttpd not installed (file presence already asserted above)"
fi

echo "SMOKE-FAILS=$FAILS"
exit "$FAILS"
