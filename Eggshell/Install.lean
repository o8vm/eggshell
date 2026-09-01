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
  "version": "0.1.1",
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

structure Layout where
  root : System.FilePath
  executable : System.FilePath
  launcher : System.FilePath
  plugin : System.FilePath
  marketplace : System.FilePath
  payloadMarker : System.FilePath
  bootstrapMarker : System.FilePath

def Layout.at (root : System.FilePath) : Layout := {
  root
  executable := root / "libexec" / "eggshell"
  launcher := root / "bin" / "egg"
  plugin := root / "plugins" / "eggshell"
  marketplace := root / ".agents" / "plugins" / "marketplace.json"
  payloadMarker := root / "share" / "eggshell" / ".eggshell-owner"
  bootstrapMarker := root / "libexec" / "eggshell.owner"
}

def installLayout : IO Layout := do
  pure (Layout.at (← Paths.installRoot))

def commandLauncher : String := r#"#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
EGGSHELL_PREFIX=$(CDPATH= cd "$bin_dir/.." && pwd)
export EGGSHELL_PREFIX
exec "$EGGSHELL_PREFIX/libexec/eggshell" egg "$@"
"#

def shellQuote (value : String) : String :=
  "'" ++ value.replace "'" "'\"'\"'" ++ "'"

def pluginLauncher (root : System.FilePath) : String :=
  "#!/bin/sh\nset -eu\nEGGSHELL_PREFIX=" ++ shellQuote root.toString ++ r#"
export EGGSHELL_PREFIX
case "${1-}" in
  codex-hook|codex-daemon) exec "$EGGSHELL_PREFIX/libexec/eggshell" "$@" ;;
  *) exec "$EGGSHELL_PREFIX/libexec/eggshell" egg "$@" ;;
esac
"#

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

def writeExecutable (target : System.FilePath) (contents : String) : IO Unit := do
  if let some parent := target.parent then IO.FS.createDirAll parent
  let temporary := System.FilePath.mk (target.toString ++ ".next")
  IO.FS.writeFile temporary contents
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
    if (← IO.FS.readBinFile launcher) != commandLauncher.toUTF8 then
      throw (IO.userError s!"refusing to replace unowned launcher {launcher}")

def validatePayload (layout : Layout) : IO Unit := do
  let managedExists ← layout.executable.pathExists
  if managedExists then
    let marked ← if ← layout.payloadMarker.pathExists then
      pure ((← IO.FS.readFile layout.payloadMarker) == ownerMarkerContents)
      else pure false
    let runningInstaller ← sameFileContents layout.executable (← IO.appPath)
    if !marked && !runningInstaller then
      throw (IO.userError s!"refusing to replace unowned executable {layout.executable}")
  validateManagedPaths layout.plugin layout.launcher

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
    ("name", "eggshell"),
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

def codexMarketplaceList : IO (List (String × System.FilePath)) := do
  let output ← IO.Process.output {
    cmd := "codex"
    args := #["plugin", "marketplace", "list", "--json"]
  }
  if output.exitCode != 0 then
    throw (IO.userError s!"codex plugin marketplace list failed: {output.stderr}")
  let document ← match Json.parse output.stdout with
    | .ok document => pure document
    | .error message => throw (IO.userError s!"invalid Codex marketplace list: {message}")
  let entries := match document.getObjValD "marketplaces" with
    | .arr values => values.toList
    | _ => []
  pure (entries.filterMap fun entry =>
    let name := (entry.getObjVal? "name").toOption.bind fun value =>
      value.getStr?.toOption
    let root := (entry.getObjVal? "root").toOption.bind fun value =>
      value.getStr?.toOption
    match name, root with
    | some name, some root => some (name, (System.FilePath.mk root).normalize)
    | _, _ => none)

def ensureCodexMarketplace (layout : Layout) : IO Unit := do
  let configured ← codexMarketplaceList
  match configured.find? (·.1 = "eggshell") with
  | some (_, root) =>
      if root != layout.root.normalize then
        throw (IO.userError s!"Codex marketplace eggshell already points to {root}")
  | none =>
      let output ← IO.Process.output {
        cmd := "codex"
        args := #["plugin", "marketplace", "add", layout.root.toString, "--json"]
      }
      if output.exitCode != 0 then
        throw (IO.userError s!"codex plugin marketplace add failed: {output.stderr}")

def removeCodexMarketplace (layout : Layout) : IO Unit := do
  let configured ← codexMarketplaceList
  if let some (_, root) := configured.find? (·.1 = "eggshell") then
    if root != layout.root.normalize then
      throw (IO.userError s!"refusing to remove Codex marketplace eggshell at {root}")
    let output ← IO.Process.output {
      cmd := "codex"
      args := #["plugin", "marketplace", "remove", "eggshell", "--json"]
    }
    if output.exitCode != 0 then
      throw (IO.userError s!"codex plugin marketplace remove failed: {output.stderr}")

def installCodex : IO String := do
  let layout ← installLayout
  validatePayload layout
  validateMarketplace layout.marketplace
  Plugin.Daemon.shutdown
  let executable ← IO.appPath
  copyExecutable executable layout.executable
  writeExecutable layout.launcher commandLauncher
  IO.FS.writeFile layout.bootstrapMarker ownerMarkerContents
  Persistence.privateFile layout.bootstrapMarker
  if let some parent := layout.payloadMarker.parent then IO.FS.createDirAll parent
  IO.FS.writeFile layout.payloadMarker ownerMarkerContents
  MiniLM.install layout.root
  if ← layout.plugin.pathExists then IO.FS.removeDirAll layout.plugin
  IO.FS.createDirAll (layout.plugin / ".codex-plugin")
  IO.FS.createDirAll (layout.plugin / "hooks")
  IO.FS.writeFile (layout.plugin / ownerMarkerName) ownerMarkerContents
  IO.FS.writeFile (layout.plugin / ".codex-plugin" / "plugin.json") pluginManifest
  IO.FS.writeFile (layout.plugin / "hooks" / "hooks.json") hooksManifest
  let cachedLauncher := pluginLauncher layout.root
  writeExecutable (layout.plugin / "bin" / "egg") cachedLauncher
  writeExecutable (layout.plugin / "bin" / "eggshelld") cachedLauncher
  let marketplaceName ← updateMarketplace layout.marketplace true
  ensureCodexMarketplace layout
  try codexPlugin "remove" marketplaceName catch _ => pure ()
  codexPlugin "add" marketplaceName
  pure s!"installed Eggshell at {layout.root} with CPU MiniLM; review its hooks with /hooks"

def uninstallCodex : IO String := do
  let layout ← installLayout
  validatePayload layout
  validateMarketplace layout.marketplace
  Plugin.Daemon.shutdown
  let marketplaceName ← updateMarketplace layout.marketplace false
  try codexPlugin "remove" marketplaceName catch _ => pure ()
  removeCodexMarketplace layout
  if ← layout.plugin.pathExists then IO.FS.removeDirAll layout.plugin
  if ← layout.launcher.pathExists then IO.FS.removeFile layout.launcher
  if ← layout.executable.pathExists then IO.FS.removeFile layout.executable
  let minilm := MiniLM.supportRoot layout.root
  if ← minilm.pathExists then IO.FS.removeDirAll minilm
  if ← layout.payloadMarker.pathExists then IO.FS.removeFile layout.payloadMarker
  if ← layout.bootstrapMarker.pathExists then IO.FS.removeFile layout.bootstrapMarker
  pure "uninstalled Eggshell Plugin and MiniLM runtime; .egg authorities, config, and staged data were preserved"

def command (installing : Bool) : IO UInt32 := do
  try
    IO.println (← if installing then installCodex else uninstallCodex)
    pure 0
  catch error =>
    IO.eprintln s!"eggshell: {error}"
    pure 1

end Eggshell.Install
