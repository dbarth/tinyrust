# Plan: rebuild rustc against a lean LLVM

The goal is not a smaller `libLLVM`. It is a `rustc` that **statically links only
the LLVM it actually calls** — which, measured, is very little.

## Why this should work

`librustc_driver` in the stock toolchain has **941 undefined symbols, 638 of them
LLVM**, against `libLLVM.dylib`'s **158,946 exported**. It touches 0.4% of the
library. Broken down by subsystem, what it references outside the C API is:

    llvm::object          3 symbols
    llvm::MCTargetOptions 1
    llvm::MCSubtargetInfo 1
    ORC / JIT / CodeView / PDB   5, combined

Five symbols across the JIT and both Windows debug formats — subsystems worth
**45,849 symbols** in the shipped dylib. Those are there because a *shared*
library exports everything it was built with, whether or not anyone calls it.

Link the same compiler against **static archives** and the linker resolves from
those 638 roots and never pulls the `.o` members holding ORC, CodeView, PDB or
the object-format readers. Selective linking, for free, at object granularity.

`rustc_llvm/build.rs` says the same thing in its own words:

```rust
const REQUIRED_COMPONENTS: &[&str] =
    &["ipo","bitreader","bitwriter","linker","asmparser","lto","coverage","instrumentation"];
```

Eight components. Not one of them is ORC, CodeView, PDB, or an object reader.

## The backends are 94 explicit roots

`librustc_driver` in the stock toolchain references 94 `LLVMInitialize*`
symbols — five per architecture (`Target`, `TargetInfo`, `TargetMC`,
`AsmParser`, `AsmPrinter`) across all 18 backends. This build emits **10**, for
x86 and aarch64 only. Each is behind `#[cfg(llvm_component = "…")]`, driven by
`OPTIONAL_COMPONENTS` in the same `build.rs`. Those cfgs follow whatever
`llvm-config --targets-built` reports, so an LLVM with fewer targets makes rustc
emit fewer roots, and the linker pulls fewer backends. Nothing to patch.

## What we have

`llvm/` — Wasmer's prebuilt LLVM, pruned. From
<https://github.com/wasmerio/llvm-custom-builds/releases/download/22.x/llvm-darwin-aarch64.tar.xz>

    llvm-config --version        22.1.8
    llvm-config --targets-built  X86 AArch64 RISCV WebAssembly LoongArch
    static archives              135 files, 145 MB
    shared libLLVM               none -- this is a static build

**22.1.8 is exactly the LLVM rustc 1.98.0 reports**, which is the version match
that makes this worth attempting at all.

The tarball is 457 MB and unpacks to 2.7 GB. We keep 604 MB: `lib/` (the
archives), `usr/include` (headers), and six binaries. The other 113 are clang
and the `llvm-*` tools, each statically linking LLVM — 1.7 GB of pure
duplication, and `clang-repl` alone is 100 MB.

### Restricting to two targets, without rebuilding LLVM

Wasmer built five targets. We want **x86 and aarch64** — a host compiler that
can also cross-compile to the other architecture anyone actually ships on.

The plan above says the cfgs follow whatever `llvm-config` reports and that
there is nothing to patch. That is literally true, and it is enough. Reading
`rustc_llvm/build.rs`, `--components` is consulted exactly once (line 222) and
drives *both* halves of the problem:

- line 233 — one `cargo:rustc-cfg=llvm_component="…"` per entry, which gates the
  `LLVMInitialize*` externs in `rustc_llvm/src/lib.rs`. Those externs are the
  linker's **only** roots into a backend; `grep -rn 'InitializeAll'` over
  `rustc_codegen_llvm` and `rustc_llvm` (shim included) returns nothing, so
  there is no escape hatch that reaches a backend another way.
- line 368 — the same list is passed to `--libs`, which *is* the link line.

So `llvm/bin/llvm-config` is now a wrapper that drops `riscv`, `webassembly`
and `loongarch` from `--components` and `--targets-built`; the original is kept
beside it as `llvm-config.real`. Measured effect on the static link line:

    88 archives  ->  71 archives
    dropped:  6 RISCV, 6 WebAssembly, 5 LoongArch  (15.4 MB on disk)
    residual references to the three:  0

Because each backend lives in its own archives, this gives **the same rustc a
two-target LLVM would have given**. What it does not do is shrink `llvm/`
itself — the 15.4 MB of dropped archives stay on disk. They are a build-time
input that is never distributed, so this does not affect the number that
matters. Rebuilding LLVM with `-DLLVM_TARGETS_TO_BUILD="X86;AArch64"` would
reclaim them and nothing else, at the cost of fetching the source, installing
ninja, and a full LLVM build.

### The system libraries llvm-config drags in

`llvm-config --system-libs` reported `-lm -lzstd -lxml2`, and both extras turn
out to be worth attacking — for different reasons.

**libxml2 is dead weight.** It is reachable only from
`libLLVMWindowsManifest.a`, which is not on rustc's link line at all; the built
`librustc_driver` contains zero `xml` references. Dropped.

**zstd cannot simply be dropped.** It is reached from `Compression.cpp.o`
inside `libLLVMSupport.a`, and that member *is* pulled in — rustc's own
`LLVMRustLLVMHasZstdCompression` (RustWrapper.cpp:1815) calls into it. Removing
`-lzstd` would be an undefined-symbol link failure. Only rebuilding LLVM with
`-DLLVM_ENABLE_ZSTD=OFF` would remove the reference itself.

But `-lzstd` was hiding a worse problem. It resolved against Homebrew, so the
compiler came out with a hard dependency on

    /opt/homebrew/opt/zstd/lib/libzstd.1.dylib

which means that `rustc` **would not run on a machine without Homebrew**. The
fix is one rustc already supports: `rustc_llvm/build.rs` turns an absolute path
to a `.a` in the `--system-libs` output into `cargo:rustc-link-lib=static=zstd`
— its own comment uses libzstd as the worked example. So the `llvm-config`
wrapper rewrites `-lzstd` to the path of `libzstd.a`.

    before   @rpath, libSystem, libobjc, Foundation, libz, libc++, libiconv,
             libxml2.2.dylib, /opt/homebrew/opt/zstd/lib/libzstd.1.dylib
    after    @rpath, libSystem, libobjc, Foundation, libz, libc++, libiconv

Nothing outside `/usr/lib` and `/System` remains. Cost: **+0.3 MB** (148.7 ->
149.0), for 242 zstd symbols moved inside and one non-portable dependency
removed.

## Steps

1. **Check out rust**, at the tag matching the toolchain we measured (1.98.0),
   so the comparison is like for like.

2. **`bootstrap.toml`**, the parts that matter:

   ```toml
   [llvm]
   link-shared = false          # static, so the linker can drop what is unused
   download-ci-llvm = false     # do not fetch rust's own LLVM

   [target.aarch64-apple-darwin]
   llvm-config = ".../tinyrust/llvm/bin/llvm-config"

   [rust]
   codegen-backends = ["llvm"]  # LLVM is always built and distributed anyway
   ```

3. **`./x build`** — stage0 is downloaded, stage1 compiles the compiler, std is
   built twice. ~~Hours, not minutes.~~ In practice **90 seconds** for stage1
   and **4 minutes** for stage2: supplying a prebuilt LLVM removes the part of
   a bootstrap that actually takes hours.

4. **Measure** `librustc_driver` and compare against the 79.2 MB of the stock
   build, and the total against 390 MB.

5. **Verify it is a real compiler**: build a crate, run its tests, check
   `--print target-list` against what it can actually emit.

## What will not move, whatever happens

    librustc_driver   79.2 MB    rustc's own Rust code, target-independent
    std               129.0 MB   already one target
    cargo              30.5 MB

**238 MB — 61% of the current 390 — that no LLVM work touches.** With a shared
libLLVM at 133 MB the ceiling on this exercise is a ~34% cut, and only if the
static link drops nearly everything. Worth knowing before spending an afternoon
on it.

## Risks

- **Rust patches its LLVM fork.** Building against stock LLVM is supported and
  is what distributions do, but it is a less-travelled path; some features can
  differ or fail to build.
- **Static linking changes the shape.** Official builds ship `libLLVM.dylib`
  separately; this puts LLVM inside `librustc_driver`. Sizes are then not
  directly comparable line by line, only in total.
- **No `rustup update`, ever.** Every Rust release means repeating this.
- **A build failure here is an LLVM/C++ link error**, not a Rust one. Expect to
  read linker output.


## Result

Built, self-hosted, and measured. `RUSTC_STAGE=2 ./build-rustc measure`:

                            stock    this build
    librustc_driver          79.2         149.0
    libLLVM.dylib           133.1     -- static
                           ------        ------
                            212.3         149.0    -30%

**The compiler and its LLVM went from 212.3 MB to 149.0 MB.** The static link
resolved from rustc's own LLVM roots and took roughly 70 MB where the shared
library cost 133 MB. ORC, CodeView, PDB and the object-format readers never
came along, exactly as predicted.

### It is a real, self-hosting compiler

stage2 is the stage1 compiler compiling the whole compiler again, and it lands
on the same size:

    stage1   156,281,896 bytes
    stage2   156,253,096 bytes    (-28,800, 0.02%)

That 0.02% is crate hashes and stage1-vs-stage0 codegen, not drift. Both stages
compile and run programs, pass threaded/panicking/unwinding tests, and emit
real arm64 Mach-O objects.

### Backends

    aarch64, x86_64, i686        can emit
    riscv64, wasm32, loongarch,
    armv7, powerpc64, s390x,
    nvptx                        no backend

Note `--print target-list` still names all 330 targets — those specs are
unconditional Rust data. The failure moves to codegen: a dropped target dies
with `could not create LLVM TargetMachine`, whereas x86_64 gets *past* that and
only trips on a missing `core`, because std was built for aarch64 only.

### What did not move, as promised

std came out 128.9 -> 111.9 MB, but **that is not an LLVM saving** — it is
`rust.debug = false` leaving `debuginfo-level-std` at 0. Measured effect on
backtraces: inlined and generic std code still reports line numbers (it is
codegen'd into the user's crate), while precompiled non-generic std frames lose
them. Set `debuginfo-level-std = 1` to get it back at the cost of the 17 MB.

Tree totals (419.4 vs 273.8 MB) are **not** like for like: stock carries cargo
and rust-analyzer, this build carries rustdoc and no cargo. The 30% above is
the honest figure.

### What it cost to get here

Four things, all now handled by `build-rustc` so a clean run reproduces them:

- `codegen-tests = false` — FileCheck is not in the wasmer tarball at all.
- `llvm-tools = false` — 14 LLVM binaries bootstrap would copy into the sysroot.
- `llvm-config` wrapper — two targets, no libxml2, static zstd.
- `--bindir` bridging — the pruned tree keeps binaries in `bin/`, not `usr/bin/`.

The only genuine link failure was a missing system library, never an undefined
LLVM symbol. The selective-linking premise was never in doubt once it built.


## Second pass: x86_64 std, and an even comparison

### std for a second target is a second directory, not a second file

Adding `x86_64-apple-darwin` to `build.target` gives a *host* compiler that is
still aarch64-only; what appears is a parallel sysroot directory:

    lib/rustlib/aarch64-apple-darwin/lib   111.9 MB   26 rlibs
    lib/rustlib/x86_64-apple-darwin/lib    114.1 MB   26 rlibs

Same 26 crates, compiled again for the other architecture. Verified end to end:
`--target x86_64-apple-darwin` now produces a real `Mach-O 64-bit executable
x86_64` that runs and prints the right answer, rather than stopping at
`can't find crate for core`.

x86_64-apple-darwin is the cheap second target because the macOS SDK is
universal, so no cross sysroot is needed. `x86_64-unknown-linux-gnu` would need
one, plus a cross linker — the backend is already there either way.

### Making the two toolchains comparable

The trees were never like for like: stock carries cargo and rust-analyzer, and
`./x build` was producing a rustdoc that stock does not have. `tools = []` does
**not** suppress rustdoc — it is a default step of `./x build`, not an entry in
that list. Building `compiler library` instead leaves it out.

`build-rustc measure` now subtracts everything that is not a compiler and says
so: out of stock go cargo, rust-analyzer, the gdb/lldb wrappers, `libexec`,
`share` and `etc`; out of this build goes rustdoc, which is no longer built.

    stock (1 std target)              348.8 MB
    this build (1 std target)         261.0 MB    -25%
    this build (2 std targets)        375.1 MB     +8%

**−25% at equal capability.** The +8% row is the honest cost of the second
target: this build is *larger* than stock overall, and buys cross-compilation
to x86_64 for it. Which row matters depends on whether the second std is
wanted; both are printed so neither can be quoted alone.
