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


## Third pass: where the remaining mass actually is

Comparison is now against the matched set — stock ships one std target, so this
counts one:

    bucket     stock          this build
    rustc      212.7 MB       115.4 MB
    std        128.9 MB       111.7 MB
    tools       77.2 MB            --
    other        0.7 MB            --
    -------------------------------------
    total      419.4 MB       227.2 MB

    rustc + std   341.6  ->  227.2 MB    -33%
    rustc alone   212.3  ->  115.4 MB    -46%

(+114.4 MB if the x86_64 std is kept, which is a capability stock does not have.)

### Stripping the compiler: 33.6 MB, no cost

`librustc_driver` still carried a full symbol table. `strip -x` — local symbols
out, exported symbols kept, so the dylib stays loadable — takes it from 149.0
to **115.4 MB**. Verified afterwards: compiles, runs tests, cross-compiles to
x86_64, LTO works, and user backtraces symbolicate exactly as before, because
those resolve against the user's own binary.

`rust.strip = true` is the supported knob but is **not usable here**: it applies
`-Cstrip=symbols` to std as well, and stripping an rlib runs `rust-objcopy`,
part of the llvm-tools component we do not ship. Stripping std would be wrong
anyway — those archives are linked into user programs and need their symbols.
So `build-rustc strip` does the compiler alone.

### .rmeta: 99.7 MB, and immovable

Nearly all of std is sidecar metadata. Three things establish that it cannot be
touched:

1. **It is required.** Moving all 26 `.rmeta` files aside and compiling gives
   `only metadata stub found for rlib dependency std`. Bootstrap builds std
   with `-Zno-embed-metadata`, so the rlib holds a 0.4 KB stub and the sidecar
   holds everything. There is no duplication to reclaim.
2. **It is mostly MIR.** `-Zmeta-stats` on a small generic crate: `mir` 55.1%,
   `tables` 11.3%, everything else in single digits. That MIR is what makes
   generic and `#[inline]` functions instantiable downstream. `core` is almost
   entirely generic, so its share is higher, not lower.
3. **It is uncompressed on purpose.** `libcore.rmeta` gzips 61.2 -> 17.5 MB and
   zstd -3 to 15.6 MB, so ~72 MB per target is theoretically on the table. But
   rustc mmaps metadata and decodes it lazily; the "inflate" in `locator.rs` is
   a buffer slice, not decompression. Compressing would force a full decode on
   every crate load. It is a deliberate speed-for-size trade, and there is no
   flag for it.

### Build-time options, surveyed

Already taken: `debug = false` (17.5 MB of std rlibs), `llvm-tools = false`,
static LLVM, two targets, no libxml2, and now the strip.

Left on the table, with what each costs:

    rust.lto = "fat"          single-digit MB. LLVM's half is not bitcode, so
                              only rustc's Rust code is in scope.
    rust.codegen-units = 1    smaller and faster code, much slower build.
    rust.std-features         dropping panic_unwind or backtrace would shrink
                              std meaningfully and break panics or backtraces.
                              Not worth it for a general-purpose toolchain.
    rust.jemalloc             already false.
    llvm.assertions           already false.

The honest summary: after the strip, rustc and std are within 4 MB of each
other, and 89% of std is metadata nobody can remove. The cheap wins are gone.


## Fat LTO: measured, and kept

`rust.lto` governs how **rustc itself** is compiled. It does not change the
binaries rustc emits -- users get LTO from their own `-C lto`, which already
works here (-13.4%, against stock's -13.1%). There is no channel by which a
more-optimised compiler produces better output.

    librustc_driver, unstripped   149.0 -> 131.6 MB   -11.7%
    librustc_driver, stripped     115.4 -> 110.3 MB    -4.4%  (-5.1 MB)
    build time (stage2)            4:08 -> 11:23       2.75x

    type-check only (5401 lines)   0.90 -> 0.81 s     10% faster
    full -O codegen (1803 lines)   5.79 -> 5.74 s     noise

Most of the unstripped 17.4 MB gain was symbol table that `strip` removes
anyway, which is why the two size rows disagree so much. The speed split is the
same story as the size: fat LTO optimises rustc's Rust half, so type-checking
gains 10% while codegen-dominated work -- where LLVM's C++ runs -- does not
move. `cargo check`-shaped workloads are where this shows up.

Kept as the default. The build is rare; the compiler is used constantly.

## Where it ends

    bucket     stock          this build
    rustc      212.7 MB       110.3 MB
    std        128.9 MB       111.7 MB
    tools       77.2 MB            --
    -------------------------------------
    total      419.4 MB       222.0 MB

    rustc + std   341.6 -> 222.0 MB   -35%
    rustc alone   212.3 -> 110.3 MB   -48%
    vs rustup's documented 1.4 GB     -84%

### Two things not worth doing

**Stripping std.** Would need `rust-objcopy` as a build dependency. Measured on
a snapshot sysroot: `libstd.rlib` 3.10 -> 3.03 MB, all 26 rlibs unchanged at
10.14 MB -- roughly 0.2 MB total, because std rlibs are ~70% LTO bitcode, which
`strip` does not touch, and they already carry no debuginfo. It would not break
linking (`strip -x` leaves 841 global symbols), but those globals are what
symbolicate std frames in user backtraces. Bad trade.

**Downgrading LLVM for Apple tooling.** Apple `nm` cannot read our rlib
intermediates -- `Unknown attribute kind (105) (Producer: 'LLVM22.1.8', Reader:
'LLVM APPLE_1_2100.0.123.102_0')` -- because those objects embed LLVM 22
bitcode. Final executables and dylibs are fine with Apple `nm`, `otool` and
`strip`; only intermediates fail. Apple clang here is 21.0.0 and rust 1.98
demands `>=21`, so LLVM 21.x is the one version satisfying both, and wasmer's
11.x-20.x builds are unusable. Not worth it: 22.1.8 is the version rust 1.98 is
developed against, and dropping to 21 takes the fallback side of 13
`LLVM_VERSION_GE(22, 0)` branches. The one case that would justify it is
`-C linker-plugin-lto`, which hands bitcode to the *system* linker and would hit
the same parse error.
