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

lean_exe eggshell_package where
  root := `tools.Package

lean_exe search_tests where
  root := `tests.SearchTests

lean_exe setup_package_tests where
  root := `tests.SetupPackageTests

lean_exe lifecycle_tests where
  root := `tests.LifecycleTests

lean_exe eggshell_render where
  root := `tools.Render
