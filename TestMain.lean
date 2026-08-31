module

public import Eggshell.Install

@[expose] public section

open Eggshell Eggshell.Plugin

def check (condition : Bool) (message : String) : IO Unit :=
  if condition then pure () else throw (IO.userError message)

def accessMode (path : System.FilePath) : IO String := do
  let bsd ← IO.Process.output { cmd := "stat", args := #["-f", "%Lp", path.toString] }
  if bsd.exitCode == 0 then pure bsd.stdout.trimAscii.copy
  else
    let gnu ← IO.Process.output { cmd := "stat", args := #["-c", "%a", path.toString] }
    if gnu.exitCode == 0 then pure gnu.stdout.trimAscii.copy
    else throw (IO.userError s!"cannot inspect access mode for {path}")

def testRoot : System.FilePath := ".lake" / "eggshell-tests"
def testEgg : System.FilePath := testRoot / "work.egg"
def operationBoundaryEgg : System.FilePath := testRoot / "operation-boundary.egg"
def concurrentEgg : System.FilePath := testRoot / "concurrent.egg"
def unionEgg : System.FilePath := testRoot / "union.egg"
def semanticEgg : System.FilePath := testRoot / "semantic.egg"
def naturalLanguageEgg : System.FilePath := testRoot / "natural-language.egg"
def dagEgg : System.FilePath := testRoot / "dag.egg"
def transportEgg : System.FilePath := testRoot / "transport.egg"

def hookTestRoot : IO System.FilePath := do
  pure (((← IO.currentDir) / testRoot / "hook-e2e").normalize)

def prepareTestProject (root : System.FilePath) : IO Unit := do
  if ← root.pathExists then IO.FS.removeDirAll root
  IO.FS.createDirAll root
  IO.FS.writeFile (root / ".eggshell.toml") r#"default = "work"

[eggs]
project = "work.egg"

[profiles.work]
read = ["project"]
write = "project"
"#

def clean : IO Unit := do
  if ← testRoot.pathExists then IO.FS.removeDirAll testRoot
  IO.FS.createDirAll testRoot

def testProjectInit : IO Unit := do
  let root := testRoot / "project-init"
  if ← root.pathExists then IO.FS.removeDirAll root
  IO.FS.createDirAll root
  let message ← Install.initProject root
  check (message.contains ".eggshell.toml")
    "project initialization did not report its config"
  let config := root / ".eggshell.toml"
  let ignore := root / ".eggs" / ".gitignore"
  check ((← IO.FS.readFile config) = Install.projectConfig)
    "project initialization changed the canonical config"
  check ((← IO.FS.readFile ignore) = "*\n!.gitignore\n")
    "project authority is not ignored by default"
  let parsed ← Config.parseFile config
  let work ← IO.ofExcept (Config.resolve parsed "work")
  check (work.read.length = 1 && work.write.isSome)
    "initialized work profile is not a single writable authority"
  try
    let _ ← Install.initProject root
    throw (IO.userError "project initialization overwrote an existing config")
  catch error =>
    check (toString error |>.contains "already exists")
      "repeated project initialization failed for the wrong reason"
  IO.println "PASS project init creates one ignored local authority"

def testNativeWorkUnits : IO Unit := do
  let atomic : ToolEvent := {
    name := "Bash"
    useId := "compound"
    input := r#"{"command":"sed -n '1,20p' src/a.c; sed -n '30,40p' src/b.c && rg 'a;b' src"}"#
    response := r#"{"output":"observed bundle"}"#
  }
  check (canonicalToolWork atomic =
      "Bash\n" ++ atomic.input)
    "native invocation identity lost canonical JSON structure"
  let batched : ToolEvent := { atomic with
    useId := "line-batch"
    input := r#"{"command":"rg update_vsyscall kernel/time\nsed -n '1,80p' kernel/time/vsyscall.c"}"#
  }
  check (canonicalToolWork batched =
      "Bash\n" ++ batched.input)
    "one native invocation was split into adapter-invented Work"
  let firstRead : ToolEvent := { atomic with
    name := "read_file"
    input := "{\"path\":\"src/a.c\",\"offset\":0,\"limit\":20}"
  }
  let secondRead : ToolEvent := { atomic with
    name := "read_file"
    input := "{\"path\":\"src/a.c\",\"offset\":20,\"limit\":20}"
  }
  check (canonicalToolWork firstRead != canonicalToolWork secondRead)
    "native input numbers disappeared from Work identity"
  let reorderedRead : ToolEvent := { firstRead with
    input := "{\"limit\":20,\"offset\":0,\"path\":\"src/a.c\"}"
  }
  check (canonicalToolWork firstRead = canonicalToolWork reorderedRead)
    "object-key order changed canonical native Work identity"
  let query : ToolEvent := { atomic with input := "{\"query\":\"x\"}" }
  let path : ToolEvent := { atomic with input := "{\"path\":\"x\"}" }
  check (canonicalToolWork query != canonicalToolWork path)
    "JSON object keys disappeared from Work identity"
  check (canonicalJson "{\"result\":{\"value\":\"x\"}}" !=
      canonicalJson "{\"result\":[\"x\"]}")
    "JSON containers disappeared from native identity"
  check (canonicalJson "{\"message\":\"true\"}" !=
      canonicalJson "{\"message\":true}")
    "JSON value types disappeared from native identity"
  check (canonicalJson "{\"output\":\"permission denied\"}" !=
      canonicalJson "{\"error\":\"permission denied\"}")
    "native result keys disappeared from Outcome identity"
  let pending : PendingTurn := {
    sessionId := "segment-session"
    turnId := "segment-turn"
    cwd := "/repo"
    prompt := "inspect both sources"
    profile := "work"
    semanticMatcher := none
    read := []
    write := none
    handoffChars := 120000
    projection := .automatic
    tools := [batched]
  }
  let staged ← IO.ofExcept (stagedGraphValues pending)
  let outcomes := staged.filterMap OutcomeEdge.fromValue?
  let decompositions := staged.filterMap AllEdge.fromValue?
  match outcomes, decompositions with
  | [operation], [decomposition] =>
      check (decomposition.children.head? == some operation.work)
        "turn decomposition lost its observed native invocation"
  | _, _ => throw (IO.userError
      "one native invocation did not compile to one Work Outcome and one turn decomposition")
  IO.println "PASS one native invocation is exactly one observed Work"

def testPersistenceDag : IO Unit := do
  let payload := "DAG_PAYLOAD_7f93a_shared_once"
  let pending : PendingTurn := {
    sessionId := "dag-session"
    turnId := "dag-turn"
    cwd := "/repo"
    prompt := "observe two operations"
    profile := "work"
    semanticMatcher := none
    read := [dagEgg.toString]
    write := some dagEgg.toString
    handoffChars := 120000
    projection := .automatic
    tools := [{
      name := "shell"
      useId := "dag-one"
      input := "{\"command\":\"printf first\"}"
      response := "{\"output\":\"" ++ payload ++ "\"}"
    }, {
      name := "shell"
      useId := "dag-two"
      input := "{\"command\":\"printf second\"}"
      response := "{\"output\":\"" ++ payload ++ "\"}"
    }]
    finalMessage := some "both observations completed"
  }
  let _ ← Persistence.create dagEgg
  let _ ← promote pending dagEgg
  let encoded ← IO.FS.readFile dagEgg
  /- The shared semantic output is stored once. Exact occurrence identity cites
     session/turn/use-id and does not retain a second raw response copy. -/
  check ((encoded.splitOn payload).length == 2)
    "the .egg DAG duplicated a shared structural Atom"
  let graph ← Persistence.load dagEgg
  let roundTrip ← IO.ofExcept (Persistence.decode (← IO.ofExcept (Persistence.encode graph)))
  check (roundTrip.authority == graph.authority &&
      roundTrip.revision == graph.revision && roundTrip.values == graph.values &&
      roundTrip.unions.length == graph.unions.length)
    ".egg DAG round-trip changed graph authority"
  IO.println "PASS .egg persists one structural Value once and round-trips its graph"

def testPrivateStorage : IO Unit := do
  let eggDirectory := testRoot / "private-authority"
  let egg := eggDirectory / "work.egg"
  let _ ← Persistence.create egg
  check ((← accessMode eggDirectory) = "700")
    ".egg directory is not private"
  check ((← accessMode egg) = "600")
    ".egg authority is not private"
  IO.setAccessRights egg {
    user := { read := true, write := true }
    group := { read := true }
    other := { read := true }
  }
  let _ ← Persistence.load egg
  check ((← accessMode egg) = "600")
    "existing .egg authority was not hardened on load"
  let stateDirectory := testRoot / "private-state"
  let state := stateDirectory / "state.json"
  let pending := stateDirectory / "pending.json"
  writeJson state ({ profile := "work" } : ThreadState)
  writeJson pending ({
    sessionId := "private-session"
    turnId := "private-turn"
    cwd := "/repo"
    prompt := "private prompt"
    profile := "work"
    semanticMatcher := none
    read := []
    write := none
    handoffChars := 120000
    projection := .automatic
  } : PendingTurn)
  check ((← accessMode stateDirectory) = "700")
    "Plugin state directory is not private"
  check ((← accessMode state) = "600" && (← accessMode pending) = "600")
    "Plugin state or pending turn is not private"
  IO.println "PASS .egg and staged Plugin state use private access modes"

def testAuthorityPathBoundaries : IO Unit := do
  let root := testRoot / "authority-boundaries"
  IO.FS.createDirAll root
  let missing := root / "missing-read.egg"
  let composite ← Persistence.loadComposite [missing]
  check (composite.values.isEmpty && !(← missing.pathExists))
    "reading a missing authority created it"
  let executable := root / "not-an-egg"
  IO.FS.writeFile executable "not an Eggshell graph"
  IO.setAccessRights executable {
    user := { read := true, write := true, execution := true }
    group := { read := true, execution := true }
    other := { read := true, execution := true }
  }
  let malformedRejected ← try
      let _ ← Persistence.load executable
      pure false
    catch _ => pure true
  check malformedRejected "malformed authority was accepted"
  check ((← accessMode executable) = "755")
    "a malformed file was chmodded before it decoded as an authority"
  let directory := root / "not-a-file"
  IO.FS.createDirAll directory
  IO.setAccessRights directory {
    user := { read := true, write := true, execution := true }
    group := { read := true, execution := true }
    other := { read := true, execution := true }
  }
  let directoryRejected ← try
      let _ ← Persistence.load directory
      pure false
    catch _ => pure true
  check directoryRejected "directory was accepted as an authority"
  check ((← accessMode directory) = "755")
    "a directory was chmodded while probing an authority"
  let linked := root / "linked.egg"
  let link ← IO.Process.output {
    cmd := "ln"
    args := #["-s", executable.toString, linked.toString]
  }
  check (link.exitCode == 0) "test could not create an authority symlink"
  let linkRejected ← try
      let _ ← Persistence.load linked
      pure false
    catch _ => pure true
  check linkRejected "symbolic-link authority was accepted"
  check ((← accessMode executable) = "755")
    "authority loading followed a symbolic link and changed its target"
  let outside := root / "outside"
  IO.FS.createDirAll outside
  let linkedDirectory := root / "linked-directory"
  let directoryLink ← IO.Process.output {
    cmd := "ln"
    args := #["-s", outside.toString, linkedDirectory.toString]
  }
  check (directoryLink.exitCode == 0)
    "test could not create a parent-directory symlink"
  let escaped := linkedDirectory / "escaped.egg"
  let escapeRejected ← try
      let _ ← Persistence.loadComposite [escaped]
      pure false
    catch _ => pure true
  check (escapeRejected && !(← (outside / "escaped.egg").pathExists))
    "authority loading escaped through a symbolic-link parent"
  IO.println "PASS authority reads never create, follow links, or harden invalid paths"

def onlyWork (tool : ToolEvent) : IO String :=
  pure (canonicalToolWork tool)

def seed : PendingTurn := {
  sessionId := "seed-session"
  turnId := "seed-turn"
  cwd := "/linux"
  prompt := "Trace pvclock into Linux wallclock interfaces"
  profile := "work"
  semanticMatcher := none
  read := [testEgg.toString]
  write := some testEgg.toString
  handoffChars := 120000
  projection := .automatic
  tools := [{
    name := "shell"
    useId := "tool-1"
    input := "{\"command\":\"rg update_vsyscall kernel/time\"}"
    response := "{\"output\":\"opaque-before-marker\\nobserved native bytes\\nopaque-after-marker\"}"
  }, {
    name := "shell"
    useId := "tool-2"
    input := "{\"command\":\"rg pvclock_clocksource_read arch/x86/kernel/pvclock.c\"}"
    response := "{\"output\":\"opaque-before-marker\\nobserved native bytes\\nopaque-after-marker\"}"
  }]
  finalMessage := some "pvclock reaches generic timekeeping and the vDSO"
}

def testLocalUnion : IO Unit := do
  check (!Matcher.Corpus.identifyingUnit "rg" &&
      !Matcher.Corpus.identifyingUnit "nl" &&
      Matcher.Corpus.identifyingUnit "x86" &&
      Matcher.Corpus.identifyingUnit "時計")
    "transport scaffolding became an independent identity anchor"
  let _ ← Persistence.create testEgg
  let promotion ← promote seed testEgg
  check (promotion.outcomeRelations.length = 3)
    "turn compiler did not persist native invocation and parent Outcomes"
  let graph ← Persistence.load testEgg
  let workGraph := WorkGraph.fromValues graph.values
  let corpus := Matcher.Corpus.build LogicalText.logicalNormalizer workGraph
  let candidateWorks := corpus.candidates.map (·.edge.work)
  check (candidateWorks.length == 3 && candidateWorks.contains (.text seed.prompt) &&
      seed.tools.all fun tool => candidateWorks.contains (.text (canonicalToolWork tool)))
    "the candidate universe hid an Outcome owner based on its All position"
  check (corpus.candidates.length == seed.tools.length + 1 &&
      workGraph.subworks.length == seed.tools.length + 1)
    "the unified Outcome corpus lost the structural All boundary"
  check (graph.revision = 1) "promotion did not advance the .egg revision"
  check (graph.values.length = 5)
    "turn compiler duplicated structural closure instead of storing relation roots"
  let nodes := graph.values.flatMap Value.nodes
  let some firstTool := seed.tools.head? |
    throw (IO.userError "seed lost its first native operation")
  check (nodes.contains (.text (canonicalToolWork firstTool)) &&
      nodes.contains (.text firstTool.useId) &&
      !nodes.contains (.text "{\"command\":\"rg update_vsyscall kernel/time\"}"))
    "native occurrence did not keep one semantic Work plus compact exact identity"
  let selection : Config.Selection := {
    label := "work"
    semanticMatcher := none
    read := [{ name := "work", path := testEgg }]
    write := some { name := "work", path := testEgg }
    handoffChars := 120000
  }
  let query ← onlyWork {
    name := "shell"
    useId := "tool-2"
    input := "{\"command\":\"rg update_vsyscall ./kernel/time\"}"
    response := ""
  }
  let some handoff ← automaticHandoff selection query [] true |
    throw (IO.userError "stored operation was not selected")
  check (handoff.localUnions > 0 && handoff.completed > 0 &&
      handoff.blocksCurrent &&
      !handoff.coveredFragments.isEmpty &&
      handoff.text.contains "opaque-before-marker")
    "structural Outcome ownership did not replan a complete historical Operation"
  let retrievalOnly ← automaticHandoff selection query [] false
    (some "new observed native result") [] true false
  check (!retrievalOnly.any fun candidate =>
      candidate.localUnions != 0 || candidate.completed != 0 ||
        candidate.blocksCurrent)
    "retrieval-only control performed equality or work erasure"
  let hidden ← automaticHandoff { selection with handoffChars := 1 } query [] true
  check hidden.isNone
    "an Outcome hidden by the transport budget still erased current work"
  let repeated ← automaticHandoff selection query handoff.deliveredGraphs true
  check repeated.isNone
    "an unchanged Outcome subtree interrupted the same operation twice"
  let rewritten ← onlyWork {
    name := "shell"
    useId := "tool-rewritten"
    input := "{\"command\":\"rg -n update_vsyscall kernel/time\"}"
    response := ""
  }
  let repeatedRewrite ← automaticHandoff selection rewritten
    handoff.deliveredGraphs true
  check repeatedRewrite.isNone
    "a surface rewrite re-delivered the same prior fragment and Outcome owner"
  let repeatedContext ← automaticHandoff selection query handoff.deliveredGraphs false
  check repeatedContext.isNone
    "an already delivered Outcome subtree was retransmitted as context"
  check (handoff.deliveredGraphs.all fun key =>
      key.startsWith "g:" || key.startsWith "d:")
    "delivery state did not distinguish graph transport from graph control"
  let compound : ToolEvent := {
    name := "shell"
    useId := "tool-3"
    input := "{\"command\":\"rg update_vsyscall ./kernel/time; inspect new tsc calibration\"}"
    response := ""
  }
  let some partialHandoff ← automaticHandoff selection (canonicalToolWork compound) [] true |
    throw (IO.userError "contained prior work was not projected into a compound operation")
  check (partialHandoff.completed > 0 && partialHandoff.blocksCurrent &&
      partialHandoff.text.contains "opaque-before-marker")
    "a compound operation did not preserve and reuse its completed fragment"
  let stagedTool : ToolEvent := {
    name := "shell"
    useId := "staged-tool"
    input := "{\"command\":\"rg stage_unique_only\"}"
    response := "{\"output\":\"stage_unique_only.c\"}"
  }
  let stagedPending : PendingTurn := {
    seed with
    sessionId := "active-session"
    turnId := "active-turn"
    tools := [stagedTool]
    finalMessage := none
  }
  let staged ← IO.ofExcept (stagedGraphValues stagedPending)
  let beforeStageProbe ← Persistence.load testEgg
  let some activeHandoff ← automaticHandoff selection
      (← onlyWork {
        stagedTool with
        useId := "proposed-tool"
        input := "{\"command\":\"rg stage_unique_only\"}"
        response := ""
      })
      [] true none staged |
    throw (IO.userError "current-turn graph control lost a staged Outcome")
  check (activeHandoff.blocksCurrent && activeHandoff.text.contains "GRAPH DELTA")
    "current-turn Outcome was retransmitted or failed to stop duplicate Work"
  let some restoredStage ← automaticHandoff selection
      (← onlyWork {
        stagedTool with
        useId := "post-compaction-tool"
        input := "{\"command\":\"rg stage_unique_only\"}"
        response := ""
      }) [] true none staged false |
    throw (IO.userError "compaction did not restore a staged Outcome graph")
  check (restoredStage.text.contains "current staged turn" &&
      restoredStage.text.contains "already visible earlier")
    "compaction restoration lost the staged Outcome graph"
  let afterStageProbe ← Persistence.load testEgg
  check (afterStageProbe.revision = beforeStageProbe.revision)
    "run-local staged Work mutated persistent .egg authority"
  IO.println "PASS batched native Work -> Local Union -> resaturation -> one graph delta"

def testSemanticProviderTransport : IO Unit := do
  let _ ← Persistence.create semanticEgg
  let priorTool : ToolEvent := {
    name := "shell"
    useId := "semantic-tool"
    input := r#"{"command":"trace the vDSO clock_gettime realtime path"}"#
    response := r#"{"output":"時刻保持層から利用者APIへ接続した"}"#
  }
  let prior : PendingTurn := {
    seed with
    sessionId := "semantic-seed"
    turnId := "semantic-turn"
    prompt := "inspect the Linux realtime fast path"
    read := [semanticEgg.toString]
    write := some semanticEgg.toString
    tools := [priorTool]
    finalMessage := some "壁時計経路を確認した"
  }
  let _ ← promote prior semanticEgg
  let base : Config.Selection := {
    label := "semantic"
    semanticMatcher := none
    read := [{ name := "semantic", path := semanticEgg }]
    write := some { name := "semantic", path := semanticEgg }
    handoffChars := 120000
  }
  let current := "利用者空間から現在時刻を高速取得する仕組みを調査"
  let surface ← automaticHandoff base current [] false
  check surface.isNone
    "surface-only matching unexpectedly bridged disjoint languages"
  let executable ← IO.appPath
  let persisted ← Persistence.load semanticEgg
  let indexed := SemanticMatcher.outcomeWorkItems persisted.values
  check (indexed.length == 1 && indexed.head?.map (·.text) = some prior.prompt)
    "semantic provider indexed operation Work instead of only parent Turn Work"
  let retrievalCommand := [executable.toString, "semantic-provider-fixture", "retrieval"]
  SemanticMatcher.enqueueWork retrievalCommand (.text prior.prompt) prior.prompt
  let retrieval ← automaticHandoff {
    base with semanticMatcher := some retrievalCommand
  } current [] false
  let some retrieval := retrieval |
    throw (IO.userError "configured provider nominated no prior Work")
  check (retrieval.localUnions = 0 && retrieval.completed = 0 &&
      retrieval.advisory > 0 && !retrieval.blocksCurrent &&
      retrieval.text.contains "壁時計経路を確認した" &&
      !retrieval.text.contains "時刻保持層から利用者APIへ接続した")
    "semantic parent retrieval demanded an unmatched historical child"
  let some operation ← automaticHandoff base
      (canonicalToolWork { priorTool with useId := "semantic-proposal" })
      retrieval.deliveredGraphs true |
    throw (IO.userError "a demanded child Operation did not reconnect its Outcome")
  check (operation.completed > 0 && operation.blocksCurrent &&
      operation.text.contains "時刻保持層から利用者APIへ接続した" &&
      operation.deliveredGraphs.any (·.startsWith "g:") &&
      operation.deliveredGraphs.any (·.startsWith "d:"))
    "a demanded child did not transport and control its own completed Outcome"
  let repeated ← automaticHandoff base
      (canonicalToolWork { priorTool with useId := "semantic-retry" })
      (retrieval.deliveredGraphs ++ operation.deliveredGraphs) true
  check repeated.isNone
    "a directly demanded child Operation interrupted the same context epoch twice"
  IO.println "PASS semantic parent stays advisory until a child Operation is demanded"

def testNaturalLanguageSessionTransport : IO Unit := do
  let _ ← Persistence.create naturalLanguageEgg
  let priorPrompt :=
    "読書支援アプリの方針を決める。登録を必須にせず、行動追跡をせず、連続記録で利用者を急かさない。"
  let priorResult :=
    "方針はローカル優先、アカウント任意、行動分析なし、連続日数やランキングなしとする。"
  let executable ← IO.appPath
  let command := [executable.toString, "semantic-provider-fixture", "retrieval"]
  let prior : PendingTurn := {
    seed with
    sessionId := "natural-language-seed"
    turnId := "natural-language-turn"
    prompt := priorPrompt
    semanticMatcher := some command
    read := [naturalLanguageEgg.toString]
    write := some naturalLanguageEgg.toString
    tools := []
    finalMessage := none
  }
  withSession prior.sessionId fun files => do
    writeJson files.state ({ profile := "natural-language" } : ThreadState)
    writeJson files.pending prior
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "Stop"), ("session_id", prior.sessionId),
    ("turn_id", prior.turnId), ("last_assistant_message", priorResult)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionEnd"), ("session_id", prior.sessionId)])
  let persisted ← Persistence.load naturalLanguageEgg
  let indexed := SemanticMatcher.outcomeWorkItems persisted.values
  check (indexed.length == 1 && indexed.head?.map (·.text) = some priorPrompt)
    "a tool-free parent turn was not indexed as natural-language Work"
  let selection : Config.Selection := {
    label := "natural-language"
    semanticMatcher := some command
    read := [{ name := "natural-language", path := naturalLanguageEgg }]
    write := some { name := "natural-language", path := naturalLanguageEgg }
    handoffChars := 120000
  }
  let current :=
    "以前決めた読書支援アプリのプライバシー方針に沿ってオンボーディングを設計する。"
  let some first ← automaticHandoff selection current [] false |
    throw (IO.userError "an independent session received no prior natural-language turn")
  check (first.completed = 0 && first.advisory > 0 && !first.blocksCurrent &&
      first.text.contains priorPrompt &&
      first.text.contains priorResult)
    "natural-language input and outcome were not transported as advisory graph"
  let repeated ← automaticHandoff selection current first.deliveredGraphs false
  check repeated.isNone
    "one session received the same natural-language graph twice before compaction"
  let some independent ← automaticHandoff selection current [] false |
    throw (IO.userError "a second independent session could not receive the shared graph")
  check (independent.text.contains priorPrompt && independent.text.contains priorResult)
    "independent-session delivery lost the prior input or outcome"
  IO.println "PASS tool-free Japanese turn crosses independent sessions once per context epoch"

def testGroundedOutcomeTransport : IO Unit := do
  let irrelevant := String.ofList (List.replicate 20000 'x')
  let relevant := "generic timekeeping vdso clock_gettime syscall."
  let result := irrelevant ++ "\n" ++ relevant ++ "\n" ++ irrelevant
  let tool : ToolEvent := {
    name := "Bash"
    useId := "projection-tool"
    input := r#"{"command":"generic timekeeping vdso clock_gettime syscall"}"#
    response := Lean.Json.mkObj [("output", .str result)] |>.compress
  }
  let prior : PendingTurn := {
    seed with
    sessionId := "projection-seed"
    turnId := "projection-turn"
    prompt := "inspect one native result"
    read := [transportEgg.toString]
    write := some transportEgg.toString
    tools := [tool]
    finalMessage := some "native result recorded"
  }
  let _ ← Persistence.create transportEgg
  let _ ← promote prior transportEgg
  let persisted ← Persistence.load transportEgg
  let encoded ← IO.ofExcept (Persistence.encode persisted)
  check (encoded.contains irrelevant)
    "the durable .egg owner lost unprojected Outcome source"
  let owner ← match (WorkGraph.fromValues persisted.values).outcomes.find?
      (fun edge => edge.work == .text (canonicalToolWork tool)) with
    | some edge => pure edge
    | none => throw (IO.userError "Outcome owner was not persisted")
  let selection : Config.Selection := {
    label := "projection"
    semanticMatcher := none
    read := [{ name := "transport", path := transportEgg }]
    write := some { name := "transport", path := transportEgg }
    handoffChars := 120000
  }
  let some handoff ← automaticHandoff selection
      (canonicalToolWork tool) [] true |
    throw (IO.userError "grounded parent graph was not selected")
  check (handoff.text.contains relevant && handoff.text.contains irrelevant &&
      handoff.text.contains (relationKey owner.relation))
    "complete Work identity did not transport its complete Outcome"
  let advisoryTool : ToolEvent := {
    tool with
    useId := "projection-advisory"
    input := r#"{"command":"generic timekeeping vdso"}"#
    response := ""
  }
  let some advisory ← automaticHandoff selection
      (canonicalToolWork advisoryTool) [] true |
    throw (IO.userError "grounded advisory fragment was not selected")
  check (advisory.blocksCurrent && advisory.completed > 0 &&
      advisory.text.contains relevant &&
      !advisory.text.contains irrelevant &&
      advisory.text.contains "GROUNDED OUTCOME" &&
      advisory.text.contains (relationKey owner.relation))
    "a relevant fragment did not transport its provenance-bearing projection"
  IO.println "PASS matched fragments transport grounded Outcome projections"

def testOperationBoundaryLookup : IO Unit := do
  let _ ← Persistence.create operationBoundaryEgg
  let prior : PendingTurn := {
    seed with
    sessionId := "boundary-seed"
    turnId := "boundary-turn"
    read := [operationBoundaryEgg.toString]
    write := some operationBoundaryEgg.toString
    tools := [{
      name := "Bash"
      useId := "prior-read"
      input := r#"{"command":"sed -n '1,180p' arch/x86/kernel/kvm.c; rg clocksource_select kernel/time"}"#
      response := r#"{"output":"arch/x86/kernel/kvm.c lines 1-180 contain kvm_guest_init and kvmclock_init\nkernel/time contains clocksource_select"}"#
    }]
  }
  let _ ← promote prior operationBoundaryEgg
  let persisted ← Persistence.load operationBoundaryEgg
  check ((WorkGraph.fromValues persisted.values).outcomes.length = 2)
    "one observed native invocation did not become one persistent Work outcome"
  let selection : Config.Selection := {
    label := "work"
    semanticMatcher := none
    read := [{ name := "work", path := operationBoundaryEgg }]
    write := some { name := "work", path := operationBoundaryEgg }
    handoffChars := 120000
  }
  let proposed : ToolEvent := {
    name := "Bash"
    useId := "proposed-read"
    input := r#"{"command":"sed -n '840,1030p' arch/x86/kernel/kvm.c; sed -n '1,180p' arch/x86/include/asm/kvm_para.h; sed -n '1,180p' arch/x86/include/asm/hypervisor.h"}"#
    response := ""
  }
  let some handoff ← automaticHandoff selection
      (canonicalToolWork proposed) [] true |
    throw (IO.userError "a related prior observation was not delivered as advice")
  check (!handoff.blocksCurrent && handoff.completed = 0 &&
      handoff.advisory > 0 &&
      handoff.text.contains "OUTCOME")
    "a new advisory Local Union did not remain visible without erasing Work"
  let retry ← automaticHandoff selection (canonicalToolWork proposed)
    handoff.deliveredGraphs true
  check retry.isNone
    "the same advisory Outcome subtree was delivered more than once"
  let connectedPartial : ToolEvent := {
    name := "Bash"
    useId := "connected-partial"
    input := r#"{"command":"rg -n clocksource_select kernel/time; inspect new acpi_pm work"}"#
    response := ""
  }
  let some partialAdvice ← automaticHandoff selection
      (canonicalToolWork connectedPartial) [] true |
    throw (IO.userError "a distinctively anchored prior fragment was not delivered")
  check (partialAdvice.completed > 0 && partialAdvice.advisory = 0 &&
      partialAdvice.blocksCurrent && !partialAdvice.coveredFragments.isEmpty)
    "a complete grounded native clause did not erase only its matching Work"
  let repeatedPartial ← automaticHandoff selection
    (canonicalToolWork connectedPartial) partialAdvice.deliveredGraphs true
  check repeatedPartial.isNone
    "one advisory Outcome owner was delivered twice in one context epoch"
  let equivalent : ToolEvent := {
    name := "Bash"
    useId := "equivalent-read"
    input := r#"{"command":"rg clocksource_select ./kernel/time; sed -n '1,180p' ./arch/x86/kernel/kvm.c"}"#
    response := ""
  }
  let equivalentHandoff ← automaticHandoff selection
    (canonicalToolWork equivalent) [] true
  check (equivalentHandoff.any (·.blocksCurrent))
    "equivalent native invocation spelling did not reuse the prior Outcome"
  let differentRange ← onlyWork {
    name := "Bash"
    useId := "different-range"
    input := r#"{"command":"sed -n '181,260p' arch/x86/kernel/kvm.c"}"#
    response := ""
  }
  /-
  A different grounded result projection from the same durable owner is new
  graph progress. Advisory evidence is transported once but cannot checkpoint
  native Work.
  -/
  let some rangeAdvice ← automaticHandoff selection differentRange
    partialAdvice.deliveredGraphs true
    | throw (IO.userError "new grounded evidence from one owner was suppressed")
  check (!rangeAdvice.blocksCurrent &&
      rangeAdvice.text.contains "GROUNDED OUTCOME")
    "a new advisory Outcome projection was not transported without erasing Work"
  let repeatedRange ← automaticHandoff selection differentRange
    (partialAdvice.deliveredGraphs ++ rangeAdvice.deliveredGraphs) true
  check repeatedRange.isNone
    "the same grounded Outcome projection was transported twice"
  let sequencedClause ← onlyWork {
    name := "Bash"
    useId := "sequence-clause"
    input := r#"{"command":"kernel/time clocksource_select rg"}"#
    response := ""
  }
  let sequenceHandoff ← automaticHandoff selection sequencedClause [] false
    (some "new observed native result")
  check (sequenceHandoff.any (fun handoff =>
      !handoff.blocksCurrent && handoff.completed > 0 &&
        handoff.localUnions > 0 && handoff.text.contains "OUTCOME"))
    "an orderless equivalent Work failed to saturate without controlling a completed call"
  IO.println "PASS run-local fragments reuse one persistent native Work"

def testWholeSliceBudget : IO Unit := do
  let slices := ["slice-too-large", "ok"]
  let fitted := fitWholeSlices 2 id slices
  check (fitted = ["ok"])
    "handoff budget truncated a semantic slice instead of omitting it whole"
    let empty ← automaticHandoff {
      label := "off"
      semanticMatcher := none
      read := []
      write := none
      handoffChars := 120000
    } "unmatched prompt" [] false
  check empty.isNone
    "an empty authority set produced invented handoff context"
  IO.println "PASS handoff preserves whole graph slices and invents no empty context"

def concurrentSeed (name command : String) : PendingTurn := {
  seed with
  sessionId := "session-" ++ name
  turnId := "turn-" ++ name
  prompt := "parallel work " ++ name
  tools := [{
    name := "shell"
    useId := "tool-" ++ name
    input := Lean.Json.mkObj [("command", command)] |>.compress
    response := Lean.Json.mkObj [("output", name)] |>.compress
  }]
  finalMessage := some ("finished " ++ name)
}

def waitPromotion (task : Task (Except IO.Error Promotion)) : IO Unit := do
  match ← IO.wait task with
  | .ok _ => pure ()
  | .error error => throw error

def testConcurrentPromotion : IO Unit := do
  let _ ← Persistence.create concurrentEgg
  let first ← IO.asTask (promote (concurrentSeed "alpha" "rg alpha") concurrentEgg)
    .dedicated
  let second ← IO.asTask (promote (concurrentSeed "beta" "rg beta") concurrentEgg)
    .dedicated
  waitPromotion first
  waitPromotion second
  let graph ← Persistence.load concurrentEgg
  let nodes := graph.values.flatMap Value.nodes
  check (graph.revision = 2) "concurrent sessions lost an atomic promotion"
  check (nodes.contains (.text "parallel work alpha"))
    "first concurrent session disappeared"
  check (nodes.contains (.text "parallel work beta"))
    "second concurrent session disappeared"
  IO.println "PASS concurrent sessions serialize one .egg without lost work"

def testUnionSuppression : IO Unit := do
  let _ ← Persistence.create unionEgg
  let left := Value.text "inspect wallclock"
  let right := Value.text "inspect realtime"
  have exact : Value.SameExactFootprint left right := by
    intro occurrence
    change occurrence ∈ [] ↔ occurrence ∈ []
    rfl
  let (first, _) ← Persistence.update unionEgg fun graph =>
    pure (Transaction.stageUnionIfNew graph (Transaction.begin graph)
      left right exact, ())
  let (second, _) ← Persistence.update unionEgg fun graph =>
    pure (Transaction.stageUnionIfNew graph (Transaction.begin graph)
      right left (Value.sameExactFootprint_symm exact), ())
  check (first.unions.length = 1) "first persistent Union was not stored"
  check (second.unions.length = 1) "redundant persistent Union was stored"
  check (second.revision = first.revision) "redundant Union advanced authority revision"
  let persistent ← match second.unions with
    | [persistent] => pure persistent
    | _ => throw (IO.userError "expected one persistent Union")
  let key := Plugin.unionKey persistent.edge
  let removed ← Plugin.splitPersistentUnion unionEgg key
  let split ← Persistence.load unionEgg
  check (removed.samePair left right) "split removed the wrong Union"
  check split.unions.isEmpty "split retained its named Union"
  check (split.values = second.values) "split changed graph data"
  check (split.revision = second.revision + 1) "split did not advance authority revision"
  IO.println "PASS persistent Union suppresses duplicates and supports exact correction"

def testConfig : IO Unit := do
  let parsed ← Config.parse (testRoot / "config.toml") r#"
default = "work"
semantic_matcher = ["cpu-matcher", "--model", "tiny"]
[eggs]
project = "memory#shared.egg" # comment outside the quoted path
[profiles.work]
read = ["project",]
write = "project"
local_union = false
"#
  check parsed.defaultWasSet "explicit default profile was lost"
  check (parsed.semanticMatcher = some ["cpu-matcher", "--model", "tiny"])
    "configured semantic matcher command was not preserved"
  check parsed.semanticMatcherWasSet
    "explicit semantic matcher was mistaken for the built-in default"
  check (match Config.admitProject parsed with | .error _ => true | .ok _ => false)
    "project config was allowed to execute a custom semantic matcher"
  let work ← IO.ofExcept (Config.resolve parsed "work")
  check (!work.localUnion)
    "retrieval-only profile did not disable run-local equality"
  check (parsed.eggs.head?.map (·.path.toString.endsWith "memory#shared.egg") = some true)
    "quoted # was parsed as a TOML comment"
  let base : Config.Config := {
    source := "global.toml"
    defaultProfile := "research"
    defaultWasSet := true
  }
  let overlay : Config.Config := {
    source := "project.toml"
    defaultProfile := "work"
    defaultWasSet := true
  }
  check ((Config.merge base overlay).defaultProfile = "work")
    "explicit project default=work did not override global default"
  let automatic ← Config.parse (testRoot / "automatic.toml") r#"
[eggs]
project = "project.egg"
[profiles.work]
read = ["project"]
"#
  check (!automatic.semanticMatcherWasSet && automatic.semanticMatcher.isNone)
    "omitted semantic matcher did not retain built-in-default intent"
  let disabled ← Config.parse (testRoot / "disabled.toml") r#"
semantic_matcher = false
[eggs]
project = "project.egg"
[profiles.work]
read = ["project"]
"#
  check (disabled.semanticMatcherWasSet && disabled.semanticMatcher.isNone)
    "explicit semantic matcher opt-out was not preserved"
  check (match Config.admitProject disabled with | .ok _ => true | .error _ => false)
    "project config could not safely disable semantic retrieval"
  let escaped ← Config.parse (testRoot / "project-boundary" / ".eggshell.toml") r#"
[eggs]
project = "../outside.egg"
[profiles.work]
read = ["project"]
write = "project"
"#
  check (match Config.admitProject escaped with | .error _ => true | .ok _ => false)
    "project config could escape its repository authority root"
  let borrowed ← Config.parse (testRoot / "project-borrow" / ".eggshell.toml") r#"
[profiles.work]
read = ["global"]
"#
  check (match Config.admitProject borrowed with | .error _ => true | .ok _ => false)
    "project profile could select a globally declared authority"
  let foreignDefault ← Config.parse
      (testRoot / "project-default" / ".eggshell.toml") r#"
default = "global"
[profiles.work]
read = []
"#
  check (match Config.admitProject foreignDefault with
    | .error _ => true | .ok _ => false)
    "project default could select a globally declared profile"
  let inherited := Config.merge parsed automatic
  check (inherited.semanticMatcher = parsed.semanticMatcher &&
      inherited.semanticMatcherWasSet)
    "project omission erased a configured global semantic matcher"
  let optedOut := Config.merge parsed disabled
  check (optedOut.semanticMatcher.isNone && optedOut.semanticMatcherWasSet)
    "project opt-out did not override a configured global semantic matcher"
  let hook := Lean.Json.mkObj [("cwd", "/project")]
  let attached := Plugin.Daemon.attachClientConfig hook (some "/project/explicit.toml")
  check (Plugin.optionalString attached "_eggshell_config" =
      some "/project/explicit.toml")
    "hook client did not carry its per-session authority configuration"
  check (Plugin.Daemon.attachClientConfig hook none == hook)
    "hook client mutated requests without an explicit configuration"
  let projectRoot := testRoot / "project-matcher-rejection"
  IO.FS.createDirAll projectRoot
  IO.FS.writeFile (projectRoot / ".eggshell.toml") r#"
semantic_matcher = ["sh", "-c", "touch should-never-run"]
[eggs]
project = "work.egg"
[profiles.work]
read = ["project"]
"#
  try
    let _ ← Config.loadWith projectRoot none
    throw (IO.userError "auto-discovered project matcher command was admitted")
  catch error =>
    check (toString error |>.contains "cannot execute semantic_matcher")
      "auto-discovered project matcher failed for the wrong reason"
  IO.println "PASS profile merge, TOML comments, and per-session daemon config"

def testMiniLMDefault : IO Unit := do
  let home := testRoot / "minilm-home"
  let pluginData := testRoot / "minilm-plugin-data"
  let paths := MiniLM.layout home pluginData
  let python := MiniLM.unixPython paths
  if let some parent := python.parent then IO.FS.createDirAll parent
  IO.FS.writeFile python ""
  IO.FS.writeFile paths.provider MiniLM.providerSource
  let some command ← MiniLM.command home pluginData |
    throw (IO.userError "installed MiniLM runtime was not selected by default")
  check (command.head? = some python.toString &&
      command.contains paths.provider.toString &&
      command.contains paths.vectors.toString &&
      command.contains MiniLM.model)
    "default MiniLM command escaped its private runtime or Plugin cache"
  let absent ← MiniLM.command (testRoot / "absent-home") pluginData
  check absent.isNone "missing MiniLM runtime fabricated a provider command"
  IO.println "PASS installed MiniLM is the zero-config semantic default"

def testMatcherScale : IO Unit := do
  let some raw ← IO.getEnv "EGGSHELL_TEST_SCALE" | return
  let some count := raw.toNat? | throw (IO.userError "invalid EGGSHELL_TEST_SCALE")
  let values := (List.range count).map fun ordinal =>
    let work := Value.text s!"inspect unique-{ordinal} alpha beta gamma"
    let outcome := Value.text s!"observed unique-{ordinal}"
    (OutcomeEdge.make work outcome [] (by simp)
      (by simp [maxOutcomeObservations])).relation
  let current := s!"inspect unique-{count - 1} alpha beta gamma"
  let started ← IO.monoNanosNow
  let graph := WorkGraph.fromValues values
  let corpus := Matcher.Corpus.build LogicalText.logicalNormalizer graph
  let prepared ← IO.monoNanosNow
  let quotient := QuotientBuilder.build? ((.text current) :: values) [] []
  check quotient.isSome "scaled quotient failed to certify"
  let quotientReady ← IO.monoNanosNow
  let hits := quotient.toList.flatMap fun quotient =>
    Matcher.findIn LogicalText.logicalNormalizer quotient corpus
      (.text current) current
  check (!hits.isEmpty) "scaled corpus failed to nominate the matching Outcome"
  let matched ← IO.monoNanosNow
  let discovery := Matcher.discoverIn? LogicalText.logicalNormalizer
    (.text current) values [] graph corpus current
  check discovery.isSome "scaled matcher failed to saturate"
  let elapsed ← IO.monoNanosNow
  IO.println (s!"PASS {count} Outcome prepare={(prepared - started) / 1000000}ms " ++
    s!"quotient={(quotientReady - prepared) / 1000000}ms " ++
    s!"match={(matched - quotientReady) / 1000000}ms " ++
    s!"fixpoint={(elapsed - matched) / 1000000}ms")

def hookJson (text : String) : IO Lean.Json :=
  match Lean.Json.parse text with
  | .ok json => pure json
  | .error message => throw (IO.userError message)

def testPluginBundle : IO Unit := do
  let manifest ← IO.FS.readFile "plugins/eggshell/.codex-plugin/plugin.json"
  let hooks ← IO.FS.readFile "plugins/eggshell/hooks/hooks.json"
  let manifestJson ← hookJson manifest
  let hooksJson ← hookJson hooks
  let embeddedManifest ← hookJson Eggshell.Install.pluginManifest
  let embeddedHooks ← hookJson Eggshell.Install.hooksManifest
  check (manifestJson == embeddedManifest) "installed and checked-in plugin manifests diverged"
  check (hooksJson == embeddedHooks) "installed and checked-in hook manifests diverged"
  check (manifestJson.getObjValD "name" == "eggshell") "plugin name is invalid"
  check (hooksJson.getObjValD "hooks" != Lean.Json.null) "plugin has no hooks"
  IO.println "PASS checked-in and installed Plugin bundle are one definition"

def testInstallerOwnership : IO Unit := do
  let foreignRoot := testRoot / "foreign-plugin"
  let foreignLauncher := testRoot / "foreign-egg"
  IO.FS.createDirAll foreignRoot
  IO.FS.writeFile (foreignRoot / "user-data") "keep"
  try
    Install.validateManagedPaths foreignRoot foreignLauncher
    throw (IO.userError "installer admitted an unowned Plugin directory")
  catch error =>
    check (toString error |>.contains "unowned Plugin directory")
      "unowned Plugin directory failed for the wrong reason"
  check (← (foreignRoot / "user-data").pathExists)
    "installer ownership check deleted foreign data"

  let ownedRoot := testRoot / "owned-plugin"
  let ownedLauncher := testRoot / "owned-egg"
  IO.FS.createDirAll (ownedRoot / ".codex-plugin")
  IO.FS.createDirAll (ownedRoot / "bin")
  IO.FS.writeFile (ownedRoot / ".codex-plugin" / "plugin.json") Install.pluginManifest
  IO.FS.writeBinFile (ownedRoot / "bin" / "egg") "owned-binary".toUTF8
  IO.FS.writeBinFile ownedLauncher "owned-binary".toUTF8
  Install.validateManagedPaths ownedRoot ownedLauncher
  IO.FS.writeBinFile ownedLauncher "foreign-binary".toUTF8
  try
    Install.validateManagedPaths ownedRoot ownedLauncher
    throw (IO.userError "installer admitted an unowned launcher")
  catch error =>
    check (toString error |>.contains "unowned launcher")
      "unowned launcher failed for the wrong reason"

  let marketplace := testRoot / "marketplace.json"
  let foreignEntry := Lean.Json.mkObj [
    ("name", "eggshell"),
    ("source", Lean.Json.mkObj [("source", "github"), ("repo", "someone/else")])
  ]
  let foreignDocument := Lean.Json.mkObj [
    ("name", "personal"),
    ("plugins", .arr #[foreignEntry])
  ]
  IO.FS.writeFile marketplace foreignDocument.pretty
  let before ← IO.FS.readFile marketplace
  try
    let _ ← Install.updateMarketplace marketplace true
    throw (IO.userError "installer replaced an unowned marketplace entry")
  catch error =>
    check (toString error |>.contains "unowned marketplace entry")
      "unowned marketplace entry failed for the wrong reason"
  check ((← IO.FS.readFile marketplace) = before)
    "marketplace collision modified user data"
  let other := Lean.Json.mkObj [("name", "other")]
  IO.FS.writeFile marketplace (Lean.Json.mkObj [
    ("name", "personal"),
    ("plugins", .arr #[other, Install.marketplaceEntry])
  ]).pretty
  let _ ← Install.updateMarketplace marketplace false
  let cleaned ← hookJson (← IO.FS.readFile marketplace)
  check (Install.marketplacePlugins cleaned == [other])
    "uninstall removed a marketplace entry it did not own"
  IO.println "PASS installer replaces only owned paths and marketplace entries"

def testHooks : IO Unit := do
  let root ← dataRoot
  if ← root.pathExists then IO.FS.removeDirAll root
  let hookRoot ← hookTestRoot
  prepareTestProject hookRoot
  let launcher := hookRoot / "egg"
  Install.copyExecutable ((← IO.currentDir) / ".lake" / "build" / "bin" / "eggshell")
    launcher
  let cli ← IO.Process.output {
    cmd := launcher.toString
    cwd := some hookRoot
    env := #[("CODEX_THREAD_ID", some "egg-entrypoint-test")]
  }
  check (cli.exitCode == 0 &&
      cli.stdout.startsWith "egg work [project] → project pending:none")
    "installed egg executable did not enter the control CLI"
  let help ← IO.Process.output { cmd := launcher.toString, args := #["--help"] }
  check (help.exitCode == 0 && help.stdout.startsWith "usage: egg ")
    "installed egg executable did not expose standalone help"
  let hookEgg := hookRoot / "work.egg"
  let cwd := hookRoot.toString
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-one"), ("cwd", cwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-one"),
    ("turn_id", "turn-one"), ("cwd", cwd), ("prompt", "Trace pvclock into wallclock")])
  let parentFiles ← sessionFiles "session-one"
  let some parentPending ← (readJson? parentFiles.pending : IO (Option PendingTurn)) |
    throw (IO.userError "hook did not stage the parent-project turn")
  check (parentPending.write == some hookEgg.toString)
    "the parent session did not snapshot its project-local .egg"
  let cliPending ← IO.Process.output {
    cmd := launcher.toString
    cwd := some hookRoot
    env := #[
      ("CODEX_THREAD_ID", some "session-one"),
      ("PLUGIN_DATA", some (hookRoot / "host-only-plugin-data").toString)
    ]
  }
  check (cliPending.exitCode == 0 && cliPending.stdout.contains "pending:active:turn-one")
    "hook-only PLUGIN_DATA split staged state from the !egg CLI"

  let nestedRoot := hookRoot / "nested-project"
  prepareTestProject nestedRoot
  let nestedCwd := nestedRoot.toString
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-nested"),
    ("cwd", nestedCwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-nested"),
    ("turn_id", "turn-nested"), ("cwd", nestedCwd),
    ("prompt", "Inspect the nested project")])
  let nestedFiles ← sessionFiles "session-nested"
  let some nestedPending ← (readJson? nestedFiles.pending : IO (Option PendingTurn)) |
    throw (IO.userError "hook did not stage the nested-project turn")
  let nestedEgg := nestedRoot / "work.egg"
  check (nestedPending.write == some nestedEgg.toString &&
      nestedPending.write != parentPending.write)
    "shared control state collapsed distinct nested-project .egg selections"
  removeIfExists nestedFiles.pending
  check (!(← hookEgg.pathExists))
    "a read path was created before the first staged turn was promoted"
  let _ ← dispatchHook (← hookJson "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"session-one\",\"turn_id\":\"turn-one\",\"tool_name\":\"shell\",\"tool_use_id\":\"tool-one\",\"tool_input\":{\"command\":\"rg update_vsyscall kernel/time\"},\"tool_response\":{\"output\":\"kernel/time/vsyscall.c update_vsyscall\"}}")
  let _ ← dispatchHook (← hookJson "{\"hook_event_name\":\"Stop\",\"session_id\":\"session-one\",\"turn_id\":\"turn-one\",\"last_assistant_message\":\"pvclock joins generic timekeeping\"}")
  let _ ← dispatchHook (← hookJson "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"session-one\"}")
  check (← hookEgg.pathExists)
    "the first kept turn did not create its write authority"
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-two"), ("cwd", cwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-two"),
    ("turn_id", "turn-two"), ("cwd", cwd), ("prompt", "Trace TSC into wallclock")])
  let preTool ← hookJson "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-two\",\"turn_id\":\"turn-two\",\"tool_name\":\"shell\",\"tool_use_id\":\"tool-two\",\"tool_input\":{\"command\":\"rg update_vsyscall ./kernel/time\"}}"
  let first ← dispatchHook preTool
  check (first.contains "permissionDecision")
    "independent session did not receive completed prior operation"
  check (first.contains "Replan the call" && first.contains "completed prior native Work")
    "one-shot operation replanning was not explained to the agent"
  let second ← dispatchHook preTool
  check (!second.contains "permissionDecision")
    "an unchanged Outcome subtree triggered twice before compaction"
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"session-two\",\"turn_id\":\"turn-two\",\"tool_name\":\"shell\",\"tool_use_id\":\"tool-two\",\"tool_input\":{\"command\":\"rg update_vsyscall ./kernel/time\"},\"tool_response\":{\"output\":\"kernel/time/vsyscall.c update_vsyscall\"}}")
  let _ ← dispatchHook (← hookJson "{\"hook_event_name\":\"PostCompact\",\"session_id\":\"session-two\"}")
  let restored ← dispatchHook preTool
  check (restored.contains "permissionDecision")
    "compaction did not make lost graph eligible for restoration"
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-three"), ("cwd", cwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-three"),
    ("turn_id", "turn-three"), ("cwd", cwd), ("prompt", "Inspect an unrelated clock")])
  let postTool ← hookJson "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"session-three\",\"turn_id\":\"turn-three\",\"tool_name\":\"shell\",\"tool_use_id\":\"tool-three\",\"tool_input\":{\"command\":\"rg update_vsyscall ./kernel/time\"},\"tool_response\":{\"output\":\"kernel/time/vsyscall.c update_vsyscall\"}}"
  let progressed ← dispatchHook postTool
  check (progressed.contains "additionalContext" &&
      !progressed.contains "permissionDecision")
    "PostToolUse did not deliver newly connected graph data as context"
  let sessionThree ← sessionFiles "session-three"
  let some stateThree ← (readJson? sessionThree.state : IO (Option ThreadState)) |
    throw (IO.userError "PostToolUse did not persist delivery progress")
  check (stateThree.lastReason.contains "blocks-current=false")
    "PostToolUse was recorded as a PreTool operation erasure"
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-four"), ("cwd", cwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-four"),
    ("turn_id", "turn-four"), ("cwd", cwd), ("prompt", "Inspect an unrelated clock")])
  let completedAfterAdvisoryBudget ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-four\",\"turn_id\":\"turn-four\",\"tool_name\":\"shell\",\"tool_use_id\":\"tool-four\",\"tool_input\":{\"command\":\"rg update_vsyscall ./kernel/time\"}}")
  check (completedAfterAdvisoryBudget.contains "permissionDecision")
    "an earlier delta incorrectly consumed the later graph transport budget"
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-five"), ("cwd", cwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-five"),
    ("turn_id", "turn-five"), ("cwd", cwd), ("prompt", "Inspect a unique parallel probe")])
  let firstParallel ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-five\",\"turn_id\":\"turn-five\",\"tool_name\":\"shell\",\"tool_use_id\":\"parallel-one\",\"tool_input\":{\"command\":\"printf eggshell_unique_parallel_probe_7f9a\"}}")
  check (!firstParallel.contains "permissionDecision")
    "a new native Work was rejected before execution"
  let duplicateParallel ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-five\",\"turn_id\":\"turn-five\",\"tool_name\":\"shell\",\"tool_use_id\":\"parallel-two\",\"tool_input\":{\"command\":\"printf eggshell_unique_parallel_probe_7f9a\"}}")
  check (!duplicateParallel.contains "permissionDecision")
    "an unclosed native occurrence incorrectly blocked a later proposal"
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"session-five\",\"turn_id\":\"turn-five\",\"tool_name\":\"shell\",\"tool_use_id\":\"parallel-one\",\"tool_input\":{\"command\":\"printf eggshell_unique_parallel_probe_7f9a\"},\"tool_response\":{\"output\":\"eggshell_unique_parallel_probe_7f9a\"}}")
  let sessionFive ← sessionFiles "session-five"
  let some pendingFive ← (readJson? sessionFive.pending : IO (Option PendingTurn)) |
    throw (IO.userError "parallel test lost its staged turn")
  check (pendingFive.inFlight.length = 1 && pendingFive.tools.length = 1)
    "PostToolUse did not close exactly its observed native occurrence"
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"Stop\",\"session_id\":\"session-five\",\"turn_id\":\"turn-five\",\"last_assistant_message\":\"one occurrence completed and one lacked a terminal hook\"}")
  let some sealedFive ← (readJson? sessionFive.pending : IO (Option PendingTurn)) |
    throw (IO.userError "Stop lost the staged turn with a missing terminal hook")
  check (sealedFive.inFlight.isEmpty && sealedFive.tools.length = 1)
    "Stop did not discard the unobserved occurrence"
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"), ("session_id", "session-six"), ("cwd", cwd)])
  let _ ← dispatchHook (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"), ("session_id", "session-six"),
    ("turn_id", "turn-six"), ("cwd", cwd),
    ("prompt", "Inspect two hook-delivery probes")])
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-six\",\"turn_id\":\"turn-six\",\"tool_name\":\"shell\",\"tool_use_id\":\"observed-six\",\"tool_input\":{\"command\":\"printf observed_hook_result_3a72\"}}")
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"session-six\",\"turn_id\":\"turn-six\",\"tool_name\":\"shell\",\"tool_use_id\":\"missing-six\",\"tool_input\":{\"command\":\"printf unobserved_hook_result_91ce\"}}")
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"session-six\",\"turn_id\":\"turn-six\",\"tool_name\":\"shell\",\"tool_use_id\":\"observed-six\",\"tool_input\":{\"command\":\"printf observed_hook_result_3a72\"},\"tool_response\":{\"output\":\"observed_hook_result_3a72\"}}")
  /- Codex Stop may omit `turn_id`; the session's sole staged turn is unambiguous. -/
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"Stop\",\"session_id\":\"session-six\",\"last_assistant_message\":\"completed with one observed native result\"}")
  let sessionSix ← sessionFiles "session-six"
  let some sealedSix ← (readJson? sessionSix.pending : IO (Option PendingTurn)) |
    throw (IO.userError "Stop discarded the fail-soft staged turn")
  check (sealedSix.inFlight.isEmpty && sealedSix.tools.length = 1 &&
      sealedSix.finalMessage.isSome)
    "Stop did not discard only the unresolved reservation"
  let _ ← dispatchHook (← hookJson
    "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"session-six\"}")
  check (!( ← sessionSix.pending.pathExists))
    "fail-soft turn did not promote its observed work"
  let failSoftGraph ← Persistence.load hookEgg
  let failSoftNodes := failSoftGraph.values.flatMap Value.nodes
  let observedTool : ToolEvent := {
    name := "shell"
    useId := "observed-six"
    input := r#"{"command":"printf observed_hook_result_3a72"}"#
    response := r#"{"output":"observed_hook_result_3a72"}"#
  }
  check (failSoftNodes.contains
        (.text (canonicalToolWork observedTool)) &&
      failSoftNodes.contains (.text (canonicalJson observedTool.response)) &&
      failSoftNodes.contains (.text "completed with one observed native result"))
    "promotion lost observed Work, Outcome, or parent result"
  check (!failSoftNodes.contains (.text "printf unobserved_hook_result_91ce"))
    "an unresolved PreToolUse reservation fabricated persistent Work"
  IO.println "PASS native history delta, independent session handoff, compaction restore"

def waitHook (task : Task (Except IO.Error String)) : IO String := do
  match ← IO.wait task with
  | .ok output => pure output
  | .error error => throw error

def testDaemonConcurrency : IO Unit := do
  let endpointFile ← Plugin.Daemon.endpointPath
  if ← endpointFile.pathExists then IO.FS.removeFile endpointFile
  let daemon ← IO.asTask Plugin.Daemon.run .dedicated
  let endpoint ← Plugin.Daemon.awaitEndpoint Plugin.Daemon.startupAttempts
  let cwd := (← hookTestRoot).toString
  let send (input : Lean.Json) := Plugin.Daemon.exchange endpoint "hook" input
  let _ ← send (Lean.Json.mkObj [
    ("hook_event_name", "SessionStart"),
    ("session_id", "daemon-parallel"), ("cwd", cwd)])
  let _ ← send (Lean.Json.mkObj [
    ("hook_event_name", "UserPromptSubmit"),
    ("session_id", "daemon-parallel"), ("turn_id", "daemon-turn"),
    ("cwd", cwd), ("prompt", "Inspect two independent probes")])
  let preOne ← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"daemon-parallel\",\"turn_id\":\"daemon-turn\",\"tool_name\":\"shell\",\"tool_use_id\":\"daemon-one\",\"tool_input\":{\"command\":\"printf daemon_probe_alpha_91b3\"}}"
  let preTwo ← hookJson
    "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"daemon-parallel\",\"turn_id\":\"daemon-turn\",\"tool_name\":\"shell\",\"tool_use_id\":\"daemon-two\",\"tool_input\":{\"command\":\"printf daemon_probe_beta_4c72\"}}"
  let firstPre ← IO.asTask (send preOne) .dedicated
  let secondPre ← IO.asTask (send preTwo) .dedicated
  let _ ← waitHook firstPre
  let _ ← waitHook secondPre
  let files ← sessionFiles "daemon-parallel"
  let some reserved ← (readJson? files.pending : IO (Option PendingTurn)) |
    throw (IO.userError "daemon lost the concurrent staged turn")
  check (reserved.inFlight.length = 2)
    "daemon did not linearize two concurrent native Work reservations"
  let postOne ← hookJson
    "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"daemon-parallel\",\"turn_id\":\"daemon-turn\",\"tool_name\":\"shell\",\"tool_use_id\":\"daemon-one\",\"tool_input\":{\"command\":\"printf daemon_probe_alpha_91b3\"},\"tool_response\":{\"output\":\"daemon_probe_alpha_91b3\"}}"
  let postTwo ← hookJson
    "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"daemon-parallel\",\"turn_id\":\"daemon-turn\",\"tool_name\":\"shell\",\"tool_use_id\":\"daemon-two\",\"tool_input\":{\"command\":\"printf daemon_probe_beta_4c72\"},\"tool_response\":{\"output\":\"daemon_probe_beta_4c72\"}}"
  let firstPost ← IO.asTask (send postOne) .dedicated
  let secondPost ← IO.asTask (send postTwo) .dedicated
  let _ ← waitHook firstPost
  let _ ← waitHook secondPost
  let some completed ← (readJson? files.pending : IO (Option PendingTurn)) |
    throw (IO.userError "daemon lost concurrent native results")
  check (completed.inFlight.isEmpty && completed.tools.length = 2)
    "daemon did not close both concurrent native Work occurrences"
  let _ ← send (← hookJson
    "{\"hook_event_name\":\"Stop\",\"session_id\":\"daemon-parallel\",\"turn_id\":\"daemon-turn\",\"last_assistant_message\":\"both probes completed\"}")
  let _ ← send (← hookJson
    "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"daemon-parallel\"}")
  let _ ← Plugin.Daemon.exchange endpoint "shutdown"
  match ← IO.wait daemon with
  | .ok 0 => pure ()
  | .ok code => throw (IO.userError s!"eggshelld exited with {code}")
  | .error error => throw error
  check (!(← files.pending.pathExists))
    "concurrent daemon turn was not promoted atomically"
  IO.println "PASS concurrent daemon clients preserve one staged turn"

def semanticProviderFixture : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  let first ← input.getLine
  if first.contains "\"index\"" then
    let query ← input.getLine
    if query.contains "\"query\"" then
      output.putStr "{\"related\":[0]}\n"
      output.flush
  else if first.contains "\"query\"" then
    output.putStr "{\"related\":[]}\n"
    output.flush
  pure 0

def runTests : IO UInt32 := do
  try
    let some dataRoot ← IO.getEnv "EGGSHELL_DATA_ROOT" |
      throw (IO.userError "tests require an isolated EGGSHELL_DATA_ROOT")
    let home := (← IO.getEnv "HOME").getD ""
    let root := System.FilePath.mk dataRoot
    check (root.isAbsolute)
      "tests require an absolute EGGSHELL_DATA_ROOT"
    check (root.normalize != System.FilePath.mk home /
        ".local" / "share" / "eggshell" / "plugin")
      "tests refuse to use the default Eggshell data directory"
    clean
    testNativeWorkUnits
    testPersistenceDag
    testPrivateStorage
    testAuthorityPathBoundaries
    testLocalUnion
    testSemanticProviderTransport
    testNaturalLanguageSessionTransport
    testGroundedOutcomeTransport
    testOperationBoundaryLookup
    testWholeSliceBudget
    testConcurrentPromotion
    testUnionSuppression
    testConfig
    testProjectInit
    testMiniLMDefault
    testMatcherScale
    testPluginBundle
    testInstallerOwnership
    testHooks
    testDaemonConcurrency
    pure 0
  catch error =>
    IO.eprintln s!"FAIL {error}"
    pure 1

def main (arguments : List String) : IO UInt32 :=
  match arguments with
  | ["semantic-provider-fixture", "retrieval"] => semanticProviderFixture
  | _ => runTests
