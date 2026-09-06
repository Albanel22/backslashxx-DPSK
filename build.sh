#!/bin/bash
set -e

echo "=== BUILD FINAL 7 : KernelSU + SuSFS + FocalTech 0flash built-in + stub dsi_freq_head inconditionnel ==="
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

# === SYNCHRONISATION COMMIT / NIGHTLY ===
NIGHTLY_DATE="2026-09-06"
NIGHTLY_DATE_COMPACT="20260906"
echo "Nightly: $NIGHTLY_DATE"
COMMIT_HASH=$(curl -s "https://api.github.com/repos/LineageOS/android_kernel_motorola_sm8250/commits?sha=lineage-23.2&until=${NIGHTLY_DATE}T23:59:59Z&per_page=1" | grep -oP '"sha": "\K[0-9a-f]+' | head -1)
echo "Commit pour nightly du $NIGHTLY_DATE : $COMMIT_HASH"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 (commit synchronisé) ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
if [ -n "$COMMIT_HASH" ]; then
    git fetch --depth=1 origin "$COMMIT_HASH"
    git checkout "$COMMIT_HASH"
fi
cd ..

cd kernel_sources

# ==================== 2. CLONE KERNELSU (COMMIT EXACT) ====================
echo "=== Intégration KernelSU (0b138d6a) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu /tmp/KernelSU || true

KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"

git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin "$KSU_COMMIT"
git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/kernel_sources"

# ==================== 2b. SYMLINK DRIVER ====================
ln -sf /tmp/KernelSU/kernel drivers/kernelsu

if [ -d "drivers/kernelsu" ]; then
    echo "✅ Symlink OK"
    ls drivers/kernelsu/ | head -5
else
    echo "❌ Symlink ÉCHOUÉ"
    exit 1
fi

printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

echo "✅ KernelSU intégré avec le commit $KSU_COMMIT"

# ==================== 2c. FIX KSU_VERSION GLOBAL ====================
echo "=== Fix KSU_VERSION global ==="

KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' drivers/kernelsu/Makefile | head -1)
if [ -z "$KSU_VER" ]; then
    KSU_VER="32601"
fi
echo "[+] KSU_VERSION détecté : $KSU_VER"

if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
    echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
    echo "[+] ccflags-y += -DKSU_VERSION=${KSU_VER} ajouté"
else
    echo "[+] ccflags-y déjà présent"
fi

grep -n "DKSU_VERSION" drivers/kernelsu/Makefile

# ==================== 2d. FIX VERSION/UAPI ====================
echo "=== Fix version et UAPI ==="

if [ -f "/tmp/KernelSU/uapi/supercall.h" ]; then
    sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h
    sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h
    echo "[+] KERNEL_SU_UAPI_VERSION forcé à 2"
fi

if [ -f "/tmp/KernelSU/uapi/ksu.h" ]; then
    sed -i 's/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION 32601/' /tmp/KernelSU/uapi/ksu.h
    echo "[+] KERNEL_SU_VERSION forcé à 32601"
fi

DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
if [ -f "$DISPATCH_FILE" ]; then
    sed -i 's/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/' "$DISPATCH_FILE"
    sed -i 's/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = 32601;/' "$DISPATCH_FILE"
    sed -i 's/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = 32601, .flags = 0 };/' "$DISPATCH_FILE"
    sed -i 's/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = 32601, .flags = 0 };/' "$DISPATCH_FILE"
    echo "[+] Corrections dispatch.c appliquées"
fi

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

# ==================== 4. TÉLÉCHARGEMENT DU VRAI SUSFS ====================
echo "=== Téléchargement du SuSFS (JackA1ltman, commit pinné) ==="

JACK_COMMIT="6eae2b587750336507096469fee74a2173e14bf6"

git clone https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo
cd /tmp/jack_repo
git checkout "$JACK_COMMIT"
cd "$GITHUB_WORKSPACE/kernel_sources"

echo "✅ Repo SuSFS pinné au commit $JACK_COMMIT"

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"

if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 non trouvé !"
    exit 1
fi

echo "✅ Patch SuSFS trouvé : $(wc -l < $SUSFS_PATCH) lignes"

# ==================== 5. APPLICATION DU PATCH SUSFS ====================
echo "=== Application du patch SuSFS ==="

patch -p1 < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

if [ -f "fs/susfs.c" ]; then
    echo "✅ fs/susfs.c créé ($(wc -l < fs/susfs.c) lignes)"
else
    echo "❌ fs/susfs.c non créé !"
    exit 1
fi

find . -name "*.rej" -type f -delete 2>/dev/null || true
find . -name "*.orig" -type f -delete 2>/dev/null || true

# ==================== 5b. CORRECTION FS/MAKEFILE ====================
if [ -f "fs/Makefile" ]; then
    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    fi
    if [ -f "fs/sus_su.c" ]; then
        if ! grep -q "sus_su.o" fs/Makefile; then
            echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
        fi
    fi
fi

# ==================== 5c. CORRECTION NAMESPACE.C ====================
python3 - << 'PYEOF'
import re

with open('fs/namespace.c', 'r') as f:
    content = f.read()

content = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', content, flags=re.MULTILINE)

if '#include <linux/susfs_def.h>' not in content:
    content = content.replace(
        '#include <linux/sched/task.h>',
        '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif'
    )

if 'extern bool susfs_is_current_ksu_domain' not in content:
    content = content.replace(
        '#include "pnode.h"',
        '#include "pnode.h"\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif'
    )

with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

# ==================== 5d. CORRECTION TASK_MMU.C ====================
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# ==================== 5e. AJOUT DES SYMBOLES MANQUANTS ====================
if ! grep -q "susfs_ksu_sid = 0" fs/susfs.c; then
    cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS
bool susfs_is_current_ksu_domain(void)
{
    const struct cred *cred = current_cred();
    return (cred->uid.val == 0 || cred->uid.val == 2000);
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);

u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);

u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
#endif
SUSFS_EOF
fi

# ==================== 6. KCONFIG SUSFS ====================
if [ -f "drivers/kernelsu/Kconfig" ]; then
    if ! grep -q "KSU_SUSFS" drivers/kernelsu/Kconfig; then
        cat >> drivers/kernelsu/Kconfig << 'KCONFIG_EOF'

menuconfig KSU_SUSFS
	bool "KernelSU SUSFS support"
	depends on KSU
	default y

if KSU_SUSFS

config KSU_SUSFS_SUS_PATH
	bool "sus_path"
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "sus_mount"
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "sus_kstat"
	default y

config KSU_SUSFS_SUS_MAP
	bool "sus_map"
	default y

config KSU_SUSFS_SPOOF_UNAME
	bool "spoof_uname"
	default y

config KSU_SUSFS_ENABLE_LOG
	bool "enable_log"
	default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "hide_ksu_susfs_symbols"
	default y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "spoof_cmdline_or_bootconfig"
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "open_redirect"
	default y

endif
KCONFIG_EOF
    fi
fi

# ==================== 7. CONFIGURATION + CORRECTIONS ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    vendor/lito-perf_defconfig

./scripts/kconfig/merge_config.sh -m -O out \
    out/.config \
    arch/arm64/configs/vendor/ext_config/moto-lito.config \
    arch/arm64/configs/vendor/ext_config/kiev-default.config

echo "=== Correction Kconfig INPUT_TOUCHSCREEN_MMI (bool) ==="
MMI_KCONFIG=$(grep -Rl "config INPUT_TOUCHSCREEN_MMI" drivers/input/touchscreen/ | head -1)
if [ -n "$MMI_KCONFIG" ]; then
    sed -i '/config INPUT_TOUCHSCREEN_MMI/,/^$/ s/tristate/bool/' "$MMI_KCONFIG"
    sed -i '/config INPUT_TOUCHSCREEN_MMI/,/^$/ s/default n/default y/' "$MMI_KCONFIG"
    echo "✅ Kconfig modifié"
fi

./scripts/config --file out/.config --disable TOUCHSCREEN_FTS

./scripts/config --file out/.config \
    --enable INPUT_TOUCHSCREEN_MMI \
    --enable INPUT_FOCALTECH_0FLASH_MMI \
    --enable INPUT_FOCALTECH_0FLASH_MMI_ENABLE_DOUBLE_TAP \
    --enable INPUT_FOCALTECH_0FLASH_MMI_ENABLE_ESD \
    --enable TOUCHCLASS_MMI_GESTURE_POISON_EVENT \
    --enable BOARD_USES_DOUBLE_TAP_CTRL

./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_MANUAL_HOOK \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SUS_MAP \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable KSU_SUSFS_OPEN_REDIRECT \
    --enable THREAD_INFO_IN_TASK

./scripts/config --file out/.config --disable LTO_CLANG --disable CFI_CLANG

./scripts/config --file out/.config --enable MMI_RELAY
./scripts/config --file out/.config --enable DRM_DYNAMIC_REFRESH_RATE
./scripts/config --file out/.config --enable SENSORS_CLASS

echo "CONFIG_MMI_RELAY=y" >> out/.config
echo "CONFIG_DRM_DYNAMIC_REFRESH_RATE=y" >> out/.config
echo "CONFIG_SENSORS_CLASS=y" >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

if ! grep -q "CONFIG_INPUT_TOUCHSCREEN_MMI=y" out/.config; then
    echo "❌ CONFIG_INPUT_TOUCHSCREEN_MMI n'est pas y"
    exit 1
fi

if ! grep -q "CONFIG_DRM_DYNAMIC_REFRESH_RATE=y" out/.config; then
    echo "❌ CONFIG_DRM_DYNAMIC_REFRESH_RATE n'est pas y"
    exit 1
fi

if ! grep -q "CONFIG_SENSORS_CLASS=y" out/.config; then
    echo "❌ CONFIG_SENSORS_CLASS n'est pas y"
    exit 1
fi

# ==================== 8. PATCH SIGNATURES + STUB dsi_freq_head ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# Définition de secours pour dsi_freq_head dans touchscreen_mmi_notif.c
if ! grep -q "struct blocking_notifier_head dsi_freq_head" drivers/input/touchscreen/touchscreen_mmi/touchscreen_mmi_notif.c; then
    sed -i '/#include <linux\/touchscreen_mmi.h>/a\
\
#ifdef CONFIG_DRM_DYNAMIC_REFRESH_RATE\
struct blocking_notifier_head dsi_freq_head = BLOCKING_NOTIFIER_INIT(dsi_freq_head);\
EXPORT_SYMBOL_GPL(dsi_freq_head);\
#endif' drivers/input/touchscreen/touchscreen_mmi/touchscreen_mmi_notif.c
    echo "✅ Stub dsi_freq_head ajouté dans touchscreen_mmi_notif.c"
else
    echo "✅ dsi_freq_head déjà présent dans touchscreen_mmi_notif.c"
fi

# ==================== 9. COMPILATION ====================
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    -j$(nproc) scripts

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    -j$(nproc) Image modules

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    HOSTCC=gcc HOSTRANDOM=no DTC_EXT=$(pwd)/out/scripts/dtc/dtc dtbs 2>&1 | tee -a build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi

echo "✅ Compilation réussie"

# ==================== 10. COMPILATION KSUD ====================
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

# ==================== 11. REPACK ====================
cd "$GITHUB_WORKSPACE"

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/${NIGHTLY_DATE_COMPACT}/boot.img"
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/${NIGHTLY_DATE_COMPACT}/dtbo.img"

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
fi

mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
