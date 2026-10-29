#!/usr/bin/env bash
# Runs AutoCAD Core Console (accoreconsole.exe) headlessly on a file of script
# steps and judges the run from its output, because accoreconsole exits 0 even
# when commands fail.
#
# Usage: run-core-console.sh <steps-file> [drawing.dwg]
#   <steps-file>  Script lines, LF or CRLF. Don't end with QUIT: the runner
#                 appends an end marker and a discard-and-quit. Lines starting
#                 with ";EXPECT " are assertions, not script: the run fails
#                 unless each one's text appears in the output.
#   [drawing]     Drawing to open (/i). Changes are always discarded.
#
# Environment overrides:
#   ACAD_DIR      AutoCAD install folder (default: C:/Program Files/Autodesk/AutoCAD 2026)
#   ACAD_PRODUCT  /product flag, e.g. ACADE for AutoCAD Electrical (default: none)
#   ACAD_PROFILE  /p flag, e.g. "<<ACADE>>" (default: AutoCAD's current profile)
#   RUN_TIMEOUT   Seconds before the run is killed (default: 120)
#
# Writes <steps-file minus extension>.out.txt (decoded output) next to the steps file.
# Exit codes: 0 pass, 1 failure found in output, 2 timeout (usually a prompt waiting for input).

set -u

steps=${1:?usage: run-core-console.sh <steps-file> [drawing.dwg]}
dwg=${2:-}
exe="$(cygpath -u "${ACAD_DIR:-C:/Program Files/Autodesk/AutoCAD 2026}")/accoreconsole.exe"
run_timeout=${RUN_TIMEOUT:-120}

base=${steps%.*}
run_scr="$base.run.scr"
raw="$base.raw.txt"
out="$base.out.txt"

# Written as CRLF, AutoCAD's native script format (LF also works). The marker is
# split with strcat so the echoed command line never matches it; only a script
# that really reached the end prints it.
{
  sed -e '$a\' "$steps" | tr -d '\r' | grep -v '^;EXPECT '
  echo '(princ (strcat "\nRUNNER-" "END"))'
  echo '_.QUIT'
  echo '_Y'
} | sed 's/$/\r/' > "$run_scr"

# Paths must be absolute: a relative /s path gives "Can't find file" (and exit 0).
args=()
[ -n "$dwg" ] && args+=(/i "$(cygpath -wa "$dwg")")
args+=(/s "$(cygpath -wa "$run_scr")")
[ -n "${ACAD_PRODUCT:-}" ] && args+=(/product "$ACAD_PRODUCT")
[ -n "${ACAD_PROFILE:-}" ] && args+=(/p "$ACAD_PROFILE")

# Without MSYS_NO_PATHCONV, Git Bash rewrites /s, /i and /p as POSIX paths and
# accoreconsole falls back to printing its usage and waiting for input forever.
start=$SECONDS
MSYS_NO_PATHCONV=1 timeout -k 5 "$run_timeout" "$exe" "${args[@]}" > "$raw" 2>&1
code=$?
elapsed=$((SECONDS - start))

# Output is UTF-16LE. Dropping NUL bytes is enough for the ASCII we match on.
tr -d '\000' < "$raw" | tr -d '\r' | grep -v -E '^$|CoreHeartBeat' > "$out"

cat "$out"
echo "----"
if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
  echo "RUNNER: TIMEOUT after ${run_timeout}s, usually a prompt waiting for input (see the last lines above)"
  exit 2
fi

# "Can't find file" and "Invalid file name" mean Core Console couldn't open the
# script itself, usually because the path is relative or over 259 characters.
problems=$(grep -n -E "Unknown command|; error:|Unable to load|Invalid option keyword|Unhandled exception|FATAL ERROR|Can't find file|Invalid file name" "$out")
if ! grep -q 'RUNNER-END' "$out"; then
  problems="${problems:+$problems
}script never reached its end marker"
fi
# Echoed script lines ("Command: ...") don't count, so a match means the text was printed.
while IFS= read -r want; do
  grep -v '^Command: ' "$out" | grep -qF -- "$want" || problems="${problems:+$problems
}expected text not found: $want"
done < <(grep '^;EXPECT ' "$steps" | tr -d '\r' | sed 's/^;EXPECT //')
if [ -n "$problems" ]; then
  echo "RUNNER: FAIL in ${elapsed}s"
  echo "$problems"
  exit 1
fi
echo "RUNNER: PASS in ${elapsed}s"
