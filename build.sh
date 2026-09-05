#!/usr/bin/env bash
# build_kernelsu_susfs.sh
# KernelSU + SuSFS 1.3.7 + UAPI2 + sys_reboot + PANEL_NOTIFICATIONS
# Device: Motorola kiev (sm8250 / Lito)
set -euo pipefail

# ==================== MODE DRY-RUN ====================
DRY_RUN=${DRY_RUN:-0}   # 0 = compilation réelle | 1 = simulation

# ==================== UTILITAIRES ====================
log() { printf "%s %s\n" "$(date -Is)" "$*"; }

log "=== BUILD : KernelSU + SuSFS 1.3.7 + PANEL_NOTIFICATIONS (kiev) ==="
df -h || true

LOGDIR=${LOGDIR:-/tmp/kernelsu_build_logs}
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/build_stdout.log") 2> >(tee -a "$LOGDIR/build_stderr.log" >&2)

# ==================== ENVIRONNEMENT ====================
if [ "$DRY_RUN" -eq 0 ]; then
    log "=== Installation des dépendances ==="
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
    sudo apt-get clean || true
    sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    sudo apt-get update -y
    sudo apt-get install -y bc bison build-essential ccache flex libelf-dev \
        libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
        clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg \
        perl python3-pip wget jq pkg-config || true
else
    log "=== MODE DRY-RUN : pas d'installation système ==="
fi

: "${GITHUB_WORKSPACE:=${PWD}}"
cd "$GITHUB_WORKSPACE" || exit 1

# ==================== 1. CLONAGE DU NOYAU ====================
if [ ! -d "kernel_sources" ]; then
    log "=== Clonage du kernel Motorola sm8250 (lineage-23.2) ==="
    if [ "$DRY_RUN" -eq 0 ]; then
        git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
            -b lineage-23.2 --depth=1 kernel_sources || { log "❌ git clone failed"; exit 1; }
    else
        mkdir -p kernel_sources
    fi
fi

cd kernel_sources || exit 1
KERNEL_ROOT="$PWD"

# Nettoyage
make mrproper || true
rm -rf out
mkdir -p out

# ==================== 2. KERNELSU ====================
if [ ! -d "drivers/kernelsu" ]; then
    log "=== Intégration KernelSU (commit 0b138d6a) ==="
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -rf drivers/kernelsu /tmp/KernelSU || true
        KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"

        git clone https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
        cd /tmp/KernelSU
        git fetch --depth=1 origin "$KSU_COMMIT" || true
        git checkout "$KSU_COMMIT" || { log "❌ Cannot checkout KSU commit"; exit 1; }
        cd "$KERNEL_ROOT"

        ln -sf /tmp/KernelSU/kernel drivers/kernelsu
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
        sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

        KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' drivers/kernelsu/Makefile | head -1 || echo "32601")
        if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
            echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
        fi

        # UAPI fixes
        sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
        sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
        sed -i "s/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION ${KSU_VER}/" /tmp/KernelSU/uapi/ksu.h 2>/dev/null || true

        DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
        if [ -f "$DISPATCH_FILE" ]; then
            sed -i "s/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/" "$DISPATCH_FILE" || true
            sed -i "s/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = ${KSU_VER};/" "$DISPATCH_FILE" || true
        fi

        log "✅ KernelSU intégré (version $KSU_VER)"
    else
        log "[DRY-RUN] Intégration KernelSU simulée"
    fi
fi

# ==================== 3. HOOKS KERNELSU ====================
log "=== Hooks KernelSU ==="

if [ "$DRY_RUN" -eq 0 ]; then
    # sys_reboot hook
    if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
        sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\
#endif' kernel/reboot.c

        sed -i '/int ret = 0;/a\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
\tksu_handle_sys_reboot(magic1, magic2, cmd, \&arg);\
#endif' kernel/reboot.c
        log "✅ Hook sys_reboot ajouté"
    fi
fi

# ==================== 4. SUSFS 1.3.7 ====================
if [ ! -f "fs/susfs.c" ]; then
    log "=== Intégration SuSFS 1.3.7 ==="
    if [ "$DRY_RUN" -eq 0 ]; then
        PATCH10_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/1.3.7/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
        PATCH50_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/1.3.7/kernel_patches/50_add_susfs_in_kernel-4.19.patch"

        wget -q "$PATCH10_URL" -O /tmp/10_enable_susfs_for_ksu.patch || exit 1
        wget -q "$PATCH50_URL" -O /tmp/50_add_susfs_in_kernel-4.19.patch || exit 1

        git clone --depth=1 --branch 1.3.7 https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs_src

        cp /tmp/susfs_src/kernel_patches/fs/susfs.c fs/
        cp /tmp/susfs_src/kernel_patches/fs/sus_su.c fs/ 2>/dev/null || true
        cp /tmp/susfs_src/kernel_patches/include/linux/susfs.h include/linux/ 2>/dev/null || true
        cp /tmp/susfs_src/kernel_patches/include/linux/susfs_def.h include/linux/ 2>/dev/null || true

        # Patch KernelSU
        cp /tmp/10_enable_susfs_for_ksu.patch drivers/kernelsu/
        cd drivers/kernelsu
        patch -p1 --forward --ignore-whitespace < 10_enable_susfs_for_ksu.patch || true
        echo 'ccflags-y += -DKSU_SUSFS' >> Makefile
        cd "$KERNEL_ROOT"

        # Patch kernel
        patch -p1 --forward --ignore-whitespace < /tmp/50_add_susfs_in_kernel-4.19.patch || true

        # Nettoyage des .rej
        find . -name "*.rej" -delete 2>/dev/null || true

        # Correction task_mmu.c (éviter les #ifdef cassés)
        if [ -f "fs/proc/task_mmu.c" ]; then
            cp fs/proc/task_mmu.c fs/proc/task_mmu.c.bak
            sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_MAPS/,/#endif/d' fs/proc/task_mmu.c || true
            log "✅ Nettoyage task_mmu.c effectué"
        fi

        # fs/Makefile
        if ! grep -q "susfs.o" fs/Makefile; then
            echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
        fi
        if [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile; then
            echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
        fi

        log "✅ SuSFS 1.3.7 intégré"
    else
        log "[DRY-RUN] SuSFS simulé"
    fi
fi

# ==================== 5. CONFIGURATION ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

CONFIG_NAME="vendor/lito-perf_defconfig"
FRAGMENT="arch/arm64/configs/vendor/ext_config/kiev-default.config"

log "Config de base : $CONFIG_NAME"
log "Fragment       : $FRAGMENT"

if [ "$DRY_RUN" -eq 0 ]; then
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

    if [ -f "$FRAGMENT" ]; then
        log "Merging fragment $FRAGMENT ..."
        scripts/kconfig/merge_config.sh -O out -m out/.config "$FRAGMENT" || true
    else
        log "⚠️ Fragment introuvable, on continue sans"
    fi

    ./scripts/config --file out/.config \
        --enable KSU \
        --enable KSU_MANUAL_HOOK \
        --disable KPROBES \
        --enable KSU_SUSFS \
        --enable KSU_SUSFS_SUS_PATH \
        --enable KSU_SUSFS_SUS_MOUNT \
        --enable KSU_SUSFS_SUS_KSTAT \
        --disable KSU_SUSFS_SUS_MAP \
        --enable KSU_SUSFS_SPOOF_UNAME \
        --enable KSU_SUSFS_ENABLE_LOG \
        --disable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        --enable KSU_SUSFS_OPEN_REDIRECT \
        --enable KSU_SUSFS_HAS_MAGIC_MOUNT \
        --enable THREAD_INFO_IN_TASK \
        --enable PANEL_NOTIFICATIONS

    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

    cat >> out/.config <<EOF
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
# CONFIG_KSU_SUSFS_SUS_MAP is not set
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_PANEL_NOTIFICATIONS=y
EOF

    grep -E "CONFIG_KSU|CONFIG_PANEL_NOTIFICATIONS" out/.config | head -20 || true

    # Désactivation signature modules
    sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c || true

    log "✅ CONFIG_PANEL_NOTIFICATIONS activé (implémentation native)"
else
    log "[DRY-RUN] Configuration simulée"
fi

# ==================== 6. COMPILATION ====================
log "=== Compilation du noyau ==="
if [ "$DRY_RUN" -eq 0 ]; then
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee "$LOGDIR/build.log"

    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        log "❌ BUILD FAILED"
        grep -i "error:" "$LOGDIR/build.log" | head -40 || true
        exit 1
    fi
    log "✅ Compilation réussie"
else
    log "[DRY-RUN] Compilation simulée"
fi

# ==================== 7. COMPILATION KSUD ====================
log "=== Compilation de ksud ==="
cd "$GITHUB_WORKSPACE" || exit 1

if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -d "$HOME/.cargo/bin" ]; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    rustup target add aarch64-linux-android || true

    if [ ! -d "$GITHUB_WORKSPACE/android-ndk-r26d" ]; then
        log "Téléchargement Android NDK r26d..."
        wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip -O /tmp/ndk.zip
        unzip -q /tmp/ndk.zip -d "$GITHUB_WORKSPACE"
        mv "$GITHUB_WORKSPACE"/android-ndk-r26d* "$GITHUB_WORKSPACE/android-ndk-r26d" 2>/dev/null || true
    fi

    export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
    export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

    NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
    NDK_SYSROOT="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    export AARCH64_CLANG_PATH="$NDK_BIN/aarch64-linux-android26-clang"
    export AARCH64_CLANGXX_PATH="$NDK_BIN/aarch64-linux-android26-clang++"
    export AR_PATH="$NDK_BIN/llvm-ar"

    # Correct pour bindgen (UNIQUEMENT avec underscores)
    export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$NDK_SYSROOT -I$NDK_SYSROOT/usr/include -I$NDK_SYSROOT/usr/include/aarch64-linux-android"
    export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="$BINDGEN_EXTRA_CLANG_ARGS"

    rm -rf ksud-src
    git clone https://github.com/backslashxx/KernelSU.git ksud-src
    cd ksud-src
    git fetch --depth=1 origin 0b138d6a9cfe4dc163aa05c21b1e6a14ff868230 || true
    git checkout 0b138d6a9cfe4dc163aa05c21b1e6a14ff868230 || true
    cd userspace/ksud

    mkdir -p .cargo
    cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
ar = "$AR_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS"
EOF

# Force l'utilisation du bon clang pour le build script aussi
    export CC="$AARCH64_CLANG_PATH"
    export CXX="$AARCH64_CLANGXX_PATH"

log "Lancement de cargo build..."
    set +e
    cargo build --release --target aarch64-linux-android 2>&1 | tee "$LOGDIR/ksud_build.log"
    CARGO_EXIT=${PIPESTATUS[0]}
    set -e

    log "Code de sortie cargo : $CARGO_EXIT"
    log "Répertoire courant : $(pwd)"
    log "Contenu du répertoire courant :"
    ls -la || true

    log "Recherche du binaire ksud dans tout le workspace..."
    KSUD_BIN=$(find "$GITHUB_WORKSPACE" -name "ksud" -type f 2>/dev/null | head -1 || true)

    if [ -z "$KSUD_BIN" ]; then
        # Essai plus large
        KSUD_BIN=$(find "$GITHUB_WORKSPACE" -type f -executable -name "*ksud*" 2>/dev/null | head -1 || true)
    fi

    log "Binaire trouvé : ${KSUD_BIN:-aucun}"

    if [ -z "$KSUD_BIN" ] || [ ! -f "$KSUD_BIN" ]; then
        log "❌ ksud introuvable après compilation"
        log "=== Recherche de tous les fichiers 'release' ==="
        find "$GITHUB_WORKSPACE" -path "*/release/*" -type f 2>/dev/null | head -50 || true
        log "=== Fin du log cargo ==="
        tail -n 40 "$LOGDIR/ksud_build.log" || true
        exit 1
    fi

log "✅ ksud trouvé : $KSUD_BIN"
    cp "$KSUD_BIN" "$GITHUB_WORKSPACE/ksud"
    chmod 755 "$GITHUB_WORKSPACE/ksud"
    ls -lh "$GITHUB_WORKSPACE/ksud"
    log "✅ ksud compilé avec succès"
else
    log "[DRY-RUN] Compilation de ksud simulée"
fi

# ==================== 8. TÉLÉCHARGEMENT BOOT.IMG ====================
cd "$GITHUB_WORKSPACE" || exit 1
log "=== Téléchargement boot.img ==="

if [ "$DRY_RUN" -eq 0 ]; then
    BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img"
    wget -q --show-progress "$BOOT_URL" -O boot-stock.img || { log "❌ Échec téléchargement boot.img"; exit 1; }

    if [ ! -f "boot-stock.img" ] || [ $(stat -c%s "boot-stock.img") -lt 80000000 ]; then
        log "❌ boot.img invalide"
        exit 1
    fi
    log "✅ boot.img téléchargé"
else
    log "[DRY-RUN] Téléchargement boot.img simulé"
fi

# ==================== 9. REPACK ====================
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p repack
    cp boot-stock.img repack/boot.img
    cd repack

    # magiskboot
    if [ ! -x "./magiskboot" ]; then
        wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
        unzip -q Magisk.apk lib/x86_64/libmagiskboot.so
        mv lib/x86_64/libmagiskboot.so magiskboot
        chmod +x magiskboot
    fi

    ./magiskboot unpack boot.img
    cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" \
        "mkdir 0755 data/adb" \
        "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

    cp "$GITHUB_WORKSPACE/ksud" local_su
    chmod 755 local_su
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" \
        "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su"
    rm -f local_su

    ./magiskboot repack boot.img new-boot.img
    mv new-boot.img ../final_boot.img
    cd ..
else
    log "[DRY-RUN] Repack simulé"
fi

# ==================== 10. ARTEFACTS ====================
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p output
    cp final_boot.img output/Backslashxx-SusFS-boot.img
    cp ksud output/ 2>/dev/null || true
    cp kernel_sources/out/arch/arm64/boot/Image output/ 2>/dev/null || true
    log "=== BUILD TERMINÉ ==="
    ls -lh output/
else
    log "=== BUILD TERMINÉ (DRY-RUN) ==="
fi

exit 0
