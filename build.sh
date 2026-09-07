#!/bin/bash
set -e

echo "=== BUILD FINAL 12 : Reset Total + Config Tactile Forcée + KernelSU + SuSFS ==="
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

# === CIBLE : 30 AOÛT (Pour correspondre à votre ROM actuelle et éviter le bootloop) ===
NIGHTLY_DATE="2026-08-30"
NIGHTLY_DATE_COMPACT="20260830"
echo "Nightly ciblée : $NIGHTLY_DATE"
COMMIT_HASH=$(curl -s "https://api.github.com/repos/LineageOS/android_kernel_motorola_sm8250/commits?sha=lineage-23.2&until=${NIGHTLY_DATE}T23:59:59Z&per_page=1" | grep -oP '"sha": "\K[0-9a-f]+' | head -1)
echo "Commit pour nightly du $NIGHTLY_DATE : $COMMIT_HASH"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 kernel_sources
cd kernel_sources
if [ -n "$COMMIT_HASH" ]; then
    git fetch origin "$COMMIT_HASH"
    git checkout "$COMMIT_HASH"
fi

# ==================== 2. KERNELSU ====================
echo "=== Intégration KernelSU ==="
rm -rf drivers/kernelsu /tmp/KernelSU || true
KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"

git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU && git fetch --depth=1 origin "$KSU_COMMIT" && git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/kernel_sources"

ln -sf /tmp/KernelSU/kernel drivers/kernelsu
printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

# Fix versions
KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' drivers/kernelsu/Makefile | head -1)
[ -z "$KSU_VER" ] && KSU_VER="32601"
grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile || echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
[ -f "/tmp/KernelSU/uapi/ksu.h" ] && sed -i 's/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION 32601/' /tmp/KernelSU/uapi/ksu.h

# Hooks manuels
hook_insert() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4"
    if [ ! -f "$file" ] || ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then return 1; fi
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"
    return 0
}
hook_insert "fs/exec.c" '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' 'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);'
hook_insert "fs/open.c" 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' 'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);'
hook_insert "fs/stat.c" 'int vfs_statx\(int dfd, const char __user \*filename, int flags,' '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' 'ksu_handle_stat(&dfd, &filename, &flags);'

# ==================== 3. SUSFS ====================
echo "=== Intégration SuSFS ==="
git clone https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo
cd /tmp/jack_repo && git checkout "6eae2b587750336507096469fee74a2173e14bf6" && cd "$GITHUB_WORKSPACE/kernel_sources"

patch -p1 < "/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch" 2>&1 | tee /tmp/susfs.log || true

# Corrections auto des rejets connus
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    sed -i '/ret = walk_page_range/i\#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif' fs/proc/task_mmu.c
    sed -i '/up_read(&mm->mmap_sem);/i\#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif' fs/proc/task_mmu.c
    rm -f fs/proc/task_mmu.c.rej
fi

find . -name "*.rej" -type f | grep -q . && { echo "❌ Rejets de patch persistants"; exit 1; }
[ -f "fs/Makefile" ] && grep -q "susfs.o" fs/Makefile || echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile

# ==================== 4. CONFIGURATION (LA CLÉ DU SUCCÈS) ====================
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out

# 1. On part de la config de base officielle
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig
./scripts/kconfig/merge_config.sh -m -O out out/.config arch/arm64/configs/vendor/ext_config/moto-lito.config arch/arm64/configs/vendor/ext_config/kiev-default.config

# 2. ON FORCE LES OPTIONS DU TACTILE QUI FONCTIONNENT (D'après votre Kconfig)
echo "=== Forçage des options Tactile MMI ==="
./scripts/config --file out/.config --enable MMI_RELAY
./scripts/config --file out/.config --enable INPUT_TOUCHSCREEN_MMI
./scripts/config --file out/.config --enable INPUT_FOCALTECH_0FLASH_MMI
./scripts/config --file out/.config --enable INPUT_FOCALTECH_0FLASH_MMI_ENABLE_DOUBLE_TAP
./scripts/config --file out/.config --enable BOARD_USES_DOUBLE_TAP_CTRL

# 3. ON FORCE KERNELSU ET SUSFS
./scripts/config --file out/.config \
    --enable KSU --enable KSU_MANUAL_HOOK \
    --disable KPROBES --disable HAVE_KPROBES --disable KPROBE_EVENTS \
    --enable KSU_SUSFS --enable KSU_SUSFS_SUS_PATH --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT --enable KSU_SUSFS_SUS_MAP --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_ENABLE_LOG --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG --enable KSU_SUSFS_OPEN_REDIRECT

# 4. ON DÉSACTIVE LES CONFLITS CONNUS
./scripts/config --file out/.config --disable LTO_CLANG --disable CFI_CLANG
./scripts/config --file out/.config --disable DRM_MSM --disable DRM_MSM_DSI

# On applique les changements
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# Vérification que le tactile est bien activé
if ! grep -q "CONFIG_INPUT_TOUCHSCREEN_MMI=y" out/.config; then
    echo "❌ Échec : Le tactile n'est pas activé dans la config !"
    exit 1
fi
echo "✅ Configuration validée (Tactile + KSU + SuSFS activés)"

# ==================== 5. STUB DE SÉCURITÉ ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
cat >> fs/susfs.c << 'EOF'
#include <linux/notifier.h>
__attribute__((weak)) struct blocking_notifier_head dsi_freq_head = BLOCKING_NOTIFIER_INIT(dsi_freq_head);
EOF

# ==================== 6. COMPILATION ====================
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image modules dtbs 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -30
    exit 1
fi
echo "✅ Compilation du noyau réussie"

# ==================== 7. KSUD & REPACK ====================
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip && unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"

rm -rf ksud-src && git clone --depth=1 https://github.com/backslashxx/KernelSU.git ksud-src
cd ksud-src && git fetch --depth=1 origin "$KSU_COMMIT" && git checkout "$KSU_COMMIT" && cd userspace/ksud
mkdir -p .cargo && echo -e "[target.aarch64-linux-android]\nlinker = \"$AARCH64_CLANG_PATH\"" > .cargo/config.toml
cargo build --release --target aarch64-linux-android
cp target/aarch64-linux-android/release/ksud "$GITHUB_WORKSPACE/ksud"

# Repack avec le boot.img du 30 Août
cd "$GITHUB_WORKSPACE"
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/${NIGHTLY_DATE_COMPACT}/boot.img"
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/${NIGHTLY_DATE_COMPACT}/dtbo.img"

mkdir -p repack && cp boot-stock.img repack/boot.img && cd repack
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so && mv lib/x86_64/libmagiskboot.so magiskboot && chmod +x magiskboot
./magiskboot unpack boot.img
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
  "mkdir 0755 data/adb/ksud" \
  "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud" \
  "mkdir 0755 system/bin" \
  "add 06755 system/bin/su $GITHUB_WORKSPACE/ksud"

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img

mkdir -p "$GITHUB_WORKSPACE/output"
cp ../final_boot.img "$GITHUB_WORKSPACE/output/Backslashxx-SusFS-boot.img"
cp ../dtbo-stock.img "$GITHUB_WORKSPACE/output/dtbo.img"
cp "$GITHUB_WORKSPACE/kernel_sources/out/.config" "$GITHUB_WORKSPACE/output/final_config.txt"

echo "=== BUILD TERMINÉ AVEC SUCCÈS ==="
ls -lh "$GITHUB_WORKSPACE/output/"
