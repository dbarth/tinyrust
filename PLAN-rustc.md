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

`librustc_driver` references 94 `LLVMInitialize*` symbols — five per
architecture (`Target`, `TargetInfo`, `TargetMC`, `AsmParser`, `AsmPrinter`)
across all 18 backends. Each is behind `#[cfg(llvm_component = "…")]`, driven by
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

### The compromise, stated plainly

Wasmer built five targets. We want one. Using their build means rustc emits 25
initializer roots instead of 5, and links five backends instead of AArch64.

That is the price of not building LLVM ourselves. Take it for the first attempt:
it proves the toolchain end to end and costs no build time. If the result is
promising, build LLVM with `-DLLVM_TARGETS_TO_BUILD=AArch64` and repeat — the
rustc side does not change, because it follows `llvm-config`.

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
   built twice. Hours, not minutes.

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
