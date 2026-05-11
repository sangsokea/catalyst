#!/usr/bin/env bash
# Driver script for building the catalyst MLIR binaries needed by QuFlow.
# Runs llvm -> stablehlo -> enzyme -> dialects in sequence with phase logs.
# Each phase logs to build-logs/<phase>.log; combined output to build_all.log.
#
# Resource use: 18 cores ~100%, 10-20 GB RAM peak, ~35 GB disk.

set -euo pipefail

CATALYST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$CATALYST_DIR/build-logs"
mkdir -p "$LOG_DIR"

cd "$CATALYST_DIR"

# pybind11 was installed via `pip install --user`. Make CMake find its config.
if [ -z "${pybind11_DIR:-}" ]; then
    export pybind11_DIR="$(python3 -c 'import pybind11; print(pybind11.get_cmake_dir())')"
    echo "=== pybind11_DIR=$pybind11_DIR"
fi

# cmake 4.x from pip is required (system cmake is 3.22, dialects build needs >=3.26).
export PATH="$HOME/.local/bin:$PATH"
echo "=== cmake: $(which cmake) ($(cmake --version | head -1))"

# Per-phase compiler overrides:
# - llvm/stablehlo/enzyme: keep clang-14 (already-cached builds use it; switching
#   would trigger ~hours of full rebuild).
# - dialects: must use g++-12 because catalyst/mlir/lib/Driver/Pipelines.cpp uses
#   C++20 std::ranges::views::filter|transform pipelines that GCC 11's libstdc++
#   rejects.
declare -A C_COMPILER_FOR=(
    [llvm]=/usr/bin/clang
    [stablehlo]=/usr/bin/clang
    [enzyme]=/usr/bin/clang
    [dialects]=/usr/bin/gcc-12
)
declare -A CXX_COMPILER_FOR=(
    [llvm]=/usr/bin/clang++
    [stablehlo]=/usr/bin/clang++
    [enzyme]=/usr/bin/clang++
    [dialects]=/usr/bin/g++-12
)

PHASES=(llvm stablehlo enzyme dialects)
START_ALL=$SECONDS

for phase in "${PHASES[@]}"; do
    PHASE_LOG="$LOG_DIR/${phase}.log"
    PHASE_START=$SECONDS

    export C_COMPILER="${C_COMPILER_FOR[$phase]}"
    export CXX_COMPILER="${CXX_COMPILER_FOR[$phase]}"

    # Disable -Werror only for dialects: gcc-12 emits false-positive -Wrestrict
    # warnings on libstdc++-12 string concat patterns when -O3 + _GLIBCXX_ASSERTIONS
    # are both set. Catalyst hard-codes both, so the cleanest workaround is to
    # downgrade -Werror to plain warnings just for this phase.
    if [ "$phase" = "dialects" ]; then
        export STRICT_WARNINGS=OFF
    else
        unset STRICT_WARNINGS
    fi

    echo "=== [$(date -Iseconds)] starting phase: $phase  (CC=$C_COMPILER CXX=$CXX_COMPILER STRICT_WARNINGS=${STRICT_WARNINGS:-ON} log: $PHASE_LOG)"

    if ! make -C mlir "$phase" > "$PHASE_LOG" 2>&1; then
        echo "=== [$(date -Iseconds)] PHASE FAILED: $phase"
        echo "    last 40 lines:"
        tail -n 40 "$PHASE_LOG" | sed 's/^/    /'
        exit 1
    fi

    PHASE_ELAPSED=$((SECONDS - PHASE_START))
    printf "=== [%s] completed phase: %s  (%dm%ds)\n" \
        "$(date -Iseconds)" "$phase" $((PHASE_ELAPSED/60)) $((PHASE_ELAPSED%60))
done

TOTAL=$((SECONDS - START_ALL))
printf "=== [%s] ALL PHASES COMPLETE in %dm%ds\n" "$(date -Iseconds)" $((TOTAL/60)) $((TOTAL%60))

echo
echo "=== Binaries produced ==="
ls -lh "$CATALYST_DIR/mlir/build/bin/quantum-opt" "$CATALYST_DIR/mlir/build/bin/quantum-translate" 2>&1
