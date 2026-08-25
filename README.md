# tinyrust

`rustup` installs **1.4 GB** by default. This installs **390 MB** that builds
the same programs, and says exactly where the remaining bytes go and why they
cannot leave.

    ./trustup install            # fetch the three components directly
    ./trustup size               # where the bytes are
    eval "$(./trustup env)"

There is no `rustup` in the default path: `trustup` reads the channel manifest,
downloads three tarballs, checks their SHA-256 and untars them. Everything lands
in `toolchain/rust-stable/`; `rm -rf toolchain` is the uninstaller.

`./trustup install --rustup` drives rustup instead and then `./trustup trim`
deletes what it over-installed. Kept because it is the thing being measured
against.

## What it saves

| | |
|---|---|
| default `rustup` profile | 1.4 GB |
| `rustup --profile minimal` | 458 MB |
| `--rustup` + `trim` | 415 MB |
| **direct** | **390 MB** |

Verified: `rustc --print sysroot` is right, and `cargo new` + `cargo build
--release` compiles and runs a crate with no warnings.

The direct route wins the last 25 MB by never writing the files at all —
`tar --exclude` during extraction rather than `rm` afterwards — and by not
installing the 11 MB `rustup` binary, whose `bin/` entries are all symlinks back
to it.

**Almost all of the saving is one component.** `rust-docs` is **893 MB** of
generated HTML — more than the compiler and the standard library together — and
it is in the default profile. Everything else here is rounding.

## What is skipped

Measured on this machine, not guessed. The direct install excludes these during
untar; `trim` deletes them after a `--rustup` install.

| | | why |
|---|---|---|
| `share/doc` | 17 MB | this installs a compiler, not a documentation system |
| `bin/rustdoc` | 11 MB | same |
| 4 × sanitizer runtime | 13 MB | linked only by `-Zsanitizer`, which is nightly-only |
| `wasm-component-ld` | 5 MB | reachable only from a wasm target that is not installed |

Two things it deliberately leaves:

- **`rust-lld`** (5.4 MB) is the default linker for some targets and the
  fallback for others.
- **`libcore`'s `.rmeta`** (61 MB) is the MIR every generic instantiation is
  built from. Delete it and the first `Vec<T>` anyone writes fails to compile.

## The floor, and why it is the floor

    libLLVM.dylib          144 MB
    librustc_driver         79 MB
    std for one target     140 MB
    cargo + bin             42 MB

### LLVM is one binary for 330 target triples

`libLLVM.dylib` is 133 MB of Mach-O with 158,946 exported symbols, and two
sections hold nearly all of it:

    __text    57.8 MB    code
    __const   54.9 MB    read-only tables

Read-only data nearly the size of the code is the tell: that is **TableGen
output** — instruction-selection matcher tables, register descriptions,
scheduling models, encodings, generated per target from `.td` files. LLVM is
roughly half data by volume.

Eighteen target backends are compiled in, on a machine that only ever emits
AArch64. By symbol count:

    8149  AMDGPU        2069  Hexagon       968  SystemZ      483  AVR
    5047  AArch64  <--  1890  ARM           881  BPF          470  M68k
    4726  X86           1794  Mips          623  LoongArch    394  Xtensa
    2271  RISCV         1025  WebAssembly   520  CSKY         348  Sparc
                        1008  NVPTX                           317  MSP430

AMD's GPU backend is larger than the one in use. That is what supports
`rustc --print target-list` → 330 triples: cross-compiling needs no new
compiler, only another `rust-std`.

The rest is not the optimiser. The heavyweights by symbol count are
`llvm::orc` (35,332) — the JIT — then `object` (8,369), `codeview` (6,835),
`DWARF` (6,716) and `pdb` (3,682): debug-info readers and writers for every
platform's format, on a Mac, plus a full assembler and disassembler in the MC
layer.

### You cannot swap in a smaller LLVM

`rustc` links `@rpath/libLLVM.dylib` **dynamically**, at LLVM 22.1.8. Homebrew
ships llvm 22.1.8. So this was worth testing:

    cp /opt/homebrew/opt/llvm/lib/libLLVM.dylib toolchain/.../lib/
    rustc -O hello.rs
    error: rustc interrupted by SIGSEGV
      2  rustc_llvm::initialize_available_targets

Same version, same install name, dynamically linked — and it dies on a class
layout that moved. `rustc_llvm` is a C++ shim compiled against Rust's LLVM
fork, so the boundary is the **C++ ABI**, which is no more stable than Rust's.

Which makes a single-arch LLVM useless on its own: it only pays off if `rustc`
is *also* built from source against it, which needs an existing Rust to
bootstrap and hours of compute. Saving 100 MB costs a build farm.

Homebrew's own LLVM builds 20 targets, so there is no smaller one to borrow.

### std ships one target and is still 140 MB

Not the same disease as LLVM, but the same family. 27 rlibs total **28 MB**;
the `.rmeta` files total **100 MB**.

`libcore` is the case in point: **2.5 MB of rlib against 61 MB of rmeta**. Core
is almost entirely generic, so there is very little to compile ahead of time and
an enormous amount of IR to carry so that downstream code can instantiate it.

That is also why there is no wheel for Rust. Python packages ship prebuilt
because CPython has a stable C ABI; Rust monomorphises generics at the use site,
unifies cargo features across the whole dependency graph, and guarantees no ABI
between compiler versions. `std` is the one prebuilt Rust library precisely
because rustup pins compiler version, target and features together — the
obstacle is the combinatorial explosion of that tuple, not impossibility.

## Hello world, for scale

macOS, aarch64, rustc 1.98.0:

| | |
|---|---|
| `cargo build` | 472 KB |
| `cargo build --release` | 434 KB |
| `opt-level="z"`, lto, panic=abort, strip | 286 KB |
| `#![no_std]`, calling `write()` | 50 KB |
| C, `cc -Os` + strip | 33 KB |

The 286 KB is not `println!`. The binary carries 193 symbols matching
gimli/addr2line/dwarf/backtrace, a 26 KB `__eh_frame` and a 4.6 KB
`__gcc_except_tab` — a complete DWARF parser and stack unwinder, so that a panic
can print a symbolised backtrace. You pay for it whether or not you ever panic.
Drop std and you are within 17 KB of C.

## How the direct install works

The channel manifest is a plain TOML index with a URL and a SHA-256 per
component per target:

    [pkg.rustc.target.aarch64-apple-darwin]
    xz_url  = ".../rustc-1.98.0-aarch64-apple-darwin.tar.xz"
    xz_hash = "287edbc2..."

So an install is three URLs — `rustc`, `rust-std`, `cargo` — each downloaded,
checksummed, and untarred with `--strip-components=2`, because the archives are
`<pkg>-<version>-<triple>/<component>/<files>`. About 110 MB of `.tar.xz`.

No TOML parser: the entries are regular enough to find by string search.
`curl`, `shasum` and `tar` cover TLS, verification and `.tar.xz` on macOS, which
is most of what the 11 MB `rustup` binary carries.

**It does not download less.** Components ship as whole tarballs, and `rustdoc`
is *inside* the rustc component — its install manifest lists 43 files including
`bin/rustdoc`. There is no rustc-without-rustdoc to fetch. The 893 MB of docs is
avoided either way, because `rust-docs` is a package of its own that neither
route requests.

**What it gives up:** `rustup update`, multiple toolchains, `+nightly`, and the
proxy shims. For a pinned single-purpose toolchain, none of that is used.

### Two things rustup's installer does that a plain untar does not

Both found by the toolchain failing, not by reading:

**The prefix must not be named after the host triple.** rustc finds its sysroot
by walking up from its own path, with a special case for
`<sysroot>/lib/rustlib/<triple>/bin/rustc`. A prefix called
`aarch64-apple-darwin` trips that rule, the sysroot lands four directories too
high, and every build fails with `can't find crate for std`. Hence
`toolchain/rust-stable/`.

**`rust-objcopy` needs a second path to `libLLVM.dylib`.** It sits in
`lib/rustlib/<triple>/bin/` with an rpath of `@loader_path/../lib`, but the
dylib ships in the prefix's own `lib/`. cargo calls it to strip release
binaries, so without a relative symlink every `--release` build prints a dyld
trace and a `SIGABRT`.

## Not done

- No `nightly`, no components beyond the three. `TRUSTUP_CHANNEL` picks the
  channel but nothing has been tried but stable.
- The direct route pins nothing: it takes whatever `channel-rust-stable.toml`
  points at today, and re-running it later gets a different compiler.
- No update path. Reinstalling is `rm -rf toolchain && ./trustup install`.
- Only four host triples are recognised, and only macOS is tested.
