# Unified Architecture for the Ribbon Compiler & Runtime

This document outlines a refined, unified architectural vision for the Ribbon compiler and its hot-reloading capabilities. The central goals are to achieve best-in-class performance through **parallel and incremental compilation** while enabling a uniquely powerful and safe **live state migration** system for hot-reloading, all built upon Ribbon's core language principles.

This plan implements a robust, cryptographically-sound model for interface identity, which serves as the foundation for both compiler incrementality and runtime type safety.

## Part 1: A Parallel and Incremental Compiler

### 1.1. Overview & Core Principles

The Ribbon compiler is designed from the ground up to support modern development workflows. This architecture focuses on two primary goals:

1.  **Parallel Compilation:** Drastically reduce full build times by compiling independent modules simultaneously.
2.  **Incremental Compilation:** Recompile only the modules affected by code changes, making iterative development nearly instantaneous.

The foundation of this architecture is a **Hub-and-Spoke Model** orchestrated by a central build manager. This model cleanly separates the compilation process into distinct, reusable services:

*   **The Build Orchestrator:** The central brain of the build system. It manages the module dependency graph, the compilation cache, and coordinates the workflow between the other services.
*   **The Frontend Service:** A pure analysis service. Its sole job is to take source code and produce a semantic representation of its public interface.
*   **The Backend Service:** A pure code generation service. Its job is to take the semantic representation from one or more modules and produce a final, executable artifact (e.g., bytecode).

This separation is the key to unlocking both parallelism and accurate incrementality, while also enabling other tools like Language Server Protocol (LSP) servers to reuse the frontend analysis without depending on the code generation backend.

### 1.2. Phase 1: The Frontend Service and the Serializable Module Artifact (SMA)

The first phase of compilation is a fast analysis pass performed by the **Frontend Service**. It is responsible for producing a **Serializable Module Artifact (SMA)** for every module (`.sma` file). The SMA is a self-contained, context-free, and cacheable representation of a module's public contract and its dependencies. It is not a separate IR, but a **"dehydrated," on-disk projection of the live `ir.Node` graph's public interface**.

The `sma.Ref` (Symbolic IR Reference) is the core of the SMA format, providing a stable, context-free replacement for the ephemeral, in-memory `ir.Ref`.

```zig
// sma.sma.Ref: A stable, serializable reference to an IR node.
const sma.sma.Ref = union(enum) {
    /// A reference to another node within this SAME artifact.
    /// The u32 is an index into this SMA's flattened node array.
    internal: u32,

    /// A stable, symbolic reference to an item in another module.
    external: struct {
        module_guid: ir.ModuleGUID, // A unique hash identifying the target module.
        symbol_name_idx: u32,       // Index into this SMA's string_table.
    },

    /// A reference to a well-known compiler builtin.
    builtin: ir.Builtin,
    
    nil,
};
```

### 1.3. The `interface_hash`: Canonical Binary Representation and Merkle Hashing

The `interface_hash` in the SMA header is the cornerstone of incremental compilation. This approach replaces earlier, more fragile ideas with a cryptographically robust method.

**The hash must be an absolutely deterministic, canonical, and compact representation of a module's public ABI and API.**

*   It **must change** if a public function's signature (including its full, inferred effect row), a public struct's layout, or any other aspect of the public contract changes.
*   It **must not change** if private implementation details, comments, or formatting are modified.

To achieve this, the `FrontendService` will generate a **Canonical Binary Representation (CBR)** for every public symbol. The final `interface_hash` is a Merkle-style hash of the entire public API, making it compositional and efficient.

**The `interface_hash` Algorithm:**

1.  **Full Module Analysis:** The `FrontendService` performs a full analysis of the entire module, including private implementations. This is crucial to correctly infer the complete effect rows of all public functions.

2.  **Build CBRs for Public Symbols:** A CBR is a tree of normalized, ABI-relevant data. The service traverses the public-facing `ir.Node` graph for each public symbol and recursively generates its CBR.

3.  **Canonicalize and Hash Components:**
    *   **Structs:** The CBR includes a `layout_policy` (`packed` or `C`). Public fields are sorted before hashing: alphabetically by name for `packed` structs, and by memory offset for `C` layout structs.
    *   **Functions:** The CBR includes the hashes of the CBRs for its return type and each parameter type. It also includes the hash of its full, inferred effect row, which is canonicalized by alphabetically sorting the effect names.
    *   **Generics:** The CBR is built for the *unspecialized* generic form, treating type parameters as built-in symbols with their own stable hashes.

4.  **Final Assembly:** The final CBR hashes for all public symbols are sorted alphabetically by symbol name and then hashed together to produce the final `interface_hash`.

### 1.4. Generics, Metaprogramming, and the Specialization Cache

To handle generics and metaprogramming, the **Backend Service** will use a **Specialization Cache**.

*   **Unspecialized SMAs:** SMAs store the interfaces of generic types in their abstract form (`List T`).
*   **Specialization on Demand:** When a module consumes a specialization (`List i32`), the `BackendService` queries the Specialization Cache with a stable key (e.g., `hash(hash("List T") + hash("i32"))`).
*   **Cache Logic:** On a cache miss, the backend performs monomorphization and generates the concrete implementation. On a hit, the pre-compiled artifact is used.
*   **RTTI Generation:** The **`Type Version ID`** needed for hot-reloading is the hash of a type's CBR, which is already computed by the `FrontendService`.

### 1.5. Phase 2: The Parallel Backend Service

The **Backend Service** consumes one or more SMAs to generate final artifacts in an embarrassingly parallel fashion. A `backend.Job` for a given module will:

1.  Create a private `ir.Context`.
2.  **Rehydrate** the SMAs for all its dependencies by loading them and reconstructing their public interfaces in the job's context. This is a two-pass process (shell creation -> linkage) to correctly handle graph cycles.
3.  Compile its own private implementation against these rehydrated interfaces.
4.  Run optimizations and generate the final artifact (e.g., `core.Bytecode`).

### 1.6. The Build Orchestrator and Incremental Workflow

The **Build Orchestrator** is the central coordinator of the entire process. It manages the `SMACache`, the `DependencyGraph`, and invokes the services.

**Workflow of an Incremental Build:**

1.  **Trigger:** A file watcher reports that `module_b.ribbon` has been modified.
2.  **Orchestration Begins:** The orchestrator is invoked for `module_b`.
3.  **Phase 1 (Analysis):** The orchestrator calls `frontend.generateSMA("path/to/module_b.ribbon", ...)` to produce a `new_module_b_sma`.
4.  **The "Should I Recompile?" Check:**
    *   The orchestrator retrieves `old_module_b_sma` from its `cache`.
    *   It compares `old_module_b_sma.header.interface_hash` with `new_module_b_sma.header.interface_hash`.
5.  **Decision & Scheduling (Phase 2):**
    *   **Case A: Hashes Match (No Public API Change).**
        *   The orchestrator schedules a single backend job: `backend.compile(&.{new_module_b_sma})`.
    *   **Case B: Hashes Differ (Public API Change).**
        *   The orchestrator consults `dep_graph` for the *reverse dependencies* of `module_b` (e.g., `module_c`, `module_d`).
        *   It schedules a parallel backend job for each affected module (`module_b`, `module_c`, `module_d`).
6.  **Cache Update:** Upon success, the orchestrator updates the cache with the new SMAs and artifacts.

This model allows an **LSP server** to be built as a separate consumer of the `Orchestrator` and `FrontendService`, getting all the semantic information it needs from the SMA without ever touching or depending on the `BackendService`.

### 1.7. Link-Time Optimization (LTO)

The existing `ir.Context.merge` function will be repurposed for an optional, final **Link-Time Optimization (LTO)** stage. In an LTO build, the orchestrator can direct the backend to merge the IR for all modules into a single context, enabling powerful whole-program optimizations like cross-module inlining.

## Part 2: A Robust Hot-Reloading System

This system leverages the SMA architecture to implement safe and powerful hot-reloading. The core principle is: **State migration is a user-space, type-safe, and compositional process, orchestrated by the runtime as a handled effect.**

### 2.1. Version 0: Compile & Restart

The initial implementation will provide a rapid recompile-and-relaunch cycle.

1.  A file watcher triggers an incremental build via the orchestrator.
2.  Upon success, the orchestrator signals the running Ribbon application.
3.  The application's host logic cleanly tears down its state and re-initializes using the new code.

### 2.2. Version 1: Live State Migration

#### Compiler Responsibilities: Type Evolution and Safety

The runtime will perform a GC-style root-up traversal utilizing a worklist. Calls to migrate must be deferrable, for example when an allocator migrates it needs to defer its allocations' migrations to avoid out-of-order migration. Ribbon's lack of full continuations will require the addition of a "retry" system when `get_new_address` fails because of dependency chains etc. The migration orchestrator in the runtime must have access to both the old and new SMAs during the migration transaction.

*   **The `Migratable` Type Class:** Users define migration logic via a standard type class. The compiler can auto-generate implementations for simple, non-breaking changes.
    ```ribbon
    Migratable := class From, To.
        migrate: From -> To | { RemapAddress, Error String }
    ```
*   **The `RemapAddress` Effect:** This is conceptualized something like the following:
    ```ribbon
    RemapAddress := effect.
        get_new_address : (*'old opaque) -> (*'new opaque) | { Error String }
        set_new_address : (*'old opaque, *'new opaque) -> () | { Error String }
    ```
*   **The `Unsafe` Effect and Trust Boundary:**
    ```ribbon
    Unsafe := effect.
        ;; no methods
    ```
    FFI calls implicitly add an `Unsafe` effect. Migrating a struct containing FFI resources will therefore be `Unsafe`. Only trusted modules can handle this effect, creating a clear safety boundary. The key implementation detail here will be defining the "trust boundary." Modules will be contractually provided with the ability to *handle* the `Unsafe` effect. This can be controlled at the location the module is imported, via annotations and other metadata. For example `trusted_guest := #trusted import "path/to/guest.bb"`, or as a flag passed to a runtime extension loader.

#### Runtime Responsibilities: State Tracking & Migration

*   **Migratable Allocators and RTTI:** Special allocators attach RTTI—specifically, the **`Type Version ID`** (from the CBR hash)—to memory blocks. This overhead is pay-for-what-you-use; production builds can use standard allocators for zero overhead.
*   **State Discovery and Host Root Registration API:** The runtime discovers state by traversing migratable allocators and registered globals. For state held only by the host (e.g., a Ribbon object in a Zig `HashMap`), the host can use an API to register these objects as roots for the migration traversal.

#### Handling Concurrency: The Safe Point Effect

To avoid migrating live call stacks, Ribbon uses a cooperative approach.

*   **The `hotReloadSyncPoint` Handler:** The application developer prompts this handler at safe points in their main loop.
*   **"Stop-the-World" Handshake & Fallback:** When a hot-reload is requested, the runtime pauses threads at their next sync point. If any thread's call stack contains a frame from a module being reloaded, the migration is **aborted**, and the system safely **falls back to the V0 fast restart behavior**, guaranteeing stability.

#### The Migration Transaction: An Atomic, Rollback-Safe Process

If all stacks are clean, the migration proceeds atomically.

1.  **Phase 1 (Allocation & Mapping):** The runtime traverses the old state, allocating new memory and building a map from old addresses to new addresses. The old state remains untouched.
2.  **Phase 2 (Migration Loop):** The runtime iteratively calls the user's `migrate` functions. It provides a handler for the `RemapAddress` effect, which uses the address map to patch pointers.
3.  **Completion or Abort:**
    *   **On Abort:** If any `migrate` fails, the transaction is rolled back by freeing all new memory. The application resumes with the original code and state.
    *   **On Success:** The runtime atomically swaps the application's root pointers to the new state, frees the old memory, and resumes execution.

### Core Challenges & Considerations

1.  **CBR Implementation Complexity:** Canonicalization is difficult. Every detail must be perfectly deterministic. Rigorous testing will be paramount.
2.  **Build Orchestrator Complexity:** The orchestrator is a significant piece of engineering, responsible for caching, dependency analysis, and job scheduling. It needs to be robust and performant.
3.  **Metaprogramming and Macros:** The `interface_hash` of a module must change if a macro it uses expands to produce a different public API. This dependency must be tracked.
4.  **Host Root Registration API:** This FFI boundary must be carefully designed to ensure memory safety and clear ownership semantics.
5.  **State Discovery Performance:** For applications with large state graphs, the traversal could introduce a noticeable pause. Future work could explore snapshotting to mitigate this.

---

# Implementation Plan

This section outlines the concrete steps required to implement the Unified Architectural Plan for Ribbon. It is designed to guide contributors through the development process, from foundational data structures to the full hot-reloading system.

## Proposed Order of Implementation

The architecture is designed to be built in logical, verifiable stages. The recommended order of implementation is as follows:

1.  **Part 1: Foundational Data Structures:** Define the core SMA and CBR structures.
2.  **Part 1: The Frontend Service:** Implement the analysis pass that produces SMAs. This is the highest priority as it unblocks all other compiler work.
3.  **Part 1: The Backend Service:** Implement the service that consumes SMAs and produces bytecode.
4.  **Part 1: The Build Orchestrator:** Tie the services together to achieve parallelism and incrementality.
5.  **Part 2: Hot-Reloading V0 (Fast Restart):** Implement the simpler restart-based hot-reloading as a first milestone.
6.  **Part 2: Hot-Reloading V1 (Live State Migration):** Implement the full state migration system.

## Part 1: Implementing the Parallel and Incremental Compiler

The goal of this part is to build a high-performance compiler that minimizes rebuild times through parallelism and caching.

#### Phase 1: Foundational Data Structures

Before services can be built, the data they exchange must be defined. This involves creating the on-disk format for the Serializable Module Artifact (SMA).

*   **Task 1.1: Define Serializable Module Artifact (`.sma`) Structure.**
    *   **Location:** A new file, `src/mod/sma.zig`.
    *   **Details:** Define the top-level `SMA` struct with the following components:
        *   `header`: Contains metadata like `ribbon_version`, `module_guid`, and the crucial `interface_hash`.
        *   `string_table`: A contiguous block of memory for all symbol names, strings, etc., referenced by index.
        *   `public_symbols`: A list mapping public symbol names (by index into `string_table`) to their root `sma.Ref`s in the `node_table`.
        *   `node_table`: A flattened array of `sma.Node`s, representing the dehydrated public IR graph.

*   **Task 1.2: Define `sma.sma.Ref` and `ir.ModuleGUID`.**
    *   **Location:** `src/mod/sma.zig` and `src/mod/ir.zig`.
    *   **Details:**
        *   In `ir.zig`, define `ModuleGUID` as a `u128` (or similar hash result type), derived from a canonical hash of the module's source path. For maximum robustness across different machines and build environments (e.g., vendored dependencies), this should be a hash of a canonical module name (e.g., my_project/utils/collections) rather than a filesystem path.
        *   In `sma.zig`, implement the `sma.Ref` (Symbolic IR Reference) union. This is the stable, serializable replacement for the in-memory `ir.Ref`.
            *   `internal: u32`: An index into the *current SMA's* `node_table`.
            *   `external: struct { module_guid: ir.ModuleGUID, symbol_name_idx: u32 }`: A reference to a public symbol in another module.
            *   `builtin: ir.Builtin`: A reference to a compiler-known primitive.
            *   `nil`: A null reference.

*   **Task 1.3: Define Canonical Binary Representation (CBR) In-Memory Structures.**
    *   **Location:** A new file, `src/mod/frontend/cbr.zig`.
    *   **Details:** Define the in-memory tree structures that represent the canonical form of public symbols before they are hashed. This is not for serialization, but for deterministic hashing.
        *   `CbrNode`: A union for different symbol kinds (function, struct, etc.).
        *   `CbrStruct`: Contains `layout_policy` and a *sorted* list of `CbrField`s (name hash, type hash).
        *   `CbrFunction`: Contains hashes for return type, parameters, and the canonicalized (sorted) effect row.

#### Phase 2: Implementing the Frontend Service

This service is responsible for analysis and SMA generation. It is the most critical first step.

*   **Task 2.1: Refactor Frontend Logic into a `frontend` Service.**
    *   **Action:** Create a new `src/mod/frontend.zig` module.
    *   **Details:** Move the parsing and semantic analysis logic currently in `src/mod/meta_language.zig` into this new, dedicated service. The `meta_language` module will become a consumer of this service.

*   **Task 2.2: Implement Full Semantic Analysis (RML-to-IR).**
    *   **Action:** Flesh out the `meta_language.compileExpr` function.
    *   **Details:** This is a major task that involves implementing the full semantic analysis of Ribbon code. It is the direct implementation of the "Missing Links: RML-to-IR Compilation" section in the `README.md`. The eventual outcome must be the correct and complete inference of types and effect rows for all functions, as this is critical for the `interface_hash`. However, the target for this task is simply compiling the object-typed ML; thus types will all be relatively simple, and relatively little inference is required for this task's purposes. The typed language's frontend facilities will then be implemented *in* RML, communicating with the runtime via builtin/FFI bindings.

*   **Task 2.3: Implement CBR Generation and Hashing.**
    *   **Location:** `src/mod/frontend/cbr.zig`.
    *   **Details:** After semantic analysis produces a complete `ir.Context`, implement the logic to generate the `interface_hash`.
        1.  Create a function `generateCbr(ir.Ref) -> CbrNode`. This function will traverse the IR graph from a public symbol's `ir.Ref` and build the corresponding `CbrNode` tree.
        2.  Implement the canonical sorting logic within `generateCbr`: sort struct fields (alphabetically or by offset) and function effect rows (alphabetically).
        3.  Implement a function `hashCbr(CbrNode) -> u128`. This performs a Merkle-style hash on the `CbrNode` tree.
        4.  Implement the final `generateInterfaceHash(*ir.Context) -> u128` function, which gets all public symbols, generates and hashes their CBRs, sorts the final hashes, and produces the single `interface_hash`.

*   **Task 2.4: Implement SMA "Dehydration" (Serialization).**
    *   **Location:** `src/mod/sma.zig`.
    *   **Details:** Create a function `dehydrate(ctx: *ir.Context, path: []const u8) !void`.
        1.  Traverse the public symbols in the `ctx` to build a `string_table`.
        2.  Perform a second traversal of the public IR graph. For each `ir.Node`, create a corresponding `sma.Node`.
        3.  During this traversal, convert every `ir.Ref` into its stable `sma.sma.Ref` equivalent. This is the core translation step.
        4.  Write the `SMA` header (including the computed `interface_hash`), `string_table`, `public_symbols` list, and `node_table` to the output `.sma` file.

#### Phase 3: Implementing the Backend Service

This service consumes SMAs and produces executable artifacts.

*   **Task 3.1: Refactor Backend Logic into a `backend` Service.**
    *   **Action:** Solidify the `src/mod/backend.zig` file as the home for this service.
    *   **Details:** Ensure the `Compiler` and `Target` concepts align with the service model, where a `Job` is the primary unit of work.

*   **Task 3.2: Implement SMA "Rehydration" (Deserialization).**
    *   **Location:** `src/mod/backend.zig`.
    *   **Details:** Create a function `rehydrate(job: *Job, sma: SMA) !void`. This populates a job's empty `ir.Context` from an SMA file. This is a critical two-pass process:
        1.  **Pass 1 (Shell Creation):** Iterate through the SMA's `node_table` and create empty "shell" `ir.Node`s in the `ir.Context`. Store the mapping from the SMA `internal` index to the new `ir.Ref`. This breaks dependency cycles.
        2.  **Pass 2 (Linkage):** Iterate through the `sma.Node` table again. For each shell `ir.Node`, populate its `ref_list` by resolving its `sma.Ref`s using the map created in Pass 1. `external` references are kept as unresolved stubs for now.

*   **Task 3.3: Implement IR-to-Bytecode Pass.**
    *   **Action:** Implement the `backend.BytecodeTarget.runJob` function.
    *   **Details:** This is the direct implementation of the "Missing Links: IR-to-Bytecode Compilation" section from the `README.md`. It will traverse the `ir.Graph` within a `Job` (which now contains both its own code and rehydrated dependency interfaces) and emit bytecode using the `bytecode.FunctionBuilder` API.

#### Phase 4: Implementing the Build Orchestrator

This is the top-level controller that makes the system incremental and parallel.

*   **Task 4.1: Implement Core Orchestrator Data Structures.**
    *   **Location:** A new file, e.g., `src/mod/orchestrator.zig`.
    *   **Details:**
        *   `SMACache`: A persistent map (e.g., on-disk key-value store or in-memory map for the lifetime of the tool) from `ModuleGUID` to a cached `SMA.Header`.
        *   `DependencyGraph`: A graph data structure mapping `ModuleGUID`s to their forward and reverse dependencies.

*   **Task 4.2: Implement the Main Build Loop.**
    *   **Action:** Create the main `orchestrator.buildModule(path)` function.
    *   **Details:** Implement the workflow described in the architectural plan:
        1.  Take a module path as input.
        2.  Invoke the `FrontendService` to generate a new SMA.
        3.  Load the old SMA header from the `SMACache`.
        4.  Compare the `interface_hash`.
        5.  If hashes differ, query the `DependencyGraph` for reverse dependencies.
        6.  Schedule a list of modules that need a backend compile pass.

*   **Task 4.3: Implement Parallel Job Execution.**
    *   **Action:** Integrate a thread pool into the orchestrator.
    *   **Details:** Take the list of modules generated in Task 4.2 and submit a `BackendService` compilation job for each one to the thread pool. Wait for all jobs to complete.

## Part 2: Implementing the Robust Hot-Reloading System

This part builds upon the incremental compiler to provide live code updates.

#### Phase 5: V0 - Fast Restart

This is the foundational, simpler version of hot-reloading.

*   **Task 5.1: Integrate a File Watcher.**
    *   **Action:** Use a cross-platform file watching library or Zig's standard library to monitor source files for changes.
    *   **Details:** When a change is detected, the watcher should invoke `orchestrator.buildModule`.

*   **Task 5.2: Implement Orchestrator-to-Runtime Signaling.**
    *   **Action:** Implement a simple compiler<->runtime communication mechanism.
    *   **Details:** A basic queue a good choice. After a successful build, the orchestrator writes a message to the queue.

*   **Task 5.3: Implement Host Application Restart Logic.**
    *   **Action:** The runtime will run a background thread to listen for messages from the compiler.
    *   **Details:** Upon receiving a signal, runtime triggers host shutdown and re-initialization sequence, loading the newly compiled artifacts.

#### Phase 6: V1 - Live State Migration

This is the advanced, state-preserving version of hot-reloading.

*   **Task 6.1: Compiler and Language Support.**
    *   **Action:** Implement the `Migratable` type class and `Unsafe` effect.
    *   **Details:**
        1.  In the `frontend` service, add the `Migratable` class to the prelude as a known built-in. Its definition is `class From, To. migrate: (From) -> To | { RemapAddress, Error String }`.
        2.  During semantic analysis, implicitly add the `Unsafe` effect to any function that performs an FFI call.
        3.  Add logic for `derive(Migratable)`. For a struct change that only adds new fields with default values, the compiler can generate a `migrate` function automatically.

*   **Task 6.2: Runtime State Tracking.**
    *   **Action:** Implement the `MigratableAllocator` and the host registration API.
    *   **Details:**
        1.  Create a new allocator in `core.zig` that wraps a standard allocator. `alloc` will prepend a small header to each allocation containing the `Type Version ID` (the CBR hash of the type).
        2.  Expose an FFI-safe API from the runtime, e.g., `ribbon_register_root(*core.Fiber, core.Value)` and `ribbon_unregister_root(*core.Fiber, core.Value)`. This allows the host to inform the Ribbon runtime about Ribbon objects it owns.

*   **Task 6.3: Implement the Migration Transaction.**
    *   **Action:** Implement the core migration logic in the runtime/interpreter.
    *   **Details:** This is the most complex part.
        1.  **Sync Point:** Implement the `hotReloadSyncPoint` effect. The application's main loop will handle this. When a reload is pending, this handler will not return immediately.
        2.  **Handshake Logic:** Inside the `hotReloadSyncPoint` handler, implement the "stop-the-world" check. Iterate through all threads and inspect their `core.CallStack`. If any `CallFrame` references a function from a module being reloaded, abort the migration and fall back to a fast restart.
        3.  **Phase 1 (Allocation & Mapping):** If the handshake succeeds, begin the transaction. Traverse all registered roots (globals, host roots, migratable allocators). For each old object, allocate a corresponding new object (of the new type version) and store the mapping `(old_address -> new_address)` in a temporary hash map.
        4.  **Phase 2 (Migration):** Traverse the old state again. For each object, find its `Migratable` implementation and call the `migrate` function.
        5.  **`RemapAddress` Effect:** Provide a runtime handler for the `RemapAddress` effect. When prompted, this handler will look up the old address in the temporary map and return the new address, allowing the user's `migrate` function to patch pointers correctly.
        6.  **Commit/Rollback:** If all `migrate` calls succeed, atomically update the root pointers to point to the new state and free the old memory. If any call fails, abort the transaction by freeing all *newly allocated* memory and resuming execution with the old state.