#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU + SuSFS
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche lineage-23.2)
# KernelSU : backslashxx/KernelSU v3.3.0-52
# Hooks    : KSU_HACK_ARM64_BRANCH_LINK (natif)
# SuSFS    : JackA1ltman/NonGKI_Kernel_Build_2nd (patch 4.19)
# =============================================================================
set -e

echo "=== BUILD KernelSU v3.3.0-52 + SuSFS 4.19 ==="
df -h

# ==================== 0. ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clone kernel LineageOS officiel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1
echo "✅ Kernel cloné"

# ==================== 1b. BACKPORT get_cred_rcu (4.19.325) ====================
echo "=== Backport de get_cred_rcu (compatible atomic_long_t) ==="

if grep -q "get_cred_rcu" include/linux/cred.h; then
    echo "✅ get_cred_rcu déjà présent"
else
    python3 - << 'PYEOF'
import re

with open('include/linux/cred.h', 'r') as f:
    content = f.read()

if 'get_cred_rcu' not in content:
    pattern = r'(static inline const struct cred \*get_cred\(const struct cred \*cred\)\s*\{[^}]*\})'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        insertion = '''

static inline const struct cred *get_cred_rcu(const struct cred *cred)
{
    struct cred *nonconst_cred = (struct cred *) cred;
    if (!cred)
        return NULL;
    if (!atomic_long_inc_not_zero(&nonconst_cred->usage))
        return NULL;
    validate_creds(cred);
    return cred;
}'''
        content = content[:match.end()] + insertion + content[match.end():]
        with open('include/linux/cred.h', 'w') as f:
            f.write(content)
        print("[+] get_cred_rcu ajouté dans include/linux/cred.h")

with open('kernel/cred.c', 'r') as f:
    content = f.read()

if 'get_cred_rcu(cred)' not in content:
    content = content.replace(
        'while (!atomic_long_inc_not_zero(&((struct cred *)cred)->usage));',
        'while (!get_cred_rcu(cred));'
    )
    content = content.replace(
        'while (!atomic_inc_not_zero(&((struct cred *)cred)->usage));',
        'while (!get_cred_rcu(cred));'
    )
    with open('kernel/cred.c', 'w') as f:
        f.write(content)
    print("[+] kernel/cred.c modifié")
PYEOF
fi

grep -n "get_cred_rcu" include/linux/cred.h || echo "⚠️ non trouvé"
grep -n "get_cred_rcu" kernel/cred.c || echo "⚠️ non utilisé"

# ==================== 2. CLONE KERNELSU v3.3.0-52 ====================
echo "=== Clone KernelSU v3.3.0-52 (backslashxx) ==="
rm -rf drivers/kernelsu /tmp/KernelSU || true

git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
if git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null; then
    git checkout v3.3.0-52
    echo "✅ Tag v3.3.0-52 checkout"
else
    echo "⚠️ Tag v3.3.0-52 introuvable, utilisation de la branche par défaut"
fi
git log --oneline -1
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
echo "✅ KernelSU intégré"

# ==================== 3. VÉRIFICATION DES HOOKS NATIFS ====================
echo "=== Vérification des hooks natifs ==="

if [ -d "/tmp/KernelSU/kernel/hook" ]; then
    echo "✅ Dossier hook/ trouvé :"
    ls /tmp/KernelSU/kernel/hook/
else
    echo "⚠️ Dossier hook/ non trouvé"
fi

# ==================== 4. INTÉGRATION SuSFS ====================
echo "=== Téléchargement et application du patch SuSFS 4.19 ==="

SUSFS_REPO="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git"
SUSFS_BRANCH="mainline"
rm -rf /tmp/susfs_repo
git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" /tmp/susfs_repo

SUSFS_PATCH="/tmp/susfs_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 introuvable !"
    echo "=== Liste des patchs disponibles ==="
    find /tmp/susfs_repo/Patches -name "*.patch" | sort
    exit 1
fi
echo "✅ Patch SuSFS trouvé : $(wc -l < "$SUSFS_PATCH") lignes"

echo "=== Application du patch SuSFS ==="
set +e
patch -p1 < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log
PATCH_EXIT=$?
set -e

if [ $PATCH_EXIT -ne 0 ]; then
    echo "⚠️ Le patch a rencontré des rejets (normal avec backslashxx)"
    echo "=== Rejets détectés ==="
    find . -name "*.rej" -type f | head -20

    for rej in $(find . -name "*.rej" -type f); do
        orig="${rej%.rej}"
        echo "Tentative de fusion pour $orig..."
        patch --merge "$orig" < "$rej" 2>/dev/null || true
        rm -f "$rej"
    done
fi

find . -name "*.orig" -type f -delete 2>/dev/null || true
find . -name "*.rej" -type f -delete 2>/dev/null || true

if [ ! -f "fs/susfs.c" ]; then
    echo "❌ fs/susfs.c non créé — le patch a échoué"
    exit 1
fi
echo "✅ fs/susfs.c créé ($(wc -l < fs/susfs.c) lignes)"

if [ -f "include/linux/susfs.h" ]; then
    echo "✅ include/linux/susfs.h créé"
fi
if [ -f "include/linux/susfs_def.h" ]; then
    echo "✅ include/linux/susfs_def.h créé"
fi

# ==================== 4b. CORRECTION FS/MAKEFILE ====================
if [ -f "fs/Makefile" ]; then
    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
        echo "[+] susfs.o ajouté à fs/Makefile"
    fi
fi

# ==================== 4c. CORRECTION DES INCLUDES MANQUANTS ====================
echo "=== Correction des includes SuSFS manquants ==="

python3 - << 'PYEOF'
import re, os

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

def inject_after_last_include(content, block):
    m = list(re.finditer(r'^#include\s+[<"][^>"]+[>"]\s*$', content, re.MULTILINE))
    if m:
        pos = m[-1].end()
        return content[:pos] + block + content[pos:]
    return content

def fix_file(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception:
        return None

    if not re.search(r'\b(susfs_[a-zA-Z0-9_]+|SUSFS_[A-Z0-9_]+)\b', content):
        return None
    if path.endswith(('susfs.h', 'susfs_def.h')):
        return None

    original = content
    changed = False

    new_content = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', content, flags=re.MULTILINE)
    if new_content != content:
        content = new_content
        changed = True

    if '#include <linux/susfs.h>' not in content:
        content = inject_after_last_include(content, INCLUDE_BLOCK)
        changed = True

    need_externs = any(sym in content for sym in EXTERN_SYMBOLS)
    if need_externs and MARKER not in content:
        anchors = ['#include "pnode.h"', '#include "internal.h"', '#include "mount.h"',
                   '#include <linux/susfs.h>', '#include <linux/susfs_def.h>', '#include <linux/fs.h>']
        inserted = False
        for anchor in anchors:
            if anchor in content:
                content = content.replace(anchor, anchor + '\n' + EXTERN_BLOCK, 1)
                inserted = True
                changed = True
                break
        if not inserted:
            content = inject_after_last_include(content, EXTERN_BLOCK)
            changed = True

    if changed and content != original:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return 'fixed'
    return None

print("[*] Scan des fichiers source...")
fixed = 0
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in ('out', '.git', 'drivers/kernelsu',
               'include/generated', 'include/config', 'scripts', 'tools', 'Documentation')]
    for fn in files:
        if fn.endswith(('.c', '.h')):
            result = fix_file(os.path.join(root, fn))
            if result == 'fixed':
                fixed += 1
                print(f"[+] Corrigé : {os.path.join(root, fn)}")

print(f"[+] {fixed} fichiers corrigés")
PYEOF

# ==================== 4d. AJOUT DES SYMBOLES MANQUANTS ====================
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
    echo "[+] susfs_is_current_ksu_domain ajouté"
fi

if ! grep -q "DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted)" fs/susfs.c; then
    cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted);
EXPORT_SYMBOL(susfs_is_sdcard_android_data_not_decrypted);
#endif
SUSFS_EOF
    echo "[+] susfs_is_sdcard_android_data_not_decrypted ajouté"
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
    echo "[+] susfs_ksu_sid / susfs_priv_app_sid ajoutés"
fi

# ==================== 4e. CORRECTION TASK_MMU.C ====================
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
    echo "[+] task_mmu.c corrigé"
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

config KSU_SUSFS_TRY_UMOUNT
	bool "try_umount"
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

config KSU_SUSFS_SUS_MAP
	bool "sus_map"
	default y

endif
KCONFIG_EOF
    fi
fi

# ==================== 6. CONFIGURATION ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/vendor/ -name "*lito*" -o -name "*kiev*" 2>/dev/null | head -1)
if [ -z "$CONFIG" ]; then
    CONFIG=$(find arch/arm64/configs/ -name "*lito*" -o -name "*kiev*" | head -1)
fi
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

set +e

./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_HACK_ARM64_BRANCH_LINK \
    --disable KSU_TAMPER_SYSCALL_TABLE \
    --disable KSU_KPROBES_KSUD \
    --enable KSU_LSM_SECURITY_HOOKS \
    --enable KSU_FEATURE_SULOG \
    --enable KSU_FEATURE_ADBROOT \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable THREAD_INFO_IN_TASK \
    --disable CC_WERROR \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_TRY_UMOUNT \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable KSU_SUSFS_OPEN_REDIRECT \
    --enable KSU_SUSFS_SUS_MAP

set -e

echo "=== Vérification config KernelSU + SuSFS ==="
grep "CONFIG_KSU" out/.config || echo "⚠️ Aucune option KSU trouvée"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Config finale ==="
grep -E "CONFIG_KSU|CONFIG_KSU_SUSFS" out/.config

# ==================== 7. PATCH SIGNATURES MODULE ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 8. PATCH TACTILE ====================
echo "=== Application du patch tactile ==="
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
        printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
        echo "✅ Patch tactile appliqué"
    else
        echo "✅ Patch tactile déjà présent"
    fi
else
    echo "⚠️ techpack/display/msm/msm_drv.c introuvable"
fi

# ==================== 9. COMPILATION DU NOYAU ====================
echo "=== Compilation du noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi
echo "✅ Compilation réussie"

# ==================== 10. COMPILATION KSUD (NDK r27) ====================
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

echo "=== Téléchargement du NDK r27 ==="

NDK_ZIP=""
for ver in r27c r27b r27; do
    url="https://dl.google.com/android/repository/android-ndk-${ver}-linux.zip"
    echo "[*] Test : $url"
    if wget --spider -q "$url" 2>/dev/null; then
        echo "[+] Disponible : $url"
        NDK_ZIP="android-ndk-${ver}-linux.zip"
        wget -q "$url"
        break
    fi
done

if [ -z "$NDK_ZIP" ]; then
    echo "❌ Aucun NDK r27 trouvé. Fallback sur r26d + patch build.rs"
    wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
    NDK_ZIP="android-ndk-r26d-linux.zip"
    NEED_BUILD_RS_PATCH=1
else
    NEED_BUILD_RS_PATCH=0
fi

unzip -q "$NDK_ZIP"
NDK_DIR=$(ls -d android-ndk-* 2>/dev/null | head -1)
echo "✅ NDK extrait : $NDK_DIR"

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/$NDK_DIR"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

"$AARCH64_CLANG_PATH" --version | head -1

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src"

if git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null; then
    git checkout v3.3.0-52
    echo "✅ Tag v3.3.0-52 checkout pour ksud"
fi

if [ "$NEED_BUILD_RS_PATCH" = "1" ]; then
    echo "=== Patch build.rs : gnu23 → gnu17 ==="
    BUILD_RS="$GITHUB_WORKSPACE/ksud-src/userspace/ksud/build.rs"
    if [ -f "$BUILD_RS" ]; then
        sed -i 's/std=gnu23/std=gnu17/g' "$BUILD_RS"
        echo "[+] build.rs patché"
    else
        find "$GITHUB_WORKSPACE/ksud-src/userspace/ksud" -name "build.rs" \
            -exec sed -i 's/std=gnu23/std=gnu17/g' {} \;
    fi
fi

CARGO_TOML="userspace/ksud/Cargo.toml"
if [ -f "$CARGO_TOML" ] && grep -q "Kernel-SU/adb_client" "$CARGO_TOML"; then
    echo "=== Patch adb_client ==="
    sed -i 's|^adb_client\s*=\s*{.*git.*Kernel-SU/adb_client.*}.*|adb_client = { version = "3.1.1", default-features = false }|' "$CARGO_TOML"
    rm -f Cargo.lock
    echo "✅ adb_client patché"
fi

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

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img" || {
    echo "❌ Impossible de télécharger boot.img"
    exit 1
}
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img" 2>/dev/null || true

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

# ==================== 12. SORTIE ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SuSFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
