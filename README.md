# pipemesh/consume

Fetches what the Pipemesh job that dispatched this run consumes
([DESIGN-V59 §7](https://pipemesh.io/docs)): file entries unpack at their
own paths, and every entry becomes a variable — `build/app` is
`$PIPEMESH_BUILD_APP` (a file's path, or `ref@digest` for an image).

```yaml
# pipemesh.yaml
sign:
  consumes: [build/app]
  produces: { signed-app: file }
  delegate: { type: github_actions, params: { workflow: sign.yml } }
```

```yaml
# .github/workflows/sign.yml
on:
  workflow_dispatch:
    inputs:
      pipemesh_sha: { required: true }
      pipemesh_run: { required: true }
permissions: { id-token: write, contents: read }
jobs:
  sign:
    runs-on: macos-latest
    steps:
      - uses: pipemesh/consume@v1
      - run: ./scripts/sign-and-notarize.sh "$PIPEMESH_BUILD_APP"
      - uses: actions/upload-artifact@v4
        with: { name: signed-app, path: dist/LocalSlack-signed.zip }
```

The run proves itself with its own GitHub OIDC token (hence `id-token:
write`); the `pipemesh_run` input only names the job run. `with: artifacts:`
narrows to some of the granted keys — a key the job's `consumes:` does not
list is refused.
