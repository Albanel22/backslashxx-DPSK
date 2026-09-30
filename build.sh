#!/usr/bin/env bash
#
# Build propre KernelSU backslashxx + SusFS pour Motorola One 5G Ace (kiev/lito)
#
# Principes:
# - KernelSU backslashxx v3.3.0-52, compatible avec le Manager 32651-4
# - application stricte du patch SusFS: aucun .rej accepté
# - aucune modification tactile, aucune désactivation de vérification de signature
# - TRY_UMOUNT, OPEN_REDIRECT, SUS_MAP et spoof cmdline désactivés par défaut
# - le boot.img source doit correspondre au firmware réellement installé
#
# Variables personnalisables:
#   WORKSPACE, KERNEL_REPO, KERNEL_REF, KSU_REPO, KSU_REF
#   SUSFS_REPO, SUSFS_REF, STOCK_BOOT_URL, STOCK_DTBO_URL
#   DEFCONFIG, JOBS, ENABLE_REPACK
#
set -Eeuo pipefail
IFS=$'\n\t'

WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_motorola_sm8250.git}"
KERNEL_REF="${KERNEL_REF:-lineage-23.2}"
KSU_REPO="${KSU_REPO:-https://github.com/backslashxx/KernelSU.git}"
KSU_REF="${KSU_REF:-v3.3.0-52}"
SUSFS_REPO="${SUSFS_REPO:-https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git}"
SUSFS_REF="${SUSFS_REF:-mainline}"
SUSFS_PATCH_REL="${SUSFS_PATCH_REL:-Patches/Patch/susfs_patch_to_4.19.patch}"
STOCK_BOOT_URL="${STOCK_BOOT_URL:-}"
STOCK_DTBO_URL="${STOCK_DTBO_URL:-}"
DEFCONFIG="${DEFCONFIG:-}"
JOBS="${JOBS:-$(nproc)}"
ENABLE_REPACK="${ENABLE_REPACK:-0}"

KERNEL_DIR="$WORKSPACE/kernel_sources"
KSU_DIR="$WORKSPACE/KernelSU"
SUSFS_DIR="$WORKSPACE/SusFS"
OUT_DIR="$KERNEL_DIR/out"
OUTPUT_DIR="$WORKSPACE/output"
LOG="$WORKSPACE/build.log"

fail() { echo "❌ $*" >&2; exit 1; }
info() { echo; echo "=== $* ==="; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Commande absente: $1"; }

cleanup_on_error() {
    rc=$?
    echo "❌ BUILD FAILED (code $rc)"
    if [[ -f "$LOG" ]]; then
        echo "--- dernières erreurs ---"
        grep -iE 'error:|undefined reference|undefined symbol|fatal:' "$LOG" | tail -80 || true
    fi
    exit "$rc"
}
trap cleanup_on_error ERR

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y bc bison build-essential ccache flex libelf-dev libssl-dev \
        libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
        clang llvm lld device-tree-compiler zip unzip curl git python3 patch
fi
for c in git make python3 patch clang ld.lld; do need_cmd "$c"; done
mkdir -p "$WORKSPACE"
rm -rf "$KERNEL_DIR" "$KSU_DIR" "$SUSFS_DIR" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

info "Clonage du noyau"
git clone --depth=1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL_DIR"
git -C "$KERNEL_DIR" log -1 --oneline

info "Clonage de KernelSU backslashxx"
git clone --depth=1 "$KSU_REPO" "$KSU_DIR"
git -C "$KSU_DIR" fetch --depth=1 origin "tag $KSU_REF"
git -C "$KSU_DIR" checkout --detach "$KSU_REF"
echo "KernelSU: $(git -C "$KSU_DIR" log -1 --oneline)"

info "Intégration KernelSU"
ln -s "$KSU_DIR/kernel" "$KERNEL_DIR/drivers/kernelsu"
grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -qF 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

info "Application stricte de SusFS 4.19"
git clone --depth=1 --branch "$SUSFS_REF" "$SUSFS_REPO" "$SUSFS_DIR"
SUSFS_PATCH="$SUSFS_DIR/$SUSFS_PATCH_REL"
[[ -f "$SUSFS_PATCH" ]] || fail "Patch SusFS introuvable: $SUSFS_PATCH"
cd "$KERNEL_DIR"
set +e
patch --batch --forward -p1 < "$SUSFS_PATCH" > "$WORKSPACE/susfs_patch.log" 2>&1
patch_rc=$?
set -e
rejects=$(find . -type f -name '*.rej' -print)
if [[ $patch_rc -ne 0 || -n "$rejects" ]]; then
    echo "--- susfs_patch.log ---"
    cat "$WORKSPACE/susfs_patch.log"
    [[ -n "$rejects" ]] && while IFS= read -r r; do echo "--- $r"; cat "$r"; done <<< "$rejects"
    fail "Le patch SusFS n'est pas applicable sans rejet"
fi
find . -type f -name '*.orig' -delete
[[ -f fs/susfs.c && -f include/linux/susfs.h && -f include/linux/susfs_def.h ]] || \
    fail "Fichiers SusFS attendus absents après application du patch"

grep -qF 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || \
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> fs/Makefile

info "Compatibilité SusFS / KernelSU"
python3 - <<'PY'
from pathlib import Path

root = Path('.')

# fs/stat.c utilise les macros et helpers déclarés dans susfs_def.h.
p = root / 'fs/stat.c'
s = p.read_text()
if '#include <linux/susfs_def.h>' not in s:
    marker = '#include <asm/unistd.h>\n'
    if marker not in s:
        raise SystemExit('fs/stat.c: include marker introuvable')
    s = s.replace(marker, marker + '\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n', 1)
    p.write_text(s)

# KernelSU setuid_hook.c référence ce helper depuis un autre objet.
p = root / 'fs/susfs.c'
s = p.read_text()
if 'static void susfs_run_sus_path_loop(void)' in s:
    s = s.replace('static void susfs_run_sus_path_loop(void)', 'void susfs_run_sus_path_loop(void)', 1)
elif 'void susfs_run_sus_path_loop(void)' not in s:
    raise SystemExit('fs/susfs.c: susfs_run_sus_path_loop introuvable')
p.write_text(s)
PY

info "Hooks manuels KernelSU pour le noyau 4.19"
python3 - <<'PYEOF_HOOKS'
from pathlib import Path
import re
root = Path('.')

def insert_once(path, signature, extern_decl, call):
    p = root / path
    s = p.read_text()
    if call in s:
        return
    m = re.search(signature, s)
    if not m:
        raise SystemExit(f"Signature introuvable pour {path}")
    block = f"\n{extern_decl}\n#if defined(CONFIG_KSU)\n{call}\n#endif\n"
    p.write_text(s[:m.end()] + block + s[m.end():])

insert_once(
    'fs/exec.c',
    r'static int do_execveat_common\(int fd, struct filename \*filename,\s*\n\s*struct user_arg_ptr argv,\s*\n\s*struct user_arg_ptr envp,\s*\n\s*int flags\)\s*\n\{',
    'extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);',
    'ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);')
insert_once(
    'fs/open.c',
    r'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{',
    'extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);',
    'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);')
insert_once(
    'fs/stat.c',
    r'int vfs_statx\(int dfd, const char __user \*filename, int flags,\s*\n\s*struct kstat \*stat, unsigned int request_mask\)\s*\n\{',
    'extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
    'ksu_handle_stat(&dfd, &filename, &flags);')
PYEOF_HOOKS

info "Déclaration Kconfig SusFS"
python3 - <<'PYEOF_KCONFIG'
from pathlib import Path
p = Path("drivers/kernelsu/Kconfig")
s = p.read_text()
if "config KSU_SUSFS" not in s:
    s += """

menuconfig KSU_SUSFS
    bool "KernelSU SUSFS support"
    depends on KSU
    default y

if KSU_SUSFS
config KSU_SUSFS_SUS_PATH
    bool "Sus path"
    default y
config KSU_SUSFS_SUS_MOUNT
    bool "Sus mount"
    default y
config KSU_SUSFS_SUS_KSTAT
    bool "Sus kstat"
    default y
config KSU_SUSFS_SPOOF_UNAME
    bool "Spoof uname"
    default y
config KSU_SUSFS_TRY_UMOUNT
    bool "Try umount"
    default n
config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    bool "Spoof cmdline or bootconfig"
    default n
config KSU_SUSFS_OPEN_REDIRECT
    bool "Open redirect"
    default n
config KSU_SUSFS_SUS_MAP
    bool "Sus map"
    default n
config KSU_SUSFS_ENABLE_LOG
    bool "Enable log"
    default y
config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    bool "Hide KernelSU/SUSFS symbols"
    default y
endif
"""
    p.write_text(s)
PYEOF_KCONFIG

info "Configuration"
if [[ -z "$DEFCONFIG" ]]; then
    DEFCONFIG=$(find arch/arm64/configs/vendor arch/arm64/configs -maxdepth 2 \
        \( -iname '*kiev*' -o -iname '*lito*' \) -type f -print -quit 2>/dev/null || true)
    [[ -n "$DEFCONFIG" ]] || fail "Defconfig kiev/lito introuvable; définir DEFCONFIG"
    DEFCONFIG="${DEFCONFIG#arch/arm64/configs/}"
fi
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
make O="$OUT_DIR" LLVM=1 "$DEFCONFIG"

scripts_config="$KERNEL_DIR/scripts/config"
[[ -x "$scripts_config" ]] || chmod +x "$scripts_config"
set +e
"$scripts_config" --file "$OUT_DIR/.config" \
    --enable KSU \
    --disable KSU_HACK_ARM64_BRANCH_LINK \
    --disable KSU_TAMPER_SYSCALL_TABLE \
    --disable KSU_KPROBES_KSUD \
    --enable KSU_LSM_SECURITY_HOOKS \
    --enable KSU_FEATURE_SULOG \
    --enable KSU_FEATURE_ADBROOT \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --disable KSU_SUSFS_TRY_UMOUNT \
    --disable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --disable KSU_SUSFS_OPEN_REDIRECT \
    --disable KSU_SUSFS_SUS_MAP \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable THREAD_INFO_IN_TASK \
    --disable CC_WERROR
set -e
make O="$OUT_DIR" LLVM=1 olddefconfig
cp "$OUT_DIR/.config" "$OUTPUT_DIR/kernel.config"
grep -E 'CONFIG_(KSU|KSU_SUSFS)' "$OUT_DIR/.config" | tee "$OUTPUT_DIR/ksu-susfs.config"

info "Compilation du noyau"
make O="$OUT_DIR" LLVM=1 -j"$JOBS" Image 2>&1 | tee "$LOG"
[[ -f "$OUT_DIR/arch/arm64/boot/Image" ]] || fail "Image noyau absente"
cp "$OUT_DIR/arch/arm64/boot/Image" "$OUTPUT_DIR/Image"
cp "$LOG" "$OUTPUT_DIR/build.log"

info "Vérifications finales"
! find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -print -quit | grep -q . || \
    fail "Des fichiers .rej/.orig subsistent"
file "$OUTPUT_DIR/Image" 2>/dev/null || true

echo "✅ Compilation KernelSU + SusFS réussie"
echo "Sorties: $OUTPUT_DIR"

if [[ "$ENABLE_REPACK" == 1 ]]; then
    [[ -n "$STOCK_BOOT_URL" ]] || fail "ENABLE_REPACK=1 nécessite STOCK_BOOT_URL"
    need_cmd curl
    need_cmd unzip
    info "Repack boot.img"
    curl -fL "$STOCK_BOOT_URL" -o "$WORKSPACE/boot-stock.img"
    echo "Le repack nécessite magiskboot fourni séparément; aucun flash n'est effectué."
    fail "Repack non activé automatiquement dans cette version sûre"
fi
