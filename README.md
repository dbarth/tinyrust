# tinyrust

Tinyrust is the smallest Rust install for macOS. Get started faster and leaner.


## Get it

    curl -sSfL https://raw.githubusercontent.com/dbarth/tinyrust/master/install.sh | sh

## Why tinyrust?

The standard Rust distribution is a 1.4GB install, before you even start compiling and adding dependencies.

Tinyrust brings that down to 262MB, an 81% reduction.

You still get the full rustup/cargo support, so you can add components or
dependencies as usual:

    rustup component add rust-analyzer-preview
    cargo add serde

If you want the full standard install, docs and all:

    trustup go full      # 1359 MB, measured, on top of this
    trustup go tiny      # back to tinyrust
    trustup trim         # remove the full one again

Both stay installed until you trim, and `go` decides which one runs.


## Use it

    curl -sSfL https://raw.githubusercontent.com/dbarth/tinyrust/master/install.sh | sh
    cargo new hello && cd hello && cargo run --release

The installer fetches the optimized toolchain and sets up the environment for building.
 - no prompt, a single profile: the tiny one. 
 - installs to `~/.rustup/toolchains/tinyrust`,
 - links into `~/.cargo/bin`,
 - adds that to your shell profile.
 
It contains `trustup`, ie "tiny rustup". `rustup` is aliased to `trustup` but does not pretend to be it:

    $ rustup version
    trustup 0.1.0
    rustc 1.98.0-dev at ~/.rustup/toolchains/tinyrust

Note: an existing rustup is never touched — its shims are left alone and you use `trustup` by name.

| | |
|---|---|
| `trustup install [DIR]` | fetch the toolchain, no rustup |
| `trustup list` | what is installed, and what else is on offer |
| `trustup size` | where the bytes are |
| `trustup version` | this, and the toolchain it manages |
| `trustup go full` | the full official toolchain, docs and all |
| `trustup go tiny` | back to tinyrust, no rustup in the path |
| `trustup trim` | remove what `go full` installed |
| `component add\|list`, `target add\|list`, `update` | intercepted: rustup refuses these on a linked toolchain |
| anything else | passed to rustup, fetched on first use |

`component add` resolves three ways and never mixes silently:

| | |
|---|---|
| in this dist | `rustc`, `rust-std`, `cargo`, `clippy-preview`, `rustfmt-preview`, `rust-analyzer-preview`, `miri` |
| `upstream-ok` | official dist — `rust-docs`, `rustc-docs`, `rust-src`, `llvm-tools-preview` |
| anything else | refused |

Rust writes the compiler version string into crate metadata: anything loading
an `.rmeta` or linking `librustc_driver` must be built by *this* compiler (mixing gives `E0514`).
trustup re-checks each upstream component after unpacking.


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


## What is included?

    rustc          the compiler, its LLVM, and rustdoc for doctests
    rust-std       the standard library, for this machine only
    cargo          the build tool
    rust-objcopy   rustc needs it for `strip = true` release profiles

That is the whole default install. Nothing is downloaded until you ask for it,
with one exception: the first command trustup passes to rustup fetches rustup itself.


## What if I miss something?

Really miss that 1GB of pre-compiled HTML docs?

    rustup component add rust-docs

Need the LSP for your IDE?

    rustup component add rust-analyzer-preview

And the rest:

| | |
|---|---|
| `clippy-preview` | lints, `cargo clippy` |
| `rustfmt-preview` | `cargo fmt` |
| `miri` | the interpreter, for UB in unsafe code |
| `rust-src` | std sources, for IDEs and `-Zbuild-std` |
| `llvm-tools-preview` | `llvm-cov` and friends, for coverage |

`rustup component list` shows what is installed and what else is on offer.


## Not done

- No `update`: reinstall is `rm -rf ~/.rustup/toolchains/tinyrust && trustup install`.
- macOS aarch64 only.


# Development

Not needed to use tinyrust. `NOTES.md` has the derivations.

    ./build-rustc llvm           # wasmer's LLVM, pruned: 457 MB -> 768 MB kept
    ./build-rustc fetch          # rust 1.98.0 + cargo submodule
    ./build-rustc configure
    RUSTC_LTO=fat RUSTC_STAGE=2 ./build-rustc build
    ./build-rustc trim           # drop the llvm-tools nothing calls
    ./build-rustc strip          # drop symbols from the compiler and tools
    ./build-rustc dist           # tarballs + manifest; refuses non-fat trees

`trustup` installs from the tinyrust release by default. Point it elsewhere with
`TRUSTUP_DIST=$PWD/dist` to use a local build, and set `TINYRUST_DIST_BASE` when
packaging so the manifest carries the URLs the packages will actually live at —
without it they point at the build machine.


## How we make Rust tiny

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

## No binary links outside the OS

`build-rustc verify` ensures every Mach-O resolves to `/usr/lib`,
`/System` or the toolchain.

## CI

`llvm.yml` prunes wasmer's LLVM once and publishes it (115 MB packed);
`release.yml` consumes that and builds the toolchain. macOS specifics: the build
leaves ~15 GB of intermediates against ~14 GB free on a runner (Xcode is deleted
first), macOS minutes bill at 10x on private repos, and binaries are ad-hoc
signed but not notarized.
