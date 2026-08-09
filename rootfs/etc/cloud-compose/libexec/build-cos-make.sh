#!/bin/sh

set -eux

MAKE_VERSION="4.4.1"
MAKE_SHA256="dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"

# A single Alpine CDN outage must not make a healthy VM replacement fail.
# These are HTTPS endpoints from the Alpine official mirror list; apk still
# verifies the signed indexes and packages with the keys baked into the pinned
# image.
alpine_mirrors="
    https://dl-cdn.alpinelinux.org/alpine
    https://mirror.math.princeton.edu/pub/alpinelinux
    https://mirror.fel.cvut.cz/alpine
"
packages_installed=false
for alpine_mirror in ${alpine_mirrors}; do
    printf "%s\n%s\n" \
        "${alpine_mirror}/v3.22/main" \
        "${alpine_mirror}/v3.22/community" \
        >/etc/apk/repositories
    rm -f /var/cache/apk/*
    if apk update && apk add build-base curl make tar; then
        packages_installed=true
        break
    fi
    echo "Alpine package mirror failed: ${alpine_mirror}" >&2
done
if [ "${packages_installed}" != true ]; then
    echo "All configured Alpine package mirrors failed" >&2
    exit 1
fi

curl -fsSL --proto "=https" --proto-redir "=https" --tlsv1.2 \
    --retry 5 --retry-all-errors --retry-delay 2 --retry-max-time 900 \
    --connect-timeout 10 --max-time 300 \
    "https://ftp.gnu.org/gnu/make/make-${MAKE_VERSION}.tar.gz" -o /tmp/make.tar.gz
echo "${MAKE_SHA256}  /tmp/make.tar.gz" | sha256sum -c -
tar -xzf /tmp/make.tar.gz -C /tmp
cd "/tmp/make-${MAKE_VERSION}"
LDFLAGS="-static" ./configure --disable-nls
make -j2
install -m 0755 make /out/.cloud-compose-make.pending
/out/.cloud-compose-make.pending --version | grep -Fqm 1 "GNU Make ${MAKE_VERSION}"
mv -f /out/.cloud-compose-make.pending /out/make
