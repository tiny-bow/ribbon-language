<!-- This file is only a template for `bin/tools/gen-isa`;
    See `~/Isa.zig` for the full document; `gen-isa.zig/#generateMarkdown` for the generator -->


This is an instruction set architecture (ISA) for the Ribbon bytecode.

The Ribbon bytecode is a low-level register based bytecode,
with support for arbitrary effect handlers. For more information on
implementation details of the Ribbon virtual machine see `core`, `bytecode`, etc.

## Syntax

### Basic layout
The ISA is divided into *Categories*;

*Categories* are further divided into *Mnemonic* bases;

*Mnemonics* then contain tables describing each concrete instruction variation.

#### Example
`callc` and `call_v` are both under the `call` mnemonic, within the `Control Flow` category.

### JIT-only Instructions
Instructions with a *jit* tag above their name are
only available when `Rvm` is compiled with the `jit` option.

#### Example
`call_foreign` is a jit-only instruction because it requires moving values
into hardware registers defined by the C ABI.

### Constant Operands
Some instructions take constant operands;
where these instructions are commutative,
the version of the instruction taking a constant
will be suffixed with `c`.

For instructions that do not commute, the two constant
versions will be suffixed with `a` and `b` respectively,
indicating whether the constant is used on the left or right side.

Additionally, some instructions have a variant that can take up to two constants,
and these are suffixed with `a`, `b`, *and* `c`. In this case the `a` and `b` are as usual,
and `c` is the version that takes two constants.

#### Example
The `mem_set` mnemonic has 4 instructions, the selection of which depends on which operands are constant:
| Instruction | Description |
|-|-|
| `mem_set` | ... address in `Rx`, up to an offset of `Rz` ... set to ... `Ry` |
| `mem_set_a` | ... address in `Rx`, up to an offset of `Ry` ... set to ... `C` |
| `mem_set_b` | ... address in `Rx`, up to an offset of `C` ... set to ... `Ry` |
| `mem_set_c` | ... address in `R`, up to an offset of `Cy` ... set to ... `Cx` |

### Encoding
We display the encoding of each instruction with the opcode as a hexadecimal number.

Padding bytes are next, shown as `00`.

Operand encoding symbology may follow the padding bytes,
such as `Rx`, indicating the first register operand to use.

Symbolic operand character sequences will begin with a capital letter,
and will be the appropriate width for the operand bytes.

#### Example
A `Constant` marker is `C___`,
because it is a 2 byte identifier.
