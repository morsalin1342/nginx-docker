# Production-Ready nginx Docker Image with Essential Modules

[![Docker Pulls](https://img.shields.io/docker/pulls/morsalin1342/nginx.svg?style=for-the-badge&logo=docker)](https://hub.docker.com/r/morsalin1342/nginx)
[![GitHub Stars](https://img.shields.io/github/stars/morsalin1342/nginx-docker?style=for-the-badge&logo=github)](https://github.com/morsalin1342/nginx-docker)
[![License](https://img.shields.io/github/license/morsalin1342/nginx-docker?style=for-the-badge)](https://github.com/morsalin1342/nginx-docker/blob/master/LICENSE)

Official nginx plus the modules it does not ship — **ModSecurity 3**, **Brotli**,
**Zstandard**, **headers-more**, **GeoIP2**, **VTS** and **OpenTelemetry** — built as
dynamic modules.

```bash
docker pull morsalin1342/nginx:latest
```

## ✨ Why This Image?

| Feature | Official `nginx` | This Image |
|---------|-----------------|------------|
| **Web application firewall** | ❌ | ✅ ModSecurity 3 + OWASP CRS (shipped, off by default) |
| **Brotli compression** | ❌ | ✅ |
| **Zstandard compression** | ❌ | ✅ negotiated alongside Brotli |
| **Per-vhost metrics** | `stub_status` — 7 global counters | ✅ VTS, Prometheus format |
| **GeoIP** | legacy databases only | ✅ GeoIP2 `.mmdb`, http **and** stream |
| **Arbitrary header removal** | ❌ | ✅ headers-more |
| **Single-entry cache purge** | zone-wide expiry only | ✅ cache-purge |
| **OpenTelemetry tracing** | ❌ | ✅ from nginx's own package repo |
| **nginx itself rebuilt?** | — | ❌ stock binary; modules load dynamically |

## What this is, and what it is not

The published image **is** the official `nginx` image. The modules are compiled in separate
builder stages and copied in as `.so` files; nginx itself is never rebuilt.

That is the whole design decision. Compiling nginx from source would put nginx's own security
updates on this repository's release schedule instead of upstream's. Here a new nginx patch
release is a one-line version bump and a rebuild of nine shared objects.

It works because the official image is configured `--with-compat`, which nginx documents as
enabling *"dynamic modules compatibility"*: a module built with a different `./configure` line
still loads into the stock binary. Without it, the module signature would have to match the
official image's entire configure invocation exactly, and any drift would be a runtime
failure on a live server.

The builder stage runs `make modules`, not `make` — only the `.so` files are compiled, and
the nginx binary it could have produced is discarded.

## Included

| Module | Version | Why it is not already in nginx |
|---|---|---|
| [ModSecurity 3](https://github.com/owasp-modsecurity/ModSecurity) + [connector](https://github.com/owasp-modsecurity/ModSecurity-nginx) | v3.0.16 / v1.0.4 | nginx ships no WAF |
| [ngx_brotli](https://github.com/google/ngx_brotli) | pinned commit | nginx has gzip and no Brotli |
| [zstd-nginx-module](https://github.com/tokers/zstd-nginx-module) | 0.1.1 | likewise; negotiated alongside Brotli, not instead of it |
| [VTS](https://github.com/vozlt/nginx-module-vts) | v0.2.7 | per-vhost metrics in Prometheus format; `stub_status` is seven global counters |
| [headers-more](https://github.com/openresty/headers-more-nginx-module) | v0.40 | nginx cannot unset an arbitrary response header |
| [GeoIP2](https://github.com/leev/ngx_http_geoip2_module) (http **and** stream) | 3.4 | nginx's own GeoIP module reads only the legacy databases MaxMind stopped publishing. **Bring your own `.mmdb`** — see below |
| [cache-purge](https://github.com/nginx-modules/ngx_cache_purge) | 3.0.2 | invalidating a single `proxy_cache` entry; nginx open source can only expire the whole zone |
| [fancyindex](https://github.com/aperezdc/ngx-fancyindex) | v0.6.0 | themed directory listings; `autoindex` output is unstyleable |
| [upload-progress](https://github.com/masterzen/nginx-upload-progress-module) | v0.9.4 | upload progress polling |
| [ngx_otel_module](https://github.com/nginxinc/nginx-otel) | 0.1.2 | OTLP/gRPC tracing — **from nginx's own package repo**, not built here |
| [OWASP CRS](https://github.com/coreruleset/coreruleset) | v4.29.0 | shipped, **not loaded** |

`ngx_brotli` publishes no releases, so it is pinned to a commit rather than a branch. An
unpinned dependency in a WAF-bearing image is a change nobody reviewed arriving under a tag
already published.

## Deliberately absent

These are **already in the official image** — verified against `nginx -V` — and adding them
would be duplication:

`limit_req` (rate limiting) · `limit_conn` · `real_ip` · HTTP/2 · HTTP/3 · gzip ·
`gzip_static` · `sub_filter` · `secure_link` · `auth_request` · `map` · `geo` · `slice` ·
`stream` with `ssl_preread`

**Mail** is complete already: `--with-mail` and `--with-mail_ssl_module` are compiled into the
official image, which is all eight of `mail_core`, `mail_auth_http`, `mail_proxy`,
`mail_realip`, `mail_ssl`, `mail_imap`, `mail_pop3` and `mail_smtp`.

**Stream** likewise, apart from GeoIP2's stream variant which this image adds: `stream_core`,
`stream_access`, `stream_geo`, `stream_geoip`, `stream_js`, `stream_limit_conn`, `stream_log`,
`stream_map`, `stream_pass`, `stream_proxy`, `stream_realip`, `stream_return`, `stream_set`,
`stream_split_clients`, `stream_ssl`, `stream_ssl_preread` and `stream_upstream`.

And these cannot be added to any open-source build, being NGINX Plus only — verified against
nginx.org, each of which documents itself as *"part of our commercial subscription"*:

- **HTTP:** `api`, `auth_jwt`, `f4f`, `hls`, `keyval`, `mp4_*`, `oidc`, `session_log`,
  `status`, `upstream_conf`
- **Stream:** `keyval`, `mqtt_preread`, `mqtt_filter`, `num_map`, `proxy_protocol_vendor`,
  `upstream_hc`, `zone_sync`

Two of those shape what open-source nginx can do and are worth knowing before you plan around
them: **`stream_zone_sync`** replicates shared zones between instances, so multi-node rate
limiting needs a different design here; and **`upstream_hc`** is *active* health checking —
open-source nginx has only the passive `max_fails`/`fail_timeout`.

## GeoIP2 needs a database you supply

The module is built in; **no database ships with it.** MaxMind requires a free account and a
licence key to download GeoLite2, and redistributing the `.mmdb` here would be neither legal
nor current.

Without one, `geoip2` variables silently return whatever `default=` you set — which looks like
the module working. Mount a database and point at it:

```nginx
geoip2 /etc/maxmind/GeoLite2-Country.mmdb {
    auto_reload 5m;                    # picks up database updates without a reload
    $geoip2_country_code default=ZZ source=$remote_addr country iso_code;
}
```

`geoip2_proxy` and `geoip2_proxy_recursive` exist for when nginx sits behind a proxy and
`$remote_addr` is not the client.

## Nothing is enabled by default

Every module is loaded and every one of them does nothing until configured. Until you write a
directive, this is a drop-in replacement for `nginx:<version>`.

ModSecurity in particular stays off. The Core Rule Set ships at `/etc/nginx/modsecurity/` and
nothing includes it — CRS in blocking mode has a real false-positive cost against application
admin panels, and the exclusions for that are site-specific. Start in `DetectionOnly`, read
your logs, then decide.

## Building Locally

```bash
docker build -t nginx-custom .
docker run --rm nginx-custom nginx -V
docker run --rm nginx-custom nginx -t
```

Overridable at build time: `NGINX_VERSION`, `DEBIAN_RELEASE`, `MODSECURITY_VERSION`,
`MODSECURITY_NGINX_VERSION`, `HEADERS_MORE_VERSION`, `GEOIP2_VERSION`, `VTS_VERSION`,
`NGX_BROTLI_COMMIT`, `ZSTD_MODULE_VERSION`, `ZSTD_VERSION`, `CRS_VERSION`,
`OTEL_MODULE_VERSION`, `FANCYINDEX_VERSION`, `CACHE_PURGE_VERSION`, `UPLOAD_PROGRESS_VERSION`.

The final stage runs `nginx -t` with every module loaded **and then starts nginx and serves a
request**, so a module built against a mismatched nginx fails **the build** rather than a
customer's server at start time.

## Tags

`<nginx-version>` and `latest`, published on push to `master`.

The tag names the **upstream nginx release**, not a build of this repository — so it is
republished when the Dockerfile changes. A module bump or a CRS update can land under an
unchanged nginx version. **Pin by digest if you need immutability.**

## Why there is no Lua

Lua and the OpenResty toolkit — `lua-nginx-module` on LuaJIT, plus `ngx_devel_kit`,
`set-misc`, `echo`, `redis2`, `srcache` and `memc` — were built here and **removed on
2026-08-31**. They worked; they were dropped because nothing needed them.

The reasoning is worth recording, because "it builds cleanly" is a weak argument for shipping
something. This image's job is to be a **gateway**: terminate TLS, route, filter, compress,
report. `srcache`, `redis2` and `memc` cache responses into Redis or memcached, which is
*application*-tier work that belongs to whatever server sits behind the gateway. `echo` and
`set-misc` are conveniences for writing that kind of logic in configuration. And Lua is the
general answer to "what if we need to do something nginx cannot express" — a real capability,
but one that pulls a second language runtime, a version-pairing constraint tight enough to
break a build, and roughly 10MB of LuaJIT into every pull, in exchange for a need nobody has
articulated yet.

If that need arrives, the modules go back: each is a version pin, a clone and a
`--add-dynamic-module` line. Carrying them *before* it arrives is how an image accumulates
surface that nobody can later justify removing.

## Why the OTel module is installed, not compiled

Every other module here is built from source because upstream nginx does not package it.
`ngx_otel_module` is the exception: nginx publishes `nginx-module-otel` in **the same
repository the official image installs nginx from**, built against that exact binary. The
compatibility question `--with-compat` exists to answer does not arise for it at all.

Compiling it instead would pull gRPC, protobuf and opentelemetry-cpp in through CMake — a long
build and a large dependency surface, for a worse binary-compatibility story than the artifact
upstream already ships. The version is pinned as `<nginx>+<module>-1~<release>`, so a
mismatched pair is refused by apt rather than loaded.

## Debian, not Alpine

ModSecurity's dependency set — yajl, lmdb, libxml2, curl — is better served by glibc, and
musl builds of it are a known source of subtle breakage.

## Why ModSecurity and not ngx_waf

`ngx_waf` was considered. It is ModSecurity-compatible and adds things this image otherwise
lacks — rate-based automatic IP banning, verified-crawler allowlisting for Google/Bing/Baidu/
Yandex, and hCaptcha/reCAPTCHA support — which together cover what a Caddy build gets from
its rate-limit and defender modules.

It was declined on maintenance. Its last upstream commit is January 2025 and the packaged
release most distributions carry is v10.1.2 from July 2022. **For a firewall specifically,
that is disqualifying in a way it would not be for a compression module** — and it pulls in
libsodium, libcurl, cJSON, uthash and libinjection, widening the attack surface of the thing
meant to reduce it.

ModSecurity 3 is actively maintained and OWASP-governed, which is the one property a WAF
cannot trade away. Its missing features have better-targeted answers: `limit_req` is built
into nginx for rate limiting, and crawler verification or CAPTCHA belong in a module chosen
for that job.

## ❓ FAQ

**Q: How do I turn the WAF on?**
A: Load the module (already loaded), point `modsecurity_rules_file` at a file that includes
`crs-setup.conf` and `rules/*.conf`, then set `modsecurity on;`. Start in `DetectionOnly`,
read your logs, and only then switch to blocking — CRS has a real false-positive cost against
application admin panels, WordPress's `/wp-admin` in particular.

**Q: I replaced `/etc/nginx/nginx.conf` and all the modules vanished. Why?**
A: `load_module` is only valid in nginx's main context, so it cannot live in `conf.d/`. The
image adds one include line to `nginx.conf`; if you replace that file, keep it:
```nginx
include /etc/nginx/modules-enabled/*.conf;
```
Mounting into `conf.d/` instead needs no such care.

**Q: GeoIP2 returns my `default=` value for every request.**
A: No database ships with the image — MaxMind requires an account and licence key, and
redistributing the `.mmdb` here would be neither legal nor current. Mount one and point
`geoip2` at it. See the GeoIP2 section above.

**Q: Why is nothing enabled by default?**
A: Every module is loaded and every one does nothing until configured, so this is a drop-in
replacement for `nginx:<version>` until you write a directive. Enabling a WAF, or choosing
detection versus blocking, belongs to whoever runs the server.

**Q: Can I use this with PHP?**
A: Yes — pair it with [morsalin1342/php](https://hub.docker.com/r/morsalin1342/php) over
FastCGI. For a single-container Caddy+PHP app server instead, use
[morsalin1342/frankenphp](https://hub.docker.com/r/morsalin1342/frankenphp).

**Q: How do I add a module that isn't here?**
A: Fork the repo, pin it to a tag or commit, and add an `--add-dynamic-module` line to the
modules stage. See CONTRIBUTING.md — and check the "Deliberately absent" list first, because
nginx may already do it.

## License

MIT for this repository's build files. The software it packages keeps its own licences: nginx
(BSD-2-Clause), ModSecurity (Apache-2.0), OWASP CRS (Apache-2.0), Brotli (MIT), headers-more
(BSD-2-Clause), ngx_http_geoip2_module (BSD-2-Clause).

---

## Related Images & Tools

Every image is published to both the personal and the organization namespace, from the same build.

| Repository | Images | Description |
|---|---|---|
| [caddy-docker](https://github.com/morsalin1342/caddy-docker) | `morsalin1342/caddy` · `easydigital/caddy` | Standalone Caddy with WAF, rate limiting & caching |
| [frankenphp-docker](https://github.com/morsalin1342/frankenphp-docker) | `morsalin1342/frankenphp` · `easydigital/frankenphp` | Caddy + PHP app server in one container |
| [php-docker](https://github.com/morsalin1342/php-docker) | `morsalin1342/php` · `easydigital/php` | Traditional PHP-FPM & CLI images |

---

## Feedback and Issues

If you have suggestions, find a bug, or want to request a new module, please [open an issue](https://github.com/morsalin1342/nginx-docker/issues) on the GitHub repository.

---

⭐ **If this project helps you, consider giving it a star!**
