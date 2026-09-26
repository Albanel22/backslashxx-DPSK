#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU v3.3.0-52
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : Albanel22/android_kernel_motorola_sm8250 branche lineage-23.2
# Hooks    : kernelsu-coccinelle (scope-minimized)
# SuSFS    : DÉSACTIVÉ pour ce premier build
# =============================================================================
set -e

echo "=== BUILD KernelSU v3.3.0-52 + Coccinelle hooks (SANS SuSFS) ==="
df -h

# ==================== 0. ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl \
    ocaml opam pkg-config libpcre-ocaml-dev

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONE DU KERNEL (LINEAGEOS OFFICIEL) ====================
echo "=== Clone kernel LineageOS officiel lineage-23.2 ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1
echo "✅ Kernel cloné depuis LineageOS officiel"

# ==================== 1b. BACKPORT get_cred_rcu ====================
echo "=== Backport de get_cred_rcu ==="

# Vérifier si get_cred_rcu existe déjà
if grep -q "get_cred_rcu" include/linux/cred.h; then
    echo "✅ get_cred_rcu déjà présent"
else
    echo "[+] Ajout de get_cred_rcu dans include/linux/cred.h"
    python3 - << 'PYEOF'
import re

# 1) Ajouter get_cred_rcu dans include/linux/cred.h
with open('include/linux/cred.h', 'r') as f:
    content = f.read()

if 'get_cred_rcu' not in content:
    # Insérer après la fonction get_cred()
    pattern = r'(static inline const struct cred \*get_cred\(const struct cred \*cred\)\s*\{[^}]*\})'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        insertion = '''

static inline const struct cred *get_cred_rcu(const struct cred *cred)
{
    struct cred *nonconst_cred = (struct cred *) cred;
    if (!cred)
        return NULL;
    if (!atomic_inc_not_zero(&nonconst_cred->usage))
        return NULL;
    validate_creds(cred);
    return cred;
}'''
        content = content[:match.end()] + insertion + content[match.end():]
        with open('include/linux/cred.h', 'w') as f:
            f.write(content)
        print("[+] get_cred_rcu ajouté dans include/linux/cred.h")
    else:
        print("[!] Pattern get_cred() non trouvé, ajout manuel nécessaire")
else:
    print("[+] get_cred_rcu déjà dans include/linux/cred.h")

# 2) Modifier kernel/cred.c
with open('kernel/cred.c', 'r') as f:
    content = f.read()

if 'get_cred_rcu(cred)' not in content:
    content = content.replace(
        'while (!atomic_inc_not_zero(&((struct cred *)cred)->usage));',
        'while (!get_cred_rcu(cred));'
    )
    with open('kernel/cred.c', 'w') as f:
        f.write(content)
    print("[+] kernel/cred.c modifié pour utiliser get_cred_rcu")
else:
    print("[+] get_cred_rcu déjà utilisé dans kernel/cred.c")
PYEOF
fi

# Vérification
grep -n "get_cred_rcu" include/linux/cred.h || echo "⚠️ get_cred_rcu non trouvé dans cred.h"
grep -n "get_cred_rcu" kernel/cred.c || echo "⚠️ get_cred_rcu non utilisé dans cred.c"

# ==================== 2. CLONE KERNELSU v3.3.0-52 ====================
echo "=== Clone KernelSU v3.3.0-52 (backslashxx) ==="
rm -rf drivers/kernelsu KernelSU /tmp/KernelSU || true

git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null || \
    git fetch --depth=1 origin refs/tags/v3.3.0-52:refs/tags/v3.3.0-52
git checkout v3.3.0-52
echo "✅ KernelSU v3.3.0-52 checkout"
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

# ==================== 3. HOOKS VIA KERNELSU-COCCINELLE ====================
echo "=== Application des hooks scope-minimized via Coccinelle ==="

# Initialiser opam + installer coccinelle
opam init --disable-sandboxing -y
eval $(opam env)
opam install -y coccinelle

# Vérifier que spatch est disponible
which spatch || { echo "❌ spatch introuvable"; exit 1; }
spatch --version | head -1

# Cloner les patchs
rm -rf /tmp/kernelsu-coccinelle
git clone --depth=1 https://github.com/devnoname120/kernelsu-coccinelle.git /tmp/kernelsu-coccinelle

# Vérifier le contenu du dépôt
echo "=== Contenu de kernelsu-coccinelle ==="
ls -la /tmp/kernelsu-coccinelle/
echo "--- scope-minimized-hooks ---"
ls -la /tmp/kernelsu-coccinelle/scope-minimized-hooks/ 2>/dev/null || \
    echo "⚠️ Répertoire scope-minimized-hooks non trouvé"
find /tmp/kernelsu-coccinelle -name "*.cocci" | head -20

# Appliquer les patchs
cd /tmp/kernelsu-coccinelle
if [ -f "apply.sh" ]; then
    echo "=== Utilisation de apply.sh ==="
    bash apply.sh "$GITHUB_WORKSPACE/kernel_sources" 2>&1 | tee /tmp/coccinelle.log
elif [ -d "scope-minimized-hooks" ]; then
    echo "=== Application manuelle des patchs scope-minimized ==="
    cd scope-minimized-hooks
    for patch in *.cocci; do
        echo ">>> Application de $patch..."
        spatch --sp-file "$patch" --dir "$GITHUB_WORKSPACE/kernel_sources" --in-place 2>&1 | tee -a /tmp/coccinelle.log
    done
else
    echo "❌ Aucune méthode d'application trouvée"
    exit 1
fi

cd "$GITHUB_WORKSPACE/kernel_sources"

# Vérifier que les hooks ont bien été insérés
echo "=== Vérification des hooks ==="
grep -r "ksu_handle_execveat" fs/exec.c | head -3 || echo "⚠️ Hook execveat non trouvé"
grep -r "ksu_handle_faccessat" fs/open.c | head -3 || echo "⚠️ Hook faccessat non trouvé"
grep -r "ksu_handle_stat" fs/stat.c | head -3 || echo "⚠️ Hook stat non trouvé"

# ==================== 4. CONFIGURATION DU NOYAU ====================
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

# Désactiver set -e pour ./scripts/config (peut retourner 1 sur options absentes)
set +e

./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_MANUAL_HOOK \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable THREAD_INFO_IN_TASK \
    --disable CC_WERROR

set -e

# Vérifier
echo "=== Vérification config KernelSU ==="
grep "CONFIG_KSU" out/.config || echo "⚠️ Aucune option KSU trouvée"

# Régénérer .config
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Config finale KernelSU ==="
grep "CONFIG_KSU" out/.config

# ==================== 5. PATCH SIGNATURES MODULE ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 6. PATCH TACTILE ====================
echo "=== Application du patch tactile (techpack/display) ==="
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

# ==================== 7. COMPILATION DU NOYAU ====================
echo "=== Compilation du noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi
echo "✅ Compilation réussie"

# ==================== 8. COMPILATION KSUD ====================
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
git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null || true
git checkout v3.3.0-52

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

# ==================== 9. REPACK ====================
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

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/Backslashxx-NoSuSFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
