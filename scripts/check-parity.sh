#!/usr/bin/env bash
#
# Runs the macOS and Windows clients side by side and fails if they disagree.
#
# Why this exists: Swift and C# share no code, so the only thing keeping the two clients behaving
# alike is a generated contract and the discipline of writing the same rules twice. `--check` in the
# generator proves the TYPES match. Nothing but this proves the BEHAVIOUR does. The first real drift
# it caught was `ok=True` against `ok=true` — C# capitalises booleans and Swift does not.
#
# Run it locally the same way CI does:  bash scripts/check-parity.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC="$REPO_DIR/macos/Saathi/.build/debug/saathi"
WIN="$REPO_DIR/windows/src/Saathi.Cli/bin/Debug/net8.0/saathi"

for binary in "$MAC" "$WIN"; do
  [[ -x "$binary" ]] || { echo "not built: $binary" >&2; exit 1; }
done

failures=0

# The macOS client speaks by default and prints with --quiet; the Windows one only prints so far.
# Compare what they SAY, not how they emit it.
compare() {
  local label="$1"; shift
  local mac_output win_output
  mac_output="$("$MAC" "$@" --quiet)"
  win_output="$("$WIN" "$@")"

  if [[ "$mac_output" == "$win_output" ]]; then
    echo "✓ $label"
  else
    echo "✗ $label — the two clients disagree:"
    diff <(printf '%s\n' "$mac_output") <(printf '%s\n' "$win_output") || true
    failures=$((failures + 1))
  fi
}

compare "actions"  actions
compare "demo"     demo
compare "say"      say "hello there"
compare "say calm" say "hello there" --tone=calm

if [[ $failures -gt 0 ]]; then
  echo
  echo "$failures command(s) differ between the macOS and Windows clients." >&2
  echo "Either the contract changed on one side only, or one client implements a rule the other does not." >&2
  exit 1
fi

echo
echo "the macOS and Windows clients agree on every command checked"
