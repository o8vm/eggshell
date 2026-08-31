module

public import Eggshell.Matcher
public import Eggshell.Paths

@[expose] public section

namespace Eggshell.Config

structure Egg where
  name : String
  path : System.FilePath
  deriving Repr, DecidableEq

structure Profile where
  name : String
  read : List String := []
  write : Option String := none
  handoffChars : Nat := 120000
  /-- False retains advisory retrieval while disabling automatic operation reuse. -/
  localUnion : Bool := true
  deriving Repr, DecidableEq

structure Config where
  source : System.FilePath
  defaultProfile : String := "work"
  defaultWasSet : Bool := false
  /-- Explicit provider command, opt-out, or an omitted built-in MiniLM default. -/
  semanticMatcher : Option (List String) := none
  /-- Distinguishes an omitted built-in default from an explicit opt-out. -/
  semanticMatcherWasSet : Bool := false
  eggs : List Egg := []
  profiles : List Profile := []
  deriving Repr, DecidableEq

structure Selection where
  label : String
  semanticMatcher : Option (List String)
  read : List Egg
  write : Option Egg
  handoffChars : Nat
  localUnion : Bool := true
  deriving Repr, DecidableEq

inductive Section where
  | root
  | eggs
  | profile (name : String)
  deriving Repr, DecidableEq

structure ParseState where
  scope : Section := .root
  defaultProfile : Option String := none
  semanticMatcher : Option (List String) := none
  semanticMatcherWasSet : Bool := false
  eggs : List (String × String) := []
  profiles : List Profile := []

def trim (text : String) : String := text.trimAscii.copy

def stripCommentLoop : List Char → Bool → Bool → List Char
  | [], _, _ => []
  | character :: tail, quoted, escaped =>
      if character = '#' && !quoted then []
      else
        let nextQuoted := if character = '"' && !escaped then !quoted else quoted
        let nextEscaped := quoted && character = '\\' && !escaped
        character :: stripCommentLoop tail nextQuoted nextEscaped

/-- TOML comments begin outside strings; paths containing `#` remain intact. -/
def stripComment (text : String) : String :=
  String.ofList (stripCommentLoop text.toList false false)

def unquote (text : String) : Except String String :=
  let value := trim text
  if value.length ≥ 2 && value.startsWith "\"" && value.endsWith "\"" then
    pure ((value.drop 1).take (value.length - 2)).copy
  else
    throw s!"expected quoted TOML string, got {value}"

def boolean (text : String) : Except String Bool :=
  match trim text with
  | "true" => pure true
  | "false" => pure false
  | value => throw s!"expected TOML boolean, got {value}"

def arrayStrings (text : String) : Except String (List String) := do
  let value := trim text
  if !(value.startsWith "[" && value.endsWith "]") then
    throw s!"expected TOML string array, got {value}"
  let body := ((value.drop 1).take (value.length - 2)).copy
  if trim body = "" then pure []
  else body.splitOn "," |>.map trim |>.filter (!·.isEmpty) |>.mapM unquote

def assignment (line : String) : Except String (String × String) :=
  match line.splitOn "=" with
  | [] | [_] => throw s!"expected TOML assignment, got {line}"
  | key :: values => pure (trim key, trim ("=".intercalate values))

def upsertProfile (profiles : List Profile) (profile : Profile) : List Profile :=
  profile :: profiles.filter (·.name != profile.name)

def alterProfile (state : ParseState) (name : String)
    (change : Profile → Profile) : ParseState :=
  let profile := state.profiles.find? (·.name == name) |>.getD { name }
  { state with profiles := upsertProfile state.profiles (change profile) }

def parseHeader (line : String) : Except String Section := do
  if !(line.startsWith "[" && line.endsWith "]") then
    throw s!"invalid TOML section {line}"
  let name := ((line.drop 1).take (line.length - 2)).copy
  if name = "eggs" then pure .eggs
  else if let some profile := (name.dropPrefix? "profiles.").map (·.toString) then
    pure (.profile profile)
  else throw s!"unknown Eggshell config section [{name}]"

def parseLine (state : ParseState) (raw : String) : Except String ParseState := do
  let line := trim (stripComment raw)
  if line = "" then pure state
  else if line.startsWith "[" then
    pure { state with scope := ← parseHeader line }
  else
    let (key, value) ← assignment line
    match state.scope with
    | .root =>
        if key = "default" then
          pure { state with defaultProfile := some (← unquote value) }
        else if key = "semantic_matcher" then
          if trim value = "false" then
            pure { state with
              semanticMatcher := none
              semanticMatcherWasSet := true }
          else
            let command ← arrayStrings value
            if command.isEmpty then
              throw "semantic_matcher must name an executable or be false"
            pure { state with
              semanticMatcher := some command
              semanticMatcherWasSet := true }
        else throw s!"unknown Eggshell config key {key}"
    | .eggs =>
        pure { state with eggs := (key, ← unquote value) :: state.eggs }
    | .profile name =>
        if key = "read" then
          let names ← arrayStrings value
          pure (alterProfile state name fun profile =>
            { profile with read := names })
        else if key = "write" then
          let target ← unquote value
          pure (alterProfile state name fun profile =>
            { profile with write := some target })
        else if key = "handoff_chars" then
          match value.toNat? with
          | some budget =>
              pure (alterProfile state name fun profile =>
                { profile with handoffChars := budget })
          | none => throw s!"invalid handoff_chars {value}"
        else if key = "local_union" then
          let enabled ← boolean value
          pure (alterProfile state name fun profile =>
            { profile with localUnion := enabled })
        else throw s!"unknown profile key {key}"

def logicalLines (text : String) : List String :=
  let rec go (lines : List String) (openArray : Option String)
      (result : List String) : List String :=
    match lines with
    | [] => (openArray.toList ++ result).reverse
    | raw :: tail =>
        let line := trim raw
        match openArray with
        | some accumulated =>
            let joined := accumulated ++ " " ++ line
            if line.endsWith "]" then go tail none (joined :: result)
            else go tail (some joined) result
        | none =>
            let parts := line.splitOn "="
            let startsArray := match parts with
              | _ :: value :: _ => (trim value).startsWith "["
              | _ => false
            if startsArray && !line.endsWith "]" then
              go tail (some line) result
            else go tail none (line :: result)
  go (text.splitOn "\n") none []

def expandPath (source : System.FilePath) (raw : String) : IO System.FilePath := do
  let expanded ← if raw.startsWith "~/" then
      match ← IO.getEnv "HOME" with
      | some home => pure (System.FilePath.mk home / (raw.drop 2).copy)
      | none => throw (IO.userError "HOME is unavailable")
    else pure (System.FilePath.mk raw)
  if expanded.isAbsolute then pure expanded.normalize
  else pure ((source.parent.getD ".") / expanded).normalize

def parse (source : System.FilePath) (text : String) : IO Config := do
  let state ← match (logicalLines text).foldlM parseLine {} with
    | .ok state => pure state
    | .error message => throw (IO.userError s!"{source}: {message}")
  let eggs ← state.eggs.reverse.mapM fun (name, rawPath) => do
    let path ← expandPath source rawPath
    pure { name, path }
  pure {
    source
    defaultProfile := state.defaultProfile.getD "work"
    defaultWasSet := state.defaultProfile.isSome
    semanticMatcher := state.semanticMatcher
    semanticMatcherWasSet := state.semanticMatcherWasSet
    eggs
    profiles := state.profiles.reverse
  }

def parseFile (path : System.FilePath) : IO Config := do
  parse path (← IO.FS.readFile path)

def insideProject (root path : System.FilePath) : Bool :=
  let rootParts := root.normalize.components
  let pathParts := path.normalize.components
  !pathParts.contains ".." && rootParts.length < pathParts.length &&
    rootParts.isPrefixOf pathParts

/--
Repository data may select only repository-owned authorities. Shared authorities
and executable matchers remain user-owned global configuration.
-/
def admitProject (config : Config) : Except String Config := do
  if config.semanticMatcher.isSome then
    throw "project .eggshell.toml cannot execute semantic_matcher; configure custom providers in the user-owned global Eggshell config"
  let root := config.source.parent.getD "." |>.normalize
  for egg in config.eggs do
    if !insideProject root egg.path then
      throw s!"project egg {egg.name} must be a path below {root}"
  let eggNames := config.eggs.map (·.name)
  for profile in config.profiles do
    if profile.read.any (!eggNames.contains ·) ||
        profile.write.any (!eggNames.contains ·) then
      throw s!"project profile {profile.name} may reference only eggs declared by this project"
  if config.defaultWasSet && config.profiles.all (·.name != config.defaultProfile) then
    throw "project default must name a profile declared by this project"
  pure config

def nearestProjectConfig (start : System.FilePath) : IO (Option System.FilePath) :=
  let rec go : Nat → System.FilePath → IO (Option System.FilePath)
    | 0, _ => pure none
    | fuel + 1, directory => do
        let candidate := directory / ".eggshell.toml"
        if ← candidate.pathExists then pure (some candidate)
        else match directory.parent with
          | some parent =>
              if parent == directory then pure none
              else go fuel parent
          | none => pure none
  go (start.toString.length + 1) start

def globalPath : IO (Option System.FilePath) := do
  pure (some (← Paths.globalConfig))

def merge (base overlay : Config) : Config :=
  let eggs := overlay.eggs ++ base.eggs.filter fun egg =>
    overlay.eggs.all (·.name != egg.name)
  let profiles := overlay.profiles ++ base.profiles.filter fun profile =>
    overlay.profiles.all (·.name != profile.name)
  {
    source := overlay.source
    defaultProfile := if overlay.defaultWasSet then
      overlay.defaultProfile else base.defaultProfile
    defaultWasSet := overlay.defaultWasSet || base.defaultWasSet
    semanticMatcher := if overlay.semanticMatcherWasSet then
      overlay.semanticMatcher else base.semanticMatcher
    semanticMatcherWasSet := overlay.semanticMatcherWasSet ||
      base.semanticMatcherWasSet
    eggs
    profiles
  }

def loadWith (cwd : System.FilePath) (explicit : Option String) : IO (Option Config) := do
  if let some explicit := explicit then
    if !explicit.trimAscii.isEmpty then
      return some (← parseFile (System.FilePath.mk explicit).normalize)
  let global ← match ← globalPath with
    | some path =>
        if ← path.pathExists then pure (some (← parseFile path))
        else pure none
    | none => pure none
  let project ← match ← nearestProjectConfig cwd with
    | some path => do
        let config ← parseFile path
        match admitProject config with
        | .ok admitted =>
            if let some base := global then
              if admitted.eggs.any fun egg => base.eggs.any (·.name == egg.name) then
                throw (IO.userError s!"{path}: project egg names cannot shadow global eggs")
            pure (some admitted)
        | .error message => throw (IO.userError s!"{path}: {message}")
    | none => pure none
  pure <| match global, project with
    | none, none => none
    | some config, none | none, some config => some config
    | some base, some overlay => some (merge base overlay)

def load (cwd : System.FilePath) : IO (Option Config) := do
  loadWith cwd (← IO.getEnv "EGGSHELL_CONFIG")

def resolve (config : Config) (profileName : String) : Except String Selection := do
  let profile ← match config.profiles.find? (·.name == profileName) with
    | some profile => pure profile
    | none => throw s!"unknown Eggshell profile {profileName}"
  let resolveEgg name := match config.eggs.find? (·.name == name) with
    | some egg => pure egg
    | none => throw s!"profile {profileName} names unknown egg {name}"
  let mut reads ← profile.read.mapM resolveEgg
  let write ← profile.write.mapM resolveEgg
  if let some target := write then
    if !reads.contains target then reads := reads ++ [target]
  pure {
    label := profileName
    semanticMatcher := config.semanticMatcher
    read := reads.eraseDups
    write
    handoffChars := profile.handoffChars
    localUnion := profile.localUnion
  }

end Eggshell.Config
