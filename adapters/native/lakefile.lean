import Lake
open Lake DSL

package eggshellAdapters where
  leanOptions := #[⟨`warningAsError, true⟩]

require eggshell from "../.."

lean_lib Adapter

@[default_target]
lean_exe eggshell_bridge where
  root := `Main

lean_exe adapter_tests where
  root := `Tests
