#!/bin/bash
set -e

echo "=== BUILD ULTIME : Optimisé Backslashxx + SusFS + Correctifs Sept 2026 ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd "$GITHUB_WORKSPACE"

# === SYNCHRONISATION COMMIT / NIGHTLY ===
NIGHTLY_DATE="2026-09-06"
NIGHTLY_DATE_COMPACT="20260906"
echo "Nightly: $NIGHTLY_DATE"
COMMIT_HASH=$(curl -s "https://api.github.com/repos/LineageOS/android_kernel_motorola_sm8250/commits?sha=lineage-23.2&until=${NIGHTLY_DATE}T23:59:59Z&per_page=1" | grep -oP '"sha": "\K[0-9a-f]+' | head -1)
echo "Commit pour nightly du $NIGHTLY_DATE : $COMMIT_HASH"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources

if [ -n "$KERNEL_COMMIT" ]; then
    echo "=== Utilisation du commit figé : $KERNEL_COMMIT ==="
    git checkout "$KERNEL_COMMIT"
else
    echo "=== Avertissement : Aucun commit figé spécifié, utilisation de la branche par défaut ==="
    git checkout lineage-23.2
fi

echo "=== Intégration Backslashxx KernelSU (Commit spécifique) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu /tmp/KernelSU || true

KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"
git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin "$KSU_COMMIT"
git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/kernel_sources"

ln -sf /tmp/KernelSU/kernel drivers/kernelsu
printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

echo "=== Hooks manuels sucompat (fs/exec.c, fs/open.c, fs/stat.c) ==="
mkdir -p ../output/manual-hooks-diag

hook_insert() {
  local file="$1" sig_re="$2" extern_block="$3" call_line="$4"
  if [ ! -f "$file" ]; then echo "❌ $file introuvable."; return 1; fi
  if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then echo "❌ Signature attendue introuvable dans $file."; return 1; fi
  perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"
  echo "[+] Hook inséré dans $file"
  return 0
}

HOOKS_FAILED=0
hook_insert "fs/exec.c" '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' 'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' || HOOKS_FAILED=1

if grep -Pzo 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
  hook_insert "fs/open.c" 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' 'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' || HOOKS_FAILED=1
elif grep -Pzo 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
  hook_insert "fs/open.c" 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' 'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' || HOOKS_FAILED=1
else
  HOOKS_FAILED=1
fi

if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,' fs/stat.c > /dev/null 2>&1; then
  hook_insert "fs/stat.c" 'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' 'ksu_handle_stat(&dfd, &filename, &flags);' || HOOKS_FAILED=1
elif grep -Pzo 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' fs/stat.c > /dev/null 2>&1; then
  hook_insert "fs/stat.c" 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' 'ksu_handle_stat(&dfd, &filename, &flag);' || HOOKS_FAILED=1
else
  HOOKS_FAILED=1
fi

if [ "$HOOKS_FAILED" -eq 1 ]; then
  echo "❌ Au moins un hook sucompat n'a pas pu être inséré."
  exit 1
fi
echo "✅ Les 3 hooks sucompat sont en place."

echo "=== Téléchargement du repo JackA1ltman ==="
rm -rf /tmp/jack_repo
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

echo "=== Application du patch SusFS 4.19 ==="
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)
if [ -n "$PATCH_419" ]; then
  echo "Application du patch: $PATCH_419"
  patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
fi

echo "=== Corrections post-patch & UAPI ==="
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    python3 - << 'PYEOF'
import re, os
file_path = 'fs/proc/task_mmu.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f: content = f.read()
    if 'SUSFS_IS_INODE_SUS_MAP' not in content:
        content = content.replace("ret = walk_page_range(start_vaddr, end, &pagemap_walk);", 
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);")
        content = re.sub(r'(ret = walk_page_range.*?)(up_read\(&mm->mmap_sem\);|mmap_read_unlock\(mm\);)', 
            r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif\n\t\2', content, flags=re.DOTALL)
        with open(file_path, 'w') as f: f.write(content)
PYEOF
    rm -f fs/proc/task_mmu.c.rej
fi

if ! grep -q "susfs_def.h" fs/namespace.c; then
  sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

mkdir -p include/uapi/linux
if [ ! -f "include/uapi/linux/mount.h" ] && [ -f "include/linux/mount.h" ]; then
    touch include/uapi/linux/mount.h
fi

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG=$(find arch/arm64/configs/ \( -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" \) | head -1)
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" "$CONFIG_NAME"

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
  echo "CONFIG_INPUT_TOUCHSCREEN_MMI=y"
  echo "CONFIG_INPUT_FOCALTECH_0FLASH_MMI=y"
  echo "CONFIG_MMI_RELAY=y"
  echo "CONFIG_DRM=y"
  echo "CONFIG_DRM_PANEL=y"
  echo "CONFIG_DRM_PANEL_NOTIFICATIONS=y"
  echo "CONFIG_DRM_PANEL_EVENT_NOTIFICATIONS=y"
  echo "CONFIG_TOUCH_PANEL_NOTIFICATIONS=y"
  echo "CONFIG_SENSORS_CORE=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" olddefconfig

if [ -f "out/.config" ]; then
    sed -i 's/# CONFIG_INPUT_TOUCHSCREEN_MMI is not set/CONFIG_INPUT_TOUCHSCREEN_MMI=y/g' out/.config
    sed -i 's/CONFIG_INPUT_TOUCHSCREEN_MMI=m/CONFIG_INPUT_TOUCHSCREEN_MMI=y/g' out/.config
    sed -i 's/# CONFIG_INPUT_FOCALTECH_0FLASH_MMI is not set/CONFIG_INPUT_FOCALTECH_0FLASH_MMI=y/g' out/.config
    sed -i 's/CONFIG_INPUT_FOCALTECH_0FLASH_MMI=m/CONFIG_INPUT_FOCALTECH_0FLASH_MMI=y/g' out/.config
    sed -i 's/# CONFIG_MMI_RELAY is not set/CONFIG_MMI_RELAY=y/g' out/.config
    sed -i 's/CONFIG_MMI_RELAY=m/CONFIG_MMI_RELAY=y/g' out/.config
fi

echo "=== Patch signatures + Patch Tactile Motorola ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

TARGET_MSM_DRV=""
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    TARGET_MSM_DRV="techpack/display/msm/msm_drv.c"
elif [ -f "drivers/gpu/drm/msm/msm_drv.c" ]; then
    TARGET_MSM_DRV="drivers/gpu/drm/msm/msm_drv.c"
fi

if [ -n "$TARGET_MSM_DRV" ]; then
    printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> "$TARGET_MSM_DRV"
    echo "✅ Patch tactile appliqué sur $TARGET_MSM_DRV"
fi

if [ -f "drivers/gpu/drm/msm/msm_drv.c" ]; then
    sed -i 's/strnstr(dev_name(dev), "mdp")/strnstr(dev_name(dev), "mdp", strlen(dev_name(dev)))/g' drivers/gpu/drm/msm/msm_drv.c
fi

cat >> fs/susfs.c << 'DSI_STUB_EOF'
#include <linux/notifier.h>
__attribute__((weak)) struct blocking_notifier_head dsi_freq_head;
DSI_STUB_EOF

echo "=== Création du header manquant panel_event_notifier.h ==="
mkdir -p include/linux/soc/qcom
cat << 'EOF' > include/linux/soc/qcom/panel_event_notifier.h
#ifndef __PANEL_EVENT_NOTIFIER_H
#define __PANEL_EVENT_NOTIFIER_H
#include <linux/notifier.h>
enum panel_event_notifier_tag {
    PANEL_EVENT_NOTIFIER_BLANK = 0,
};
struct panel_event_notification {
    int notif_type;
    int *data;
};
static inline void *panel_event_notifier_register(int n, struct notifier_block *nb) { return (void *)1; }
static inline int panel_event_notifier_unregister(void *p, struct notifier_block *nb) { return 0; }
#endif
EOF

echo "=== Compilation finale (Noyau + Modules) ==="
make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  -j"$(nproc)" Image modules 2>&1 | tee build.log

echo "=== Compilation des Device Trees (Mode sécurisé -j1) ==="
make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  -j1 dtbs 2>&1 | tee -a build.log || echo "⚠️ Avertissement : dtbs partiel."

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation du noyau (Image) réussie"
else
  echo "❌ BUILD FAILED : L'image du noyau n'a pas été générée."
  grep -i "error:" build.log | head -20
  exit 1
fi

echo "=== Compilation de ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
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

KSUD_BINARY="$GITHUB_WORKSPACE/ksud-src/target/aarch64-linux-android/release/ksud"
if [ ! -f "$KSUD_BINARY" ]; then
  echo "❌ ksud introuvable"
  exit 1
fi

cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"

echo "=== Téléchargement des images stock ==="
cd "$GITHUB_WORKSPACE"
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/${NIGHTLY_DATE_COMPACT}/boot.img" 2>/dev/null || true
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/${NIGHTLY_DATE_COMPACT}/dtbo.img" 2>/dev/null || true

if [ -f "boot-stock.img" ]; then
  mkdir -p repack
  cp boot-stock.img repack/boot.img

  wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
  unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot
  rm -rf Magisk-v27.0.apk lib/
  
  cd repack
  set +e
  ./magiskboot unpack boot.img
  set -e

  if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec réel du unpack"
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
fi

echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ AVEC SUCCÈS ==="
ls -lh output/
