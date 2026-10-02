# Base images are pinned by digest, not by tag. A tag is mutable: the same
# string can resolve to a different image tomorrow, so a tag-only pin means the
# thing that was scanned and the thing that ships need not be identical.
# docker-nginx-lego pins the same way, and its version watcher re-resolves the
# digest whenever it bumps the tag.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine@sha256:66f9a494af2b76ecb3eab75ff47166df61caec6d200c59d556b77327493d83a8 AS build_deps

RUN apk add --no-cache git ca-certificates

WORKDIR /workspace
ENV GO111MODULE=on

COPY go.mod go.sum ./
RUN go mod download

FROM build_deps AS build

COPY . .

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build \
    -o webhook \
    -ldflags '-w -extldflags "-static"' \
    .

# ── Runtime image ────────────────────────────────────────────────────────────
FROM alpine:3.24@sha256:d56c381f961d307a21b3ca004cf1e3910f106644aefb1f43e654c8a56c4fd395

RUN apk add --no-cache ca-certificates

COPY --from=build /workspace/webhook /usr/local/bin/webhook

# Run as a non-root user for least-privilege operation
USER nobody:nobody

ENTRYPOINT ["webhook"]
