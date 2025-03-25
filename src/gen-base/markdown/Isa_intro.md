<!-- This file is only a template for `bin/tools/gen-isa`;
    See `~/Isa.zig` for the full document; `gen-isa.zig/#generateMarkdown` for the generator -->


This is an instruction set architecture (ISA) for the Ribbon bytecode.

The Ribbon bytecode is a low-level register based bytecode,
with support for arbitrary effect handlers. For more information on
implementation details of the Ribbon virtual machine see `core`, `bytecode`, etc.

## Overview

### Basic layout
The ISA is divided into *Categories*;

*Categories* are further divided into *Mnemonic* bases;

*Mnemonics* then contain tables describing each concrete instruction variation.

#### Example
`callc` and `call_v` are both under the `call` mnemonic, within the `Control Flow` category.

#### JIT-only Instructions
Instructions with a *jit* tag above their name are
only available when `Rvm` is compiled with the `jit` option.

### Encoding
We display the encoding of each instruction as segmented bytes. The Ribbon
bytecode is always in little endian order, and we display these bytes as they
are ordered in memory.

The opcode is shown first, as a two byte hexadecimal number.

Padding bytes are shown as `__`.

In addition to standard hex characters and underscores, we utilize operand
encoding symbology, such as `Rx`, indicating the first register operand to use.
Symbolic operand character sequences will begin with a capital letter, and will
be the appropriate width for the operand's bytes if they were shown in hex form.

Nybbles displayed with `.` continue the value to the left of them.

Some instructions take up multiple words. We display word boundaries as line
breaks within the tables' **Encoding** columns, with subsequent instruction
address representations arranged lower within these lines. Where the number of
words used is dynamic, a trailing line containing `...` will be shown.

#### Example
An instruction with a `u16` immediate operand will use the notation
`I.`&nbsp;`..`, because it is 2 bytes.

Similarly, `Register` operands are simply `R.` or `Rx`, `Ry`, etc because they
are 1-byte identifiers.

As a concrete example, `store64c`, an instruction which stores a 64-bit
immediate value (encoded as `Iy`) to memory at the address in a designated
register (encoded as `R`), offset by another 32-bit immediate value (encoded as
`Ix`), has an encoding column entry like this:

| Encoding |
|-|
| `2d`&nbsp;`00`&nbsp;`R.`&nbsp;`Ix`&nbsp;`..`&nbsp;`..`&nbsp;`..`&nbsp;`__`<br>`Iy`&nbsp;`..`&nbsp;`..`&nbsp;`..`&nbsp;`..`&nbsp;`..`&nbsp;`..`&nbsp;`..` |

#### Immediate Operands
Immediate operands are formatted with `I`; immediate in this context means that
the value is literally encoded into the byte stream, rather than encoding a
reference to the value. We allow up to 64-bit immediates for all operations that
are binary or greater in arity; in all cases the bit size of the immediate
operand and the bit size of the operation must match. (I.e. there is no 'add 8
bit imm to 32 bit reg' instruction.)

Where instructions utilizing immediate operands are commutative, the version of
the instruction taking a constant will be suffixed with `c`.

For instructions that do not commute, the two constant versions will be suffixed
with `a` and `b` respectively, indicating whether the constant is used on the
left or right side.

##### Example
| Name | Description Excerpt |
|-|-|
| `mem_set` | ... up to an offset of `Rz`, is set to ... `Ry` |
| `mem_set_a` | ... up to an offset of `I`, is set to `Ry` |
| `mem_set_b` | ... up to an offset of `Ry`, is set to `I` |
|...|
| `mem_swap` | ... up to an offset of `Rz` ... |
| `mem_swap_c` | ... up to an offset of `I` ... |
