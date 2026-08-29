# The build image for the Linux hosts. Both of them: the digest is a manifest
# list, so the same line builds an arm64 image on an arm64 machine and an
# amd64 one on Intel, the way the two macOS runners work.
#
# 22.04 is not a free choice. wasmer's LLVM binaries need GLIBC_2.34 and
# GLIBCXX_3.4.30 -- they were built on 22.04 -- so nothing older can run
# llvm-config, and without llvm-config there is no build. Ubuntu 20.04 was the
# first choice and it cannot start a single one of them.
#
# What we ship comes out asking for glibc 2.34, not the 2.35 the image has:
# nothing on the link line reaches for a symbol newer than that. So the floor
# is 2.34 -- RHEL 9, Amazon Linux 2023, Ubuntu 22.04, Debian 12 -- and it is
# measured by `build-rustc verify`, not assumed here.
#
# A user still needs a C toolchain. rustc links through `cc`, and on a machine
# without one `cargo build` stops at "linker `cc` not found". That is a
# prerequisite, documented, not something the toolchain can carry.
FROM ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc

ENV DEBIAN_FRONTEND=noninteractive
# patchelf is the install_name_tool of this platform: `bundle` needs it to set
# RUNPATH. perl is for cargo's vendored OpenSSL. Everything else is what
# bootstrap asks for.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential binutils ca-certificates cmake curl file git \
      ninja-build patchelf perl pkg-config python3 xz-utils zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /work
