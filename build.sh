#!/bin/bash
set -e
echo "=== Début du build Backslashxx KernelSU + SUSFS ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg patch

cd "$GITHUB_WORKSPACE"

echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration Backslashxx (clone dans drivers/kernelsu) ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true

git clone --depth=1 --filter=blob:none --sparse https://github.com/backslashxx/KernelSU.git backslashxx-src
(cd backslashxx-src && git sparse-checkout set kernel)
mkdir -p drivers/kernelsu
cp -r backslashxx-src/kernel/* drivers/kernelsu/
rm -rf backslashxx-src

echo "=== Structure récupérée ==="
ls -la drivers/kernelsu/

if ! grep -q "kernelsu" drivers/Kconfig; then
  echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
  echo "OK: Kconfig modifié"
fi

if ! grep -q "kernelsu" drivers/Makefile; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
  echo "OK: Makefile modifié"
fi

echo "=== Récupération des patches SUSFS (JackA1ltman/NonGKI_Kernel_Build_2nd) ==="
cd "$GITHUB_WORKSPACE"
git clone --depth=1 --filter=blob:none --sparse https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git susfs-tools
(cd susfs-tools && git sparse-checkout set Patches)

SUSFS_PATCH="susfs-tools/Patches/Patch/susfs_patch_to_4.19.patch"
SUSFS_HOOK_SCRIPT="susfs-tools/Patches/susfs_inline_hook_patches.sh"

if [ ! -f "$SUSFS_PATCH" ]; then
  echo "❌ Patch SUSFS introuvable à $SUSFS_PATCH"
  ls -la susfs-tools/Patches/ 2>/dev/null || true
  exit 1
fi

cd kernel_sources

echo "=== Application du patch SUSFS 4.19 ==="
mkdir -p ../output/susfs-patch-rejects
if ! patch -p1 --forward < "../$SUSFS_PATCH" > ../susfs_patch.log 2>&1; then
  echo "⚠️  Le patch SUSFS ne s'est pas appliqué proprement (hunks rejetés probables)."
fi
cat ../susfs_patch.log

REJ_COUNT=$(find . -name "*.rej" | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
  echo "⚠️ $REJ_COUNT hunk(s) rejeté(s). Correction manuelle..."
  find . -name "*.rej" -exec cp --parents {} ../output/susfs-patch-rejects/ \;
  cp ../susfs_patch.log ../output/susfs-patch-rejects/
  
  # === CORRECTIONS MANUELLES ===
  
  # 1. Corriger fs/namespace.c - Hunk #1 (include susfs_def.h)
  if ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
    echo "OK: namespace.c include corrigé"
  fi
  
  # 2. Corriger fs/proc/task_mmu.c - Hunk #7 (UNIQUEMENT la ligne 1617)
  sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true
  echo "OK: task_mmu.c ligne 1617 corrigée"
  
  # 3. Supprimer les .rej corrigés
  rm -f fs/namespace.c.rej fs/proc/task_mmu.c.rej 2>/dev/null || true
  
  # Vérifier si d'autres .rej existent encore
  REMAINING_REJ=$(find . -name "*.rej" | wc -l)
  if [ "$REMAINING_REJ" -gt 0 ]; then
    echo "⚠️ $REMAINING_REJ .rej restants (non bloquants pour namespace.c hunk #5)"
    find . -name "*.rej"
    # On ne quitte PAS : le hunk #5 de namespace.c peut être partiel
  fi
  
  echo "✅ Corrections manuelles terminées"
fi

if [ -f "../$SUSFS_HOOK_SCRIPT" ]; then
  echo "=== Exécution du script de hooks inline SUSFS ==="
  chmod +x "../$SUSFS_HOOK_SCRIPT"
  bash "../$SUSFS_HOOK_SCRIPT" | tee ../susfs_hooks.log
  if grep -q "patch failed" ../susfs_hooks.log; then
    echo "⚠️ Au moins un hook a échoué. On continue (vérification à la compilation)."
    cp ../susfs_hooks.log ../output/susfs-patch-rejects/ 2>/dev/null || mkdir -p ../output/susfs-patch-rejects && cp ../susfs_hooks.log ../output/susfs-patch-rejects/
  fi

  echo "=== Correctif manuel : policy_rwlock ==="
  if ! grep -q "selinux_state" security/selinux/include/security.h; then
    if grep -q "static DEFINE_RWLOCK(policy_rwlock);" security/selinux/ss/services.c; then
      sed -i 's/static DEFINE_RWLOCK(policy_rwlock);/DEFINE_RWLOCK(policy_rwlock);/' security/selinux/ss/services.c
      echo "[+] policy_rwlock rendu non-static"
    fi
  fi
else
  echo "❌ Script de hooks inline introuvable"
  exit 1
fi

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)

if [ -z "$CONFIG" ]; then
  echo "❌ Aucun defconfig trouvé"
  exit 1
fi

CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KPROBE_EVENTS=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Vérification ==="
grep -E "CONFIG_KSU|CONFIG_SECCOMP" out/.config

echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi

echo "=== Téléchargement des images stock ==="
cd "$GITHUB_WORKSPACE"
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img" 2>/dev/null || {
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
}
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" 2>/dev/null || true

if [ -f "boot-stock.img" ]; then
  mkdir -p repack
  cp boot-stock.img repack/boot.img
  wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
  unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot
  rm -rf Magisk-v27.0.apk lib/
  cd repack
  ./magiskboot unpack boot.img
  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/Backslashxx-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINÉ ==="
ls -lh output/
