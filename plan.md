# Unified Architecture for the Ribbon Compiler & Runtime

This document outlines a refined, unified architectural vision for the Ribbon compiler and its hot-reloading capabilities. The central goals are to achieve best-in-class performance through **parallel and incremental compilation** while enabling a uniquely powerful and safe **live state migration** system for hot-reloading.

This plan moves away from a strictly bottom-up implementation order towards a **vertical slice** strategy. This ensures that at each stage of development, core components have the necessary high-level context to be implemented robustly, avoiding the architectural friction of building low-level pieces in isolation.

## Part 1: A Parallel and Incremental Compiler

### 1.1. Overview & Core Principles

The Ribbon compiler is designed from the ground up to support modern development workflows. This architecture focuses on two primary goals:

1.  **Parallel Compilation:** Drastically reduce full build times by compiling independent modules simultaneously.
2.  **Incremental Compilation:** Recompile only the modules affected by code changes, making iterative development nearly instantaneous.

The foundation of this architecture is a **Hub-and-Spoke Model** where distinct services operate on a shared context for a given build.

*   **The Build Orchestrator:** The brain of the build system. It discovers modules, builds the dependency graph, manages the compilation cache, and coordinates the entire workflow.
*   **The Compilation Session:** A short-lived object representing the state of a single build run. It owns the root `ir.Context` and holds critical mapping data, such as which `ir.Context` corresponds to which `ModuleGUID`. This cleanly separates the persistent IR from transient, build-specific metadata.
*   **The Frontend Service:** A pure analysis service. Its job is to take source code, rehydrate dependency interfaces from the `CompilationSession`, and produce a semantic representation of a module's public interface and private implementation.
*   **The Backend Service:** A pure code generation service. Its job is to take the semantic representation from one or more modules and produce a final, executable artifact.

This separation is the key to unlocking parallelism and accurate incrementality, while also enabling other tools like Language Server Protocol (LSP) servers to reuse the frontend analysis without depending on the code generation backend.

### 1.2. The `CompilationSession`: A Context for a Single Build

To avoid polluting the core `ir.Context` with build-specific metadata, the `Orchestrator` creates a `CompilationSession` for each build. This object acts as the "short-term memory" for the build, providing the necessary context for services to interact.

```zig
// A conceptual representation.
const CompilationSession = struct {
    /// The single root IR context for this build. All child contexts for
    /// individual modules will be created under this root.
    root_context: *ir.Context,

    /// Maps a child context's ID to its module's GUID and other info.
    /// This is the key to resolving external references during dehydration.
    context_id_to_module: std.HashMap(ir.Context.Id, ModuleInfo, ...),

    /// A reverse map from an `ir.Ref` (pointing to an external symbol)
    /// back to its original module GUID and symbol name. Populated during
    /// dependency rehydration.
    ref_to_external_symbol: std.HashMap(ir.Ref, ExternalSymbolInfo, ...),

    // Other caches for this build run...
};
```

### 1.3. The Serializable Module Artifact (SMA)

The SMA is a binary file (`.sma`) produced by the `FrontendService`. It is a self-contained, cacheable representation of a **whole, fully analyzed module**.

The SMA contains two distinct sections:
*   **A Public Interface Section:** A dehydrated representation of the module's public API. This is what other modules compile against.
*   **A Private Implementation Section:** A dehydrated representation of the module's private implementation, including function bodies. This is what the `BackendService` uses to generate code for this specific module.

#### SMA File Format

*(Note: [`binary_format.md`](./binary_format.md) is the canonical definition for this table)*

| Offset | Field                 | Type           | Description                                                |
| :----- | :-------------------- | :------------- | :--------------------------------------------------------- |
| 0x00   | `magic_number`        | `[6]u8`        | The bytes `RIBSMA`.                                        |
| 0x06   | `format_version`      | `u16`          | The version of the SMA format.                             |
| 0x08   | `header`              | `SMA.Header`   | Metadata and offsets to other tables.                      |
| ...    | `string_table`        | `[]u8`         | Null-terminated UTF-8 strings.                             |
| ...    | `public_symbol_table` | `[]SMASymbol`  | Maps public symbol names to nodes.                         |
| ...    | `public_node_table`   | `[]SMANode`    | Dehydrated IR graph for the **public interface**.            |
| ...    | `private_node_table`  | `[]SMANode`    | Dehydrated IR graph for the **private implementation**.      |

### 1.4. The `interface_hash` and Canonical Binary Representation (CBR)

The `interface_hash` is the cornerstone of incremental compilation. It is a cryptographic fingerprint of the module's **public contract (API/ABI)**. To generate it, the `FrontendService` creates a temporary, in-memory **Canonical Binary Representation (CBR)** of the public interface.

The final `interface_hash` is a Merkle-style hash (BLAKE3) of the entire public API, making it compositional and deterministic.

**Canonicalization Rules:**
*   Public symbols are sorted alphabetically by name before the final hash is computed.
*   Struct fields are sorted alphabetically for packed layouts and by memory offset for C layouts.
*   Effect rows are sorted alphabetically by effect name.

### 1.5. The Incremental Build Workflow

The **Build Orchestrator** coordinates the entire process.

1.  **Trigger:** A file watcher reports a change to `module_b.ribbon`.
2.  **Orchestration Begins:**
    *   The `Orchestrator` creates a `CompilationSession` and a `DependencyGraph`.
    *   It performs dependency discovery (parsing only `import` statements) to build the graph.
    *   It uses **Tarjan's algorithm to find Strongly Connected Components (SCCs)**. This produces a topologically sorted list of *groups* of modules. Modules within a group (an SCC) have cyclic dependencies on each other. (e.g., `[ [utils], [module_a, module_b], [app] ]`).
3.  **Frontend Loop (SCC-based Analysis):**
    *   The orchestrator iterates through the sorted list of SCCs.
    *   For the `[utils]` SCC:
        *   The frontend service is called for `utils.ribbon`. It has no Ribbon dependencies. `utils.sma` is generated.
    *   For the `[module_a, module_b]` SCC:
        *   The frontend service is invoked for the entire group. It must analyze `module_a` and `module_b` in a way that allows them to resolve types from each other.
        *   This pass requires rehydrating the public interface of `utils` first.
        *   It produces `new_module_a.sma` and `new_module_b.sma`.
    *   For the `[app]` SCC:
        *   The frontend service analyzes `app.ribbon`.
        *   It first rehydrates the public interfaces from `module_a.sma` and `module_b.sma`.
        *   It produces `app.sma`.
4.  **The "Should I Recompile?" Check:**
    *   The orchestrator computes the `interface_hash` from the public part of `new_module_b.sma`.
    *   It compares this with the `interface_hash` from the cached `old_module_b.sma`.
5.  **Backend Scheduling (Parallel Code Generation):**
    *   **Case A: Hashes Match (No Public API Change).** Only `module_b` needs its code regenerated. A single backend job is scheduled: `backend.compile(module_b)`.
    *   **Case B: Hashes Differ (Public API Change).** The `DependencyGraph` is consulted for reverse dependencies (e.g., `app`). Parallel backend jobs are scheduled for `module_b` and `app`.

## Part 2: A Robust Hot-Reloading System

This system leverages the SMA architecture to implement safe and powerful hot-reloading. The core principle is: **State migration is a user-space, type-safe, and compositional process, orchestrated by the runtime as a handled effect.**

### 2.1. Version 0: Compile & Restart

The initial implementation will provide a rapid recompile-and-relaunch cycle.

1.  A file watcher triggers an incremental build via the orchestrator.
2.  Upon success, the orchestrator signals the running Ribbon application.
3.  The application's host logic cleanly tears down its state and re-initializes using the new code.

### 2.2. Version 1: Live State Migration

#### Compiler Responsibilities: Type Evolution and Safety

*   **The `Migratable` Type Class:** Users define migration logic via a standard type class.
    ```ribbon
    Migratable := class From, To.
        migrate: From -> To | { RemapAddress, Error String }
    ```
*   **The `RemapAddress` Effect:** This effect is handled by the runtime during a migration transaction to safely update pointers from old memory locations to new ones.
*   **The `Unsafe` Effect and Trust Boundary:** Migrating types that contain raw pointers or FFI resources implicitly adds an `Unsafe` effect. Only explicitly trusted modules can handle this effect, creating a clear safety boundary.

#### Runtime Responsibilities: State Tracking & Migration

*   **Migratable Allocators and RTTI:** Special allocators attach RTTI—specifically, the **`Type Version ID`** (the CBR hash of the type)—to memory blocks. This is a pay-for-what-you-use feature.
*   **The Migration Transaction:** Migration is an atomic, rollback-safe process.
    1.  The runtime pauses execution at a safe point (e.g., the top of the main loop).
    2.  It traverses the old state, allocating new memory and building an address-remapping table.
    3.  It iteratively calls the user-defined `migrate` functions, providing a handler for the `RemapAddress` effect.
    4.  If any migration fails, the transaction is aborted, new memory is freed, and execution resumes with the old state.
    5.  On success, the runtime atomically swaps the application's root pointers to the new state, frees the old memory, and resumes execution.

---

## Implementation Plan

This plan is structured as a series of **vertical slices**, ensuring that a functional (though incomplete) end-to-end pipeline exists at each major stage.

### Proposed Order of Implementation

1.  **Phase 1: Skeleton Infrastructure:** Establish the `Orchestrator` and `DependencyGraph` with the ability to determine a correct build order.
2.  **Phase 2: The "Single Dependency" Frontend Slice:** Implement the minimum viable `FrontendService` and `SMA` serialization/deserialization to compile a module that depends on another.
3.  **Phase 3: The Backend Slice:** Connect the `BackendService` to create a complete, albeit non-incremental, build pipeline.
4.  **Phase 4: Full Incrementality:** Implement CBR hashing and caching in the `Orchestrator`.
5.  **Phase 5 & 6: Hot-Reloading:** Implement the `V0` (fast restart) and `V1` (state migration) systems.

---

## Part 1: Implementing the Parallel and Incremental Compiler

### Phase 1: Skeleton Infrastructure

**Goal:** Create an orchestrator that can scan a root module, discover its dependencies, and print a correct topological build order.

*   **Task 1.1: Define Core Orchestrator Structures.**
    *   **Location:** New files, e.g., `src/mod/orchestration.zig`, `src/mod/orchestration/graph.zig`.
    *   **Details:**
        *   Define the `CompilationSession` struct. It will initially be simple, containing just the `root_context: *ir.Context`.
        *   Define a `DependencyGraph` that can store module paths and their direct dependencies.
        *   Define the main `BuildOrchestrator` struct.

*   **Task 1.2: Implement Dependency Discovery.**
    *   **Action:** Create a lightweight function in the `frontend` service, `discoverImports(path) -> ![]const []const u8`, that performs a minimal parse of a source file to extract only its `import` statements.
    *   **Action:** Implement the `BuildOrchestrator.buildDependencyGraph(root_module_path)` method. It will recursively call `discoverImports` to populate the `DependencyGraph`.

*   **Task 1.3: Implement Tarjan's Algorithm for SCCs.**
    *   **Action:** Implement a function that uses **Tarjan's algorithm** to find the strongly connected components (SCCs) of the `DependencyGraph`.
    *   **Details:** The function should produce an `ArrayList(ArrayList(ModuleGUID))`. Each inner list is an SCC, and the outer list is topologically sorted. This correctly handles module import cycles.

*   **Task 1.4: Implement the `main` Driver.**
    *   **Action:** In `src/bin/main.zig`, instantiate the `BuildOrchestrator`, call it on a test file, and print the resulting build order.
    *   **Verification:** This phase is complete when the driver correctly prints the build order in SCC groups, e.g., `[ ["path/to/dependency.ribbon"], ["path/to/main.ribbon", "path/to/utils.ribbon"] ]` for a project where `main` and `utils` import each other.

### Phase 2: The "Single Dependency" Frontend Slice

**Goal:** Compile a module (`app.ribbon`) that depends on another (`utils.ribbon`) by generating `utils.sma`, loading its public interface, and then generating `app.sma`.

*   **Task 2.1: Implement SMA Serialization ("Dehydration").**
    *   **Location:** `src/mod/sma.zig`.
    *   **Action:** Implement the `Dehydrator` logic as described in the architectural plan. Crucially, its `dehydrateChildRef` function will now expect to be passed a `*CompilationSession` to resolve external and builtin references.

*   **Task 2.2: Implement SMA Deserialization ("Rehydration").**
    *   **Location:** `src/mod/orchestration/rehydrator.zig` (new file).
    *   **Action:** Implement `rehydratePublicInterface(session: *CompilationSession, sma: *const sma.Artifact) !void`. This function will:
        1.  Create a new child `ir.Context` for the dependency module.
        2.  Populate it with `ir.Node`s by reading the SMA's public sections.
        3.  Update the `session`'s `context_id_to_module` and `ref_to_external_symbol` maps.

*   **Task 2.3: Integrate into `FrontendService` and `Orchestrator`.**
    *   **Action:** Modify the `FrontendService`'s main entry point to accept a `*CompilationSession`.
    *   **Action:** In the `BuildOrchestrator`'s build loop, for each module:
        1.  Load the SMAs of its direct dependencies (which have already been generated in previous loop iterations).
        2.  Call the `FrontendService`, passing the session and the loaded dependency SMAs.
        3.  The `FrontendService` will rehydrate the dependencies before analyzing the current module's source.
        4.  Save the generated SMA to a cache directory.

*   **Verification:** This phase is complete when the orchestrator can successfully generate valid `.sma` files for a project with at least one inter-module dependency.

### Phase 3: The Backend Slice

**Goal:** Create a complete, single-threaded build pipeline that can take a root module and produce a final, executable bytecode artifact.

*   **Task 3.1: Implement Full Module Rehydration.**
    *   **Location:** `src/mod/backend.zig`.
    *   **Action:** Implement `rehydrateFull(ctx: *ir.Context, sma: *const sma.Artifact)` which deserializes **both** the public and private sections of an SMA into an `ir.Context` for compilation.

*   **Task 3.2: Implement the `BackendService`.**
    *   **Action:** The `BackendService`'s main function will take a list of SMAs to link.
    *   **Details:** It will create a new `ir.Context`, rehydrate the public interfaces of all dependencies, then rehydrate the full content of the primary module, and finally run the IR-to-Bytecode lowering pass.

*   **Task 3.3: Connect `Orchestrator` to `BackendService`.**
    *   **Action:** After the frontend loop completes, the `Orchestrator` will schedule a backend job for the root module, passing it all necessary dependency SMAs.

*   **Verification:** This phase is complete when running the build driver on `app.ribbon` produces a single, valid, and executable bytecode file.

### Phase 4: Full Incrementality and Parallelism

**Goal:** Evolve the single-threaded pipeline into a fast, parallel, and truly incremental compiler.

*   **Task 4.1: Implement CBR Generation and Hashing.**
    *   **Location:** `src/mod/cbr.zig`.
    *   **Action:** Implement the `generateInterfaceHash` logic. This is a significant task requiring careful attention to canonicalization rules.

*   **Task 4.2: Implement Caching in the Orchestrator.**
    *   **Action:** The `Orchestrator` will now use the `interface_hash` to decide whether a module and its reverse dependencies need to be recompiled by the backend, as described in the architectural plan.

*   **Task 4.3: Implement Parallel Job Execution.**
    *   **Action:** Integrate a thread pool into the orchestrator. The backend scheduling logic will submit compilation jobs for all dirty modules to the pool and wait for them to complete.

## Part 2: Implementing the Robust Hot-Reloading System

This part builds upon the incremental compiler to provide live code updates.

### Phase 4: V0 - Fast Restart

This is the foundational, simpler version of hot-reloading.

*   **Task 4.1: Integrate a File Watcher.**
    *   **Action:** Use a cross-platform file watching library or Zig's standard library to monitor source files for changes.
    *   **Details:** When a change is detected, the watcher should invoke `orchestrator.buildModule`.

*   **Task 4.2: Implement Orchestrator-to-Runtime Signaling.**
    *   **Action:** Implement a simple compiler<->runtime communication mechanism.
    *   **Details:** A basic queue a good choice. After a successful build, the orchestrator writes a message to the queue.

*   **Task 4.3: Implement Host Application Restart Logic.**
    *   **Action:** The runtime will run a background thread to listen for messages from the compiler.
    *   **Details:** Upon receiving a signal, runtime triggers host shutdown and re-initialization sequence, loading the newly compiled artifacts.

### Phase 5: V1 - Live State Migration

This is the advanced, state-preserving version of hot-reloading.

*   **Task 5.1: Compiler and Language Support.**
    *   **Action:** Implement the `Migratable` type class and `Unsafe` effect.
    *   **Details:**
        1.  In the `frontend` service, add the `Migratable` class to the prelude as a known built-in. Its definition is `class From, To. migrate: (From) -> To | { RemapAddress, Error String }`.
        2.  During semantic analysis, implicitly add the `Unsafe` effect to any function that performs an FFI call.
        3.  Add logic for `derive(Migratable)`. For a struct change that only adds new fields with default values, the compiler can generate a `migrate` function automatically.

*   **Task 5.2: Runtime State Tracking.**
    *   **Action:** Implement the `MigratableAllocator` and the host registration API.
    *   **Details:**
        1.  Create a new allocator in `core.zig` that wraps a standard allocator. `alloc` will prepend a small header to each allocation containing the `Type Version ID` (the CBR hash of the type).
        2.  Expose an FFI-safe API from the runtime, e.g., `ribbon_register_root(*core.Fiber, core.Value)` and `ribbon_unregister_root(*core.Fiber, core.Value)`. This allows the host to inform the Ribbon runtime about Ribbon objects it owns.

*   **Task 5.3: Implement the Migration Transaction.**
    *   **Action:** Implement the core migration logic in the runtime/interpreter.
    *   **Details:** This is the most complex part.
        1.  **Sync Point:** Implement the `hotReloadSyncPoint` effect. The application's main loop will handle this. When a reload is pending, this handler will not return immediately.
        2.  **Handshake Logic:** Inside the `hotReloadSyncPoint` handler, implement the "stop-the-world" check. Iterate through all threads and inspect their `core.CallStack`. If any `CallFrame` references a function from a module being reloaded, abort the migration and fall back to a fast restart.
        3.  **Phase 1 (Allocation & Mapping):** If the handshake succeeds, begin the transaction. Traverse all registered roots (globals, host roots, migratable allocators). For each old object, allocate a corresponding new object (of the new type version) and store the mapping `(old_address -> new_address)` in a temporary hash map.
        4.  **Phase 2 (Migration):** Traverse the old state again. For each object, find its `Migratable` implementation and call the `migrate` function.
        5.  **`RemapAddress` Effect:** Provide a runtime handler for the `RemapAddress` effect. When prompted, this handler will look up the old address in the temporary map and return the new address, allowing the user's `migrate` function to patch pointers correctly.
        6.  **Commit/Rollback:** If all `migrate` calls succeed, atomically update the root pointers to point to the new state and free the old memory. If any call fails, abort the transaction by freeing all *newly allocated* memory and resuming execution with the old state.