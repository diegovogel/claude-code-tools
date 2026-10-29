# AutoCAD extension gotchas

Lessons learned building and testing AutoCAD .NET extensions. Read the headers, then the sections that touch the task. Each entry is a one-line tip or a Symptom / Cause / Fix. Add new ones as you learn them (SKILL.md, rule 7).

## Workflow rules

- Judge every Core Console run by its output, never its exit code: accoreconsole exits 0 even after `Unknown command` or a failed NETLOAD. `scripts/run-core-console.sh` does this for you. _Discovered: 2026-10-28_
- Before an experiment, decide the one thing it should prove and have it print a marker for that. A run with no marker proves only that nothing crashed. _Discovered: 2026-10-28_

## Core Console

### Hangs forever when run from Git Bash

**Symptom:** accoreconsole prints its usage text, then waits for input until it's killed.
**Cause:** Git Bash (MSYS) rewrites arguments that start with `/` (`/s`, `/i`, `/p`) into POSIX paths, so Core Console sees no valid switches and drops into interactive mode.
**Fix:** prefix the call with `MSYS_NO_PATHCONV=1`, and always run it under `timeout`. The same goes for any Windows tool with `/` switches, such as tf.exe and reg.exe. _Discovered: 2026-10-28_

- Output is UTF-16LE. `tr -d '\000'` makes it greppable for ASCII; decode properly if you need non-ASCII text. _Discovered: 2026-10-28_
- The `/s` script path must be absolute. A relative path prints `"x.scr": Can't find file.`, runs nothing, and still exits 0. _Discovered: 2026-10-28_
- Long script paths fail too: a 290-character path gave `Invalid file name` (even with the `\\?\` prefix Core Console adds), while about 200 characters worked. Keep QA folders shallow. _Discovered: 2026-10-28_
- `(getcname "MYCMD")` returns nil for an unregistered command and works for .NET commands, so it checks that NETLOAD registered a command without running it (verified against LINE and a made-up name). _Discovered: 2026-10-28_
- An unknown command (or any script error) aborts the rest of the script, so later lines never run. A missing end marker is how you notice. _Discovered: 2026-10-28_
- QUIT on a modified drawing asks `Really want to discard all changes to drawing? <N>`. Answer `_Y`, or the run hangs. _Discovered: 2026-10-28_
- Without `/p`, Core Console uses AutoCAD's current profile; the startup line `Drawing created using acad.dwt from AutoCAD profile: <<...>>` says which. `/product ACADE /p "<<ACADE>>"` works for AutoCAD Electrical. _Discovered: 2026-10-28_
- `(layoutlist)` is undefined in Core Console (`; error: no function definition: LAYOUTLIST`), like the other ActiveX-era Visual LISP helpers. Read paper space size from `LIMMAX` instead, or list layouts from .NET. _Discovered: 2026-10-29_
- `(princ "x")` prints x and then the echo of its return value. End probe lines with `(princ)` for clean output. _Discovered: 2026-10-28_
- Script files run with either CRLF or LF line endings (both verified), so there's no need to convert by hand. _Discovered: 2026-10-28_
- A Core Console crash leaves no trace in its output: the text just stops, and the runner reports `script never reached its end marker`. The Windows Application event log has the details: `.NET Runtime` event 1026 with the exception and `Application Error` event 1000 with the faulting module. In PowerShell: `Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddMinutes(-15)} | Where-Object Message -match accoreconsole`. _Discovered: 2026-10-28_

## Load security (SECURELOAD, trusted locations)

### NETLOAD fails with only "Unable to load ... assembly."

**Symptom:** NETLOAD prints `Unable to load <path> assembly.` and nothing else, so the plugin's commands are then unknown. `/loadmodule` fails silently, and LISP `load` prints `; error: File load canceled`.
**Cause:** SECURELOAD is 1 (the default) and the file is outside every trusted location. Core Console cancels the load instead of prompting.
**Fix:** have the user add a dev folder to Trusted Locations and stage builds there (`headless-testing.md`). Never set SECURELOAD to 0. _Discovered: 2026-10-28_

- Trusted locations and SECURELOAD are stored per profile, as `TRUSTEDPATHS` and `SECURELOAD` under `HKCU\Software\Autodesk\AutoCAD\R25.1\ACAD-<id>\Profiles\<profile>\Variables`. Reading them there is a quick check of what the user set; never write them. _Discovered: 2026-10-28_
- A trusted path ending in `\...` trusts its subfolders too (verified by loading from a subfolder). AutoCAD stores it with `%UserProfile%` in place of the user folder. _Discovered: 2026-10-28_

## Building

- The .NET 10 SDK builds `net8.0-windows` projects fine; the first restore downloads the .NET 8 reference pack. _Discovered: 2026-10-28_
- Referencing accoremgd and acdbmgd gives MSB3277 version-conflict warnings unless the project sets both `<UseWPF>true</UseWPF>` and `<UseWindowsForms>true</UseWindowsForms>`. `UseWPF` also drops `System.IO` from the implicit usings, so `Path`, `File` and `StringWriter` stop compiling until you add `using System.IO;`. _Discovered: 2026-10-28_
- Referencing acmgd doesn't stop Core Console from loading an assembly: one that references acmgd loaded, registered its commands, and its `IExtensionApplication.Initialize` wrote to the editor through `Autodesk.AutoCAD.ApplicationServices.Application.DocumentManager`. Community sources say real UI (dialogs, palettes, ribbon) fails or crashes there; not yet tested here. _Discovered: 2026-10-28_
- AutoCAD references without `<Private>false</Private>` copy about 35 AutoCAD DLLs (AcWindows, AdWindows, Newtonsoft.Json and more) into the build output. Staging only your own DLL and .pdb works, because AutoCAD loads its own assemblies from its install folder. _Discovered: 2026-10-28_
- An incremental build that recompiles nothing reports 0 warnings. Count warnings only from `dotnet build --no-incremental`, which takes seconds for a typical extension. _Discovered: 2026-10-28_
- Older extensions often keep their `.csproj` at the root of the source folder, so its default `**/*.cs` glob would also compile test projects placed in subfolders. Exclude them in the main project with `<DefaultItemExcludes>$(DefaultItemExcludes);Tests\**</DefaultItemExcludes>`. _Discovered: 2026-10-28_
- `dotnet sln add` added `Debug|x86` and `Release|x86` platforms to a solution that only had Any CPU and x64. Check the `.sln` diff and remove them before sharing the change. _Discovered: 2026-10-28_

## Testing

### A unit test can't load acdbmgd, though the DLL is right there

**Symptom:** a `dotnet test` test fails with `System.IO.FileNotFoundException: Could not load file or assembly '...\Acdbmgd.dll'. The specified module could not be found.`, while Acdbmgd.dll sits in the test output folder.
**Cause:** the code under test touched an AutoCAD type. AutoCAD's managed DLLs wrap its native engine, which exists only inside AutoCAD, so the module that can't be found is a native dependency.
**Fix:** keep AutoCAD types out of code you unit test, or move the test into the in-process tests (`headless-testing.md`), where the same call works (verified with the same call both ways). _Discovered: 2026-10-28_

- NUnit runs tests on a worker thread of its own unless told otherwise, and AutoCAD's API isn't safe there. Pass NUnitLite's `--mainthread` (present in 5.0.0). Verified: with it, tests ran on the command's thread; without it, on another one. _Discovered: 2026-10-28_
- An NUnitLite run whose `--where` filter matches nothing exits 0 (result Inconclusive, 0 tests). Judge the run by the `total` and `failed` attributes of the `--result` XML's root, not by the exit code alone. _Discovered: 2026-10-28_

## Loading and reloading

- .NET assemblies can't be unloaded from AutoCAD, so picking up a new build means restarting it (Core Console restarts on every run anyway). Full AutoCAD also locks the DLL it loaded, so stage each build into a new folder. _Discovered: 2026-10-28_

## Plotting

- Headless PNG output works with the `PublishToWeb PNG.pc3` device and the `XGA (1024.00 x 768.00 Pixels)` paper size. The full `-PLOT` answer sequence is in `headless-testing.md`. _Discovered: 2026-10-28_
- A .NET multi-sheet plot (`PlotFactory.CreatePublishEngine` with a `PlotProgressDialog`, the pattern of the widely copied multi-sheet sample) crashed Core Console with `AccessViolationException` right after it switched layouts. Whether the dialog or the engine is to blame is untested; `-PLOT` from a script works. _Discovered: 2026-10-28_
- To look at a plotted PDF on a machine without PDF tools, render it from PowerShell 5.1 with Windows' built-in `Windows.Data.Pdf.PdfDocument` (load the WinRT types, await `LoadFromFileAsync`, then `GetPage(0).RenderToStreamAsync` into an `InMemoryRandomAccessStream`; `PdfPageRenderOptions.SourceRect` crops a region). `PdfPage.Size` is in 1/96-inch units, not points: a 42 x 30 inch sheet reports 4032 x 2880. _Discovered: 2026-10-29_
- Before QA of a command that plots, check where every configured device and output path goes. A plotter queue on a mapped drive looks just like a folder, and a QA plot sent there prints for real. _Discovered: 2026-10-29_
- `PlotSettingsValidator.GetPlotDeviceList()` lists `None`, then the machine's Windows printers, then the PC3 devices, so a device's number differs between machines. Never hard-code a device number in a shared test. _Discovered: 2026-10-28_

## Source control (TFVC)

- tf.exe ships with Visual Studio at `<VS install>\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe`; `vswhere -find "**\TF.exe"` finds it. In VS 2026, per-command help is `tf vc help <command>`; `tf help <command>` only prints a banner. _Discovered: 2026-10-28_
- `tf vc workspace /new /noprompt` maps the whole collection (`$/`) to the current folder. Run `tf vc workfold /unmap $/`, then map only the project folder, before the first get, or you'll download everything. _Discovered: 2026-10-28_
- Keep machine-specific files (a private git repo, notes, test output) in a folder above the mapped workspace folder, where TFVC can't see them, rather than listing them in a `.tfignore`, which is itself a shared file. _Discovered: 2026-10-28_
- In a local workspace, files are writable and edits show up in `tf vc status` on their own, with no checkout step. `tf vc undo <file> /noprompt` restores the server version. _Discovered: 2026-10-28_
- Claude's Edit tool kept UTF-8 BOM and CRLF line endings intact on legacy C# files (checked with `file`), so a whole-file diff after an edit means something else rewrote the file. _Discovered: 2026-10-28_
- Older TFVC repos often track `obj/`. To keep builds from editing those files, put a `Directory.Build.props` in the folder above the workspace that sets `<UseArtifactsOutput>true</UseArtifactsOutput>` and `<ArtifactsPath>$(MSBuildThisFileDirectory)artifacts</ArtifactsPath>`. Builds then write there, and `tf vc status` stayed clean (verified). _Discovered: 2026-10-28_
