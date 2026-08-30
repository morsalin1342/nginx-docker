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
# rebuild of five `.so` files.
#
# # What is included, and why each
#
#   ModSecurity 3 + connector  the only maintained WAF engine for nginx. Ships
#                              with the OWASP Core Rule Set, loaded by nothing.
#   ngx_brotli                 nginx has gzip built in and no Brotli at all.
#   headers-more               nginx cannot unset an arbitrary response header
#                              without it — `more_clear_headers`.
#   GeoIP2                     nginx's own ngx_http_geoip_module speaks the
#                              legacy GeoIP databases MaxMind stopped
#                              publishing; this reads .mmdb.
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

ARG NGINX_VERSION=1.27.5
ARG DEBIAN_RELEASE=bookworm

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
    && make install

# ─────────────────────────────────────────────────────────────────────────────
# The nginx modules, built against the exact nginx source of the final image
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_RELEASE}-slim AS modules

ARG NGINX_VERSION
ARG MODSECURITY_NGINX_VERSION=v1.0.4
ARG HEADERS_MORE_VERSION=v0.40
ARG GEOIP2_VERSION=3.4
# ngx_brotli publishes no releases, so this is a commit. Pinned rather than
# tracking master: an unpinned dependency in a WAF-bearing gateway is a change
# nobody reviewed arriving in a tag we already published.
ARG NGX_BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git libtool pkg-config \
        libcurl4-openssl-dev libgeoip-dev liblmdb-dev libmaxminddb-dev \
        libpcre2-dev libssl-dev libxml2-dev libxslt1-dev libyajl-dev zlib1g-dev \
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
    && git clone --recursive https://github.com/google/ngx_brotli.git \
    && git -C ngx_brotli checkout "${NGX_BROTLI_COMMIT}" \
    && git -C ngx_brotli submodule update --init --recursive

# Brotli's bundled libbrotli must be built before nginx configures against it.
WORKDIR /usr/src/ngx_brotli/deps/brotli
RUN mkdir -p out && cd out \
    && cmake -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_C_FLAGS="-Ofast -fPIC" \
             -DCMAKE_CXX_FLAGS="-Ofast -fPIC" \
             -DCMAKE_INSTALL_PREFIX=./installed .. \
    && cmake --build . --config Release --target brotlienc

# `--with-compat` is mandatory and not optional tidiness: without it these
# modules are rejected by the stock binary at load time with a version mismatch,
# which is the whole reason this stage can exist separately from the image.
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
WORKDIR /usr/src/nginx-${NGINX_VERSION}
RUN ./configure \
        --with-compat \
        --add-dynamic-module=../ModSecurity-nginx \
        --add-dynamic-module=../headers-more-nginx-module \
        --add-dynamic-module=../ngx_http_geoip2_module \
        --add-dynamic-module=../ngx_brotli \
    && make -j"$(nproc)" modules

# ─────────────────────────────────────────────────────────────────────────────
# The image: stock nginx, plus the four modules and the rules
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:${NGINX_VERSION}-${DEBIAN_RELEASE}

ARG NGINX_VERSION
ARG CRS_VERSION=v4.29.0

LABEL org.opencontainers.image.title="easydigital/nginx" \
      org.opencontainers.image.description="nginx with ModSecurity 3, Brotli, headers-more and GeoIP2 as dynamic modules" \
      org.opencontainers.image.source="https://github.com/easydigital/nginx-docker" \
      org.opencontainers.image.licenses="BSD-2-Clause"

# Runtime libraries the modules link against. The -dev packages stay in the
# builder; only the shared objects are needed here.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4 libgeoip1 liblmdb0 libmaxminddb0 libxml2 libyajl2 \
    && rm -rf /var/lib/apt/lists/*

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

# Prove the four modules load into the stock binary before the image is
# published. A module built against a mismatched nginx fails here, at build
# time, rather than on a customer's gateway at start time.
RUN printf 'load_module modules/ngx_http_modsecurity_module.so;\n\
load_module modules/ngx_http_headers_more_filter_module.so;\n\
load_module modules/ngx_http_geoip2_module.so;\n\
load_module modules/ngx_http_brotli_filter_module.so;\n\
load_module modules/ngx_http_brotli_static_module.so;\n' \
        > /etc/nginx/modules-enabled/00-easydigital.conf \
    && nginx -t
