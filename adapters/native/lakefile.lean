import Lake
open Lake DSL

package eggshellAdapters where
  leanOptions := #[⟨`warningAsError, true⟩]

require eggshell from "../.."

@[default_target]
lean_exe eggshell_bridge where
  root := `Main
