# Runs AutoCAD Core Console (accoreconsole.exe) headlessly on a file of script
# steps and judges the run from its output, because accoreconsole exits 0 even
# when commands fail. Written for Windows PowerShell 5.1.
#
# Usage: run-core-console.ps1 <steps-file> [drawing.dwg]
#   <steps-file>  Script lines, LF or CRLF, in UTF-8 (a BOM is fine). Don't end
#                 with QUIT: the runner appends an end marker and a
#                 discard-and-quit. Lines starting with ";EXPECT " are
#                 assertions, not script: the run fails unless each one's text
#                 appears in the output.
#   [drawing]     Drawing to open (/i). Changes are always discarded.
#
# Environment overrides:
#   ACAD_DIR      AutoCAD install folder (default: C:\Program Files\Autodesk\AutoCAD 2026)
#   ACAD_PRODUCT  /product flag, e.g. ACADE for AutoCAD Electrical (default: none)
#   ACAD_PROFILE  /p flag, e.g. <<ACADE>> (default: AutoCAD's current profile)
#   RUN_TIMEOUT   Seconds before the run and its child processes are killed (default: 120)
#
# Writes <steps-file minus extension>.out.txt (decoded output) next to the steps file.
# Exit codes: 0 pass, 1 failure found in output, 2 timeout (usually a prompt waiting for input).

param([string]$StepsFile, [string]$Drawing)

# Any error before a verdict (a bad argument or setting) exits 1, like a failed
# run. Left alone, it would leave $LASTEXITCODE unset or exit -1 under -File.
trap { [Console]::Error.WriteLine("run-core-console: $($_.Exception.Message)"); exit 1 }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $StepsFile) { throw 'usage: run-core-console.ps1 <steps-file> [drawing.dwg]' }
$acadDir = if ($env:ACAD_DIR) { $env:ACAD_DIR } else { 'C:\Program Files\Autodesk\AutoCAD 2026' }
$exe = Join-Path $acadDir 'accoreconsole.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "accoreconsole.exe not found in $acadDir (set ACAD_DIR)" }
$timeout = if ($env:RUN_TIMEOUT) { $env:RUN_TIMEOUT } else { '120' }
$seconds = 0.0
if (-not [double]::TryParse($timeout, 'Float', [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or $seconds -le 0) {
    throw "RUN_TIMEOUT must be a number of seconds, not '$timeout'"
}

$steps = (Resolve-Path -LiteralPath $StepsFile).ProviderPath
$base = Join-Path (Split-Path $steps) ([IO.Path]::GetFileNameWithoutExtension($steps))
$runScr = "$base.run.scr"
$raw = "$base.raw.txt"
$out = "$base.out.txt"

# Text that isn't valid UTF-8 is read in the ANSI code page instead, which is
# how Core Console itself reads a script without a BOM.
function Read-Text([string]$path) {
    try { [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true)) }
    catch [Text.DecoderFallbackException] { [IO.File]::ReadAllText($path, [Text.Encoding]::Default) }
}

$text = Read-Text $steps
$lines = @($text.Replace("`r", '') -split "`n")
if ($lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
$expects = @($lines | Where-Object { $_ -cmatch '^;EXPECT ' } | ForEach-Object { $_.Substring(8) })

# Written as CRLF, AutoCAD's native script format (LF also works), and as UTF-8
# with a BOM, because Core Console reads a script without one in the ANSI code
# page. The marker is split with strcat so the echoed command line never
# matches it; only a script that really reached the end prints it.
$scriptLines = @($lines | Where-Object { $_ -cnotmatch '^;EXPECT ' })
$scriptLines += '(princ (strcat "\nRUNNER-" "END"))', '_.QUIT', '_Y'
[IO.File]::WriteAllText($runScr, ($scriptLines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))

# Paths must be absolute: a relative /s path gives "Can't find file" (and exit 0).
$argv = @()
if ($Drawing) { $argv += '/i', $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Drawing) }
$argv += '/s', $runScr
if ($env:ACAD_PRODUCT) { $argv += '/product', $env:ACAD_PRODUCT }
if ($env:ACAD_PROFILE) { $argv += '/p', $env:ACAD_PROFILE }
# Windows PowerShell has no ProcessStartInfo.ArgumentList, so quote by hand the
# way Windows splits a command line: backslashes before a quote are doubled.
$cmdLine = ($argv | ForEach-Object {
    if ($_ -and $_ -notmatch '[\s"]') { $_ }
    else { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
}) -join ' '

$psi = [Diagnostics.ProcessStartInfo]::new($exe, $cmdLine)
$psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# A stdin pipe that stays open and never sends anything, so a prompt left
# waiting hangs until the timeout. With stdin at end of file (NUL) the prompt
# reads garbage instead, and the run can crash and still exit 0.
$psi.RedirectStandardInput = $true

$rawFile = [IO.File]::Create($raw)
$errBuf = [IO.MemoryStream]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$proc = [Diagnostics.Process]::Start($psi)
$copies = [Threading.Tasks.Task[]]($proc.StandardOutput.BaseStream.CopyToAsync($rawFile), $proc.StandardError.BaseStream.CopyToAsync($errBuf))
$timedOut = -not $proc.WaitForExit([int][Math]::Min($seconds * 1000, [int]::MaxValue))
if ($timedOut) {
    # /T also ends the conhost.exe that Core Console starts as a child. The
    # catch is for a run that ended just now: under a caller's 2> redirect,
    # Windows PowerShell turns taskkill's "not found" on stderr into an exception.
    try { taskkill.exe /PID $proc.Id /T /F | Out-Null } catch { }
}
$elapsed = [int]$clock.Elapsed.TotalSeconds
# stderr goes after stdout, as with 2>&1 (Core Console writes none).
if ([Threading.Tasks.Task]::WaitAll($copies, 10000)) { $errBuf.WriteTo($rawFile) }
$rawFile.Dispose()
$proc.Dispose()

# Output is UTF-16LE with no BOM.
$text = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($raw))
$outLines = @($text.Replace("`r", '') -split "`n" | Where-Object { $_ -ne '' -and -not $_.Contains('CoreHeartBeat') })

# Core Console's first line names a temp file that it deletes only when the run
# ends through QUIT, so aborted, crashed and killed runs leave it behind. After
# a .NET crash it holds the error and stack trace, which never reach the
# output: add any text in it to the output, then delete it.
$tmp = $outLines | ForEach-Object { if ($_ -cmatch '^Redirect stdout \(file: (.+\\accc\d+)\)\.$') { $Matches[1] } } | Select-Object -First 1
if ($tmp -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
    try {
        $left = @((Read-Text $tmp).Replace("`r", '') -split "`n" | Where-Object { $_ -ne '' })
        if ($left.Count) { $outLines += "---- text Core Console left in $tmp ----"; $outLines += $left }
        Remove-Item -LiteralPath $tmp -Force
    } catch { $outLines += "---- couldn't read or delete ${tmp}: $($_.Exception.Message) ----" }
}
[IO.File]::WriteAllLines($out, [string[]]$outLines, [Text.UTF8Encoding]::new($true))

$outLines
'----'
if ($timedOut) {
    "RUNNER: TIMEOUT after ${timeout}s, usually a prompt waiting for input (see the last lines above)"
    exit 2
}

# "Can't find file" and "Invalid file name" mean Core Console couldn't open the
# script itself, usually because the path is relative or over 259 characters.
$problems = @($outLines |
    Select-String -CaseSensitive "Unknown command|; error:|Unable to load|Invalid option keyword|Unhandled exception|FATAL ERROR|Can't find file|Invalid file name" |
    ForEach-Object { "$($_.LineNumber):$($_.Line)" })
if (-not ($outLines -cmatch 'RUNNER-END')) { $problems += 'script never reached its end marker' }
# Echoed script lines ("Command: ...") don't count, so a match means the text was printed.
$printed = @($outLines -cnotmatch '^Command: ')
foreach ($want in $expects) {
    if (-not ($printed | Where-Object { $_.Contains($want) })) { $problems += "expected text not found: $want" }
}
if ($problems.Count) {
    "RUNNER: FAIL in ${elapsed}s"
    $problems
    exit 1
}
"RUNNER: PASS in ${elapsed}s"
exit 0
