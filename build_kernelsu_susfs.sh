#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : Albanel22/android_kernel_motorola_sm8250 (branche lineage-23.2)
# KernelSU : backslashxx/KernelSU v3.3.0-52
# Hooks    : KSU_HACK_ARM64_BRANCH_LINK (natif)
# SusFS    : nGKI patch 4.19 + cyberc3dr/susfs-rksu-master
# =============================================================================
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "=== BUILD cyberc3dr KernelSU (BRANCH_LINK) + SusFS nGKI 4.19 ==="
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

# ==================== 2. CLONE KERNELSU ====================
# La branche cyberc3dr/susfs-rksu-master fournit KernelSU avec SusFS natif.
# Surcharger ces variables uniquement avec une branche ayant la même API.
KSU_REPO="${KSU_REPO:-https://github.com/cyberc3dr/KernelSU.git}"
KSU_REF="${KSU_REF:-susfs-rksu-master}"
echo "=== Clone KernelSU: $KSU_REPO ($KSU_REF) ==="
rm -rf drivers/kernelsu /tmp/KernelSU || true

git clone --depth=1 "$KSU_REPO" /tmp/KernelSU
cd /tmp/KernelSU
if git fetch --depth=1 origin "$KSU_REF" 2>/dev/null && git checkout FETCH_HEAD 2>/dev/null; then
    echo "✅ Révision KernelSU sélectionnée: $KSU_REF"
else
    echo "⚠️ Révision $KSU_REF introuvable, utilisation de la branche clonée"
fi
git log --oneline -1
cd "$GITHUB_WORKSPACE/kernel_sources"

# ==================== 2a. SUSFS nGKI ====================
echo "=== Préparation SusFS via nGKI_Kernel_Build ==="
NGKI_DIR="/tmp/nGKI_Kernel_Build"
rm -rf "$NGKI_DIR"
git clone --depth=1 --branch rebase \
    https://github.com/cyberc3dr/nGKI_Kernel_Build.git "$NGKI_DIR"
SUSFS_PATCH="$NGKI_DIR/Patches/Patch/susfs_patch_to_4.19.patch"

# La branche susfs-rksu-master contient déjà la partie KernelSU/SUSFS.
# Le patch nGKI ajoute la partie noyau spécifique au 4.19.
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
        echo "❌ Le patch nGKI SusFS 4.19 a des rejets et le correctif est absent: $SUSFS_FIX_PATCH"
        cat susfs_patch.log
        [ -n "$REJECTS" ] && printf '%s\n' "$REJECTS" | while read -r f; do echo "--- $f"; cat "$f"; done
        exit 1
    fi
    echo "⚠️ Rejets nGKI détectés; application du correctif kiev/lito"
    patch --batch --forward -p1 < "$SUSFS_FIX_PATCH" > susfs_kiev_lito_fix.log 2>&1 || {
        cat susfs_kiev_lito_fix.log
        echo "❌ Le correctif kiev/lito ne s'applique pas à cette révision"
        exit 1
    }
    # Les rejets du patch générique sont remplacés par les hunks du correctif.
    find . -type f \( -name '*.rej' -o -name '*.orig' \) -delete
fi

REJECTS=$(find . -type f -name '*.rej' -print)
if [ -n "$REJECTS" ]; then
    echo "❌ Des rejets SusFS subsistent après le correctif"
    printf '%s\n' "$REJECTS" | while read -r f; do echo "--- $f"; cat "$f"; done
    exit 1
fi
find . -type f -name '*.orig' -delete
# Le patch 4.19 utilise des symboles définis par susfs_def.h dans fs/stat.c.
# Certaines versions du patch n'ajoutent pas cet include automatiquement.
python3 - <<'PYEOF_STAT'
from pathlib import Path
path = Path("fs/stat.c")
text = path.read_text()
include = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n"
if "#include <linux/susfs_def.h>" not in text:
    marker = "#include <asm/unistd.h>\n"
    if marker not in text:
        raise SystemExit("Impossible de trouver #include <asm/unistd.h> dans fs/stat.c")
    text = text.replace(marker, marker + "\n" + include, 1)
    path.write_text(text)
    print("✅ Include susfs_def.h ajouté à fs/stat.c")
else:
    print("✅ Include susfs_def.h déjà présent dans fs/stat.c")
PYEOF_STAT

# KernelSU setuid_hook.c appelle cette fonction depuis un autre objet.
# Le patch SusFS 4.19 la déclare static, ce qui provoque un symbole non résolu au link.
python3 - <<'PYEOF_SYMBOL'
from pathlib import Path
path = Path("fs/susfs.c")
text = path.read_text()
old = "static void susfs_run_sus_path_loop(void)"
new = "void susfs_run_sus_path_loop(void)"
if old in text:
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("✅ susfs_run_sus_path_loop rendu global")
elif new in text:
    print("✅ susfs_run_sus_path_loop déjà global")
else:
    raise SystemExit("Définition de susfs_run_sus_path_loop introuvable dans fs/susfs.c")
PYEOF_SYMBOL

echo "✅ Patch noyau SusFS nGKI + correctif kiev/lito appliqués"

# ==================== 2a-ter. DÉFINITIONS MANQUANTES SUSFS ====================
echo "=== Ajout des définitions manquantes SuSFS ==="

# Ces symboles sont référencés par le code SuSFS mais leurs définitions
# ont été perdues lors de l'application du patch (hunks rejetés).
# On les ajoute manuellement dans fs/susfs.c.

python3 - << 'PYEOF'
from pathlib import Path

path = Path("fs/susfs.c")
if not path.exists():
    print("❌ fs/susfs.c introuvable")
    raise SystemExit(1)

text = path.read_text()
added = []

# 1. susfs_is_current_ksu_domain
if "bool susfs_is_current_ksu_domain(void)" not in text and \
   "susfs_is_current_ksu_domain(void)" not in text.split("EXPORT_SYMBOL")[0]:
    if "susfs_is_current_ksu_domain" not in text:
        text += '''

/* __SUSFS_FIX_ksu_domain__ */
bool susfs_is_current_ksu_domain(void)
{
	const struct cred *cred = current_cred();
	return (cred->uid.val == 0 || cred->uid.val == 2000);
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);
'''
        added.append("susfs_is_current_ksu_domain")
    else:
        print("[i] susfs_is_current_ksu_domain déjà défini")
else:
    print("[i] susfs_is_current_ksu_domain déjà défini")

# 2. susfs_ksu_sid + susfs_priv_app_sid
if "susfs_ksu_sid" not in text:
    text += '''

/* __SUSFS_FIX_ksu_sid__ */
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
'''
    added.append("susfs_ksu_sid")
    added.append("susfs_priv_app_sid")
else:
    print("[i] susfs_ksu_sid déjà défini")

path.write_text(text)
if added:
    print(f"✅ Définitions ajoutées: {', '.join(added)}")
else:
    print("✅ Aucune définition manquante")
PYEOF

# Vérification
echo "=== Vérification ==="
grep -n "susfs_is_current_ksu_domain\|susfs_ksu_sid\|susfs_priv_app_sid" fs/susfs.c | tail -10

# ==================== 2b. SYMLINK DRIVER ===================="
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

# Désactiver set -e pour ./scripts/config (peut retourner 1 sur options absentes)
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
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --disable KSU_SUSFS_TRY_UMOUNT \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable KSU_SUSFS_OPEN_REDIRECT \
    --enable KSU_SUSFS_SUS_MAP \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable THREAD_INFO_IN_TASK \
    --disable CC_WERROR

set -e

echo "=== Vérification config KernelSU ==="
grep "CONFIG_KSU" out/.config || echo "⚠️ Aucune option KSU trouvée"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Config finale KernelSU ==="
grep "CONFIG_KSU" out/.config

# ==================== 5. PATCH SIGNATURES MODULE ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 6. PATCH TACTILE ====================
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

# ==================== 8. COMPILATION KSUD (NDK r27) ====================
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

# --- Télécharger le NDK r27 (supporte -std=gnu23) ---
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

# Vérifier la version de clang
"$AARCH64_CLANG_PATH" --version | head -1

# --- Cloner KernelSU ---
rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src"

if git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null; then
    git checkout v3.3.0-52
    echo "✅ Tag v3.3.0-52 checkout pour ksud"
fi

# --- Patch build.rs si NDK r26d (fallback) ---
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

# --- Fix adb_client si nécessaire ---
CARGO_TOML="userspace/ksud/Cargo.toml"
if [ -f "$CARGO_TOML" ] && grep -q "Kernel-SU/adb_client" "$CARGO_TOML"; then
    echo "=== Patch adb_client ==="
    sed -i 's|^adb_client\s*=\s*{.*git.*Kernel-SU/adb_client.*}.*|adb_client = { version = "3.1.1", default-features = false }|' "$CARGO_TOML"
    rm -f Cargo.lock
    echo "✅ adb_client patché"
fi

# --- Compilation ksud ---
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
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

# ==================== 10b. MODULE USERSPACE SUSFS ====================
echo "=== Préparation du module userspace SusFS ==="
rm -rf "$GITHUB_WORKSPACE/susfs4ksu-module"
git clone --depth=1 --branch v1.5.2+ \
    https://github.com/sidex15/susfs4ksu-module.git \
    "$GITHUB_WORKSPACE/susfs4ksu-module"
(cd "$GITHUB_WORKSPACE/susfs4ksu-module" && zip -qr "$GITHUB_WORKSPACE/output/susfs4ksu-module.zip" . -x '.git/*')

echo "=== BUILD TERMINÉ ==="
ls -lh output/
