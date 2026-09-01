#!/bin/bash
set -e

echo "=== BUILD KernelSU backslashxx + SuSFS (basé sur ReSukiSU fonctionnel) ==="
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
echo "=== Clonage du kernel Motorola sm8250 ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

# ==================== 2. CLONE KERNELSU BACKSLASHXX (COMMIT EXACT) ====================
echo "=== Intégration KernelSU backslashxx (0b138d6a) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu /tmp/KernelSU || true

KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"

git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin "$KSU_COMMIT"
git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/kernel_sources"

# Copie du driver (pas de symlink)
rm -rf drivers/kernelsu
cp -r /tmp/KernelSU/kernel drivers/kernelsu

if [ -d "drivers/kernelsu" ]; then
    echo "✅ Driver KernelSU copié"
else
    echo "❌ Échec copie"
    exit 1
fi

printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

# ==================== 2b. FIX VERSION/UAPI ====================
echo "=== Fix KSU_VERSION et UAPI ==="
KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' drivers/kernelsu/Makefile | head -1)
[ -z "$KSU_VER" ] && KSU_VER="32601"
echo "KSU_VERSION=$KSU_VER"

if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
    echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
fi

if [ -f "drivers/kernelsu/uapi/supercall.h" ]; then
    sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' drivers/kernelsu/uapi/supercall.h
    sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' drivers/kernelsu/uapi/supercall.h
fi

if [ -f "drivers/kernelsu/uapi/ksu.h" ]; then
    sed -i 's/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION 32601/' drivers/kernelsu/uapi/ksu.h
fi

DISPATCH_FILE="drivers/kernelsu/kernel/supercall/dispatch.c"
if [ -f "$DISPATCH_FILE" ]; then
    sed -i 's/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/' "$DISPATCH_FILE"
    sed -i 's/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = 32601;/' "$DISPATCH_FILE"
    sed -i 's/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = 32601, .flags = 0 };/' "$DISPATCH_FILE"
    sed -i 's/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = 32601, .flags = 0 };/' "$DISPATCH_FILE"
fi

# ==================== 3. HOOKS MANUELS (DOUBLE GARDE) ====================
echo "=== Hooks ReSukiSU (double garde SUSFS || MANUAL_HOOK) ==="

# execveat
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  python3 - << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f:
    content = f.read()
extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
'''
pattern = r'(static int do_execveat_common\()'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
old_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
new_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
if old_code in content:
    content = content.replace(old_code, new_code, 1)
else:
    pattern = r'(int do_execve\(struct filename \*filename,.*?struct user_arg_ptr envp = \{ \.ptr\.native = __envp \};\n)'
    replacement = r'\1#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('fs/exec.c', 'w') as f:
    f.write(content)
print("Hook execveat OK")
PYEOF
fi

# faccessat
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  python3 - << 'PYEOF'
import re
with open('fs/open.c', 'r') as f:
    content = f.read()
extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''
pattern = r'(SYSCALL_DEFINE3\(faccessat)'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
old_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
new_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
if old_code in content:
    content = content.replace(old_code, new_code, 1)
else:
    pattern = r'(SYSCALL_DEFINE3\(faccessat.*?\n\{)'
    replacement = r'\1\n#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif'
    content = re.sub(pattern, replacement, content, count=1)
with open('fs/open.c', 'w') as f:
    f.write(content)
print("Hook faccessat OK")
PYEOF
fi

# stat (newfstatat, newfstat, fstat64)
if ! grep -q "ksu_handle_stat" fs/stat.c; then
  python3 - << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f:
    content = f.read()
extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

if 'ksu_handle_stat(&dfd' not in content:
    old = '''	struct kstat stat;
	int error;

	return vfs_fstatat(dfd, filename, &stat, flag);'''
    new = '''	struct kstat stat;
	int error;

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
    if old in content:
        content = content.replace(old, new, 1)

if 'ksu_handle_newfstat_ret' not in content:
    old = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;'''
    new = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;'''
    if old in content:
        content = content.replace(old, new, 1)

if 'ksu_handle_fstat64_ret' not in content:
    old = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;'''
    new = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;'''
    if old in content:
        content = content.replace(old, new, 1)

with open('fs/stat.c', 'w') as f:
    f.write(content)
print("Hooks stat OK")
PYEOF
fi

# sys_reboot
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  python3 - << 'PYEOF'
import re
with open('kernel/reboot.c', 'r') as f:
    content = f.read()
extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
pattern = r'(SYSCALL_DEFINE4\(reboot)'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
old = '''	char buffer[256];
	int ret = 0;'''
new = '''	char buffer[256];
	int ret = 0;

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
if old in content:
    content = content.replace(old, new, 1)
with open('kernel/reboot.c', 'w') as f:
    f.write(content)
print("Hook sys_reboot OK")
PYEOF
fi

# input_handle_event (CRUCIAL pour le tactile)
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  python3 - << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f:
    content = f.read()
extern_decl = '''
#ifdef CONFIG_KSU
extern struct static_key_true ksu_is_input_hook_enabled;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
pattern = r'(static void input_handle_event\(struct input_dev \*dev,)'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
old = '''	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
new = '''#ifdef CONFIG_KSU
	if (static_branch_unlikely(&ksu_is_input_hook_enabled))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif
	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
if old in content:
    content = content.replace(old, new, 1)
else:
    old2 = '''	input_get_disposition(dev, type, code, &value);'''
    new2 = '''#ifdef CONFIG_KSU
	if (static_branch_unlikely(&ksu_is_input_hook_enabled))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif
	input_get_disposition(dev, type, code, &value);'''
    if old2 in content:
        content = content.replace(old2, new2, 1)
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
print("Hook input_handle_event OK")
PYEOF
fi

# setresuid
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  python3 - << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()
extern_decl = '''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
pattern = r'(long __sys_setresuid)'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
old = '''	bool ruid_new, euid_new, suid_new;'''
new = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
if old in content:
    content = content.replace(old, new, 1)
with open('kernel/sys.c', 'w') as f:
    f.write(content)
print("Hook setresuid OK")
PYEOF
fi

# sys_read
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  python3 - << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f:
    content = f.read()
extern_decl = '''
#ifdef CONFIG_KSU
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd);
#endif
'''
pattern = r'(SYSCALL_DEFINE3\(read)'
content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
old = '''	return ksys_read(fd, buf, count);'''
new = '''#ifdef CONFIG_KSU
	if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
		ksu_handle_sys_read(fd);
#endif
	return ksys_read(fd, buf, count);'''
if old in content:
    content = content.replace(old, new, 1)
with open('fs/read_write.c', 'w') as f:
    f.write(content)
print("Hook sys_read OK")
PYEOF
fi

echo "✅ Tous les hooks sont en place"

# ==================== 4. APPLICATION DU PATCH SUSFS ====================
echo "=== Téléchargement et application du patch SusFS 4.19 ==="
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo 2>/dev/null || true

PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)
if [ -n "$PATCH_419" ]; then
  echo "Patch: $PATCH_419"
  patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
else
  echo "❌ Patch SusFS 4.19 introuvable"
  find /tmp/jack_repo/Patches -name "*.patch" | head -20
  exit 1
fi

# ==================== 5. CORRECTIONS POST-PATCH ====================
echo "=== Corrections post-patch SusFS ==="

# task_mmu.c
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
    echo "OK: task_mmu.c"
fi

# namespace.c
if ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
    echo "OK: namespace.c"
fi

# Ajout symboles SuSFS manquants
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
    echo "OK: symboles SuSFS ajoutés"
fi

# ==================== 6. CONFIGURATION ====================
echo "=== Configuration du noyau ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
if [ -z "$CONFIG" ]; then
  echo "❌ Aucun fichier de configuration trouvé"
  exit 1
fi
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

# Configuration inspirée du ReSukiSU fonctionnel
./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_MANUAL_HOOK \
    --enable KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
    --enable KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
    --enable KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
    --enable KPROBES \
    --enable HAVE_KPROBES \
    --enable KRETPROBES \
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

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# Ajout manuel de sécurité
{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

grep "CONFIG_KSU" out/.config | sort

# ==================== 7. PATCH SIGNATURES + TACTILE ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# Patch tactile (identique à ReSukiSU)
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 8. COMPILATION DU NOYAU ====================
echo "=== Compilation du noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi

echo "✅ Image compilée"

# ==================== 9. COMPILATION KSUD ====================
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

# ==================== 10. REPACK ====================
cd "$GITHUB_WORKSPACE"

echo "=== Téléchargement boot stock ==="
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img"
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img"

SIZE=$(stat -c%s boot-stock.img)
if [ "$SIZE" -lt 80000000 ]; then
    echo "❌ boot-stock.img trop petit ($SIZE)"
    exit 1
fi

mkdir -p repack
cp boot-stock.img repack/boot.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/

cd repack
./magiskboot unpack boot.img

# Remplacer kernel
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

# Ajouter ksud et su
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

# Script de capture
mkdir -p "$GITHUB_WORKSPACE/capture"
cat > "$GITHUB_WORKSPACE/capture/capture_logs.sh" << 'EOF'
#!/system/bin/sh
sleep 5
dmesg > /data/local/tmp/dmesg.txt
logcat -d > /data/local/tmp/logcat.txt
cp /proc/config.gz /data/local/tmp/config.gz 2>/dev/null
cp /proc/kallsyms /data/local/tmp/kallsyms.txt 2>/dev/null

mkdir -p /sdcard/Download
cp /data/local/tmp/dmesg.txt /sdcard/Download/dmesg.txt
cp /data/local/tmp/logcat.txt /sdcard/Download/logcat.txt
cp /data/local/tmp/config.gz /sdcard/Download/config.gz 2>/dev/null
cp /data/local/tmp/kallsyms.txt /sdcard/Download/kallsyms.txt 2>/dev/null

echo "Logs captured" > /data/local/tmp/capture_done
EOF

chmod 755 "$GITHUB_WORKSPACE/capture/capture_logs.sh"

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/post-fs-data.d" \
    "add 0755 data/adb/post-fs-data.d/capture_logs.sh $GITHUB_WORKSPACE/capture/capture_logs.sh"

# Repack
./magiskboot repack boot.img new-boot.img || { echo "❌ Échec repack"; exit 1; }
mv new-boot.img ../final_boot.img

cd ..

# ==================== 11. OUTPUT ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
