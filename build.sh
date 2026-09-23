#!/bin/bash
set -e

echo "=== BUILD WINNER : KernelSU v3.2.5-76+ (0b138d6a) + SuSFS + st20-perf LOCALVERSION ==="
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
echo "=== Clonage du kernel Albanel22 lineage-23.2-tactile ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. CLONE KERNELSU (COMMIT EXACT) ====================
echo "=== Integration KernelSU (0b138d6a) ==="
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
    echo "[+] Symlink OK"
    ls drivers/kernelsu/ | head -5
else
    echo "ERREUR: Symlink echoue"
    exit 1
fi

printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

echo "[+] KernelSU integre avec le commit $KSU_COMMIT"

# ==================== 2c. FIX KSU_VERSION GLOBAL ====================
echo "=== Fix KSU_VERSION global ==="

KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' drivers/kernelsu/Makefile | head -1)
if [ -z "$KSU_VER" ]; then
    KSU_VER="32601"
fi
echo "[+] KSU_VERSION detecte : $KSU_VER"

if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
    echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
    echo "[+] ccflags-y += -DKSU_VERSION=${KSU_VER} ajoute"
else
    echo "[+] ccflags-y deja present"
fi

grep -n "DKSU_VERSION" drivers/kernelsu/Makefile

# ==================== 2d. FIX VERSION/UAPI DANS LES BONS FICHIERS ====================
echo "=== Fix version et UAPI dans /tmp/KernelSU ==="

if [ -f "/tmp/KernelSU/uapi/supercall.h" ]; then
    sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h
    sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h
    echo "[+] KERNEL_SU_UAPI_VERSION force a 2"
fi

if [ -f "/tmp/KernelSU/uapi/ksu.h" ]; then
    sed -i 's/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION 32601/' /tmp/KernelSU/uapi/ksu.h
    echo "[+] KERNEL_SU_VERSION force a 32601"
fi

DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
if [ -f "$DISPATCH_FILE" ]; then
    sed -i 's/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/' "$DISPATCH_FILE"
    sed -i 's/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = 32601;/' "$DISPATCH_FILE"
    sed -i 's/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = 32601, .flags = 0 };/' "$DISPATCH_FILE"
    sed -i 's/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = 32601, .flags = 0 };/' "$DISPATCH_FILE"
    echo "[+] Corrections dispatch.c appliquees"
fi

grep -n "uapi_version\|ksuver_override\|cmd = { .version" "$DISPATCH_FILE" 2>/dev/null || true

# ==================== 3. HOOKS MANUELS KERNELSU ====================
echo "=== Hooks manuels KernelSU ==="

hook_insert() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4"

    if [ ! -f "$file" ]; then
        echo "ERREUR: $file introuvable."
        return 1
    fi

    if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then
        echo "ERREUR: Signature non trouvee dans $file"
        return 1
    fi

    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"
    echo "[+] Hook insere dans $file"
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
    echo "ERREUR: Hook faccessat non trouve"
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
    echo "ERREUR: Hook stat non trouve"
    HOOKS_FAILED=1
fi

# Hook sys_reboot
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
 sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\
#endif' kernel/reboot.c

 sed -i '/int ret = 0;/a\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\
#endif' kernel/reboot.c

 echo "[+] Hook sys_reboot OK"
else
 echo "[+] Hook sys_reboot deja present"
fi

echo "[+] Hooks KernelSU en place"

# ==================== 4. TELECHARGEMENT DU VRAI SUSFS ====================
echo "=== Telechargement du VRAI SuSFS (JackA1ltman) ==="

git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"

if [ ! -f "$SUSFS_PATCH" ]; then
    echo "ERREUR: Patch SuSFS 4.19 non trouve"
    find /tmp/jack_repo/Patches -name "*.patch" | sort
    exit 1
fi

echo "[+] Patch SuSFS trouve : $(wc -l < $SUSFS_PATCH) lignes"

# ==================== 5. APPLICATION DU PATCH SUSFS ====================
echo "=== Application du patch SuSFS ==="

patch -p1 < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

if [ -f "fs/susfs.c" ]; then
    echo "[+] fs/susfs.c cree ($(wc -l < fs/susfs.c) lignes)"
else
    echo "ERREUR: fs/susfs.c non cree"
    exit 1
fi

if [ -f "include/linux/susfs.h" ]; then
    echo "[+] include/linux/susfs.h cree"
fi

if [ -f "include/linux/susfs_def.h" ]; then
    echo "[+] include/linux/susfs_def.h cree"
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

# ==================== 5c. CORRECTION GENERIQUE DES FICHIERS PATCHES PAR SUSFS ====================
echo "=== Correction generique des fichiers patches par SuSFS ==="

python3 - << 'PYEOF'
import re
import os

PATTERN_SUSFS = re.compile(
    r'\b('
    r'susfs_[a-zA-Z0-9_]+'
    r'|SUSFS_[A-Z0-9_]+'
    r'|STATX_SUS_[A-Z0-9_]+'
    r'|DEFAULT_KSU_MNT_MINOR_DEV'
    r'|CL_COPY_MNT_NS'
    r')\b'
)

EXTERN_SYMBOLS = [
    'susfs_is_current_ksu_domain',
    'susfs_is_sdcard_android_data_not_decrypted',
]

MARKER = '/* __SUSFS_EXTERNS_INJECTED__ */'

INCLUDE_BLOCK = (
    '\n/* __SUSFS_INCLUDES_INJECTED__ */\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    '#include <linux/susfs.h>\n'
    '#endif\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#include <linux/susfs_def.h>\n'
    '#endif\n'
)

EXTERN_BLOCK = (
    '\n' + MARKER + '\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    'extern bool susfs_is_current_ksu_domain(void);\n'
    'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n'
    '#endif\n'
)

def has_extern_decl(content, symbol):
    return bool(re.search(
        r'(extern|static|DEFINE_STATIC_KEY|EXPORT_SYMBOL)\s*[^;\n]*' + re.escape(symbol),
        content
    ))

def list_kernel_sources():
    files = []
    for root, dirs, filenames in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in (
            'out', '.git', 'drivers/kernelsu', 'include/generated',
            'include/config', 'scripts', 'tools', 'Documentation'
        )]
        for fn in filenames:
            if fn.endswith(('.c', '.h')):
                files.append(os.path.join(root, fn))
    return files

def fix_file(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception:
        return None

    if not PATTERN_SUSFS.search(content):
        return None

    if path.endswith(('susfs.h', 'susfs_def.h')):
        return None

    original = content
    changed = False

    new_content = re.sub(
        r'^\s*n(?=#ifdef|#endif|#include|#define|extern)',
        '',
        content,
        flags=re.MULTILINE
    )
    if new_content != content:
        content = new_content
        changed = True

    if '#include <linux/susfs.h>' not in content and '#include <linux/susfs_def.h>' not in content:
        m = list(re.finditer(r'^#include\s+[<"][^>"]+[>"]\s*$', content, re.MULTILINE))
        if m:
            pos = m[-1].end()
            content = content[:pos] + INCLUDE_BLOCK + content[pos:]
            changed = True

    need_externs = False
    for sym in EXTERN_SYMBOLS:
        if sym in content and not has_extern_decl(content, sym):
            need_externs = True
            break

    if need_externs and MARKER not in content:
        anchors = [
            '#include "pnode.h"',
            '#include "internal.h"',
            '#include "mount.h"',
            '#include <linux/susfs.h>',
            '#include <linux/susfs_def.h>',
            '#include <linux/fs.h>',
        ]
        inserted = False
        for anchor in anchors:
            if anchor in content:
                content = content.replace(anchor, anchor + '\n' + EXTERN_BLOCK, 1)
                inserted = True
                changed = True
                break

        if not inserted:
            m = list(re.finditer(r'^#include\s+[<"][^>"]+[>"]\s*$',
                                 content, re.MULTILINE))
            if m:
                pos = m[-1].end()
                content = content[:pos] + '\n' + EXTERN_BLOCK + content[pos:]
                changed = True

    if changed and content != original:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return 'fixed'
    return None

print("[*] Scan des fichiers source du kernel...")
all_files = list_kernel_sources()
print(f"[*] {len(all_files)} fichiers .c/.h scannes")

fixed_count = 0
for f in all_files:
    result = fix_file(f)
    if result == 'fixed':
        print(f"[+] Corrige : {f}")
        fixed_count += 1

print(f"[+] Corrections generiques SuSFS terminees ({fixed_count} fichiers corriges)")
PYEOF

echo "=== Verification fs/stat.c ==="
grep -n "__SUSFS_INCLUDES_INJECTED__\|__SUSFS_EXTERNS_INJECTED__\|susfs.h\|susfs_def.h" fs/stat.c | head -10 || true

echo "=== Verification fs/super.c ==="
grep -n "__SUSFS_INCLUDES_INJECTED__\|__SUSFS_EXTERNS_INJECTED__\|susfs.h\|susfs_def.h\|susfs_is_current_ksu_domain\|susfs_is_sdcard_android_data_not_decrypted" fs/super.c | head -15 || true

echo "=== Verification fs/namespace.c ==="
grep -n "__SUSFS_INCLUDES_INJECTED__\|__SUSFS_EXTERNS_INJECTED__\|susfs.h\|susfs_def.h\|CL_COPY_MNT_NS" fs/namespace.c | head -15 || true

# ==================== 5d. CORRECTION TASK_MMU.C ====================
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# ==================== 5e. AJOUT DES SYMBOLES MANQUANTS DANS FS/SUSFS.C ====================
echo "=== Ajout des symboles manquants dans fs/susfs.c ==="

if ! grep -q "^bool susfs_is_current_ksu_domain" fs/susfs.c; then
    cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bool susfs_is_current_ksu_domain(void)
{
    const struct cred *cred = current_cred();
    return (cred->uid.val == 0 || cred->uid.val == 2000);
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);
#endif
SUSFS_EOF
    echo "[+] susfs_is_current_ksu_domain ajoute"
fi

if ! grep -q "DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted)" fs/susfs.c; then
    cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted);
EXPORT_SYMBOL(susfs_is_sdcard_android_data_not_decrypted);
#endif
SUSFS_EOF
    echo "[+] susfs_is_sdcard_android_data_not_decrypted ajoute"
fi

if ! grep -q "susfs_ksu_sid" fs/susfs.c; then
    cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
#endif
SUSFS_EOF
    echo "[+] susfs_ksu_sid / susfs_priv_app_sid ajoutes"
fi

echo "=== Symboles SuSFS exportes ==="
grep -n "EXPORT_SYMBOL(susfs_" fs/susfs.c | head -20 || true

# ==================== 5f. SANITY CHECK FINAL ====================
echo "=== Sanity check final des includes SuSFS ==="
for f in fs/stat.c fs/super.c fs/namespace.c fs/namei.c fs/open.c fs/exec.c fs/readdir.c fs/d_path.c fs/proc/task_mmu.c fs/proc/base.c fs/proc/fd.c fs/mount.h; do
  [ -f "$f" ] || continue
  if grep -qE 'susfs_|SUSFS_|STATX_SUS_|CL_COPY_MNT_NS|DEFAULT_KSU_MNT_MINOR_DEV' "$f"; then
    if grep -qE '#include <linux/(susfs|susfs_def)\.h>' "$f"; then
      echo "  OK: $f"
    else
      echo "  MANQUANT: $f"
    fi
  fi
done

# ==================== 5g. RUSTINE CL_COPY_MNT_NS ====================
echo "=== Rustine CL_COPY_MNT_NS ==="

if grep -q "CL_COPY_MNT_NS" fs/namespace.c; then
    if ! grep -q "define CL_COPY_MNT_NS" fs/namespace.c; then
        echo "[!] CL_COPY_MNT_NS utilise mais non defini -> injection"
        python3 - << 'PYEOF'
import re

path = 'fs/namespace.c'
with open(path) as f:
    c = f.read()

if 'define CL_COPY_MNT_NS' not in c:
    define_block = (
        '\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
        '#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n'
        '#endif\n'
    )
    m = list(re.finditer(r'^#include\s+[<"][^>"]+[>"]\s*$', c, re.MULTILINE))
    if m:
        pos = m[-1].end()
        c = c[:pos] + define_block + c[pos:]
    else:
        c = define_block + c

    with open(path, 'w') as f:
        f.write(c)
    print("[+] CL_COPY_MNT_NS defini dans fs/namespace.c")
else:
    print("[=] CL_COPY_MNT_NS deja defini")
PYEOF
    else
        echo "[+] CL_COPY_MNT_NS deja defini dans namespace.c"
    fi
else
    echo "[=] CL_COPY_MNT_NS non utilise dans namespace.c"
fi

echo "--- Verification CL_COPY_MNT_NS ---"
grep -n "CL_COPY_MNT_NS" fs/namespace.c | head -10 || true

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

# ==================== 7. CONFIGURATION ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG_NAME="vendor/lito-perf_defconfig"
echo "Config utilisee: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

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

# Forcer LOCALVERSION à -cip136-st20-perf et bloquer le suffixe dirty/auto
./scripts/config --file out/.config --set-str LOCALVERSION "-cip136-st20-perf"
./scripts/config --file out/.config --disable LOCALVERSION_AUTO

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

{
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

grep "CONFIG_KSU_SUSFS\|CONFIG_LOCALVERSION" out/.config

# ==================== 7b. FIX get_cred_rcu (kernel 4.19) ====================
echo "=== Fix get_cred_rcu pour kernel 4.19 ==="

if grep -q "get_cred_rcu" kernel/cred.c; then
    if ! grep -q "get_cred_rcu" include/linux/cred.h; then
        python3 - << 'PYEOF'
import re

path = 'include/linux/cred.h'
with open(path) as f:
    c = f.read()

if 'get_cred_rcu' not in c:
    block = '''
/*
 * Compat: get_cred_rcu() n'existe pas dans les kernels 4.19.
 * Ajoute pour satisfaire les patches KernelSU backslashxx.
 * cred->usage est un atomic_t en 4.19 (atomic_long_t en 5.x).
 */
static inline const struct cred *get_cred_rcu(const struct cred *cred)
{
	struct cred *nonconst_cred = (struct cred *) cred;
	if (!cred)
		return NULL;
	if (!atomic_inc_not_zero(&nonconst_cred->usage))
		return NULL;
	return cred;
}
'''
    anchors = [
        'static inline void put_cred(const struct cred *_cred)',
        'extern void __put_cred(struct cred *);',
        'static inline void validate_creds(const struct cred *cred)',
    ]
    inserted = False
    for a in anchors:
        if a in c:
            c = c.replace(a, a + '\n' + block, 1)
            inserted = True
            break

    if not inserted:
        c += '\n' + block

    with open(path, 'w') as f:
        f.write(c)
    print("[+] get_cred_rcu ajoute a include/linux/cred.h")
else:
    print("[=] get_cred_rcu deja dans include/linux/cred.h")
PYEOF
    else
        echo "[+] get_cred_rcu deja dans include/linux/cred.h"
    fi

    if ! grep -q '#include <linux/cred.h>' kernel/cred.c; then
        sed -i '1i#include <linux/cred.h>' kernel/cred.c
        echo "[+] include cred.h ajoute a kernel/cred.c"
    fi
fi

echo "Verification get_cred_rcu:"
grep -n "get_cred_rcu" include/linux/cred.h kernel/cred.c 2>/dev/null | head -10 || true

# ==================== 8. PATCH SIGNATURES ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 8a. PATCH TACTILE ====================
printf "\n/* --- Debut Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 9. COMPILATION ====================
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi

echo "Compilation reussie"

# ==================== 10. REPACK (ksud NON compile : le Manager fournit le sien) ====================
cd "$GITHUB_WORKSPACE"

BASE="https://mirrorbits.lineageos.org/full/kiev/20260920"

curl -fL --retry 3 -o boot-stock.img "$BASE/boot.img" \
  || { echo "ERREUR: boot.img introuvable: $BASE/boot.img"; exit 1; }
curl -fL --retry 3 -o dtbo-stock.img "$BASE/dtbo.img" \
  || echo "[!] dtbo.img non telecharge (non bloquant)"
ls -l boot-stock.img

mkdir -p repack mb
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
unzip -q -o Magisk.apk lib/x86_64/libmagiskboot.so -d mb
cp mb/lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot

cd repack
set +e
./magiskboot unpack boot.img
set -e
ls -l
if [ ! -f "kernel" ]; then
    echo "ERREUR: Echec du unpack"
    exit 1
fi

cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot repack boot.img new-boot.img || { echo "ERREUR: Echec du repack"; exit 1; }
cd ..

mkdir -p output
cp repack/new-boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINE ==="
ls -lh output/
