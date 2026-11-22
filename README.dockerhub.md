# nginx — Official nginx with ModSecurity, Brotli, Zstandard and GeoIP2 Modules

**Maintained by [morsalin1342](https://hub.docker.com/u/morsalin1342)** · [GitHub](https://github.com/morsalin1342/nginx-docker)

[![Docker Pulls](https://img.shields.io/docker/pulls/morsalin1342/nginx?style=for-the-badge&logo=docker)](https://hub.docker.com/r/morsalin1342/nginx)
[![Image Size](https://img.shields.io/docker/image-size/morsalin1342/nginx/latest?style=for-the-badge&logo=docker)](https://hub.docker.com/r/morsalin1342/nginx/tags)
[![GitHub Stars](https://img.shields.io/github/stars/morsalin1342/nginx-docker?style=for-the-badge&logo=github)](https://github.com/morsalin1342/nginx-docker)
[![License](https://img.shields.io/github/license/morsalin1342/nginx-docker?style=for-the-badge)](https://github.com/morsalin1342/nginx-docker/blob/master/LICENSE)

Official nginx plus **ModSecurity 3**, **Brotli**, **Zstandard**, **headers-more**, **GeoIP2**,
**VTS**, **cache-purge**, **fancyindex**, **upload-progress** and **OpenTelemetry**, as dynamic
modules. The image *is* the official `nginx` image — the modules are compiled
separately and loaded into the stock binary, so nginx's own security updates arrive on
nginx's schedule, not this repository's.

**Platform:** linux/amd64 only. `morsalin1342/nginx` and `easydigital/nginx` are the same image, pushed by the same build with the same digest; pull whichever you prefer.

## ✨ Why This Image?

| Feature | Official image | This image |
|---|---|---|
| **Web application firewall** | ❌ | ✅ ModSecurity 3 + OWASP CRS, shipped off by default |
| **Brotli / Zstandard** | ❌ | ✅ Both, negotiated per client |
| **Per-vhost metrics** | `stub_status` — 7 global counters | ✅ VTS, Prometheus format |
| **GeoIP** | Legacy databases only | ✅ GeoIP2 `.mmdb`, http and stream |
| **Header removal** | ❌ | ✅ headers-more |
| **Single-entry cache purge** | Zone-wide expiry only | ✅ cache-purge |
| **OpenTelemetry** | ❌ | ✅ From nginx's own package repo |
| **nginx itself rebuilt?** | — | ❌ Stock binary, modules load dynamically |

## Quick Start

```bash
docker run -d --name nginx \
    -p 80:80 -p 443:443 \
    -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro \
    morsalin1342/nginx:latest
```

This image's modules are loaded and **every one of them does nothing until you configure it.**
The official image's own dynamic modules (njs, image_filter, xslt, geoip, acme) stay unloaded,
as they are there. Drop-in replacement for `nginx:<version>` until you use one.

> **If you replace `/etc/nginx/nginx.conf`**, keep this line at the top — `load_module` is only
> valid in nginx's main context, so it cannot live in `conf.d/`, and without it none of the
> modules below exist:
>
> ```nginx
> include /etc/nginx/modules-enabled/*.conf;
> ```
>
> Mounting into `conf.d/` instead needs no such care.

## What's Included

| Module | Directive to start with | Why it is not already in nginx |
|---|---|---|
| ModSecurity 3 | `modsecurity on;` | nginx ships no WAF |
| Brotli | `brotli on;` | nginx has gzip only |
| Zstandard | `zstd on;` | nginx has gzip only; zstd is negotiated by Chrome 123+ and Firefox 126+ |
| VTS | `vhost_traffic_status on;` | per-vhost metrics in Prometheus format; `stub_status` is seven global counters |
| headers-more | `more_clear_headers Server;` | nginx cannot unset arbitrary headers |
| GeoIP2 (http **and** stream) | `geoip2 /path/db.mmdb { … }` | nginx's own GeoIP module reads only the legacy databases MaxMind stopped publishing |
| cache-purge | `proxy_cache_purge PURGE from …;` | open-source nginx can only expire a whole cache zone |
| fancyindex | `fancyindex on;` | `autoindex` output is unstyleable |
| upload-progress | `upload_progress proxied 1m;` | upload progress polling |
| OpenTelemetry | `otel_trace on;` | OTLP/gRPC tracing — installed from nginx's own package repo |

Already in official nginx and therefore **not** duplicated here: rate limiting (`limit_req`),
connection limiting, `real_ip`, HTTP/2, HTTP/3, gzip, `sub_filter`, `secure_link`,
`auth_request`, `map`, `geo`.

## ModSecurity

The OWASP Core Rule Set, ModSecurity's `modsecurity.conf` and a `main.conf` that loads them ship
at `/etc/nginx/modsecurity/`, and **nothing loads them.** That is deliberate: CRS in blocking
mode has a real false-positive cost against application admin panels, and the exclusions are
site-specific. Enabling it, and choosing detection or blocking, is yours.

```nginx
http {
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;
}
```

`main.conf` includes `modsecurity.conf` (ModSecurity's `modsecurity.conf-recommended`, copied
unchanged from the v3.0.17 source the library was built from), then `crs-setup.conf`, then the
CRS rules, with `SecRuleEngine DetectionOnly`: matches are written to the audit log, nothing is
blocked.
`modsecurity.conf` keeps ModSecurity's rules `200002` and `200003`, which reject request bodies
that fail to parse or break strict multipart parsing; CRS cannot inspect those bodies otherwise.
The audit log is `/var/log/modsec_audit.log` inside the container, as
`modsecurity.conf` sets it; it records requests that matched a rule or got a 5xx or a 4xx other
than 404.

Read your logs before blocking anything. To block, add one line **before**
`modsecurity_rules_file`, in the same block:

```nginx
    modsecurity on;
    modsecurity_rules 'SecRuleEngine On';
    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;
```

Before, not after: when one block sets `SecRuleEngine` twice, the connector keeps the first
value it loads, so a line after `main.conf` leaves it in `DetectionOnly`.

To change anything else, mount your own `main.conf` (or `crs-setup.conf`) over the shipped one.

`modsecurity` defaults to **off** in the connector itself, so the module being loaded changes
nothing until you say otherwise.

The connector also provides `modsecurity_rules_file`, `modsecurity_rules_remote`,
`modsecurity_rules`, `modsecurity_use_error_log` and `modsecurity_transaction_id`. The last is
worth knowing: paired with `$request_id` in your `log_format`, it lets you correlate an access
log line with the error log entry the WAF wrote for the same request.

## Available Tags

`<nginx-version>` and `latest`. The tag names the **upstream nginx release** the image is
built on, and is republished when this repository's Dockerfile changes — a module bump or a
CRS update can land under an unchanged nginx version. Pin by digest if you need immutability.

## Verifying the Build

```bash
docker run --rm morsalin1342/nginx:latest nginx -V
docker run --rm morsalin1342/nginx:latest nginx -t
```

Every published image runs `nginx -t` with every module loaded at build time, checks the WAF
configuration in a throwaway copy, and starts nginx and serves a request, so a module built
against a mismatched nginx fails the build rather than a running server.

## ❓ FAQ

**Q: Why does nothing happen after I pull it?**
A: This image's modules are loaded and every one does nothing until configured; the official image's own dynamic modules stay unloaded. Until you write a directive this is a drop-in replacement for `nginx:<version>`.

**Q: I replaced nginx.conf and the modules vanished.**
A: `load_module` is only valid in the main context. Keep `include /etc/nginx/modules-enabled/*.conf;` at the top of your file, or mount into `conf.d/` instead.

**Q: GeoIP2 returns my default for everything.**
A: No database ships with the image — MaxMind requires an account. Mount a `.mmdb` and point `geoip2` at it.

## Licence

The repository's build files are MIT. nginx (BSD-2-Clause), ModSecurity and the OWASP CRS
(Apache-2.0) and the other modules keep their own licences; the
[Licence section](https://github.com/morsalin1342/nginx-docker#licence) lists them.

---

### 🔗 Related Images & Tools

<!-- BEGIN GENERATED: related (from manifest/images.yaml in the morsalin1342/.github repository; do not edit by hand) -->
| Image / Tool | Description |
|--------------|-------------|
| [morsalin1342/caddy](https://hub.docker.com/r/morsalin1342/caddy) | Standalone Caddy with WAF, rate limiting & caching |
| [morsalin1342/frankenphp](https://hub.docker.com/r/morsalin1342/frankenphp) | Caddy + PHP app server in one container |
| [morsalin1342/php](https://hub.docker.com/r/morsalin1342/php) | Traditional PHP-FPM & CLI images |
| [morsalin1342/apache](https://hub.docker.com/r/morsalin1342/apache) | Apache as a static server or php-fpm application server, no PHP inside |
| [morsalin1342/adminer](https://hub.docker.com/r/morsalin1342/adminer) | Adminer database tool: the official image plus Alpine security updates |
| [easydigital/nginx](https://hub.docker.com/r/easydigital/nginx) | Same image, organization namespace |
<!-- END GENERATED: related -->

---

⭐ **If this image helps you, consider giving it a star on [GitHub](https://github.com/morsalin1342/nginx-docker)!**
