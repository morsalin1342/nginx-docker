# Contributing

Thanks for your interest in improving this nginx Docker image!

## How to Contribute

### Request a New Module
1. Open an issue with the title `Module request: <name>`
2. Provide the repository URL and a tag or commit to pin
3. State the module's last release and last commit date — an unmaintained module is
   unlikely to be added, and for anything security-related that is disqualifying
4. Explain the use case — what can it do that stock nginx cannot?

Check first that nginx does not already do it. Rate limiting, connection limiting,
`real_ip`, HTTP/2, HTTP/3, gzip, `sub_filter`, `secure_link`, `auth_request`, `map`, `geo`
and the whole `stream` and `mail` families are already in the official image, and the
README lists what is NGINX Plus only and cannot be added to an open-source build at all.

### Report a Bug
1. Open an issue with details: image tag, error message, steps to reproduce
2. If the bug is about a module not loading, include `nginx -V` and the contents of
   `/etc/nginx/modules-enabled/10-modules.conf`

### Submit a Pull Request
1. Fork the repo and create a feature branch
2. Pin your module to a tag or commit — never a moving branch
3. Add it to the `./configure` line in the modules stage
4. Test locally:
   ```bash
   docker build -t test-nginx .
   docker run --rm test-nginx nginx -V
   docker run --rm test-nginx nginx -t
   ```
5. Open a PR against `master` with a clear description

## Project Structure

```
.
├── Dockerfile                 # Three stages: libmodsecurity, modules, final image
├── .github/workflows/         # CI/CD pipeline
├── README.md                  # GitHub README
├── README.dockerhub.md        # Personal Docker Hub description
└── README.dockerhub-org.md    # Org Docker Hub description
```

## Version Upgrades

To upgrade nginx:
1. Update `ARG NGINX_VERSION` in the `Dockerfile` — it feeds both the source tarball and
   the final stage's base image, and they **must** match or the modules will not load
2. Bump `OTEL_MODULE_VERSION` if needed; the package is pinned as
   `<nginx>+<module>-1~<release>` and apt refuses a mismatched pair
3. Test the build locally
4. The CI pipeline auto-detects the new version for tagging

## Code Style
- Keep the Dockerfile readable with clear section headers
- Every module is pinned to a tag or commit, and every pin is explained
- Record *why* a decision was made, not just what it was — the Dockerfile comments and
  the README's "Why there is no Lua" section are the standard to match
