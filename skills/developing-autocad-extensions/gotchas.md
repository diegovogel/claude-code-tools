# AutoCAD extension gotchas

Lessons learned building and testing AutoCAD .NET extensions. Read the headers, then the sections that touch the task. Each entry is a one-line tip or a Symptom / Cause / Fix. Add new ones as you learn them (SKILL.md, rule 7).

## Workflow rules

- Judge every Core Console run by its output, never its exit code: accoreconsole exits 0 even after `Unknown command` or a failed NETLOAD. `scripts/run-core-console.ps1` does this for you. _Discovered: 2026-10-28_
- Before an experiment, decide the one thing it should prove and have it print a marker for that. A run with no marker proves only that nothing crashed. _Discovered: 2026-10-28_

## Core Console

### Hangs forever when called from Git Bash

**Symptom:** accoreconsole called by hand from Git Bash prints its usage text, then waits for input until it's killed.
**Cause:** Git Bash (MSYS) rewrites arguments that start with `/` (`/s`, `/i`, `/p`) into POSIX paths, so Core Console sees no valid switches and drops into interactive mode.
**Fix:** use the runner (PowerShell rewrites nothing). To call accoreconsole from Git Bash anyway, prefix the call with `MSYS_NO_PATHCONV=1` and run it under `timeout`. The same goes for any Windows tool with `/` switches, such as tf.exe and reg.exe. _Discovered: 2026-10-28_

- Output is UTF-16LE with no BOM, whether it goes to a file or a pipe. Decode it as UTF-16LE (the runner does): stripping the NUL bytes keeps only ASCII intact. _Discovered: 2026-10-28_
- The `/s` script path must be absolute. A relative path prints `"x.scr": Can't find file.`, runs nothing, and still exits 0. _Discovered: 2026-10-28_
- Long script paths fail too: a 290-character path gave `Invalid file name` (even with the `\\?\` prefix Core Console adds), while about 200 characters worked. Windows PowerShell 5.1 can't open paths that long at all, so the runner reports `Cannot find path ... because it does not exist` for a steps file that's there. Claude's session scratchpad can be that deep, so keep QA folders shallow, such as `%TEMP%\<name>`. _Discovered: 2026-10-28_
- `(getcname "MYCMD")` returns nil for an unregistered command and works for .NET commands, so it checks that NETLOAD registered a command without running it (verified against LINE and a made-up name). _Discovered: 2026-10-28_
- An unknown command (or any script error) aborts the rest of the script, so later lines never run. A missing end marker is how you notice. _Discovered: 2026-10-28_
- QUIT on a modified drawing asks `Really want to discard all changes to drawing? <N>`. Answer `_Y`, or the run hangs. _Discovered: 2026-10-28_
- With stdin at end of file (`NUL`, or as Claude Code's Bash and PowerShell tools run commands), a prompt doesn't wait for input: it reads U+FFFF characters, and a `getpoint` went on to `; error: Exception occurred: 0xC0000005 (Access Violation)` and exit code 0. Given an open stdin that sends nothing, it waits until killed; the runner sets that up, so a prompt left waiting always ends in TIMEOUT. _Discovered: 2026-10-29_
- Without `/p`, Core Console uses AutoCAD's current profile; the startup line `Drawing created using acad.dwt from AutoCAD profile: <<...>>` says which. `/product ACADE /p "<<ACADE>>"` works for AutoCAD Electrical. _Discovered: 2026-10-28_
- `/p` doesn't only pick the profile for that run: it makes it AutoCAD's current profile, which later runs without `/p` use too, as does full AutoCAD started without one. One test run with `/p <<VANILLA>>` left later runs on a profile with no trusted locations, so NETLOAD failed with `Unable to load`. One run with the original profile switches it back (verified both ways). _Discovered: 2026-10-29_
- `(layoutlist)` is undefined in Core Console (`; error: no function definition: LAYOUTLIST`), like the other ActiveX-era Visual LISP helpers. Read paper space size from `LIMMAX` instead, or list layouts from .NET. _Discovered: 2026-10-29_
- `(princ "x")` prints x and then the echo of its return value. End probe lines with `(princ)` for clean output. _Discovered: 2026-10-28_
- Script files run with either CRLF or LF line endings (both verified), so there's no need to convert by hand. _Discovered: 2026-10-28_
- Core Console reads a script without a BOM in the ANSI code page, so UTF-8 text such as `°` arrives as `Â°`. UTF-8 with a BOM and UTF-16LE with a BOM both work (verified with `°Ø€Ω`); the runner writes UTF-8 with a BOM. _Discovered: 2026-10-29_
- Every run starts by naming a temp file, `Redirect stdout (file: %TEMP%\accc<N>)`. Core Console deletes it only when the run ends through QUIT, so aborted, crashed and killed runs leave it behind, usually empty, and those pile up in `%TEMP%`. The runner deletes it after every run. _Discovered: 2026-10-29_
- A Core Console crash cuts the output short, and editor messages written just before it can be lost too (a marker written right before the fault never appeared). The .NET error and stack trace land in that temp file instead, in ANSI rather than UTF-16, and the runner adds them to the end of its output (verified with a plug-in that crashes on purpose). They match `.NET Runtime` event 1026 in the Windows Application event log. Neither names the plug-in's own method; `Application Error` event 1000 adds the faulting module. In PowerShell: `Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddMinutes(-15)} | Where-Object Message -match accoreconsole`. Where Windows Error Reporting's `LocalDumps` key exists, each crash also leaves a minidump of about 20 MB in `%LOCALAPPDATA%\CrashDumps`, which Windows caps at 10 files by default. _Discovered: 2026-10-28_

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

### Saving a never-saved drawing writes Drawing1.dwg into the startup folder

**Symptom:** a `Database.SaveAs(doc.Name, ...)` meant to "save the open drawing" silently creates `Drawing1.dwg` in an unexpected folder, overwriting any file of that name, and the document is then named there. In a feature test run from a source folder, the file landed in the source tree.
**Cause:** an unsaved drawing's `doc.Name` is just `Drawing1.dwg`, and AutoCAD resolves it against `DWGPREFIX`, the folder AutoCAD or Core Console started in. Changing .NET's `Environment.CurrentDirectory` doesn't move it (verified). `HostApplicationServices.FindFile(doc.Name, ...)` throws `eFilerError` for the same drawing.
**Fix:** check `Document.IsNamedDrawing` before saving or looking up the drawing's file (`DWGTITLED` is the system variable). Start Core Console in a disposable folder (the process's working directory), so a test that saves the startup drawing can't write into your repo; a drawing AutoCAD has open can't be deleted by the test afterwards. _Discovered: 2026-11-12_

## Dialogs (WinForms)

- A WinForms dialog can be constructed and laid out in Core Console without being shown (`_ = form.Handle; form.PerformLayout();`), so its layout can be feature tested. Core Console reports 96 DPI, so a bug that only shows above 100% scaling can pass there. _Discovered: 2026-11-12_
- A form with `ControlBox = false` and a `Text` set after `ClientSize` (designer order) is sized with no title bar, then gains one without growing, so its bottom row is clipped: exactly flush at 96 DPI, 10 px short at 120. `AutoSize = true` with bottom/right `Padding` fixes it. It also resists a smaller `Size`, `Bounds` or Win32 `SetWindowPos` (though not the `ClientSize` setter, so test with `Size`). AutoCAD saves each `ShowModalDialog(form)` dialog's bounds per profile under `Profiles\<profile>\Dialogs\<form type>`, in 96-DPI units (542 x 303 for a 677 x 379 window at 125%). _Discovered: 2026-11-12_

### Labels drawn over buttons and text boxes above 100% scaling (.NET 8)

**Symptom:** in a dialog that looks fine at 100%, at 125% buttons show only a sliver and text boxes lose the start of their text ("IMINARY" for "PRELIMINARY"). The controls aren't clipped by the form edge; the labels beside them paint over them.
**Cause:** a .NET 8 WinForms bug. With `AutoScaleMode.Font`, a designer-written form that sets its `Font` after adding its controls (the designer's order) scales every `Label` twice: 1.78× at 125%, against 1.33× for buttons, text boxes and positions (measured with a minimal form). The labels then reach into the next control, and the designer's `Controls.Add` order puts them on top. .NET 10 (AutoCAD 2027) scales them once.
**Fix:** `AutoScaleDimensions = new SizeF(96F, 96F)` with `AutoScaleMode = AutoScaleMode.Dpi`. Every control then scales by 1.25 at 125%, and 100% is unchanged. Every designer form in the extension has the same shape, so check them all, not just the one reported: a label over the next control's left edge is easy to miss. Core Console and test hosts run at 96 DPI, so no automated test sees this. Check by rendering the form in a small system-DPI-aware exe (`Application.SetHighDpiMode(HighDpiMode.SystemAware)`, like `acad.exe`) and reading control bounds or a `CopyFromScreen` capture. _Discovered: 2026-11-12_

## Loading and reloading

- .NET assemblies can't be unloaded from AutoCAD, so picking up a new build means restarting it (Core Console restarts on every run anyway). Full AutoCAD also locks the DLL it loaded, so stage each build into a new folder. _Discovered: 2026-10-28_

## Plotting

- Headless PNG output works with the `PublishToWeb PNG.pc3` device and the `XGA (1024.00 x 768.00 Pixels)` paper size. The full `-PLOT` answer sequence is in `headless-testing.md`. _Discovered: 2026-10-28_
- A .NET multi-sheet plot (`PlotFactory.CreatePublishEngine` with a `PlotProgressDialog`, the pattern of the widely copied multi-sheet sample) crashed Core Console with `AccessViolationException` right after it switched layouts. Whether the dialog or the engine is to blame is untested; `-PLOT` from a script works. _Discovered: 2026-10-28_
- To look at a plotted PDF, render a page with `scripts/render-pdf.ps1`, which uses Windows' built-in `Windows.Data.Pdf` and needs nothing installed; render wide and crop with System.Drawing to read small text. `PdfPage.Size` is in 1/96-inch units, not points: a 42 x 30 inch sheet reports 4032 x 2880. The pdf-viewer plugin and desktop extension can't open local files on Windows (every path is "not in allowed list"; modelcontextprotocol/ext-apps#644 and #816, unfixed as of 2026-11-05), so don't spend time configuring them. _Discovered: 2026-10-29, updated 2026-11-05_
- Before QA of a command that plots, check where every configured device and output path goes. A plotter queue on a mapped drive looks just like a folder, and a QA plot sent there prints for real. _Discovered: 2026-10-29_
### Back-to-back sheets from a .NET plot loop are silently skipped

**Symptom:** a command that plots several layouts one after another (each with its own `PlotFactory.CreatePublishEngine` job) produces only the first PDF. No error, and the Plot and Publish Details show one job with one sheet.
**Cause:** with `BACKGROUNDPLOT` at 2, AutoCAD's default, publish jobs finish in the background, and code that only plots while `PlotFactory.ProcessPlotState == NotPlotting` (a common pattern) skips every sheet that comes up while the previous job is still running.
**Fix:** run the loop with `BACKGROUNDPLOT` set to 0 and restore it afterwards (verified: the same run then plotted every layout). Leave the dev machine at 2 so QA reproduces what users get. _Discovered: 2026-11-11_

- `BACKGROUNDPLOT` is an `Int16` that `Application.SetSystemVariable` sets and restores from a command (verified in Core Console). It's saved with the user's settings, not the drawing, so restore it in a `finally` (or a disposable scope), including in tests. _Discovered: 2026-11-12_

- `PlotSettingsValidator.GetPlotDeviceList()` lists `None`, then the machine's Windows printers, then the PC3 devices, so a device's number differs between machines. Never hard-code a device number in a shared test. _Discovered: 2026-10-28_

## Source control (TFVC)

- tf.exe ships with Visual Studio at `<VS install>\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe`; `vswhere -find "**\TF.exe"` finds it. In VS 2026, per-command help is `tf vc help <command>`; `tf help <command>` only prints a banner. _Discovered: 2026-10-28_
- `tf vc workspace /new /noprompt` maps the whole collection (`$/`) to the current folder. Run `tf vc workfold /unmap $/`, then map only the project folder, before the first get, or you'll download everything. _Discovered: 2026-10-28_
- Keep machine-specific files (a private git repo, notes, test output) in a folder above the mapped workspace folder, where TFVC can't see them, rather than listing them in a `.tfignore`, which is itself a shared file. _Discovered: 2026-10-28_
- In a local workspace, files are writable and edits show up in `tf vc status` on their own, with no checkout step. `tf vc undo <file> /noprompt` restores the server version. _Discovered: 2026-10-28_
- Claude's Edit tool kept UTF-8 BOM and CRLF line endings intact on legacy C# files (checked with `file`), so a whole-file diff after an edit means something else rewrote the file. _Discovered: 2026-10-28_
- Older TFVC repos often track `obj/`. To keep builds from editing those files, put a `Directory.Build.props` in the folder above the workspace that sets `<UseArtifactsOutput>true</UseArtifactsOutput>` and `<ArtifactsPath>$(MSBuildThisFileDirectory)artifacts</ArtifactsPath>`. Builds then write there, and `tf vc status` stayed clean (verified). _Discovered: 2026-10-28_
