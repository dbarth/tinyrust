# tinyrust

Tinyrust is the smallest Rust install for macOS.

The standard Rust distribution is a 1.4GB install, before you even start compiling and adding dependencies. Tinyrust brings that down to 262MB, an 81% reduction.

Get started faster and leaner.

## Installation

    curl -sSfL https://dbarth.github.io/tinyrust/install.sh | sh

The installer fetches the optimized toolchain and sets up the environment for building.
 - no prompt, a single profile: the tiny one. 
 - installs to `~/.rustup/toolchains/tinyrust`,
 - links into `~/.cargo/bin`,
 - adds that to your shell profile.
 - features `trustup`, ie "tiny rustup", aliased to `rustup` to help stay tiny

You still get the full rustup/cargo support, so you can add components or
dependencies as usual:

    rustup component add rust-analyzer-preview
    rustup target add x86_64-apple-darwin
    cargo add serde

If you want the full standard install, docs and all:

    trustup go full      # 1359 MB, measured, on top of this
    trustup go tiny      # back to tinyrust

`trustup go` decides which one runs. Both toolcains stay installed until you trim:

    trustup trim         # remove the full one again

We ship both Apple Silicon and Intel. The installer picks by itself: `trustup`
reads the machine and asks the manifest for that host, the way `rustup` does.
There is one install command and no arch to choose.

The compiler emits for x86_64 and aarch64 both, whichever one it runs on.
`rustup target add x86_64-apple-darwin` adds the other target and
cross-compilation then works for both architectures.


# Usage

|---|---|
| `trustup install [DIR]` | fetch the toolchain, no rustup |
| `trustup info` | version, toolchain, components, targets, size |
| `trustup go full \| tiny` | switch between the full toolchain and the tiny one |
| `trustup trim` | remove what `go full` installed |
| `component add\|remove\|list`, `target add\|remove\|list` | intercepted: see below |
| anything else | passed to rustup, fetched on first use |

When tiny versions of the toolchain components are available, `component add`
will download these in priority, or default to official variants otherwise.
If you switch between toolchains with `go`, it will ensure no incompatible parts are mixed.

See the development notes below for the rationale.

|---|---|
| tiny versions | `rustc`, `rust-std`, `cargo`, `clippy-preview`, `rustfmt-preview`, `rust-analyzer-preview`, `miri` |
| `upstream-ok` | official dist — `cargo`, `rust-docs`, `rustc-docs`, `rust-src`, `rust-analysis`, `llvm-tools-preview`, `llvm-bitcode-linker-preview` |

## What is included?

    rustc          the compiler, its LLVM, and rustdoc for doctests
    rust-std       the standard library, for this machine
    cargo          the build tool
    rust-objcopy   rustc needs it for `strip = true` release profiles

Nothing else is downloaded until you ask for it, with one exception:
the first command requiring the real `rustup` will fetch it on demand.

Other parts of the toolchain you can add with `rustup component add`:

|---|---|
| `clippy-preview` | lints, `cargo clippy` |
| `rustfmt-preview` | `cargo fmt` |
| `miri` | the interpreter, for UB in unsafe code |
| `rust-src` | std sources, for IDEs and `-Zbuild-std` |
| `llvm-tools-preview` | `llvm-cov` and friends, for coverage |
| `rustc-alt` | compiler built for speed over size: +10 MB, release builds ~10% faster |

`rustup component list` shows what is installed and what else is on offer.

## The numbers

Just for macOS aarch64, rustc 1.98.0, one std target:

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

## TODO

- Linux support, x86_64 and aarch64.
- More reporting and cache management, install tiny, stay tiny.
- In-place `update`: `trustup install` replaces the toolchain whole.


# Development

Not needed to use tinyrust.

    ./build-rustc zstd           # the one library we link, pinned, no Homebrew
    ./build-rustc llvm           # wasmer's LLVM: 2.7 GB unpacked -> 768 MB kept
    ./build-rustc fetch          # rust 1.98.0 + cargo submodule
    ./build-rustc configure
    RUSTC_LTO=fat RUSTC_STAGE=2 ./build-rustc build
    ./build-rustc trim           # drop the llvm-tools nothing calls
    ./build-rustc strip          # drop symbols from the compiler and tools
    ./build-rustc dist           # tarballs + manifest; refuses non-fat trees
    ./build-rustc dist-merge OUT IN...   # both hosts into one manifest
    ./check                      # install it in a sandbox and use it

CI runs `check --dist dist` on each host after packaging, so a release cannot
go out with a component that does not run.

`check` is the scenario a new user walks through — install, hello world, a
release build with `strip = true`, docs, a dependency, each component we ship,
the targets we do not — run as tests, in a scratch `$HOME` that leaves the real
one alone. `-o net` skips what needs the network, `--published` tests the
release, `--dist DIR` tests a dist that is built but not yet published.

`trustup` installs from the tinyrust release by default. Point it elsewhere with
`TRUSTUP_DIST=$PWD/dist` to use a local build, and set `TINYRUST_DIST_BASE` when
packaging so the manifest carries the URLs the packages will actually live at —
without it they point at the build machine.

The build reads the machine it runs on. An Intel Mac produces an Intel
toolchain with no flag to set. `RUSTC_HOST` overrides it, but only to a host
that can run the compiler — this is not a cross-build. CI runs one job per
host and `dist-merge` folds the two dists into the single manifest a release
serves.

## How we make Rust tiny

A summary of the optimizations we apply. See NOTES.md` for more details.

### rustc: −48% on the compiler

We combine several optimizations:
- limited target support: aarch64 and x86, no SystemZ, no RISC-V
- only the essential build options
- static linking
- LTO fat

`librustc_driver` calls 638 of `libLLVM.dylib`'s 158,946 symbols. A shared
library exports everything; static archives let the linker take only what is
called.

    static link, 2 targets    212.3 -> 149.0 MB
    strip -x                  149.0 -> 115.4 MB
    fat LTO                   115.4 -> 110.3 MB, 3x build time

Backends: x86, x86_64, aarch64. `llvm-config-lean` hides the rest from
`--components`, which drives both the `LLVMInitialize*` cfgs and the link line.
`--print target-list` still names 330 triples; dropped ones fail codegen.

Fat LTO saves 15.3 MB across the tools and 5.1 MB on the compiler. It's a small download
win (`xz` already removes most of it) but is still a significant install-size gain.

### llvm-tools: 205 MB in, 4.1 MB kept

`llc` and `opt` are 118.7 MB of it and rustc never invokes them. Only `rust-objcopy`
stays because rustc requires it for `-Cstrip`.

### std: −13%, and the floor

    std .rmeta    99.7 MB   89% of std
    std .rlib     10.1 MB

`debuginfo-level-std = 0` saves 17.5 MB off the rlibs; the cost is line numbers
for precompiled std frames in backtraces. The `.rmeta` is metadata every generic
instantiation is built from — required, and the reason std cannot go much below
110 MB.

## What we build, what we reuse

Rust writes the compiler version string into crate metadata. Anything carrying
compiled Rust has to be built by this compiler. So does anything linking
`librustc_driver`. Clippy, rustfmt, rust-analyzer and miri all do, so we build
them.

Docs are HTML. `rust-src` is source text. The LLVM tools are standalone
binaries. None of that is tied to a compiler, so we take it from the official
dist unchanged.

We do not keep that list by hand:

    build-rustc upstream-ok      sweep the official dist, write ./upstream-ok

The sweep downloads each official component and applies two rules:

    no .rlib and no .rmeta
    no Mach-O linking librustc_driver

`trustup` applies the same two rules after unpacking. `dist` reads
`./upstream-ok`. Re-run the sweep instead of editing it.

## No binary links outside the OS

`build-rustc verify` ensures every Mach-O resolves to `/usr/lib`, `/System` or
the toolchain — and resolves it, rather than reading the path: `@loader_path`
and `@rpath` are followed, so a dangling one fails the build instead of
shipping.

## CI

`llvm.yml` prunes wasmer's LLVM once and publishes it (115 MB packed);
`release.yml` consumes that and builds the toolchain. Both run on GitHub's macOS
runners with third-party actions pinned to commit SHAs. `prepare` checks for the
~25 GB the build needs and stops if it is not there; nothing on the runner is
deleted. Binaries are ad-hoc signed but not notarized.
