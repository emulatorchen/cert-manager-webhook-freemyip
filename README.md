# cert-manager-webhook-freemyip

**Let's Encrypt wildcard certificates for a freemyip.com domain, on Kubernetes.**

[![Release](https://img.shields.io/github/v/release/emulatorchen/cert-manager-webhook-freemyip?label=release&sort=semver)](https://github.com/emulatorchen/cert-manager-webhook-freemyip/releases)
[![Docker Hub](https://img.shields.io/docker/v/emulator/cert-manager-webhook-freemyip?label=docker%20hub&sort=semver)](https://hub.docker.com/r/emulator/cert-manager-webhook-freemyip)
[![Helm chart](https://img.shields.io/badge/helm-chart%20repository-0f1689)](https://emulatorchen.github.io/cert-manager-webhook-freemyip)
[![License](https://img.shields.io/github/license/emulatorchen/cert-manager-webhook-freemyip)](LICENSE)

A [cert-manager](https://cert-manager.io) ACME DNS-01 webhook solver for
[freemyip.com](https://freemyip.com) dynamic DNS.

The webhook implements the cert-manager external DNS solver protocol so that
Let's Encrypt can verify domain ownership — including wildcard certificates —
using the freemyip TXT-record API.

## How it works

freemyip exposes a single HTTP endpoint that manages both A-records and TXT
records for your registered domain.

freemyip applies the update to whichever domain the token owns, publishing at
`_acme-challenge.<that domain>` regardless of what `domain` says. The parameter
is effectively ignored.

That matters for one reason: **a token for the wrong domain fails silently.**
freemyip answers `OK` and writes the record under its own domain, so the solver
reports success while validation never finds the record. Each freemyip domain
has its own token, so check the token matches the domain you are issuing for.

```
GET https://freemyip.com/update

  token    your freemyip API token
  domain   _acme-challenge.example.freemyip.com
  txt      the challenge value to publish (Present),
           or empty to clear the record (CleanUp)
```

Sending `example.freemyip.com` instead publishes the record one label too high.
freemyip accepts that and answers `OK`, so it looks like it worked, but no ACME
validation can succeed.

The webhook calls this endpoint in response to cert-manager's `Present` and
`CleanUp` calls, allowing Let's Encrypt to verify `_acme-challenge.example.freemyip.com`.

## Prerequisites

- cert-manager ≥ v1.8.0 installed in the cluster
- A registered domain on freemyip.com (e.g. `example.freemyip.com`)
- Your freemyip API token

## Build

```bash
# Run go mod tidy first to populate go.sum
make tidy

# Build the binary locally
make build

# Build and push Docker image
IMAGE_REGISTRY=ghcr.io/emulatorchen IMAGE_TAG=0.1.0 make docker-push
```

## Install

```bash
helm repo add cert-manager-webhook-freemyip \
  https://emulatorchen.github.io/cert-manager-webhook-freemyip
helm repo update

cat > values.yaml <<'EOF'
clusterIssuer:
  email: you@example.com
  staging:
    create: true
  production:
    create: true
EOF

helm upgrade --install cert-manager-webhook-freemyip \
  cert-manager-webhook-freemyip/cert-manager-webhook-freemyip \
  --namespace cert-manager -f values.yaml
```

Supply the freemyip API key one of two ways. Either set `freemyip.token` in that
values file and let the chart create the Secret, or create the Secret yourself in
the `cert-manager` namespace with a single key named `token`, then point the
chart at it with `secret.existingSecret` and `secret.existingSecretName`. The
second keeps the key out of the values file and out of your shell history.

Use a values file rather than `--set` either way: anything on the command line is
visible in the process list to every other user on the machine.

The chart defaults to `docker.io/emulator/cert-manager-webhook-freemyip` at the
chart's `appVersion`, so no image override is needed. The same image is published
to `ghcr.io/emulatorchen/cert-manager-webhook-freemyip` for anyone who prefers it:

```bash
  --set image.repository=ghcr.io/emulatorchen/cert-manager-webhook-freemyip
```

The chart is also published as an OCI artifact, and as a `.tgz` attached to each
GitHub release:

```bash
helm upgrade --install cert-manager-webhook-freemyip \
  oci://ghcr.io/emulatorchen/charts/cert-manager-webhook-freemyip \
  --version 0.1.0 --namespace cert-manager
```

## Usage

Reference the ClusterIssuer in a Certificate or Ingress annotation:

```yaml
# Ingress annotation
cert-manager.io/cluster-issuer: cert-manager-webhook-freemyip-production

# Certificate resource
spec:
  issuerRef:
    name: cert-manager-webhook-freemyip-production
    kind: ClusterIssuer
  dnsNames:
    - example.freemyip.com
    - "*.example.freemyip.com"
```

## Configuration reference

| Value | Default | Description |
|-------|---------|-------------|
| `freemyip.token` | `""` | freemyip API token (stored in a Secret) |
| `clusterIssuer.email` | `name@example.com` | Email for Let's Encrypt registration |
| `clusterIssuer.production.create` | `false` | Create the production ClusterIssuer |
| `clusterIssuer.staging.create` | `false` | Create the staging ClusterIssuer |
| `image.repository` | `docker.io/emulator/cert-manager-webhook-freemyip` | Image registry path |
| `image.tag` | `""` | Image tag; empty uses the chart `appVersion` |
| `image.digest` | set per release | Exact published image; overrides `image.tag` when set. Clear it to choose by tag |
| `groupName` | `acme.freemyip.emulatorchen.github.com` | Webhook group name (must be unique) |

## Vulnerability scan

Every release scans the image it actually published and puts the result at the
end of its release notes, with the severity counts first:
[scan of the latest release](https://github.com/emulatorchen/cert-manager-webhook-freemyip/releases/latest#vulnerability-scan).
Each earlier release keeps its own scan in its own notes.

## Common questions

**Can it issue wildcard certificates?**
Yes. DNS-01 is the only challenge type Let's Encrypt accepts for a wildcard
name, and this solver performs DNS-01, so a Certificate listing both
`example.freemyip.com` and `*.example.freemyip.com` is issued normally.

**Why does issuance fail when freemyip answered `OK`?**
The token, not the `domain` parameter, decides where the record is published.
A token for the wrong domain fails silently — see [How it works](#how-it-works).

**Do I have to use the Helm chart?**
In practice, yes. cert-manager reaches the solver through an `APIService`, and
the chart is what registers it along with the RBAC the webhook needs to read
its Secret. Running the image on its own does nothing.

**Which architectures are published?**
`linux/amd64` and `linux/arm64`. Every published image carries a build
provenance attestation and an SBOM; version tags are immutable, and `latest`
moves only on a reviewed release.

**Is it affiliated with freemyip.com, cert-manager or Let's Encrypt?**
No. It is an independent webhook solver that talks to the public freemyip API.

## Links

- [Helm chart repository](https://emulatorchen.github.io/cert-manager-webhook-freemyip)
- [Docker Hub](https://hub.docker.com/r/emulator/cert-manager-webhook-freemyip)
- [GitHub Container Registry](https://github.com/emulatorchen/cert-manager-webhook-freemyip/pkgs/container/cert-manager-webhook-freemyip)
- [Releases and changelog](https://github.com/emulatorchen/cert-manager-webhook-freemyip/releases)
- [cert-manager webhook solver documentation](https://cert-manager.io/docs/configuration/acme/dns01/webhook/)

## License

Apache 2.0 — see [LICENSE](LICENSE).
