module

public import Adapter.Runtime
public import Adapter.Install
import Adapter.ContractAudit

@[expose] public section

open Lean Eggshell Eggshell.Plugin Eggshell.Adapter

def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def pureTests : IO Unit := do
  for (input, expected) in [
      ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
      ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1") ] do
    check (Sha256.hex input.toUTF8 == expected) "SHA-256 known-answer mismatch"
  let identity : Identity := ⟨.gemini, "test"⟩
  let state : Correlation := { owner := identity, turn := some "turn" }
  let raw := Json.mkObj [("session_id", .str "test"), ("cwd", .str "/tmp"),
    ("hook_event_name", .str "BeforeTool"), ("tool_name", .str "shell"),
    ("tool_input", Json.mkObj [("command", .str "cat a")])]
  let .event _ first ← IO.ofExcept (normalize .gemini .before raw state "first") |
    throw (IO.userError "first tool not normalized")
  let .event _ second ← IO.ofExcept (normalize .gemini .before raw first "second") |
    throw (IO.userError "second tool not normalized")
  check (second.calls.length == 2) "identical operations collapsed"
  let after := raw.setObjVal! "hook_event_name" (.str "AfterTool")
    |>.setObjVal! "tool_response" (.str "observed")
  let .event result finished ← IO.ofExcept (normalize .gemini .after after second "ignored") |
    throw (IO.userError "same-turn parallel result not attributed")
  check (result.getObjValD "tool_use_id" == .str "first" && finished.calls.head?.any (·.finished))
    "parallel result did not retain its occurrence"
  let conflicting := { second with calls := second.calls.map fun call =>
    if call.id == "second" then { call with turn := "another", writable := true } else { call with writable := true } }
  let .unattributed ambiguous true ← IO.ofExcept (normalize .gemini .after after conflicting "ignored") |
    throw (IO.userError "cross-turn ambiguity was incorrectly attributed")
  check (!(ambiguous.getObjVal? "turn_id").isOk) "ambiguous result got a parent"
  let alien := { state with owner := ⟨.claude, "test"⟩ }
  check (!(normalize .gemini .before raw alien "id").isOk) "foreign owner was accepted"
  for host in [Host.claude, .gemini, .cursor, .opencode] do
    for event in [Event.stop, .interrupt, .finish, .compact] do
      check (projectReply host event (some "context") (some "deny") == .quiet) "terminal hook was not quiet"
  IO.println "Pure adapter contracts: passed (plus kernel-checked universal theorems)"

structure Fixture where
  root : System.FilePath
  binary : System.FilePath

def Fixture.env (f : Fixture) : Array (String × Option String) := #[
  ("EGGSHELL_PREFIX", some (f.root / "runtime").toString),
  ("EGGSHELL_DATA_ROOT", some (f.root / "data").toString),
  ("EGGSHELL_CONFIG", some (f.root / ".eggshell.toml").toString),
  ("PLUGIN_ROOT", none), ("CODEX_THREAD_ID", none)]

def Fixture.run (f : Fixture) (args : Array String) (input : Option Json := none) : IO Json := do
  let output ← IO.Process.output { cmd := f.binary.toString, args, cwd := some f.root, env := f.env }
    (input.map Json.compress)
  check (output.exitCode == 0) ("command failed: " ++ output.stderr)
  if output.stdout.trimAscii.isEmpty then return Json.mkObj []
  IO.ofExcept (Json.parse output.stdout)

def Fixture.hook (f : Fixture) (host : Host) (event : Event) (session := "chat")
    (turn := "turn") (fields : List (String × Json) := []) : IO Json := do
  let name := (events host).find? (·.2 == event) |>.map (·.1) |>.getD ""
  let base := [("hook_event_name", .str name), ("cwd", .str f.root.toString)] ++
    (if host == .cursor then [("conversation_id", .str session), ("generation_id", .str turn)]
     else [("session_id", .str session)] ++ if host == .opencode then [("turn_id", .str turn)] else [])
  f.run #["hook", host.name] (some (Json.mkObj (base ++ fields)))

def Fixture.waitFor (f : Fixture) (marker : String) : IO Unit := do
  for _ in [0:320] do
    if ← (f.root / "work.egg").pathExists then
      if ((← IO.FS.readFile (f.root / "work.egg")).splitOn marker).length > 1 then return
    IO.sleep 25
  throw (IO.userError ("missing saved outcome: " ++ marker))

def Fixture.state (f : Fixture) (host : Host) (session := "chat") : IO Json := do
  IO.ofExcept (Json.parse (← IO.FS.readFile (f.root / "data" / "sessions" /
    sessionKey ⟨host, session⟩ / "state.json")))

def Fixture.control (f : Fixture) (host : Host) (session : String) (args : Array String) : IO Unit := do
  let result ← IO.Process.output {
    cmd := f.binary.toString
    args := #["control", host.name, "--session", session] ++ args
    cwd := some f.root
    env := f.env }
  check (result.exitCode == 0) result.stderr

def Fixture.answerDrafts (f : Fixture) (session : String) : IO Bool := do
  let path := f.root / "data" / "sessions" / sessionKey ⟨.cursor, session⟩ / "adapter-drafts"
  if !(← path.isDir) then return false
  return !(← path.readDir).isEmpty

def moreLifecycleTests (f : Fixture) : IO Unit := do
  for session in ["aborted", "completed", "private", "off"] do
    let _ ← f.hook .cursor .start session
    if session == "private" then f.control .cursor session #["next", "private"]
    let _ ← f.hook .cursor .prompt session "turn" [("prompt", .str "Investigate a clock edge case")]
    if session == "off" then f.control .cursor session #["off"]
    let marker := "FINAL_" ++ session
    let _ ← f.hook .cursor .answer session "turn" [("text", .str marker)]
    if session == "private" || session == "off" then
      check (!(← f.answerDrafts session)) "unwritable turn stored an answer candidate"
    let _ ← f.hook .cursor .stop session "turn" [("status", .str (if session == "aborted" then "aborted" else "completed"))]
    if session == "completed" then f.waitFor marker
    else check (((← IO.FS.readFile (f.root / "work.egg")).splitOn marker).length == 1) "incomplete/private final answer was saved"
  let session := "late-origin"
  let _ ← f.hook .claude .prompt session "turn" [("prompt", .str "Original task")]
  let fields := [("tool_name", .str "shell"), ("tool_use_id", .str "late"),
    ("tool_input", Json.mkObj [("command", .str "cat late.c")])]
  let _ ← f.hook .claude .before session "turn" fields
  let _ ← f.hook .claude .stop session "turn" [("last_assistant_message", .str "Original task is closed")]
  let _ ← f.hook .claude .prompt session "new" [("prompt", .str "Different new task")]
  let _ ← f.hook .claude .after session "turn" (fields ++ [("tool_response", .str "LATE_ORIGINAL_RECEIPT")])
  f.waitFor "LATE_ORIGINAL_RECEIPT"
  let session := "parallel-tools"
  let _ ← f.hook .gemini .prompt session "turn" [("prompt", .str "Parallel clock investigation")]
  let fields := [("tool_name", .str "run_shell_command"),
    ("tool_input", Json.mkObj [("command", .str "cat parallel.c")])]
  let tasks ← ["one", "two"].mapM fun _ => IO.asTask (f.hook .gemini .before session "turn" fields) .dedicated
  for task in tasks do let _ ← IO.ofExcept (← IO.wait task); pure ()
  let tasks ← ["PARALLEL_ONE", "PARALLEL_TWO"].mapM fun marker =>
    IO.asTask (f.hook .gemini .after session "turn" (fields ++ [("tool_response", .str marker)])) .dedicated
  for task in tasks do let _ ← IO.ofExcept (← IO.wait task); pure ()
  f.waitFor "PARALLEL_ONE"
  f.waitFor "PARALLEL_TWO"
  let session := "ambiguous-tools"
  let _ ← f.hook .gemini .prompt session "turn" [("prompt", .str "First origin")]
  let _ ← f.hook .gemini .before session "turn" fields
  let _ ← f.hook .gemini .prompt session "next" [("prompt", .str "Second origin")]
  let _ ← f.hook .gemini .before session "next" fields
  let _ ← f.hook .gemini .after session "next" (fields ++ [("tool_response", .str "AMBIGUOUS_RECEIPT")])
  let root := f.root / "data" / "adapters" / "unattributed" / sessionKey ⟨.gemini, session⟩
  let saved ← root.readDir
  check (saved.size == 1) "ambiguous result was lost"
  let some entry := saved[0]? | throw (IO.userError "missing ambiguous receipt")
  let receipt ← IO.ofExcept (Json.parse (← IO.FS.readFile entry.path))
  check (!(receipt.getObjVal? "turn_id").isOk) "ambiguous result was assigned a parent"
  check (((← IO.FS.readFile (f.root / "work.egg")).splitOn "AMBIGUOUS_RECEIPT").length == 1)
    "ambiguous result promoted into the graph"
  IO.println "Native lifecycle: aborted/private/off answers, late origin, parallel and ambiguous results passed"

def Fixture.cleanup (f : Fixture) : IO Unit := do
  let sessions := f.root / "data" / "sessions"
  if ← sessions.isDir then
    for entry in ← sessions.readDir do
      let path := entry.path / "daemon.json"
      if ← path.pathExists then
        try
          let endpoint ← IO.ofExcept (fromJson? (← IO.ofExcept (Json.parse (← IO.FS.readFile path))) : Except String Daemon.Endpoint)
          let _ ← Daemon.exchange endpoint "shutdown" .null
        catch _ => pure ()

def integrationTests (binary : System.FilePath) : IO Unit := do
  let root ← IO.FS.createTempDir
  let root ← IO.FS.realPath root
  let f : Fixture := ⟨root, binary⟩
  IO.FS.writeFile (root / ".eggshell.toml") "semantic_matcher = false\ndefault = \"work\"\n[eggs]\nproject = \"work.egg\"\n[profiles.work]\nread = [\"project\"]\nwrite = \"project\"\n[profiles.private]\nread = [\"project\"]\n"
  try
    for host in [Host.claude, .gemini, .cursor, .opencode] do
      let session := host.name ++ "-writer"
      let _ ← f.hook host .start session
      let _ ← f.hook host .prompt session "turn" [("prompt", .str "Inspect the clock")]
      let fields := [("tool_name", .str "shell"), ("tool_input", Json.mkObj [("command", .str ("cat " ++ host.name ++ ".c"))])] ++
        if host == .gemini then [] else [("tool_use_id", .str "call")]
      let _ ← f.hook host .before session "turn" fields
      let marker := host.name ++ "_SAVED_PROGRESS"
      let _ ← f.hook host .after session "turn" (fields ++
        [(if host == .cursor then "tool_output" else "tool_response", .str marker)])
      f.waitFor marker
      let reader := host.name ++ "-reader"
      let _ ← f.hook host .prompt reader "turn" [("prompt", .str "Inspect the clock")]
      let reply ← f.hook host .before reader "turn" fields
      let output := if host == .opencode then reply.getObjValD "output" else reply
      check (output.getObjValD "permission" == .str "deny" || output.getObjValD "decision" == .str "deny" ||
        (output.getObjValD "hookSpecificOutput").getObjValD "permissionDecision" == .str "deny") "new chat did not reuse saved work"
      if host == .opencode then
        check ((← f.state host reader).getObjValD "lastHandoff" == .str "") "delivery acknowledged before JS insertion"
        let _ ← f.hook host .compact reader
        let _ ← f.run #["ack", host.name] (some reply)
        check ((← f.state host reader).getObjValD "lastHandoff" == .str "") "obsolete receipt was accepted"
    IO.println "Native engine integration: four harnesses save before Stop and reuse in a new chat"
    moreLifecycleTests f
    for host in [Host.claude, .gemini, .cursor, .opencode] do
      let project := root / ("install-" ++ host.name)
      IO.FS.createDirAll project
      let config := project / Eggshell.Adapter.Install.configPath host
      let initial := Json.mkObj [("otherSetting", .bool true), ("hooks", Json.mkObj [
        ("otherEvent", .arr #[Json.mkObj [("command", .str "keep")]])])]
      if host != .opencode then
        IO.FS.createDirAll config.parent.get!
        IO.FS.writeFile config initial.compress
      let args := #["install", host.name, "--project", project.toString, "--prefix", (root / "prefix's space").toString]
      let _ ← f.run args
      let first ← IO.FS.readFile config
      let _ ← f.run args
      check ((← IO.FS.readFile config) == first) "installer not idempotent"
      -- Reproduce a process exit after writing the new receipt but before
      -- replacing the old project config. Both owned versions must recover.
      let support := root / "prefix's space" / "share" / "eggshell-adapters"
      let key := Sha256.hex (host.name ++ "\n" ++ config.toString).toUTF8
      let receiptPath := support / "receipts" / (key ++ ".json")
      let previous ← IO.ofExcept (Json.parse (← IO.FS.readFile receiptPath))
      let future := if host == .opencode then Json.mkObj [("contents", .str "interrupted version")]
        else Json.mkObj [("entries", Eggshell.Adapter.Install.entries host "interrupted-command")]
      IO.FS.writeFile receiptPath (future.setObjVal! "previous" previous).compress
      let _ ← f.run args
      check ((← IO.FS.readFile config) == first) "interrupted installation orphaned an owned hook"
      let _ ← f.run (args.push "--uninstall")
      if host == .opencode then check (!(← config.pathExists)) "OpenCode entry not removed"
      else
        let value ← IO.ofExcept (Json.parse (← IO.FS.readFile config))
        check (value.getObjValD "otherSetting" == .bool true &&
          (value.getObjValD "hooks").getObjValD "otherEvent" == (initial.getObjValD "hooks").getObjValD "otherEvent")
          "unrelated settings changed"
    IO.println "Native installer: idempotence, interrupted receipt recovery and ownership passed for all four harnesses"
  finally
    f.cleanup
    IO.FS.removeDirAll root

def main (args : List String) : IO UInt32 := do
  pureTests
  let binary := System.FilePath.mk (args.headD ".lake/build/bin/eggshell_bridge")
  integrationTests (← IO.FS.realPath binary)
  pure 0
