# Headless testing with AutoCAD Core Console

`accoreconsole.exe` lives in the AutoCAD install folder (`C:\Program Files\Autodesk\AutoCAD 2026`). It opens a drawing, or a new one from the profile's template, runs a script, and exits. A run takes 1 to 5 seconds. It loads the same .NET assemblies as AutoCAD, as long as they don't need the UI.

## The runner

```bash
scripts/run-core-console.sh <steps-file> [drawing.dwg]
```

- Appends an end marker and a discard-and-quit to your steps, converts them to CRLF, runs Core Console under a timeout, decodes the UTF-16 output into `<steps>.out.txt`, and prints it.
- Ends with a verdict line, `RUNNER: PASS`, `RUNNER: FAIL` (with the offending lines) or `RUNNER: TIMEOUT`, and exits 0, 1 or 2 to match.
- Lines starting with `;EXPECT ` are assertions: the runner strips them from the script and fails the run unless each one's text appears in the output. Echoed script lines (`Command: ...`) don't count.
- FAIL means one of: `Unknown command`, a LISP `; error:`, `Unable to load`, `Invalid option keyword`, an unhandled exception, `FATAL ERROR`, Core Console couldn't open the script (`Can't find file`, `Invalid file name`), the end marker never printed (the script aborted or crashed), or an `;EXPECT` text is missing.
- Environment: `ACAD_PRODUCT` and `ACAD_PROFILE` pick the product and profile (AutoCAD Electrical: `ACAD_PRODUCT=ACADE ACAD_PROFILE='<<ACADE>>'`), `ACAD_DIR` the install folder, `RUN_TIMEOUT` the timeout in seconds (default 120).
- The drawing is never saved, though the code under test can still save it itself, so test on copies.
- The run files (`*.run.scr`, `*.raw.txt`, `*.out.txt`) land next to the steps file; keep them out of version control.

A PASS with no `;EXPECT` lines only means nothing failed loudly. Prove the behavior: have the code print a computed result such as `MYCMD-OK count=3`, and add `;EXPECT MYCMD-OK count=3`. Build literal markers with `strcat`, so a script line swallowed as a prompt answer can't satisfy its own expectation through the echo.

After changing the runner, run `scripts/selftest.sh`. It checks one passing case and three failing ones, in about 10 seconds.

## Steps files

One script entry per line:

```
(command "_.NETLOAD" "C:/Users/<you>/AutoCAD-Dev/<build>/MyPlugin.dll")
MYCOMMAND
(princ (strcat "\nDIAG CLAYER=" (getvar "CLAYER")))(princ)
```

- At the command prompt and most option prompts a space acts as Enter, so pass anything containing spaces (paths, names) through AutoLISP `(command ...)`, with forward slashes in paths. Some string prompts, such as plot device and paper size names, take spaces literally.
- Prefix commands with `_.` (`_.ZOOM`, `_.NETLOAD`) so localized or redefined commands can't change the meaning.
- End probe lines with `(princ)` so the echo of the return value doesn't clutter the output.
- Answer every prompt explicitly. A missing answer turns the next line into the answer, and a script error aborts everything after it.
- Don't end with QUIT; the runner adds it.
- Keep steps files at short paths. Core Console can't open a script path of 290 characters.
- Lines starting with `;` are comments, skipped even while a command waits for input (`;EXPECT ` lines are the runner's own).

To check that NETLOAD registered a command without running it (`getcname` returns nil for unknown commands):

```
(princ (strcat "\nCHECK MYCMD=" (if (getcname "MYCMD") "found" "missing")))(princ)
;EXPECT CHECK MYCMD=found
```

## Staging builds

AutoCAD loads assemblies only from trusted locations (SECURELOAD=1, the default). Keep one dev folder trusted with its subfolders, for example `%UserProfile%\AutoCAD-Dev\...`, and copy each build into a new subfolder before loading it:

- Full AutoCAD locks a loaded DLL until it exits, so building in place fails while it's open; a fresh subfolder per build avoids the lock.
- Core Console starts clean on every run, so it always loads the copy you point it at.
- Stage only your own DLL and .pdb, plus any third-party DLLs you ship. The build output may also hold dozens of copied AutoCAD DLLs (see gotchas, Building); leave those behind.
- The user adds the trusted folder once: OPTIONS, Files tab, Trusted Locations, Add, type the path ending in `\...`, accept the "not read-only" warning, OK, then close AutoCAD so it saves. Trusted locations are per profile, so add it in the profile the tests run under. Never set it yourself through the registry.

## In-process tests (NUnit inside Core Console)

For code that needs a live drawing database. The test DLL carries NUnit and NUnitLite; Core Console NETLOADs it next to the extension, and a command in it runs the tests. Verified with NUnit and NUnitLite 5.0.0 on AutoCAD 2026.

- **Project:** `net8.0-windows` with `UseWPF` and `UseWindowsForms`, `CopyLocalLockFileAssemblies` (so the NUnit DLLs land in the output), the `NUnit` and `NUnitLite` packages, a project reference to the extension, and references to `accoremgd` and `acdbmgd` with `Private` false. No test SDK or adapter: `dotnet test` never runs it.
- **Runner command**, in the test DLL:

  ```csharp
  [CommandMethod("RUNTESTS")]
  public void Run()
  {
      Editor editor = Application.DocumentManager.MdiActiveDocument.Editor; // ApplicationServices.Core
      using var output = new StringWriter();
      int exitCode = new AutoRun(Assembly.GetExecutingAssembly()).Execute(
          new[] { "--mainthread", "--noheader", "--nocolor", "--labels=After", "--result=" + resultXmlPath },
          new ExtendedTextWrapper(output), TextReader.Null); // NUnit.Common.ExtendedTextWrapper
      editor.WriteMessage("\n{0}", output.ToString());
      // Then read total and failed from the result XML's root and print a PASS or FAIL marker.
  }
  ```

  `--mainthread` is required (gotchas, Testing). Compute the marker from the XML, because a filter that matches nothing exits 0, and `;EXPECT` the PASS marker in the steps file.
- **Filtering:** have the command prompt for an NUnit `--where` expression (`PromptStringOptions` with `AllowSpaces`), so the steps line after the command picks the tests (`test =~ Name`) and an empty line runs them all.
- **Staging:** copy the test DLL and .pdb, `nunit.framework.dll`, `nunit.framework.legacy.dll` and `nunitlite.dll` next to the extension's DLL. The steps NETLOAD the extension, then the test DLL, then run the command.
- **Test drawings:** `new Database(true, true)` gives an in-memory drawing with default contents, separate from the open document.
- A run takes 2 to 3 seconds.

## Plotting to PNG for a visual check

These steps plot the model space extents to a 1024x768 PNG:

```
_.ZOOM _E
-PLOT
Y
Model
PublishToWeb PNG.pc3
XGA (1024.00 x 768.00 Pixels)
L
N
E
F
C
Y
.
Y
A
C:\path\without\spaces\out.png
N
Y
```

The answers, in order: detailed configuration, layout, device, paper size, landscape, not upside down, extents, fit, centered, plot styles yes, no style table (`.`), lineweights yes, shade as displayed, file name, don't save the page setup, proceed. The file name was only tested without spaces.

## Reading the output

- `Drawing created using acad.dwt from AutoCAD profile: <<NAME>>` shows which profile the run used.
- `**** System Variable Changed ****` and `LogFilePath has been set to the working folder.` are normal startup noise.
