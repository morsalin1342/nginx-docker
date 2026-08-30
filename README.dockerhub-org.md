# nginx — with the modules it does not ship

**Maintained by [easydigital](https://hub.docker.com/u/easydigital)** · [GitHub](https://github.com/easydigital/nginx-docker)

Official nginx plus **ModSecurity 3**, **Brotli**, **headers-more** and **GeoIP2**, built as
dynamic modules. The image *is* the official `nginx` image — the modules are compiled
separately and loaded into the stock binary, so nginx's own security updates arrive on
nginx's schedule, not this repository's.

## Quick start

```bash
docker run -d --name nginx \
    -p 80:80 -p 443:443 \
    -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro \
    easydigital/nginx:latest
```

The modules are loaded and **every one of them does nothing until you configure it.** Drop-in
replacement for `nginx:<version>` until you use one.

> **If you replace `/etc/nginx/nginx.conf`**, keep this line at the top — `load_module` is only
> valid in nginx's main context, so it cannot live in `conf.d/`, and without it none of the
> modules below exist:
>
> ```nginx
> include /etc/nginx/modules-enabled/*.conf;
> ```
>
> Mounting into `conf.d/` instead needs no such care.

## What is included

| Module | Directive to start with | Why it is not already in nginx |
|---|---|---|
| ModSecurity 3 | `modsecurity on;` | nginx ships no WAF |
| Brotli | `brotli on;` | nginx has gzip only |
| headers-more | `more_clear_headers Server;` | nginx cannot unset arbitrary headers |
| GeoIP2 | `geoip2 /path/db.mmdb { … }` | nginx's own GeoIP module reads only the legacy databases MaxMind stopped publishing |

Already in official nginx and therefore **not** duplicated here: rate limiting (`limit_req`),
connection limiting, `real_ip`, HTTP/2, HTTP/3, gzip, `sub_filter`, `secure_link`,
`auth_request`, `map`, `geo`.

## ModSecurity

The OWASP Core Rule Set ships at `/etc/nginx/modsecurity/` and **nothing loads it.** That is
deliberate: CRS in blocking mode has a real false-positive cost against application admin
panels, and the exclusions are site-specific. Enabling it, and choosing detection or blocking,
is yours.

```nginx
# /etc/nginx/nginx.conf
load_module modules/ngx_http_modsecurity_module.so;   # already loaded by default

http {
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;
}
```

Where `main.conf` includes `modsecurity.conf`, `crs-setup.conf` and `rules/*.conf`. Start in
`DetectionOnly` and read your logs before blocking anything.

`modsecurity` defaults to **off** in the connector itself, so the module being loaded changes
nothing until you say otherwise.

The connector also provides `modsecurity_rules_file`, `modsecurity_rules_remote`,
`modsecurity_rules`, `modsecurity_use_error_log` and `modsecurity_transaction_id`. The last is
worth knowing: paired with `$request_id` in your `log_format`, it lets you correlate an access
log line with the error log entry the WAF wrote for the same request.

## Tags

`<nginx-version>` and `latest`. The tag names the **upstream nginx release** the image is
built on, and is republished when this repository's Dockerfile changes — a module bump or a
CRS update can land under an unchanged nginx version. Pin by digest if you need immutability.

## Verifying

```bash
docker run --rm easydigital/nginx:latest nginx -V
docker run --rm easydigital/nginx:latest nginx -t
```

Every published image runs `nginx -t` with all five modules loaded at build time, so a module
built against a mismatched nginx fails the build rather than a running server.
