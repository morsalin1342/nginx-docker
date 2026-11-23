## Description
<!-- What does this PR do? -->

## Type of change
- [ ] New nginx module added
- [ ] Version upgrade
- [ ] Bug fix
- [ ] Configuration change
- [ ] Documentation update

## Testing
<!-- How did you test this change? -->
```bash
docker build -t test-nginx .
docker run --rm test-nginx nginx -V
docker run --rm test-nginx nginx -t
```

## Checklist
- [ ] I have tested the Docker build locally
- [ ] The module is pinned to a tag or commit — never a moving branch
- [ ] The module is added to the `./configure` line in the modules stage
- [ ] `nginx -t` and the startup check both pass in the final stage
- [ ] No unrelated changes are included
