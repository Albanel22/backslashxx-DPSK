#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU + SusFS
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche lineage-23.2)
# KernelSU : cyberc3dr/KernelSU (susfs-rksu-master)
# Hooks    : KSU_HACK_ARM64_BRANCH_LINK (natif)
# SusFS    : core + logs uniquement (minimal)
# =============================================================================
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "=== BUILD KernelSU + SusFS minimal (BRANCH_LINK) ==="
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
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources
git log --oneline -1
echo "✅ Kernel cloné"

# ==================== 1b. BACKPORT get_cred_rcu (4.19.325) ====================
echo "=== Backport de get_cred_rcu ==="

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
        print("[+] get_cred_rcu ajouté")

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

# ==================== 2. CLONE KERNELSU ====================
KSU_REPO="${KSU_REPO:-https://github.com/cyberc3dr/KernelSU.git}"
KSU_REF="${KSU_REF:-susfs-rksu-master}"
echo "=== Clone KernelSU: $KSU_REPO ($KSU_REF) ==="
rm -rf drivers/kernelsu /tmp/KernelSU || true

git clone --depth=1 "$KSU_REPO" /tmp/KernelSU
cd /tmp/KernelSU
if git fetch --depth=1 origin "$KSU_REF" 2>/dev/null && git checkout FETCH_HEAD 2>/dev/null; then
    echo "✅ Révision KernelSU: $KSU_REF"
else
    echo "⚠️ Révision $KSU_REF introuvable"
fi
git log --oneline -1
cd "$GITHUB_WORKSPACE/kernel_sources"

# ==================== 2a. SUSFS nGKI ====================
echo "=== Préparation SusFS via nGKI ==="
NGKI_DIR="/tmp/nGKI_Kernel_Build"
rm -rf "$NGKI_DIR"
git clone --depth=1 --branch rebase \
    https://github.com/cyberc3dr/nGKI_Kernel_Build.git "$NGKI_DIR"
SUSFS_PATCH="$NGKI_DIR/Patches/Patch/susfs_patch_to_4.19.patch"

if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch nGKI SusFS 4.19 introuvable"
    exit 1
fi

set +e
patch --batch --forward -p1 < "$SUSFS_PATCH" > susfs_patch.log 2>&1
SUSFS_PATCH_RC=$?
set -e

REJECTS=$(find . -type f -name '*.rej' -print)
SUSFS_FIX_PATCH="${SUSFS_FIX_PATCH:-$SCRIPT_DIR/susfs_kiev_lito_fix.patch}"
if [ "$SUSFS_PATCH_RC" -ne 0 ] || [ -n "$REJECTS" ]; then
    if [ ! -f "$SUSFS_FIX_PATCH" ]; then
        echo "❌ Rejets SusFS + correctif absent: $SUSFS_FIX_PATCH"
        cat susfs_patch.log
        exit 1
    fi
    echo "⚠️ Application du correctif kiev/lito"
    patch --batch --forward -p1 < "$SUSFS_FIX_PATCH" > susfs_kiev_lito_fix.log 2>&1 || {
        cat susfs_kiev_lito_fix.log
        exit 1
    }
    find . -type f \( -name '*.rej' -o -name '*.orig' \) -delete
fi

find . -type f -name '*.orig' -delete

# --- Fix include susfs_def.h dans fs/stat.c ---
python3 - <<'PYEOF_STAT'
from pathlib import Path
path = Path("fs/stat.c")
text = path.read_text()
include = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n"
if "#include <linux/susfs_def.h>" not in text:
    marker = "#include <asm/unistd.h>\n"
    if marker in text:
        text = text.replace(marker, marker + "\n" + include, 1)
        path.write_text(text)
        print("✅ include susfs_def.h ajouté à fs/stat.c")
PYEOF_STAT

# --- Fix susfs_run_sus_path_loop global ---
python3 - <<'PYEOF_SYMBOL'
from pathlib import Path
path = Path("fs/susfs.c")
text = path.read_text()
old = "static void susfs_run_sus_path_loop(void)"
new = "void susfs_run_sus_path_loop(void)"
if old in text:
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("✅ susfs_run_sus_path_loop global")
elif new in text:
    print("✅ susfs_run_sus_path_loop déjà global")
PYEOF_SYMBOL

echo "✅ Patch SusFS nGKI appliqué"

# ==================== 2a-ter. VÉRIFICATION DES DÉFINITIONS SUSFS ====================
echo "=== Vérification des définitions SuSFS ==="

# Ces symboles sont déjà définis dans cyberc3dr/KernelSU (drivers/kernelsu/selinux/selinux.c)
# Ne PAS les ajouter dans fs/susfs.c, sinon conflit au link (duplicate symbol)

if grep -q "susfs_is_current_ksu_domain" /tmp/KernelSU/kernel/selinux/selinux.c 2>/dev/null; then
    echo "✅ susfs_is_current_ksu_domain fourni par cyberc3dr/KernelSU"
else
    echo "⚠️ susfs_is_current_ksu_domain non trouvé dans KernelSU — vérifier la révision"
fi

if grep -q "susfs_ksu_sid" /tmp/KernelSU/kernel/selinux/selinux.c 2>/dev/null; then
    echo "✅ susfs_ksu_sid fourni par cyberc3dr/KernelSU"
else
    echo "⚠️ susfs_ksu_sid non trouvé dans KernelSU"
fi

if grep -q "susfs_priv_app_sid" /tmp/KernelSU/kernel/selinux/selinux.c 2>/dev/null; then
    echo "✅ susfs_priv_app_sid fourni par cyberc3dr/KernelSU"
else
    echo "⚠️ susfs_priv_app_sid non trouvé dans KernelSU"
fi

echo "✅ Vérification terminée (pas d'ajout dans fs/susfs.c)"

# ==================== 2b. SYMLINK DRIVER ====================
ln -sf /tmp/KernelSU/kernel drivers/kernelsu

if [ ! -d "drivers/kernelsu" ]; then
    echo "❌ Symlink ÉCHOUÉ"
    exit 1
fi
echo "✅ Symlink OK"

printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig
echo "✅ KernelSU intégré"

# ==================== 3. VÉRIFICATION HOOKS ====================
echo "=== Vérification des hooks natifs ==="
if [ -d "/tmp/KernelSU/kernel/hook" ]; then
    echo "✅ Hooks :"
    ls /tmp/KernelSU/kernel/hook/
fi

# ==================== 4. CONFIGURATION ====================
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
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_ENABLE_LOG \
    --disable KSU_SUSFS_SUS_PATH \
    --disable KSU_SUSFS_SUS_MOUNT \
    --disable KSU_SUSFS_SUS_KSTAT \
    --disable KSU_SUSFS_SPOOF_UNAME \
    --disable KSU_SUSFS_TRY_UMOUNT \
    --disable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --disable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --disable KSU_SUSFS_OPEN_REDIRECT \
    --disable KSU_SUSFS_SUS_MAP \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable THREAD_INFO_IN_TASK \
    --disable CC_WERROR

set -e

echo "=== Config KernelSU ==="
grep "CONFIG_KSU" out/.config || echo "⚠️ Aucune option KSU"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Config finale ==="
grep "CONFIG_KSU" out/.config

# Vérification profil SusFS minimal
grep -q '^CONFIG_KSU_SUSFS=y$' out/.config || { echo "❌ KSU_SUSFS pas activé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS_ENABLE_LOG=y$' out/.config || { echo "❌ KSU_SUSFS_ENABLE_LOG pas activé"; exit 1; }

for symbol in \
    KSU_SUSFS_SUS_PATH \
    KSU_SUSFS_SUS_MOUNT \
    KSU_SUSFS_SUS_KSTAT \
    KSU_SUSFS_SPOOF_UNAME \
    KSU_SUSFS_TRY_UMOUNT \
    KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    KSU_SUSFS_OPEN_REDIRECT \
    KSU_SUSFS_SUS_MAP; do
    if grep -q "^CONFIG_${symbol}=y$" out/.config; then
        echo "❌ CONFIG_${symbol} ne doit pas être activé"
        exit 1
    fi
done
echo "✅ Profil SusFS minimal validé"

# ==================== 5. PATCH SIGNATURES MODULE ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 6. PATCH TACTILE ====================
echo "=== Patch tactile ==="
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
        printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
        echo "✅ Patch tactile appliqué"
    fi
fi

# ==================== 7. COMPILATION ====================
echo "=== Compilation du noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi
echo "✅ Compilation noyau réussie"

# ==================== 8. COMPILATION KSUD ====================
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

NDK_ZIP=""
for ver in r27c r27b r27; do
    url="https://dl.google.com/android/repository/android-ndk-${ver}-linux.zip"
    if wget --spider -q "$url" 2>/dev/null; then
        NDK_ZIP="android-ndk-${ver}-linux.zip"
        wget -q "$url"
        break
    fi
done

if [ -z "$NDK_ZIP" ]; then
    wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
    NDK_ZIP="android-ndk-r26d-linux.zip"
    NEED_BUILD_RS_PATCH=1
else
    NEED_BUILD_RS_PATCH=0
fi

unzip -q "$NDK_ZIP"
NDK_DIR=$(ls -d android-ndk-* 2>/dev/null | head -1)

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/$NDK_DIR"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src"

if git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null; then
    git checkout v3.3.0-52
fi

if [ "$NEED_BUILD_RS_PATCH" = "1" ]; then
    find "$GITHUB_WORKSPACE/ksud-src" -name "build.rs" -exec sed -i 's/std=gnu23/std=gnu17/g' {} \;
fi

CARGO_TOML="userspace/ksud/Cargo.toml"
if [ -f "$CARGO_TOML" ] && grep -q "Kernel-SU/adb_client" "$CARGO_TOML"; then
    sed -i 's|^adb_client\s*=\s*{.*git.*Kernel-SU/adb_client.*}.*|adb_client = { version = "3.1.1", default-features = false }|' "$CARGO_TOML"
    rm -f Cargo.lock
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
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"

# ==================== 9. REPACK ====================
cd "$GITHUB_WORKSPACE"

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
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

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SuSFS-minimal-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

# ==================== 10b. MODULE USERSPACE SUSFS ====================
echo "=== Module userspace SusFS ==="
rm -rf "$GITHUB_WORKSPACE/susfs4ksu-module"
git clone --depth=1 --branch v1.5.2+ \
    https://github.com/sidex15/susfs4ksu-module.git \
    "$GITHUB_WORKSPACE/susfs4ksu-module"
(cd "$GITHUB_WORKSPACE/susfs4ksu-module" && zip -qr "$GITHUB_WORKSPACE/output/susfs4ksu-module.zip" . -x '.git/*')

echo "=== BUILD TERMINÉ ==="
ls -lh output/
