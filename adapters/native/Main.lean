module

public import Adapter.Runtime
public import Adapter.Install
public import Eggshell.SearchProvider

@[expose] public section

open Lean Eggshell Eggshell.Plugin Eggshell.Adapter

def main (args : List String) : IO UInt32 := do
  try
    if (← IO.getEnv "PLUGIN_ROOT").isSome then
      let child ← IO.Process.spawn {
        cmd := (← IO.appPath).toString
        args := args.toArray
        env := #[("PLUGIN_ROOT", none)] }
      return ← child.wait
    match args with
    | "search-provider" :: options => Eggshell.SearchProvider.run options
    | ["hook", host] => hook (← IO.ofExcept (Host.parse host))
    | ["ack", host] => acknowledge (← IO.ofExcept (Host.parse host))
    | "install" :: host :: options => Eggshell.Adapter.Install.command (← IO.ofExcept (Host.parse host)) options
    | "control" :: host :: "--session" :: session :: commands =>
        control (← IO.ofExcept (Host.parse host)) session commands
    | ["codex-daemon", session] => Daemon.run session
    | ["codex-worker", role] => Worker.run role
    | ["codex-rpc", kind] => Daemon.rpcClient kind
    | "egg" :: rest => eggControl rest
    | ["--help"] =>
        IO.println "Eggshell adapter bridge: hook HOST | ack HOST | install HOST [--project PATH] [--uninstall] | control HOST --session ID COMMAND"
        pure 0
    | _ => throw (IO.userError "invalid adapter command; use --help")
  catch error =>
    IO.eprintln s!"Eggshell adapter: {error}"
    pure 1
