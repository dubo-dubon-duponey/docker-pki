ARG           FROM_REGISTRY=ghcr.io/dubo-dubon-duponey

ARG           FROM_IMAGE_BUILDER=base:builder-bullseye-2021-09-01@sha256:12be2a6d0a64b59b1fc44f9b420761ad92efe8188177171163b15148b312481a
ARG           FROM_IMAGE_AUDITOR=base:auditor-bullseye-2021-09-01@sha256:28d5eddcbbee12bc671733793c8ea8302d7d79eb8ab9ba0581deeacabd307cf5
ARG           FROM_IMAGE_RUNTIME=base:runtime-bullseye-2021-09-01@sha256:bbd3439247ea1aa91b048e77c8b546369138f910b5083de697f0d36ac21c1a8c
ARG           FROM_IMAGE_TOOLS=tools:linux-bullseye-2021-09-01@sha256:e5535efb771ca60d2a371cd2ca2eb1a7d6b7b13cc5c4d27d48613df1a041431d

FROM          $FROM_REGISTRY/$FROM_IMAGE_TOOLS                                                                          AS builder-tools

FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_BUILDER                                              AS fetcher-certstrap

ARG           GIT_REPO=github.com/square/certstrap
ARG           GIT_VERSION=1768704
ARG           GIT_COMMIT=17687043c6aa40489620cfba2d6350d586cda8ed

ENV           WITH_BUILD_SOURCE="."
ENV           WITH_BUILD_OUTPUT="certstrap"
ENV           WITH_LDFLAGS=""

RUN           git clone --recurse-submodules git://"$GIT_REPO" .; git checkout "$GIT_COMMIT"
RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=NETRC \
              [[ "${GOFLAGS:-}" == *-mod=vendor* ]] || go mod download

FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_BUILDER                                              AS fetcher-step

ARG           GIT_REPO=github.com/smallstep/certificates
ARG           GIT_VERSION=v0.17.2
ARG           GIT_COMMIT=9e7a3cd897dfe4518b4afd861cf4f3a42d11bf7d

ENV           WITH_BUILD_SOURCE="./cmd/step-ca"
ENV           WITH_BUILD_OUTPUT="step-ca"
ENV           WITH_LDFLAGS="-X main.Version=${GIT_VERSION} -X main.BuildTime=${BUILD_CREATED}"

ENV           CGO_ENABLED=1
ENV           WITH_CGO_NET=true

RUN           git clone --recurse-submodules git://"$GIT_REPO" .; git checkout "$GIT_COMMIT"

RUN           echo "replace github.com/micromdm/scep/v2 v2.0.0 => github.com/micromdm/scep/v2 v2.1.0" >> go.mod
RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=NETRC \
              go mod tidy
#              sed -Ei 's/scep\/v2 v2.0.0/scep\/v2 v2.1.0/g' go.mod; go mod tidy

RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=NETRC \
              [[ "${GOFLAGS:-}" == *-mod=vendor* ]] || go mod download

RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              apt-get update -qq; \
              apt-get install -qq --no-install-recommends ninja-build=1.10.1-1; \
              for architecture in armel armhf arm64 ppc64el i386 s390x amd64; do \
                apt-get install -qq --no-install-recommends \
                  libpcsclite-dev:"$architecture"=1.9.1-1; \
              done

FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_BUILDER                                              AS fetcher-step-cli

ARG           GIT_REPO=github.com/smallstep/cli
ARG           GIT_VERSION=v0.17.2
ARG           GIT_COMMIT=4c11bf97d32d0dfba05e4764c62327c3423fb52d

ENV           WITH_BUILD_SOURCE="./cmd/step"
ENV           WITH_BUILD_OUTPUT="step"
ENV           WITH_LDFLAGS="-X main.Version=${GIT_VERSION} -X main.BuildTime=${BUILD_CREATED}"

ENV           CGO_ENABLED=1
ENV           WITH_CGO_NET=true

RUN           git clone --recurse-submodules git://"$GIT_REPO" .; git checkout "$GIT_COMMIT"

RUN           echo "replace github.com/micromdm/scep/v2 v2.0.0 => github.com/micromdm/scep/v2 v2.1.0" >> go.mod
RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=NETRC \
              go mod tidy

RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=NETRC \
              [[ "${GOFLAGS:-}" == *-mod=vendor* ]] || go mod download


FROM          --platform=$BUILDPLATFORM fetcher-certstrap                                                               AS builder-certstrap

ARG           TARGETARCH
ARG           TARGETOS
ARG           TARGETVARIANT
ENV           GOOS=$TARGETOS
ENV           GOARCH=$TARGETARCH

ENV           CGO_CFLAGS="${CFLAGS:-} ${ENABLE_PIE:+-fPIE}"
ENV           GOFLAGS="-trimpath ${ENABLE_PIE:+-buildmode=pie} ${GOFLAGS:-}"

# Important cases being handled:
# - cannot compile statically with PIE but on amd64 and arm64
# - cannot compile fully statically with NETCGO
RUN           export GOARM="$(printf "%s" "$TARGETVARIANT" | tr -d v)"; \
              [ "${CGO_ENABLED:-}" != 1 ] || { \
                eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
                export PKG_CONFIG="${DEB_TARGET_GNU_TYPE}-pkg-config"; \
                export AR="${DEB_TARGET_GNU_TYPE}-ar"; \
                export CC="${DEB_TARGET_GNU_TYPE}-gcc"; \
                export CXX="${DEB_TARGET_GNU_TYPE}-g++"; \
                [ ! "${ENABLE_STATIC:-}" ] || { \
                  [ ! "${WITH_CGO_NET:-}" ] || { \
                    ENABLE_STATIC=; \
                    LDFLAGS="${LDFLAGS:-} -static-libgcc -static-libstdc++"; \
                  }; \
                  [ "$GOARCH" == "amd64" ] || [ "$GOARCH" == "arm64" ] || [ "${ENABLE_PIE:-}" != true ] || ENABLE_STATIC=; \
                }; \
                WITH_LDFLAGS="${WITH_LDFLAGS:-} -linkmode=external -extld="$CC" -extldflags \"${LDFLAGS:-} ${ENABLE_STATIC:+-static}${ENABLE_PIE:+-pie}\""; \
                WITH_TAGS="${WITH_TAGS:-} cgo ${ENABLE_STATIC:+static static_build}"; \
              }; \
              go build -ldflags "-s -w -v ${WITH_LDFLAGS:-}" -tags "${WITH_TAGS:-} net${WITH_CGO_NET:+c}go osusergo" -o /dist/boot/bin/"$WITH_BUILD_OUTPUT" "$WITH_BUILD_SOURCE"

FROM          --platform=$BUILDPLATFORM fetcher-step                                                                    AS builder-step

ARG           TARGETARCH
ARG           TARGETOS
ARG           TARGETVARIANT
ENV           GOOS=$TARGETOS
ENV           GOARCH=$TARGETARCH

ENV           CGO_CFLAGS="${CFLAGS:-} ${ENABLE_PIE:+-fPIE}"
ENV           GOFLAGS="-trimpath ${ENABLE_PIE:+-buildmode=pie} ${GOFLAGS:-}"

# Important cases being handled:
# - cannot compile statically with PIE but on amd64 and arm64
# - cannot compile fully statically with NETCGO
RUN           export GOARM="$(printf "%s" "$TARGETVARIANT" | tr -d v)"; \
              [ "${CGO_ENABLED:-}" != 1 ] || { \
                eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
                export PKG_CONFIG="${DEB_TARGET_GNU_TYPE}-pkg-config"; \
                export AR="${DEB_TARGET_GNU_TYPE}-ar"; \
                export CC="${DEB_TARGET_GNU_TYPE}-gcc"; \
                export CXX="${DEB_TARGET_GNU_TYPE}-g++"; \
                [ ! "${ENABLE_STATIC:-}" ] || { \
                  [ ! "${WITH_CGO_NET:-}" ] || { \
                    ENABLE_STATIC=; \
                    LDFLAGS="${LDFLAGS:-} -static-libgcc -static-libstdc++"; \
                  }; \
                  [ "$GOARCH" == "amd64" ] || [ "$GOARCH" == "arm64" ] || [ "${ENABLE_PIE:-}" != true ] || ENABLE_STATIC=; \
                }; \
                WITH_LDFLAGS="${WITH_LDFLAGS:-} -linkmode=external -extld="$CC" -extldflags \"${LDFLAGS:-} ${ENABLE_STATIC:+-static}${ENABLE_PIE:+-pie}\""; \
                WITH_TAGS="${WITH_TAGS:-} cgo ${ENABLE_STATIC:+static static_build}"; \
              }; \
              go build -ldflags "-s -w -v ${WITH_LDFLAGS:-}" -tags "${WITH_TAGS:-} net${WITH_CGO_NET:+c}go osusergo" -o /dist/boot/bin/"$WITH_BUILD_OUTPUT" "$WITH_BUILD_SOURCE"

RUN           eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
              mkdir -p /dist/boot/lib; \
              cp /usr/lib/"$DEB_TARGET_MULTIARCH"/libpcsclite.so.1   /dist/boot/lib

FROM          --platform=$BUILDPLATFORM fetcher-step-cli                                                                AS builder-step-cli

ARG           TARGETARCH
ARG           TARGETOS
ARG           TARGETVARIANT
ENV           GOOS=$TARGETOS
ENV           GOARCH=$TARGETARCH

ENV           CGO_CFLAGS="${CFLAGS:-} ${ENABLE_PIE:+-fPIE}"
ENV           GOFLAGS="-trimpath ${ENABLE_PIE:+-buildmode=pie} ${GOFLAGS:-}"

# Important cases being handled:
# - cannot compile statically with PIE but on amd64 and arm64
# - cannot compile fully statically with NETCGO
RUN           export GOARM="$(printf "%s" "$TARGETVARIANT" | tr -d v)"; \
              [ "${CGO_ENABLED:-}" != 1 ] || { \
                eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
                export PKG_CONFIG="${DEB_TARGET_GNU_TYPE}-pkg-config"; \
                export AR="${DEB_TARGET_GNU_TYPE}-ar"; \
                export CC="${DEB_TARGET_GNU_TYPE}-gcc"; \
                export CXX="${DEB_TARGET_GNU_TYPE}-g++"; \
                [ ! "${ENABLE_STATIC:-}" ] || { \
                  [ ! "${WITH_CGO_NET:-}" ] || { \
                    ENABLE_STATIC=; \
                    LDFLAGS="${LDFLAGS:-} -static-libgcc -static-libstdc++"; \
                  }; \
                  [ "$GOARCH" == "amd64" ] || [ "$GOARCH" == "arm64" ] || [ "${ENABLE_PIE:-}" != true ] || ENABLE_STATIC=; \
                }; \
                WITH_LDFLAGS="${WITH_LDFLAGS:-} -linkmode=external -extld="$CC" -extldflags \"${LDFLAGS:-} ${ENABLE_STATIC:+-static}${ENABLE_PIE:+-pie}\""; \
                WITH_TAGS="${WITH_TAGS:-} cgo ${ENABLE_STATIC:+static static_build}"; \
              }; \
              go build -ldflags "-s -w -v ${WITH_LDFLAGS:-}" -tags "${WITH_TAGS:-} net${WITH_CGO_NET:+c}go osusergo" -o /dist/boot/bin/"$WITH_BUILD_OUTPUT" "$WITH_BUILD_SOURCE"

#######################
# Builder assembly
#######################
FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_AUDITOR                                              AS builder

COPY          --from=builder-tools          /boot/bin/goello-server /dist/boot/bin

COPY          --from=builder-certstrap       /dist /dist
COPY          --from=builder-step            /dist /dist
COPY          --from=builder-step-cli        /dist /dist
RUN           setcap 'cap_net_bind_service+ep' /dist/boot/bin/ghostunnel
RUN           patchelf --set-rpath '/boot/lib' /dist/boot/bin/step-ca
RUN           setcap 'cap_net_bind_service+ep' /dist/boot/bin/step-ca

RUN           chmod 555 /dist/boot/bin/*; \
              epoch="$(date --date "$BUILD_CREATED" +%s)"; \
              find /dist/boot -newermt "@$epoch" -exec touch --no-dereference --date="@$epoch" '{}' +;

#######################
# Runtime
#######################
FROM          $FROM_REGISTRY/$FROM_IMAGE_RUNTIME

USER          root

# Prepare dbus
RUN           mkdir -p /run/dbus; chown "$BUILD_UID":root /run/dbus; chmod 775 /run/dbus

# ca-certificates=20200601~deb10u1 is not necessary in itself
# Removing fuse for now - fuse-overlay is just too buggy
# fuse3=3.10.3-1 \
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              apt-get update -qq && apt-get install -qq --no-install-recommends \
                libnss-mdns=0.14.1-2 && \
              apt-get -qq autoremove      && \
              apt-get -qq clean           && \
              rm -rf /var/lib/apt/lists/* && \
              rm -rf /tmp/*               && \
              rm -rf /var/tmp/*

RUN           echo dubo-dubon-duponey:100000:65536 | tee /etc/subuid | tee /etc/subgid

VOLUME        /run

COPY          --from=builder --chown=$BUILD_UID:root /dist /

USER          dubo-dubon-duponey

# Current config below is full-blown regular caddy config, which is only partly useful here
# since caddy only role is to provide and renew TLS certificates

### Front server configuration
# Port to use
ENV           PORT=4443
ENV           PORT_HTTP=80
EXPOSE        4443
EXPOSE        80
# Log verbosity for
ENV           LOG_LEVEL="warn"
# Domain name to serve
ENV           DOMAIN="$NICK.local"
ENV           ADDITIONAL_DOMAINS=""

# Whether the server should behave as a proxy (disallows mTLS)
ENV           SERVER_NAME="DuboDubonDuponey/1.0 (Caddy/2) [$NICK]"

# Control wether tls is going to be "internal" (eg: self-signed), or alternatively an email address to enable letsencrypt
# XXX disable by default for now until:
# - figure out a better solution that misusing caddy to manage and rotate the certs
# - figure out buildkit behavior wrt cert rotation (bounce?)
# - figure out performance impact of TLS over buildtime
ENV           TLS=""
# "internal"
# 1.2 or 1.3
ENV           TLS_MIN=1.2
# Either require_and_verify or verify_if_given
ENV           TLS_MTLS_MODE="verify_if_given"
# Issuer name to appear in certificates
#ENV           TLS_ISSUER="Dubo Dubon Duponey"
# Either disable_redirects or ignore_loaded_certs if one wants the redirects
ENV           TLS_AUTO=disable_redirects

ENV           AUTH_ENABLED=false
# Realm in case access is authenticated
ENV           AUTH_REALM="My Precious Realm"
# Provide username and password here (call the container with the "hash" command to generate a properly encrypted password, otherwise, a random one will be generated)
ENV           AUTH_USERNAME="dubo-dubon-duponey"
ENV           AUTH_PASSWORD="cmVwbGFjZV9tZV93aXRoX3NvbWV0aGluZwo="

### mDNS broadcasting
# Enable/disable mDNS support
ENV           MDNS_ENABLED=false
# Name is used as a short description for the service
ENV           MDNS_NAME="$NICK mDNS display name"
# The service will be annonced and reachable at $MDNS_HOST.local
ENV           MDNS_HOST="$NICK"
# Type to advertise
ENV           MDNS_TYPE="_http._tcp"

# Caddy certs will be stored here
VOLUME        /certs

# Caddy uses this
VOLUME        /tmp

# Used by the backend service
VOLUME        /data

ENV           HEALTHCHECK_URL="tcp://127.0.0.1:$PORT"

HEALTHCHECK   --interval=120s --timeout=30s --start-period=10s --retries=1 CMD buildctl --addr "$HEALTHCHECK_URL" debug workers || exit 1
