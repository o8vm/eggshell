module

public import Eggshell.Install

@[expose] public section

namespace Eggshell.Setup
open Lean

inductive Action where
  | inspect | initialize
  deriving BEq, DecidableEq

def action (configured checkOnly : Bool) : Action :=
  if configured || checkOnly then .inspect else .initialize

theorem configured_is_preserved (checkOnly : Bool) : action true checkOnly = .inspect := rfl
theorem check_never_initializes (configured : Bool) : action configured true = .inspect := by
  simp [action]
theorem initialize_only_when_missing (configured checkOnly : Bool)
    (h : action configured checkOnly = .initialize) : configured = false ∧ checkOnly = false := by
  cases configured <;> cases checkOnly <;> simp_all [action]

def report (project : System.FilePath) : IO Json := do
  let out ← IO.Process.output {
    cmd := (← IO.appPath).toString
    args := #["egg", "doctor"]
    cwd := some project
    env := #[("CODEX_THREAD_ID", none)] }
  if out.exitCode != 0 then throw (IO.userError out.stderr)
  IO.ofExcept (Json.parse out.stdout)

def command (args : List String) : IO UInt32 := do
  let rec parse (project : System.FilePath) (checkOnly : Bool) : List String → Except String _
    | [] => .ok (project, checkOnly)
    | "--project" :: value :: rest => parse (.mk value) checkOnly rest
    | "--check" :: rest => parse project true rest
    | _ => .error "usage: eggshell setup [--project PATH] [--check]"
  let (project, checkOnly) ← IO.ofExcept (parse (← IO.currentDir) false args)
  let project ← IO.FS.realPath project
  if !(← project.isDir) then throw (IO.userError "project must be a directory")
  let existing ← report project
  match action (existing.getObjValD "configuration" == .str "ready") checkOnly with
  | .inspect => pure ()
  | .initialize =>
      let _ ← IO.Process.run {
        cmd := (← IO.appPath).toString
        args := #["egg", "init"]
        cwd := some project
        env := #[("CODEX_THREAD_ID", none)] }
      pure ()
  let final ← report project
  IO.println final.pretty
  pure (if final.getObjValD "configuration" == .str "ready" then 0 else 1)

end Eggshell.Setup
