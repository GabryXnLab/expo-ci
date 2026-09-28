#!/usr/bin/env bash
# Patch del NDK Android (linux-aarch64) per usare clang nativo invece di
# emulazione QEMU su x86_64. Senza questa patch, la build C++ degli oltre 13
# moduli nativi gira sotto qemu-user-static → build ~1h. Con la patch usa il
# clang aarch64 di sistema (Ubuntu llvm-18) con flag Android corretti → ~10-15min.
#
# Modifiche idempotenti (marker NDKPATCH-v2):
#   1. /opt/android-sdk/ndk/<ver>/toolchains/llvm/prebuilt/linux-aarch64/bin/
#      clang e clang++: sostituisce i symlink con un wrapper che inietta
#      -resource-dir, -rtlib=compiler-rt, -unwindlib=libunwind quando il target
#      è *-android*. Risolve "unable to find library -lgcc" su sistema clang.
#   2. /opt/android-sdk/ndk/<ver>/build/cmake/android-legacy.toolchain.cmake:
#      aggiunge detection ARM64 host → ANDROID_HOST_TAG=linux-aarch64. Senza
#      questo, AGP/cmake usa sempre linux-x86_64 e quindi qemu.
#
# Idempotente — eseguire più volte è sicuro.

set -euo pipefail

NDK="${ANDROID_NDK_HOME:-/opt/android-sdk/ndk/27.3.13750724}"
if [ ! -d "$NDK/toolchains/llvm/prebuilt/linux-aarch64" ]; then
    echo "NDK aarch64 dir non trovata: $NDK/toolchains/llvm/prebuilt/linux-aarch64" >&2
    echo "Skip patch — il host non è aarch64 o lo stub non è installato." >&2
    exit 0
fi

if [ "$(uname -m)" != "aarch64" ]; then
    echo "Host non aarch64 ($(uname -m)) — skip patch."
    exit 0
fi

BIN="$NDK/toolchains/llvm/prebuilt/linux-aarch64/bin"
LEGACY_CMAKE="$NDK/build/cmake/android-legacy.toolchain.cmake"

# Necessita sudo se i file sono root-owned. Detect.
if [ -w "$BIN/clang" ] 2>/dev/null && [ -w "$LEGACY_CMAKE" ] 2>/dev/null; then
    SUDO=""
else
    SUDO="sudo"
fi

# ─── Patch 1: clang/clang++ wrapper ─────────────────────────────────────────
WRAPPER_TMP=$(mktemp)
cat > "$WRAPPER_TMP" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# NDKPATCH-v2: aarch64-Linux native cross-compile wrapper for system clang-18.
SELF_NAME=$(basename "$0")
SYSTEM_CLANG="/usr/lib/llvm-18/bin/clang"
case "$SELF_NAME" in
    clang++) ARGV0="${SYSTEM_CLANG}++" ;;
    *)       ARGV0="$SYSTEM_CLANG"   ;;
esac
ANDROID_TARGET=0
for arg in "$@"; do
    case "$arg" in
        --target=*android*) ANDROID_TARGET=1; break ;;
    esac
done
if [ "$ANDROID_TARGET" = "1" ]; then
    NDK_X86_64=$(cd "$(dirname "$0")/../../linux-x86_64" 2>/dev/null && pwd)
    if [ -z "$NDK_X86_64" ]; then
        echo "clang-android-wrapper: cannot locate linux-x86_64 NDK dir" >&2
        exec "$ARGV0" "$@"
    fi
    # -Qunused-arguments silenzia "argument unused" per i flag linker
    # (-rtlib/-unwindlib) durante compile-only. Senza, moduli con -Werror
    # (es. react-native-worklets) fanno fallire la compilazione.
    exec "$ARGV0" \
        -Qunused-arguments \
        -resource-dir="$NDK_X86_64/lib/clang/18" \
        -rtlib=compiler-rt \
        -unwindlib=libunwind \
        "$@"
else
    exec "$ARGV0" "$@"
fi
WRAPPER_EOF

needs_patch_clang=1
if [ -f "$BIN/clang" ] && grep -q "NDKPATCH-v2" "$BIN/clang" 2>/dev/null; then
    needs_patch_clang=0
fi

if [ "$needs_patch_clang" = "1" ]; then
    echo "Patching clang/clang++ wrappers in $BIN ..."
    $SUDO rm -f "$BIN/clang" "$BIN/clang++"
    $SUDO cp "$WRAPPER_TMP" "$BIN/clang"
    $SUDO cp "$WRAPPER_TMP" "$BIN/clang++"
    $SUDO chmod 755 "$BIN/clang" "$BIN/clang++"
else
    echo "clang/clang++ wrappers già patchati (NDKPATCH-v2)."
fi
rm -f "$WRAPPER_TMP"

# ─── Patch 2: android-legacy.toolchain.cmake host detection ─────────────────
if grep -qE "NDKPATCH-v[0-9]+.*aarch64" "$LEGACY_CMAKE" 2>/dev/null; then
    echo "android-legacy.toolchain.cmake già patchato."
else
    echo "Patching $LEGACY_CMAKE ..."
    $SUDO python3 -c "
p = '$LEGACY_CMAKE'
with open(p) as f: s = f.read()
old = '''if(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux)
  set(ANDROID_HOST_TAG linux-x86_64)
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)'''
new = '''if(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux)
  # NDKPATCH-v2: usa toolchain aarch64 nativo se host è ARM64 (niente QEMU).
  if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES \"aarch64|arm64\" AND
     EXISTS \"\${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/linux-aarch64\")
    set(ANDROID_HOST_TAG linux-aarch64)
  else()
    set(ANDROID_HOST_TAG linux-x86_64)
  endif()
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)'''
if old not in s:
    print('WARN: blocco originale non trovato — già patchato manualmente?')
else:
    with open(p, 'w') as f: f.write(s.replace(old, new))
    print('OK')
"
fi

echo "✓ NDK aarch64 host patches applicati."
