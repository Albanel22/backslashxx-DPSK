#!/usr/bin/env bash
# build_kernelsu_susfs.sh
# Script: build KernelSU + SuSFS (1.3.7) + UAPI2 + sys_reboot
# Corrections: safer git checkout, strict shell, improved magiskboot handling, safer Makefile check, logging.
# Usage: export GITHUB_WORKSPACE=/path/to/workspace; ./build_kernelsu_susfs.sh
# Set DRY_RUN=1 for simulation.

set -euo pipefail
# set -x   # Uncomment for verbose debug

# ==================== MODE DRY-RUN ====================
DRY_RUN=${DRY_RUN:-0}  # ← Mettez 0 pour lancer la compilation réelle

# ==================== UTILITAIRES ====================
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

log() { printf "%s %s\n" "$(date -Is)" "$*"; }

log "=== BUILD DIAGNOSTIC : KernelSU + SuSFS (1.3.7) + UAPI2 + sys_reboot ==="
df -h || true

# Create log dir
LOGDIR=${LOGDIR:-/tmp/kernelsu_build_logs}
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/build_stdout.log") 2> >(tee -a "$LOGDIR/build_stderr.log" >&2)

# ==================== ENVIRONNEMENT ====================
if [ "$DRY_RUN" -eq 0 ]; then
    log "=== MODE RÉEL : installation des dépendances ==="
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
    sudo apt-get clean || true
    sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    sudo apt-get update -y
    sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
        libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
        clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl \
        python3-pip wget jq pkg-config libfuse3-dev || true
else
    log "=== MODE DRY-RUN : aucune installation système ==="
fi

: "${GITHUB_WORKSPACE:=${PWD}}"
cd "$GITHUB_WORKSPACE" || exit 1

# ==================== 1. CLONAGE DU NOYAU ====================
if [ ! -d "kernel_sources" ]; then
    log "=== Clonage du kernel Motorola sm8250 (lineage-23.2) ==="
    if [ "$DRY_RUN" -eq 0 ]; then
        git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
            -b lineage-23.2 --depth=1 kernel_sources || { log "❌ git clone kernel failed"; exit 1; }
    else
        echo "[DRY-RUN] git clone ..."; mkdir -p kernel_sources
    fi
fi

cd kernel_sources || exit 1
KERNEL_ROOT="$PWD"

# ==================== 2. KERNELSU ====================
if [ ! -d "drivers/kernelsu" ]; then
    log "=== Intégration KernelSU (commit 0b138d6a) ==="
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -rf drivers/kernelsu KernelSU /tmp/KernelSU || true
        KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"
        git clone https://github.com/backslashxx/KernelSU.git /tmp/KernelSU || { log "❌ clone KernelSU failed"; exit 1; }
        cd /tmp/KernelSU
        # Safer checkout: try direct, else fetch the commit
        if ! git checkout "$KSU_COMMIT" 2>/dev/null; then
            git fetch --no-tags --depth=1 origin "$KSU_COMMIT" 2>/dev/null || git fetch origin "$KSU_COMMIT" 2>/dev/null || true
            if ! git checkout "$KSU_COMMIT" 2>/dev/null; then
                log "❌ Cannot fetch KSU commit $KSU_COMMIT"; exit 1
            fi
        fi
        cd "$KERNEL_ROOT"
        KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' /tmp/KernelSU/kernel/Makefile | head -1 || true)
        [ -z "$KSU_VER" ] && KSU_VER="32601"
        log "[+] KSU_VERSION : $KSU_VER"
        ln -sf /tmp/KernelSU/kernel drivers/kernelsu
        if [ ! -d "drivers/kernelsu" ]; then
            log "❌ Symlink échoué"
            exit 1
        fi
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
        sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig
        if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile 2>/dev/null; then
            echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
        fi
        # Update uapi version defines to UAPI v2
        sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
        sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
        sed -i "s/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION ${KSU_VER}/" /tmp/KernelSU/uapi/ksu.h 2>/dev/null || true
        DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
        if [ -f "$DISPATCH_FILE" ]; then
            sed -i "s/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/" "$DISPATCH_FILE" || true
            sed -i "s/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = ${KSU_VER};/" "$DISPATCH_FILE" || true
            sed -i "s/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE" || true
            sed -i "s/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE" || true
        fi
        log "✅ KernelSU intégré"
    else
        log "[DRY-RUN] Intégration KernelSU simulée"
    fi
fi

# ==================== 3. HOOKS KERNELSU ====================
log "=== Vérification des hooks KernelSU ==="
hook_insert_if_absent() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4" search="$5"
    [ ! -f "$file" ] && { log "⚠️ $file absent"; return 1; }
    if grep -q "$search" "$file" 2>/dev/null; then
        log "⏩ $search déjà présent dans $file"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] Hook $search ajouté dans $file"
        return 0
    fi
    if ! grep -Pzo "$sig_re" "$file" >/dev/null 2>&1; then
        log "❌ Signature non trouvée dans $file"
        return 1
    fi
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \"-Wdeclaration-after-statement\"\n${call_line}\n#endif\n/s" "$file"
    log "✅ Hook inséré dans $file"
    return 0
}

hook_insert_if_absent "fs/exec.c" \
    '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' \
    'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' \
    'ksu_handle_execveat'

# open.c hooks: keep original logic but guarded
if grep -Pzo 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' fs/open.c >/dev/null 2>&1; then
    hook_insert_if_absent "fs/open.c" \
        'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
        'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
        'ksu_handle_faccessat'
elif grep -Pzo 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' fs/open.c >/dev/null 2>&1; then
    hook_insert_if_absent "fs/open.c" \
        'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
        'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
        'ksu_handle_faccessat'
fi

if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' fs/stat.c >/dev/null 2>&1; then
    hook_insert_if_absent "fs/stat.c" \
        'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
        'ksu_handle_stat(&dfd, &filename, &flags);' \
        'ksu_handle_stat'
elif grep -Pzo 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' fs/stat.c >/dev/null 2>&1; then
    hook_insert_if_absent "fs/stat.c" \
        'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
        'ksu_handle_stat(&dfd, &filename, &flag);' \
        'ksu_handle_stat'
fi

if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c 2>/dev/null; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\
#endif' kernel/reboot.c
        sed -i '/int ret = 0;/a\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\
#endif' kernel/reboot.c
        log "✅ Hook sys_reboot ajouté"
    else
        log "[DRY-RUN] Hook sys_reboot ajouté dans kernel/reboot.c"
    fi
fi

# ==================== 4. INTÉGRATION SUSFS ====================
if [ ! -f "fs/susfs.c" ]; then
    log "=== Téléchargement des patches SuSFS (version 1.3.7) ==="
    PATCH10_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/1.3.7/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
    PATCH50_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/1.3.7/kernel_patches/50_add_susfs_in_kernel-4.19.patch"

    if [ "$DRY_RUN" -eq 0 ]; then
        wget -q "$PATCH10_URL" -O /tmp/10_enable_susfs_for_ksu.patch || { log "❌ Échec du téléchargement du patch 10"; exit 1; }
        wget -q "$PATCH50_URL" -O /tmp/50_add_susfs_in_kernel-4.19.patch || { log "❌ Échec du téléchargement du patch 50"; exit 1; }

        log "=== Clonage du tag 1.3.7 pour les sources ==="
        git clone --depth=1 --branch 1.3.7 https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs_src || { log "❌ Échec du clone du tag 1.3.7"; exit 1; }

        log "=== Copie des fichiers sources ==="
        cp /tmp/susfs_src/kernel_patches/fs/susfs.c fs/ || { log "❌ fs/susfs.c manquant"; exit 1; }
        cp /tmp/susfs_src/kernel_patches/fs/sus_su.c fs/ 2>/dev/null || log "⚠️ sus_su.c optionnel"
        cp /tmp/susfs_src/kernel_patches/include/linux/susfs.h include/linux/ 2>/dev/null || log "⚠️ susfs.h"
        cp /tmp/susfs_src/kernel_patches/include/linux/susfs_def.h include/linux/ 2>/dev/null || log "⚠️ susfs_def.h"

        log "=== Application du patch 10 sur KernelSU ==="
        cp /tmp/10_enable_susfs_for_ksu.patch drivers/kernelsu/
        cd drivers/kernelsu
        patch -p1 --forward --ignore-whitespace < 10_enable_susfs_for_ksu.patch 2>&1 | tee /tmp/patch10.log || {
            log "⚠️ Certains hunks du patch 10 ont échoué."
            grep -E "FAILED|reject" /tmp/patch10.log || true
            find . -name "*.rej" -print -delete 2>/dev/null || true
        }
        if ! grep -q '\-DKSU_SUSFS' Makefile 2>/dev/null; then
            log "⚠️ Ajout de -DKSU_SUSFS au Makefile (ccflags-y)"
            echo 'ccflags-y += -DKSU_SUSFS' >> Makefile
        fi
        if ! grep -q "KSU_SUSFS" Kconfig 2>/dev/null; then
            log "⚠️ Ajout manuel de Kconfig..."
            cat >> Kconfig <<'EOF'
menuconfig KSU_SUSFS
    bool "KernelSU SuSFS support"
    depends on KSU
    default y
if KSU_SUSFS
config KSU_SUSFS_SUS_PATH
    bool "sus_path support"
    default y
config KSU_SUSFS_SUS_MOUNT
    bool "sus_mount support"
    default y
config KSU_SUSFS_SUS_KSTAT
    bool "sus_kstat support"
    default y
config KSU_SUSFS_SUS_MAP
    bool "sus_map support"
    default y
config KSU_SUSFS_SPOOF_UNAME
    bool "spoof_uname support"
    default y
config KSU_SUSFS_ENABLE_LOG
    bool "enable_log support"
    default y
config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    bool "hide_ksu_susfs_symbols"
    default n
config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    bool "spoof_cmdline_or_bootconfig"
    default y
config KSU_SUSFS_OPEN_REDIRECT
    bool "open_redirect support"
    default y
config KSU_SUSFS_HAS_MAGIC_MOUNT
    bool "magic_mount support"
    default y
endif
EOF
        fi
        cd "$KERNEL_ROOT"

        log "=== Application du patch 50 sur le noyau ==="
        cp /tmp/50_add_susfs_in_kernel-4.19.patch .
        patch -p1 --forward --ignore-whitespace < 50_add_susfs_in_kernel-4.19.patch 2>&1 | tee /tmp/patch50.log || {
            log "⚠️ Certains hunks du patch 50 ont échoué."
            grep -E "FAILED|reject" /tmp/patch50.log || true
        }
        rm -f 50_add_susfs_in_kernel-4.19.patch

        # Robust repair of fs/open.c with backup
        log "=== Correction robuste de fs/open.c ==="
        cp fs/open.c fs/open.c.bak || true

        perl -i -pe '
            if (/^long do_faccessat\(int dfd, const char __user \*filename, int mode\)/) {
                $in_faccessat = 1;
                $found_correct = 0;
                $in_block = 0;
            }
            if ($in_faccessat) {
                if (/^\s*#ifdef CONFIG_KSU_SUSFS_SUS_PATH/) {
                    $in_block = 1;
                    $_ = "";
                }
                if ($in_block) {
                    $_ = "";
                    if (/^\s*#endif/) {
                        $in_block = 0;
                    }
                    next;
                }
                if (/^\s*unsigned int lookup_flags = LOOKUP_FOLLOW;/) {
                    if (!$found_correct) {
                        $found_correct = 1;
                        $_ .= "\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n    struct filename *fname_sus;\n    int status;\n    int error_sus;\n    fname_sus = getname_safe(filename);\n    status = susfs_sus_path_by_filename(fname_sus, &error_sus, SYSCALL_FAMILY_ALL_ENOENT);\n    putname_safe(fname_sus);\n    if (status) {\n        return error_sus;\n    }\n#endif\n";
                    }
                }
                if (/^\s*}/ && $in_faccessat) {
                    $in_faccessat = 0;
                }
            }
            if (!$in_faccessat) {
                if (/^\s*#ifdef CONFIG_KSU_SUSFS_SUS_PATH/ || /^\s*#endif \/\/ CONFIG_KSU_SUSFS_SUS_PATH/) {
                    $_ = "";
                }
            }
        ' fs/open.c

        if [ ! -s "fs/open.c" ]; then
            log "⚠️ fs/open.c est vide, restauration de la sauvegarde..."
            cp fs/open.c.bak fs/open.c
            sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_PATH/,/#endif/d' fs/open.c || true
            sed -i '/unsigned int lookup_flags = LOOKUP_FOLLOW;/a\
#ifdef CONFIG_KSU_SUSFS_SUS_PATH\
    struct filename *fname_sus;\
    int status;\
    int error_sus;\
    fname_sus = getname_safe(filename);\
    status = susfs_sus_path_by_filename(fname_sus, &error_sus, SYSCALL_FAMILY_ALL_ENOENT);\
    putname_safe(fname_sus);\
    if (status) {\
        return error_sus;\
    }\
#endif' fs/open.c || true
        fi

        log "✅ fs/open.c corrigé (backup: fs/open.c.bak)"

        # fs/proc/task_mmu.c correction if rejected
        if [ -f "fs/proc/task_mmu.c.rej" ]; then
            log "=== Correction de fs/proc/task_mmu.c ==="
            sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_MAPS/,/#endif/d' fs/proc/task_mmu.c || true
            sed -i '/show_vma_header_prefix/i\
#ifdef CONFIG_KSU_SUSFS_SUS_MAPS\
    char *out_name;\
    int ret = 0;\
    out_name = kmalloc(SUSFS_MAX_LEN_PATHNAME, GFP_KERNEL);\
    if (!out_name)\
        goto orig_flow;\
    ret = susfs_sus_maps(ino, end - start, &ino, &dev, &flags, &pgoff, vma, out_name);\
    if (ret == 2) {\
        seq_pad(m, '\'' '\'');\
        seq_puts(m, out_name);\
        seq_putc(m, '\''\\n'\'');\
        kfree(out_name);\
        return;\
    }\
    kfree(out_name);\
orig_flow:\
#endif' fs/proc/task_mmu.c || true
            rm -f fs/proc/task_mmu.c.rej || true
            log "✅ fs/proc/task_mmu.c corrigé"
        fi

        find . -name "*.rej" -delete 2>/dev/null || true

        log "=== Vérification des sources ==="
        if [ ! -f "fs/susfs.c" ]; then
            log "❌ fs/susfs.c manquant. Abandon."
            exit 1
        fi
        log "✅ fs/susfs.c présent ($(wc -l < fs/susfs.c) lignes)"

        # Mise à jour de fs/Makefile
        if ! grep -q "susfs.o" fs/Makefile 2>/dev/null; then
            echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
        fi
        if [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile 2>/dev/null; then
            echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
        fi

        rm -rf /tmp/susfs_src /tmp/jack_hooks 2>/dev/null || true

        log "✅ SuSFS intégré (version 1.3.7)"
    else
        log "[DRY-RUN] Téléchargement et application des patches 1.3.7 simulés"
    fi
fi

# ==================== 5. CONFIGURATION DU NOYAU ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
export CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}
# Optionnel : forcer clang via CC env (ex: export FORCE_CC=/path/to/clang)
: "${FORCE_CC:-}"

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p out
    CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1 || true)
    CONFIG_NAME=${CONFIG#arch/arm64/configs/}
    log "Config utilisée: $CONFIG_NAME"
    if [ -n "${FORCE_CC:-}" ]; then
        log "Forcer CC=${FORCE_CC} pour la compilation"
        make O=out LLVM=1 CC="$FORCE_CC" CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 "$CONFIG_NAME"
    else
        make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 "$CONFIG_NAME"
    fi

    ./scripts/config --file out/.config \
        --enable KSU \
        --enable KSU_MANUAL_HOOK \
        --disable KPROBES \
        --enable KSU_SUSFS \
        --enable KSU_SUSFS_SUS_PATH \
        --enable KSU_SUSFS_SUS_MOUNT \
        --enable KSU_SUSFS_SUS_KSTAT \
        --enable KSU_SUSFS_SUS_MAP \
        --enable KSU_SUSFS_SPOOF_UNAME \
        --enable KSU_SUSFS_ENABLE_LOG \
        --disable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        --enable KSU_SUSFS_OPEN_REDIRECT \
        --enable KSU_SUSFS_HAS_MAGIC_MOUNT \
        --enable THREAD_INFO_IN_TASK

    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

    # Ensure explicit CONFIG entries exist
    cat >> out/.config <<EOF
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
EOF

    grep "CONFIG_KSU_SUSFS" out/.config || true
    sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c || true

    # Patch tactile if needed
    if [ -f "techpack/display/msm/msm_drv.c" ]; then
        printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_noti[...]
        log "[+] Patch tactile appliqué"
    fi
else
    log "[DRY-RUN] Configuration du noyau (make, scripts/config, etc.) simulée"
fi

# ==================== 6. COMPILATION DU NOYAU ====================
log "=== Compilation du noyau ==="
if [ "$DRY_RUN" -eq 0 ]; then
    # Use V=1 to capture exact compile commands for debugging if necessary
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee "$LOGDIR/build.log"
    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        log "❌ BUILD FAILED"
        grep -i "error:" "$LOGDIR/build.log" | head -50 || true
        exit 1
    fi
    log "✅ Compilation du noyau réussie"
else
    log "[DRY-RUN] Compilation du noyau (make ...) simulée"
fi

# ==================== 7. COMPILATION KSUD (Rust) ====================
log "=== Compilation de ksud (Rust) ==="
cd "$GITHUB_WORKSPACE" || exit 1

if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -d "$HOME/.cargo/bin" ]; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    rustup target add aarch64-linux-android || true

    if [ ! -d "$GITHUB_WORKSPACE/android-ndk-r26d" ]; then
        log "Téléchargement Android NDK r26d (ceci peut prendre du temps)..."
        wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip -O /tmp/android-ndk-r26d-linux.zip
        unzip -q /tmp/android-ndk-r26d-linux.zip -d "$GITHUB_WORKSPACE"
        # normalize folder name
        mv "$GITHUB_WORKSPACE"/android-ndk-r26d* "$GITHUB_WORKSPACE/android-ndk-r26d" 2>/dev/null || true
    fi
    export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
    export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
    export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
    export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
    export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
    export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysr[...]"

    rm -rf "$GITHUB_WORKSPACE/ksud-src" || true
    git clone https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src" || { log "❌ clone KernelSU for ksud failed"; exit 1; }
    cd "$GITHUB_WORKSPACE/ksud-src"
    if ! git checkout "$KSU_COMMIT" 2>/dev/null; then
        git fetch --no-tags --depth=1 origin "$KSU_COMMIT" || true
        git checkout "$KSU_COMMIT" || true
    fi
    cd userspace/ksud
    mkdir -p .cargo
    cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
    cargo build --release --target aarch64-linux-android 2>&1 | tee "$LOGDIR/ksud_build.log"
    if [ ! -f "target/aarch64-linux-android/release/ksud" ]; then
        log "❌ ksud introuvable"
        tail -n 200 "$LOGDIR/ksud_build.log" || true
        exit 1
    fi
    cp target/aarch64-linux-android/release/ksud "$GITHUB_WORKSPACE/ksud"
    chmod 755 "$GITHUB_WORKSPACE/ksud"
    log "✅ ksud compilé"
else
    log "[DRY-RUN] Compilation de ksud (Rust) simulée"
fi

# ==================== 8. TÉLÉCHARGEMENT BOOT.IMG VIA API ====================
cd "$GITHUB_WORKSPACE" || exit 1

log "=== Récupération du dernier boot.img pour kiev via l'API LineageOS ==="
if [ "$DRY_RUN" -eq 0 ]; then
    API_URL="https://mirrorbits.lineageos.org/api/v2/builds/kiev"
    curl -s "$API_URL" > /tmp/api_response.json
    if command -v jq >/dev/null 2>&1; then
        BOOT_FILEPATH=$(jq -r '.kiev[0].files[] | select(.filename=="boot.img") | .filepath' /tmp/api_response.json)
    else
        BOOT_FILEPATH=$(grep -o '"boot.img","filepath":"[^"]*"' /tmp/api_response.json | head -1 | sed 's/.*"filepath":"\([^"]*\)".*/\1/')
    fi
    if [ -z "$BOOT_FILEPATH" ]; then
        log "❌ Impossible de trouver le boot.img dans l'API."
        exit 1
    fi
    BOOT_URL="https://mirrorbits.lineageos.org${BOOT_FILEPATH}"
    wget -q "$BOOT_URL" -O boot-stock.img || { log "❌ Téléchargement boot.img failed"; exit 1; }
    if [ ! -f "boot-stock.img" ] || [ $(stat -c%s "boot-stock.img") -lt 80000000 ]; then
        log "❌ Téléchargement du boot.img échoué (taille incorrecte)."
        exit 1
    fi
    log "✅ boot.img téléchargé"
else
    log "[DRY-RUN] Téléchargement du boot.img via API simulé"
fi

# ==================== 9. REPACK DU BOOT.IMG ====================
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p repack
    cp boot-stock.img repack/boot.img
    cd repack || exit 1

    # Prefer a native magiskboot binary if available
    if [ ! -x "./magiskboot" ]; then
        # Try to fetch a known magiskboot prebuilt (update URL if necessary)
        log "Tentative de récupération d'un magiskboot exécutable pour Linux..."
        # NOTE: update the URL below to a trusted prebuilt magiskboot Linux binary if you have one.
        # Fallback: extract libmagiskboot.so from Magisk APK (may not be executable on host).
        if ! wget -q -O magiskboot 'https://raw.githubusercontent.com/topjohnwu/magisk-files/master/magiskboot' 2>/dev/null; then
            log "Téléchargement direct magiskboot échoué — extraction depuis l'APK (fallback)."
            if [ ! -f "Magisk-v27.0.apk" ]; then
                wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
            fi
            unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so || true
            if [ -f lib/x86_64/libmagiskboot.so ]; then
                mv lib/x86_64/libmagiskboot.so magiskboot || true
                chmod +x magiskboot || true
            fi
        else
            chmod +x magiskboot || true
        fi
    fi

    if [ ! -x "./magiskboot" ]; then
        log "⚠️ magiskboot introuvable ou non exécutable. Le repack peut échouer. Veuillez fournir un magiskboot exécutable."
    fi

    set +e
    ./magiskboot unpack boot.img 2>&1 | tee "$LOGDIR/magiskboot_unpack.log"
    UNPACK_EXIT=${PIPESTATUS[0]:-1}
    set -e
    if [ "$UNPACK_EXIT" -ne 0 ]; then
        log "❌ Échec du unpack via magiskboot (exit $UNPACK_EXIT). Voir $LOGDIR/magiskboot_unpack.log"
        exit 1
    fi

    if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
        log "❌ Échec du unpack (kernel ou ramdisk.cpio manquant)"
        ls -l || true
        exit 1
    fi

    # Replace kernel with the built Image
    BUILT_IMAGE="$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image"
    if [ -f "$BUILT_IMAGE" ]; then
        cp "$BUILT_IMAGE" kernel
    else
        log "⚠️ Built Image introuvable: $BUILT_IMAGE"
    fi

    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" \
        "mkdir 0755 data/adb" \
        "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud" 2>&1 | tee "$LOGDIR/magiskboot_cpio_add1.log"

    cp "$GITHUB_WORKSPACE/ksud" local_su_binary || true
    chmod 755 local_su_binary || true

    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" \
        "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary" 2>&1 | tee "$LOGDIR/magiskboot_cpio_add2.log"

    rm -f local_su_binary || true

    ./magiskboot repack boot.img new-boot.img 2>&1 | tee "$LOGDIR/magiskboot_repack.log" || { log "❌ Échec du repack (voir logs)"; exit 1; }
    mv new-boot.img ../final_boot.img || true
    cd ..
else
    log "[DRY-RUN] Repack du boot.img simulé"
fi

# ==================== 10. COLLECTE DES ARTEFACTS ====================
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p output
    cp final_boot.img output/Backslashxx-SusFS-boot.img 2>/dev/null || log "⚠️ final_boot.img manquant"
    cp kernel_sources/build.log output/ 2>/dev/null || log "⚠️ build.log manquant"
    cp ksud output/ 2>/dev/null || log "⚠️ ksud manquant"
    log "=== BUILD TERMINÉ ==="
    ls -lh output/ || true
else
    log "[DRY-RUN] Collecte des artefacts (output/) simulée"
    log "=== BUILD TERMINÉ (simulation) ==="
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "Le mode dry-run est activé. Aucune modification réelle n'a été effectuée."
    log "Pour exécuter réellement, mettez DRY_RUN=0 en tête du script."
fi

exit 0
