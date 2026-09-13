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

# Build both first unless told not to. Skipping this is how the check lies: `dotnet test` does not
# rebuild Saathi.Cli (the test project does not reference it), so a stale Windows binary silently
# compares an old contract against a new one — a false failure here, and just as easily a false pass.
if [[ "${1:-}" != "--no-build" ]]; then
  echo "building both clients (pass --no-build to skip)"
  (cd "$REPO_DIR/macos/Saathi" && swift build) >/dev/null
  (cd "$REPO_DIR/windows" && dotnet build Saathi.sln -v q --nologo) >/dev/null
fi

for binary in "$MAC" "$WIN"; do
  [[ -x "$binary" ]] || { echo "not built: $binary" >&2; exit 1; }
done

# A .NET apphost finds its runtime through DOTNET_ROOT, not PATH. When the SDK was installed with
# dotnet-install.sh (which puts it in ~/.dotnet) rather than system-wide, running the built binary
# fails with "You must install .NET to run this application" even though `dotnet build` just
# succeeded. CI's setup-dotnet installs system-wide and needs none of this.
if [[ -z "${DOTNET_ROOT:-}" && -x "$HOME/.dotnet/dotnet" ]]; then
  export DOTNET_ROOT="$HOME/.dotnet"
fi

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

# The provider report is the most important one to keep identical: it is how a person checks
# whether anything they say leaves their machine, and two clients disagreeing about that would be
# worse than either being wrong on its own.
compare "provider" provider
# The voice report is the same kind of promise as the provider one, and a finer-grained one: it is
# where a learner reads whether their AUDIO leaves the machine or only a transcript does. Both
# clients must say the same thing about that, including on Windows, where the lane is reported
# before it is implemented.
compare "voice"    voice
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
