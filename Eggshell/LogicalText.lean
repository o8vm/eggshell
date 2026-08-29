module

import Std

@[expose] public section

namespace Eggshell.LogicalText

/-- Half-open UTF-8 byte range. -/
structure ByteSpan where
  start : Nat
  stop : Nat
  deriving Repr, DecidableEq, BEq, Hashable, Ord

namespace ByteSpan

def valid (span : ByteSpan) : Bool := span.start < span.stop

def touches (left right : ByteSpan) : Bool :=
  left.start ≤ right.stop && right.start ≤ left.stop

def merge (left right : ByteSpan) : ByteSpan :=
  { start := Nat.min left.start right.start, stop := Nat.max left.stop right.stop }

end ByteSpan

/--
One normalized grapheme together with the exact source bytes that produced it.
Normalization is an input to the matcher, so the semantic algorithm and its
proofs do not depend on an operating-system Unicode implementation.
-/
structure Piece where
  text : String
  source : ByteSpan
  deriving Repr, DecidableEq

abbrev Normalizer := String → List Piece

def asciiWordCharacter (character : Char) : Bool :=
  character.val < 128 && (character.isAlphanum || character = '_')

def asciiCompoundCharacter (character : Char) : Bool :=
  asciiWordCharacter character || character = '/' || character = '.'

def dropTrailingDots (characters : List Char) : List Char :=
  (characters.reverse.dropWhile (· = '.')).reverse

/--
Code paths and dotted identifiers are one logical unit. A leading `./` is only
relative-shell spelling, and sentence-final dots carry no identity.
-/
def canonicalAsciiCompound (text : String) : String :=
  let characters := if text.startsWith "./" then text.toList.drop 2 else text.toList
  String.ofList (dropTrailingDots characters)

/--
Natural-language matching uses logical tokens, not coincident characters.
ASCII words are units, while paths and dotted identifiers remain indivisible
compound units; other ASCII syntax is a boundary. Non-ASCII scalars remain
units so unsegmented scripts need no language-specific tokenizer. Every unit
retains its exact source bytes.
-/
def logicalNormalizer : Normalizer := fun text => Id.run do
  let mut pieces : Array Piece := #[]
  let mut word := ""
  let mut wordStart := 0
  let mut wordBytes := 0
  let mut offset := 0
  for character in text.toList do
    let original := String.singleton character
    let bytes := original.toUTF8.size
    if asciiCompoundCharacter character then
      if word.isEmpty then wordStart := offset
      word := word ++ original.toLower
      wordBytes := wordBytes + bytes
    else
      if !word.isEmpty then
        pieces := pieces.push {
          text := canonicalAsciiCompound word
          source := { start := wordStart, stop := wordStart + wordBytes }
        }
        word := ""
        wordBytes := 0
      pieces := pieces.push {
        text := if character.val < 128 || character.isWhitespace then " "
          else original.toLower
        source := { start := offset, stop := offset + bytes }
      }
    offset := offset + bytes
  if !word.isEmpty then
    pieces := pieces.push {
      text := canonicalAsciiCompound word
      source := { start := wordStart, stop := wordStart + wordBytes }
    }
  return pieces.toList

structure Unit where
  logical : ByteSpan
  source : ByteSpan
  text : String
  deriving Repr, DecidableEq, BEq, Hashable

structure T where
  original : String
  text : String
  units : List Unit
  deriving Repr, DecidableEq

def whitespacePiece (piece : Piece) : Bool :=
  !piece.text.isEmpty && piece.text.toList.all Char.isWhitespace

def build (normalize : Normalizer) (original : String) : T :=
  Id.run do
    let mut output := ByteArray.empty
    let mut units : Array Unit := #[]
    let mut pendingSpace := false
    for piece in normalize original do
      if whitespacePiece piece then
        pendingSpace := true
      else if !piece.text.isEmpty then
        if pendingSpace && !output.isEmpty && output.get! (output.size - 1) != 32 then
          output := output.push 32
        let start := output.size
        let bytes := piece.text.toUTF8
        output := output ++ bytes
        units := units.push {
          logical := { start, stop := start + bytes.size }
          source := piece.source
          text := piece.text
        }
        pendingSpace := false
    return {
      original
      text := (String.fromUTF8? output).getD ""
      units := units.toList
    }

def logical (original : String) : T := build logicalNormalizer original

def isEmpty (text : T) : Bool := text.units.isEmpty

def byteSlice? (text : String) (span : ByteSpan) : Option String := do
  if span.start ≥ span.stop || span.stop > text.toUTF8.size then none else
  String.fromUTF8? (text.toUTF8.extract span.start span.stop)

def logicalSlice? (text : T) (span : ByteSpan) : Option String :=
  byteSlice? text.text span

def sourceSlice? (text : T) (span : ByteSpan) : Option String :=
  byteSlice? text.original span

def unitsIn (text : T) (span : ByteSpan) : List Nat :=
  let rec visit : List Unit → Nat → List Nat
    | [], _ => []
    | unit :: tail, ordinal =>
        let rest := visit tail (ordinal + 1)
        if span.start ≤ unit.logical.start && unit.logical.stop ≤ span.stop then
          ordinal :: rest
        else rest
  visit text.units 0

def envelope? : List ByteSpan → Option ByteSpan
  | [] => none
  | head :: tail => some (tail.foldl ByteSpan.merge head)

def sourceSpan? (text : T) (logical : ByteSpan) : Option ByteSpan :=
  unitsIn text logical |>.filterMap (text.units[·]? |>.map (·.source)) |> envelope?

def coalesce (spans : List ByteSpan) : List ByteSpan :=
  let ordered := (spans.toArray.mergeSort fun left right =>
    left.start < right.start || (left.start = right.start && left.stop ≤ right.stop)).toList
  match ordered with
  | [] => []
  | head :: tail =>
      (tail.foldl (fun reversed next =>
        match reversed with
        | [] => [next]
        | current :: rest =>
            if current.touches next then current.merge next :: rest
            else next :: reversed) [head]).reverse

/-- Exact source pieces selected by logical evidence, without unmatched gaps. -/
def sourceSpans? (text : T) (logicalSpans : List ByteSpan) : Option (List ByteSpan) := do
  let spans := logicalSpans.filterMap (sourceSpan? text) |> coalesce
  if spans.isEmpty then none else pure spans

def sourceEnvelope? (text : T) (logicalSpans : List ByteSpan) : Option ByteSpan := do
  envelope? (← sourceSpans? text logicalSpans)

def unitSpan? (text : T) (first width : Nat) : Option ByteSpan := do
  if width = 0 then none else
  let head ← text.units[first]?
  let last ← text.units[first + width - 1]?
  pure { start := head.logical.start, stop := last.logical.stop }

structure Gram where
  span : ByteSpan
  first : Nat
  last : Nat
  text : String
  deriving Repr, DecidableEq

/-- All one-to-three-unit anchors, longest first. -/
def grams (text : T) : List Gram :=
  [3, 2, 1].flatMap fun width =>
    if width > text.units.length then [] else
    (List.range (text.units.length - width + 1)).filterMap fun first => do
      let span ← unitSpan? text first width
      let surface ← logicalSlice? text span
      pure { span, first, last := first + width, text := surface }

end Eggshell.LogicalText
