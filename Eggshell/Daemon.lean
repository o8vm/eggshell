module

public import Eggshell.PluginCli
public import Std.Async.TCP
public import Std.Async.Timer

@[expose] public section

namespace Eggshell.Plugin.Daemon

open Lean Std Async TCP

def maxFrameBytes : Nat := 8 * 1024 * 1024
def startupAttempts : Nat := 80

structure Endpoint where
  session : String := ""
  pid : Nat := 0
  port : Nat
  secret : String
  /-- Identity of the daemon executable selected by the current Plugin bundle. -/
  generation : String
  deriving ToJson, FromJson

def endpointJsonDefaults : List (String × Json) :=
  [("session", toJson ""), ("pid", toJson (0 : Nat))]

namespace Endpoint

def compatible (endpoint : Endpoint) (generation : String) : Bool :=
  endpoint.generation == generation

theorem incompatible_generation_rejected {endpoint : Endpoint} {generation : String}
    (different : endpoint.generation ≠ generation) :
    endpoint.compatible generation = false := by
  simp [compatible, different]

end Endpoint

def endpointPath (session : String) : IO System.FilePath := do
  pure ((← sessionFiles session).directory / "daemon.json")

def startupLock (session : String) : IO System.FilePath := do
  pure ((← sessionFiles session).directory / "daemon-start")

def daemonExecutable : IO System.FilePath := do
  match ← IO.getEnv "PLUGIN_ROOT" with
  | some root =>
      let bundled := System.FilePath.mk root / "bin" / "eggshelld"
      if ← bundled.pathExists then pure bundled else IO.appPath
  | none => IO.appPath

/--
The endpoint is valid only for the executable selected by this Plugin bundle.
File metadata is a private lifecycle generation, not semantic authority; it
keeps a reinstalled Plugin from silently talking to an older resident daemon.
-/
def executableGeneration (path : System.FilePath) : IO String := do
  let metadata ← path.metadata
  pure s!"{metadata.byteSize}:{repr metadata.modified}"

def desiredGeneration : IO String := do
  executableGeneration (← daemonExecutable)

def loopback (port : UInt16) : Net.SocketAddress :=
  .v4 ⟨.ofParts 127 0 0 1, port⟩

def frameLength (bytes : ByteArray) : ByteArray :=
  let value := bytes.size.toUInt32
  .mk #[
    (value >>> 24).toUInt8,
    (value >>> 16).toUInt8,
    (value >>> 8).toUInt8,
    value.toUInt8]

def decodeLength (bytes : ByteArray) : Nat :=
  ((bytes.get! 0).toNat <<< 24) |||
    ((bytes.get! 1).toNat <<< 16) |||
    ((bytes.get! 2).toNat <<< 8) ||| (bytes.get! 3).toNat

partial def receiveExactly (client : Socket.Client) (remaining : Nat)
    (deadline : Nat) (received : ByteArray := ByteArray.empty) : IO ByteArray := do
  if remaining = 0 then return received
  let now ← IO.monoMsNow
  if now ≥ deadline then throw (IO.userError "daemon receive deadline expired")
  let chunk ← (do
    let timer ← Selector.sleep (.ofNat (deadline - now))
    Selectable.one #[
      .case (client.recvSelector remaining.toUInt64) pure,
      .case timer (fun _ => throw (IO.userError "daemon receive deadline expired"))]).block
  let some chunk := chunk |
    throw (IO.userError "eggshelld closed an incomplete frame")
  if chunk.isEmpty then
    throw (IO.userError "eggshelld returned an empty frame")
  receiveExactly client (remaining - chunk.size) deadline (received.append chunk)

def receiveFrame (client : Socket.Client) (budget : Nat := 24000) : IO ByteArray := do
  let deadline := (← IO.monoMsNow) + budget
  let header ← receiveExactly client 4 deadline
  let length := decodeLength header
  if length > maxFrameBytes then
    throw (IO.userError "eggshelld frame exceeds the transport bound")
  receiveExactly client length deadline

def sendFrame (client : Socket.Client) (payload : ByteArray) : IO Unit := do
  if payload.size > maxFrameBytes then
    throw (IO.userError "eggshelld frame exceeds the transport bound")
  (client.sendAll #[frameLength payload, payload]).block

def response (output : Except String String) : Json :=
  match output with
  | .ok value => Json.mkObj [("ok", true), ("output", value)]
  | .error message => Json.mkObj [("ok", false), ("error", message)]

def request (secret kind : String) (payload : Json := Json.null) : Json :=
  Json.mkObj [("secret", secret), ("kind", kind), ("payload", payload)]

def serveRequest (session secret : String) (json : Json) : IO (Json × Bool) := do
  if optionalString json "secret" != some secret then
    pure (response (.error "unauthorized daemon request"), false)
  else
    match optionalString json "kind" with
    | some "hook" =>
        let input := json.getObjValD "payload"
        if optionalString input "session_id" != some session then
          return (response (.error "wrong chat manager"), false)
        try pure (response (.ok (← dispatchHook input)), false)
        catch error => pure (response (.error error.toString), false)
    | some "ack" =>
        try
          let id ← IO.ofExcept (requiredString (json.getObjValD "payload") "receipt")
          acknowledge session id
          pure (response (.ok ""), false)
        catch error => pure (response (.error error.toString), false)
    | some "ping" => pure (response (.ok (toString (← IO.monoMsNow))), false)
    | some "shutdown" => pure (response (.ok ""), true)
    | _ => pure (response (.error "unknown daemon request"), false)

/--
Serve one occurrence for this chat. Search and saving have independent worker
processes; the state lock covers only short metadata transitions.
-/
def serveClient (session secret : String) (stopping : IO.Ref Bool)
    (client : Socket.Client) : IO Unit := do
  let (reply, stop) ← try
      let bytes ← receiveFrame client
      let text ← match String.fromUTF8? bytes with
        | some text => pure text
        | none => throw (IO.userError "daemon request is not UTF-8")
      let json ← match Json.parse text with
        | .ok json => pure json
        | .error message => throw (IO.userError message)
      serveRequest session secret json
    catch error => pure (response (.error error.toString), false)
  sendFrame client reply.compress.toUTF8
  if stop then stopping.set true

def retainRunning (tasks : List (Task (Except IO.Error Unit))) :
    IO (List (Task (Except IO.Error Unit))) := do
  let mut running := []
  for task in tasks do
    if ← IO.hasFinished task then
      if let .error error ← IO.wait task then
        IO.eprintln s!"eggshelld client: {error}"
    else
      running := task :: running
  pure running

def removeEndpointIfOwned (endpoint : Endpoint) : IO Unit := do
  let path ← endpointPath endpoint.session
  try
    if let some current ← (readJson? path endpointJsonDefaults : IO (Option Endpoint)) then
      if current.secret = endpoint.secret then removeIfExists path
  catch _ => pure ()

def run (session : String) : IO UInt32 := do
  let files ← sessionFiles session
  Persistence.withLockWithin (files.directory / "manager") 0 do
    runOwned session
where
 runOwned (session : String) : IO UInt32 := do
  let path ← endpointPath session
  if let some parent := path.parent then IO.FS.createDirAll parent
  let server ← Socket.Server.mk
  server.bind (loopback 0)
  server.listen 128
  server.noDelay
  let address ← server.getSockName
  let secret := Blake3.hex (← IO.getRandomBytes 32)
  let endpoint : Endpoint := {
    session
    pid := (← IO.Process.getPID).toNat
    port := address.port.toNat
    secret
    generation := ← desiredGeneration
  }
  writeJson path endpoint
  Persistence.privateFile path
  let stopping ← IO.mkRef false
  let mut clients : List (Task (Except IO.Error Unit)) := []
  let mut lastActivity ← IO.monoMsNow
  let mut saves : List (Task (Except IO.Error Unit)) := []
  let saveCursor ← IO.mkRef ("", ([] : List String))
  let mut nextSave : Nat := 0
  try
    while !(← stopping.get) do
      match ← server.tryAccept with
      | none => IO.sleep 1
      | some client =>
          lastActivity ← IO.monoMsNow
          if clients.length < 32 then
            clients := (← IO.asTask (serveClient session secret stopping client) .dedicated) :: clients
      clients ← retainRunning clients
      saves ← retainRunning saves
      let now ← IO.monoMsNow
      if saves.isEmpty && now ≥ nextSave then
        saves := [← IO.asTask (flushDeferred session (now + 60000) (some saveCursor)) .dedicated]
        nextSave := now + 1000
      if saves.isEmpty && now > lastActivity + 300000 then stopping.set true
    Worker.shutdown
    removeEndpointIfOwned endpoint
    pure 0
  catch error =>
    removeEndpointIfOwned endpoint
    IO.eprintln s!"eggshelld: {error}"
    pure 1

def connect (endpoint : Endpoint) : IO Socket.Client := do
  if endpoint.port > 65535 then
    throw (IO.userError "invalid eggshelld port")
  let client ← Socket.Client.mk
  (client.connect (loopback endpoint.port.toUInt16)).block
  pure client

def exchange (endpoint : Endpoint) (kind : String)
    (payload : Json := Json.null) (budget : Nat := 24000) : IO String := do
  let client ← connect endpoint
  sendFrame client (request endpoint.secret kind payload |>.compress |>.toUTF8)
  let bytes ← receiveFrame client budget
  let text ← match String.fromUTF8? bytes with
    | some text => pure text
    | none => throw (IO.userError "daemon response is not UTF-8")
  let json ← match Json.parse text with
    | .ok json => pure json
    | .error message => throw (IO.userError message)
  if json.getObjValD "ok" == true then
    pure ((optionalString json "output").getD "")
  else throw (IO.userError ((optionalString json "error").getD "daemon failure"))

def loadEndpoint (session : String) : IO Endpoint := do
  let path ← endpointPath session
  let some endpoint ← (readJson? path endpointJsonDefaults : IO (Option Endpoint)) |
    throw (IO.userError "eggshelld is not running")
  pure endpoint

def spawn (session : String) : IO Unit := do
  let executable ← daemonExecutable
  let _ ← IO.Process.spawn {
    cmd := executable.toString
    args := #["codex-daemon", session]
    stdin := .null
    stdout := .null
    stderr := .null
    setsid := true
  }
  pure ()

def readyEndpoint (session : String) : IO Endpoint := do
  let endpoint ← loadEndpoint session
  if endpoint.session != session then throw (IO.userError "wrong chat endpoint")
  let expected ← desiredGeneration
  if !endpoint.compatible expected then
    throw (IO.userError "eggshelld executable generation is stale")
  let _ ← exchange endpoint "ping" (budget := 250)
  pure endpoint

partial def awaitEndpoint (session : String) : Nat → IO Endpoint
  | 0 => throw (IO.userError "eggshelld did not become ready")
  | attempts + 1 =>
      try
        readyEndpoint session
      catch _ =>
        IO.sleep 10
        awaitEndpoint session attempts

def ensure (session : String) : IO Endpoint := do
  try readyEndpoint session
  catch _ => Persistence.withLockWithin (← startupLock session) 200 do
    try readyEndpoint session
    catch _ =>
      try
        let stale ← loadEndpoint session
        let _ ← exchange stale "shutdown" (budget := 250)
      catch _ => pure ()
      removeIfExists (← endpointPath session)
      spawn session
      awaitEndpoint session startupAttempts

def attachClientConfig (input : Json) (config : Option String) : Json :=
  match config with
  | some path => input.setObjVal! "_eggshell_config" path
  | none => input

/-- The RPC subprocess owns every potentially blocking transport operation. -/
def rpcClient (kind : String) : IO UInt32 := do
  let result ← try
    let input ← IO.ofExcept (Json.parse (← (← IO.getStdin).getLine))
    let session ← IO.ofExcept (requiredString input "session_id")
    let endpoint ← ensure session
    let output ← exchange endpoint kind input
    pure (Json.mkObj [("output", output)])
    catch error => pure (Json.mkObj [("error", error.toString)])
  IO.println result.compress
  pure 0

/-- The supervisor kills and reaps its process group before returning on timeout. -/
def boundedRpc (kind : String) (input : Json) (deadline : Nat) : IO (Option String) := do
  let child ← IO.Process.spawn {
    cmd := (← IO.appPath).toString, args := #["codex-rpc", kind]
    stdin := .piped, stdout := .piped, stderr := .null, setsid := true }
  let task ← IO.asTask (do
    child.stdin.putStr (input.compress ++ "\n")
    child.stdin.flush
    -- RPC stdin is one JSON line; it must not wait for EOF from its parent.
    child.stdout.readToEnd) .dedicated
  try
    let result ← Worker.awaitUntil task deadline
    Worker.killGroup child
    let _ ← child.wait
    let _ ← IO.wait task
    pure result
  catch error =>
    Worker.killGroup child
    let _ ← child.wait
    throw error

def hookClient : IO UInt32 := do
  let inputText ← (← IO.getStdin).readToEnd
  try
    let input ← IO.ofExcept (Json.parse inputText)
    let input := attachClientConfig input (← IO.getEnv "EGGSHELL_CONFIG")
    captureTerminal input
    let event := (optionalString input "hook_event_name").getD ""
    let fast := ["Stop", "Interrupt", "PostCompact", "SessionEnd"].contains event ||
      (event == "SessionStart" && optionalString input "source" == some "compact")
    let deadline := (← IO.monoMsNow) + (if fast then 2000 else 26000)
    let receipt := Blake3.hex (← IO.getRandomBytes 16)
    let input := (input.setObjVal! "_eggshell_deadline" (toJson (deadline - 250)))
      |>.setObjVal! "_eggshell_receipt" receipt
    let result ← boundedRpc "hook" input (deadline - 150)
    let reply := result.bind (Json.parse · |>.toOption)
    if let some error := reply.bind (optionalString · "error") then
      IO.eprintln s!"Eggshell hook failed open: {error}"
    let output := (reply.bind (optionalString · "output")).filter
      (fun text => (Json.parse text).isOk) |>.getD emptyHook
    let stdout ← IO.getStdout
    stdout.putStr (output.trimAscii.toString ++ "\n")
    stdout.flush
    if result.isSome && output != emptyHook then
      let ack := Json.mkObj [("session_id", (optionalString input "session_id").getD ""),
        ("receipt", receipt)]
      try
        let _ ← boundedRpc "ack" ack deadline
      catch error => IO.eprintln s!"Eggshell receipt was not acknowledged: {error}"
    pure 0
  catch error =>
    IO.eprintln s!"Eggshell hook failed open: {error}"
    IO.println emptyHook
    pure 0

def shutdown : IO Unit := do
  let root ← dataRoot
  let directory := root / "sessions"
  let paths ← if ← directory.pathExists then do
      (← directory.readDir).toList.mapM fun entry => pure (entry.path / "daemon.json")
    else pure []
  for path in root / "daemon.json" :: paths do
    try
      if let some endpoint ← (readJson? path endpointJsonDefaults : IO (Option Endpoint)) then
        let _ ← exchange endpoint "shutdown" (budget := 500)
    catch _ => pure ()

end Eggshell.Plugin.Daemon
