module

public import Eggshell.Daemon

@[expose] public section

open Lean Eggshell Eggshell.Plugin

def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def awaitCondition (condition : IO Bool) (label : String) : IO Unit := do
  for _ in [0:400] do
    if ← condition then return
    IO.sleep 25
  throw (IO.userError ("condition did not complete: " ++ label))

def readObject (path : System.FilePath) : IO Json := do
  IO.ofExcept (Json.parse (← IO.FS.readFile path))

structure Fixture where
  root : System.FilePath
  binary : System.FilePath
  helper : System.FilePath

def Fixture.files (f : Fixture) (session := "chat") := f.root / "data" / "sessions" / session
def Fixture.config (f : Fixture) := f.root / "global.toml"
def Fixture.env (f : Fixture) : Array (String × Option String) := #[
  ("EGGSHELL_DATA_ROOT", some (f.root / "data").toString),
  ("EGGSHELL_CONFIG", some f.config.toString),
  ("EGGSHELL_PREFIX", some (f.root / "runtime").toString), ("PLUGIN_ROOT", none), ("CODEX_THREAD_ID", none)]

def Fixture.input (f : Fixture) (event : String) (session := "chat") (extra : List (String × Json) := []) :=
  Json.mkObj ([("hook_event_name", .str event), ("session_id", .str session),
    ("turn_id", .str "turn"), ("cwd", .str f.root.toString)] ++ extra)

def Fixture.hook (f : Fixture) (event : String) (session := "chat") (extra : List (String × Json) := []) : IO Json := do
  let result ← IO.Process.output {
    cmd := f.binary.toString
    args := #["codex-hook"]
    cwd := some f.root
    env := f.env } (some (f.input event session extra).compress)
  require (result.exitCode == 0) result.stderr
  IO.ofExcept (Json.parse result.stdout)

def Fixture.start (f : Fixture) (session := "chat") : IO Unit := do
  let _ ← f.hook "SessionStart" session
  let _ ← f.hook "UserPromptSubmit" session [("prompt", .str "Inspect the clock implementation")]

def Fixture.post (f : Fixture) (marker : String) (session := "chat") (id := "probe") : IO Unit := do
  let _ ← f.hook "PostToolUse" session [("tool_name", .str "shell"), ("tool_use_id", .str id),
    ("tool_input", Json.mkObj [("command", .str "cat clock.c")]),
    ("tool_response", Json.mkObj [("output", .str marker)])]

def Fixture.egg (f : Fixture) : IO String := do
  if ← (f.root / "work.egg").pathExists then IO.FS.readFile (f.root / "work.egg") else pure ""

def Fixture.contains (f : Fixture) (marker : String) : IO Bool := do
  pure (((← f.egg).splitOn marker).length > 1)

def Fixture.saved (f : Fixture) (marker : String) : IO Unit := awaitCondition (f.contains marker) marker

def Fixture.queue (f : Fixture) (session := "chat") : IO (Array System.FilePath) := do
  let root := f.files session / "checkpoints"
  if !(← root.isDir) then return #[]
  return (← root.readDir).filterMap fun entry => if entry.fileName.endsWith ".json" then some entry.path else none

def Fixture.endpoint (f : Fixture) (session := "chat") : IO Daemon.Endpoint := do
  IO.ofExcept (fromJson? (← readObject (f.files session / "daemon.json")))

def Fixture.control (f : Fixture) (command : String) : IO UInt32 := do
  let result ← IO.Process.output {
    cmd := f.binary.toString
    args := #["egg", command]
    cwd := some f.root
    env := f.env.push ("CODEX_THREAD_ID", some "chat") }
  pure result.exitCode

def locked (path : System.FilePath) (action : IO α) : IO α := do
  let lock ← IO.FS.Handle.mk path .append
  lock.lock
  try action finally lock.unlock

def killPid (pid : Nat) : IO Unit := do
  let _ ← IO.Process.output { cmd := "/bin/kill", args := #["-KILL", toString pid] }

def firstTests (f : Fixture) : IO Unit := do
  f.start
  f.post "EARLY_RESULT"
  f.saved "EARLY_RESULT"
  let pending ← readObject (f.files / "pending.json")
  require (pending.getObjValD "finalMessage" == .null) "partial work became a final answer"
  f.start "reader"
  let reply ← f.hook "PreToolUse" "reader" [("tool_name", .str "shell"), ("tool_use_id", .str "reuse"),
    ("tool_input", Json.mkObj [("command", .str "cat clock.c")])]
  require ((reply.compress.splitOn "permissionDecision").length > 1) "partial work not reusable"
  let before ← f.egg
  f.post "EARLY_RESULT"
  awaitCondition ((·.isEmpty) <$> f.queue) "duplicate queue drain"
  require ((← f.egg) == before) "replay changed saved graph"
  for name in ["work.egg.tmp", "work.egg.tmp-999999-0"] do IO.FS.writeFile (f.root / name) "{incomplete"
  f.post "AFTER_ABANDONED_TEMP" "chat" "after-temp"
  f.saved "AFTER_ABANDONED_TEMP"
  require (← f.contains "EARLY_RESULT") "earlier outcome disappeared"
  let _ ← IO.ofExcept (Json.parse (← f.egg))
  for name in ["work.egg.tmp", "work.egg.tmp-999999-0"] do
    require ((← IO.FS.readFile (f.root / name)) == "{incomplete") "abandoned evidence overwritten"
  IO.println "Core lifecycle: partial save, cross-chat reuse, replay and abandoned writes passed"

def contentionTests (f : Fixture) : IO Unit := do
  f.start
  locked (f.root / "work.egg.guard") do
    f.post "AFTER_AUTHORITY_LOCK"
    awaitCondition ((!·.isEmpty) <$> f.queue) "checkpoint while authority locked"
    let start ← IO.monoMsNow
    let _ ← f.hook "Stop"
    require ((← IO.monoMsNow) - start < 2500) "Stop waited for the authority lock"
    IO.sleep 1300
    require (!(← f.queue).isEmpty && !(← f.contains "AFTER_AUTHORITY_LOCK")) "busy-authority receipt lost"
  f.saved "AFTER_AUTHORITY_LOCK"
  awaitCondition ((·.isEmpty) <$> f.queue) "authority queue drain"
  f.start "journal"
  locked (f.files "journal" / "save.guard") do
    f.post "RECOVERED_JOURNAL" "journal"
    for path in ← f.queue "journal" do IO.FS.removeFile path
    require (!(← f.contains "RECOVERED_JOURNAL")) "save fixture failed to stop consumer"
  f.saved "RECOVERED_JOURNAL"
  IO.println "Core lifecycle: authority contention and journal recovery passed"

def crashTests (f : Fixture) : IO Unit := do
  f.start
  let marker := f.root / "lock-held"
  let owner ← IO.Process.spawn {
    cmd := f.helper.toString
    args := #["hold-lock", (f.root / "work.egg.guard").toString, marker.toString]
    setsid := true }
  try
    awaitCondition marker.pathExists "lock-owner startup"
    f.post "AFTER_LOCK_OWNER_CRASH"
    killPid owner.pid.toNat
    f.saved "AFTER_LOCK_OWNER_CRASH"
  finally
    try owner.kill catch _ => pure ()
    let _ ← owner.wait
    pure ()
  f.start "restart"
  locked (f.root / "work.egg.guard") do
    f.post "AFTER_MANAGER_CRASH" "restart"
    let before ← f.endpoint "restart"
    killPid before.pid
    let _ ← f.hook "SessionStart" "restart"
    require ((← f.endpoint "restart").secret != before.secret) "manager was not replaced"
  f.saved "AFTER_MANAGER_CRASH"
  f.start "writer"
  locked (f.root / "work.egg.guard") do
    f.post "AFTER_WRITER_CRASH" "writer"
    let manager := (← f.endpoint "writer").pid
    let writer ← IO.mkRef (none : Option Nat)
    awaitCondition (do
      let listing ← IO.Process.run { cmd := "ps", args := #["-axo", "pid,ppid,args"] }
      for line in listing.splitOn "\n" do
        let parts := line.splitOn " " |>.filter (!·.isEmpty)
        if parts[1]? == some (toString manager) && (line.splitOn "codex-worker save").length > 1 then
          writer.set (parts.head?.bind String.toNat?)
      return (← writer.get).isSome) "save worker startup"
    killPid (← writer.get).get!
    require (!(← f.queue "writer").isEmpty) "writer crash lost checkpoint"
  f.saved "AFTER_WRITER_CRASH"
  IO.println "Core lifecycle: killed lock owner, manager and save worker recovered"

def isolationTests (f : Fixture) : IO Unit := do
  let tasks ← (List.range 4).mapM fun _ => IO.asTask (f.hook "SessionStart") .dedicated
  for task in tasks do let _ ← IO.ofExcept (← IO.wait task); pure ()
  f.start "second"
  let first ← f.endpoint
  let second ← f.endpoint "second"
  require (first.port != second.port && first.secret != second.secret) "chats share manager identity"
  let rejected ← try
      let _ ← Daemon.exchange first "hook" (f.input "PostCompact" "second")
      pure false
    catch _ => pure true
  require rejected "manager accepted another chat's event"
  let duplicate ← IO.Process.output { cmd := f.binary.toString, args := #["codex-daemon", "chat"], env := f.env }
  require (duplicate.exitCode != 0) "duplicate manager acquired the lease"
  IO.FS.writeFile (f.files / "state.json") "tr"
  IO.FS.writeFile (f.files / "pending.json") "tr"
  let old ← IO.FS.readFile f.config
  IO.FS.writeFile f.config "invalid"
  require ((← f.control "off") == 0) "off could not recover broken state"
  require ((← readObject (f.files / "state.json")).getObjValD "enabled" == .bool false) "off did not disable"
  let reply ← f.hook "PostCompact"
  require (reply == Json.mkObj []) "disabled compaction emitted instructions"
  IO.FS.writeFile f.config (old.replace "work\"" "research\"" |>.replace "profiles.work" "profiles.research")
  require ((← f.control "on") == 0) "on did not resolve repaired configuration"
  IO.println "Core lifecycle: manager isolation, duplicate lease and corrupt-state control passed"

def deliveryTests (f : Fixture) : IO Unit := do
  f.start "seed"
  f.post "FIRST_CLOCK_OBSERVATION" "seed"
  f.saved "FIRST_CLOCK_OBSERVATION"
  f.start "reader"
  let fields := [("tool_name", .str "shell"), ("tool_use_id", .str "first"),
    ("tool_input", Json.mkObj [("command", .str "cat clock.c")])]
  let first ← f.hook "PreToolUse" "reader" fields
  require ((first.getObjValD "hookSpecificOutput").getObjValD "permissionDecision" == .str "deny") "first outcome not reused"
  f.start "second-seed"
  f.post "SECOND_CLOCK_OBSERVATION" "second-seed"
  f.saved "SECOND_CLOCK_OBSERVATION"
  let fields := fields.map fun (k,v) => (k, if k == "tool_use_id" then .str "second" else v)
  let second ← f.hook "PreToolUse" "reader" fields
  require ((second.compress.splitOn "SECOND_CLOCK_OBSERVATION").length > 1) "new evidence ignored after prior denial"
  let again ← f.hook "PreToolUse" "reader" (fields.map fun (k,v) => (k, if k == "tool_use_id" then .str "third" else v))
  require (!((again.getObjValD "hookSpecificOutput").getObjVal? "permissionDecision").isOk)
    "unchanged evidence caused repeated denial"
  f.start "lost-receipt"
  let _ ← f.hook "PostCompact" "lost-receipt"
  let endpoint ← f.endpoint "lost-receipt"
  let _ ← Daemon.exchange endpoint "hook" (f.input "PreToolUse" "lost-receipt" (fields ++ [("_eggshell_receipt", .str "lost")]))
  let delivered := do
    let state ← readObject (f.files "lost-receipt" / "state.json")
    let graphs ← IO.ofExcept (state.getObjValAs? (List String) "deliveredGraphs")
    pure (graphs.any (·.startsWith "g:"))
  require (!(← delivered)) "lost receipt marked graph delivered"
  let _ ← f.hook "PostCompact" "lost-receipt"
  let _ ← Daemon.exchange endpoint "ack" (Json.mkObj [("receipt", .str "lost")])
  require (!(← delivered)) "old-context receipt was accepted"
  IO.println "Core lifecycle: changed evidence, unchanged denial suppression and lost/stale receipts passed"

def deadlineTest (f : Fixture) : IO Unit := do
  f.start "seed"
  f.post "DEADLINE_SEED" "seed"
  let _ ← f.hook "Stop" "seed" [("last_assistant_message", .str "Clock result for retrieval")]
  f.saved "Clock result for retrieval"
  let _ ← f.hook "SessionStart" "deadline"
  let marker := f.root / "expired-provider-pids"
  let config := f.root / "expired.toml"
  let command := toJson [f.helper.toString, "hung-provider", marker.toString]
  IO.FS.writeFile config ((← IO.FS.readFile f.config).replace "semantic_matcher = false" ("semantic_matcher = " ++ command.compress))
  let endpoint ← f.endpoint "deadline"
  let clock ← Daemon.exchange endpoint "ping" .null
  let some peer := clock.toNat? | throw (IO.userError "invalid peer monotonic clock")
  let start ← IO.monoMsNow
  let output ← Daemon.exchange endpoint "hook" (f.input "UserPromptSubmit" "deadline" [
    ("prompt", .str "Recall the clock result"), ("_eggshell_config", .str config.toString),
    ("_eggshell_deadline", toJson (peer + 800)), ("_eggshell_receipt", .str "expired")])
  require ((← IO.monoMsNow) - start < 2000) "expired search exceeded its transport deadline"
  require (← marker.pathExists) "deadline fixture never started"
  require ((← IO.ofExcept (Json.parse output)) == Json.mkObj []) "expired search published context"
  f.post "SAVED_AFTER_DEADLINE" "deadline"
  f.saved "SAVED_AFTER_DEADLINE"
  let pids ← IO.ofExcept (fromJson? (← readObject marker) : Except String (List Nat))
  for pid in pids do
    let status ← IO.Process.output { cmd := "ps", args := #["-o", "stat=", "-p", toString pid] }
    require (status.stdout.trimAscii.isEmpty || status.stdout.trimAscii.toString.startsWith "Z") "expired provider survived"
  IO.println "Core lifecycle: expired search was reaped and subsequent work saved"

def hungSearchTest (f : Fixture) : IO Unit := do
  f.start "seed"
  f.post "SEARCH_SEED" "seed"
  let _ ← f.hook "Stop" "seed" [("last_assistant_message", .str "Clock investigation completed")]
  f.saved "Clock investigation completed"
  let marker := f.root / "provider-pids"
  let config := f.root / "slow.toml"
  let command := toJson [f.helper.toString, "hung-provider", marker.toString]
  IO.FS.writeFile config ((← IO.FS.readFile f.config).replace "semantic_matcher = false" ("semantic_matcher = " ++ command.compress))
  let task ← IO.asTask (IO.Process.output {
    cmd := f.binary.toString
    args := #["codex-hook"]
    cwd := some f.root
    env := f.env.push ("EGGSHELL_CONFIG", some config.toString) }
    (some (f.input "UserPromptSubmit" "slow" [("prompt", .str "What did we find about the clock?")]).compress)) .dedicated
  awaitCondition marker.pathExists "hung provider startup"
  let pids ← IO.ofExcept (fromJson? (← readObject marker) : Except String (List Nat))
  try
    f.post "SAVED_DURING_HUNG_SEARCH" "slow"
    f.saved "SAVED_DURING_HUNG_SEARCH"
    let start ← IO.monoMsNow
    f.start "independent"
    require ((← IO.monoMsNow) - start < 3000) "search blocked another chat"
    let start ← IO.monoMsNow
    let _ ← f.hook "Stop" "slow"
    require ((← IO.monoMsNow) - start < 2500) "search blocked Stop"
    let some output ← Worker.awaitUntil task ((← IO.monoMsNow) + 4000) |
      throw (IO.userError "search owner failed to stop")
    require (output.exitCode == 0 && (← IO.ofExcept (Json.parse output.stdout)) == Json.mkObj []) "cancelled search published"
    for pid in pids do
      awaitCondition (do
        let result ← IO.Process.output { cmd := "ps", args := #["-o", "stat=", "-p", toString pid] }
        let status := result.stdout.trimAscii.toString
        return status.isEmpty || status.startsWith "Z") "provider process-group cleanup"
  finally for pid in pids do killPid pid
  IO.println "Core lifecycle: hung search preserves saves, independent chats, Stop and process cleanup"

def withFixture (test : Fixture → IO Unit) : IO Unit := do
  let root ← IO.FS.createTempDir
  let root ← IO.FS.realPath root
  let f : Fixture := ⟨root, ← IO.FS.realPath ".lake/build/bin/eggshell", ← IO.appPath⟩
  let config := "semantic_matcher = false\ndefault = \"work\"\n[eggs]\nproject = \"work.egg\"\n[profiles.work]\nread = [\"project\"]\nwrite = \"project\"\n"
  IO.FS.writeFile f.config config
  IO.FS.writeFile (root / ".eggshell.toml") (config.replace "semantic_matcher = false\n" "")
  try test f
  finally
    let sessions := root / "data" / "sessions"
    let mut managers : List Nat := []
    if ← sessions.isDir then
      for entry in ← sessions.readDir do
        try
          let endpoint ← IO.ofExcept (fromJson? (← readObject (entry.path / "daemon.json")) : Except String Daemon.Endpoint)
          managers := endpoint.pid :: managers
          let _ ← Daemon.exchange endpoint "shutdown" .null
        catch _ => pure ()
    -- A shutdown reply acknowledges the request before the manager has removed
    -- its endpoint and stopped writing. Wait for process exit before traversing
    -- the fixture tree; otherwise removeDirAll can race daemon.json removal.
    for pid in managers do
      awaitCondition (do
        let result ← IO.Process.output { cmd := "ps", args := #["-o", "stat=", "-p", toString pid] }
        let status := result.stdout.trimAscii.toString
        return status.isEmpty || status.startsWith "Z") "fixture manager shutdown"
    IO.FS.removeDirAll root

def main (args : List String) : IO UInt32 := do
  match args with
  | ["hold-lock", path, marker] =>
      locked (.mk path) do
        IO.FS.writeFile (.mk marker) "ready"
        IO.sleep 60000
      pure 0
  | ["sleep"] => IO.sleep 60000 *> pure 0
  | ["hung-provider", marker] =>
      let _ ← (← IO.getStdin).getLine
      let child ← IO.Process.spawn { cmd := (← IO.appPath).toString, args := #["sleep"] }
      IO.FS.writeFile (.mk marker) (toJson [(← IO.Process.getPID).toNat, child.pid.toNat]).compress
      IO.sleep 60000
      pure 0
  | [] =>
      for test in [firstTests, contentionTests, crashTests, isolationTests, deliveryTests, deadlineTest, hungSearchTest] do withFixture test
      pure 0
  | _ => throw (IO.userError "invalid lifecycle fixture command")
