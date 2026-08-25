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
| **tinyrust** | **62 MB** | **262 MB** |

| | stock | tinyrust | |
|---|---|---|---|
| compiler + LLVM | 212.7 MB | 110.3 MB | −48% |
| std | 128.9 MB | 111.7 MB | −13% |
| cargo, rustdoc, rust-objcopy | 77.2 MB | 39.5 MB | −49% |

Builds a crate with a crates.io dependency, `strip = true` release profiles,
doctests, and its own compiler again — stage2 self-hosts to within 0.02%.

## Use it

    curl -sSfL https://raw.githubusercontent.com/dbarth/tinyrust/master/install.sh | sh
    cargo new hello && cd hello && cargo run --release

No prompt: one profile, the small one. Goes to `~/.rustup/toolchains/tinyrust`,
links into `~/.cargo/bin`, adds that to your shell profile. An existing rustup
is never touched — its shims are left alone and you use `trustup` by name.

`rustup` is aliased to `trustup` but does not pretend to be it:

    $ rustup --version
    trustup -- a thin rustup wrapper, installing a tinyrust toolchain
      toolchain  rustc 1.98.0-dev at ~/.rustup/toolchains/tinyrust
      this is not rustup. Commands it does not handle are passed through to
      the real one, fetched on demand. For the full official toolchain:
        trustup install --rustup

| | |
|---|---|
| `trustup install [DIR]` | fetch components, no rustup |
| `trustup install --rustup` | drive rustup, then trim what it over-installed |
| `trustup component list\|add` | resolve against the manifest |
| `trustup size` | where the bytes are |
| `trustup env` | shell lines to use it |
| anything else | passed to rustup, fetched on first use |

`component add` resolves three ways and never mixes silently:

| | |
|---|---|
| in this dist | `rustc`, `rust-std`, `cargo`, `clippy`, `rustfmt`, `rust-analyzer`, `miri` |
| `upstream-ok` | official dist — `rust-docs`, `rust-src`, `llvm-tools` |
| anything else | refused |

Rust writes the compiler version string into crate metadata, so anything loading
an `.rmeta` or linking `librustc_driver` must be built by *this* compiler —
mixing gives `E0514`. trustup re-checks each upstream component after unpacking.

## Not done

- Packages are built locally, not published. Real pulls will be release
  artifacts; today it is `TRUSTUP_DIST=$PWD/dist trustup install`.
- No `update`: reinstall is `rm -rf ~/.rustup/toolchains/tinyrust && trustup install`.
- macOS aarch64 only. Nothing pinned — `trustup` takes today's stable manifest.
- Neither CI workflow has run yet.

# Development

Not needed to use tinyrust. `PLAN-rustc.md` has the derivations.

    ./build-rustc llvm           # wasmer's LLVM, pruned: 457 MB -> 768 MB kept
    ./build-rustc fetch          # rust 1.98.0 + cargo submodule
    ./build-rustc configure
    RUSTC_LTO=fat RUSTC_STAGE=2 ./build-rustc build
    ./build-rustc trim           # drop the llvm-tools nothing calls
    ./build-rustc strip          # drop symbols from the compiler and tools
    ./build-rustc dist           # tarballs + manifest; refuses non-fat trees

## Where the compiler's −48% comes from

`librustc_driver` calls 638 of `libLLVM.dylib`'s 158,946 symbols. A shared
library exports everything; static archives let the linker take only what is
called.

    static link, 2 targets    212.3 -> 149.0 MB
    strip -x                  149.0 -> 115.4 MB
    fat LTO                   115.4 -> 110.3 MB, 3x build time

Backends: x86, x86_64, aarch64. `llvm-config-lean` hides the rest from
`--components`, which drives both the `LLVMInitialize*` cfgs and the link line.
`--print target-list` still names 330 triples; dropped ones fail codegen.

Fat LTO is worth 15.3 MB across the tools and 5.1 MB on the compiler — an
installed-size lever, not a download one, since `xz` already removes most of it.

## llvm-tools: 205 MB in, 4.1 MB kept

`llc` and `opt` are 118.7 MB of it and rustc never invokes them. `rust-objcopy`
stays because rustc requires it for `-Cstrip`.

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

`debuginfo-level-std = 0` saves 17.5 MB; the cost is line numbers for
precompiled std frames in backtraces.

## CI

`llvm.yml` prunes wasmer's LLVM once and publishes it (115 MB packed);
`release.yml` consumes that and builds the toolchain. macOS specifics: the build
leaves ~15 GB of intermediates against ~14 GB free on a runner (Xcode is deleted
first), macOS minutes bill at 10x on private repos, and binaries are ad-hoc
signed but not notarized.
