#!/bin/bash
set -e
echo "=== Début du build Backslashxx + SusFS (mainline) ==="
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

echo "=== Nettoyage clean_hook.sh (branche mainline) ==="
curl -LSs "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Bin/clean_hook.sh" -o clean_hook.sh
chmod +x clean_hook.sh
bash clean_hook.sh 2>&1 | tee ../clean_hook.log
echo "OK: clean_hook.sh exécuté"

echo "=== Intégration Backslashxx (clone sparse) ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true

git clone --depth=1 --filter=blob:none --sparse https://github.com/backslashxx/KernelSU.git backslashxx-src
(cd backslashxx-src && git sparse-checkout set kernel)
mkdir -p drivers/kernelsu
cp -r backslashxx-src/kernel/* drivers/kernelsu/
rm -rf backslashxx-src

if ! grep -q "kernelsu" drivers/Kconfig; then
  echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
fi

if ! grep -q "kernelsu" drivers/Makefile; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

echo "=== Téléchargement des scripts JackA1ltman (mainline) ==="
cd "$GITHUB_WORKSPACE"
git clone --depth=1 --filter=blob:none --sparse --branch mainline https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git susfs-tools
(cd susfs-tools && git sparse-checkout set Patches Bin)

SUSFS_PATCH="susfs-tools/Patches/Patch/susfs_patch_to_4.19.patch"
SYSCALL_HOOK_SCRIPT="susfs-tools/Patches/syscall_hook_patches.sh"

cd kernel_sources

echo "=== Exécution du script syscall_hook_patches.sh ==="
if [ -f "../$SYSCALL_HOOK_SCRIPT" ]; then
  chmod +x "../$SYSCALL_HOOK_SCRIPT"
  bash "../$SYSCALL_HOOK_SCRIPT" | tee ../syscall_hooks.log
  echo "Script exécuté"
else
  echo "❌ syscall_hook_patches.sh introuvable"
  find ../susfs-tools -name "*.sh" | head -10
  exit 1
fi

echo "=== Application du patch SUSFS 4.19 ==="
if [ -f "../$SUSFS_PATCH" ]; then
  if ! patch -p1 --forward < "../$SUSFS_PATCH" > ../susfs_patch.log 2>&1; then
    echo "⚠️ Hunks rejetés (pris en charge par les corrections manuelles)"
  fi
  cat ../susfs_patch.log
else
  echo "❌ Patch SUSFS introuvable"
  find ../susfs-tools -name "*4.19*" | head -10
  exit 1
fi

# Corrections manuelles initiales des includes dans namespace.c
if ! grep -q "susfs_def.h" fs/namespace.c; then
  sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
  echo "OK: namespace.c corrigé"
fi

sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true
echo "OK: task_mmu.c corrigé"

# Restauration des fichiers avec symboles absents de Backslashxx
git checkout lib/xarray.c fs/read_write.c security/selinux/hooks.c 2>/dev/null || true
echo "OK: fichiers restaurés"

rm -f fs/namespace.c.rej fs/proc/task_mmu.c.rej 2>/dev/null || true

# === CORRECTION ROBUSTE HUNK #5 : vfs_kern_mount ===
python3 << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()

# Pattern large pour capturer alloc_vfsmnt(name) indépendamment des retours à la ligne
old_pattern = r'(mnt\s*=\s*alloc_vfsmnt\s*\(\s*name\s*\)\s*;)'
new_code = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
			goto bypass_orig_flow;
		}
	}
#endif
	\g<1>
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif'''

content, count = re.subn(old_pattern, new_code, content, count=1)
if count > 0:
    print("OK: vfs_kern_mount corrigé (Hunk #5)")
else:
    print("ERREUR: pattern vfs_kern_mount non trouvé")

with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

# === AJOUTER susfs_alloc_non_unshare_ksu_vfsmnt ===
python3 << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()

if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
    susfs_func = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static struct mount *susfs_alloc_non_unshare_ksu_vfsmnt(const char *name)
{
	struct mount *mnt = kmem_cache_zalloc(mnt_cache, GFP_KERNEL);
	int res;

	if (mnt) {
		res = ida_alloc_min(&mnt_id_ida, DEFAULT_KSU_MNT_ID, GFP_KERNEL);
		if (res < 0)
			goto out_free_cache;

		mnt->mnt_id = res;

		if (name) {
			mnt->mnt_devname = kstrdup_const(name, GFP_KERNEL_ACCOUNT);
			if (!mnt->mnt_devname)
				goto out_free_id;
		}

#ifdef CONFIG_SMP
		mnt->mnt_pcp = alloc_percpu(struct mnt_pcp);
		if (!mnt->mnt_pcp)
			goto out_free_devname;
		this_cpu_add(mnt->mnt_pcp->mnt_count, 1);
#else
		mnt->mnt_count = 1;
		mnt->mnt_writers = 0;
#endif

		INIT_HLIST_NODE(&mnt->mnt_hash);
		INIT_LIST_HEAD(&mnt->mnt_child);
		INIT_LIST_HEAD(&mnt->mnt_mounts);
		INIT_LIST_HEAD(&mnt->mnt_list);
		INIT_LIST_HEAD(&mnt->mnt_expire);
		INIT_LIST_HEAD(&mnt->mnt_share);
		INIT_LIST_HEAD(&mnt->mnt_slave_list);
		INIT_LIST_HEAD(&mnt->mnt_slave);
		INIT_HLIST_NODE(&mnt->mnt_mp_list);
		INIT_LIST_HEAD(&mnt->mnt_umounting);
		init_fs_pin(&mnt->mnt_umount, drop_mountpoint);
	}
	return mnt;

#ifdef CONFIG_SMP
out_free_devname:
	kfree_const(mnt->mnt_devname);
#endif
out_free_id:
	mnt_free_id(mnt);
out_free_cache:
	kmem_cache_free(mnt_cache, mnt);
	return NULL;
}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
    pattern = r'(static struct mount \*alloc_vfsmnt\(const char \*name\))'
    content = re.sub(pattern, susfs_func + '\n' + r'\1', content, count=1)
    
    with open('fs/namespace.c', 'w') as f:
        f.write(content)
    print("OK: susfs_alloc_non_unshare_ksu_vfsmnt ajoutée")
else:
    print("OK: susfs_alloc_non_unshare_ksu_vfsmnt déjà présente")
PYEOF

# === CORRECTION HUNK #7 : pagemap_read SUS_MAP ===
python3 << 'PYEOF'
import re
with open('fs/proc/task_mmu.c', 'r') as f:
    content = f.read()

if 'struct vm_area_struct *vma;' not in content:
    old_decl = '''	int ret = 0, copied = 0;'''
    new_decl = '''	int ret = 0, copied = 0;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	struct vm_area_struct *vma;
#endif'''
    if old_decl in content:
        content = content.replace(old_decl, new_decl, 1)
        print("OK: déclaration vma ajoutée")

old_code = '''		ret = walk_page_range(start_vaddr, end, &pagemap_walk);'''
new_code = '''#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP'''

if old_code in content:
    content = content.replace(old_code, new_code, 1)
    print("OK: pagemap_read corrigé (Hunk #7)")
else:
    print("ERREUR: pattern pagemap_read non trouvé")

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)
PYEOF

# Restauration propre de msm_drv.c avant d'appliquer le patch tactile
git checkout techpack/display/msm/msm_drv.c 2>/dev/null || true
echo "OK: msm_drv.c restauré pour le tactile"

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KALLSYMS=y"
  echo "CONFIG_KALLSYMS_ALL=y"
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

echo "=== Contournement du contrôle de version strict des modules + patch tactile ==="
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
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINÉ ==="
ls -lh output/
