#!/bin/bash
set -e

echo "=== BUILD DIAGNOSTIC : KernelSU + SuSFS + UAPI2 + sys_reboot (sans masquage symboles) ==="
df -h

# ==================== ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl \
    python3-pip wget jq

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 (lineage-23.2) ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

# ==================== 2. KERNELSU (COMMIT FIXE 0b138d6a) ====================
echo "=== Intégration KernelSU (commit 0b138d6a) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu /tmp/KernelSU || true

KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"

git clone https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin "$KSU_COMMIT"
git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/kernel_sources"

# Récupération de la version depuis le Makefile
KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' /tmp/KernelSU/kernel/Makefile | head -1)
if [ -z "$KSU_VER" ]; then
    KSU_VER="32601"
fi
echo "[+] KSU_VERSION détecté : $KSU_VER"

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

# ==================== 2c. FIX KSU_VERSION GLOBAL ====================
if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
    echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
fi

# ==================== 2d. FIX UAPI DANS LES BONS FICHIERS ====================
echo "=== Fix UAPI version ==="
if [ -f "/tmp/KernelSU/uapi/supercall.h" ]; then
    sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h
    sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h
fi

if [ -f "/tmp/KernelSU/uapi/ksu.h" ]; then
    sed -i "s/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION ${KSU_VER}/" /tmp/KernelSU/uapi/ksu.h
fi

DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
if [ -f "$DISPATCH_FILE" ]; then
    sed -i "s/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/" "$DISPATCH_FILE"
    sed -i "s/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = ${KSU_VER};/" "$DISPATCH_FILE"
    sed -i "s/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE"
    sed -i "s/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE"
fi

echo "✅ KernelSU intégré avec le commit $KSU_COMMIT (version ${KSU_VER})"

# ==================== 3. HOOKS MANUELS KERNELSU ====================
echo "=== Hooks manuels KernelSU ==="

hook_insert() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4"
    
    if [ ! -f "$file" ]; then
        echo "❌ $file introuvable."
        return 1
    fi
    
    if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then
        echo "❌ Signature non trouvée dans $file"
        return 1
    fi
    
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \"-Wdeclaration-after-statement\"\n${call_line}\n#endif\n/s" "$file"
    echo "✅ Hook inséré dans $file"
    return 0
}

HOOKS_FAILED=0

# fs/exec.c
hook_insert "fs/exec.c" \
    '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' \
    'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' \
    || HOOKS_FAILED=1

# fs/open.c (deux variantes)
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
    echo "❌ Hook faccessat non trouvé"
    HOOKS_FAILED=1
fi

# fs/stat.c
if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' fs/stat.c > /dev/null 2>&1; then
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
    echo "❌ Hook stat non trouvé"
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
  echo "[+] Hook sys_reboot déjà présent"
fi

if [ $HOOKS_FAILED -eq 1 ]; then
    echo "⚠️ Certains hooks ont échoué, mais on continue."
fi

# ==================== 4. TÉLÉCHARGEMENT DE SUSFS ====================
echo "=== Téléchargement de SuSFS (JackA1ltman) ==="
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 non trouvé !"
    exit 1
fi
echo "✅ Patch SuSFS trouvé : $(wc -l < $SUSFS_PATCH) lignes"

# ==================== 5. APPLICATION DU PATCH SUSFS AVEC VÉRIFICATION ====================
echo "=== Application du patch SuSFS (vérification préalable) ==="
if patch -p1 --dry-run < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_dryrun.log | grep -q "FAILED"; then
    echo "❌ Le patch échoue sur certains fichiers. Rejets :"
    grep -E "Hunk.*FAILED" /tmp/susfs_dryrun.log
    exit 1
fi

patch -p1 < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_apply.log

if [ ! -f "fs/susfs.c" ] || [ ! -f "include/linux/susfs.h" ] || [ ! -f "include/linux/susfs_def.h" ]; then
    echo "❌ Fichiers SUSFS manquants après application !"
    exit 1
fi
echo "✅ Fichiers SUSFS créés."

find . -name "*.rej" -type f -delete 2>/dev/null || true
find . -name "*.orig" -type f -delete 2>/dev/null || true

# ==================== 5a. AJOUT DES SYMBOLES (uniquement si absents) ====================
if ! grep -q "susfs_is_current_ksu_domain" fs/susfs.c; then
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
    echo "[+] Symboles SusFS ajoutés"
else
    echo "[+] Symboles SusFS déjà présents"
fi

# ==================== 5b. CORRECTION FS/MAKEFILE ====================
if [ -f "fs/Makefile" ]; then
    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    fi
    if [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
    fi
fi

# ==================== 5c. CORRECTION NAMESPACE.C ====================
python3 - << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()
content = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', content, flags=re.MULTILINE)
if '#include <linux/susfs_def.h>' not in content:
    content = content.replace(
        '#include <linux/sched/task.h>',
        '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif'
    )
if 'extern bool susfs_is_current_ksu_domain' not in content:
    content = content.replace(
        '#include "pnode.h"',
        '#include "pnode.h"\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif'
    )
with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

# ==================== 5d. CORRECTION TASK_MMU.C ====================
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# ==================== 6. CONFIGURATION DU NOYAU ====================
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
    --enable KSU_MANUAL_HOOK \
    --disable KPROBES \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SUS_MAP \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_ENABLE_LOG \
    --disable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable KSU_SUSFS_OPEN_REDIRECT \
    --enable THREAD_INFO_IN_TASK

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# Ajout explicite des options
{
    echo "CONFIG_KSU_SUSFS=y"
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
    echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
    echo "# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set"
    echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
} >> out/.config

grep "CONFIG_KSU_SUSFS" out/.config

# ==================== 7. PATCH SIGNATURES ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 8. PATCH TACTILE (si fichier existe) ====================
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
    echo "[+] Patch tactile appliqué"
else
    echo "⚠️ Patch tactile sauté (fichier manquant)"
fi

# ==================== 9. COMPILATION DU NOYAU ====================
echo "=== Compilation du noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi
echo "✅ Compilation du noyau réussie"

# ==================== 10. COMPILATION KSUD (MÊME COMMIT) ====================
echo "=== Compilation de ksud (Rust) ==="
cd "$GITHUB_WORKSPACE"

if [ ! -d "$HOME/.cargo/bin" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

if [ ! -d "$GITHUB_WORKSPACE/android-ndk-r26d" ]; then
    wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
    unzip -q android-ndk-r26d-linux.zip
fi

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src"
git fetch --depth=1 origin "$KSU_COMMIT"
git checkout "$KSU_COMMIT"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

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
echo "✅ ksud compilé avec le commit $KSU_COMMIT"

# ==================== 11. TÉLÉCHARGEMENT DU BOOT.IMG VIA API LINEAGEOS ====================
cd "$GITHUB_WORKSPACE"

echo "=== Récupération du dernier boot.img pour kiev via l'API LineageOS ==="
API_URL="https://mirrorbits.lineageos.org/api/v2/builds/kiev"
curl -s "$API_URL" > /tmp/api_response.json

if command -v jq &> /dev/null; then
    BOOT_FILEPATH=$(jq -r '.kiev[0].files[] | select(.filename=="boot.img") | .filepath' /tmp/api_response.json)
else
    BOOT_FILEPATH=$(grep -o '"boot.img","filepath":"[^"]*"' /tmp/api_response.json | head -1 | sed 's/.*"filepath":"\([^"]*\)".*/\1/')
fi

if [ -z "$BOOT_FILEPATH" ]; then
    echo "❌ Impossible de trouver le boot.img dans la réponse de l'API."
    exit 1
fi

BOOT_URL="https://mirrorbits.lineageos.org${BOOT_FILEPATH}"
echo "URL du boot.img : $BOOT_URL"

wget -q "$BOOT_URL" -O boot-stock.img

if [ ! -f "boot-stock.img" ] || [ $(stat -c%s "boot-stock.img") -lt 80000000 ]; then
    echo "❌ Téléchargement du boot.img échoué ou fichier invalide."
    exit 1
fi
echo "✅ boot.img téléchargé ($(stat -c%s boot-stock.img) octets)"

# ==================== 12. REPACK DU BOOT.IMG ====================
mkdir -p repack
cp boot-stock.img repack/boot.img
cd repack

# Télécharger magiskboot si absent
if [ ! -f "magiskboot" ]; then
    wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
    unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
    mv lib/x86_64/libmagiskboot.so magiskboot
    chmod +x magiskboot
    rm -rf Magisk-v27.0.apk lib/
fi

set +e
./magiskboot unpack boot.img
set -e
if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec du unpack"
    exit 1
fi

# Remplacer le kernel
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

# Ajouter ksud dans le ramdisk
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

# ==================== 13. COLLECTE DES ARTEFACTS ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp kernel_sources/build.log output/
cp ksud output/ 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
