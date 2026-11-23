#!/usr/bin/env bash
# Compare every version the Dockerfile pins with the latest upstream release.
#
# Trivy scans the image's Debian packages, but it cannot see what this image
# builds from source (libmodsecurity, the nginx modules, zstd, the Core Rule
# Set), and Dependabot cannot move a FROM line built from an ARG. This script
# covers both: it reads each pin from the Dockerfile, asks upstream for the
# newest release, and exits 1 listing every pin that is behind. It also checks
# that each pinned tag still points at the pinned commit.
#
# Usage: scripts/check-upstream.sh [path/to/Dockerfile]
# Needs bash, curl and jq. Set GITHUB_TOKEN to avoid GitHub's anonymous rate
# limit (the workflow passes its own token).

set -euo pipefail

DOCKERFILE="${1:-Dockerfile}"
behind=()
failed=()
mismatched=()

arg() {
    local value
    value="$(sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -n1)"
    [ -n "$value" ] || { echo "ARG $1 not found in $DOCKERFILE" >&2; exit 2; }
    printf '%s' "$value"
}

fetch() { curl -fsSL --retry 3 --max-time 60 "$@"; }

gh_api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        fetch -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            "https://api.github.com/$1"
    else
        fetch -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
    fi
}

# Newest non-draft, non-prerelease release whose tag matches a pattern.
latest_release() {
    gh_api "repos/$1/releases?per_page=100" \
        | jq -r '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name' \
        | grep -E "$2" | sort -V | tail -n1
}

# Newest tag matching a pattern, for projects that tag without releasing.
latest_tag() {
    gh_api "repos/$1/tags?per_page=100" | jq -r '.[].name' | grep -E "$2" | sort -V | tail -n1
}

# The commit a tag points at, through an annotated tag object if there is one.
tag_commit() {
    local ref type sha
    ref="$(gh_api "repos/$1/git/ref/tags/$2")"
    type="$(jq -r .object.type <<<"$ref")"
    sha="$(jq -r .object.sha <<<"$ref")"
    if [ "$type" = tag ]; then
        sha="$(gh_api "repos/$1/git/tags/$sha" | jq -r .object.sha)"
    fi
    printf '%s' "$sha"
}

# compare NAME PINNED LATEST: record NAME as behind when LATEST sorts after PINNED.
compare() {
    local name="$1" pinned="$2" latest="$3"
    if [ -z "$latest" ]; then
        failed+=("$name: could not read the latest upstream version")
    elif [ "$(printf '%s\n%s\n' "${pinned#v}" "${latest#v}" | sort -V | tail -n1)" != "${pinned#v}" ]; then
        behind+=("$name: pinned $pinned, latest $latest")
    fi
    printf '%-22s pinned %-12s latest %s\n' "$name" "$pinned" "${latest:-?}"
}

# github NAME REPO PATTERN VERSION_ARG [COMMIT_ARG] [tags]
github() {
    local name="$1" repo="$2" pattern="$3" pinned latest commit
    pinned="$(arg "$4")"
    if [ "${6:-}" = tags ]; then
        latest="$(latest_tag "$repo" "$pattern" || true)"
    else
        latest="$(latest_release "$repo" "$pattern" || true)"
    fi
    compare "$name" "$pinned" "$latest"
    if [ -n "${5:-}" ]; then
        commit="$(arg "$5")"
        if [ "$(tag_commit "$repo" "$pinned" || true)" != "$commit" ]; then
            mismatched+=("$name: tag $pinned does not point at the pinned commit $commit")
        fi
    fi
}

# nginx: the newest stable release on nginx.org, and the official image for it.
nginx_pinned="$(arg NGINX_VERSION)"
debian="$(arg DEBIAN_RELEASE)"
nginx_stable="$(fetch https://nginx.org/en/download.html \
    | grep -oE 'Stable version.*' | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
    | head -n1 | sed -E 's/^nginx-(.*)\.tar\.gz$/\1/' || true)"
compare nginx "$nginx_pinned" "$nginx_stable"

hub_digest() {
    fetch "https://hub.docker.com/v2/namespaces/library/repositories/$1/tags/$2" | jq -r '.digest // empty'
}
# The Debian release the official image is built on: `stable` and
# `stable-<release>` are the same image while the pinned release is current.
if [ "$(hub_digest nginx stable || true)" != "$(hub_digest nginx "stable-${debian}" || true)" ]; then
    behind+=("Debian release: nginx:stable is no longer nginx:stable-${debian}")
fi
if [ -z "$(hub_digest nginx "${nginx_pinned}-${debian}" || true)" ]; then
    failed+=("nginx: the base image nginx:${nginx_pinned}-${debian} was not found on Docker Hub")
fi

github ModSecurity       owasp-modsecurity/ModSecurity           '^v3\.[0-9]+\.[0-9]+$'  MODSECURITY_VERSION       MODSECURITY_COMMIT
github ModSecurity-nginx owasp-modsecurity/ModSecurity-nginx     '^v[0-9.]+$'            MODSECURITY_NGINX_VERSION MODSECURITY_NGINX_COMMIT
github CRS               coreruleset/coreruleset                 '^v4\.[0-9]+\.[0-9]+$'  CRS_VERSION
github zstd              facebook/zstd                           '^v[0-9.]+$'            ZSTD_VERSION
github headers-more      openresty/headers-more-nginx-module     '^v[0-9.]+$'            HEADERS_MORE_VERSION      HEADERS_MORE_COMMIT   tags
github GeoIP2            leev/ngx_http_geoip2_module             '^[0-9.]+$'             GEOIP2_VERSION            GEOIP2_COMMIT
github VTS               vozlt/nginx-module-vts                  '^v[0-9.]+$'            VTS_VERSION               VTS_COMMIT
github zstd-nginx-module tokers/zstd-nginx-module                '^[0-9.]+$'             ZSTD_MODULE_VERSION       ZSTD_MODULE_COMMIT
github fancyindex        aperezdc/ngx-fancyindex                 '^v[0-9.]+$'            FANCYINDEX_VERSION        FANCYINDEX_COMMIT
github cache-purge       nginx-modules/ngx_cache_purge           '^[0-9.]+$'             CACHE_PURGE_VERSION       CACHE_PURGE_COMMIT
github upload-progress   masterzen/nginx-upload-progress-module  '^v[0-9.]+$'            UPLOAD_PROGRESS_VERSION   UPLOAD_PROGRESS_COMMIT tags
github nginx-otel        nginxinc/nginx-otel                     '^v[0-9.]+$'            OTEL_MODULE_VERSION

# ngx_brotli has no releases: compare the pinned commit with the default branch.
brotli_pinned="$(arg NGX_BROTLI_COMMIT)"
brotli_head="$(gh_api repos/google/ngx_brotli/commits/master | jq -r .sha || true)"
printf '%-22s pinned %-12s latest %s\n' ngx_brotli "${brotli_pinned:0:12}" "${brotli_head:0:12}"
if [ -z "$brotli_head" ]; then
    failed+=("ngx_brotli: could not read the latest commit")
elif [ "$brotli_head" != "$brotli_pinned" ]; then
    behind+=("ngx_brotli: pinned ${brotli_pinned}, master is ${brotli_head}")
fi

# The OpenTelemetry package must exist for this exact nginx in nginx's own
# repository, and should be the newest one there.
otel_pinned="${nginx_pinned}+$(arg OTEL_MODULE_VERSION)-1~${debian}"
otel_latest="$(fetch "https://nginx.org/packages/debian/dists/${debian}/nginx/binary-amd64/Packages.gz" \
    | gzip -dc | awk '/^Package: /{p=($2=="nginx-module-otel")} p && /^Version: /{print $2}' \
    | sort -V | tail -n1 || true)"
compare nginx-module-otel "$otel_pinned" "$otel_latest"

echo
if [ "${#failed[@]}" -gt 0 ]; then
    echo "Could not check:"
    printf '  %s\n' "${failed[@]}"
fi
if [ "${#mismatched[@]}" -gt 0 ]; then
    echo "Tag and commit disagree:"
    printf '  %s\n' "${mismatched[@]}"
fi
if [ "${#behind[@]}" -gt 0 ]; then
    echo "Behind upstream:"
    printf '  %s\n' "${behind[@]}"
fi
if [ "${#failed[@]}" -gt 0 ] || [ "${#mismatched[@]}" -gt 0 ] || [ "${#behind[@]}" -gt 0 ]; then
    exit 1
fi
echo "Every pin is at the latest upstream release."
