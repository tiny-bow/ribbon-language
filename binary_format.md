## Ribbon Serializable Module Artifact (SMA) and Canonical Binary Representation (CBR) Specification

### 1. Introduction

This document specifies two critical components of the Ribbon compiler architecture:

1.  The **Serializable Module Artifact (SMA)**: The on-disk, cacheable binary format that represents a module's public
    interface and dependencies.
2.  The **Canonical Binary Representation (CBR)**: An in-memory, deterministic data structure derived from a module's
    public interface, used exclusively for generating a cryptographic hash (`interface_hash`) that uniquely and
    verifiably identifies that interface.

These components are the foundation for the compiler's primary goals of **parallel compilation**, **deeply incremental
builds**, and the **safe, type-aware hot-reloading system**.

---

### 2. Serializable Module Artifact (SMA) Specification

The SMA is a binary file (e.g., `.sma`) produced by the `FrontendService`. It contains all information necessary for
another module to compile against it without needing access to its source code.

#### 2.1. File Format

An SMA file is a contiguous binary blob with the following top-level structure:

| Offset | Field                | Type          | Description                                                    |
| :----- | :------------------- | :------------ | :------------------------------------------------------------- |
| 0x00   | `magic_number`       | `[6]u8`       | The bytes `RIBSMA`.                                            |
| 0x06   | `format_version`     | `u16`         | The version of the SMA format itself (e.g., `1`).              |
| 0x08   | `header`             | `SMA.Header`  | Metadata about the module and offsets to other tables.         |
| ...    | `string_table`       | `[]u8`        | Contiguous block of null-terminated UTF-8 strings.             |
| ...    | `public_symbol_table`| `[]SMASymbol` | Table mapping public symbol names to IR nodes.                 |
| ...    | `node_table`         | `[]SMANode`   | Flattened, serializable representation of the public IR graph. |

#### 2.2. Detailed Structures

##### `SMA.Header`

| Field                 | Type           | Description                                                                                                   |
| :-------------------- | :------------- | :------------------------------------------------------------------------------------------------------------ |
| `ribbon_version`      | `u64`          | The `major.minor.patch` of the Ribbon compiler that generated this artifact, packed into a `u64`.             |
| `module_guid`         | `ir.ModuleGUID`| A `u128` cryptographic hash of the canonical module path/name (e.g., `hash("my_project/utils/collections")`). |
| `interface_hash`      | `u128`         | A cryptographic hash of the module's public interface, derived from its CBR. See Section 3.                   |
| `string_table_offset` | `u32`          | Byte offset from the start of the file to the `string_table`.                                                 |
| `string_table_len`    | `u32`          | Length of the `string_table` in bytes.                                                                        |
| `symbol_table_offset` | `u32`          | Byte offset to the `public_symbol_table`.                                                                     |
| `symbol_table_len`    | `u32`          | Number of entries in the `public_symbol_table`.                                                               |
| `node_table_offset`   | `u32`          | Byte offset to the `node_table`.                                                                              |
| `node_table_len`      | `u32`          | Number of entries in the `node_table`.                                                                        |

##### `Public Symbol Table Entry (`SMASymbol`)`

A simple mapping used to find the entry point for a public symbol in the `node_table`.

| Field             | Type  | Description                                                |
| :---------------- | :---- | :--------------------------------------------------------- |
| `name_idx`        | `u32` | Index into the `string_table` for the symbol's name.       |
| `root_node_idx`   | `u32` | Index into the `node_table` for the symbol's root IR node. |

---

### 3. Canonical Binary Representation (CBR) Specification

The CBR is an **in-memory-only** data structure created by the `FrontendService`. Its sole purpose is to serve as a
deterministic, canonical input to a cryptographic hash function to produce the `interface_hash`. It represents the
**public contract** of a symbol, stripped of all implementation details.

#### 3.1. Core Principle: Canonicalization

All lists within CBR structures **must be sorted** before hashing to ensure determinism.

*   Symbol names, effect names, and type class names are sorted alphabetically.
*   Struct fields are sorted alphabetically by name for `packed` structs, and by memory offset for `C`-layout structs.

---

### 4. The `interface_hash` Algorithm

The `interface_hash` is computed by the `FrontendService` after a full semantic analysis of a module.

1.  **Identify Public Symbols:** The service identifies all top-level symbols marked as public. This includes functions, structs, enums, etc.
2.  **Generate CBR for Each Symbol:** For each public symbol's `ir.Ref`, the service recursively builds its corresponding `CbrNode` tree.
    *   This process must correctly handle private types exposed in public signatures by fully including their structure in the CBR.
    *   All canonicalization (sorting) rules are applied during this step.
3.  **Hash Each CBR Tree:** A function, `hashCbr(CbrNode) -> u128`, performs a Merkle-style hash on each `CbrNode` tree.
    *   The hashing starts from the leaves (e.g., primitive types, which have well-known constant hashes) and works its way up.
    *   The hash algorithm shall be **BLAKE3** for its performance and cryptographic properties.
4.  **Assemble Final Symbol List:** Create a list of pairs: `(symbol_name: []const u8, symbol_cbr_hash: u128)`.
5.  **Canonical Sort of Public Symbols:** Sort this list alphabetically by `symbol_name`. This is the final and most
    critical canonicalization step, ensuring that the order of declaration in the source file does not affect the final
    hash.
6.  **Compute Final Hash:** Concatenate only the `u128` hashes from the sorted list into a single byte buffer and
    compute the final BLAKE3 hash of this buffer. This result is the module's `interface_hash`.

---

### 5. Considerations

This section documents further details and potential extensions based on the architectural plan.

*   **Macro Dependencies:** The `interface_hash` of a module **A** that uses a public macro from module **B** must
    incorporate the `interface_hash` of module **B**'s macro definitions. The `FrontendService` must therefore have
    access to dependency SMAs to expand macros correctly, and the `Build Orchestrator` must track these transitive
    dependencies.
*   **Stable ABI and Symbol Renaming:** The default behavior is that renaming a public symbol is a breaking change. For
    libraries requiring an ultra-stable ABI, a future extension could introduce an annotation like
    `@abiName("stable_name")` or `@abiGUID("...")`. The CBR generation would use this stable identifier instead of the
    source symbol name for hashing and for `external` `sma.Ref` lookups.
*   **Type Version ID for Hot-Reloading:** The **`Type Version ID`** required by the runtime's `MigratableAllocator` is
    simply the `u128` CBR hash of that specific type's `CbrNode`. This value is already computed during the
    `interface_hash` generation and can be stored in the final artifact's metadata.