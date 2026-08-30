#!/bin/bash
set -e

echo "=== BUILD MATCH : backslashxx/KernelSU + JackA1ltman SuSFS v4.19 ==="
df -h

# ==================== ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/://ubuntu.com' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 perl

cd "$GITHUB_WORKSPACE"
mkdir -p workspace_boot
cd workspace_boot

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 (LineageOS) ==="
git clone https://github.com \
    -b lineage-23.2 --depth=1 kernel_sources

# ==================== 2. TÉLÉCHARGEMENT DU BOOT.IMG OFFICIEL ====================
echo "=== Récupération du boot.img stock LineageOS ==="
curl -Lo stock_boot.img "https://lineageos.org"

# Récupération de magiskboot pour le repack final
mkdir -p tools
curl -Lo tools/magiskboot.tar.gz "https://github.com" || \
curl -Lo tools/magiskboot "https://github.com"
if [ -f "tools/magiskboot.tar.gz" ]; then
    tar -xf tools/magiskboot.tar.gz -C tools/
fi
chmod +x tools/magiskboot

# ==================== 3. INTEGRATION DE BACKSLASHXX/KERNELSU ====================
echo "=== Clonage de backslashxx/KernelSU ==="
cd kernel_sources
rm -rf drivers/kernelsu KernelSU susfs4ksu /tmp/KernelSU || true

KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"

git clone --depth=1 https://github.com /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin "$KSU_COMMIT"
git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/workspace_boot/kernel_sources"

# Création du lien symbolique requis par le pilote de backslashxx
ln -sf /tmp/KernelSU/kernel drivers/kernelsu

if [ -d "drivers/kernelsu" ]; then
    echo "✅ Symlink backslashxx/KernelSU OK"
else
    echo "❌ Échec du Symlink"
    exit 1
fi

printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

# ==================== 3b. INJECTION DU BINAIRE KSUD SYNCHRONISÉ ====================
echo "=== Synchronisation de l'espace utilisateur pour éviter l'Erreur 1 ==="
cd /tmp/KernelSU/userspace/ksud
mkdir -p bin/aarch64
# Injection du binaire v1.0.1 qui correspond à la base de protocole de ce commit de backslashxx
curl -Lo bin/aarch64/ksud "https://github.com"
chmod +x bin/aarch64/ksud

cd "$GITHUB_WORKSPACE/workspace_boot/kernel_sources"

# Configuration automatique des flags de version (dynamique, sans forçage bloquant)
KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' drivers/kernelsu/Makefile | head -1)
if [ -z "$KSU_VER" ]; then KSU_VER="32601"; fi
if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
    echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
fi

# ==================== 4. HOOKS MANUELS POUR COHABITATION KSU/SUSFS ====================
echo "=== Application des hooks spécifiques ==="
hook_insert() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4"
    if [ ! -f "$file" ]; then return 1; fi
    if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then return 1; fi
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"
    return 0
}

HOOKS_FAILED=0
hook_insert "fs/exec.c" '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' 'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' || HOOKS_FAILED=1

if grep -Pzo 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
    hook_insert "fs/open.c" 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' 'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' || HOOKS_FAILED=1
else
    hook_insert "fs/open.c" 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' 'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' || HOOKS_FAILED=1
fi

if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,' fs/stat.c > /dev/null 2>&1; then
    hook_insert "fs/stat.c" 'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' 'ksu_handle_stat(&dfd, &filename, &flags);' || HOOKS_FAILED=1
else
    hook_insert "fs/stat.c" 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' 'ksu_handle_stat(&dfd, &filename, &flag);' || HOOKS_FAILED=1
fi

# ==================== 5. APPLICATION DES PATCHS JACKA1LTMAN (SUSFS) ====================
echo "=== Intégration de JackA1ltman/NonGKI_Kernel_Build_2nd ==="
git clone --depth=1 https://github.com -b mainline /tmp/jack_repo

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"

# Application du patch de structure kernel global pour le support SuSFS
patch -p1 < "$SUSFS_PATCH" 2>&1 || true

# Application des correctifs spécifiques pour lier le SuSFS de JackA1ltman au code non-GKI de backslashxx
cp /tmp/jack_repo/Patches/KernelSU/ksu_susfs.c drivers/kernelsu/ 2>/dev/null || echo "ℹ️ Fichier ksu_susfs.c géré par l'arborescence"

SUSFS_HEADER="include/linux/susfs.h"
if [ -f "$SUSFS_HEADER" ]; then
    sed -i 's/#define CONFIG_SUSFS_SHOW_KSU_VERSION.*/#define CONFIG_SUSFS_SHOW_KSU_VERSION 1/' "$SUSFS_HEADER" 2>/dev/null || true
fi

# ==================== 6. CONFIGURATION DEFCONFIG ====================
DEFCONFIG_FILE="arch/arm64/configs/vendor/sm8250_defconfig"
if [ ! -f "$DEFCONFIG_FILE" ]; then DEFCONFIG_FILE=$(find arch/arm64/configs/ -name "*defconfig" | head -1); fi
{
    echo "CONFIG_KSU=y"
    echo "CONFIG_SUSFS=y"
    echo "CONFIG_SUSFS_SHOW_KSU_VERSION=y"
} >> "$DEFCONFIG_FILE"

# ==================== 7. COMPILATION DU NOYAU ====================
echo "=== Lancement de la compilation du noyau avec Clang ==="
export ARCH=arm64
export SUBARCH=arm64
make O=out $(basename "$DEFCONFIG_FILE")
make -j$(nproc --all) O=out CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- LD=ld.lld

# ==================== 8. REMPAQUETAGE EN BOOT.IMG VIA MAGISKBOOT ====================
echo "=== Création du boot.img final ==="
cd "$GITHUB_WORKSPACE/workspace_boot"

cp tools/magiskboot .
./magiskboot unpack stock_boot.img

if [ -f "kernel_sources/out/arch/arm64/boot/Image.gz" ]; then
    cp kernel_sources/out/arch/arm64/boot/Image.gz kernel
else
    cp kernel_sources/out/arch/arm64/boot/Image kernel
fi

./magiskboot repack stock_boot.img new-boot.img

# Alignement avec votre étape "Upload results" (dossier output/)
mkdir -p "$GITHUB_WORKSPACE/output"
cp new-boot.img "$GITHUB_WORKSPACE/output/boot.img"

echo "🎉 LE BOOT.IMG COMPILÉ EST DISPONIBLE POUR VOTRE ARTEFACT !"
