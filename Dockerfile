# nginx with the modules it does not ship.
#
# Official nginx plus ModSecurity 3, Brotli, headers-more and GeoIP2, built as
# **dynamic** modules against the matching nginx release. The official image is
# configured `--with-compat`, which nginx documents as enabling "dynamic modules
# compatibility" — modules built separately load into the stock binary rather
# than requiring nginx itself to be rebuilt.
#
# That is the point of this file. A source rebuild would put nginx's own security
# updates on this image's release schedule instead of upstream's; here the final
# stage *is* the official image, and a new nginx patch is a version bump and a
# rebuild of six `.so` files.
#
# # What is included, and why each
#
#   ModSecurity 3 + connector  the only maintained WAF engine for nginx. Ships
#                              with the OWASP Core Rule Set, loaded by nothing.
#   ngx_brotli                 nginx has gzip built in and no Brotli at all.
#   zstd                       Zstandard, beside Brotli rather than instead of
#                              it. They do not compete: a client advertises what
#                              it accepts and nginx picks, so shipping both means
#                              zstd for clients that support it (Chrome 123+,
#                              Firefox 126+), Brotli for the rest, gzip for
#                              everything else.
#   headers-more               nginx cannot unset an arbitrary response header
#                              without it — `more_clear_headers`.
#   GeoIP2                     nginx's own ngx_http_geoip_module speaks the
#                              legacy GeoIP databases MaxMind stopped
#                              publishing; this reads .mmdb.
#   VTS                        per-virtual-host traffic statistics, and the only
#                              one of these that emits Prometheus. nginx ships
#                              stub_status, which is seven plain-text counters
#                              for the whole server with no per-host breakdown
#                              and no Prometheus format -- not a metrics
#                              endpoint anything can scrape usefully.
#
# # What is deliberately absent
#
# Rate limiting, connection limiting, real_ip, HTTP/2, HTTP/3, gzip, sub_filter,
# secure_link, auth_request, map and geo are **already in the official image** —
# verified against `nginx -V`. Nothing here duplicates them.
#
# Note also that several modules in nginx's documentation index are NGINX Plus
# only and cannot be added to an open-source build at all: `api`, `auth_jwt`,
# `keyval`, `oidc`, `session_log`, `status`, `upstream_conf`, `upstream_hc`.
#
# # Nothing is enabled by default
#
# The modules are loaded, and every one of them does nothing until configured.
# ModSecurity in particular stays off: `modsecurity on;` is the operator's
# decision, and the Core Rule Set has a real false-positive cost on
# application admin panels.
#
# Debian rather than Alpine: ModSecurity's dependency set — yajl, lmdb, libxml2,
# curl — is better served by glibc.

ARG NGINX_VERSION=1.30.4
ARG DEBIAN_RELEASE=trixie

# ─────────────────────────────────────────────────────────────────────────────
# libmodsecurity — the WAF engine itself, which the nginx connector links against
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_RELEASE}-slim AS modsecurity

ARG MODSECURITY_VERSION=v3.0.16

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake build-essential ca-certificates git libtool pkg-config \
        libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre2-dev libssl-dev \
        libxml2-dev libyajl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# --depth 1 with the submodules: ModSecurity vendors its parser generators, and
# a full history clone is roughly ten times the download for no benefit.
RUN git clone --branch "${MODSECURITY_VERSION}" --depth 1 --recursive \
        https://github.com/owasp-modsecurity/ModSecurity /usr/src/ModSecurity

WORKDIR /usr/src/ModSecurity
RUN ./build.sh \
    && ./configure --disable-doxygen-doc --disable-doxygen-html --disable-examples \
    && make -j"$(nproc)" \
    && make install \
    # Strip the debug symbols. libmodsecurity.so is built unstripped and is
    # ~175MB that way — by a wide margin the largest thing in the published
    # image, and larger than the entire nginx base. Stripping takes it to
    # single-digit megabytes and costs nothing anyone debugging this image
    # would miss: the symbols belong in a -dbg artifact, not in every pull.
    && strip --strip-unneeded /usr/local/modsecurity/lib/libmodsecurity.so.*.*.*

# ─────────────────────────────────────────────────────────────────────────────
# The nginx modules, built against the exact nginx source of the final image
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_RELEASE}-slim AS modules

ARG NGINX_VERSION
ARG MODSECURITY_NGINX_VERSION=v1.0.4
ARG HEADERS_MORE_VERSION=v0.40
ARG GEOIP2_VERSION=3.4
ARG VTS_VERSION=v0.2.7
ARG ZSTD_MODULE_VERSION=0.1.1
# Widely-deployed community modules. Each is pinned, each is optional at
# runtime, and each earns its place by being something nginx cannot do alone.
ARG FANCYINDEX_VERSION=v0.6.0
ARG CACHE_PURGE_VERSION=3.0.2
ARG UPLOAD_PROGRESS_VERSION=v0.9.4
# ngx_brotli publishes no releases, so this is a commit. Pinned rather than
# tracking master: an unpinned dependency in a WAF-bearing gateway is a change
# nobody reviewed arriving in a tag we already published.
#
# **Both compression modules are worth knowing the state of**, since neither is
# pristine and both were kept deliberately. ngx_brotli's last commit is October
# 2023 and it has never cut a release; zstd-nginx-module last moved in June 2025
# and its own README calls it "currently considered experimental". They are
# carried because compression is the main reason anyone builds custom nginx and
# gzip alone is a poor showing in 2026 — not because either is actively
# developed. Both are pinned, both are off by default, and dropping either is a
# two-line change.
ARG NGX_BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git libtool pkg-config \
        libcurl4-openssl-dev libgeoip-dev liblmdb-dev libmaxminddb-dev \
        libpcre2-dev libssl-dev libxml2-dev libxslt1-dev libyajl-dev libzstd-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=modsecurity /usr/local/modsecurity /usr/local/modsecurity
WORKDIR /usr/src

RUN curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" | tar -xz \
    && git clone --branch "${MODSECURITY_NGINX_VERSION}" --depth 1 \
        https://github.com/owasp-modsecurity/ModSecurity-nginx.git \
    && git clone --branch "${HEADERS_MORE_VERSION}" --depth 1 \
        https://github.com/openresty/headers-more-nginx-module.git \
    && git clone --branch "${GEOIP2_VERSION}" --depth 1 \
        https://github.com/leev/ngx_http_geoip2_module.git \
    && git clone --branch "${VTS_VERSION}" --depth 1 \
        https://github.com/vozlt/nginx-module-vts.git \
    && git clone --branch "${ZSTD_MODULE_VERSION}" --depth 1 \
        https://github.com/tokers/zstd-nginx-module.git \
    && git clone --branch "${FANCYINDEX_VERSION}" --depth 1 \
        https://github.com/aperezdc/ngx-fancyindex.git \
    && git clone --branch "${CACHE_PURGE_VERSION}" --depth 1 \
        https://github.com/nginx-modules/ngx_cache_purge.git \
    && git clone --branch "${UPLOAD_PROGRESS_VERSION}" --depth 1 \
        https://github.com/masterzen/nginx-upload-progress-module.git \
    && git clone --recursive https://github.com/google/ngx_brotli.git \
    && git -C ngx_brotli checkout "${NGX_BROTLI_COMMIT}" \
    && git -C ngx_brotli submodule update --init --recursive

# Brotli's bundled libbrotli, built before nginx configures against it.
#
# **Upstream's own example flags are wrong for a distributable image.**
# ngx_brotli's README suggests `-march=native -mtune=native`, which compiles for
# the CPU of whichever machine ran the build. In an image built on one host and
# run on another that is an illegal-instruction crash on first request, and it
# would pass every test performed on the build machine. They are omitted
# deliberately; `-Ofast -fPIC` is what remains.
#
# BUILD_SHARED_LIBS=OFF so brotlienc links statically into the module, per
# upstream. A shared build would leave the .so needing a libbrotlienc the final
# image does not install.
WORKDIR /usr/src/ngx_brotli/deps/brotli
RUN mkdir -p out && cd out \
    && cmake -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_SHARED_LIBS=OFF \
             -DCMAKE_C_FLAGS="-Ofast -fPIC" \
             -DCMAKE_CXX_FLAGS="-Ofast -fPIC" \
             -DCMAKE_INSTALL_PREFIX=./installed .. \
    && cmake --build . --config Release --target brotlienc

# libzstd, built with -fPIC so it can link into a shared object.
#
# The same treatment Brotli gets above, and for the same reason. The zstd module
# prefers the static archive — its README explains why: "this Nginx module uses
# some advanced APIs where static linking is recommended" — but Debian's
# libzstd.a is not built with -fPIC, so linking it into a dynamic module fails:
#
#   relocation R_X86_64_PC32 ... can not be used when making a shared object
#
# The dynamic fallback is not an option either, because **it is broken
# upstream**. zstd-nginx-module's filter/config builds its link flags as
#
#   ngx_zstd_opt_L="-L$ZSTD_LIB -lzstd -Wl,-rpath, $ZSTD_LIB"
#
# with a space after the trailing comma, which expands to a malformed
# `-Wl,-rpath,` with an empty path plus a bare directory handed to the linker as
# a file. The link test then fails and configure aborts with "requires the
# ZStandard library" — which reads like a missing dependency and is not one.
# That typo is presumably why every packager of this module links it statically.
#
# So: our own libzstd, PIC, and the static path it already prefers.
ARG ZSTD_VERSION=1.5.6

WORKDIR /usr/src
RUN curl -fsSL "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" \
        | tar -xz \
    && make -C "zstd-${ZSTD_VERSION}/lib" -j"$(nproc)" libzstd.a CFLAGS="-O3 -fPIC" \
    && mkdir -p /usr/local/zstd/lib /usr/local/zstd/include \
    && cp "zstd-${ZSTD_VERSION}/lib/libzstd.a" /usr/local/zstd/lib/ \
    && cp "zstd-${ZSTD_VERSION}"/lib/zstd.h "zstd-${ZSTD_VERSION}"/lib/zdict.h \
          "zstd-${ZSTD_VERSION}"/lib/zstd_errors.h /usr/local/zstd/include/

ENV ZSTD_INC=/usr/local/zstd/include
ENV ZSTD_LIB=/usr/local/zstd/lib

# `--with-compat` is mandatory and not optional tidiness: without it these
# modules are rejected by the stock binary at load time with a version mismatch,
# which is the whole reason this stage can exist separately from the image.
#
# **On whether the rest of the configure line must match the official image's:**
# ngx_brotli's README says it must — "you will need to use exactly the same
# ./configure arguments as your Nginx configuration … otherwise you will get a
# 'module is not binary compatible' error on startup". nginx's own
# documentation says `--with-compat` exists precisely to make that unnecessary.
#
# **Settled empirically on 2026-08-31: nginx's documentation is right and
# ngx_brotli's README is wrong.** Built with nothing but the two flags below,
# every module loads into the official binary — verified by the `nginx -t` at
# the end of the final stage, which reports "syntax is ok" and announces
# libmodsecurity3. Following ngx_brotli's advice would mean pasting a
# forty-argument configure line here and re-verifying it on every nginx bump,
# for no benefit.
#
# The `nginx -t` stays regardless: it is what would catch this changing.
#
# **The source version must equal the target image's version.** The
# ModSecurity-nginx documentation states it outright — "when building a dynamic
# module, your nginx source version needs to match the version of nginx you're
# compiling this for" — which is why the tarball fetched above and the final
# stage's base image both interpolate the same NGINX_VERSION. Bumping one
# without the other produces modules that build cleanly and refuse to load.
#
# `make modules`, not `make`: this compiles only objs/*.so. The nginx binary
# this stage could produce is never built and never shipped — the image is the
# official one.
# `--with-stream` is not about building nginx with stream support — nginx is
# never built here. It tells the addon configs that the stream module *type* is
# available, so those that have a stream variant emit one.
#
# GeoIP2 is the case. Its config carries
#
#   if [ $STREAM != NO -a $nginx_version -gt 1011001 ]; then
#       ngx_module_name="ngx_stream_geoip2_module"
#
# and without this flag that branch is skipped **silently** — no warning, no
# error, just a module that is not in the image and nobody notices until a
# stream {} block references it. The official image ships stream variants of its
# own geoip and js modules, so an image that offered only the http half of ours
# would be the odd one out.
#
# The remaining modules are HTTP-only by nature: ModSecurity inspects HTTP,
# Brotli and zstd are response filters, headers-more edits headers. VTS has a
# stream counterpart but it is a separate project (nginx-module-stream-sts),
# not a variant this flag would produce.
WORKDIR /usr/src/nginx-${NGINX_VERSION}
RUN ./configure \
        --with-compat \
        --with-stream \
        --add-dynamic-module=../ModSecurity-nginx \
        --add-dynamic-module=../headers-more-nginx-module \
        --add-dynamic-module=../ngx_http_geoip2_module \
        --add-dynamic-module=../nginx-module-vts \
        --add-dynamic-module=../ngx-fancyindex \
        --add-dynamic-module=../ngx_cache_purge \
        --add-dynamic-module=../nginx-upload-progress-module \
        --add-dynamic-module=../zstd-nginx-module \
        --add-dynamic-module=../ngx_brotli \
    && make -j"$(nproc)" modules

# ─────────────────────────────────────────────────────────────────────────────
# The image: stock nginx, plus the modules and the rules
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:${NGINX_VERSION}-${DEBIAN_RELEASE}

ARG NGINX_VERSION
ARG CRS_VERSION=v4.29.0

LABEL org.opencontainers.image.title="nginx" \
      org.opencontainers.image.description="nginx with ModSecurity 3, Brotli, headers-more and GeoIP2 as dynamic modules" \
      org.opencontainers.image.source="https://github.com/morsalin1342/nginx-docker" \
      org.opencontainers.image.licenses="MIT"

# Runtime libraries the modules link against. The -dev packages stay in the
# builder; only the shared objects are needed here.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4 libgeoip1 liblmdb0 libmaxminddb0 libxml2 libyajl2 libzstd1 \
    && rm -rf /var/lib/apt/lists/*

# OpenTelemetry, from nginx's own package repository rather than built here.
#
# ngx_otel_module is the one module in this image that upstream packages
# itself, and the package is the right way to get it. It is built by nginx
# against the exact binary this image is based on — the official image installs
# `nginx` from this same repository — so the compatibility question the rest of
# this Dockerfile answers with --with-compat does not arise at all.
#
# Building it from source would mean pulling in gRPC, protobuf and
# opentelemetry-cpp through CMake: a long build, a large dependency surface,
# and a worse binary-compatibility story than the artifact upstream ships.
#
# **The version is pinned to nginx's**, `<nginx>+<module>-1~<release>`. A
# mismatched pair is refused by apt rather than loaded, which is the failure
# mode worth having.
ARG DEBIAN_RELEASE
ARG OTEL_MODULE_VERSION=0.1.2
# The signing key is verified, not trusted blindly: apt checks the repository
# signature against it. gnupg is installed only to dearmor the key and is
# removed again, so it is not part of the published image.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gnupg; \
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg; \
    printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] %s %s nginx\n' \
        'https://nginx.org/packages/debian' "${DEBIAN_RELEASE}" \
        > /etc/apt/sources.list.d/nginx.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "nginx-module-otel=${NGINX_VERSION}+${OTEL_MODULE_VERSION}-1~${DEBIAN_RELEASE}"; \
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list

COPY --from=modsecurity /usr/local/modsecurity/lib/libmodsecurity.so* /usr/local/modsecurity/lib/
COPY --from=modules /usr/src/nginx-${NGINX_VERSION}/objs/*.so /usr/lib/nginx/modules/

RUN ldconfig /usr/local/modsecurity/lib

# The OWASP Core Rule Set, shipped but **not enabled**.
#
# Nothing here loads it, and that is deliberate rather than unfinished. CRS in
# blocking mode has a real false-positive cost — it catches request shapes that
# application admin panels make legitimately, and the exclusions for those are
# site-specific and not something upstream ships. Turning it on, and choosing
# detection or blocking, belongs to whoever runs the server.
#
# To use it: load the module, point modsecurity_rules_file at a file that
# includes crs-setup.conf and rules/*.conf, and set `modsecurity on;`.
RUN mkdir -p /etc/nginx/modsecurity \
    && curl -fsSL "https://github.com/coreruleset/coreruleset/archive/refs/tags/${CRS_VERSION}.tar.gz" \
        | tar -xz -C /etc/nginx/modsecurity --strip-components=1 \
    && cp /etc/nginx/modsecurity/crs-setup.conf.example /etc/nginx/modsecurity/crs-setup.conf

# Load the modules, and prove they load, before the image is published.
#
# # Why an include rather than five load_module lines in nginx.conf
#
# `load_module` is only valid in nginx's main context — it cannot go in
# conf.d/*.conf, which is where the official image expects user configuration.
# So the directives have to reach nginx.conf itself.
#
# Writing them into nginx.conf directly would work until somebody mounts their
# own nginx.conf over it, which is the single most common way this image will be
# used and which would silently unload every module. Instead nginx.conf gains
# **one** include line, and the directives live in a file of their own:
# replacing nginx.conf then costs one line to restore rather than five, and the
# file it points at is the image's business rather than the user's.
#
# /etc/nginx/modules-enabled/ is created here because it does not exist in the
# official image — that is a Debian *package* convention, not this image's, and
# assuming it was the first version of this step's mistake.
#
# The list is generated from the modules that actually built rather than typed
# out. A hand-written list is two artifacts that must agree, and the one that
# drifts is the list: a module added to the configure line above but forgotten
# here builds, ships, and is never loaded by anybody.
RUN mkdir -p /etc/nginx/modules-enabled \
    && for so in /usr/lib/nginx/modules/*.so; do \
           case "$so" in *-debug.so) continue ;; esac; \
           echo "load_module modules/$(basename "$so");"; \
       done > /etc/nginx/modules-enabled/10-modules.conf \
    && printf 'include /etc/nginx/modules-enabled/*.conf;\n' | \
        cat - /etc/nginx/nginx.conf > /tmp/nginx.conf \
    && mv /tmp/nginx.conf /etc/nginx/nginx.conf \
    && nginx -t

# Start nginx for real, and serve one request, before the image is published.
#
# `nginx -t` is not enough, and this step exists because of a real escape
# rather than as belt and braces. The config test parses the configuration and
# loads the modules; it does not run a module's own initialisation. A Lua build
# briefly carried here passed `nginx -t` cleanly and then aborted every worker
# at startup — an image that tested green and served nothing. Lua is gone, but
# the class of failure is not specific to it: any module that does real work at
# init can fail in exactly that gap, and only actually starting finds it.
# `-e` redirects the error log to a real file: in this image
# /var/log/nginx/error.log is a symlink to /dev/stderr, which cannot be read
# back, and the failure this step exists to catch is *logged* rather than
# returned — nginx starts, the workers abort, and the exit status says nothing.
RUN set -e; \
    nginx -e /tmp/startup.log -g 'daemon off;' & \
    pid=$!; \
    for i in $(seq 1 20); do \
        curl -fsS -o /dev/null http://127.0.0.1/ && break; \
        sleep 0.5; \
    done; \
    curl -fsS -o /dev/null http://127.0.0.1/; \
    kill "$pid"; \
    if grep -qiE '\[(emerg|alert|crit)\]' /tmp/startup.log; then \
        echo 'nginx logged a startup error:'; cat /tmp/startup.log; exit 1; \
    fi; \
    rm -f /tmp/startup.log
