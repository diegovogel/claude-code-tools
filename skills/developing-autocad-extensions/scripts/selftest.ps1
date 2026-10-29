# Checks that run-core-console.ps1 tells a passing run from failing ones.
# Run it after changing the runner. Needs AutoCAD 2026; takes about 15 seconds.
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'run-core-console.ps1'
$temp = [IO.Path]::GetTempPath()
$dir = Join-Path $temp ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory $dir | Out-Null
$fails = 0

# check <name> <expected runner exit code> <regex a line of its output must match> <steps lines...>
# The run must also leave none of Core Console's temp files (accc<N>) behind.
function check([string]$name, [int]$want, [string]$sign) {
    $steps = Join-Path $dir "$name.steps"
    [IO.File]::WriteAllLines($steps, [string[]]$args)  # UTF-8 without a BOM, like Claude's Write tool
    $before = @(Get-ChildItem $temp -Filter 'accc*' -File | ForEach-Object Name)
    $log = @(& $runner $steps 2>&1 | ForEach-Object { "$_" })
    $got = $LASTEXITCODE
    $left = @(Get-ChildItem $temp -Filter 'accc*' -File | Where-Object { $before -notcontains $_.Name } | ForEach-Object Name)
    if ($got -eq $want -and ($log -cmatch $sign) -and -not $left.Count) {
        "ok     $name (exit $got)"
    } else {
        "WRONG  ${name}: exit $got, wanted $want and a line matching $sign" + $(if ($left.Count) { "; left $left behind" })
        $log | Select-Object -Skip ([Math]::Max(0, [array]::IndexOf($log, '----')))
        $script:fails++
    }
}

try {
    check pass 0 '^RUNNER: PASS' '(princ (strcat "\nGOT-" "ONE"))(princ)' ';EXPECT GOT-ONE'
    check missing-expectation 1 '^expected text not found: GOT-TWO$' '(princ (strcat "\nGOT-" "ONE"))(princ)' ';EXPECT GOT-TWO'
    check unknown-command 1 '^\d+:Unknown command' 'NOSUCHCOMMAND'
    check lisp-error 1 '^\d+:; error:' '(car 1)'
    # Built from char codes to keep this file ASCII: Windows PowerShell reads a
    # .ps1 without a BOM in the ANSI code page. The omega isn't in that code page,
    # so a lossy step on the way (an ANSI script, NUL-stripped output) fails too.
    $text = "45$([char]0xB0)$([char]0xD8)$([char]0x3A9)"
    check non-ascii 0 "^GOT-$text$" "(princ (strcat `"\nGOT-`" `"$text`"))(princ)" ";EXPECT GOT-$text"
    # getpoint can't take the lines the runner appends as its answer, so the
    # prompt waits for input until the timeout.
    $saved = $env:RUN_TIMEOUT
    $env:RUN_TIMEOUT = 5
    try { check timeout 2 '^RUNNER: TIMEOUT' '(getpoint "\nPICK A POINT: ")' } finally { $env:RUN_TIMEOUT = $saved }
} finally {
    Remove-Item -Recurse -Force $dir
}
exit $fails
