import Lake

open Lake DSL

package eggshell where
  leanOptions := #[⟨`warningAsError, true⟩]

lean_lib Eggshell

@[default_target]
lean_exe eggshell where
  root := `Main

lean_exe eggshell_tests where
  root := `TestMain
