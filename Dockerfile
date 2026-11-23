# nginx with the modules it does not ship.
#
# Official nginx plus ModSecurity 3, Brotli, Zstandard, headers-more, GeoIP2,
# VTS, cache-purge, fancyindex, upload-progress and OpenTelemetry, as
# **dynamic** modules for the matching nginx release. The official image is
# configured `--with-compat`, which nginx documents as enabling "dynamic modules
# compatibility" — modules built separately load into the stock binary rather
# than requiring nginx itself to be rebuilt.
#
# That is the point of this file. A source rebuild would put nginx's own security
# updates on this image's release schedule instead of upstream's; here the final
# stage *is* the official image, and a new nginx patch is a version bump and a
# rebuild of twelve `.so` files. The thirteenth, ngx_otel_module, is installed
# from nginx's own package repository rather than built.
#
# # What is included, and why each
#
#   ModSecurity 3 + connector  the only maintained WAF engine for nginx. Ships
#                              with the OWASP Core Rule Set and a main.conf
#                              that loads both, used by nothing until you opt in.
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
#   cache-purge                removes one proxy_cache entry; open-source nginx
#                              can only let a whole zone expire.
#   fancyindex                 themed directory listings.
#   upload-progress            upload progress polling.
#   ngx_otel_module            OpenTelemetry tracing, from nginx's packages.
#
# # What is deliberately absent
#
# Rate limiting, connection limiting, real_ip, HTTP/2, HTTP/3, gzip, sub_filter,
# secure_link, auth_request, map, geo and mp4 are **already in the official
# image** — verified against `nginx -V`. Nothing here duplicates them.
#
# Note also that several modules in nginx's documentation index are NGINX Plus
# only and cannot be added to an open-source build at all: `api`, `auth_jwt`,
# `keyval`, `oidc`, `session_log`, `status`, `upstream_conf`, `upstream_hc`.
#
# # Nothing is enabled by default
#
# This image's modules are loaded, and every one of them does nothing until
# configured. The dynamic modules the official image ships (njs, image_filter,
# xslt, geoip, acme) stay unloaded, as they are there. ModSecurity in particular
# stays off: `modsecurity on;` is the operator's decision, and the Core Rule Set
# has a real false-positive cost on application admin panels.
#
# Debian rather than Alpine: ModSecurity's dependency set — yajl, lmdb, libxml2,
# curl — is better served by glibc.

ARG NGINX_VERSION=1.30.7
ARG DEBIAN_RELEASE=trixie

# ─────────────────────────────────────────────────────────────────────────────
# libmodsecurity — the WAF engine itself, which the nginx connector links against
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_RELEASE}-slim AS modsecurity

# bash with pipefail for every RUN below, so a failed download in front of a
# pipe fails the build instead of handing the next command an empty stream.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The tag and the commit it points at. The commit is what is fetched; the tag
# is checked against it, so a tag moved upstream fails the build rather than
# changing what this image contains.
ARG MODSECURITY_VERSION=v3.0.17
ARG MODSECURITY_COMMIT=1925753989ccce977cdaae417b55c9726c7cf02c

# Unpinned on purpose: these are Debian's current packages for the release,
# security fixes included. hadolint's DL3008 asks for version pins.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake build-essential ca-certificates git libtool pkg-config \
        libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre2-dev libssl-dev \
        libxml2-dev libyajl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# One commit, no history, then the submodules at the commits that commit
# records: ModSecurity vendors its parser generators, and a full history clone
# is roughly ten times the download for no benefit.
WORKDIR /usr/src/ModSecurity
RUN git init -q . \
    && git remote add origin https://github.com/owasp-modsecurity/ModSecurity \
    && git fetch -q --depth 1 origin "${MODSECURITY_COMMIT}" \
    && git checkout -q --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${MODSECURITY_COMMIT}" \
    && tagged="$(git ls-remote origin "refs/tags/${MODSECURITY_VERSION}" "refs/tags/${MODSECURITY_VERSION}^{}" | sort -k2 | tail -n1 | cut -f1)" \
    && { test "$tagged" = "${MODSECURITY_COMMIT}" \
         || { echo "${MODSECURITY_VERSION} is ${tagged:-missing} upstream, not ${MODSECURITY_COMMIT}" >&2; exit 1; }; } \
    && git submodule update -q --init --recursive

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

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Every module is pinned twice: the release tag, and the commit that tag points
# at. The commit is what is fetched and checked out; the tag is checked against
# it at build time, so a tag that moves upstream fails the build instead of
# quietly changing what a published image contains. scripts/check-upstream.sh
# reports when a newer release exists.
ARG NGINX_VERSION
ARG MODSECURITY_NGINX_VERSION=v1.0.4
ARG MODSECURITY_NGINX_COMMIT=3f4b57df10ce43b1f1c722141f7621dc64838be8
ARG HEADERS_MORE_VERSION=v0.42
ARG HEADERS_MORE_COMMIT=e30b10e0bb1cfb042d76ba3a865410ff95d65660
ARG GEOIP2_VERSION=3.4
ARG GEOIP2_COMMIT=cbaa35461c62a99d2577e6bae3273492502d8769
ARG VTS_VERSION=v0.2.7
ARG VTS_COMMIT=38b8612527ecb003ea15cefe934f302cf1a7c27e
ARG ZSTD_MODULE_VERSION=0.1.1
ARG ZSTD_MODULE_COMMIT=6be764e2bed04f889af824eff2d4dd737ebdab5a
# Widely-deployed community modules. Each is pinned, each is optional at
# runtime, and each earns its place by being something nginx cannot do alone.
ARG FANCYINDEX_VERSION=v0.6.0
ARG FANCYINDEX_COMMIT=70311f239ec1e88ff79c669d126d08532ddb8554
ARG CACHE_PURGE_VERSION=3.0.4
ARG CACHE_PURGE_COMMIT=a6da1352f52a8a02dd6828e88c39ed42fddcee96
ARG UPLOAD_PROGRESS_VERSION=v0.9.4
ARG UPLOAD_PROGRESS_COMMIT=463d60b5024d3870280d3a63b1568a2676e24a8c
# ngx_brotli publishes no releases, so this is a commit alone. Pinned rather
# than tracking master: an unpinned dependency in a WAF-bearing gateway is a
# change nobody reviewed arriving in a tag we already published.
#
# **Both compression modules are worth knowing the state of**, since neither is
# pristine and both were kept deliberately. ngx_brotli has never cut a release:
# its last commit, in October 2026, moved the bundled Brotli library to v1.2.1,
# and the one before that was October 2023. zstd-nginx-module last moved in
# June 2025 and its own README calls it "currently considered experimental".
# They are carried because compression is the main reason anyone builds custom
# nginx and gzip alone is a poor showing in 2026 — not because either is
# actively developed. Both are pinned, both are off by default, and dropping
# either is a two-line change.
ARG NGX_BROTLI_COMMIT=53e0fb55f250f48fe80c0ddbf6c0f7103cdbaae1

# gnupg is for checking the nginx source signature below. Unpinned on purpose,
# as in the stage above.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git gnupg libtool pkg-config \
        libcurl4-openssl-dev libgeoip-dev liblmdb-dev libmaxminddb-dev \
        libpcre2-dev libssl-dev libxml2-dev libxslt1-dev libyajl-dev libzstd-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=modsecurity /usr/local/modsecurity /usr/local/modsecurity
WORKDIR /usr/src

# The nginx source, verified against nginx's own signature before it is used.
#
# nginx signs every release tarball with a developer's key, and nginx.org
# publishes those keys at /en/pgp_keys.html. The keys are fetched from there,
# but trust comes from the fingerprints written below, not from the download:
# the signature must be good **and** made by one of these keys, or the build
# stops. The keys are Roman Arutyunyan, Sergey Kandaurov, Sergey Budnevitch,
# Konstantin Pavlov and Sai Krishna Kumar Reddy Yadamakanti, in that order.
RUN NGINX_RELEASE_KEYS="43387825DDB1BB97EC36BA5D007C8D7C15D87369 \
        D6786CE303D9A9022998DC6CC8464D549AF75C0A \
        7338973069ED3F443F4D37DFA64FD5B17ADB39A8 \
        13C82A63B603576156E30A4EA0EA981B66B0D967 \
        AC50DD4E7CD5D51FD00D1F4C4DB15B66AA75322B"; \
    set -e; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    for key in arut pluknet sb thresh sai; do \
        curl -fsSL "https://nginx.org/keys/${key}.key" | gpg --batch --quiet --import; \
    done; \
    curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc"; \
    gpg --batch --status-fd 1 --verify "nginx-${NGINX_VERSION}.tar.gz.asc" \
        "nginx-${NGINX_VERSION}.tar.gz" > verify.status; \
    signer="$(awk '$2 == "VALIDSIG" { print $NF }' verify.status)"; \
    trusted=no; \
    for fpr in ${NGINX_RELEASE_KEYS}; do [ "$fpr" = "$signer" ] && trusted=yes; done; \
    if [ "$trusted" != yes ]; then \
        echo "nginx-${NGINX_VERSION}.tar.gz is not signed by a pinned nginx key (${signer:-no valid signature})" >&2; \
        exit 1; \
    fi; \
    echo "nginx-${NGINX_VERSION}.tar.gz: good signature from ${signer}"; \
    tar -xzf "nginx-${NGINX_VERSION}.tar.gz"; \
    rm -rf "$GNUPGHOME" verify.status "nginx-${NGINX_VERSION}.tar.gz" "nginx-${NGINX_VERSION}.tar.gz.asc"

# The modules, each fetched as one commit and checked: HEAD must be the pinned
# commit, and the pinned tag must still point at it upstream.
RUN fetch() { \
        url="$1" dir="$2" tag="$3" commit="$4"; \
        git init -q "$dir"; \
        git -C "$dir" remote add origin "$url"; \
        git -C "$dir" fetch -q --depth 1 origin "$commit"; \
        git -C "$dir" checkout -q --detach FETCH_HEAD; \
        test "$(git -C "$dir" rev-parse HEAD)" = "$commit"; \
        if [ -n "$tag" ]; then \
            tagged="$(git -C "$dir" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}" | sort -k2 | tail -n1 | cut -f1)"; \
            if [ "$tagged" != "$commit" ]; then \
                echo "$url: tag $tag is ${tagged:-missing}, not the pinned $commit" >&2; return 1; \
            fi; \
        fi; \
    }; \
    set -e; \
    fetch https://github.com/owasp-modsecurity/ModSecurity-nginx.git ModSecurity-nginx \
        "${MODSECURITY_NGINX_VERSION}" "${MODSECURITY_NGINX_COMMIT}"; \
    fetch https://github.com/openresty/headers-more-nginx-module.git headers-more-nginx-module \
        "${HEADERS_MORE_VERSION}" "${HEADERS_MORE_COMMIT}"; \
    fetch https://github.com/leev/ngx_http_geoip2_module.git ngx_http_geoip2_module \
        "${GEOIP2_VERSION}" "${GEOIP2_COMMIT}"; \
    fetch https://github.com/vozlt/nginx-module-vts.git nginx-module-vts \
        "${VTS_VERSION}" "${VTS_COMMIT}"; \
    fetch https://github.com/tokers/zstd-nginx-module.git zstd-nginx-module \
        "${ZSTD_MODULE_VERSION}" "${ZSTD_MODULE_COMMIT}"; \
    fetch https://github.com/aperezdc/ngx-fancyindex.git ngx-fancyindex \
        "${FANCYINDEX_VERSION}" "${FANCYINDEX_COMMIT}"; \
    fetch https://github.com/nginx-modules/ngx_cache_purge.git ngx_cache_purge \
        "${CACHE_PURGE_VERSION}" "${CACHE_PURGE_COMMIT}"; \
    fetch https://github.com/masterzen/nginx-upload-progress-module.git nginx-upload-progress-module \
        "${UPLOAD_PROGRESS_VERSION}" "${UPLOAD_PROGRESS_COMMIT}"; \
    fetch https://github.com/google/ngx_brotli.git ngx_brotli "" "${NGX_BROTLI_COMMIT}"; \
    git -C ngx_brotli submodule update -q --init --recursive

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
RUN cmake -S . -B out \
             -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_SHARED_LIBS=OFF \
             -DCMAKE_C_FLAGS="-Ofast -fPIC" \
             -DCMAKE_CXX_FLAGS="-Ofast -fPIC" \
             -DCMAKE_INSTALL_PREFIX=./installed \
    && cmake --build out --config Release --target brotlienc

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
#
# The tarball is checked against the SHA-256 that zstd publishes beside it as
# the release asset zstd-<version>.tar.gz.sha256.
ARG ZSTD_VERSION=1.5.7
ARG ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

WORKDIR /usr/src
RUN curl -fsSLO "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" \
    && echo "${ZSTD_SHA256}  zstd-${ZSTD_VERSION}.tar.gz" | sha256sum -c - \
    && tar -xzf "zstd-${ZSTD_VERSION}.tar.gz" \
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
    && make -j"$(nproc)" modules \
    && find objs -maxdepth 1 -name '*.so' -printf '%f\n' | sort > /usr/src/built-modules.txt

# ─────────────────────────────────────────────────────────────────────────────
# The image: stock nginx, plus the modules and the rules
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:${NGINX_VERSION}-${DEBIAN_RELEASE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG NGINX_VERSION
ARG CRS_VERSION=v4.30.0
# The SHA-256 of coreruleset-<version>-minimal.tar.gz, as GitHub records it for
# that asset of the CRS release.
ARG CRS_SHA256=3d678a41fd5aade34760127fef5dd64fd7a77848913fc0f70dde0cf467c94427

# licenses is empty on purpose. The repository's own files are MIT, but the image
# combines software under many licences (the README's Licence section names the main
# ones; the SBOM each build keeps lists every package), and no single SPDX expression
# has been derived for all of it. The base image sets no licences label today; the
# empty value keeps it that way if one is added.
LABEL org.opencontainers.image.title="nginx" \
      org.opencontainers.image.description="nginx with ModSecurity 3, Brotli, Zstandard, headers-more, GeoIP2, VTS, cache-purge, fancyindex, upload-progress and OpenTelemetry as dynamic modules" \
      org.opencontainers.image.source="https://github.com/morsalin1342/nginx-docker" \
      org.opencontainers.image.licenses=""

# Runtime libraries the modules link against. The -dev packages stay in the
# builder; only the shared objects are needed here. `acl` (setfacl, getfacl) lets
# an entrypoint grant a user access to a directory without changing its owner.
#
# Every package the base image ships is upgraded to Debian's security releases
# at build time, so a fix Debian has published (zlib1g CVE-2026-85091, apt,
# libcares2, libexpat1, libbrotli1) is in the image even before the official
# base image is rebuilt. Unpinned for the same reason.
# hadolint ignore=DL3008
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        acl libcurl4 libgeoip1 liblmdb0 libmaxminddb0 libxml2 libyajl2 libzstd1 \
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
# The repository signing key is checked by fingerprint, not trusted because it
# downloaded. nginx_signing.key holds nginx's three package signing keys; the
# fingerprints below are the ones nginx.org lists and the official nginx image
# pins. Only those keys are exported into the keyring apt uses, and a key file
# missing any of them stops the build. apt then checks the repository's
# signature against that keyring. gnupg is installed only for this and is
# removed again, so it is not part of the published image. The key list is
# split on purpose (SC2086).
# hadolint ignore=DL3008,SC2086
RUN NGINX_PACKAGE_KEYS="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 \
        8540A6F18833A80E9C1653A42FD21310B49F6B46 \
        9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3"; \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gnupg; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --batch --quiet --import; \
    for fpr in ${NGINX_PACKAGE_KEYS}; do \
        gpg --batch --list-keys --with-colons "$fpr" | grep -q "^fpr:::::::::${fpr}:" \
            || { echo "nginx_signing.key does not contain the pinned key ${fpr}" >&2; exit 1; }; \
    done; \
    gpg --batch --export ${NGINX_PACKAGE_KEYS} > /usr/share/keyrings/nginx-archive-keyring.gpg; \
    rm -rf "$GNUPGHOME"; \
    printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] %s %s nginx\n' \
        'https://nginx.org/packages/debian' "${DEBIAN_RELEASE}" \
        > /etc/apt/sources.list.d/nginx.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "nginx-module-otel=${NGINX_VERSION}+${OTEL_MODULE_VERSION}-1~${DEBIAN_RELEASE}"; \
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list

# libmodsecurity once. The real file only (libmodsecurity.so.3.0.x): COPY
# follows symlinks, so copying libmodsecurity.so* stored the same library three
# times. ldconfig recreates the libmodsecurity.so.3 link the connector loads.
COPY --from=modsecurity /usr/local/modsecurity/lib/libmodsecurity.so.*.*.* /usr/local/modsecurity/lib/
COPY --from=modules /usr/src/nginx-${NGINX_VERSION}/objs/*.so /usr/lib/nginx/modules/
COPY --from=modules /usr/src/built-modules.txt /tmp/built-modules.txt

RUN ldconfig /usr/local/modsecurity/lib

# The OWASP Core Rule Set, shipped but **not enabled**.
#
# Nothing here loads it, and that is deliberate rather than unfinished. CRS in
# blocking mode has a real false-positive cost — it catches request shapes that
# application admin panels make legitimately, and the exclusions for those are
# site-specific and not something upstream ships. Turning it on, and choosing
# detection or blocking, belongs to whoever runs the server.
#
# The release's "minimal" tarball: the rules, crs-setup.conf.example, the plugin
# placeholders and the docs, without the regression tests and the regex-assembly
# sources, which are for developing CRS rather than running it.
RUN mkdir -p /etc/nginx/modsecurity \
    && curl -fsSL -o /tmp/crs.tar.gz \
        "https://github.com/coreruleset/coreruleset/releases/download/${CRS_VERSION}/coreruleset-${CRS_VERSION#v}-minimal.tar.gz" \
    && echo "${CRS_SHA256}  /tmp/crs.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/crs.tar.gz -C /etc/nginx/modsecurity --strip-components=1 \
    && rm /tmp/crs.tar.gz \
    && cp /etc/nginx/modsecurity/crs-setup.conf.example /etc/nginx/modsecurity/crs-setup.conf

# ModSecurity's own configuration, from the ModSecurity source the library was
# built from, and a main.conf that loads it, then the CRS setup, then the rules,
# in DetectionOnly. Nothing includes main.conf: the WAF stays off until
# `modsecurity on;` and `modsecurity_rules_file /etc/nginx/modsecurity/main.conf;`.
# modsecurity.conf names unicode.mapping relative to itself, so the two sit
# side by side.
COPY --from=modsecurity /usr/src/ModSecurity/modsecurity.conf-recommended /etc/nginx/modsecurity/modsecurity.conf
COPY --from=modsecurity /usr/src/ModSecurity/unicode.mapping /etc/nginx/modsecurity/unicode.mapping
COPY modsecurity/main.conf /etc/nginx/modsecurity/main.conf

# Load this image's modules, and prove they load, before the image is published.
#
# # Why an include rather than thirteen load_module lines in nginx.conf
#
# `load_module` is only valid in nginx's main context — it cannot go in
# conf.d/*.conf, which is where the official image expects user configuration.
# So the directives have to reach nginx.conf itself.
#
# Writing them into nginx.conf directly would work until somebody mounts their
# own nginx.conf over it, which is the single most common way this image will be
# used and which would silently unload every module. Instead nginx.conf gains
# **one** include line, and the directives live in a file of their own:
# replacing nginx.conf then costs one line to restore rather than thirteen, and
# the file it points at is the image's business rather than the user's.
#
# /etc/nginx/modules-enabled/ is created here because it does not exist in the
# official image — that is a Debian *package* convention, not this image's, and
# assuming it was the first version of this step's mistake.
#
# # Why the list is written out
#
# /usr/lib/nginx/modules also holds the dynamic modules the official image
# ships — njs, image_filter, xslt, geoip and acme — which the official image
# does not load. Loading everything in the directory loaded those too, so the
# image behaved differently from the one it claims to be a drop-in for. The list
# is this image's own thirteen: the twelve built above and ngx_otel_module.
#
# A hand-written list can drift from what the modules stage builds, so it is
# checked here: every .so the build produced must be in the list, and every
# file the list names must exist, or the build fails.
RUN set -e; \
    mkdir -p /etc/nginx/modules-enabled; \
    printf 'load_module modules/%s;\n' \
        ngx_http_modsecurity_module.so \
        ngx_http_brotli_filter_module.so \
        ngx_http_brotli_static_module.so \
        ngx_http_zstd_filter_module.so \
        ngx_http_zstd_static_module.so \
        ngx_http_headers_more_filter_module.so \
        ngx_http_geoip2_module.so \
        ngx_stream_geoip2_module.so \
        ngx_http_vhost_traffic_status_module.so \
        ngx_http_cache_purge_module.so \
        ngx_http_fancyindex_module.so \
        ngx_http_uploadprogress_module.so \
        ngx_otel_module.so \
        > /etc/nginx/modules-enabled/10-modules.conf; \
    while read -r so; do \
        grep -qxF "load_module modules/${so};" /etc/nginx/modules-enabled/10-modules.conf \
            || { echo "built ${so} but 10-modules.conf does not load it" >&2; exit 1; }; \
    done < /tmp/built-modules.txt; \
    sed -n 's|^load_module modules/\(.*\);$|\1|p' /etc/nginx/modules-enabled/10-modules.conf \
        | while read -r so; do \
            test -f "/usr/lib/nginx/modules/${so}" \
                || { echo "10-modules.conf loads ${so}, which is not in the image" >&2; exit 1; }; \
        done; \
    rm -f /tmp/built-modules.txt; \
    printf 'include /etc/nginx/modules-enabled/*.conf;\n' \
        | cat - /etc/nginx/nginx.conf > /tmp/nginx.conf; \
    mv /tmp/nginx.conf /etc/nginx/nginx.conf; \
    nginx -t

# The WAF configuration is shipped and included by nothing, so the `nginx -t`
# above never parses it. It is checked here, once, in a throwaway configuration
# that turns it on: without this, main.conf, modsecurity.conf and every CRS rule
# are files that could fail to load for a whole release with every build green.
RUN printf '%s\n' \
        'include /etc/nginx/modules-enabled/*.conf;' \
        'events {}' \
        'http {' \
        '    modsecurity on;' \
        '    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;' \
        '}' > /tmp/waf-check.conf \
    && nginx -t -c /tmp/waf-check.conf \
    && rm -f /tmp/waf-check.conf

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
    for _ in $(seq 1 20); do \
        curl -fsS -o /dev/null http://127.0.0.1/ && break; \
        sleep 0.5; \
    done; \
    curl -fsS -o /dev/null http://127.0.0.1/; \
    nginx -e /tmp/startup.log -s quit; \
    wait "$pid"; \
    if grep -qiE '\[(emerg|alert|crit)\]' /tmp/startup.log; then \
        echo 'nginx logged a startup error:'; cat /tmp/startup.log; exit 1; \
    fi; \
    rm -f /tmp/startup.log
