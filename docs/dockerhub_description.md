# cert-manager-webhook-freemyip

A [cert-manager](https://cert-manager.io) ACME DNS-01 webhook solver for
[freemyip.com](https://freemyip.com) dynamic DNS, so Let's Encrypt can issue
certificates — including wildcards — for a freemyip domain.

Source and issues: https://github.com/emulatorchen/cert-manager-webhook-freemyip

## Tags

| Tag | Meaning |
|-----|---------|
| `latest` | The most recent release. Moves only on a reviewed release. |
| `X.Y.Z` | An immutable version, matching the chart `appVersion` and the `vX.Y.Z` git tag. |

Built for `linux/amd64` and `linux/arm64`. Every published image carries a
build provenance attestation and an SBOM.

## Install

The image is not run directly — it is deployed by the Helm chart, which also
creates the `APIService` cert-manager needs.

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

Supply the freemyip API key either by setting `freemyip.token` in that values
file, or by creating a Secret yourself with a single key named `token` and
pointing the chart at it with `secret.existingSecret` and
`secret.existingSecretName`.

The chart defaults to this image, so no `image.repository` override is needed.

## Usage

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
spec:
  secretName: example-tls
  issuerRef:
    name: cert-manager-webhook-freemyip-production
    kind: ClusterIssuer
  dnsNames:
    - example.freemyip.com
    - "*.example.freemyip.com"
```

## One thing to know about freemyip

freemyip applies an update to whichever domain the **token** owns, publishing at
`_acme-challenge.<that domain>` regardless of the `domain` parameter. A token
for the wrong domain therefore fails silently: the API answers `OK`, the solver
reports success, and validation never finds the record. Each freemyip domain has
its own token — check the token matches the domain you are issuing for.

## Requirements

- cert-manager ≥ v1.8.0 in the cluster
- A registered freemyip.com domain and its API token

## License

Apache 2.0.
