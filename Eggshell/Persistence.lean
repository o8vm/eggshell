module

public import Eggshell.Quotient
public import Lean.Data.Json

@[expose] public section

namespace Eggshell.Persistence

open Lean

def privateFile (path : System.FilePath) : IO Unit :=
  IO.setAccessRights path {
    user := { read := true, write := true }
    group := {}
    other := {}
  }

def privateDirectory (path : System.FilePath) : IO Unit := do
  IO.FS.createDirAll path
  IO.setAccessRights path {
    user := { read := true, write := true, execution := true }
    group := {}
    other := {}
  }

def symlinkMetadata? (path : System.FilePath) : IO (Option IO.FS.Metadata) := do
  try pure (some (← path.symlinkMetadata))
  catch _ => pure none

/--
Authority paths never traverse symbolic links. This keeps a checked project-local
path local when it is later read or created and prevents hardening an unrelated
link target.
-/
def rejectSymlinkAncestors (path : System.FilePath) : IO Unit := do
  let rec visit : Nat → System.FilePath → IO Unit
    | 0, _ => throw (IO.userError s!"authority path is too deep: {path}")
    | fuel + 1, current => do
        if let some metadata ← symlinkMetadata? current then
          if metadata.type == .symlink then
            throw (IO.userError s!"authority path traverses a symbolic link: {current}")
        match current.parent with
        | some parent =>
            if parent == current then pure () else visit fuel parent
        | none => pure ()
  visit (path.toString.length + 1) path.normalize

/-- Missing is distinct from malformed. Existing authorities must be regular files. -/
def regularMetadata? (path : System.FilePath) : IO (Option IO.FS.Metadata) := do
  rejectSymlinkAncestors path
  match ← symlinkMetadata? path with
  | none => pure none
  | some metadata =>
      if metadata.type == .file then pure (some metadata)
      else throw (IO.userError s!"Eggshell authority is not a regular file: {path}")

def operatorName : Operator → String
  | .all => "all"
  | .outcome => "outcome"
  | .occurrence => "occurrence"
  | .inquiry => "inquiry"
  | .receipt => "receipt"

def operatorFromName : String → Except String Operator
  | "all" => pure .all
  | "outcome" => pure .outcome
  | "occurrence" => pure .occurrence
  | "inquiry" => pure .inquiry
  | "receipt" => pure .receipt
  | name => throw s!"unknown Eggshell operator: {name}"

mutual

def valueToJson : Value → Json
  | .atom bytes => .arr #[
      .str "atom",
      .arr (bytes.toList.toArray.map fun byte => (byte.toNat : Json))
    ]
  | .apply operator references => .arr #[
      .str "apply",
      .str (operatorName operator),
      .arr (refsToJson references)
    ]

def refsToJson : Refs → Array Json
  | .nil => #[]
  | .semantic value tail =>
      #[.arr #[.str "semantic", valueToJson value]] ++ refsToJson tail
  | .exact value tail =>
      #[.arr #[.str "exact", valueToJson value]] ++ refsToJson tail

end

def bytesFromJson (items : Array Json) : Except String ByteArray := do
  let bytes ← items.toList.mapM fun item => do
    let value ← item.getNat?
    if value < 256 then pure value.toUInt8
    else throw "Atom byte exceeds 255"
  pure (.mk bytes.toArray)

mutual

def valueFromJson : Nat → Json → Except String Value
  | 0, _ => throw "Value nesting exceeds input bound"
  | fuel + 1, json => do
      let items ← json.getArr?
      match items.toList with
      | [.str "atom", .arr bytes] => pure (.atom (← bytesFromJson bytes))
      | [.str "apply", .str operatorName, .arr references] =>
          let operator ← operatorFromName operatorName
          pure (.apply operator (← refsFromJson fuel references.toList))
      | _ => throw "invalid Value encoding"

def refsFromJson : Nat → List Json → Except String Refs
  | 0, [] => pure .nil
  | 0, _ => throw "Ref nesting exceeds input bound"
  | _ + 1, [] => pure .nil
  | fuel + 1, json :: tail => do
      let pair ← json.getArr?
      match pair.toList with
      | [.str "semantic", encoded] =>
          pure (.semantic (← valueFromJson fuel encoded)
            (← refsFromJson fuel tail))
      | [.str "exact", encoded] =>
          pure (.exact (← valueFromJson fuel encoded)
            (← refsFromJson fuel tail))
      | _ => throw "invalid Ref encoding"

end

/-- A storage-only DAG node. Semantic identity remains the structural `Value`. -/
inductive StoredNode where
  | atom (bytes : ByteArray)
  | apply (operator : Operator) (arguments : List (Authority × Nat))

def listAt? : List α → Nat → Option α
  | [], _ => none
  | value :: _, 0 => some value
  | _ :: tail, index + 1 => listAt? tail index

/-- Exact lookup makes table references auditable; no digest decides identity. -/
def indexOfValue (needle : Value) : List Value → Option Nat
  | [] => none
  | value :: tail =>
      if value = needle then some 0
      else (indexOfValue needle tail).map Nat.succ

theorem indexOfValue_sound {needle : Value} {values : List Value} {index : Nat}
    (found : indexOfValue needle values = some index) :
    listAt? values index = some needle := by
  induction values generalizing index with
  | nil => simp [indexOfValue] at found
  | cons value tail induction =>
      by_cases equal : value = needle
      · simp only [indexOfValue, equal, if_true, Option.some.injEq] at found
        subst index
        simp [listAt?, equal]
      · simp only [indexOfValue, equal, if_false] at found
        cases located : indexOfValue needle tail with
        | none => simp [located] at found
        | some tailIndex =>
            simp [located] at found
            subst index
            simpa [listAt?] using induction located

theorem indexOfValue_complete {needle : Value} {values : List Value}
    (present : needle ∈ values) :
    ∃ index, indexOfValue needle values = some index := by
  induction values with
  | nil => simp at present
  | cons value tail induction =>
      by_cases equal : value = needle
      · exact ⟨0, by simp [indexOfValue, equal]⟩
      · have reverse : needle ≠ value := fun same => equal same.symm
        have inTail : needle ∈ tail := by simpa [reverse] using present
        obtain ⟨index, found⟩ := induction inTail
        exact ⟨index + 1, by simp [indexOfValue, equal, found]⟩

/-- Every structural Value is stored once; graph roots and Union endpoints are references. -/
def graphNodes (graph : Graph) : List Value :=
  ((graph.authority :: graph.values) ++ graph.unions.flatMap fun persistent =>
    [persistent.edge.left, persistent.edge.right])
    |>.flatMap Value.nodes
    |>.eraseDups

theorem graphNodes_contains_authority (graph : Graph) :
    graph.authority ∈ graphNodes graph := by
  simp only [graphNodes, List.mem_eraseDups, List.mem_flatMap]
  exact ⟨graph.authority, by simp, by cases graph.authority <;> simp [Value.nodes]⟩

theorem graphNodes_contains_value {graph : Graph} {value : Value}
    (present : value ∈ graph.values) : value ∈ graphNodes graph := by
  simp only [graphNodes, List.mem_eraseDups, List.mem_flatMap]
  exact ⟨value, by simp [present], by cases value <;> simp [Value.nodes]⟩

theorem graph_value_reference_sound {graph : Graph} {value : Value}
    (present : value ∈ graph.values) :
    ∃ index, indexOfValue value (graphNodes graph) = some index ∧
      listAt? (graphNodes graph) index = some value := by
  obtain ⟨index, found⟩ := indexOfValue_complete (graphNodes_contains_value present)
  exact ⟨index, found, indexOfValue_sound found⟩

def tableIndex (nodes : List Value) (value : Value) : Except String Nat :=
  match indexOfValue value nodes with
  | some index => pure index
  | none => throw "Value escaped the .egg DAG"

def storedRefToJson (reference : Authority × Nat) : Json :=
  let (authority, index) := reference
  .arr #[.str (match authority with | .semantic => "semantic" | .exact => "exact"),
    (index : Json)]

def storedNodeToJson : StoredNode → Json
  | .atom bytes =>
      match String.fromUTF8? bytes with
      | some text => .arr #[.str "atom", .str text]
      | none => .arr #[.str "bytes",
          .arr (bytes.toList.toArray.map fun byte => (byte.toNat : Json))]
  | .apply operator arguments => .arr #[
      .str "apply",
      .str (operatorName operator),
      .arr (arguments.toArray.map storedRefToJson)
    ]

def encodeRefs (nodes : List Value) : Refs → Except String (List (Authority × Nat))
  | .nil => pure []
  | .semantic value tail => do
      pure ((.semantic, ← tableIndex nodes value) :: (← encodeRefs nodes tail))
  | .exact value tail => do
      pure ((.exact, ← tableIndex nodes value) :: (← encodeRefs nodes tail))

def encodeNode (nodes : List Value) : Value → Except String StoredNode
  | .atom bytes => pure (.atom bytes)
  | .apply operator arguments => do
      pure (.apply operator (← encodeRefs nodes arguments))

def storedRefFromJson (json : Json) : Except String (Authority × Nat) := do
  let items ← json.getArr?
  match items.toList with
  | [.str "semantic", encodedIndex] => pure (.semantic, ← encodedIndex.getNat?)
  | [.str "exact", encodedIndex] => pure (.exact, ← encodedIndex.getNat?)
  | _ => throw "invalid .egg DAG reference"

def storedNodeFromJson (json : Json) : Except String StoredNode := do
  let items ← json.getArr?
  match items.toList with
  | [.str "atom", .str text] => pure (.atom text.toUTF8)
  | [.str "bytes", .arr bytes] => pure (.atom (← bytesFromJson bytes))
  | [.str "apply", .str encodedOperator, .arr encodedArguments] =>
      pure (.apply (← operatorFromName encodedOperator)
        (← encodedArguments.toList.mapM storedRefFromJson))
  | _ => throw "invalid .egg DAG node"

mutual

def resolveNode : Nat → List StoredNode → Nat → Except String Value
  | 0, _, _ => throw "cyclic or over-nested .egg DAG"
  | fuel + 1, nodes, index =>
      match listAt? nodes index with
      | none => throw "invalid .egg DAG index"
      | some (.atom bytes) => pure (.atom bytes)
      | some (.apply operator arguments) => do
          pure (.apply operator (← resolveRefs fuel nodes arguments))

def resolveRefs : Nat → List StoredNode → List (Authority × Nat) →
    Except String Refs
  | _, _, [] => pure .nil
  | 0, _, _ => throw "cyclic or over-nested .egg DAG"
  | fuel + 1, nodes, (authority, index) :: tail => do
      let value ← resolveNode fuel nodes index
      let rest ← resolveRefs fuel nodes tail
      pure <| match authority with
        | .semantic => .semantic value rest
        | .exact => .exact value rest

end

def persistentUnionFromIndices (fuel : Nat) (nodes : List StoredNode)
    (authority : Value) (json : Json) : Except String (PersistentUnion authority) := do
  let items ← json.getArr?
  match items.toList with
  | [.str "union", encodedLeft, encodedRight] =>
      let left ← resolveNode fuel nodes (← encodedLeft.getNat?)
      let right ← resolveNode fuel nodes (← encodedRight.getNat?)
      if accepted : Value.sameExactFootprint left right then
        pure (.make authority left right (Value.sameExactFootprint_sound accepted))
      else throw "persistent Union changes Exact authority"
  | _ => throw "invalid persistent Union encoding"

def graphToJson (graph : Graph) : Except String Json := do
  let nodes := graphNodes graph
  let storedNodes ← nodes.mapM (encodeNode nodes)
  let authority ← tableIndex nodes graph.authority
  let values ← graph.values.mapM (tableIndex nodes)
  let unions ← graph.unions.mapM fun persistent => do
    let left ← tableIndex nodes persistent.edge.left
    let right ← tableIndex nodes persistent.edge.right
    pure <| .arr #[.str "union", (left : Json), (right : Json)]
  pure <| .arr #[
    .str "eggshell",
    (graph.revision : Json),
    .arr (storedNodes.toArray.map storedNodeToJson),
    (authority : Json),
    .arr (values.toArray.map fun index : Nat => (index : Json)),
    .arr unions.toArray
  ]

def graphFromJson (fuel : Nat) (json : Json) : Except String Graph := do
  let items ← json.getArr?
  match items.toList with
  | [.str "eggshell", encodedRevision, .arr encodedNodes, encodedAuthority,
      .arr encodedValues, .arr encodedUnions] =>
      let revision ← encodedRevision.getNat?
      let nodes ← encodedNodes.toList.mapM storedNodeFromJson
      let authority ← resolveNode fuel nodes (← encodedAuthority.getNat?)
      let values ← encodedValues.toList.mapM fun encoded => do
        resolveNode fuel nodes (← encoded.getNat?)
      if valid : values.all Relation.wellFormed then
        let unions ← encodedUnions.toList.mapM
          (persistentUnionFromIndices fuel nodes authority)
        pure {
          authority
          revision
          values
          unions
          values_wellFormed := by
            intro value present
            exact (List.all_eq_true.mp valid) value present
        }
      else throw "stored graph contains an invalid operator application"
  | _ => throw "invalid .egg root"

def encode (graph : Graph) : Except String String :=
  return (← graphToJson graph).compress

def decode (text : String) : Except String Graph := do
  let json ← Json.parse text
  graphFromJson (text.length + 1) json

theorem decoded_values_are_well_formed {text graph}
    (_accepted : decode text = .ok graph) :
    ∀ value, value ∈ graph.values → Relation.wellFormed value :=
  graph.values_wellFormed

/-- Read and validate an existing authority before changing its access mode. -/
def loadExisting? (path : System.FilePath) : IO (Option Graph) := do
  match ← regularMetadata? path with
  | none => pure none
  | some _ =>
      let text ← IO.FS.readFile path
      let graph ← match decode text with
        | .ok graph => pure graph
        | .error message => throw (IO.userError s!"{path}: {message}")
      privateFile path
      pure (some graph)

def load (path : System.FilePath) : IO Graph := do
  match ← loadExisting? path with
  | some graph => pure graph
  | none => throw (IO.userError s!"Eggshell authority does not exist: {path}")

def saveAtomic (path : System.FilePath) (graph : Graph) : IO Unit := do
  rejectSymlinkAncestors path
  if let some parent := path.parent then
    if !(← parent.pathExists) then privateDirectory parent
  let temporary := System.FilePath.mk (path.toString ++ ".tmp")
  rejectSymlinkAncestors temporary
  if (← symlinkMetadata? temporary).isSome then
    throw (IO.userError s!"temporary authority path already exists: {temporary}")
  let encoded ← match encode graph with
    | .ok text => pure text
    | .error message => throw (IO.userError message)
  IO.FS.writeFile temporary encoded
  privateFile temporary
  IO.FS.rename temporary path
  privateFile path

def authorityForPath (path : System.FilePath) : Value :=
  .text ("egg authority " ++ path.normalize.toString)

def lockPath (path : System.FilePath) : System.FilePath :=
  .mk (path.toString ++ ".lock")

def acquireLock (path : System.FilePath) : Nat → IO Unit
  | 0 => throw (IO.userError s!"timed out waiting for {lockPath path}")
  | retries + 1 =>
      try IO.FS.createDir (lockPath path)
      catch _ =>
        IO.sleep 25
        acquireLock path retries

def withLock (path : System.FilePath) (action : IO α) : IO α := do
  rejectSymlinkAncestors path
  if let some parent := (lockPath path).parent then
    if !(← parent.pathExists) then privateDirectory parent
  acquireLock path 400
  try
    let result ← action
    IO.FS.removeDir (lockPath path)
    pure result
  catch error =>
    try IO.FS.removeDir (lockPath path) catch _ => pure ()
    throw error

def create (path : System.FilePath) : IO Graph :=
  withLock path do
    if (← regularMetadata? path).isSome then
      throw (IO.userError s!"Eggshell authority already exists: {path}")
    let graph := Graph.empty (authorityForPath path)
    saveAtomic path graph
    pure graph

structure Composite where
  values : List Value
  unions : List UnionEdge
  authorities : List Value
  origins : List (Value × Value)
  unionOrigins : List (UnionEdge × Value)

def Composite.authoritiesFor (composite : Composite) (value : Value) : List Value :=
  (composite.origins.filterMap fun (candidate, authority) =>
    if candidate = value then some authority else none
  ).eraseDups

def loadComposite (paths : List System.FilePath) : IO Composite := do
  let graphs := (← paths.mapM loadExisting?).filterMap id
  pure {
    values := graphs.flatMap (·.values) |>.eraseDups
    unions := graphs.flatMap fun graph => graph.unions.map (·.edge)
    authorities := graphs.map (·.authority)
    origins := graphs.flatMap fun graph => graph.values.map (fun value =>
      (value, graph.authority))
    unionOrigins := graphs.flatMap fun graph => graph.unions.map (fun persistent =>
      (persistent.edge, graph.authority))
  }

def commit (path : System.FilePath) (transaction : Transaction) : IO Graph :=
  withLock path do
    let current := (← loadExisting? path).getD (Graph.empty (authorityForPath path))
    match Transaction.commitIfCurrent current transaction with
    | none => throw (IO.userError "stale .egg transaction")
    | some committed =>
        saveAtomic path committed
        pure committed

def update (path : System.FilePath)
    (prepare : Graph → Except String (Transaction × α)) : IO (Graph × α) :=
  withLock path do
    let current := (← loadExisting? path).getD (Graph.empty (authorityForPath path))
    let (transaction, result) ← match prepare current with
      | .ok prepared => pure prepared
      | .error message => throw (IO.userError message)
    if transaction.isEmpty then pure (current, result)
    else
      match Transaction.commitIfCurrent current transaction with
      | none => throw (IO.userError "transaction was not built from the locked .egg head")
      | some committed =>
          saveAtomic path committed
          pure (committed, result)

end Eggshell.Persistence
