# pipemesh/consume

Fetches what the Pipemesh job that dispatched this run consumes
([DESIGN-V59 §7](https://pipemesh.io/docs)): file entries unpack at their
own paths, and every entry becomes the variable the job's `consumes:`
names — `APP: build/app` is `$APP` (a file's path, or `ref@digest` for
an image).

```yaml
# pipemesh.yaml
sign:
  consumes: { APP: build/app }
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
      - run: ./scripts/sign-and-notarize.sh "$APP"
      - uses: actions/upload-artifact@v4
        with: { name: signed-app, path: dist/LocalSlack-signed.zip }
```

The run proves itself with its own GitHub OIDC token (hence `id-token:
write`); the `pipemesh_run` input only names the job run. `with: artifacts:`
narrows to some of the granted keys — a key the job's `consumes:` does not
list is refused.

## Pipemesh's registry

`registry-login: true` also logs the run in to Pipemesh's registry
(DESIGN-V142 §3), with a login for exactly what the job may reach: pull
on the images it consumes there, push on its `oci` keys' places
(`pipemesh/produce` with `place: true` says where).

```yaml
permissions: { id-token: write, contents: read }
steps:
  - id: pipemesh
    uses: pipemesh/consume@v1
    with:
      registry-login: true
  - run: docker run --rm "$APP" ./smoke-test   # $APP: an image the job consumes, ref@digest
```

- **With `docker` on the runner** it runs `docker login`, so docker,
  buildx, crane and Jib (which read Docker's config) pull and push.
- **Outputs** `registry` (the host), `registry-username` and
  `registry-password` (masked in the log) are for any other tool:
  `crane auth login "${{ steps.pipemesh.outputs.registry }}" -u … -p …`.
- **The login is valid 15 minutes,** minted when the step runs: put the
  step right before the pulls and pushes.
- **Needs** a Pipemesh instance with a registry of its own, and one that
  hands out registry logins to Actions runs (`POST
  /api/runtime/actions/images/credential`); others refuse the step.
