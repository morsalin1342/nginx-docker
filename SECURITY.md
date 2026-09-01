# Security Policy

## Supported Versions

| Version  | Supported          |
|----------|--------------------|
| 1.30.4   | :white_check_mark: |

## Reporting a Vulnerability

**Please report privately**, using GitHub's private vulnerability reporting:

- [Report a vulnerability](https://github.com/morsalin1342/nginx-docker/security/advisories/new)

That keeps the details between us until there is a fix to ship. Please do not open a public
issue for a security problem — a public issue discloses the vulnerability to everyone,
including anyone who would use it, before there is anything to upgrade to.

Please include:
- A clear description of the vulnerability
- Steps to reproduce
- The image tag/version affected

We aim to respond within 48 hours and publish a fix as soon as possible.

## A note on the WAF

ModSecurity and the OWASP Core Rule Set ship in this image but **nothing loads them** —
see the README. An image running with default configuration is therefore not protected by
a WAF, and that is deliberate rather than a vulnerability. Enabling it, and choosing
detection or blocking mode, belongs to whoever runs the server.

## Supported Base Images

These images are built on top of:
- [nginx](https://github.com/nginx/nginx) — Official nginx base image
- [ModSecurity](https://github.com/owasp-modsecurity/ModSecurity) and its
  [nginx connector](https://github.com/owasp-modsecurity/ModSecurity-nginx)
- [OWASP Core Rule Set](https://github.com/coreruleset/coreruleset)
- [nginx-otel](https://github.com/nginxinc/nginx-otel) — installed from nginx's own package repository

If a vulnerability exists in an upstream component, we will update to the patched version and release updated images.
