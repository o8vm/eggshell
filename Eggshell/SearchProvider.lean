module

public import Eggshell.SearchRank
public import Eggshell.MiniLM
public import Eggshell.Sha256
public import Eggshell.Persistence
public import Lean.Data.Json.FromToJson

@[expose] public section

namespace Eggshell.SearchProvider
open Lean

structure Options where
  cache : System.FilePath
  models : System.FilePath
  model : String := MiniLM.model
  mode : String := "hybrid"
  topK : Nat := 8
  anchorK : Nat := 2
  threshold : Float := 0.38
  trace : Option System.FilePath := none

def number (json : Json) : Except String Float := do
  match json with
  | .num value =>
    let result := value.toFloat
    if result.isFinite then pure result else throw "expected finite JSON number"
  | _ => throw "expected finite JSON number"

def natural (value : String) : Except String Nat :=
  match value.toNat? with
  | some n => .ok n
  | none => .error "expected a natural number"

def parse (defaults : Options) : List String → Except String Options
  | [] => .ok defaults
  | "--cache" :: v :: rest => parse { defaults with cache := .mk v } rest
  | "--model-cache" :: v :: rest => parse { defaults with models := .mk v } rest
  | "--model" :: v :: rest => parse { defaults with model := v } rest
  | "--mode" :: v :: rest =>
      if ["lexical", "semantic", "hybrid"].contains v then parse { defaults with mode := v } rest
      else .error "unsupported search mode"
  | "--top-k" :: v :: rest => do parse { defaults with topK := ← natural v } rest
  | "--anchor-k" :: v :: rest => do parse { defaults with anchorK := ← natural v } rest
  | "--threshold" :: v :: rest => do parse { defaults with threshold := ← number (← Json.parse v) } rest
  | "--trace" :: v :: rest => parse { defaults with trace := some (.mk v) } rest
  | _ => .error "invalid search-provider arguments"

abbrev Encoder := IO.Process.Child { stdin := .piped, stdout := .piped, stderr := .inherit }

def encoder (options : Options) : IO Encoder := do
  let layout := MiniLM.layout (← Paths.installRoot) options.cache
  let some python ← MiniLM.runtimePython? layout | throw (IO.userError "MiniLM runtime is not installed")
  IO.Process.spawn {
    cmd := python.toString
    args := #["-c", MiniLM.embeddingSource, options.model, options.models.toString, "4"]
    stdin := .piped
    stdout := .piped
    stderr := .inherit }

def exchange (child : Encoder) (input : Json) : IO Json := do
  child.stdin.putStrLn input.compress
  child.stdin.flush
  let result ← IO.ofExcept (Json.parse (← child.stdout.getLine))
  if let .ok error := result.getObjValAs? String "error" then throw (IO.userError error)
  pure result

/-- Persisted vectors carry the exact model and source bytes. The hash is only
    a locator; a collision or damaged record cannot authorize different text. -/
structure CachedVector where
  model : String
  text : String
  vector : Json
  deriving ToJson, FromJson

def cacheMatches (model text : String) (cached : CachedVector) : Bool :=
  decide (cached.model = model ∧ cached.text = text)

theorem accepted_cache_identity (model text : String) (cached : CachedVector)
    (h : cacheMatches model text cached = true) : cached.model = model ∧ cached.text = text := by
  exact of_decide_eq_true h

theorem changed_cache_text_rejected (model text : String) (cached : CachedVector)
    (h : cached.text ≠ text) : cacheMatches model text cached = false := by
  simp [cacheMatches, h]

theorem changed_cache_model_rejected (model text : String) (cached : CachedVector)
    (h : cached.model ≠ model) : cacheMatches model text cached = false := by
  simp [cacheMatches, h]

def cacheKey (model text : String) : String := Sha256.hex (model ++ "\x00" ++ text).toUTF8

def readVector (options : Options) (text : String) : IO (Option Json) := do
  let path := options.cache / "vectors" / (cacheKey options.model text ++ ".json")
  if !(← path.pathExists) then return none
  try
    let cached ← IO.ofExcept (fromJson? (← IO.ofExcept (Json.parse (← IO.FS.readFile path))) : Except String CachedVector)
    if cacheMatches options.model text cached then return some cached.vector
    throw (IO.userError "embedding cache identity mismatch")
  catch _ => return none

def saveVector (options : Options) (text : String) (vector : Json) : IO Unit := do
  let root := options.cache / "vectors"
  Persistence.privateDirectory root
  let path := root / (cacheKey options.model text ++ ".json")
  let temp := System.FilePath.mk (path.toString ++ ".tmp-" ++ toString (← IO.Process.getPID))
  IO.FS.writeFile temp (toJson ({ model := options.model, text, vector } : CachedVector)).compress
  Persistence.privateFile temp
  IO.FS.rename temp path

def store (options : Options) (child : Encoder) (texts : List String) : IO Unit := do
  let parts := (texts.flatMap SearchRank.windows).eraseDups
  let mut missing := []
  for part in parts do if (← readVector options part).isNone then missing := missing ++ [part]
  if missing.isEmpty then return
  let response ← exchange child (Json.mkObj [("texts", toJson missing)])
  let vectors ← IO.ofExcept (response.getObjValAs? (Array Json) "vectors")
  if vectors.size != missing.length then throw (IO.userError "embedding count mismatch")
  for (text, vector) in missing.zip vectors.toList do saveVector options text vector

def vectors (options : Options) (text : String) : IO Json := do
  let values ← (SearchRank.windows text).mapM fun part => do
    let some value ← readVector options part | throw (IO.userError "missing indexed embedding")
    pure value
  pure (.arr values.toArray)

def trace (options : Options) (record : Json) : IO Unit := do
  if let some path := options.trace then
    try
      if let some parent := path.parent then Persistence.privateDirectory parent
      let file ← IO.FS.Handle.mk path .append
      Persistence.privateFile path
      file.putStrLn record.compress
      file.flush
    catch error => IO.eprintln s!"Eggshell trace: {error}"

def handle (options : Options) (child : Option Encoder) (request : Json) : IO (Option Json) := do
  if let .ok index := request.getObjValAs? (Array Json) "index" then
    if let some child := child then
      let texts ← IO.ofExcept (index.toList.mapM (·.getObjValAs? String "text"))
      store options child texts
    return none
  let query ← IO.ofExcept ((request.getObjValD "query").getObjValAs? String "text")
  let candidates ← IO.ofExcept (request.getObjValAs? (Array Json) "candidates")
  let texts ← IO.ofExcept (candidates.toList.mapM (·.getObjValAs? String "text"))
  let lexical := SearchRank.lexical query texts
  let anchors := SearchRank.lexical query texts true
  let mut scored : List (Float × Nat) := []
  if let some child := child then
    store options child (texts ++ [query])
    let response ← exchange child (Json.mkObj [("queries", ← vectors options query),
      ("candidates", .arr (← texts.toArray.mapM (vectors options)))])
    let scores ← IO.ofExcept (response.getObjValAs? (Array Json) "scores")
    if scores.size != candidates.size then throw (IO.userError "similarity count mismatch")
    scored ← IO.ofExcept (scores.toList.zipIdx.mapM fun (value, index) => do pure (← number value, index))
  let ordered := scored.mergeSort SearchRank.scoreOrder
  let semantic := (ordered.filter (·.1 ≥ options.threshold)).map (·.2)
  let hybrid := (SearchRank.fused [lexical, semantic]).take options.topK
  let base := if options.mode == "hybrid" then hybrid else if options.mode == "lexical" then lexical else semantic
  let selected := SearchRank.select candidates.size options.topK (anchors.take options.anchorK) base
  trace options (Json.mkObj [("mode", .str options.mode), ("candidate_count", toJson candidates.size),
    ("candidate_ids", .arr (candidates.map (·.getObjValD "id"))),
    ("lexical_rank", toJson lexical), ("anchor_rank", toJson anchors),
    ("semantic_rank", toJson (ordered.map (·.2))), ("semantic_threshold_rank", toJson semantic),
    ("hybrid_rank", toJson hybrid), ("selected", toJson selected)])
  pure (some (Json.mkObj [("related", toJson selected)]))

def run (args : List String) : IO UInt32 := do
  let layout := MiniLM.layout (← Paths.installRoot) (← Paths.dataRoot)
  let options ← IO.ofExcept (parse { cache := layout.vectors, models := layout.models } args)
  let child ← if options.mode == "lexical" then pure none else some <$> encoder options
  try
    let stdin ← IO.getStdin
    let stdout ← IO.getStdout
    repeat
      let line ← stdin.getLine
      if line.isEmpty then break
      try
        let request ← IO.ofExcept (Json.parse line)
        if let some result ← handle options child request then
          stdout.putStrLn result.compress
          stdout.flush
      catch error =>
        IO.eprintln s!"Eggshell search: {error}"
        stdout.putStrLn "{\"related\":[]}"
        stdout.flush
    pure 0
  finally
    if let some child := child then
      child.kill
      let _ ← child.wait
      pure ()

end Eggshell.SearchProvider
