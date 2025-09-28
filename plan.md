# Unified Architecture for the Ribbon Compiler & Runtime

This document outlines a refined, unified architectural vision for the Ribbon compiler and its hot-reloading
capabilities. The central goals are to achieve best-in-class performance through
**parallel and incremental compilation** while enabling a uniquely powerful and safe **live state migration** system for
hot-reloading.

This plan moves away from a strictly bottom-up implementation order towards a **vertical slice** strategy. This ensures
that at each stage of development, core components have the necessary high-level context to be implemented robustly,
avoiding the architectural friction of building low-level pieces in isolation.

## Part 1: A Parallel and Incremental Compiler

### 1.1. Overview & Core Principles

The Ribbon compiler is designed from the ground up to support modern development workflows. This architecture focuses on
two primary goals:

1.  **Parallel Compilation:** Drastically reduce full build times by compiling independent modules simultaneously.
2.  **Incremental Compilation:** Recompile only the modules affected by code changes, making iterative development
    nearly instantaneous.

The foundation of this architecture is a **Hub-and-Spoke Model** where distinct services operate on a shared context for
a given build.

*   **The Build Orchestrator:** The brain of the build system. It discovers modules via their definition files, builds
    the dependency graph, manages the compilation cache, and coordinates the entire workflow.
*   **The Compilation Session:** A short-lived object representing the state of a single build run. It owns the root
    `ir.Context` and holds critical mapping data, such as which `ir.Context` corresponds to which `ModuleGUID`. This
    cleanly separates the persistent IR from transient, build-specific metadata.
*   **The Frontend Service:** A pure analysis service. Its job is to take a set of source files, rehydrate dependency
    interfaces from the `CompilationSession`, configure itself with the module's specified language extensions, and
    produce a semantic representation of the module's public interface and private implementation.
*   **The Backend Service:** A pure code generation service. Its job is to take the semantic representation from one or
    more modules and produce a final, executable artifact.

This separation is the key to unlocking parallelism and accurate incrementality, while also enabling other tools like
Language Server Protocol (LSP) servers to reuse the frontend analysis without depending on the code generation backend.

### 1.2. The Module Definition File (`.rmod`)

The source of truth for a Ribbon module is its **Module Definition File (`.rmod`)**. This file acts as a manifest,
providing the static context necessary for the compiler to operate. Because Ribbon's syntax is user-extensible, the
compiler cannot reliably parse a source file without first being told which language features and macros are active. The
`.rmod` file provides this essential configuration.

It uses a restricted, non-extensible subset of RML syntax for clarity and ease of parsing by the build orchestrator.

**Example `graphics.rmod`:**
```
;; `graphics` is the canonical name of this module, used for dependency resolution.
module graphics.
  ;; The list of source files that constitute this module's implementation.
  ;; Paths are relative to the .rmod file and can include directories,
  ;; which will be scanned recursively for `.rib` files.
  sources = [
    "renderer.rib",
    "shaders/",          ;; Includes all .rib files in this directory
    "mesh/",
  ]

  ;; A map of modules this module depends on.
  ;; The keys ('std', 'gpu') are the local aliases used in `import` statements.
  ;; The values are dependency specifiers (e.g., version strings, paths).
  dependencies = {
    std = package "core@0.1.0",
    gpu = github "tiny-bow/rgpu#W7SI6GbejPFWIbAPfm6uS623SVD",
    linalg = path "../linear-algebra",
  }

  ;; A list of language extension modules to activate for this module.
  ;; The compiler will load the public interfaces of these extensions
  ;; to configure the parser with their custom syntax rules and macros.
  extensions = [
    std/macros,
    std/dsl/operator-precedence,
    gpu/descriptors,
    linalg/vector-ops,
  ]
```

This manifest enables a robust **Two-Phase Parsing Model**:
1.  **Static Configuration Parsing:** The build orchestrator first scans for and parses all `.rmod` files. This is a
    fast, predictable step that allows it to build the complete dependency graph without touching any `.ribbon` source
    code.
2.  **Extensible Source Parsing:** When compiling a specific module, the orchestrator configures the `FrontendService`
    with the extensions listed in the `.rmod` file. The frontend then uses this custom-configured parser to process the
    module's source files.

### 1.3. The `CompilationSession`

To avoid polluting the core `ir.Context` with build-specific metadata, the `Orchestrator` creates a `CompilationSession`
for each build. This object acts as the "short-term memory" for the build.

```zig
// A conceptual representation.
const CompilationSession = struct {
    root_context: *ir.Context,
    context_id_to_module: std.HashMap(ir.Context.Id, ModuleInfo, ...),
    ref_to_external_symbol: std.HashMap(ir.Ref, ExternalSymbolInfo, ...),

    // Caches the configured syntax for each module in the build.
    // Maps a module's GUID to the `analysis.Parser.Syntax` object that
    // has been configured with its specific language extensions.
    configured_syntaxes: std.HashMap(ir.ModuleGUID, *analysis.Parser.Syntax, ...),
};
```

### 1.4. The Serializable Module Artifact (SMA)

The SMA remains the primary cacheable artifact. It is a binary file (`.sma`) produced by the `FrontendService`
representing a single, fully analyzed module. It contains both a public interface section for dependents and a private
implementation section for the backend.

### 1.5. The `interface_hash` and Canonical Binary Representation (CBR)

The `interface_hash` is the cornerstone of incremental compilation. It is a cryptographic fingerprint of a module's
**public contract (API/ABI)**. To generate it, the `FrontendService` creates a temporary, in-memory **Canonical Binary
Representation (CBR)** of the public interface.

**The `interface_hash` is compositional.** It depends not only on the module's own public symbols but also on
the interfaces of the language extensions it uses. A change to a public macro in an extension module will correctly
trigger a recompilation of all modules that use it.

**Canonicalization Rules:**
* Public symbols are sorted alphabetically by name.
* The `interface_hash` of each used extension module is included in the hash calculation.
* Struct fields are sorted alphabetically for packed layouts and by memory offset for C layouts.
* Effect rows are sorted alphabetically by effect name.

### 1.6. The Incremental Build Workflow

1.  **Trigger:** A file watcher reports a change to a file (e.g., `renderer.ribbon` or `graphics.rmod`).
2.  **Orchestration Begins:**
    * The `Orchestrator` creates a `CompilationSession`.
    * It performs **Module Discovery** by finding all `.rmod` files and parsing them.
    * It recursively scans any directories listed in `sources` to find all relevant `.ribbon` files.
    * It builds the `DependencyGraph` from the `dependencies` sections.
    * It uses **Tarjan's algorithm to find Strongly Connected Components (SCCs)**, producing a topologically sorted
      build order. (e.g., `[ [utils], [module_a, module_b], [app] ]`).
3.  **Frontend Loop (SCC-based Analysis):**
    * The orchestrator iterates through the sorted list of SCCs.
    * For each module in an SCC:
        - Load the module's `.rmod` file.
        - Rehydrate the public interfaces of all its dependencies from their cached `.sma` files.
        - Rehydrate the public interfaces of all its language extensions.
        - Use the extension interfaces to **configure a custom parser syntax** for this module and cache it in the
          `CompilationSession`.
        - Invoke the `FrontendService`, which uses this configured parser to analyze all source files listed in the
          `.rmod`.
        - The frontend service generates a new `.sma` artifact for the module.
4.  **The "Should I Recompile?" Check:**
    * The orchestrator computes the `interface_hash` from the public part of the new `.sma` file (including the hashes
      of its extensions).
    * It compares this with the `interface_hash` from the cached `old.sma`.
5.  **Backend Scheduling (Parallel Code Generation):**
    * **Case A: Hashes Match (No Public API Change).** Only the module whose source files changed needs its code
      regenerated. A single backend job is scheduled.
    * **Case B: Hashes Differ (Public API Change).** The `DependencyGraph` is consulted for reverse dependencies.
      Parallel backend jobs are scheduled for the changed module and all affected downstream modules.

## Part 2: A Robust Hot-Reloading System

This system leverages the SMA architecture to implement safe and powerful hot-reloading. The core principle is:
**State migration is a user-space, type-safe, and compositional process, orchestrated by the runtime as a handled effect.**

### 2.1. Version 0: Compile & Restart

The initial implementation will provide a rapid recompile-and-relaunch cycle.

1. A file watcher triggers an incremental build via the orchestrator.
2. Upon success, the orchestrator signals the running Ribbon application.
3. The application's host logic cleanly tears down its state and re-initializes using the new code.

### 2.2. Version 1: Live State Migration

#### Compiler Responsibilities: Type Evolution and Safety

* **The `Migratable` Type Class:** Users define migration logic via a standard type class.
    ```ribbon
    Migratable := class From, To.
        migrate: From -> To | { RemapAddress, Error String }
    ```
* **The `RemapAddress` Effect:** This effect is handled by the runtime during a migration transaction to safely update
  pointers from old memory locations to new ones.
* **The `Unsafe` Effect and Trust Boundary:** Migrating types that contain raw pointers or FFI resources implicitly adds
  an `Unsafe` effect. Only explicitly trusted modules can handle this effect.

#### Runtime Responsibilities: State Tracking & Migration

* **Migratable Allocators and RTTI:** Special allocators attach RTTI—specifically, the **`Type Version ID`** (the CBR
  hash of the type)—to memory blocks.
* **The Migration Transaction:** Migration is an atomic, rollback-safe process.
    1. The runtime pauses execution at a safe point.
    2. It traverses the old state, allocating new memory and building an address-remapping table.
    3. It iteratively calls the user-defined `migrate` functions, providing a handler for the `RemapAddress` effect.
    4. If any migration fails, the transaction is aborted, new memory is freed, and execution resumes with the old
       state.
    5. On success, the runtime atomically swaps the application's root pointers to the new state, frees the old memory,
       and resumes execution.

---

## Implementation Plan

This plan is structured as a series of **vertical slices**, ensuring that a functional (though incomplete) end-to-end
pipeline exists at each major stage.

### Phase 1: Module Manifest & Dependency Graph

**Goal:** Create an orchestrator that can find and parse all `.rmod` files in a project, recursively scan `sources`
directories, and build a complete dependency graph, printing a correct topological build order.

* **Task 1.1:** Define and implement a static, non-extensible parser for the `.rmod` file format.
* **Task 1.2:** Implement the `BuildOrchestrator`'s discovery mechanism. It should scan for `.rmod` files and use the
  new parser.
* **Task 1.3:** Implement the logic to recursively scan directories listed in the `sources` key of a `.rmod` file,
  finding all `.ribbon` files.
* **Task 1.4:** Implement Tarjan's algorithm to compute the SCCs of the dependency graph and produce a topologically
  sorted build order.
* **Verification:** The build driver can be run on a project and correctly print the build order in SCC groups.

### Phase 2: The "Single Dependency" Frontend Slice

**Goal:** Compile a module (`app`) that depends on another (`utils`) by generating `utils.sma`, rehydrating its public
interface, and then generating `app.sma`. This phase will *not* yet handle language extensions.

* **Task 2.1:** Implement SMA serialization ("dehydration") and deserialization ("rehydration") for public interfaces.
* **Task 2.2:** Modify the `BuildOrchestrator` to loop through the build order. For each module, it will:
  1. Load the SMAs of its dependencies (generated in previous iterations).
  2. Invoke the `FrontendService`, providing the dependency SMAs.
* **Task 2.3:** The `FrontendService` rehydrates the dependency SMAs into the `CompilationSession` before parsing the
  current module's source files. It then generates a new `.sma` and saves it to the cache.
* **Verification:** The orchestrator can successfully generate valid `.sma` files for a project with at least one
  inter-module dependency.

### Phase 3: The Backend Slice

**Goal:** Create a complete, single-threaded build pipeline that can take a root module and produce a final, executable
bytecode artifact.

* **Task 3.1:** Implement rehydration for the *private implementation* section of an SMA.
* **Task 3.2:** Implement the `BackendService`. It will take a list of SMAs to link, rehydrate them into a single
  `ir.Context`, and run the IR-to-Bytecode lowering pass.
* **Task 3.3:** Connect the `Orchestrator` to the `BackendService`. After the frontend pass is complete, it will
  schedule a backend job for the root module.
* **Verification:** The build driver can compile a multi-module project into a single, valid, and executable bytecode
  file.

### Phase 4: Full Incrementality and Language Extensions

**Goal:** Implement the CBR hashing, caching, parser configuration, and parallel execution needed for a fast, truly
incremental build.

* **Task 4.1:** Implement CBR generation and hashing (`generateInterfaceHash`).
* **Task 4.2:** In the `Orchestrator`, implement the logic to configure a parser with language extensions by rehydrating
  the public interfaces of extension modules.
* **Task 4.3:** Update the `interface_hash` calculation to be compositional, including the hashes of used extensions.
* **Task 4.4:** Implement caching. The `Orchestrator` will now use the `interface_hash` to decide whether a module and
  its reverse dependencies need frontend/backend recompilation.
* **Task 4.5:** Integrate a thread pool into the orchestrator for parallel backend job execution.

### Phase 5 & 6: Hot-Reloading

These phases build upon the now-complete incremental compiler.

* **Phase 5: V0 - Fast Restart:** Implement the file watcher and the signaling mechanism between the orchestrator and
  the running application to trigger a clean restart.
* **Phase 6: V1 - Live State Migration:** Implement the compiler and runtime support for state migration: the
  `Migratable` type class, `RemapAddress` effect, migratable allocators, and the atomic migration transaction logic.