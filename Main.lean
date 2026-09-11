module

public import Eggshell.Install

@[expose] public section

def usage : String :=
  "usage: eggshell install codex\n       eggshell install runtime\n       eggshell uninstall codex\n       egg init\n       egg [COMMAND]"

def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["codex-hook"] => Eggshell.Plugin.Daemon.hookClient
  | ["codex-daemon", "shutdown"] => do
      Eggshell.Plugin.Daemon.shutdown
      pure 0
  | ["codex-daemon", session] => Eggshell.Plugin.Daemon.run session
  | ["codex-worker", role] => Eggshell.Plugin.Worker.run role
  | ["codex-rpc", kind] => Eggshell.Plugin.Daemon.rpcClient kind
  | ["egg", "init"] => Eggshell.Install.initCommand
  | ["egg", "uninstall", "codex"] => Eggshell.Install.command false
  | "egg" :: rest => Eggshell.Plugin.eggControl rest
  | ["init"] => Eggshell.Install.initCommand
  | ["install", "runtime"] => Eggshell.Install.runCommand Eggshell.Install.installRuntime
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
