# Base images are pinned by digest, not by tag. A tag is mutable: the same
# string can resolve to a different image tomorrow, so a tag-only pin means the
# thing that was scanned and the thing that ships need not be identical.
# docker-nginx-lego pins the same way, and its version watcher re-resolves the
# digest whenever it bumps the tag.
FROM --platform=$BUILDPLATFORM golang:1.26.10-alpine@sha256:87c65a688975c0b1d4585d204874c45ca78354670e3a5f11368c5a492303d696 AS build_deps

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
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# The base digest can lag behind a zlib fix that Alpine has already shipped in
# this branch. Upgrading by name, not pinning a version, picks up the fix and
# never breaks when Alpine retires an old package. The release still scans the
# image it actually built.
RUN apk upgrade --no-cache zlib && apk add --no-cache ca-certificates

COPY --from=build /workspace/webhook /usr/local/bin/webhook

# Run as a non-root user for least-privilege operation
USER nobody:nobody

ENTRYPOINT ["webhook"]
