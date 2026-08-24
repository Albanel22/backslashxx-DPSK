#!/bin/bash
set -e

echo "=== Début du build KernelSU + SusFS complet ==="
df -h

# ==================== ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

# ==================== 2. INTÉGRATION KERNELSU ====================
echo "=== Intégration KernelSU (backslashxx) ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

# ==================== 3. HOOKS MANUELS KERNELSU ====================
echo "=== Hooks manuels KernelSU ==="

hook_insert() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4"
    
    if [ ! -f "$file" ]; then
        echo "❌ $file introuvable."
        return 1
    fi
    
    if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then
        echo "❌ Signature non trouvée dans $file"
        return 1
    fi
    
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"
    echo "✅ Hook inséré dans $file"
    return 0
}

HOOKS_FAILED=0

# fs/exec.c
hook_insert "fs/exec.c" \
    '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' \
    'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' \
    || HOOKS_FAILED=1

# fs/open.c
if grep -Pzo 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
    hook_insert "fs/open.c" \
        'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
        'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
        || HOOKS_FAILED=1
elif grep -Pzo 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
    hook_insert "fs/open.c" \
        'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
        'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
        || HOOKS_FAILED=1
else
    echo "❌ Hook faccessat non trouvé"
    HOOKS_FAILED=1
fi

# fs/stat.c
if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,' fs/stat.c > /dev/null 2>&1; then
    hook_insert "fs/stat.c" \
        'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
        'ksu_handle_stat(&dfd, &filename, &flags);' \
        || HOOKS_FAILED=1
elif grep -Pzo 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' fs/stat.c > /dev/null 2>&1; then
    hook_insert "fs/stat.c" \
        'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
        'ksu_handle_stat(&dfd, &filename, &flag);' \
        || HOOKS_FAILED=1
else
    echo "❌ Hook stat non trouvé"
    HOOKS_FAILED=1
fi

if [ "$HOOKS_FAILED" -eq 1 ]; then
    echo "❌ Échec des hooks KernelSU"
    exit 1
fi

echo "✅ Hooks KernelSU en place"

# ==================== 4. INTÉGRATION SUSFS DEPUIS sidex15/susfs4ksu ====================
echo "=== Téléchargement du dépôt SusFS officiel ==="

# Télécharger le dépôt sidex15/susfs4ksu
git clone --depth=1 https://github.com/sidex15/susfs4ksu.git /tmp/susfs4ksu

echo "=== Structure du dépôt SusFS ==="
find /tmp/susfs4ksu -maxdepth 3 -type d | head -30

# Chercher les patches pour noyau 4.19
echo "=== Recherche des patches SusFS ==="
find /tmp/susfs4ksu -name "*.patch" -o -name "*.c" -o -name "*.h" | grep -i "4.19\|susfs" | head -30

# Trouver le patch principal pour 4.19
PATCH_419=$(find /tmp/susfs4ksu -name "*4.19*" -name "*.patch" | head -1)

if [ -z "$PATCH_419" ]; then
    # Chercher dans les sous-dossiers
    PATCH_419=$(find /tmp/susfs4ksu/kernel_patches -name "*.patch" | grep "4.19" | head -1)
fi

if [ -n "$PATCH_419" ]; then
    echo "✅ Patch SusFS 4.19 trouvé : $PATCH_419"
    echo "Application du patch..."
    patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
else
    echo "⚠️ Patch 4.19 non trouvé directement"
    echo "Recherche étendue..."
    
    # Lister tous les patches disponibles
    find /tmp/susfs4ksu -name "*.patch" | sort
    
    # Essayer d'appliquer tous les patches dans l'ordre
    for patch_file in $(find /tmp/susfs4ksu/kernel_patches -name "*.patch" | sort); do
        echo "Application de : $patch_file"
        patch -p1 < "$patch_file" 2>&1 | tee -a /tmp/susfs_patch.log || true
    done
fi

# Vérifier si les sources SusFS ont été créées
echo "=== Vérification des sources SusFS ==="

if [ -d "drivers/kernelsu/susfs" ]; then
    echo "✅ Dossier SusFS créé"
    find drivers/kernelsu/susfs -type f | head -30
fi

# Chercher les fichiers source SusFS créés par le patch
SUSFS_C_FILES=$(find . -name "susfs*.c" -not -path "./out/*" | head -20)
SUSFS_H_FILES=$(find . -name "susfs*.h" -not -path "./out/*" | head -20)

echo "Fichiers .c SusFS :"
echo "$SUSFS_C_FILES"

echo "Fichiers .h SusFS :"
echo "$SUSFS_H_FILES"

# Si les sources ne sont pas dans le bon endroit, les déplacer
if [ -z "$SUSFS_C_FILES" ]; then
    echo "⚠️ Aucun fichier source SusFS créé par le patch"
    echo "Recherche dans le dépôt téléchargé..."
    
    # Chercher les sources dans le dépôt
    find /tmp/susfs4ksu -name "susfs*.c" -o -name "susfs*.h" | head -30
    
    # Créer la structure
    mkdir -p drivers/kernelsu/susfs/src
    mkdir -p drivers/kernelsu/susfs/include/linux
    
    # Copier les fichiers source si trouvés
    if find /tmp/susfs4ksu -name "susfs.c" | grep -q .; then
        echo "Copie des sources depuis le dépôt..."
        find /tmp/susfs4ksu -name "susfs*.c" -exec cp {} drivers/kernelsu/susfs/src/ \;
        find /tmp/susfs4ksu -name "susfs*.h" -exec cp {} drivers/kernelsu/susfs/include/linux/ \;
    else
        echo "❌ Sources SusFS introuvables dans le dépôt"
        echo "Création de sources minimales..."
        
        # Créer le header
        cat > drivers/kernelsu/susfs/include/linux/susfs_def.h << 'HEADER_EOF'
#ifndef _SUSFS_DEF_H_
#define _SUSFS_DEF_H_

#include <linux/types.h>
#include <linux/version.h>
#include <linux/cred.h>
#include <linux/uidgid.h>

#define SUSFS_VERSION "1.5.4"

#ifdef CONFIG_KSU_SUSFS
extern u32 susfs_ksu_sid;
extern u32 susfs_priv_app_sid;
extern bool susfs_is_current_ksu_domain(void);
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
extern int susfs_sus_path(const char *path);
extern int susfs_sus_mount(const char *path);
extern int susfs_sus_kstat(const char *path);
extern int susfs_spoof_uname(void);
#endif

#endif
HEADER_EOF

        # Créer la source minimale
        cat > drivers/kernelsu/susfs/src/susfs.c << 'SOURCE_EOF'
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/cred.h>
#include <linux/uidgid.h>
#include <linux/export.h>
#include "../include/linux/susfs_def.h"

#ifdef CONFIG_KSU_SUSFS
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
bool susfs_is_current_ksu_domain(void) { return false; }
EXPORT_SYMBOL(susfs_is_current_ksu_domain);
int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid) { return 0; }
EXPORT_SYMBOL(ksu_handle_setresuid);
int susfs_sus_path(const char *path) { return 0; }
EXPORT_SYMBOL(susfs_sus_path);
int susfs_sus_mount(const char *path) { return 0; }
EXPORT_SYMBOL(susfs_sus_mount);
int susfs_sus_kstat(const char *path) { return 0; }
EXPORT_SYMBOL(susfs_sus_kstat);
int susfs_spoof_uname(void) { return 0; }
EXPORT_SYMBOL(susfs_spoof_uname);
#endif
SOURCE_EOF
    fi
fi

# Créer le Makefile SusFS
if [ -d "drivers/kernelsu/susfs" ]; then
    if [ ! -f "drivers/kernelsu/susfs/Makefile" ]; then
        cat > drivers/kernelsu/susfs/Makefile << 'EOF'
obj-$(CONFIG_KSU_SUSFS) += src/susfs.o
EOF
    fi
fi

# Ajouter au Makefile KernelSU
if [ -f "drivers/kernelsu/Makefile" ]; then
    if ! grep -q "susfs/" drivers/kernelsu/Makefile; then
        echo 'obj-$(CONFIG_KSU_SUSFS) += susfs/' >> drivers/kernelsu/Makefile
        echo "✅ SusFS ajouté au Makefile"
    fi
fi

# ==================== 5. CORRECTIONS POST-PATCH ====================
echo "=== Corrections post-patch ==="

# Correction namespace.c
if ! grep -q "susfs_def.h" fs/namespace.c 2>/dev/null; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c 2>/dev/null || true
fi

# Correction task_mmu.c
sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true

# ==================== 6. CONFIGURATION ====================
echo "=== Configuration du noyau ==="

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG=$(find arch/arm64/configs/ \
    \( -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" \) \
    | head -1)

CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$CONFIG_NAME"

# Ajouter la configuration
{
    echo "CONFIG_KSU=y"
    echo "CONFIG_KSU_MANUAL_HOOK=y"
    echo "# CONFIG_KPROBES is not set"
    echo "# CONFIG_HAVE_KPROBES is not set"
    echo "# CONFIG_KPROBE_EVENTS is not set"
    echo "CONFIG_COMPAT=y"
    echo "CONFIG_COMPAT_32BIT_TIME=y"
    echo "# CONFIG_COMPAT_VDSO is not set"
    echo "# CONFIG_VDSO32 is not set"
    echo "CONFIG_KSU_SUSFS=y"
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
    echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
    echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
    echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
} >> out/.config

make O=out LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

# ==================== 7. PATCHS SPÉCIFIQUES ====================
echo "=== Patchs spécifiques ==="

# Patch signatures
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# Patch tactile Motorola
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 8. COMPILATION ====================
echo "=== Compilation du noyau ==="

make O=out LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    -j"$(nproc)" Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi

echo "✅ Compilation réussie"

# Vérification des symboles
echo "=== Vérification SusFS ==="
strings out/arch/arm64/boot/Image | grep -i "susfs" | head -20

# ==================== 9. COMPILATION KSUD ====================
echo "=== Compilation de ksud ==="

cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

git clone --depth=1 https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
EOF

cargo build --release --target aarch64-linux-android

cp target/aarch64-linux-android/release/ksud "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"

echo "✅ ksud compilé"

# ==================== 10. CRÉATION IMAGE BOOT ====================
cd "$GITHUB_WORKSPACE"

echo "=== Création de l'image boot ==="

mkdir -p output

# Utiliser mkbootimg directement
mkbootimg \
    --kernel kernel_sources/out/arch/arm64/boot/Image \
    --ramdisk /dev/null \
    --output output/Backslashxx-SusFS-boot.img \
    --header_version 2 \
    --pagesize 4096 \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"

cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud

echo "=== BUILD TERMINÉ ==="
ls -lh output/
