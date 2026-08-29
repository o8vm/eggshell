module

import Std

@[expose] public section

namespace Eggshell.Blake3

def blockBytes : Nat := 64
def chunkBytes : Nat := 1024

def chunkStart : UInt32 := 1
def chunkEnd : UInt32 := 2
def parent : UInt32 := 4
def root : UInt32 := 8

def iv : Array UInt32 := #[
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]

def permutation : Array Nat := #[2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

def rotateRight (word : UInt32) (count : Nat) : UInt32 :=
  (word >>> count.toUInt32) ||| (word <<< (32 - count).toUInt32)

def modifyAt (words : Array UInt32) (index : Nat) (change : UInt32 → UInt32) :
    Array UInt32 :=
  words.set! index (change words[index]!)

def g (state : Array UInt32) (a b c d mx my : Nat) : Array UInt32 :=
  let state := modifyAt state a fun value => value + state[b]! + state[mx]!
  let state := state.set! d (rotateRight (state[d]! ^^^ state[a]!) 16)
  let state := modifyAt state c fun value => value + state[d]!
  let state := state.set! b (rotateRight (state[b]! ^^^ state[c]!) 12)
  let state := modifyAt state a fun value => value + state[b]! + state[my]!
  let state := state.set! d (rotateRight (state[d]! ^^^ state[a]!) 8)
  let state := modifyAt state c fun value => value + state[d]!
  state.set! b (rotateRight (state[b]! ^^^ state[c]!) 7)

def round (state : Array UInt32) (message : Array UInt32) : Array UInt32 :=
  let words := state ++ message
  let words := g words 0 4 8 12 16 17
  let words := g words 1 5 9 13 18 19
  let words := g words 2 6 10 14 20 21
  let words := g words 3 7 11 15 22 23
  let words := g words 0 5 10 15 24 25
  let words := g words 1 6 11 12 26 27
  let words := g words 2 7 8 13 28 29
  let words := g words 3 4 9 14 30 31
  words.extract 0 16

def permute (message : Array UInt32) : Array UInt32 :=
  permutation.map fun index => message[index]!

def sevenRounds (state message : Array UInt32) : Array UInt32 :=
  let first := round state message
  let secondMessage := permute message
  let second := round first secondMessage
  let thirdMessage := permute secondMessage
  let third := round second thirdMessage
  let fourthMessage := permute thirdMessage
  let fourth := round third fourthMessage
  let fifthMessage := permute fourthMessage
  let fifth := round fourth fifthMessage
  let sixthMessage := permute fifthMessage
  let sixth := round fifth sixthMessage
  round sixth (permute sixthMessage)

structure Source where
  segments : List ByteArray
  size : Nat

namespace Source

def ofSegments (segments : List ByteArray) : Source :=
  { segments, size := segments.foldl (fun total bytes => total + bytes.size) 0 }

def byteAt : List ByteArray → Nat → UInt8
  | [], _ => 0
  | head :: tail, offset =>
      if offset < head.size then head.get! offset
      else byteAt tail (offset - head.size)

def getD (source : Source) (offset : Nat) : UInt8 :=
  if offset < source.size then byteAt source.segments offset else 0

end Source

def wordAt (source : Source) (offset : Nat) : UInt32 :=
  let byte index := (source.getD (offset + index)).toUInt32
  byte 0 ||| (byte 1 <<< 8) ||| (byte 2 <<< 16) ||| (byte 3 <<< 24)

def blockWords (source : Source) (offset : Nat) : Array UInt32 :=
  (Array.range 16).map fun index => wordAt source (offset + index * 4)

def counterLow (counter : UInt64) : UInt32 := counter.toUInt32
def counterHigh (counter : UInt64) : UInt32 := (counter >>> 32).toUInt32

def compress (chaining : Array UInt32) (block : Array UInt32)
    (counter : UInt64) (length : UInt32) (flags : UInt32) : Array UInt32 :=
  let initial := chaining ++ iv.extract 0 4 ++
    #[counterLow counter, counterHigh counter, length, flags]
  let state := sevenRounds initial block
  (Array.range 8).map (fun index => state[index]! ^^^ state[index + 8]!) ++
    (Array.range 8).map (fun index => state[index + 8]! ^^^ chaining[index]!)

structure Output where
  chaining : Array UInt32
  block : Array UInt32
  counter : UInt64
  length : UInt32
  flags : UInt32

namespace Output

def words (output : Output) (extraFlags : UInt32 := 0) : Array UInt32 :=
  compress output.chaining output.block output.counter output.length
    (output.flags ||| extraFlags)

def chainingValue (output : Output) : Array UInt32 :=
  (output.words).extract 0 8

end Output

def chunkOutput (source : Source) (start length : Nat) (counter : UInt64) : Output := Id.run do
  let blocks := if length = 0 then 1 else (length + blockBytes - 1) / blockBytes
  let mut chaining := iv
  for blockIndex in [0:blocks - 1] do
    let blockStart := start + blockIndex * blockBytes
    let blockLength := Nat.min blockBytes (length - blockIndex * blockBytes)
    let flags := if blockIndex = 0 then chunkStart else 0
    chaining := (compress chaining (blockWords source blockStart) counter
      blockLength.toUInt32 flags).extract 0 8
  let finalIndex := blocks - 1
  let finalStart := start + finalIndex * blockBytes
  let finalLength := if length = 0 then 0 else length - finalIndex * blockBytes
  let finalFlags := chunkEnd ||| (if finalIndex = 0 then chunkStart else 0)
  return {
    chaining
    block := blockWords source finalStart
    counter
    length := finalLength.toUInt32
    flags := finalFlags
  }

def parentOutput (left right : Array UInt32) : Output := {
  chaining := iv
  block := left ++ right
  counter := 0
  length := 64
  flags := parent
}

def mergeStack (stack : List (Array UInt32)) (value : Array UInt32)
    (completedChunks : Nat) : List (Array UInt32) :=
  let rec go (remaining : Nat) (stack : List (Array UInt32))
      (value : Array UInt32) : List (Array UInt32) :=
    if remaining % 2 = 0 then
      match stack with
      | left :: tail => go (remaining / 2) tail (parentOutput left value).chainingValue
      | [] => [value]
    else value :: stack
  go completedChunks stack value

def finalOutput (source : Source) : Output := Id.run do
  let chunks := if source.size = 0 then 1 else (source.size + chunkBytes - 1) / chunkBytes
  let mut stack : List (Array UInt32) := []
  for chunkIndex in [0:chunks - 1] do
    let start := chunkIndex * chunkBytes
    let length := Nat.min chunkBytes (source.size - start)
    let output := chunkOutput source start length chunkIndex.toUInt64
    stack := mergeStack stack output.chainingValue (chunkIndex + 1)
  let lastIndex := chunks - 1
  let lastStart := lastIndex * chunkBytes
  let lastLength := if source.size = 0 then 0 else source.size - lastStart
  let mut output := chunkOutput source lastStart lastLength lastIndex.toUInt64
  for left in stack do
    output := parentOutput left output.chainingValue
  return output

def appendWord (output : ByteArray) (word : UInt32) : ByteArray :=
  output
    |>.push word.toUInt8
    |>.push (word >>> 8).toUInt8
    |>.push (word >>> 16).toUInt8
    |>.push (word >>> 24).toUInt8

def wordBytes (word : UInt32) : ByteArray := appendWord {} word

def hashSegments (segments : List ByteArray) : ByteArray :=
  let words := (finalOutput (Source.ofSegments segments)).words root
  wordBytes words[0]! ++ wordBytes words[1]! ++
    wordBytes words[2]! ++ wordBytes words[3]! ++
    wordBytes words[4]! ++ wordBytes words[5]! ++
    wordBytes words[6]! ++ wordBytes words[7]!

def hash (bytes : ByteArray) : ByteArray := hashSegments [bytes]

def u64le (value : Nat) : ByteArray :=
  (Array.range 8).foldl (fun bytes index =>
    bytes.push (value >>> (index * 8)).toUInt8) {}

def digest (domain : ByteArray) (fields : List ByteArray) : ByteArray :=
  hashSegments (u64le domain.size :: domain ::
    fields.flatMap fun field => [u64le field.size, field])

def hexDigit (value : UInt8) : Char :=
  if value < 10 then Char.ofNat ('0'.toNat + value.toNat)
  else Char.ofNat ('a'.toNat + value.toNat - 10)

def hex (bytes : ByteArray) : String :=
  String.ofList <| bytes.toList.flatMap fun byte =>
    [hexDigit (byte.toNat / 16).toUInt8, hexDigit (byte.toNat % 16).toUInt8]

theorem hashSegments_size (segments : List ByteArray) :
    (hashSegments segments).size = 32 := by
  simp [hashSegments, wordBytes, appendWord]

theorem hash_size (bytes : ByteArray) : (hash bytes).size = 32 := by
  exact hashSegments_size [bytes]

/-- Official BLAKE3 unkeyed known-answer vectors pin the executable definition. -/
theorem empty_vector :
    hex (hash {}) =
      "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262" := by
  native_decide

theorem abc_vector :
    hex (hash "abc".toUTF8) =
      "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85" := by
  native_decide

end Eggshell.Blake3
