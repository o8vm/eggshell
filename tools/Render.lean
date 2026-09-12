module

public import Eggshell.Sha256

@[expose] public section

open Eggshell

def run (cmd : String) (args : Array String) : IO Unit := do
  let _ ← IO.Process.run { cmd, args }

/-- Version-controlled SVGs are the editable artwork. Rasterization and video
    encoding are delegated to their native rendering tools, never to Python. -/
def social : IO Unit := do
  let root : System.FilePath := "docs/assets/brand"
  for theme in ["light", "dark"] do
    let name := "github-social-preview-" ++ theme ++ "-1280x640"
    run "rsvg-convert" #[(root / (name ++ ".svg")).toString, "-o", (root / (name ++ ".png")).toString]

def demo : IO Unit := do
  let record ← IO.FS.readBinFile "docs/benchmarks/llvm-follow-up.json"
  if Sha256.hex record != "a1dd0a7d1abffbbe7322279769fb20328ef0e42009d558e7d472a26b26c3d498" then
    throw (IO.userError "Measurement record changed; review the SVG figures and update their evidence fingerprint before rendering")
  let root ← IO.FS.realPath "docs/assets/demo"
  let temporary ← IO.FS.createTempDir
  try
    let names := ["01-investigate", "02-reuse", "03-continue", "04-results"]
    let mut images := #[]
    for name in names do
      let image := temporary / (name ++ ".png")
      run "rsvg-convert" #[(root / (name ++ ".svg")).toString, "-o", image.toString]
      images := images.push image.toString
    run "magick" (#["-delay", "750"] ++ images ++ #["-loop", "0", "-layers", "Optimize", (root / "walkthrough.gif").toString])
    let frames := String.intercalate "" (images.toList.map fun image => "file '" ++ image ++ "'\nduration 7.5\n") ++
      "file '" ++ images.back! ++ "'\n"
    let concat := temporary / "frames.txt"
    IO.FS.writeFile concat frames
    run "ffmpeg" #["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
      "-i", concat.toString, "-t", "30", "-r", "24", "-c:v", "libx264", "-crf", "20",
      "-pix_fmt", "yuv420p", "-movflags", "+faststart", (root / "walkthrough.mp4").toString]
  finally IO.FS.removeDirAll temporary

def main (args : List String) : IO UInt32 := do
  match args with
  | ["social"] => social *> pure 0
  | ["demo"] => demo *> pure 0
  | _ => throw (IO.userError "usage: eggshell_render social|demo")
