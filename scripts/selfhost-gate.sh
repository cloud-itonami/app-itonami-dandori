#!/bin/sh
# Amu selfhost gate for kotoba/dandori/*.kotoba. No Node.js, nbb, JVM or
# babashka: the pinned Amu root compiler builds a loaderless aarch64-linux
# static image and the image runs; sh, sed, awk and grep only orchestrate.
#
# usage: scripts/selfhost-gate.sh ROOT_ELF EXPECT MODULE...
#
#   ROOT_ELF  kotoba-lang/amu seed/bootstrap/aarch64-linux-static-root.elf at
#             the pinned commit below; its sha256 is checked first.
#   EXPECT    the :result the image must report, or "all" for 2^n - 1 over
#             the n test-* functions.
#   MODULE    .kotoba files in dependency order. Their ns forms are dropped
#             and the bodies joined into one closed unit, followed by a main
#             that adds 2^i for each test-* (file order) that returns true.
#
#   GATE_SED  optional sed expression applied to the unit before compiling
#             (the negative control: mutate one row, expect its bit to drop).
#
# On aarch64 Linux the image runs natively; elsewhere the same commands run
# in podman (linux/arm64, --network none) with a directory under GATE_TMP
# (default: the current directory), which podman must be able to mount.
set -eu

ROOT_SHA256=8256bfd8462c2014bf1864f154e88aa7cbb16eda7754aaabf8bf2303dcfc8dc7
IMAGE=docker.io/library/python:3.12-alpine

[ $# -ge 3 ] || { echo "usage: $0 ROOT_ELF EXPECT MODULE..." >&2; exit 2; }
root=$1; expect=$2; shift 2

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
got=$(sha "$root")
[ "$got" = "$ROOT_SHA256" ] || { echo "gate: root sha256 $got, want $ROOT_SHA256" >&2; exit 1; }

G=$(mktemp -d "${GATE_TMP:-$(pwd)}/.selfhost-gate.XXXXXX")
trap 'rm -rf "$G"' EXIT
cp "$root" "$G/root.elf"

# the unit: every module body, then main
: > "$G/body.kotoba"
tests=""
for f in "$@"; do
  awk 'state == 0 && /^\(ns / { state = 1 }
       state == 1 { if ($0 ~ /\]\)\)[ \t]*$/) state = 2; next }
       state == 2 { print }' "$f" >> "$G/body.kotoba"
  tests="$tests $(sed -n 's/^(defn \(test-[a-z0-9-]*\) \[\] :bool.*/\1/p' "$f" | tr '\n' ' ')"
done
n=0; sum=""; close=""
for t in $tests; do
  bit=$(awk -v k="$n" 'BEGIN { print 2 ^ k }')
  sum="$sum(+ (if ($t) $bit 0) "; close="$close)"; n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "gate: no test-* in $*" >&2; exit 1; }
[ "$expect" = all ] && expect=$(awk -v k="$n" 'BEGIN { print 2 ^ k - 1 }')
{ echo '(ns selfhost-gate (:export [main]))'
  if [ -n "${GATE_SED:-}" ]; then sed "$GATE_SED" "$G/body.kotoba"; else cat "$G/body.kotoba"; fi
  echo "(defn main [] :i64 ${sum}0$close)"
} > "$G/gate.kotoba"
if [ -n "${GATE_SED:-}" ]; then
  sed "$GATE_SED" "$G/body.kotoba" | cmp -s - "$G/body.kotoba" && { echo "gate: GATE_SED changed nothing" >&2; exit 1; }
fi

run="./root.elf compile $G/gate.kotoba --target aarch64-linux --output $G/gate.elf --format static && chmod +x gate.elf && KEXE_STRUCTURED_REPORT=1 ./gate.elf"
if [ "$(uname -s)-$(uname -m)" = Linux-aarch64 ]; then
  out=$(cd "$G" && KEXE_CAP_RESOURCES_35="$G" sh -c "$run" 2>&1) || true
else
  out=$(podman run --rm --platform linux/arm64 --network none -e KEXE_CAP_RESOURCES_35="$G" \
          -v "$G:$G" -w "$G" "$IMAGE" sh -c "$run" 2>&1) || true
fi
echo "$out"
echo "gate: tests($n):$tests"
echo "gate: unit sha256 $(sha "$G/gate.kotoba")"
echo "$out" | grep -q ':status :ok' || { echo "gate: the image did not report :status :ok" >&2; exit 1; }
result=$(echo "$out" | sed -n 's/.*:status :ok :result \(-\{0,1\}[0-9]*\).*/\1/p' | tail -n 1)
[ "$result" = "$expect" ] || { echo "gate: :result $result, want $expect" >&2; exit 1; }
echo "gate: :result $result (want $expect) ok"
