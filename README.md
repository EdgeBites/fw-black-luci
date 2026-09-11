# fw.black — automatic DNS-based firewall blocklist (nftables)

[![ci](https://github.com/EdgeBites/fw-black-luci/actions/workflows/ci.yml/badge.svg)](https://github.com/EdgeBites/fw-black-luci/actions/workflows/ci.yml)

Maintained by [EdgeBites.com](https://EdgeBites.com) — <info@edgebites.com>.
Source: [github.com/EdgeBites/fw-black-luci](https://github.com/EdgeBites/fw-black-luci).

Blocks unwanted domains/trackers at the router by watching active
connections, reverse-resolving them, and dropping TCP 80/443 toward matches.
Runs on OpenWrt 22+ (firewall4/nftables), IPv4 + IPv6, BusyBox `sh`-clean.
Tested on OpenWrt 24.10.8 rootfs in Docker.

## How it works

Loop in `fw-black.sh` (default every `INTERVAL=300` s):

1. `ips.sh` extracts unique IPs from `/proc/net/nf_conntrack`
   (falls back to `/proc/net/ip_conntrack`), validates octets, dedupes.
2. `resips.sh` reads that list (`/tmp/ips`), skips LAN/loopback/link-local,
   runs `nslookup` per public IP, and appends the IP to `/tmp/blacklist.ips`
   when the PTR hostname literally contains any entry from `blocklist.cfg`.
3. `fw-black.sh` adds each IP in `/tmp/blacklist.ips` to an nftables set.
   One filter rule per family drops matching forwards.

Filtering is nftables set-based, not rule-per-IP:

- Table `inet fwblack` (own table, so `fw4 reload` never wipes it —
  see `fwblack.nft`), sets `blacklist_v4` (`ipv4_addr`) and
  `blacklist_v6` (`ipv6_addr`), chain `forward_black`
  (`type filter hook forward priority filter; policy accept`):
  `tcp dport { 80, 443 } ip daddr @blacklist_v4 counter drop` and the
  `ip6` counterpart. The daemon creates these idempotently and then only
  runs `nft add element …` — `nft` is never flushed globally.
- LAN/loopback/link-local/multicast (`10/8`, `172.16/12`, `192.168/16`,
  `127/8`, `::1`, `fe80::/10`, `fc00::/7`, `ff00::/8`, …) are never added.
- Matching is literal substring (`case *"$entry"*`), not regex, so dots
  in domains are safe. Appends are exact-line deduped (`grep -Fxq`).

Files:

| File | Purpose |
| --- | --- |
| `fw-black.sh` | Daemon loop, nftables setup, set inserts |
| `fwblack.nft` | Declarative ruleset for fw4 auto-include |
| `fwblack.init` | procd service definition |
| `ips.sh` | Conntrack → unique IP list |
| `resips.sh` | IP → PTR → blocklist match → append |
| `blocklist.cfg` | One domain fragment per line (literal substring match), `#` comments, blank lines ignored |

Limitations: TCP 80/443 in `FORWARD` only (no UDP/DoH, no INPUT/OUTPUT);
entries never expire (remove via `nft delete element …`); depends on
working reverse DNS; `nslookup` runs serially with a 5 s timeout.

Performance: `resips.sh` skips already-blocked IPs, caches resolutions in
`/tmp/fwblack.dnscache` (positive TTL 86400 s, negative 3600 s), and loads
`blocklist.cfg` once per cycle; the daemon inserts sets in one `nft`
call per address family and sleeps `INTERVAL` (default 300 s) plus up to
`INTERVAL_JITTER` (default 30 s). Tune via
`CACHE_TTL_POS`/`CACHE_TTL_NEG`/`CACHE_MAX`/`CACHE_FILE` env vars.

### Benchmarks (home-router scale, `openwrt/rootfs:x86_64-24.10.8` container)

| Test | Result |
| --- | --- |
| `ips.sh`, 5000 conntrack lines | 0.06 s → 1401 unique IPs (invalid `999.*` rejected, IPv6 kept) |
| `resips.sh` cold, 200 IPs / 20 public, 50 ms mock DNS | 0.11 s, 20 DNS calls → 2 blocked |
| `resips.sh` warm, same input | 0.09 s, 0 new DNS calls, file idempotent |
| Serial proof, 3 IPs × 1 s DNS | 3.01 s cold → 0.00 s warm (negative cache; serial by design for low CPU) |
| Daemon batch, 50 v4 + 20 v6, real nft (privileged) | all 70 in sets after ~2 cycles, 1 `nft` call per family/cycle |
| Steady state (warm cache + idempotent re-add of 70) | 0.10 s + 0.00 s, 0 DNS calls |

Notes: BusyBox `sleep` ignores fractional seconds (benchmarks use integer
delays); DNS is the dominant cost cold, cache makes the steady state ~free.

### Package (new) vs legacy (old) benchmarks

Method: same `openwrt/rootfs:x86_64-24.10.8` privileged container, BusyBox
`ash`/`awk`, identical inputs, interleaved runs, `/proc/uptime` ms timer
(10 ms resolution). Old = root `fw-black.sh`/`ips.sh`/`resips.sh`;
new = packaged `files/` copies. All outputs verified byte-equivalent
(`ips` list, blocked list, nft set contents).

| Test | Old (legacy) | New (package) | Verdict |
| --- | --- | --- | --- |
| `ips.sh`, 5000 conntrack lines → 1445 unique IPs (10×) | med 125 ms | med 120 ms | parity (logic unchanged) |
| `resips.sh` cold, 200 IPs / 20 public, ~45 ms mock DNS (3×) | med 1530 ms, 20 DNS calls | med 1550 ms, 20 DNS calls | parity (+1.3%, timer noise) |
| `resips.sh` warm, 0 new DNS (8×) | med 110 ms | med 110 ms | identical |
| `resips.sh`, 5 public IPs × 1 s DNS | cold 5040 ms → warm 20 ms, 5 calls total | cold 5040 ms → warm 20 ms, 5 calls total | identical |
| Daemon single cycle incl. startup + `nft_init` + 70-IP batch (5×) | med 50 ms | med 40 ms | no startup regression |
| `nft -f` ruleset load (10×, delete untimed) | med 0 ms (all ≤10 ms) | med 0 ms (all ≤10 ms) | parity; the 2 idempotency statements are unmeasurable |

New-only (no legacy counterpart — ubus round-trip incl. CLI spawn):

| RPC (`luci.fwblack`) | Latency |
| --- | --- |
| `status`, `blocked` (20 IPs) | ≤10 ms |
| `log` (50 lines) | ≤10 ms |
| `lookup` (1× real DNS, `8.8.8.8 → dns.google`) | 10–40 ms (DNS-bound; dnsmasq-cached hits ~10 ms) |

Expected: the package refactor touched only once-per-startup/per-run
preamble (path resolution, UCI hand-off); the per-IP hot loop is
byte-identical, so parity is the correct result — confirmed.

## Install (recommended: OpenWrt package)

This repo is a single OpenWrt package (`Makefile` at root, install files
under `files/`). It builds two `.ipk`s: `fwblack` (daemon + UCI + nft) and
`luci-app-fwblack` (LuCI UI).

```sh
# Inside an OpenWrt buildroot / SDK (24.10+):
git clone https://github.com/EdgeBites/fw-black-luci.git package/fwblack
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # select Network -> Firewall -> fwblack, LuCI -> Applications -> luci-app-fwblack
make package/fwblack/compile V=s
opkg install bin/packages/*/base/fwblack_*.ipk bin/packages/*/luci/luci-app-fwblack_*.ipk
```

On the router:

```sh
service fwblack enable && service fwblack start
fw4 reload   # picks up /usr/share/nftables.d/ruleset-post/fwblack.nft
uci show fwblack
nft list table inet fwblack
```

Configure via UCI (hybrid: settings in UCI, domains stay a flat file):

```sh
uci set fwblack.global.interval='120'
uci commit fwblack && service fwblack reload
vi /etc/fwblack/blocklist.cfg && service fwblack reload
# or edit in LuCI: Network -> fw.black (daemon settings, blocklist editor
# with validation, blocked-IP management, reverse-DNS tester, log viewer,
# service control)
```

Layout installed by the package:

| Path | Purpose |
| --- | --- |
| `/usr/sbin/fw-black` | Daemon (UCI env from init, falls back to defaults) |
| `/usr/libexec/fwblack/{ips,resips}.sh` | Helpers |
| `/etc/config/fwblack` | UCI settings (conffile) |
| `/etc/fwblack/blocklist.cfg` | Domains, one per line (conffile) |
| `/etc/init.d/fwblack` | UCI-driven procd service + `service_triggers()` |
| `/usr/share/nftables.d/ruleset-post/fwblack.nft` | fw4 auto-include (flush-safe, reload-idempotent) |
| LuCI view/ACL/ucode backend | `Network -> fw.black` in the web UI (`view/fwblack/overview.js`, `menu.d` + `acl.d`, ubus object `luci.fwblack` in `ucode/fwblack.uc`) |
| LuCI view/ACL/menu | `Network -> fw.black` in the web UI |

Legacy `/etc/fw.black/*` installs are auto-migrated on first install
(`postinst` + `files/etc/uci-defaults/99-fwblack`): a legacy blocklist wins
over the packaged default (saved as `blocklist.cfg.ppkg-default`), guarded by
a one-shot marker so later upgrades never clobber user edits.

## Install (manual, no buildroot)

```sh
# 1. Copy files to the router
scp fw-black.sh ips.sh resips.sh blocklist.cfg fwblack.nft root@router:/etc/fw.black/
ssh root@router 'chmod +x /etc/fw.black/fw-black.sh /etc/fw.black/ips.sh /etc/fw.black/resips.sh'

# 2. Make the ruleset survive fw4 reloads/reboots
ssh root@router 'mkdir -p /etc/nftables.d/ruleset-post && cp /etc/fw.black/fwblack.nft /etc/nftables.d/ruleset-post/fwblack.nft && fw4 reload'

# 3. Edit the domains you want blocked
ssh root@router 'vi /etc/fw.black/blocklist.cfg'
```

## Run as a service (procd, auto-start on boot)

Package install (UCI):

```sh
service fwblack enable && service fwblack start
service fwblack status; logread -e fwblack | tail -20
nft list table inet fwblack; nft list set inet fwblack blacklist_v4; nft list set inet fwblack blacklist_v6
uci set fwblack.global.interval='120'; uci commit fwblack; service fwblack reload
```

Manual install (legacy `fwblack.init`):

```sh
scp fwblack.init root@router:/etc/init.d/fwblack
ssh root@router 'chmod +x /etc/init.d/fwblack'
ssh root@router 'service fwblack enable && service fwblack start'
ssh root@router 'service fwblack status; logread -e fwblack | tail -20'
ssh root@router 'nft list table inet fwblack; nft list set inet fwblack blacklist_v4; nft list set inet fwblack blacklist_v6'

# Optional: change the scan interval (seconds, default 300) — add an
# env line inside start_service() in /etc/init.d/fwblack, before
# procd_close_instance, then restart:
#   procd_set_param env INTERVAL=120
ssh root@router 'vi /etc/init.d/fwblack && service fwblack restart'
```

Manual run (no service):

```sh
ssh root@router '/etc/fw.black/fw-black.sh &'
```

Uninstall:

```sh
ssh root@router 'service fwblack stop; service fwblack disable; rm /etc/init.d/fwblack /etc/nftables.d/ruleset-post/fwblack.nft; nft delete table inet fwblack; fw4 reload'
```

## Verify / troubleshoot

```sh
ash -n /usr/sbin/fw-black && ash -n /usr/libexec/fwblack/ips.sh && ash -n /usr/libexec/fwblack/resips.sh
nft -c -f /usr/share/nftables.d/ruleset-post/fwblack.nft && echo NFT-OK
CONNTRACK_FILE=/tmp/ips BLACKLIST=/etc/fwblack/blocklist.cfg BLKIPS=/tmp/blacklist.ips /usr/libexec/fwblack/resips.sh
logread -e fwblack | tail -20
# LuCI: Network -> fw.black renders view fwblack/overview (JS served at
# /luci-static/resources/view/fwblack/overview.js); menu + ACL at
# /usr/share/luci/menu.d/luci-app-fwblack.json and
# /usr/share/rpcd/acl.d/luci-app-fwblack.json; backend ubus object
# luci.fwblack (/usr/share/rpcd/ucode/fwblack.uc) with methods
# status/blocked/unblock/lookup/log/svc/cache_clear
```

Verified 2026-09-11 in `openwrt/rootfs:x86_64-24.10.8` (privileged Docker):
`ash -n` clean on all scripts, `nft -c -f` OK, procd start OK
(`ubus call service list` shows `fwblack` running with UCI env),
`fw4 reload` auto-includes the nft file and stays at exactly 2 drop rules
after repeated reloads, mock `resips.sh` blocks `scorecardresearch.com`
hits and skips LAN, `nft add element` populates `blacklist_v4`,
LuCI login page HTTP 200 and `overview.js` HTTP 200.

Full editor verified 2026-09-11 (ubus object `luci.fwblack`, all 7 methods):
`status`/`blocked` counts, `lookup 8.8.8.8 → dns.google, not blocked`,
`unblock` removes an IP from both `/tmp/blacklist.ips` and the nft set
(invalid IPs and shell metachars rejected), `svc reload` restarts the daemon
(new pid, still running), `cache_clear` wipes the DNS cache, `log` reads
logd (grep filter covers the hyphenated `fw-black:` tag, which `-e fwblack`
would miss). JS passes `node --check`; repo and container md5-identical.

Common issues: empty sets → reverse DNS failing or no conntrack traffic;
`nft: Operation not permitted` → needs root/`CAP_NET_ADMIN`; custom
`inet fw4` rules disappearing → expected, this project uses its own
`inet fwblack` table precisely to avoid that.

## Contributing (openwrt/packages conformance)

Packaging follows
[openwrt/packages CONTRIBUTING.md](https://github.com/openwrt/packages/blob/master/CONTRIBUTING.md):
SPDX `PKG_LICENSE`, `PKG_LICENSE_FILES`, `PKGARCH:=all`, feed indentation
rules (two spaces metadata, tabs in `install`, none in `conffiles`/scriptlets),
procd init, registered `conffiles`, and CI scripts next to the `Makefile`
(`test.sh`, `test-version.sh`, `pre-test.sh`). `test*.sh` avoid `grep -q`
so matches stay visible in CI logs.

Release checklist (keep in sync, then see CI badge in `.github/workflows`):

- `PKG_VERSION` (`Makefile`) == `VERSION` (repo root) == `VERSION='…'` in
  `fw-black.sh`, `ips.sh`, `resips.sh`,
  `files/usr/sbin/fw-black`, `files/usr/libexec/fwblack/*.sh`.
- Version bump → reset `PKG_RELEASE:=1`; package-only change →
  increment `PKG_RELEASE`.

Submitting upstream:

1. Upstream is `https://github.com/EdgeBites/fw-black-luci`
   (maintainer `EdgeBites.com <info@edgebites.com>`).
2. Copy this directory to `net/fwblack/` in a fork of
   `openwrt/packages`.
3. Open a PR titled `net/fwblack: add new package` with `Signed-off-by`
   (real name + real email, see
   [Sign your work](https://openwrt.org/submitting-patches#sign_your_work)).

## Support

- Homepage: [https://EdgeBites.com](https://EdgeBites.com)
- Contact: <info@edgebites.com>
- Issues: [github.com/EdgeBites/fw-black-luci/issues](https://github.com/EdgeBites/fw-black-luci/issues)
- Security: see [SECURITY.md](SECURITY.md) — please email
  <info@edgebites.com> instead of opening a public issue.
