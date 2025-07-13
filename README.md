<div align="center">
  <img style="height: 18em"
       alt="Ribbon Language Poster"
       src="https://ribbon-lang.com/images/ribbon-language-poster.png"
       />
</div>

<div align="right">
  <h1>Ribbon</h1>
  <h3>The Ribbon Programming Language</h3>
  <sup><code>main</code> development branch</sup>
</div>

---

<div align="center"><br>

  [Website](https://ribbon-lang.com/) •
  [Design Docs](https://design.ribbon-lang.com/) •
  [Discord](https://discord.gg/3FWqmJQAEQ) •
  [Sponsor](https://github.com/sponsors/tiny-bow)

</div>

---


This is the primary repo for the [Ribbon Programming Language](https://ribbon-lang.com/) toolchain. The repo contains the bytecode vm, intermediate representation, compiler, frontend, and other core components. This is a community-focused, [Apache 2.0 Licensed](./LICENSE) open-source project. It is under the stewardship of [Tiny Bow](https://tinybow.org), a nonprofit organization founded with the primary goal of supporting open-source, extensible software within the Ribbon ecosystem.

We're building Ribbon to be a new home for:
* Systems programmers who want modern type safety.
* Language designers looking for a powerful meta-programming toolkit.
* Game developers and others needing predictable, realtime performance in their modding and scripting systems.

To serve these creators, Ribbon provides:
* **Fine-grained Performance:** Zero GC, composable tracked allocation, and tracked thread affinity.
* **Deep Extensibility:** LISP-inspired toolkit for creating domain-specific solutions.
* **Modern Type Systems:** Strong static typing with full inference for safety and flexibility.

Ribbon is an embeddable programming language, designed to resolve the long-standing tension between high-level developer experience and low-level systems access. It combines influences from the latest in academic research and industry practice to offer performance without sacrificing usability. It is designed for building and extending realtime applications like games and data analytics tools, as well as providing a language-design toolkit for DSLs and academic pursuits.

We are in a focused development phase, with a `0.1.0` release targeted for **Q4 2025**. This first major release will deliver a feature-complete bytecode compiler and interpreter. This will establish the foundational baseline for building the Ribbon ecosystem. From this point forward, API stability as well as the JIT and native backends will become the primary focal points of compiler development. This will allow development of the standard library to begin in earnest and enable the community to create the first experimental applications.



### Contents

* [What is Ribbon?](#what-is-ribbon)
    * [Side Effect Tracking](#side-effect-tracking)
    * [Structural Polymorphism](#structural-polymorphism)
    * [Layout Polymorphism](#layout-polymorphism)
    * [Type Classes](#type-classes)
    * [Phantom Types](#phantom-types)
    * [Dynamic Meta-Language](#dynamic-meta-language)
    * [Object Notation Language](#object-notation-language)
* [Building from Source](#building-from-source)
    * [Notes](#notes)
* [Source Overview](#source-overview)
    * [Generated Files](#generated-files)
* [Contributing](#contributing)
    * [Discussion](#discussion)
    * [Design](#design)
    * [Issues](#issues)
    * [Pull Requests](#pull-requests)
    * [Sponsorship](#sponsorship)



### What is Ribbon?

A core tenet of Ribbon's design philosophy is the notion that *syntax is secondary*. For the majority of Ribbon's development thus far, we have therefore focused on semantics. However, some of the syntax of our base languages is ready to show, and we present a few simple examples here to demonstrate Ribbon's capabilities. We ask that you keep in mind details are subject to change, and focus on the design of the developer experience.

If any of the following is confusing, it may help to refer to the [Design Documentation](https://design.ribbon-lang.com), for example the [Grammar](https://design.ribbon-lang.com/Grammar) may be of particular use in mentally parsing the examples.

<sup><em>If those don't help either, please <a href="#discussion">let us know</a>.</em></sup>


#### Side Effect Tracking

Ribbon offers one of the first production-focused implementations of some new developments in language design academia, pioneered most notably in the modern era by the Koka research language: algebraic effects. In short, we allow function types to be annotated with the side effects they perform. Not only that, due to recent advancements in type inference we can do this automatically wherever you choose. Finally, we hook into these new type-level semantics to allow you to dynamically insert handler functions for these side effects, without destroying performance.

First, we define an effect definition:
```ribbon
Exception := effect E.
    throw : E -> !
```

_Note: The `!` here indicates the "bottom type," representing terminated control flow; for example the result type of functions that never return. The use of this type in the effect signature indicates that handlers are expected to always cancel the computation, rather than return control flow to the caller._

Then, we can use it anywhere in a function:
```ribbon
import Exception/throw

my-failable-function := fun a, b.
    match b.
        0 => throw 'DivisionByZero
        _ => a / b
```
_Note: The prefix single-quote `'` syntax here represents a symbol literal; if you are unfamiliar with LISP and the like, the values of Symbol types are globally-memoized static pointers to the name after the quote. Comparing two symbols is therefore quite cheap and serves a simple and consistent way to encode basic identification._

The compiler can then infer that `my-failable-function` has the side effect type `Exception Symbol` among its *effect row*:
```ribbon
my-failable-function : forall n. (n, n) -> n | { Exception Symbol } = ...
```

Let's break down this signature. In Ribbon, the function arrow `->` is best understood as a *mixfix* type constructor that describes not just inputs and an output, but also the effects a function may perform. The general form is:
```ribbon
(Inputs...) -> Output | Effects
```

The `|` symbol is *not* a standalone operator; it's a delimiter within the `->` constructor that introduces the optional effects component of a function type. The expression following it can be any type that specifies an *effect row*: a type-level list of effects. This allows the type system to track effects with the same precision it tracks data. Because of Ribbon's focus on inference, you do not have to write these signatures yourself in most cases. Additionally, in situations where you do want to be explicit, you can simply specify the rest of the type yourself and write `_` for the effect row, or a part of it, indicating that *only that part* should be inferred.

Now, we can *handle* this side effect in any function, and if `my-failable-function` is used in our "handler block" (including via indirect calls), our handler will be invoked as the definition of `throw`:
```ribbon
import std/io/Console

main := fun ().
    with handler Exception Symbol.
        throw sym =>
            Console/log "Exception occurred: " sym
            cancel 1
    do
        my-failable-function 2 0

        0
```

Tracing the execution of `main`:
1. We add an effect handler for `Exception Symbol` to the dynamic environment. This registers a special function for the `Exception/throw` effect that, when invoked, performs a `Console/log` effect, which entry points like `main` have access to. It also utilizes the `cancel` operation, with a value of `1`. This is similar to `return` or more accurately, labeled `break`s found in other languages.
2. We execute the `do` block in this extended dynamic environment.
3. We call `my-failable-function` with two arguments in an invalid combination.
4. `my-failable-function` performs its check, `throw`s a symbol representing the error, and the throw is intercepted by our handler.
5. Handling begins, prompting `Console/log` in the pre-existing dynamic environment.
6. After the `Console/log` effect resolves, the handler proceeds to its next operation: `cancel`. This immediately terminates the execution of the `do` block, making `1` the resulting value of the entire `with handler ... do ...` expression.
7. Outside our effect handler block, `1` is returned as `main`'s exit code, as the handler block and its nested `do` are a trailing expression in `main`'s body.
8. Note that execution never reached the trailing expression `0`, it is not evaluated.

We have focused a lot on the type inference in Ribbon, dedicating a lot of research into the concept of *full inference*. If you've studied the field, you'll know that true full inference is a logical impossibility, but we have focused on making what is theoretically inferrable always inferred when you want it to be. The simple signature `(n, n) -> n` is a good starting point, but it doesn't tell the whole story. For example, how does the compiler know that `n` needs to support division? To answer questions like that, we need to introduce other foundational elements.


#### Structural Polymorphism

In extensible systems, a common problem is multiple sources defining "the same" data type. This isn't limited to extensible systems though, as shown by the following example:
```ribbon
Vector2 := struct { x: f32, y: f32 }
Point2 := struct { x: f32, y: f32 }
```
Ribbon has a *nominative type system*, meaning the name given to a type such as a `struct` at its definition is a core part of its identity. In such systems, these two types are incompatible. If we want a single function to get the magnitude of both types, many languages leave us with only macros and templates to solve the problem. Some languages offer interfaces, Rust and Haskell offer [traits/type classes](#type-classes) to set bounds, but neither of these yet has a simple method to talk about the structural qualities of the types; we are left to binding accessor methods.

Utilizing the same underlying typing mechanics as our effects system, we can also provide a powerful and flexible approach to this problem: structural polymorphism. This complements [classes](#type-classes) a great deal, providing a providing a complementary axis of type description: the shape and attributes of types.

This signature does not describe a single type, it describes a family of functions operating on multiple types of structured data:
```ribbon
magnitude2 : {x: any n, y: n, ..} -> n
```

The syntax `any n` here simply creates a quantifier (type variable name) inline. The more interesting syntax is `{..}`. A partially-elaborated form of this type is as follows:
```ribbon
magnitude2 : forall n: type, s: type, r: row data where {x: n, y: n} <> r ~ layout_of s. s -> n
```

In short, this allows the `magnitude2` function to work on *any* `struct`s as long as they have `x` and `y` fields of the same numeric type.

##### Elaboration Details

1. **`forall n: type, s: type, r: row data`**

    This quantifier declares three generic placeholders: `n` for an arbitrary type, `s` for our nominative (named) type like `Point2`, and `r` for a `row` of `data`: a type-level description of a struct's fields. This `r` is how we allow types with *more* fields than just `x` and `y`.

2. **`where {x: n, y: n} <> r ~ layout_of s`**

    This qualifier declares the core constraint. It reads as:
    * Given our quantified variables, ...
    * ...the layout (fields) of our type `s`...
    * ...must be equivalent (`~`) to a structure containing `{x: n, y: n}`...
    * ...concatenated (`<>`) with any other remaining fields (`r`).

3. **`s -> n`**

    The final function signature shows that it still operates on the original *named type* `s`. This is key, because it means we get the benefits of structural checking for functions like these; while remaining within our nominative type system, which works better for the following feature. It is also the key to how the compiler performs this elaboration: since the function type constructor `->` itself can be thought of as being bounded `Input: type, Output: type, Effect: row effect`, when we spot it applied to `row data`, we can easily lift out the rows into these and other constraints.


#### Layout Polymorphism

Structural polymorphism gives us high-level abstractions over the shape of our data. But for a systems language, that is only half the story. To achieve maximum performance and seamless C interoperability, control over the precise *memory layout* of data is paramount. Ribbon surfaces this critical dimension of data design directly into the type system.

The key is a simple but powerful concept: In Ribbon, fields have both a logical identifier (Name) and a physical position in memory (Layout). You can specify either or both explicitly.

At the term level:
* When you write `{ x: f32, y: f32 }`, you are only specifying the `Name`s. The compiler assigns a default, packed `Layout` for you automatically.
* When you write `(f32, f32)`, this is syntactic sugar for a struct where you only specify the `Layout`s. It desugars to something like `{@0: f32, @4: f32}`.

This unified model allows you to take full manual control when performance or FFI demands it, defining data structures with a fixed, C-compatible memory layout:

```ribbon
;; A struct with a precise, C-compatible memory layout
C_UserData := struct {
    id     @ 0 : u64,
    status @ 8 : u8,
    -- 3 bytes of implicit padding --
    score  @ 12: f32,
}
```

This duality unlocks two distinct and powerful forms of polymorphism, allowing functions to be generic over either a field's name or its physical layout:

```ribbon
;; 1. Polymorphism by Name:
;; This function works on any struct with a 'score' field of type f32,
;; regardless of its memory offset.
get_score := fun(p: {score: f32, ..}) -> f32.
    p.score

;; 2. Polymorphism by Layout:
;; This function works on any struct with a u8 at memory offset 8,
;; regardless of its name.
get_status_byte := fun(p: {@8: u8, ..}) -> u8.
    p@8
```

To ensure this system is robust and predictable, a few simple rules apply:
* **Uniqueness:** Within a single struct, all field names must be unique, and all field offsets must also be unique. This constraint is essential for making type inference tractable and predictable.
* **No Overlapping:** Field layouts may not overlap. For cases requiring overlapping data, like C-style unions, Ribbon provides a dedicated `union` utilizing this same label system. Bit-level layouts can be achieved with Ribbon's explicit-width integer types.

This system provides a unique combination of control and abstraction, with far-reaching benefits:
* **Unambiguous C Interop:** Create and consume C structs with guaranteed ABI compatibility.
* **Systems Design Patterns:** Implement concepts like custom object headers or v-tables by reserving specific memory offsets for metadata or function pointers.
* **Powerful Abstractions:** The `(Name, Layout)` foundation transparently unifies tuples and structs and is the basis for features like named vs. positional function arguments.


#### Type Classes

_Note: This is **not** the same as object-oriented classes/inheritance, it is a **compositional** system rather than an **extensional** one._

Now we can address our incomplete signatures for arithmetic functions. Like Rust and Haskell, Ribbon uses type classes to describe abstract capabilities. However, Ribbon takes a different approach to how implementations (or instances) are managed. Instead of a single global set of instances, Ribbon adopts a model similar to PureScript, where instances are lexically scoped.

This design directly solves the "orphan rule" problem and gives you, the programmer, complete and predictable control. It means you can:
* Define any instance for any type, without restriction.
* Use multiple, competing instances for the same type within different parts of your program.
* Explicitly choose which implementation to use by bringing it into scope, just like a normal variable.

This isn't an arbitrary choice; it's a core part of Ribbon's philosophy. The mechanism for providing a type class instance is intentionally parallel to handling a side effect. Both systems are about providing a concrete implementation for an abstract interface within a specific scope.

This class specifies the behavior of addition across all scopes that utilize it:
```ribbon
Add := class A, B=A.
    C : Type = A
    infixl 50 + : (A, B) -> C
```
Using this definition, we can craft an implementation:
```ribbon
import std/ops/Add

add_i32 := impl Add i32.
    `+` = std/intrinsics/i32/add
```
We can utilize definitions to craft functions without any knowledge of implementations:
```ribbon
import std/ops/Add

incr := fun x.
    x + 1
```
The inferred type of `incr` will be something like:
```ribbon
incr : forall X where Add X X, FromInteger X. (X, X) -> (Add X X).C
```
_Note: The `(Add X X).C` return type refers to the associated type `C` from the `Add` type class, which specifies the result type of the addition._

And we can utilize specific implementations to *eliminate* these constraints from our functions in a similar way as side effects:
```ribbon
incr := fun x.
    with impl std/ops/Add = add_i32
    
    x + 1
```


#### Phantom Types

Phantom types in Ribbon are no different than in languages like Rust and Haskell; however, we combine them with the above features to provide novel safety and abstraction mechanisms.

Pointer types in Ribbon are arity-2 infix constructors:
```ribbon
my_i32_pointer: 'static * i32 = &some_constant
```
There's also a prefix syntax, `* i32`, that simply infers the symbolic parameter.

The extra parameter here is *conceptually similar* to reference lifetimes in Rust, but implemented differently and utilized in a new way: We combine this with our algebraic effects system, and combine both with our memory management solution.

Whenever you perform a read or write on any pointer, this attaches a side effect type to the function. This side effect is similarly annotated with the same symbolic parameter as the pointer, letting us know which memory the function is accessing, and whether it is reading or writing to it. Similarly, allocators can provide pointers to callers with these annotations, and simple analysis can annotate constants and stack values appropriately, closing the loop.

Similarly, we can encode thread affinity by attaching symbolic effect types that are only handled by thread executor functions.

In addition to powerful user-level features like low-overhead custom address spaces, execution scope control, etc; this adds a high degree of safety through its simple declaration and enforcement by the type system. Furthermore, the Ribbon runtime can retain awareness of these bounds, restrict the mutation of pointers, and present a fairly robust sandbox for compiled code without runtime overhead. Our goal is to utilize this to enable a *zero data marshalling* embedding workflow for Ribbon.


#### Dynamic Meta-Language

The systems described so far detail the *typed language* offered by Ribbon; which is itself a construct of an underlying system. We call this underlying system "RML," the Ribbon meta-language. This is a high-level, dynamically typed language running on the same principles as the rest of the pipeline: high performance, easy interop, excellent control. We utilize session based arena memory management to support the object model, sticking to our Zero-GC principle.

The meta-language is designed for a singular purpose: formal language processing with embedded content. While not an S-Expression language, its homoiconicity is a big inspiration and concrete syntax trees are a first-class variant of the object type. Quasiquotes are also a fundamental component. Both of these are allowed in both the term and pattern-matching grammars to enable powerful functional macros.

This language is meant to serve as the glue between the Ribbon typed language and DSLs created by users, as well as the foundational method of creating them.

##### Example

All definitions in the Ribbon meta-language share a common dynamic type, `meta_language/Value`, since RML itself is dynamically typed. The following would ***not*** be allowed:
```ribbon
;; invalid RML
x : i32 = ..
```
However, we can still write functions rather normally:
```ribbon
square := fun x. x * x
```
It is not necessary to declare effects, they all have the same type:
```ribbon
my-failable-function := fun a, b.
    match b.
        0 => prompt throw 'DivisionByZero
        _ => a / b
```
This same definition from before, with the small addition of the `prompt` keyword, is still understood by the RML frontend. It understands it in a slightly different manner however, adapted to the dynamically typed environment.

`prompt throw 'DivisionByZero` is instead essentially equivalent to the following:
```ribbon
meta_language/UserEffect.prompt 'throw ('DivisionByZero, )
```
The specific user-defined effect being performed is always a monomorphic `UserEffect`: `prompt : Value -> Value -> Value`.

The meta-language has an additional keyword `fetch`, which is similar to `prompt`, but simply gets a copy of the `Value` bound in the dynamic environment rather than invoking it.


#### Object Notation Language

A stripped-down version of RML is also in the works, focused purely on data specification. This allows you to define static data, such as configuration files, themes, or asset definitions, using the same familiar syntax you use everywhere else in the ecosystem.

It's designed to reduce cognitive overhead by eliminating the need to switch contexts to a separate format like JSON or YAML for simple data interchange, and to support robust conversion to and from other formats using the existing toolchain.

##### Example

```ribbon
;; game-settings.ro (Ribbon Object)
{
  window_title = "My Awesome Game",
  resolution = (width: 1920, height: 1080),
  graphics = (vsync: true, quality: 'ultra),
}
```



### Building from Source

We have aspirations toward self-hosting Ribbon eventually, but in this early phase, our host language of choice is [Zig](https://ziglang.org).

Zig handles the dependency management. Simply cloning the repository and running `zig build` will fetch the dependencies.
> Note: the fetch is currently not handled by the nix flake, it is expecting to be run with `direnv`/`nix develop` for now, giving it http access.

Running `zig build --help` will give an overview of the build api. Alternatively, [tasks.json](./.vscode/tasks.json) provides a good overview, even if you are not using VS Code.

The driver (`zig build run`) as of now just parses code and prints the AST back to you, as current development is focused on the IR and backend.


#### Notes

* We are currently pinned to Zig version `0.14.1`.
* 32-bit architectures are not currently planned to be supported.
* Big-endian architectures are untested.
* ARM architectures are untested.
* Windows has had minimal testing.
* Confirmed working on Debian-based systems. (Ubuntu 22 & 24)
* Primary development environment is currently:
    * `NixOS` `25.05`
        > A basic Nix Flake setting up a Zig development environment is [included in the repository](./flake.nix).
        >
        > The environment is also configured for use with [`direnv`](./envrc).
    * `AMD` `x64`
        > Specifically, the primary testing machine utilizes a `Ryzen 5 2600` from the `Zen+` family.
* If you're not using the Nix Flake, [zvm](https://www.zvm.app/) or [zigup](https://marler8997.github.io/zigup/) may be useful.



### Source Overview

* [Core Internals (Fiber, etc)](./src/mod/core.zig) - Defines the Ribbon runtime core; the vm execution fiber, the bytecode definition structure, etc.
* [Bytecode Utilities](./src/mod/bytecode.zig) - Disassembler, higher level utilities for working with bytecodes.
* [Lexical & Syntactic Utilities](./src/mod/source.zig) - Source tracking structures, abstract lexer and parser.
* [Core X64 Target Abstractions](./src/mod/x64/) - Basic ABI abstraction and machine code assembly API.
* [Instruction Specification Architecture](./src/gen-base/zig/isa.zig) - Specifies the bytecode instruction encoding using comptime-accessible Zig data. Source of truth for generated files.
* [Reference Bytecode Interpreter](./src/mod/interpreter.zig) - The Zig-language implementation of the bytecode interpretation logic and minimal API.
* [SoN/SSA Hybrid Intermediate Representation](./src/mod/ir.zig) - Ribbon's backend IR; a graph-based representation of source code already semantically analyzed by frontends.
* [Backend & Bytecode Target](./src/mod/backend.zig) - Handles the conversion from the IR to bytecode and other backend tasks.
* [Meta-Language Frontend](./src/mod/meta_language.zig) - Meta-language specific parser, analysis, and data types.
* [Build-time Zig, ASM & Markdown Codegen Facilities](./src/bin/tools/gen.zig) - Uses [`isa.zig`](./src/gen-base/zig/isa.zig) to generate various source files for the Ribbon toolchain & documentation.
* [Driver Stub](./src/bin/main.zig) - Work-in-progress. A REPL interface is available (though the 'E' for 'Eval' is still on the way!).


#### Generated Files

These files are generated and cached by the build system and are not under source control in this repo.

* `Isa.md` - The full specification for the Ribbon Instruction Set Architecture (ISA). This document provides a comprehensive guide to every opcode, its encoding, and its operational semantics.

    It is exported into the design documentation: 
    [Rendered](https://design.ribbon-lang.com/Bytecode-VM/Isa),
    [Source](https://github.com/tiny-bow/language-design/doc/Bytecode%20VM/Isa.md).

* `Instruction.zig` - The generated Zig API for working with Ribbon's bytecode. It defines the core opcode `enum`, types encoding the shape of every instruction's operand payload, and other data structures used by the compiler, VM, and disassembler.

    To view it, first run `zig build dump-intermediates` to create the file; it will then be located at `./zig-out/tmp/Instruction.zig`.



### Contributing

Ribbon is built by and for its community, and every contribution is vital. Whether you contribute ideas, bug reports, code, or funding, you are helping us build a future where robust, joyful software creation is open to all. Join us in shaping Ribbon together!


#### Discussion

We highly encourage everyone with an interest in Ribbon to hop on the [Tiny Bow Community Discord](https://discord.gg/3FWqmJQAEQ). Freeform discussion there can help coordinate our efforts and ensure contributors’ time is well spent, for example by surfacing ongoing work or existing issues before you invest significant effort. It's also the best place to start if you want to help bikeshed language concepts.


#### Design

Before contributing, it can definitely be helpful to check out the [Design Documentation](https://design.ribbon-lang.com/). It's currently a work in progress as well, but the high-level overview it provides is a good tool to have.

The source is also on GitHub at [/tiny-bow/language-design](https://github.com/tiny-bow/language-design) and in the [mono-repo](https://github.com/tiny-bow/mono-repo). As mentioned above, the design document is another big vector for contributors right now. Any design-related proposals (language features, syntax changes etc) should be filed at the [language-design](https://github.com/tiny-bow/language-design) repo as well.

**Please note:** Any issues or PRs that propose or implement changes in designed features without documented precedent as outlined above must be rejected.


#### Issues

Please keep in mind that the project is still in its early stages. If you encounter issues such as "The REPL doesn't evaluate the code," please note that certain features, like the pipeline from REPL to evaluator, are not yet fully implemented. We appreciate your understanding and encourage reporting issues that provide actionable feedback for the current stage of development.

While we do not yet have an issue template, issues filed should generally fall into a few categories:

1. **Tracking for PRs**
    
    Issues that track the implementation of features or improvements.
    
    > **Example:** Noting and discussing efforts toward implementing a designed feature that is not yet present.

2. **Uncaught Logical Errors**
    
    Issues that document logical errors in the implementation.
    
    > **Example:** Describing a scenario where a core toolchain function produces an incorrect result under certain conditions.

3. **Implementation-Specific Proposals**
    
    Proposals that do not change the language, but change how the language is implemented.
    
    > **Example:** Detailing and discussing the possible replacement of an algorithm used for a specific compiler pass.


#### Pull Requests

Before submitting large or feature-implementation pull requests, we strongly encourage you to start a conversation; either on our [Community Discord](https://discord.gg/3FWqmJQAEQ) or by opening an issue. This helps ensure your efforts align with ongoing development and design goals, and can save time by surfacing potential blockers or duplicate work early. Open communication also helps us provide guidance, context, and feedback to make your contribution as impactful as possible.

Small fixes and patch PRs (such as typo corrections, documentation improvements, or minor bug fixes) are always welcome; feel free to submit these at any time without prior discussion.


#### Sponsorship

If you share our vision for a new era of extensible, high-performance software, consider supporting Ribbon through [GitHub Sponsors](https://github.com/sponsors/tiny-bow). Your sponsorship directly fuels our mission to build Ribbon as an open-source language and realtime software engine; combining performance, safety, and deep extensibility for creators, game developers, and platform builders. Financial support directly contributes to the community in establishing and maintaining our non-profit foundation, providing essential community infrastructure, and dedicating focused lead-developer time, as well as in the creation of accessible learning resources.
