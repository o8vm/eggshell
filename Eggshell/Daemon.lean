module

public import Eggshell.PluginCli
public import Std.Async.TCP

@[expose] public section

namespace Eggshell.Plugin.Daemon

open Lean Std Async TCP

def maxFrameBytes : Nat := 8 * 1024 * 1024
def startupAttempts : Nat := 2000

structure Endpoint where
  port : Nat
  secret : String
  /-- Identity of the daemon executable selected by the current Plugin bundle. -/
  generation : String
  deriving ToJson, FromJson

namespace Endpoint

def compatible (endpoint : Endpoint) (generation : String) : Bool :=
  endpoint.generation == generation

theorem incompatible_generation_rejected {endpoint : Endpoint} {generation : String}
    (different : endpoint.generation ≠ generation) :
    endpoint.compatible generation = false := by
  simp [compatible, different]

end Endpoint

def endpointPath : IO System.FilePath := do
  pure ((← dataRoot) / "daemon.json")

def startupLock : IO System.FilePath := do
  pure ((← dataRoot) / "daemon-start")

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
    (received : ByteArray := ByteArray.empty) : IO ByteArray := do
  if remaining = 0 then return received
  let some chunk ← (client.recv? remaining.toUInt64).block |
    throw (IO.userError "eggshelld closed an incomplete frame")
  if chunk.isEmpty then
    throw (IO.userError "eggshelld returned an empty frame")
  receiveExactly client (remaining - chunk.size) (received.append chunk)

def receiveFrame (client : Socket.Client) : IO ByteArray := do
  let header ← receiveExactly client 4
  let length := decodeLength header
  if length > maxFrameBytes then
    throw (IO.userError "eggshelld frame exceeds the transport bound")
  receiveExactly client length

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

def serveRequest (secret : String) (json : Json) : IO (Json × Bool) := do
  if optionalString json "secret" != some secret then
    pure (response (.error "unauthorized daemon request"), false)
  else
    match optionalString json "kind" with
    | some "hook" =>
        let input := json.getObjValD "payload"
        try pure (response (.ok (← dispatchHook input)), false)
        catch error => pure (response (.error error.toString), false)
    | some "ping" => pure (response (.ok ""), false)
    | some "shutdown" => pure (response (.ok ""), true)
    | _ => pure (response (.error "unknown daemon request"), false)

/--
Serve one transport occurrence.  The socket server owns framing only; semantic
serialization remains the per-session lock in `withSession`, so unrelated Codex
sessions can saturate concurrently without weakening one-session atomicity.
-/
def serveClient (secret : String) (stopping : IO.Ref Bool)
    (client : Socket.Client) : IO Unit := do
  let (reply, stop) ← try
      let bytes ← receiveFrame client
      let text ← match String.fromUTF8? bytes with
        | some text => pure text
        | none => throw (IO.userError "daemon request is not UTF-8")
      let json ← match Json.parse text with
        | .ok json => pure json
        | .error message => throw (IO.userError message)
      serveRequest secret json
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

def finishClients (tasks : List (Task (Except IO.Error Unit))) : IO Unit := do
  for task in tasks do
    if let .error error ← IO.wait task then
      IO.eprintln s!"eggshelld client: {error}"

def removeEndpointIfOwned (endpoint : Endpoint) : IO Unit := do
  let path ← endpointPath
  try
    if let some current ← (readJson? path : IO (Option Endpoint)) then
      if current.secret = endpoint.secret then removeIfExists path
  catch _ => pure ()

def run : IO UInt32 := do
  let path ← endpointPath
  if let some parent := path.parent then IO.FS.createDirAll parent
  let server ← Socket.Server.mk
  server.bind (loopback 0)
  server.listen 128
  server.noDelay
  let address ← server.getSockName
  let secret := Blake3.hex (← IO.getRandomBytes 32)
  let endpoint : Endpoint := {
    port := address.port.toNat
    secret
    generation := ← desiredGeneration
  }
  writeJson path endpoint
  Persistence.privateFile path
  let stopping ← IO.mkRef false
  let mut clients : List (Task (Except IO.Error Unit)) := []
  try
    while !(← stopping.get) do
      match ← server.tryAccept with
      | none => IO.sleep 1
      | some client =>
          clients := (← IO.asTask (serveClient secret stopping client)) :: clients
      clients ← retainRunning clients
    finishClients clients
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
    (payload : Json := Json.null) : IO String := do
  let client ← connect endpoint
  sendFrame client (request endpoint.secret kind payload |>.compress |>.toUTF8)
  let bytes ← receiveFrame client
  let text ← match String.fromUTF8? bytes with
    | some text => pure text
    | none => throw (IO.userError "daemon response is not UTF-8")
  let json ← match Json.parse text with
    | .ok json => pure json
    | .error message => throw (IO.userError message)
  if json.getObjValD "ok" == true then
    pure ((optionalString json "output").getD "")
  else throw (IO.userError ((optionalString json "error").getD "daemon failure"))

def loadEndpoint : IO Endpoint := do
  let path ← endpointPath
  let some endpoint ← (readJson? path : IO (Option Endpoint)) |
    throw (IO.userError "eggshelld is not running")
  pure endpoint

def spawn : IO Unit := do
  let executable ← daemonExecutable
  let _ ← IO.Process.spawn {
    cmd := executable.toString
    args := #["codex-daemon"]
    stdin := .null
    stdout := .null
    stderr := .null
    setsid := true
  }
  pure ()

def readyEndpoint : IO Endpoint := do
  let endpoint ← loadEndpoint
  let expected ← desiredGeneration
  if !endpoint.compatible expected then
    throw (IO.userError "eggshelld executable generation is stale")
  let _ ← exchange endpoint "ping"
  pure endpoint

partial def awaitEndpoint : Nat → IO Endpoint
  | 0 => throw (IO.userError "eggshelld did not become ready")
  | attempts + 1 =>
      try
        readyEndpoint
      catch _ =>
        IO.sleep 10
        awaitEndpoint attempts

def ensure : IO Endpoint := do
  try
    readyEndpoint
  catch _ =>
    /-
    A hook runner can be killed at its deadline while it owns the startup
    directory.  The daemon is the real authority: give a concurrent launcher
    time to publish a live endpoint, then reclaim an ownerless startup lock.
    This keeps cold starts serial without making one interrupted hook disable
    every future Codex session.
    -/
    let startup := ← startupLock
    let lease := Persistence.lockPath startup
    if ← lease.pathExists then
      try return ← awaitEndpoint startupAttempts
      catch _ =>
        try IO.FS.removeDir lease catch _ => pure ()
    Persistence.withLock (← startupLock) do
      try
        readyEndpoint
      catch _ =>
        /-
        A generation mismatch is an orderly upgrade, not a connection error.
        Stop the stale owner before publishing the replacement endpoint. The
        old process removes the endpoint only when its secret still owns it,
        so it cannot unlink the replacement in the shutdown race.
        -/
        try
          let stale ← loadEndpoint
          let _ ← exchange stale "shutdown"
        catch _ => pure ()
        removeIfExists (← endpointPath)
        spawn
        awaitEndpoint startupAttempts

def call (kind : String) (payload : Json := Json.null) : IO String := do
  exchange (← ensure) kind payload

def attachClientConfig (input : Json) (config : Option String) : Json :=
  match config with
  | some path => input.setObjVal! "_eggshell_config" path
  | none => input

def hookClient : IO UInt32 := do
  let inputText ← (← IO.getStdin).readToEnd
  match Json.parse inputText with
  | .error message =>
      IO.eprintln s!"Eggshell ignored malformed hook input: {message}"
      IO.println emptyHook
      pure 0
  | .ok input =>
      try
        let input := attachClientConfig input (← IO.getEnv "EGGSHELL_CONFIG")
        IO.println (← call "hook" input)
        pure 0
      catch error =>
        IO.eprintln s!"Eggshell hook failed open: {error}"
        IO.println emptyHook
        pure 0

def shutdown : IO Unit := do
  try
    let endpoint ← loadEndpoint
    let _ ← exchange endpoint "shutdown"
    pure ()
  catch _ => removeIfExists (← endpointPath)

end Eggshell.Plugin.Daemon
