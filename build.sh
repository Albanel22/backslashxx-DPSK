#!/bin/bash
set -e
echo "=== Build KernelSU master backslashxx (non-GKI) + hooks + SuSFS ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev \
  gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd $GITHUB_WORKSPACE

echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration Backslashxx KernelSU (master HEAD) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu /tmp/KernelSU || true

git clone --depth=1 -b master https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd $GITHUB_WORKSPACE/kernel_sources

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
echo "✅ Makefile et Kconfig modifiés"

echo "=== Hooks manuels sucompat ==="
sed -i '1i#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"' fs/exec.c
sed -i '1i#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"' fs/open.c
sed -i '1i#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"' fs/stat.c

# exec.c
if ! grep -q "ksu_handle_execveat_sucompat" fs/exec.c; then
  sed -i '/static int do_execveat_common/i\
#ifdef CONFIG_KSU\
extern bool ksu_execveat_hook __read_mostly;\
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\
void *envp, int *flags);\
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\
void *argv, void *envp, int *flags);\
#endif' fs/exec.c

  sed -i '/static int do_execveat_common.*{/a\
#ifdef CONFIG_KSU\
if (unlikely(ksu_execveat_hook))\
ksu_handle_execveat(\&fd, \&filename, \&argv, \&envp, \&flags);\
else\
ksu_handle_execveat_sucompat(\&fd, \&filename, \&argv, \&envp, \&flags);\
#endif' fs/exec.c
fi

# open.c
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  sed -i '1i\
#ifdef CONFIG_KSU\
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\
#endif' fs/open.c
  if grep -q "long do_faccessat" fs/open.c; then
    sed -i '/long do_faccessat.*{/a\
#ifdef CONFIG_KSU\
ksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\
#endif' fs/open.c
  else
    sed -i '/SYSCALL_DEFINE3(faccessat.*{/a\
#ifdef CONFIG_KSU\
ksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\
#endif' fs/open.c
  fi
fi

# stat.c
if ! grep -q "ksu_handle_stat" fs/stat.c; then
  sed -i '1i\
#ifdef CONFIG_KSU\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\
#endif' fs/stat.c
  if grep -q "int vfs_statx" fs/stat.c; then
    sed -i '/int vfs_statx.*{/a\
#ifdef CONFIG_KSU\
ksu_handle_stat(\&dfd, \&filename, \&flags);\
#endif' fs/stat.c
  else
    sed -i '/int vfs_fstatat.*{/a\
#ifdef CONFIG_KSU\
ksu_handle_stat(\&dfd, \&filename, \&flag);\
#endif' fs/stat.c
  fi
fi

echo "✅ Hooks manuels en place"

echo "=== Application du patch SusFS 4.19 ==="
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo 2>/dev/null || true
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)
if [ -n "$PATCH_419" ]; then
  patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
fi

# Corrections SusFS
python3 - << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()
if 'susfs_def.h' not in content:
    content = content.replace('#include <linux/sched/task.h>',
'''#include <linux/sched/task.h>
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25)
#endif''')
with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

python3 - << 'PYEOF'
import re
with open('fs/proc/task_mmu.c', 'r') as f:
    content = f.read()
if 'SUSFS_IS_INODE_SUS_MAP' not in content:
    old = '''		ret = down_read_killable(&mm->mmap_sem);
		if (ret)
			goto out_free;
		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
		up_read(&mm->mmap_sem);'''
    new = '''		ret = down_read_killable(&mm->mmap_sem);
		if (ret)
			goto out_free;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif
		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif
		up_read(&mm->mmap_sem);'''
    content = content.replace(old, new)
with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)
PYEOF

sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true

if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  python3 - << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()
if 'ksu_handle_setresuid' not in content:
    content = re.sub(r'(long __sys_setresuid)',
'''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
long __sys_setresuid''', content, count=1)
    content = content.replace('''	bool ruid_new, euid_new, suid_new;''',
'''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif''')
with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
fi

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

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

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

./scripts/config --file out/.config --disable SECCOMP_FILTER
echo "# CONFIG_SECCOMP_FILTER is not set" >> out/.config
grep "CONFIG_SECCOMP" out/.config

echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "=== Compilation noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -30
  exit 1
fi
echo "✅ Compilation réussie"

echo "=== Compilation ksud ==="
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

cd "$GITHUB_WORKSPACE"
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

git clone --depth=1 -b master https://github.com/backslashxx/KernelSU.git ksud-src
cd ksud-src/userspace/ksud

mkdir -p .cargo
cat > .cargo/config.toml << EOF
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
if [ -f "$KSUD_BINARY" ]; then
  cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
  chmod 755 "$GITHUB_WORKSPACE/ksud"
  echo "OK: ksud compilé"
else
  echo "⚠️ ksud introuvable"
fi

cd "$GITHUB_WORKSPACE"

echo "=== Repack ==="
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
  cp $GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image kernel
  if [ -f "$GITHUB_WORKSPACE/ksud" ]; then
    mkdir -p ramdisk/data/adb
    cp "$GITHUB_WORKSPACE/ksud" ramdisk/data/adb/ksud
    chmod 755 ramdisk/data/adb/ksud
  fi
  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp $GITHUB_WORKSPACE/ksud output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
