# Blarney

[Blarney](http://mn416.github.io/blarney/)
is a Haskell library for hardware description that builds a
range of HDL abstractions on top of a small set of core circuit
primitives.  It is a modern variant of
[Lava](http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.110.5587&rep=rep1&type=pdf), requiring GHC 8.6.1 or later.

## Contents

Examples:

* [Example 1: Two-sort](#example-1-two-sort)
* [Example 2: Bubble sort](#example-2-bubble-sort)
* [Example 3: Polymorphism](#example-3-polymorphism)
* [Example 4: Basic RTL](#example-4-basic-rtl)
* [Example 5: Queues](#example-5-queues)
* [Example 6: Wires](#example-6-wires)
* [Example 7: Bit selection](#example-7-bit-selection)
* [Example 8: Bits class](#example-8-bits-class)
* [Example 9: FShow class](#example-9-fshow-class)
* [Example 10: Recipes](#example-10-recipes)
* [Example 11: Block RAMs](#example-11-block-rams)
* [Example 12: Streams](#example-12-streams)
* [Example 13: Modular compilation](#example-13-modular-compilation)
* [Example 14: Bit-string pattern matching](#example-14-bit-string-pattern-matching)
* [Example 15: Tiny 8-bit CPU](#example-15-tiny-8-bit-cpu)

## Example 1: Two-sort

Sorting makes for a good introduction to the library.  Let's start
with perhaps the simplest kind of sorter possible: one that sorts just
two inputs.  Given a pair of 8-bit values, the function `twoSort`
returns the sorted pair.

```hs
import Blarney

twoSort :: (Bit 8, Bit 8) -> (Bit 8, Bit 8)
twoSort (a, b) = a .<. b ? ((a, b), (b, a))
```

This definition makes use of three Blarney constructs: the `Bit` type
for bit vectors (parametised by the size of the vector); the unsigned
comparison operator `.<.`; and the ternary conditional operator `?`.
To check that it works, let's create a test bench that supplies some
sample inputs and displays the outputs.

```hs
top :: RTL ()
top = do
  display "twoSort (0x1,0x2) = " (twoSort (0x1,0x2))
  display "twoSort (0x2,0x1) = " (twoSort (0x2,0x1))
  finish
```

We use Blarney's RTL (register-transfer level) monad.  All statements
in this monad are executed *in parallel* and *on every clock cycle*.
We can generate some Verilog as follows.

```hs
main :: IO ()
main = emitVerilogTop top "top" "/tmp/twoSort/"
```

Assuming the above code is in a file named `Sorter.hs`, it can be
compiled at the command-line using

```sh
> blc Sorter.hs
```

where `blc` stands for *Blarney compiler*.  This is just a script that
invokes GHC with the appropriate compiler flags.  For it to work,
the `BLARNEY_ROOT` environment variable needs to be set to the root of
the repository, and `BLARNEY_ROOT/Scripts` must be in your `PATH`.
Running the resulting executable will produce Verilog in the
`/tmp/twoSort` directory, including a makefile to build a Verilator
simulator (`sudo apt-get install verilator`).  The simulator can be
built and run as follows.

```sh
> cd /tmp/twoSort
> make
> ./top
twoSort (0x1,0x2) = (0x1,0x2)
twoSort (0x2,0x1) = (0x1,0x2)
```

Looks like `twoSort` is working!

## Example 2: Bubble sort

We can build a general *N*-element sorter by connecting together
multiple two-sorters.  One of the simplest ways to do this is the
*bubble sort* network.  The key component of this network is a
function `bubble` that takes a list of inputs and returns a new list
in which the smallest element comes first (the smallest element
"bubbles" to the front).

```hs
bubble :: [Bit 8] -> [Bit 8]
bubble [] = []
bubble [x] = [x]
bubble (x:y:rest) = bubble (small:rest) ++ [large]
  where (small, large) = twoSort (x, y)
```

If we repeatedly call `bubble` then we end up with a sorted list.

```hs
sort :: [Bit 8] -> [Bit 8]
sort [] = []
sort xs = smallest : sort rest
  where smallest:rest = bubble xs
```

Running the test bench

```hs
top :: RTL ()
top = do
  let inputs = [0x3, 0x4, 0x1, 0x0, 0x2]
  display "sort " inputs " = " (sort inputs)
  finish
```

in simulation yields:

```
sort [0x3,0x4,0x1,0x0,0x2] = [0x0,0x1,0x2,0x3,0x4]
```

To see that the `sort` function really is describing a circuit, let's
draw the circuit digram for a 5-element bubble sorter.

```
        -->.
           |
        -->+---.
           |   |
Inputs  -->+---+---.
           |   |   |
        -->+---+---+---.
           |   |   |   |
        -->+---+---+---+---.
           |   |   |   |   |
           v   v   v   v   v

                Outputs
```

The input list is supplied on the left, and the sorted output list is
produced at the bottom.  Each `+` denotes a two-sorter that takes
inputs from the top and the left, and produces the smaller value to
the bottom and the larger value to the right.

See [The design and verification of a sorter
core](https://pdfs.semanticscholar.org/de30/22efc5aec833d7b52bd4770a382fea729bba.pdf)
for a more in-depth exploration of sorting circuits in Haskell.

## Example 3: Polymorphism

For simplicity, we've made our sorter specific to lists of 8-bit
values.  But if we look at the types of the primitive functions it
uses, we can see that it actually has a more general type.

```hs
(.<.) :: Cmp a  => a -> a -> Bit 1
(?)   :: Bits a => Bit 1 -> (a, a) -> a
```

So `.<.` can be used on any type in the
[Cmp](http://mn416.github.io/blarney/Blarney-Bit.html#t:Cmp)
(comparator) class.  Similarly '?' can be used on any type in the
[Bits](http://mn416.github.io/blarney/Blarney-Prelude.html#t:Bits)
class (which allows serialisation to a bit vector and back
again). So a more generic definition of `twoSort` would be:

```hs
twoSort :: (Bits a, Cmp a) => (a, a) -> (a, a)
twoSort (a, b) = a .<. b ? ((a, b), (b, a))
```

Indeed, this would be the type inferred by the Haskell compiler if no
type signature was supplied.

## Example 4: Basic RTL

So far, we've only seen the `display` and `finish` actions of the RTL
monad.  It also supports creation and assignment of registers.  To
illustrate, here is an RTL block that creates a 4-bit `cycleCount`
register, increments it on each cycle, stopping when it reaches 10.

```hs
top :: RTL ()
top = do
  -- Create a register
  cycleCount :: Reg (Bit 4) <- makeReg 0

  -- Increment on every cycle
  cycleCount <== cycleCount.val + 1

  -- Display value on every cycle
  display "cycleCount = " (cycleCount.val)

  -- Terminate simulation when count reaches 10
  when (cycleCount.val .==. 10) do
    display "Finished"
    finish
```

This example introduces a number of new library functions: `makeReg`
creates a register, initialised to the given value; `val` returns the
value of a register; the `.` operator is defined by Blarney as
*reverse function application* rather than the usual *function
composition*; and `when` allows conditional RTL blocks to be
introduced.  One can also use `if`/`then`/`else` in an RTL context,
thanks to Haskell's rebindable syntax feature.

```hs
  -- Terminate simulation when count reaches 10
  if cycleCount.val .==. 10
    then do
      display "Finished"
      finish
    else
      display "Not finished"
```

Running `top` in simulation gives

```
cycleCount = 0x0
cycleCount = 0x1
cycleCount = 0x2
cycleCount = 0x3
cycleCount = 0x4
cycleCount = 0x5
cycleCount = 0x6
cycleCount = 0x7
cycleCount = 0x8
cycleCount = 0x9
cycleCount = 0xa
Finished
```

## Example 5: Queues

Queues (also known as FIFOs) are commonly used abstraction in hardware
design.  Blarney provides [a range of different queue
implementations](http://mn416.github.io/blarney/Blarney-Queue.html),
all of which implement the following interface.

```hs
-- Queue interface
data Queue a =
  Queue {
    notEmpty :: Bit 1        -- Is the queue non-empty?
  , notFull  :: Bit 1        -- Is there any space in the queue?
  , enq      :: a -> RTL ()  -- Insert an element (assuming notFull)
  , deq      :: RTL ()       -- Remove the first element (assuming canDeq)
  , canDeq   :: Bit 1        -- Guard on the deq and first methods
  , first    :: a            -- View the first element (assuming canDeq)
  }
```

The type `Queue a` represents a queue holding elements of type `a`,
and provides a range of standard functions on queues.  The `enq`
method should only be called when `notFull` is true and the `deq`
method should only be called when `canDeq` is true.  Similarly, the
`first` element of the queue is only valid when `canDeq` is true.
Below, we present the simplest possible implementation of a
one-element queue.

```hs
-- Simple one-element queue implementation
makeSimpleQueue :: Bits a => RTL (Queue a)
makeSimpleQueue = do
  -- Register holding the one element
  reg :: Reg a <- makeReg dontCare

  -- Register defining whether or not queue is full
  full :: Reg (Bit 1) <- makeReg 0

  -- Methods
  let notFull  = full.val .==. 0
  let notEmpty = full.val .==. 1
  let enq a    = do reg <== a
                    full <== 1
  let deq      = full <== 0
  let canDeq   = full.val .==. 1
  let first    = reg.val

  -- Return interface
  return (Queue notEmpty notFull enq deq canDeq first)
```

The following simple test bench illustrates how to use a queue.

```hs
-- Small test bench for queues
top :: RTL ()
top = do
  -- Instantiate a queue of 8-bit values
  queue :: Queue (Bit 8) <- makeSimpleQueue

  -- Create an 8-bit count register
  count :: Reg (Bit 8) <- makeReg 0
  count <== count.val + 1

  -- Writer side
  when (queue.notFull) do
    enq queue (count.val)
    display "Enqueued " (count.val)

  -- Reader side
  when (queue.canDeq) do
    deq queue
    display "Dequeued " (queue.first)

  -- Terminate after 100 cycles
  when (count.val .==. 100) finish
```

## Example 6: Wires

*Wires* are a feature of the RTL monad that offer a way for separate
RTL blocks to communicate *within the same clock cycle*.  Whereas
assignment to a register becomes visible on the clock cycle after the
assigment occurs, assignment to a wire is visible on the same cycle as
the assignment.  If no assignment is made to a wire on a particular
cycle, then the wire emits its *default value* on that cycle.  When
multiple assignments to the same wire occur on the same cycle, the
wire emits the bitwise disjunction of all the assigned values.

To illustrate, let's implement an *n*-bit counter module that supports
increment and decerement operations.

```hs
-- Interface for a n-bit counter
data Counter n =
  Counter {
    inc    :: RTL ()
  , dec    :: RTL ()
  , output :: Bit n
  }
```

We'd like the counter to support *parallel calls* to `inc` and `dec`.
That is, if `inc` and `dec` are called on the same cycle then the
counter's `output` is unchanged.  We'll achieve this using wires.

```hs
makeCounter :: KnownNat n => RTL (Counter n)
makeCounter = do
  -- State
  count :: Reg (Bit n) <- makeReg 0

  -- Wires
  incWire :: Wire (Bit 1) <- makeWire 0
  decWire :: Wire (Bit 1) <- makeWire 0

  -- Increment
  when (incWire.val .&. decWire.val.inv) do
    count <== count.val + 1

  -- Decrement
  when (incWire.val.inv .&. decWire.val) do
    count <== count.val - 1

  -- Interface
  let inc    = incWire <== 1
  let dec    = decWire <== 1
  let output = count.val

  return (Counter inc dec output)
```

## Example 7: Bit selection

Blarney provides the following untyped bit-selection functions, i.e.
where the selection indices are values rather than types, meaning the
width mismatches will not be caught by the type checker, but by a
(probably unhelpful) error-message at circuit-generation time.

```hs
-- Dynamically-typed bit selection
bit :: Int -> Bit n -> Bit 1

-- Dynamically-typed sub-range selection
bits :: KnownNat m => (Int, Int) -> Bit n -> Bit m
```

There are statically-typed versions of both these functions --
[index](http://mn416.github.io/blarney/Blarney-Bit.html#v:index) and
[range](http://mn416.github.io/blarney/Blarney-Bit.html#v:range).
To illustrate, here's a function to select the upper four bits of a byte.

```hs
-- Extract upper 4 bits of a byte
upperNibble :: Bit 8 -> Bit 4
upperNibble x = range @7 @4 x
```

We use type application to specify the type-level indices.

## Example 8: Bits class

Any type in the
[Bits](http://mn416.github.io/blarney/Blarney-Bits.html)
lass can be represented in hardware, e.g.
stored in a wire, a register, or a RAM.

```hs
class Bits a where
  type SizeOf a :: Nat
  sizeOf        :: a -> Int
  pack          :: a -> Bit (SizeOf a)
  unpack        :: Bit (SizeOf a) -> a
```

The `Bits` class supports *generic deriving*.  For example, suppose
we have a simple data type for memory requests:

```hs
data MemReq =
  MemReq {
    memOp   :: Bit 1    -- Is it a load or a store request?
  , memAddr :: Bit 32   -- 32-bit address
  , memData :: Bit 32   -- 32-bit data for stores
  }
  deriving (Generic, Bits)
```

To make this type a member of the `Bits` class, we have suffixed it
with `derving (Generic, Bits)`.  The generic deriving mechanism for
`Bits` does not support *sum types* (there is no way to convert a
bit-vector to a sum type using the circuit primitives provided
Blarney).

## Example 9: FShow class

Any type in the
[FShow](http://mn416.github.io/blarney/Blarney-FShow.html)
class can be passed as an argument to the
`display` function.

```hs
class FShow a where
  fshow     :: a -> Format
  fshowList :: [a] -> Format     -- Has default definition

-- Abstract data type for things that can be displayed
newtype Format

-- Format constructors
mempty :: Format                         -- Empty (from Monoid class)
(<>)   :: Format -> Format -> Format     -- Append (from Monoid class)

-- Primitive instances
instance FShow Char
instance FShow (Bit n)
```

As an example, here is how the `FShow` instance for pairs is defined.

```hs
-- Example instance: displaying pairs
instance (FShow a, FShow b) => FShow (a, b) where
  fshow (a, b) = fshow "(" <> fshow a <> fshow "," <> fshow b <> fshow ")"
```

Like the `Bits` class, the `FShow` class supports *generic deriving*:
just include `FShow` in the `deriving` clause for the data type.

## Example 10: Recipes

State machines are a common way of defining the control-path of a
circuit.  They are typically expressed by doing case-analysis of the
current-state and manually setting the next-state.  Quite often
however, they can be expressed more neatly in a
[Recipe](http://mn416.github.io/blarney/Blarney-Recipe.html)
-- a simple imperative language with various control-flow statements.

```hs
data Recipe = 
    Skip                   -- Do nothing (in zero cycles)
  | Tick                   -- Do nothing (in one cycle)
  | RTL (RTL ())           -- Perform RTL block (in one cycle)
  | Seq [Recipe]           -- Execute recipes in sequence
  | Par [Recipe]           -- Fork-join parallelism
  | If (Bit 1) Recipe      -- Conditional recipe
  | While (Bit 1) Recipe   -- Loop
```

To illustrate, here is a small state machine that computes the
factorial of 10.

```hs
fact :: RTL ()
fact = do
  -- State
  n   :: Reg (Bit 32) <- makeReg 0
  acc :: Reg (Bit 32) <- makeReg 1

  -- Compute factorial of 10
  let recipe =
        Seq [
          RTL do
            n <== 10
        , While (n.val .>. 0) (
            RTL do
              n <== n.val - 1
              acc <== acc.val * n.val
          )
        , RTL do
            display "fact(10) = " (acc.val)
            finish
        ]
       
  runOnce recipe 
```

Blarney provides a lightweight compiler for the `Recipe` language
(under 100 lines of code), which we invoke above through the call to
`runOnce`.

A very common use of recipes is to define test sequences.  For
example, here is a simple test sequence for the `Counter` module
defined earlier.

```hs
-- Test-bench for a counter
top :: RTL ()
top = do
  -- Instantiate an 4-bit counter
  counter :: Counter 4 <- makeCounter

  -- Sample test sequence
  let test =
        Seq [
          RTL do
            counter.inc
        , RTL do
            counter.inc
        , RTL do
            counter.inc
            counter.dec
        , RTL do
            display "counter = " (counter.output)
            finish
        ]

  runOnce test
```

Here, we increment `counter` on the first cycle, and then again on the
second.  On the third cycle, we both increment and decrement it in
parallel.  On the fourth cycle, we display the value and terminate the
simulator.

## Example 11: Block RAMs

Blarney provides
[a variety of block RAM
modules](http://mn416.github.io/blarney/Blarney-RAM.html)
commonly supported on FPGAs.
They are all based around the following interface.

```hs
-- Block RAM interface
-- (Parameterised by the address width a and the data width d)
data RAM a d =
  RAM {
    load    :: a -> RTL ()
  , store   :: a -> d -> RTL ()
  , out     :: d
  }
```

When a `load` is issued for a given address, the value at that address
appears on `out` on the next clock cycle.  When a `store` is issued,
the value is written to the RAM on the current cycle, and the written
value appears on `out` on the next cycle.  A parallel `load` and
`store` to the same `RAM` interface should not be issued on the same
cycle.  To illustrate, here is a test bench that creates a block RAM
and performs a `store` followed by a `load`.

```hs
top :: RTL ()
top = do
  -- Instantiate a 256 element RAM of 5-bit values
  ram :: RAM (Bit 8) (Bit 5) <- makeRAM

  -- Write 10 to ram[0] and read it back again
  let test =
        Seq [
          RTL do
            store ram 0 10
        , RTL do
            load ram 0
        , RTL do
            display "Got " (ram.out)
            finish
        ]

  runOnce test
```

Somewhat-related to block RAMs are
(register files)[http://mn416.github.io/blarney/Blarney-RTL.html#t:RegFile].
The difference
is that a register file allows the value at an address to be
determined *within* a clock cycle.  It also allows any number of reads
and writes to be performed within the same cycle.  Register files have
the following interface.

```hs
data RegFile a d =
  RegFile {
    (!)    :: a -> d              -- Read
  , update :: a -> d -> RTL ()    -- Write
  }
```

Unlike block RAMs, register files (especially large ones) do not
always map efficiently onto hardware, so use with care!

## Example 12: Streams

Streams are another commonly-used abstraction in hardware description.
They are often used to implement hardware modules that consume data at
a *variable rate*, depending on internal details of the module that
the implementer does not wish to (or is unable to) expose.  In
Blarney,
[streams](file:///home/mn416/work/mn416.github.io/blarney/Blarney-Stream.html)
are captured by the following interface.

```hs
type Stream a = Get a

data Get a =
  Get {
    get    :: RTL ()
  , canGet :: Bit 1
  , value  :: a
  }
```

Streams are closely related to queues.  Indeed, any queue can be
converted to a stream:

```hs
-- Convert a queue to a stream
toStream :: Queue a -> Stream a
toStream q =
  Get {
    get    = q.deq
  , canGet = q.canDeq
  , value  = q.first
  }
```

As an example, here's a function that increments each value in the
input stream to produce the output stream.

```hs
incS :: Stream (Bit 8) -> RTL (Stream (Bit 8))
incS xs = do
  -- Output buffer
  buffer <- makeQueue

  -- Incrementer
  when (xs.canGet .&. buffer.notFull) do
    get xs
    enq buffer (xs.value + 1)

  -- Convert buffer to a stream
  return (buffer.toStream)
```

## Example 13: Modular compilation

So far we've seen examples of top-level modules, i.e. modules with no
inputs or outputs, being converted to Verilog.  In fact, any Blarney
function whose inputs and outputs are members of the
[Interface](http://mn416.github.io/blarney/Blarney-Interface.html) class
can be converted to Verilog (and the `Interface` class supports
generic deriving).  To illustrate, we can convert the function `incS`
(defined in [Example 12](#example-12-streams)) into a Verilog module
as follows.

```hs
main :: IO ()
main = emitVerilogModule incS "incS" "/tmp/inc"
```

The generated Verilog module `/tmp/inc/incS.v` has the following
interface:

```sv
module incS(
  input  wire clock
, output wire [0:0] in_get_en
, input  wire [0:0] in_canGet
, input  wire [7:0] in_value
, input  wire [0:0] out_get_en
, output wire [0:0] out_canGet
, output wire [7:0] out_value
);
```

Considering the definition of the `Stream` type, the correspondance
between the Blarney and the Verilog is quite clear:

Signal       | Description
------       | -----------
`in_get_en`  | Output asserted whenever the module consumes an element from the input stream.
`in_canGet`  | Input signalling when there is data available in the input stream.
`in_value`   | Input containing the next value in the input stream.
`out_get_en` | Input signalling when the caller consumes an element from the output stream.
`out_canGet` | Output asserted whenever there is data available in the output stream.
`out_value`  | Output containing the next value in the output stream.

It is also possible to instantiate a Verilog module inside a Blarney
description.  To illustrate, here is a function that creates an
instance of the Verilog `incS` module shown above.

```hs
-- This function creates an instance of a Verilog module called "incS"
makeIncS :: Stream (Bit 8) -> RTL (Stream (Bit 8))
makeIncS = makeInstance "incS" 
```

Notice that interface of the Verilog module being instantiated is
determined from the type signature.  Here's a sample top-level module
that uses the `makeIncS` function:

```hs
top :: RTL ()
top = do
  -- Counter
  count :: Reg (Bit 8) <- makeReg 0

  -- Input buffer
  buffer <- makeQueue

  -- Create an instance of incS
  out <- makeIncS (buffer.toStream)

  -- Fill input
  when (buffer.notFull) do
    enq buffer (count.val)
    count <== count.val + 1

  -- Consume
  when (out.canGet) do
    get out
    display "Got " (out.value)
    when (out.value .==. 100) finish
```

Using the following `main` function we can generate both the `incS`
module and a top-level module that instantiates it.

```hs
main :: IO ()
main = do
  let dir = "/tmp/inc"
  emitVerilogModule incS "incS" dir
  emitVerilogTop top "top" dir
```

Using this approach, we can maintain the module hierarchy of a Blarney
design whenever we generate Verilog, rather than having to flatten it
to massive netlist.  This technique can also be used to instantaite
any Verilog module within a Blarney design.

## Example 14: Bit-string pattern matching

Recent work on specifying and implementing ISAs led us to develop two
libraries for doing bit-string pattern matching.  The first,
[BitPat](http://mn416.github.io/blarney/Blarney-BitPat.html),
is statically-typed and based on the paper [Type-safe pattern
combinators](https://core.ac.uk/download/pdf/50525461.pdf).
The second,
[BitScan](http://mn416.github.io/blarney/Blarney-BitScan.html),
is dynamically typed but more expressive.
As an example, `BitScan`,
let's us define the following instruction decoder for a tiny subset of
RISC-V.

```hs
import Blarney.BitScan

-- Semantics of add instruction
add :: Bit 5 -> Bit 5 -> Bit 5 -> RTL ()
add rs2 rs1 rd =
  display "add r" (rd.val) ", r" (rs1.val) ", r" (rs1.val)

-- Semantics of addi instruction
addi :: Bit 12 -> Bit 5 -> Bit 5 -> RTL ()
addi imm rs1 rd =
  display "add r" (rd.val) ", r" (rs1.val) ", " (imm.val)

-- Semantics of store-word instruciton
sw :: Bit 12 -> Bit 5 -> Bit 5 -> RTL ()
sw imm rs2 rs1 = display "sw " rs2 ", " rs1 "[" imm "]"

top :: RTL ()
top = do
  -- Sample RISC-V store-word instruction
  let instr :: Bit 32 = 0b1000000_00001_00010_010_00001_0100011

  -- Dispatch
  match instr
    [
      "0000000   rs2[4:0]  rs1[4:0] 000 rd[4:0]  0110011" ==> add,
      "          imm[11:0] rs1[4:0] 000 rd[4:0]  0010011" ==> addi,
      "imm[11:5] rs2[4:0]  rs1[4:0] 010 imm[4:0] 0100011" ==> sw
    ]

  finish
```

The nice thing about this decoder is that the *scattered immediate*
field `imm` in the `sw` instruction is automatically assembled by the
library.  That is, the `imm[11:5]` part of the immediate is combined
with the `imm[4:0]` part to give the final 12-bit immediate value
passed to the right-hand-side function.  Scattered immediates appear a
lot in the RISC-V specification.  Thanks to Jon Woodruff for
suggesting this feature!

## Example 15: Tiny 8-bit CPU

As a way of briging together a number of the ideas introduced above,
let's define a very simple, 8-bit CPU with the following ISA.

  Opcode     | Meaning
  ---------- | ---------
  `00ZZNNNN` | Write value `0000NNNN` to register `ZZ`
  `01ZZXXYY` | Add register `XX` to register `YY` and store in register `ZZ`
  `10NNNNYY` | Branch back by `NNNN` instructions if register `YY` is non-zero
  `11NNNNNN` | Halt

To begin, let's consider a non-pipelined implementation of this ISA,
which has a CPI (cycles-per-instruction) of two: one cycle is used to
fetch the next instruction, and one cycle is used to execute it.  The
CPU will execute the program defined in the file `instrs.hex`.

```hs
makeCPU :: RTL ()
makeCPU = do
  -- Instruction memory (containing 32 instructions)
  instrMem :: RAM (Bit 5) (Bit 8) <- makeRAMInit "instrs.hex"

  -- Register file (containing 4 registers)
  regFile :: RegFile (Bit 2) (Bit 8) <- makeRegFile

  -- Program counter
  pc :: Reg (Bit 5) <- makeReg 0

  -- Are we fetching (1) or executing (0)
  fetch :: Reg (Bit 1) <- makeReg 1

  -- Load immediate instruction
  let li rd imm = do
        update regFile rd (zeroExtend imm)
        pc <== pc.val + 1
        display "rf[" rd "] := " imm

  -- Add instruction
  let add rd rs0 rs1 = do
        let sum = regFile!rs0 + regFile!rs1
        update regFile rd sum
        pc <== pc.val + 1
        display "rf[" rd "] := " sum

  -- Branch instruction
  let bnz offset rs = do
        if regFile!rs .==. 0
          then pc <== pc.val + 1
          else pc <== pc.val - zeroExtend offset

  -- Halt instruction
  let halt imm = finish

  -- Fetch
  when (fetch.val) $ do
    load instrMem (pc.val)
    fetch <== 0

  -- Execute
  when (fetch.val.inv) $ do
    match (instrMem.out)
      [
        lit 0b00 <#> var @2 <#> var @4              ==>  li,
        lit 0b01 <#> var @2 <#> var @2  <#> var @2  ==>  add,
        lit 0b10 <#> var @4 <#> var @2              ==>  bnz,
        lit 0b11 <#> var @6                         ==>  halt
      ]
    fetch <== 1
```

We have also developed a [3-stage pipeline
implemention](https://github.com/POETSII/blarney/blob/master/Examples/CPU/CPU.hs)
of the same ISA that has a CPI much closer to 1.  Although the ISA is
very simple, it does contain a few challenges for a pipelined
implementation, namely *control hazards* (due to the branch
instruction) and *data hazards* (due to the add instruction).  We
resolve data hazards using *register forwarding* and control hazards
by performing a *pipeline flush* when the branch is taken.
