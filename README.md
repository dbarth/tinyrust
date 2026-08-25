# tinyrust

Tinyrust installs the smallest Rust environment, to quickly bootstrap a new
project, without the 1.4GB tax of normal `rustup`.

`trustup` is tiny-rustup: it replaces `rustup` and downloads packages rebuilt to
be tiny by default. You still get the full rustup/cargo/... support. Just not
1G of precompiled HTML by default, nor the rest of the kitchen sink you won't
need anyway.

This is not meant for language developers, tinyrust is meant for developers
looking for a quick way to get started with Rust.

## The tax

macOS aarch64, rustc 1.98.0, one std target. Measured, not estimated.

| | download | installed |
|---|---|---|
| `rustup`, default profile | — | 1.4 GB |
| official components, no rustup | 84 MB | 381 MB |
| **tinyrust** | **62 MB** | **271 MB** |

| | stock | tinyrust | |
|---|---|---|---|
| compiler + LLVM | 212.7 MB | 115.4 MB | −46% |
| std | 128.9 MB | 112.4 MB | −13% |
| cargo, rustdoc, rust-objcopy | 77.2 MB | 43.1 MB | −44% |

Builds a crate with a crates.io dependency, `strip = true` release profiles,
doctests, and its own compiler again — stage2 self-hosts to within 0.02%.

## Use it

    ./trustup install
    eval "$(./trustup env)"
    cargo new hello && cd hello && cargo build --release

`trustup` is the rustup replacement. Everything lives under one directory;
nothing touches `~/.rustup`, `~/.cargo` or `PATH`, and `rm -rf toolchain` is the
uninstaller.

| | |
|---|---|
| `trustup install [DIR]` | fetch components directly, no rustup |
| `trustup install --rustup` | drive rustup, then delete what it over-installed |
| `trustup trim` | remove what a build never reads (`--rustup` only) |
| `trustup component list` | what is installed, what else is on offer |
| `trustup component add N` | add one — clippy, rustfmt, rust-analyzer |
| `trustup size` | where the bytes are |
| `trustup env` | shell lines to use it |
| anything else | passed through to `rustup` |

Only the verbs where tinyrust differs are intercepted. `update`, `default`,
`toolchain`, `target`, `show` and the rest go to the real rustup, which is
fetched on first use and linked to the toolchain already installed — no second
download, nothing to opt into.

It reads the channel manifest, downloads three tarballs, checks their SHA-256
and untars them. No TOML parser and no 11 MB `rustup` binary: `curl`, `shasum`
and `tar` already cover TLS, verification and `.tar.xz`.

Four things are excluded during extraction rather than deleted afterwards, so
they are never written at all:

| | | |
|---|---|---|
| `share/doc` | 17 MB | this installs a compiler |
| `bin/rustdoc` | 11 MB | **but `cargo test` needs it for doctests — see Not done** |
| 4 × sanitizer runtime | 13 MB | `-Zsanitizer` is nightly-only |
| `wasm-component-ld` | 5 MB | reachable only from an uninstalled wasm target |

`rust-lld` (5.4 MB) stays: it is the default linker for some targets.

## Not done

- The tiny packages are built and installed locally, not published. Real pulls
  will be GitHub Actions artifacts; today it is
  `TRUSTUP_DIST=file://$PWD/dist TRUSTUP_CHANNEL=local ./trustup install`.
- `update` on a linked toolchain does not rebuild it; reinstalling is
  `rm -rf` and `trustup install`.
- A direct install of *official* components still excludes `bin/rustdoc`, so
  doctests fail there. Locally built packages are not pruned and keep it.
- No `rustup update`, no `+nightly`, no second toolchain. Reinstalling is
  `rm -rf toolchain && ./trustup install`.
- macOS aarch64 only. `./llvm` is wasmer's prebuilt LLVM 22.1.8.
- Nothing pinned: `trustup` takes whatever the stable manifest points at today.

`PLAN-rustc.md` has the derivations and the measurements behind each number.

# Development

How the small toolchain is produced. Not needed to use tinyrust.

## build-rustc

    ./build-rustc fetch          # rust 1.98.0 + cargo submodule
    ./build-rustc configure      # bootstrap.toml pointing at ./llvm
    ./build-rustc build          # RUSTC_STAGE=2 for self-hosted
    ./build-rustc strip trim     # drop symbols, drop unused llvm-tools
    ./build-rustc measure
    ./build-rustc dist           # 62 MB of tarballs + a channel manifest

    TRUSTUP_DIST=$PWD/dist ./trustup install /tmp/t

`dist` packages one `rust-std` per target. trustup installs the host's; the
others wait for `target add`.

## Compiler, −46%

`librustc_driver` calls 638 of `libLLVM.dylib`'s 158,946 symbols. A shared
library exports everything; static archives let the linker take only what is
called.

    static link, 2 targets    212.3 -> 149.0 MB
    strip -x                  149.0 -> 115.4 MB
    RUSTC_LTO=fat, opt-in     115.4 -> 110.3 MB, 3x build time

Backends: x86, x86_64, aarch64. `llvm-config-lean` hides the rest from
`--components`, which drives both the `LLVMInitialize*` cfgs and the link line.
`--print target-list` still names 330 triples; dropped ones fail codegen with
`could not create LLVM TargetMachine`.

## Tools, 43.1 MB of 205

| | | |
|---|---|---|
| cargo | 28.6 MB | nothing else resolves dependencies |
| rustdoc | 10.3 MB | `cargo test` needs it for doctests |
| rust-objcopy | 4.1 MB | rustc requires it for `-Cstrip` |
| dropped | 201 MB | `llc` and `opt` are 118.7 MB of it |

`trustup component add` resolves in three ways, and never mixes silently:

| | |
|---|---|
| in this dist | taken from it — `rustc`, `rust-std`, `cargo` |
| declared `upstream-ok` | taken from the official dist — `rust-analyzer`, `rust-docs`, `rust-src`, `llvm-tools` |
| anything else | refused — `clippy`, `rustfmt`, `miri` |

Rust writes the exact compiler version string into crate metadata, so anything
that loads an `.rmeta` or links `librustc_driver` must be built by *this*
compiler. Mixing gives `E0514: found crate std compiled by an incompatible
version of rustc`. Everything else only runs rustc or carries no code — official
cargo drives this rustc correctly.

## No binary links outside the OS

`build-rustc verify` fails the build unless every Mach-O resolves to `/usr/lib`,
`/System` or the toolchain. Three leaks so far:

    librustc_driver -> homebrew libzstd     static libzstd.a
    cargo           -> homebrew libssl      vendored-openssl
    rust-objcopy    -> homebrew libzstd     bundle, @loader_path + re-sign

Two were found by hand, the third by `verify`.

## Floor

    std .rmeta    99.7 MB   89% of std, required, cannot shrink
    std .rlib     10.1 MB

`debuginfo-level-std = 0` already saves 17.5 MB; the cost is line numbers for
precompiled std frames in backtraces.
