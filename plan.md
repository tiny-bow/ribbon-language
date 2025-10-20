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
  sources =
    "renderer.rib",
    "shaders/",          ;; Includes all .rib files in this directory
    "mesh/",


  ;; A map of modules this module depends on.
  ;; The keys ('std', 'gpu') are the local aliases used in `import` statements.
  ;; The values are dependency specifiers (e.g., version strings, paths).
  dependencies =
    std = package "core@0.1.0"
    gpu = github "tiny-bow/rgpu#W7SI6GbejPFWIbAPfm6uS623SVD"
    linalg = path "../linear-algebra"
  

  ;; A list of language extension modules to activate for this module.
  ;; The compiler will load the public interfaces of these extensions
  ;; to configure the parser with their custom syntax rules and macros.
  extensions =
    std/macros,
    std/dsl/operator-precedence,
    gpu/descriptors,
    linalg/vector-ops,

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

### 1.7. Discussion

The choice of consistent dehydration to SMA in the frontend is a key architectural decision that might seem
counterintuitive at first glance.

In the simplest possible case: a clean, single-threaded build of one module with no dependencies;
the sequence of events is:

1.  **Frontend:** Analyzes source code -> Populates an in-memory `ir.Context`.
2.  **Frontend:** Dehydrates the `ir.Context` -> Writes a `.sma` file to disk (or memory).
3.  **Backend:** Reads the `.sma` file -> Rehydrates it back into an `ir.Context`.
4.  **Backend:** Generates bytecode from that `ir.Context`.

Looked at in isolation, that sequence seems wasteful. The `ir.Context` existed in memory, was serialized, and then
immediately deserialized.

However, the architecture isn't optimized for this simple case. The "always dehydrate" rule is a deliberate
architectural trade-off that unlocks the compiler's primary goals: **parallelism, robust incrementality, and tooling
integration.** It's the cost of entry for these powerful features.

Here is why that "wasteful" step is actually the cornerstone of the whole design:

#### 1.7.1. Strict Separation of Concerns

The design treats the Frontend and Backend as completely separate, decoupled services.

*   The **Frontend's contract** is: "Given source code and dependency SMAs, produce a new SMA."
*   The **Backend's contract** is: "Given one or more SMAs, produce an executable artifact."

The SMA is the clean, well-defined API boundary between them. By *always* producing an SMA, the Frontend fulfills its
contract every single time. This keeps its logic simple and predictable. It doesn't need a special "fast path" where it
sometimes passes an in-memory object to the backend, which would complicate the interface and create a tighter coupling
between the two services.

#### 1.7.2. Enabling Parallel Compilation

This is a huge reason. The in-memory `ir.Context` is a complex graph full of pointers. It's not something we can easily
or safely pass between different processes or threads. A serialized binary file, however, is the perfect medium for
inter-process communication.

Consider a project with two independent modules, `A` and `B`:

1.  The **Orchestrator** sees that `A` and `B` can be compiled in parallel.
2.  It launches **two separate Frontend processes/threads**, one for `A` and one for `B`.
3.  Frontend `A` analyzes `A.rib` and writes `A.sma`.
4.  Frontend `B` analyzes `B.rib` and writes `B.sma`.
5.  Once both files are written, the Orchestrator knows
    the frontend phase for both is complete and can schedule the backend jobs.

Without the SMA as a concrete output artifact, this parallel workflow would be impossible. The Frontend couldn't just
"hand over" its in-memory `ir.Context` to a separate backend process.

#### 1.7.3. The Foundation of Incremental Builds & Caching

**The SMA file *is* the cache.** The entire incremental build system depends on the existence of this file from the
previous compilation run.

Here's the workflow on a *second* build, after a change in a file in Module `A`:

1.  The **Orchestrator** sees a change in `A.rib`.
2.  It runs the **Frontend** on Module `A`, producing a **new `A.sma`**.
3.  It then computes the **CBR `interface_hash`** from the new `A.sma`.
4.  It loads the **old `A.sma`** from the cache and compares its `interface_hash`.
    *   If the hashes match, the public API hasn't changed.
        The Orchestrator knows it only needs to run the Backend on Module `A`.
    *   If the hashes differ, the API has changed. The Orchestrator uses its dependency graph
        to find all modules that depend on `A` and schedules them for a backend recompile as well.

Without the Frontend *always* producing an SMA, there would be no artifact to cache and no `interface_hash` to compare
on the next run. The dehydration step isn't just for the current build; it's an investment for all future builds.

#### 1.7.4. Decoupling for Tooling (like Language Servers)

This separation is also a huge win for other tools. A Language Server (like the one that powers VS Code's IntelliSense)
needs to do exactly what the Frontend does: parse and analyze code to find errors, provide definitions, etc.

However, a Language Server **has no need for a backend**. It doesn't generate code.

Because the Frontend is a separate service, the Language Server can use it directly to get semantic information about
the code without ever needing to link against or even know about the Backend service. This makes the compiler's core
analysis logic highly reusable.

#### 1.7.5. A Note on the Term "Rehydration"

It's also worth clarifying the data flow. In a full build of a single module `A`:

1.  **Frontend for `A`:**
    *   *Rehydrates* the **public interfaces** from the SMAs of its dependencies (e.g., `std.sma`).
    *   Analyzes `A.rib`.
    *   *Dehydrates* its complete IR (public and private) into `A.sma`.
2.  **Backend for `A`:**
    *   Consumes the entire `A.sma`, loading both the public and private sections into an `ir.Context` to generate code.

So, the immediate "rehydration" after dehydration is done by a different component (the Backend) for a different purpose
(code generation). The Frontend only ever rehydrates the *public interfaces* of *other* modules.

The dehydration step is the pivot point upon which the entire parallel and incremental architecture rests. It provides
the clean, serializable artifact that enables caching, inter-process communication, and service decoupling. The minor
overhead in the simplest case is a very small price to pay for the massive performance gains and architectural clarity
in all other, more common scenarios.

### 1.8 Critical Action Items

#### 1.8.1. The AST-to-IR Transformation (Semantic Analysis)

This is the core logic of the **Frontend Service**. It's the bridge between what the parser produces and what the rest
of the compiler consumes.

*   **What it is:** The process of walking the Abstract Syntax Tree (`meta_language.Expr`) and building the semantic
    graph in an `ir.Context`. This is where the compiler truly starts to *understand* the code.
*   **Current Status:**
    * **Solid Input:** The parser is capable of turning source code into an `Expr` AST (`ml_integration.zig` tests this).
    * **Solid Output Target:** The `ir.Context` data model is extremely robust and ready to be populated
        (`ir_integration.zig` tests this).
*   **What's Missing (The Core Task):**
    1. **Symbol Resolution:** Logic to create and manage scopes. When the code says `x + 1`, this pass needs to figure
       out what `x` refers to (a function parameter, a local variable, an imported symbol, etc.).
    2. **Type Inference/Checking:** The heart of the analysis. It must walk the `Expr` tree, assign types to every node,
       and ensure that operations are valid (e.g., can't add a string to an integer). For the metalanguage analysis,
       this is a much simpler task, due to the dynamic typing. Every expression is of type `Value` or nil.
    3. **Control-Flow Graph (CFG) Generation:** Translating syntactic constructs like `if/else` or `match` expressions
       into the IR's representation of basic blocks (`ir.StructureKind.block`) and control-flow edges
       (`ir.StructureKind.ctrl_edge`).
*   **Why it's Critical:** Without this transformation, the Frontend has no meaningful `ir.Context` to pass on. It can
    parse the code, but it can't understand it. This is the primary missing piece within the Frontend Service itself.

#### 1.8.2. SMA Dehydration and Rehydration

This is the implementation of the "API boundary" between the Frontend and Backend services, as defined in `src/mod/sma.zig`.

*   **What it is:** The process of serializing the in-memory `ir.Context` graph to a `.sma` file (dehydration) and the
    reverse process of loading a `.sma` file back into an `ir.Context` (rehydration).
*   **Current Status:**
    * The file format and in-memory structures (`sma.Artifact`, `sma.Node`, `sma.Ref`) are already defined.
    * The skeleton `Dehydrator` and `Rehydrator` structs exist.
*   **What's Missing (The Core Task):**
    1. **Dehydration Logic (`Dehydrator.dehydrateNode`)**: The recursive algorithm that walks the live `ir.Context`
       graph. Its most important job is to translate in-memory pointers (`ir.Ref`) into stable, serializable `sma.Ref`s
       (which are indices or external symbol references). This involves distinguishing between public, private, and
       external references.
    2. **Public Interface Separation (`Dehydrator.findPublicRefs`)**: This is a crucial, non-trivial part of
       dehydration. The code needs to traverse the IR graph starting from exported symbols and correctly identify the
       complete public API (e.g., a function's signature but *not* its body) to separate it from the private
       implementation.
    3. **Rehydration Logic (`Rehydrator.run`)**: The two-pass process described in `plan.md`.
        * **Pass 1:** Create "shell" `ir.Node`s for everything in the SMA's public interface.
        * **Pass 2:** Go back and link all the nodes together by converting the `sma.Ref`s back into live `ir.Ref`
          pointers. This two-pass approach is essential to correctly handle cyclic type definitions.
*   **Why it's Critical:** This is the communication channel between all compiler stages. Without it, the Frontend can't
    save its work, and the Backend can't load the work of dependencies to begin its own process. For our test case, the
    Frontend for `main.rib` would be unable to rehydrate `utils.sma` to understand the functions it's importing.

#### 1.8.3. The IR-to-Bytecode Lowering Pass

This is the primary responsibility of the **Backend Service**.

*   **What it is:** The process of traversing a complete, merged `ir.Context` and emitting the corresponding bytecode
    instructions using the `bytecode.TableBuilder` API.
*   **Current Status:**
    * **Solid Input:** The `ir.Context` is the well-defined input.
    * **Excellent Output API:** The `bytecode.TableBuilder` API is mature, powerful, and heavily tested
        (`bc_integration.zig`). It can already build complex functions with branches, locals, and effects.
*   **What's Missing (The Core Task):**
    1. **Graph Linearization:** An algorithm to walk the IR's control-flow graph (a set of linked `block` nodes) and
        decide the final, linear layout of bytecode blocks in memory.
    2. **Instruction Selection/Lowering:** The logic that iterates through the `instruction` nodes within each IR block
        and translates them. For example, seeing an IR node for addition (`ir.Operation.add`) must trigger a call to
        `BlockBuilder.instr(.i_add64, ...)` with the correct registers.
    3. **Register/Stack Allocation:** A strategy for mapping the infinite set of values in the IR to the VM's finite set
        of registers or stack slots (`addr_l`, `load64`, `store64`).
*   **Why it's Critical:** This is the final step that produces the actual executable. Without this, the compiler can
    fully analyze and represent the program but has no way to generate the bytecode that the (already functional)
    interpreter can run.

#### 1.8.4. The Path to a Testable Slice

The great news is that the "ends" of the pipeline are in very good shape:
*   **Beginning:** Parsing source to an AST (`ml_integration.zig`).
*   **End:** Assembling bytecode manually (`bc_integration.zig`) and executing it (`bc_interp.zig`).

The critical path to making the vertical slice testable is to implement the **three major "middle" pieces** that connect
these ends:

1.  **Frontend:** Implement **AST-to-IR analysis** to create a semantic graph.
2.  **Interface:** Implement **SMA Dehydration/Rehydration** to save and load that graph.
3.  **Backend:** Implement the **IR-to-Bytecode lowering** logic to translate the graph into instructions for the
    existing bytecode builder.

Fleshing out these three areas, even in a minimal way, will complete the end-to-end pipeline and make the compiler
testable as a whole.

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