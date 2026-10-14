# Build environment of the Linux daemon binaries (add-release-distribution
# decision 10). Debian 11 has glibc 2.31 and GCC 10, so OTP, its static
# OpenSSL and erlexec's port program compiled here run on glibc >= 2.31.
# scripts/build-daemon.sh builds this image and runs itself inside it as the
# calling user; OTP (scripts/build-erts.sh), Elixir and zig
# (scripts/build-tools.sh) are built or downloaded into the mounted cache.
FROM debian:bullseye

# Debian 11 is archived: its packages, security updates included, are served
# from archive.debian.org.
RUN printf '%s\n' \
    'deb http://archive.debian.org/debian bullseye main' \
    'deb http://archive.debian.org/debian bullseye-updates main' \
    'deb http://archive.debian.org/debian-security bullseye-security main' \
    >/etc/apt/sources.list \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl perl unzip xz-utils \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
