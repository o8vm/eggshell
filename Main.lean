module

public import Eggshell.Install

@[expose] public section

def usage : String :=
  "usage: eggshell install codex\n       eggshell uninstall codex\n       egg init\n       egg [COMMAND]"

def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["codex-hook"] => Eggshell.Plugin.Daemon.hookClient
  | ["codex-daemon"] => Eggshell.Plugin.Daemon.run
  | ["codex-daemon", "shutdown"] => do
      Eggshell.Plugin.Daemon.shutdown
      pure 0
  | "egg" :: rest => Eggshell.Plugin.eggControl rest
  | ["init"] => Eggshell.Install.initCommand
  | ["install", "codex"] => Eggshell.Install.command true
  | ["uninstall", "codex"] => Eggshell.Install.command false
  | _ =>
      if (← IO.appPath).fileName = some "egg" then
        Eggshell.Plugin.eggControl arguments
      else if arguments.isEmpty || arguments = ["--help"] || arguments = ["-h"] then
        IO.println usage
        pure 0
      else
        IO.eprintln usage
        pure 1
