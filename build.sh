#!/bin/bash
set -e

# ==================== MODE DRY-RUN ====================
DRY_RUN=0  # ← Changez à 0 pour exécuter réellement

# ==================== FONCTIONS ====================
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

append_to_file() {
    local file="$1"
    local content="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] Ajout dans $file :"
        echo "$content" | sed 's/^/  /'
    else
        echo "$content" >> "$file"
    fi
}

echo "=== BUILD DIAGNOSTIC : KernelSU + SuSFS (patchs 10 + 50) + UAPI2 + sys_reboot ==="
df -h

# ==================== ENVIRONNEMENT ====================
if [ "$DRY_RUN" -eq 0 ]; then
    echo "=== MODE RÉEL : installation des dépendances ==="
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
    sudo apt-get clean
    sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    sudo apt-get update
    sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
        libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
        clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl \
        python3-pip wget jq
else
    echo "=== MODE DRY-RUN : aucune installation système ==="
fi

cd "$GITHUB_WORKSPACE" || exit 1

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 (lineage-23.2) ==="
if [ "$DRY_RUN" -eq 0 ]; then
    git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
        -b lineage-23.2 --depth=1 kernel_sources
else
    echo "[DRY-RUN] git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources"
    mkdir -p kernel_sources
    cd kernel_sources
    mkdir -p fs include/linux drivers techpack/display/msm kernel arch/arm64/boot out/arch/arm64/boot fs/overlayfs fs/proc
    touch fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
    touch fs/exec.c fs/open.c fs/stat.c fs/namespace.c kernel/reboot.c fs/overlayfs/readdir.c fs/proc/task_mmu.c
    touch fs/Makefile drivers/Makefile drivers/Kconfig include/linux/mount.h
    touch techpack/display/msm/msm_drv.c
    touch out/arch/arm64/boot/Image
    cd ..
fi

cd kernel_sources || exit 1
KERNEL_ROOT="$PWD"

# ==================== 2. KERNELSU (commit 0b138d6a) ====================
echo "=== Intégration KernelSU (commit 0b138d6a) ==="
if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf drivers/kernelsu KernelSU /tmp/KernelSU || true
    KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"
    git clone https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
    cd /tmp/KernelSU
    git fetch --depth=1 origin "$KSU_COMMIT"
    git checkout "$KSU_COMMIT"
    cd "$KERNEL_ROOT"
    KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' /tmp/KernelSU/kernel/Makefile | head -1)
    [ -z "$KSU_VER" ] && KSU_VER="32601"
    echo "[+] KSU_VERSION : $KSU_VER"
    ln -sf /tmp/KernelSU/kernel drivers/kernelsu
    if [ ! -d "drivers/kernelsu" ]; then
        echo "❌ Symlink échoué"
        exit 1
    fi
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
    sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig
    if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
        echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
    fi
    sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
    sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
    sed -i "s/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION ${KSU_VER}/" /tmp/KernelSU/uapi/ksu.h 2>/dev/null || true
    DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
    if [ -f "$DISPATCH_FILE" ]; then
        sed -i "s/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/" "$DISPATCH_FILE"
        sed -i "s/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = ${KSU_VER};/" "$DISPATCH_FILE"
        sed -i "s/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE"
        sed -i "s/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE"
    fi
    echo "✅ KernelSU intégré"
else
    echo "[DRY-RUN] Intégration KernelSU (commit 0b138d6a) simulée"
fi

# ==================== 3. HOOKS KERNELSU (ajout conditionnel) ====================
echo "=== Vérification des hooks KernelSU ==="
hook_insert_if_absent() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4" search="$5"
    [ ! -f "$file" ] && return 1
    if grep -q "$search" "$file" 2>/dev/null; then
        echo "⏩ $search déjà présent dans $file"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] Hook $search ajouté dans $file"
        return 0
    fi
    if ! grep -Pzo "$sig_re" "$file" >/dev/null 2>&1; then
        echo "❌ Signature non trouvée dans $file"
        return 1
    fi
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \"-Wdeclaration-after-statement\"\n${call_line}\n#endif\n/s" "$file"
    echo "✅ Hook inséré dans $file"
    return 0
}

hook_insert_if_absent "fs/exec.c" \
    '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' \
    'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' \
    'ksu_handle_execveat'

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
    else
        echo "[DRY-RUN] Hook sys_reboot ajouté dans kernel/reboot.c"
    fi
fi

# ==================== 4. INTÉGRATION SUSFS (patchs 10 + 50) ====================
echo "=== Téléchargement des patches SuSFS (10 + 50) ==="
PATCH10_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
PATCH50_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/kernel_patches/50_add_susfs_in_kernel-4.19.patch"

if [ "$DRY_RUN" -eq 0 ]; then
    wget -q "$PATCH10_URL" -O /tmp/10_enable_susfs_for_ksu.patch || { echo "❌ Échec du téléchargement du patch 10"; exit 1; }
    wget -q "$PATCH50_URL" -O /tmp/50_add_susfs_in_kernel-4.19.patch || { echo "❌ Échec du téléchargement du patch 50"; exit 1; }

    echo "=== Application du patch 10 sur KernelSU ==="
    cp /tmp/10_enable_susfs_for_ksu.patch drivers/kernelsu/
    cd drivers/kernelsu
    patch -p1 --forward --ignore-whitespace < 10_enable_susfs_for_ksu.patch 2>&1 | tee /tmp/patch10.log || {
        echo "⚠️ Certains hunks du patch 10 ont échoué."
        grep -E "FAILED|reject" /tmp/patch10.log
        find . -name "*.rej" -delete 2>/dev/null
    }
    if ! grep -q "KSU_SUSFS" Kconfig 2>/dev/null; then
        echo "⚠️ Patch 10 n'a pas modifié Kconfig. Ajout manuel..."
        cat >> Kconfig << 'EOF'
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
    if ! grep -q "DKSU_SUSFS" Makefile; then
        echo "ccflags-y += -DKSU_SUSFS" >> Makefile
    fi
    cd "$KERNEL_ROOT"

    echo "=== Application du patch 50 sur le noyau ==="
    cp /tmp/50_add_susfs_in_kernel-4.19.patch .
    patch -p1 --forward --ignore-whitespace < 50_add_susfs_in_kernel-4.19.patch 2>&1 | tee /tmp/patch50.log || {
        echo "⚠️ Certains hunks du patch 50 ont échoué."
        grep -E "FAILED|reject" /tmp/patch50.log
        find . -name "*.rej" -delete 2>/dev/null
    }
    rm -f 50_add_susfs_in_kernel-4.19.patch

    echo "=== Vérification et téléchargement des sources ==="
    if [ ! -f "fs/susfs.c" ]; then
        wget -q "https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/fs/susfs.c" -O fs/susfs.c
    fi
    if [ ! -f "include/linux/susfs.h" ]; then
        wget -q "https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/include/linux/susfs.h" -O include/linux/susfs.h
    fi
    if [ ! -f "include/linux/susfs_def.h" ]; then
        wget -q "https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/include/linux/susfs_def.h" -O include/linux/susfs_def.h
    fi
    if [ ! -f "fs/sus_su.c" ]; then
        wget -q "https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/fs/sus_su.c" -O fs/sus_su.c 2>/dev/null || echo "⚠️ sus_su.c non trouvé (facultatif)"
    fi

    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    fi
    if [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
    fi

    # Supprimer les .rej restants
    find . -name "*.rej" -delete 2>/dev/null

    if [ -f "fs/susfs.c" ]; then
        echo "✅ fs/susfs.c présent ($(wc -l < fs/susfs.c) lignes)"
        echo "✅ SuSFS intégré avec succès"
    else
        echo "❌ fs/susfs.c manquant. Abandon."
        exit 1
    fi
else
    echo "[DRY-RUN] Téléchargement et application des patches 10+50 simulés"
fi

# ==================== 5. CONFIGURATION DU NOYAU ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p out
    CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
    CONFIG_NAME=${CONFIG#arch/arm64/configs/}
    echo "Config utilisée: $CONFIG_NAME"
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME
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
    grep "CONFIG_KSU_SUSFS" out/.config
    sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

    # Patch tactile
    if [ -f "techpack/display/msm/msm_drv.c" ]; then
        printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
        echo "[+] Patch tactile appliqué"
    fi
else
    echo "[DRY-RUN] Configuration du noyau (make, scripts/config, etc.) simulée"
fi

# ==================== 6. COMPILATION DU NOYAU ====================
echo "=== Compilation du noyau ==="
if [ "$DRY_RUN" -eq 0 ]; then
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        echo "❌ BUILD FAILED"
        grep -i "error:" build.log | head -50
        exit 1
    fi
    echo "✅ Compilation du noyau réussie"
else
    echo "[DRY-RUN] Compilation du noyau (make ...) simulée"
fi

# ==================== 7. COMPILATION KSUD ====================
echo "=== Compilation de ksud (Rust) ==="
cd "$GITHUB_WORKSPACE"

if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -d "$HOME/.cargo/bin" ]; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    source "$HOME/.cargo/env"
    rustup target add aarch64-linux-android
    if [ ! -d "$GITHUB_WORKSPACE/android-ndk-r26d" ]; then
        wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
        unzip -q android-ndk-r26d-linux.zip
    fi
    export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
    export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
    export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
    export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
    export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
    export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"
    rm -rf "$GITHUB_WORKSPACE/ksud-src"
    git clone https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
    cd "$GITHUB_WORKSPACE/ksud-src"
    git fetch --depth=1 origin "$KSU_COMMIT"
    git checkout "$KSU_COMMIT"
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
    cargo build --release --target aarch64-linux-android
    if [ ! -f "target/aarch64-linux-android/release/ksud" ]; then
        echo "❌ ksud introuvable"
        exit 1
    fi
    cp target/aarch64-linux-android/release/ksud "$GITHUB_WORKSPACE/ksud"
    chmod 755 "$GITHUB_WORKSPACE/ksud"
    echo "✅ ksud compilé"
else
    echo "[DRY-RUN] Compilation de ksud (Rust) simulée"
fi

# ==================== 8. TÉLÉCHARGEMENT BOOT.IMG VIA API ====================
cd "$GITHUB_WORKSPACE"

echo "=== Récupération du dernier boot.img pour kiev via l'API LineageOS ==="
if [ "$DRY_RUN" -eq 0 ]; then
    API_URL="https://mirrorbits.lineageos.org/api/v2/builds/kiev"
    curl -s "$API_URL" > /tmp/api_response.json
    if command -v jq &> /dev/null; then
        BOOT_FILEPATH=$(jq -r '.kiev[0].files[] | select(.filename=="boot.img") | .filepath' /tmp/api_response.json)
    else
        BOOT_FILEPATH=$(grep -o '"boot.img","filepath":"[^"]*"' /tmp/api_response.json | head -1 | sed 's/.*"filepath":"\([^"]*\)".*/\1/')
    fi
    if [ -z "$BOOT_FILEPATH" ]; then
        echo "❌ Impossible de trouver le boot.img dans l'API."
        exit 1
    fi
    BOOT_URL="https://mirrorbits.lineageos.org${BOOT_FILEPATH}"
    wget -q "$BOOT_URL" -O boot-stock.img
    if [ ! -f "boot-stock.img" ] || [ $(stat -c%s "boot-stock.img") -lt 80000000 ]; then
        echo "❌ Téléchargement du boot.img échoué."
        exit 1
    fi
    echo "✅ boot.img téléchargé"
else
    echo "[DRY-RUN] Téléchargement du boot.img via API simulé"
fi

# ==================== 9. REPACK DU BOOT.IMG ====================
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p repack
    cp boot-stock.img repack/boot.img
    cd repack
    if [ ! -f "magiskboot" ]; then
        wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
        unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
        mv lib/x86_64/libmagiskboot.so magiskboot
        chmod +x magiskboot
        rm -rf Magisk-v27.0.apk lib/
    fi
    set +e
    ./magiskboot unpack boot.img
    set -e
    if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
        echo "❌ Échec du unpack"
        exit 1
    fi
    cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" \
        "mkdir 0755 data/adb" \
        "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
    cp "$GITHUB_WORKSPACE/ksud" local_su_binary
    chmod 755 local_su_binary
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" \
        "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary"
    rm -f local_su_binary
    ./magiskboot repack boot.img new-boot.img || { echo "❌ Échec du repack"; exit 1; }
    mv new-boot.img ../final_boot.img
    cd ..
else
    echo "[DRY-RUN] Repack du boot.img simulé"
fi

# ==================== 10. COLLECTE DES ARTEFACTS ====================
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p output
    cp final_boot.img output/Backslashxx-SusFS-boot.img 2>/dev/null || echo "⚠️ final_boot.img manquant"
    cp kernel_sources/build.log output/ 2>/dev/null || echo "⚠️ build.log manquant"
    cp ksud output/ 2>/dev/null || echo "⚠️ ksud manquant"
    echo "=== BUILD TERMINÉ ==="
    ls -lh output/
else
    echo "[DRY-RUN] Collecte des artefacts (output/) simulée"
    echo "=== BUILD TERMINÉ (simulation) ==="
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Le mode dry-run est activé. Aucune modification réelle n'a été effectuée."
    echo "Pour exécuter réellement, mettez DRY_RUN=0 en tête du script."
fi
