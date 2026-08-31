# nginx-docker

Official nginx plus the modules it does not ship — **ModSecurity 3**, **Brotli**,
**Zstandard**, **headers-more**, **GeoIP2** and **VTS** — built as dynamic modules.

```bash
docker pull easydigital/nginx:latest
```

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

And these cannot be added to any open-source build, being NGINX Plus only: `api`, `auth_jwt`,
`keyval`, `oidc`, `session_log`, `status`, `upstream_conf`, `upstream_hc`.

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

## Building locally

```bash
docker build -t nginx-custom .
docker run --rm nginx-custom nginx -V
docker run --rm nginx-custom nginx -t
```

Overridable at build time: `NGINX_VERSION`, `DEBIAN_RELEASE`, `MODSECURITY_VERSION`,
`MODSECURITY_NGINX_VERSION`, `HEADERS_MORE_VERSION`, `GEOIP2_VERSION`, `VTS_VERSION`,
`NGX_BROTLI_COMMIT`, `ZSTD_MODULE_VERSION`, `ZSTD_VERSION`, `CRS_VERSION`.

The final stage runs `nginx -t` with every module loaded, so a module built against a
mismatched nginx fails **the build** rather than a customer's server at start time.

## Tags

`<nginx-version>` and `latest`, published on push to `master`.

The tag names the **upstream nginx release**, not a build of this repository — so it is
republished when the Dockerfile changes. A module bump or a CRS update can land under an
unchanged nginx version. **Pin by digest if you need immutability.**

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

## Licence

MIT for this repository's build files. The software it packages keeps its own licences: nginx
(BSD-2-Clause), ModSecurity (Apache-2.0), OWASP CRS (Apache-2.0), Brotli (MIT), headers-more
(BSD-2-Clause), ngx_http_geoip2_module (BSD-2-Clause).
