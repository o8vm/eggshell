module

public import Eggshell.PluginHooks

@[expose] public section

namespace Eggshell.Plugin

def controlUsage : String :=
  "usage: egg [init|use P|next P|next graph auto|none|VALUES|keep [EGG]|drop|" ++
  "graph [VALUES]|why|find TEXT|class VALUE|union LEFT RIGHT|split UNION|" ++
  "diff [EGG]|inspect]"

def controlSession : IO String := do
  match ← IO.getEnv "CODEX_THREAD_ID" with
  | some session => pure session
  | none => throw (IO.userError "run egg through Codex ! shell UI")

def currentConfig : IO Config.Config := do
  let cwd ← IO.currentDir
  let some config ← Config.load cwd |
    throw (IO.userError "no .eggshell.toml or global Eggshell config")
  pure config

def currentSelection (config : Config.Config) (state : ThreadState) : IO Config.Selection :=
  match Config.resolve config state.profile with
  | .ok selection => pure selection
  | .error message => throw (IO.userError message)

def statusLine (selection : Config.Selection) (state : ThreadState)
    (pending : Option PendingTurn) : String :=
  let reads := " ".intercalate (selection.read.map (·.name))
  let write := selection.write.map (·.name) |>.getD "read-only"
  let pendingText := match pending with
    | none => "none"
    | some pending =>
        let phase := if pending.finalMessage.isSome then "sealed" else "active"
        s!"{phase}:{pending.turnId.take 8}"
  s!"egg {state.profile} [{reads}] → {write} pending:{pendingText}"

def chooseTarget (config : Config.Config) (pending : PendingTurn)
    (requested : Option String) : IO System.FilePath := do
  match requested with
  | some name =>
      match config.eggs.find? (·.name == name) with
      | some egg => pure egg.path
      | none => throw (IO.userError s!"unknown egg {name}")
  | none =>
      match pending.write with
      | some path => pure (System.FilePath.mk path)
      | none => throw (IO.userError "pending turn has no write target; name one with !egg keep EGG")

def graphForSelection (selection : Config.Selection) : IO Persistence.Composite :=
  Persistence.loadComposite (selection.read.map (·.path))

def renderFind (composite : Persistence.Composite) (query : String) : String :=
  let needle := query.toLower
  let found := allNodes composite |>.filterMap fun value => do
    let text ← Matcher.atomText? value
    if text.toLower.contains needle then
      some s!"{valueKey value}  {shortValue value 500}"
    else none
  if found.isEmpty then "no matching Atom" else "\n".intercalate found

def unionKey (edge : UnionEdge) : String :=
  let left := valueEncoding edge.left
  let right := valueEncoding edge.right
  let ordered := if left ≤ right then [left.toUTF8, right.toUTF8]
    else [right.toUTF8, left.toUTF8]
  "u" ++ Blake3.hex (Blake3.digest "eggshell.union.ui".toUTF8 ordered)

def renderClass (composite : Persistence.Composite) (value : Value) : IO String := do
  match QuotientBuilder.build? (allNodes composite) composite.unions [] with
  | none => throw (IO.userError "stored Union classes failed certification")
  | some quotient =>
      let representative := quotient.canonical value
      let members := allNodes composite |>.filter fun member =>
        quotient.toEquality.same member value
      let unions := composite.unionOrigins.filterMap fun (edge, authority) =>
        if quotient.toEquality.same edge.left value ||
            quotient.toEquality.same edge.right value then
          some (s!"UNION {unionKey edge} {valueKey edge.left} = " ++
            s!"{valueKey edge.right} authority={valueKey authority}")
        else none
      let unionText := if unions.isEmpty then "" else
        "\n" ++ "\n".intercalate unions
      pure <| "CLASS representative=" ++ valueKey representative ++ "\n" ++
        "\n".intercalate (members.map fun member =>
          s!"{valueKey member}  {shortValue member 1000}") ++ unionText

def graphClosure (root : Value) : List Value := root.nodes.eraseDups

def renderRoots (roots : List Value) : String :=
  "\n".intercalate <| roots.flatMap graphClosure |>.eraseDups |>.map (fun value =>
    s!"{valueKey value}  {shortValue value 4000}")

def persistUnion (target : System.FilePath) (left right : Value) : IO UnionEdge := do
  if safe : Value.sameExactFootprint left right then
    let (_, edge) ← Persistence.update target fun graph =>
      let edge : UnionEdge := {
        left
        right
        scope := .workspace graph.authority
        exactAuthority := Value.sameExactFootprint_sound safe
      }
      let transaction := Transaction.stageUnionIfNew graph (Transaction.begin graph)
        left right (Value.sameExactFootprint_sound safe)
      pure (transaction, edge)
    pure edge
  else throw (IO.userError "Union would change Exact authority")

def splitPersistentUnion (target : System.FilePath) (key : String) : IO UnionEdge :=
  Persistence.withLock target do
    let graph ← Persistence.load target
    match graph.unions.filter (unionKey ·.edge == key) with
    | [persistent] =>
        let updated := graph.removeUnionPair persistent.edge.left persistent.edge.right
        Persistence.saveAtomic target updated
        pure persistent.edge
    | [] => throw (IO.userError s!"Union {key} is not owned by {target}")
    | _ => throw (IO.userError s!"ambiguous Union key {key}")

def control (arguments : List String) : IO String := do
  let session ← controlSession
  withSession session fun files => do
    let config ← currentConfig
    let mut state := (← (readJson? files.state : IO (Option ThreadState))).getD
      (defaultState config)
    let pending ← (readJson? files.pending : IO (Option PendingTurn))
    let selection ← currentSelection config state
    match arguments with
    | [] => pure (statusLine selection state pending)
    | ["--help"] | ["-h"] => pure controlUsage
    | ["use", profile] =>
        let _ ← match Config.resolve config profile with
          | .ok selection => pure selection
          | .error message => throw (IO.userError message)
        state := { state with profile }
        writeJson files.state state
        pure s!"egg {profile} selected"
    | ["next", profile] =>
        let _ ← match Config.resolve config profile with
          | .ok selection => pure selection
          | .error message => throw (IO.userError message)
        state := { state with nextProfile := some profile }
        writeJson files.state state
        pure s!"egg next {profile}"
    | ["next", "graph", "none"] =>
        state := { state with nextProjection := some .none }
        writeJson files.state state
        pure "egg next graph none"
    | ["next", "graph", "auto"] =>
        state := { state with nextProjection := some .automatic }
        writeJson files.state state
        pure "egg next graph auto"
    | "next" :: "graph" :: roots =>
        state := { state with nextProjection := some (.roots roots) }
        writeJson files.state state
        pure s!"egg next graph roots:{roots.length}"
    | ["drop"] =>
        removeIfExists files.pending
        pure "egg dropped staged turn"
    | ["keep"] | ["keep", _] =>
        let some pending := pending |
          throw (IO.userError "no staged turn")
        if pending.finalMessage.isNone then
          throw (IO.userError "active turn cannot be kept")
        let requested := arguments.drop 1 |>.head?
        let target ← chooseTarget config pending requested
        let promotion ← promote pending target
        state := addDeliveredGraphs state
          (promotion.outcomeRelations.map nativeHistoryKey)
        writeJson files.state state
        removeIfExists files.pending
        pure s!"egg kept {pending.turnId.take 8} → {target}"
    | ["graph"] =>
        pure <| if state.lastHandoff = "" then "no graph was sent" else state.lastHandoff
    | ["why"] =>
        pure <| if state.lastReason = "" then "no graph selection has run" else state.lastReason
    | "graph" :: roots =>
        let composite ← graphForSelection selection
        let values ← roots.mapM fun key =>
          match resolveKey composite key with
          | .ok value => pure value
          | .error message => throw (IO.userError message)
        pure (renderRoots values)
    | "find" :: query =>
        let composite ← graphForSelection selection
        pure (renderFind composite (" ".intercalate query))
    | ["class", key] =>
        let composite ← graphForSelection selection
        let value ← match resolveKey composite key with
          | .ok value => pure value
          | .error message => throw (IO.userError message)
        renderClass composite value
    | ["union", leftKey, rightKey] =>
        let target ← match selection.write with
          | some egg => pure egg.path
          | none => throw (IO.userError "current profile is read-only")
        let composite ← graphForSelection selection
        let left ← match resolveKey composite leftKey with
          | .ok value => pure value
          | .error message => throw (IO.userError message)
        let right ← match resolveKey composite rightKey with
          | .ok value => pure value
          | .error message => throw (IO.userError message)
        let edge ← persistUnion target left right
        pure s!"egg union {unionKey edge} {leftKey} = {rightKey} → {target}"
    | ["split", key] =>
        let target ← match selection.write with
          | some egg => pure egg.path
          | none => throw (IO.userError "current profile is read-only")
        let edge ← splitPersistentUnion target key
        pure s!"egg split {key} {valueKey edge.left} != {valueKey edge.right} → {target}"
    | ["inspect"] =>
        let reads := ", ".intercalate (selection.read.map fun egg =>
          s!"{egg.name}={egg.path}")
        let heads ← selection.read.mapM fun egg => do
          match ← Persistence.loadExisting? egg.path with
          | none => pure s!"{egg.name}:missing"
          | some graph => pure (s!"{egg.name}:revision={graph.revision}," ++
              s!"values={graph.values.length},unions={graph.unions.length}")
        pure (statusLine selection state pending ++ s!"\nread=[{reads}]\n" ++
          "heads=[" ++ "; ".intercalate heads ++ s!"]\nconfig={config.source}")
    | ["diff"] | ["diff", _] =>
        let some pending := pending |
          throw (IO.userError "no staged turn")
        let requested := arguments.drop 1 |>.head?
        let target ← chooseTarget config pending requested
        let graph := (← Persistence.loadExisting? target).getD
          (Graph.empty (Persistence.authorityForPath target))
        let compiled ← match compile graph pending target.toString with
          | .ok compiled => pure compiled
          | .error message => throw (IO.userError message)
        pure s!"target={target}\nbase-revision={graph.revision}\nstaged-values={compiled.transaction.stagedValues.length}\noutcomes={compiled.promotion.outcomeRelations.length}"
    | _ => throw (IO.userError controlUsage)

def eggControl (arguments : List String) : IO UInt32 := do
  if arguments = ["--help"] || arguments = ["-h"] then
    IO.println controlUsage
    return 0
  try
    IO.println (← control arguments)
    pure 0
  catch error =>
    IO.eprintln s!"egg: {error}"
    pure 1

end Eggshell.Plugin
