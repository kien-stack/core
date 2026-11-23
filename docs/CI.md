# CI

**What it does:**

- Every pull request: lints and tests the Helm charts (`Charts test result` check).
- Every week: Renovate opens PRs for new chart, image and action versions.
- On `main`: release-please opens a release PR; merge it to publish a release.

**How to use it:**

- Open a PR and wait for `Charts test result` to be green.
- Run the same checks locally: `bash hack/validate.sh`.
- Renovate: install the [Renovate GitHub App](https://github.com/apps/renovate) on your repo.
- Write commits as `feat: ...`, `fix: ...` so releases get the right version.
