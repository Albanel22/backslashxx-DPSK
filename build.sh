#!/bin/bash
set -e

echo "=== BUILD BACKSLASHXX + KPROBES + SuSFS ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

# ==================== 2. CLONE KERNELSU BACKSLASHXX (COMMIT EXACT) ====================
echo "=== Intégration KernelSU Backslashxx ==="
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
else
    echo "❌ Symlink ÉCHOUÉ"
    exit 1
fi

printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

# ==================== 3. TÉLÉCHARGEMENT DU VRAI SUSFS ====================
echo "=== Téléchargement du VRAI SuSFS (JackA1ltman) ==="
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"

if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 non trouvé !"
    exit 1
fi

echo "✅ Patch SuSFS trouvé"

# ==================== 4. APPLICATION DU PATCH SUSFS ====================
echo "=== Application du patch SuSFS ==="
patch -p1 < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

find . -name "*.rej" -type f -delete 2>/dev/null || true
find . -name "*.orig" -type f -delete 2>/dev/null || true

# ==================== 4b. CORRECTIONS POST-PATCH ====================
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

# Correction namespace.c pour SuSFS
python3 - << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()
if '#include <linux/susfs_def.h>' not in content:
    content = content.replace(
        '#include <linux/sched/task.h>',
        '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif'
    )
with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# ==================== 5. KCONFIG SUSFS ====================
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

# ==================== 6. CONFIGURATION (AVEC KPROBES) ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

./scripts/config --file out/.config \
    --enable KSU \
    --enable KPROBES \
    --enable HAVE_KPROBES \
    --enable KPROBE_EVENTS \
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
    --enable THREAD_INFO_IN_TASK \
    --enable TOUCHSCREEN_FOCALTECH

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# ==================== 7. PATCH SIGNATURES ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 8. PATCH TACTILE FOCALTECH STUB ====================
echo "=== Application du patch tactile non bloquant ==="
printf "\n/* --- Dummy Panel Notifier pour FocalTech --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 9. COMPILATION ====================
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi

echo "✅ Compilation réussie"

# ==================== 10. REPACK (Lien fixe du 30 août) ====================
cd "$GITHUB_WORKSPACE"

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" || {
    echo "❌ Échec du téléchargement du boot stock"
    exit 1
}
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img" 2>/dev/null || true

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
  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
  ./magiskboot repack boot.img new-boot.img || { echo "❌ Échec du repack"; exit 1; }
  mv new-boot.img ../final_boot.img
  cd ..
fi

mkdir -p output
cp final_boot.img output/Backslashxx-Kprobes-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINÉ ==="
ls -lh output/
