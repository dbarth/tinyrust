# How to create a minimum viable Rust install

What makes a Rust install big, and how much of it can go before you can no
longer compile an app on macOS?

## Premise

A default `rustup` install is 1.4 GB. Strip the documentation and the optional
components and 419 MB remains — the smallest thing that still builds a crate:

    libLLVM.dylib     133.1 MB    the code generator
    std               128.9 MB    one target
    librustc_driver    79.2 MB    the compiler itself
    rust-analyzer      38.1 MB    editor only
    cargo              30.5 MB    dependency resolution
    rustlib/bin         7.1 MB    rust-lld, rust-objcopy, gcc-ld
    libexec             1.4 MB

Two observations set the plan of attack. LLVM is the single largest item and
nothing in it is Rust. std is the second, and it is nearly all metadata. Those
are the only two worth attacking; everything else is rounding.

## Method

Iterate with a tool that builds and measures. `build-rustc` owns every step —
`llvm`, `fetch`, `configure`, `build`, `strip`, `trim`, `verify`, `dist`,
`measure` — so each finding below is a flag or a wrapper that a clean run
reproduces, and `measure` re-derives the numbers on demand.

## Results

macOS aarch64, one std target, fat LTO, stripped. Measured by CI on the
artifacts it published as v0.1.0:

    bucket     stock          this build
    rustc      212.3 MB       110.3 MB      -48%
    std        128.9 MB       111.8 MB      -13%
    tools       77.2 MB        38.2 MB      -51%
    -------------------------------------
    total      418.4 MB       260.3 MB      -38%

    download   rustc 30.1 + rust-std 23.5 + cargo 8.0 = 61.6 MB

`tools` is cargo 24.8 + rustdoc 9.3 + rust-objcopy 4.1; stock's 77.2 is
cargo 30.5 + rust-analyzer 38.1 + rustlib/bin 7.1 + libexec 1.4.

A second std target adds 114.2 MB and buys cross-compilation to x86_64.

stage2 self-hosts. Verified end to end: a crates.io dependency builds,
`strip = true` release profiles invoke rust-objcopy,
`cargo test --doc` runs a doctest.

## Findings

### What an app actually needs to build

Four things, and only four: `rustc`, std, `cargo` (nothing else resolves
dependencies), and `rust-objcopy` — which is not optional, because
`cargo build --release` with `strip = true` fails outright with `unable to run
rust-objcopy`. `rustdoc` joins them the moment a library has doc examples,
since `cargo test` runs doctests through it.

Everything else is a component a user adds on demand. rust-analyzer is editor
only; clippy and rustfmt change no build outcome. None of the three can be
taken from the official dist, though — each links `librustc_driver` and so is
tied to the exact compiler build. They have to be built here or not offered.

### LLVM is the hog, and rustc barely touches it

`librustc_driver` has 941 undefined symbols, 638 of them LLVM, against
`libLLVM.dylib`'s 158,946 exported. It uses 0.4% of the library.

    llvm::object                 3 symbols
    llvm::MCTargetOptions        1
    llvm::MCSubtargetInfo        1
    ORC / JIT / CodeView / PDB   5, combined

Five symbols across the JIT and both Windows debug formats — subsystems worth
45,849 symbols in the shipped dylib. They are there because a shared library
exports everything it was built with, whether or not anyone calls it.
`rustc_llvm/build.rs` says the same thing: `REQUIRED_COMPONENTS` is eight
entries, none of them ORC, CodeView, PDB or an object reader.

### So link it statically

Against static archives the linker resolves from those 638 roots and never
pulls the `.o` members holding the rest. 212.3 → 149.0 MB, before stripping.

`strip -x` then takes 149.0 → 115.4 MB. Exported symbols are kept so the dylib
still loads, and user backtraces are unaffected — they resolve against the
user's own binary. `rust.strip = true` is unusable for this: it applies
`-Cstrip=symbols` to std too, which would remove the globals that symbolicate
std frames.

### A prebuilt LLVM cuts the build, not just the payload

`llvm/` is wasmer's LLVM 22.1.8, pruned 2.7 GB → 768 MB. 22.1.8 is exactly
what rustc 1.98.0 reports, which is what makes this work at all. Supplying it
removes the part of a bootstrap that takes hours: stage1 is 90 s and stage2
4 min, against a full LLVM build.

A custom LLVM would go further. `--components` is read once in
`rustc_llvm/build.rs` (line 222) and drives both halves: line 233 emits one
`llvm_component` cfg per entry, gating the `LLVMInitialize*` externs that are
the linker's only roots into a backend; line 368 passes the same list to
`--libs`, which is the link line. So `llvm-config-lean` hides riscv,
webassembly and loongarch from both, and gets the same rustc a two-target LLVM
would have produced:

    88 archives -> 71.  Dropped 15.4 MB.  Residual references: 0.

`--print target-list` still names 330 triples — those specs are unconditional
Rust data. A dropped target fails at codegen with `could not create LLVM
TargetMachine`.

### What is left is bitcode, and only some of it moves

After LLVM, std is the payload, and 99.7 MB of its 111.8 is `.rmeta`:

1. Required. Moving the 26 `.rmeta` files aside gives `only metadata stub found
   for rlib dependency std` — bootstrap builds std with `-Zno-embed-metadata`,
   so the rlib holds a 0.4 KB stub.
2. Mostly MIR. `-Zmeta-stats`: `mir` 55.1%, `tables` 11.3%. That MIR is what
   makes generics and `#[inline]` instantiable downstream; `core` is almost
   entirely generic, so its share is higher.
3. Uncompressed on purpose. `libcore.rmeta` gzips 61.2 → 17.5 MB, but rustc
   mmaps metadata and decodes lazily. Compressing forces a full decode per
   crate load. No flag exists.

The rlibs are ~70% LTO bitcode, which `strip` does not touch either. So std is
a floor.

Where bitcode does move is the compiler and its tools. `rust.lto = "fat"`
governs how rustc itself is compiled — it does not change emitted binaries,
since users get LTO from their own `-C lto` (−13.4% here, against stock's
−13.1%):

    librustc_driver, stripped    115.4 -> 110.3 MB   -4.4%
    build time (stage2)           4:08 -> 11:23      2.75x
    type-check only               0.90 -> 0.81 s     10% faster
    full -O codegen               5.79 -> 5.74 s     noise

It applies to the tools as well — `tool.rs:129` passes it to RustcPrivate tools
and cargo — so cargo comes out 28.6 → 24.8 and rustdoc 10.3 → 9.3. Optimising
the set as a whole is worth more than optimising rustc alone. The build is
rare; the compiler is used constantly. Kept as the default.

### Cutting size exposed build-host leaks

Trimming meant checking what each binary actually links, and three times a
shipped binary had picked up a Homebrew library that a user would not have:

    librustc_driver -> libzstd     static libzstd.a via the llvm-config wrapper
    cargo           -> libssl      build.tool.cargo.features=["vendored-openssl"]
    rust-objcopy    -> libzstd     bundle: @loader_path + ad-hoc re-sign

`build-rustc verify` now walks every Mach-O and fails unless each dependency
resolves to `/usr/lib`, `/System` or the toolchain. It found the third within
seconds of being written, which is the argument for having it.

zstd cannot simply be dropped: `Compression.cpp.o` in `libLLVMSupport.a` is
pulled in by rustc's own `LLVMRustLLVMHasZstdCompression`. Linking it
statically costs +0.3 MB. libxml2 was reachable only from
`libLLVMWindowsManifest.a`, never on the link line, and is simply dropped.

### llvm-tools: 205.3 MB in, 4.1 MB kept

Bootstrap installs 14 binaries, each statically linking LLVM. `llc` and `opt`
alone are 118.7 MB and rustc never invokes them — it drives LLVM in-process
through its own shim. `llvm-profdata` and `llvm-cov` would be needed for
`-C instrument-coverage`; add them to `RUSTC_LLVM_TOOLS_KEEP`.

## Rejected

- **Stripping std** — 0.2 MB across all 26 rlibs, and it costs backtrace
  symbolication.
- **LLVM 21 for Apple tooling** — Apple `nm` cannot read our rlib intermediates
  (`Unknown attribute kind (105)`); final binaries are fine. Dropping to 21
  takes the fallback side of 13 `LLVM_VERSION_GE(22, 0)` branches.
- **reqwest/gitoxide to shed OpenSSL** — `curl`, `curl-sys`, `git2`,
  `git2-curl` and `libgit2-sys` are non-optional deps of cargo, so no feature
  removes them; the http-transport features only swap gitoxide's backend.
  Would add a second TLS stack. `vendored-openssl` already closed the leak.
- **`rust.std-features`** — dropping panic_unwind or backtrace shrinks std
  meaningfully and breaks panics or backtraces.

## TODO

- x86_64 host toolchain — a rustc that runs on Intel Macs. std already ships
  for x86_64; this is the compiler itself, and it needs a macos-13 runner.
- Linux targets — the backend is already linked in; needs a cross sysroot and
  a cross linker.
- Build our own LLVM instead of using wasmer's. Three gains: the three unused
  backends stop occupying 15.4 MB of the build tree, `-DLLVM_ENABLE_ZSTD=OFF`
  removes the zstd reference instead of statically linking it, and we stop
  depending on someone else's release cadence. Costs a full LLVM build, and
  changes nothing we ship.
- Check whether notarization is needed. Binaries are ad-hoc signed, which is
  enough to run; a browser download would get a Gatekeeper prompt, but `curl`
  does not set the quarantine bit and the installer uses `curl`. Untested.
- More reporting and cache management, so a Rust install can be kept tiny
  rather than just installed tiny. `info crates` is written and unwired; the
  registry cargo fills has no `cargo` command to prune it, and neither `trim`
  nor rustup touches it.
- Every Rust release means repeating this. No `rustup update` path.
