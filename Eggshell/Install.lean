module

public import Eggshell.Daemon

@[expose] public section

namespace Eggshell.Install

open Lean

def projectConfig : String := r#"default = "work"

[eggs]
project = ".eggs/work.egg"

[profiles.work]
read = ["project"]
write = "project"

[profiles.private]
read = ["project"]

[profiles.off]
read = []
"#

def initProject (root : System.FilePath) : IO String := do
  let config := root / ".eggshell.toml"
  if ← config.pathExists then
    throw (IO.userError s!"{config} already exists")
  let authority := root / ".eggs"
  Persistence.privateDirectory authority
  let ignore := authority / ".gitignore"
  if !(← ignore.pathExists) then
    IO.FS.writeFile ignore "*\n!.gitignore\n"
  IO.FS.writeFile config projectConfig
  pure s!"initialized Eggshell at {config}"

def initCommand : IO UInt32 := do
  try
    IO.println (← initProject (← IO.currentDir))
    pure 0
  catch error =>
    IO.eprintln s!"egg: {error}"
    pure 1

def pluginManifest : String := r##"{
  "name": "eggshell",
  "version": "0.1.0",
  "description": "Reduce repeated Codex work with a persistent, user-controlled work graph",
  "author": {
    "name": "o8vm",
    "url": "https://github.com/o8vm"
  },
  "homepage": "https://github.com/o8vm/eggshell",
  "repository": "https://github.com/o8vm/eggshell",
  "license": "Apache-2.0",
  "keywords": ["codex", "agent-memory", "work-graph", "productivity"],
  "interface": {
    "displayName": "Eggshell",
    "shortDescription": "Continue related work without rediscovering it.",
    "longDescription": "Eggshell records native Codex work in user-controlled .egg files, then uses Union and saturation to hand later sessions reusable outcomes and an open frontier.",
    "developerName": "o8vm",
    "category": "Productivity",
    "capabilities": [],
    "websiteURL": "https://github.com/o8vm/eggshell",
    "brandColor": "#F7F3EA",
    "defaultPrompt": [
      "Continue this task from relevant prior work without repeating completed investigation."
    ]
  }
}"##

def hooksManifest : String := r#"{
  "description": "Select prior work before Codex acts and stage the completed turn.",
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "timeout": 30}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "additionalContextLimit": 48000, "timeout": 30}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "additionalContextLimit": 48000, "timeout": 30}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "additionalContextLimit": 48000, "timeout": 30}]}],
    "PostCompact": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "timeout": 3}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "timeout": 3}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "\"${PLUGIN_ROOT}/bin/egg\" codex-hook", "timeout": 3}]}]
  }
}"#

def home : IO System.FilePath := do
  match ← IO.getEnv "HOME" with
  | some home => pure (System.FilePath.mk home)
  | none => throw (IO.userError "HOME is unavailable")

def copyExecutable (source target : System.FilePath) : IO Unit := do
  if let some parent := target.parent then IO.FS.createDirAll parent
  /-
  Never rewrite a running Plugin executable in place. macOS may kill the old
  mapped image after its vnode changes, and a resident daemon would then keep
  serving the previous semantics. Publish a fresh inode atomically instead.
  -/
  let temporary := System.FilePath.mk (target.toString ++ ".next")
  IO.FS.writeBinFile temporary (← IO.FS.readBinFile source)
  IO.setAccessRights temporary {
    user := { read := true, write := true, execution := true }
    group := { read := true, execution := true }
    other := { read := true, execution := true }
  }
  IO.FS.rename temporary target

def ownerMarkerName : String := ".eggshell-owner"
def ownerMarkerContents : String := "o8vm/eggshell\n"

def ownedManifest (json : Json) : Bool :=
  json.getObjValD "name" == "eggshell" &&
    json.getObjValD "repository" == "https://github.com/o8vm/eggshell"

/-- Installation may replace only a directory previously identified as Eggshell. -/
def ownedPluginRoot (root : System.FilePath) : IO Bool := do
  if !(← root.pathExists) then pure false
  else
    let marker := root / ownerMarkerName
    if ← marker.pathExists then
      pure ((← IO.FS.readFile marker) = ownerMarkerContents)
    else
      let manifest := root / ".codex-plugin" / "plugin.json"
      if !(← manifest.pathExists) then pure false
      else
        match Json.parse (← IO.FS.readFile manifest) with
        | .ok json => pure (ownedManifest json)
        | .error _ => pure false

def sameFileContents (left right : System.FilePath) : IO Bool := do
  if !(← left.pathExists) || !(← right.pathExists) then pure false
  else pure ((← IO.FS.readBinFile left) == (← IO.FS.readBinFile right))

def validateManagedPaths (root launcher : System.FilePath) : IO Unit := do
  let rootExists ← root.pathExists
  if rootExists && !(← ownedPluginRoot root) then
    throw (IO.userError s!"refusing to replace unowned Plugin directory {root}")
  if ← launcher.pathExists then
    if !rootExists || !(← sameFileContents launcher (root / "bin" / "egg")) then
      throw (IO.userError s!"refusing to replace unowned launcher {launcher}")

def marketplaceEntry : Json := Json.mkObj [
  ("name", "eggshell"),
  ("source", Json.mkObj [("source", "local"), ("path", "./plugins/eggshell")]),
  ("policy", Json.mkObj [("installation", "AVAILABLE"), ("authentication", "ON_INSTALL")]),
  ("category", "Productivity")
]

def isEggshellEntry (json : Json) : Bool :=
  json.getObjValD "name" == (.str "eggshell")

def isOwnedEggshellEntry (json : Json) : Bool :=
  isEggshellEntry json &&
    json.getObjValD "source" == marketplaceEntry.getObjValD "source"

def marketplaceDocument (path : System.FilePath) : IO Json := do
  if ← path.pathExists then
    match Json.parse (← IO.FS.readFile path) with
    | .ok document => pure document
    | .error message => throw (IO.userError s!"{path}: {message}")
  else pure (Json.mkObj [
    ("name", "personal"),
    ("interface", Json.mkObj [("displayName", "Personal")]),
    ("plugins", .arr #[])
  ])

def marketplacePlugins (document : Json) : List Json :=
  match document.getObjValD "plugins" with
  | .arr plugins => plugins.toList
  | _ => []

def validateMarketplace (path : System.FilePath) : IO Unit := do
  let existing := marketplacePlugins (← marketplaceDocument path)
  if existing.any fun entry => isEggshellEntry entry && !isOwnedEggshellEntry entry then
    throw (IO.userError "refusing to replace an unowned marketplace entry named eggshell")

def updateMarketplace (path : System.FilePath) (installing : Bool) : IO String := do
  let document ← marketplaceDocument path
  let name := document.getObjValD "name" |>.getStr? |>.toOption |>.getD "personal"
  let existing := marketplacePlugins document
  if existing.any fun entry => isEggshellEntry entry && !isOwnedEggshellEntry entry then
    throw (IO.userError "refusing to replace an unowned marketplace entry named eggshell")
  let retained := existing.filter (!isOwnedEggshellEntry ·)
  let plugins := if installing then retained ++ [marketplaceEntry] else retained
  let updated := document.setObjVal! "plugins" (.arr plugins.toArray)
  if let some parent := path.parent then IO.FS.createDirAll parent
  let temporary := System.FilePath.mk (path.toString ++ ".next")
  IO.FS.writeFile temporary updated.pretty
  IO.FS.rename temporary path
  pure name

def codexPlugin (command marketplace : String) : IO Unit := do
  let output ← IO.Process.output {
    cmd := "codex"
    args := #["plugin", command, s!"eggshell@{marketplace}", "--json"]
  }
  if output.exitCode != 0 then
    throw (IO.userError s!"codex plugin {command} failed: {output.stderr}")

def installCodex : IO String := do
  let userHome ← home
  let root := userHome / "plugins" / "eggshell"
  let marketplace := userHome / ".agents" / "plugins" / "marketplace.json"
  let launcher := userHome / ".local" / "bin" / "egg"
  validateManagedPaths root launcher
  validateMarketplace marketplace
  Plugin.Daemon.shutdown
  MiniLM.install userHome
  if ← root.pathExists then IO.FS.removeDirAll root
  IO.FS.createDirAll (root / ".codex-plugin")
  IO.FS.createDirAll (root / "hooks")
  IO.FS.writeFile (root / ownerMarkerName) ownerMarkerContents
  IO.FS.writeFile (root / ".codex-plugin" / "plugin.json") pluginManifest
  IO.FS.writeFile (root / "hooks" / "hooks.json") hooksManifest
  let executable ← IO.appPath
  copyExecutable executable (root / "bin" / "egg")
  copyExecutable executable (root / "bin" / "eggshelld")
  copyExecutable executable launcher
  let marketplaceName ← updateMarketplace marketplace true
  try codexPlugin "remove" marketplaceName catch _ => pure ()
  codexPlugin "add" marketplaceName
  pure s!"installed Eggshell Codex Plugin with CPU MiniLM at {root}; review its hooks with /hooks"

def uninstallCodex : IO String := do
  let userHome ← home
  let root := userHome / "plugins" / "eggshell"
  let marketplace := userHome / ".agents" / "plugins" / "marketplace.json"
  let launcher := userHome / ".local" / "bin" / "egg"
  validateManagedPaths root launcher
  validateMarketplace marketplace
  Plugin.Daemon.shutdown
  let marketplaceName ← updateMarketplace marketplace false
  try codexPlugin "remove" marketplaceName catch _ => pure ()
  if ← root.pathExists then IO.FS.removeDirAll root
  if ← launcher.pathExists then IO.FS.removeFile launcher
  pure "uninstalled Eggshell Plugin; .egg authorities and staged data were preserved"

def command (installing : Bool) : IO UInt32 := do
  try
    IO.println (← if installing then installCodex else uninstallCodex)
    pure 0
  catch error =>
    IO.eprintln s!"eggshell: {error}"
    pure 1

end Eggshell.Install
