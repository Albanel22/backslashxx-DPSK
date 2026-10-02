#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log_info()  { echo "[$(date +'%H:%M:%S')] ✅ $*"; }
log_warn()  { echo "[$(date +'%H:%M:%S')] ⚠️ $*"; }
log_err()   { echo "[$(date +'%H:%M:%S')] ❌ $*" >&2; }

trap 'log_err "Script interrompu"; exit 1' ERR

echo "=== BUILD KernelSU v3.3.0-52 + SusFS ==="
df -h

# ==================== 0. INSTALLATION MINIMALE ====================
log_info "Installation des outils essentiels"

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential bc bison flex libelf-dev libssl-dev libncurses-dev \
    aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
    clang llvm lld device-tree-compiler zip unzip curl git python3 \
    mkbootimg perl rsync wget ca-certificates

log_info "Outils installés"

# ==================== 1. CLONAGE DU NOYAU ====================
cd "$SCRIPT_DIR"
rm -rf kernel_sources 2>/dev/null || true

log_info "Clonage du kernel..."
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources
log_info "Kernel cloné"

# ==================== 2. BACKPORT get_cred_rcu ====================
log_info "Backport get_cred_rcu"

python3 << 'PY'
import re
from pathlib import Path

cred_h = Path("include/linux/cred.h")
content = cred_h.read_text()

if "get_cred_rcu" not in content:
    pattern = r"(static inline const struct cred \*get_cred\(const struct cred \*cred\)\s*\{.*?\})"
    match = re.search(pattern, content, re.DOTALL)
    if match:
        insertion = '\nstatic inline const struct cred *get_cred_rcu(const struct cred *cred)\n{\n    struct cred *nonconst_cred = (struct cred *) cred;\n    if (!cred) return NULL;\n    if (!atomic_long_inc_not_zero(&nonconst_cred->usage)) return NULL;\n    validate_creds(cred);\n    return cred;\n}\n'
        content = content[:match.end()] + insertion + content[match.end():]
        cred_h.write_text(content)

cred_c = Path("kernel/cred.c")
text = cred_c.read_text()
if "get_cred_rcu(cred)" not in text:
    text = text.replace("while (!atomic_long_inc_not_zero(&((struct cred *)cred)->usage));", "while (!get_cred_rcu(cred));")
    text = text.replace("while (!atomic_inc_not_zero(&((struct cred *)cred)->usage));", "while (!get_cred_rcu(cred));")
    cred_c.write_text(text)

print("✅ get_cred_rcu OK")
PY

# ==================== 3. CLONE KERNELSU ====================
log_info "Clone KernelSU v3.3.0-52"

rm -rf /tmp/KernelSU
git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null && git checkout v3.3.0-52 || true
cd "$SCRIPT_DIR/kernel_sources"

log_info "KernelSU OK"

# ==================== 4. PATCH SUSFS ====================
log_info "Patch SusFS nGKI"

rm -rf /tmp/nGKI
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/nGKI

PATCH="/tmp/nGKI/Patches/Patch/susfs_patch_to_4.19.patch"
[ -f "$PATCH" ] || { log_err "Patch SusFS introuvable"; exit 1; }

patch --batch --forward -p1 < "$PATCH" > /dev/null 2>&1 || true
find . -type f \( -name '*.rej' -o -name '*.orig' \) -delete

python3 << 'PY'
from pathlib import Path

# Fix fs/stat.c
if Path("fs/stat.c").exists():
    p = Path("fs/stat.c")
    t = p.read_text()
    if "#include <linux/susfs_def.h>" not in t:
        t = t.replace("#include <asm/unistd.h>\n", "#include <asm/unistd.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n", 1)
        p.write_text(t)

# Fix fs/susfs.c
if Path("fs/susfs.c").exists():
    p = Path("fs/susfs.c")
    t = p.read_text()
    t = t.replace("static void susfs_run_sus_path_loop(void)", "void susfs_run_sus_path_loop(void)", 1)
    
    # Ajouter symboles manquants
    if "susfs_ksu_sid" not in t:
        t += "\nu32 susfs_ksu_sid = 0;\nEXPORT_SYMBOL(susfs_ksu_sid);\n"
    if "susfs_priv_app_sid" not in t:
        t += "u32 susfs_priv_app_sid = 0;\nEXPORT_SYMBOL(susfs_priv_app_sid);\n"
    if "susfs_is_current_ksu_domain" not in t:
        t += "bool susfs_is_current_ksu_domain(void) { const struct cred *cred = current_cred(); return (cred->uid.val == 0 || cred->uid.val == 2000); }\nEXPORT_SYMBOL(susfs_is_current_ksu_domain);\n"
    if "susfs_show_version" not in t:
        t += "\nvoid susfs_show_version(void __user **user_info) { struct st_susfs_version info = {0}; if (copy_from_user(&info, (struct st_susfs_version __user *)*user_info, sizeof(info))) { info.err = -EFAULT; goto out; } strscpy(info.susfs_version, SUSFS_VERSION, SUSFS_MAX_VERSION_BUFSIZE - 1); info.err = 0; out: copy_to_user((struct st_susfs_version __user *)*user_info, &info, sizeof(info)); }\n"
    if "susfs_show_variant" not in t:
        t += "void susfs_show_variant(void __user **user_info) { struct st_susfs_variant info = {0}; if (copy_from_user(&info, (struct st_susfs_variant __user *)*user_info, sizeof(info))) { info.err = -EFAULT; goto out; } strscpy(info.susfs_variant, SUSFS_VARIANT, SUSFS_MAX_VARIANT_BUFSIZE - 1); info.err = 0; out: copy_to_user((struct st_susfs_variant __user *)*user_info, &info, sizeof(info)); }\n"
    
    p.write_text(t)

print("✅ SusFS patches OK")
PY

# ==================== 5. PATCH DISPATCH.C ====================
log_info "Patch dispatch.c pour SUSFS routing"

DISPATCH="$(find /tmp/KernelSU -name 'dispatch.c' | head -1)"
[ -n "$DISPATCH" ] || { log_err "dispatch.c introuvable"; exit 1; }

python3 << 'PY'
import re
from pathlib import Path

p = Path("/tmp/KernelSU/kernel/supercall/dispatch.c")
t = p.read_text()

if '#include <linux/susfs.h>' not in t:
    t = re.sub(r'(#include\s+[<"][^\n>"]+(>|")\n)', r'\1#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#include <linux/susfs_def.h>\n#endif\n', t, count=1)

if "__ksu_handle_cmd" in t:
    # Ajouter le routage avant le return final
    susfs_routing = '''
#ifdef CONFIG_KSU_SUSFS
    if ((unsigned int)magic2 == 0xFAFAFAFA) {
        switch (cmd) {
        case 0x55550: susfs_add_sus_path((void __user **)&arg); return 0;
        case 0x55553: susfs_add_sus_path_loop((void __user **)&arg); return 0;
        case 0x555a0: susfs_enable_log((void __user **)&arg); return 0;
        case 0x555e1: susfs_show_version((void __user **)&arg); return 0;
        case 0x555e2: susfs_get_enabled_features((void __user **)&arg); return 0;
        case 0x555e3: susfs_show_variant((void __user **)&arg); return 0;
        default: break;
        }
    }
#endif
'''
    # Insérer avant le dernier return
    t = re.sub(r'(\s+)return __do_nothing\(\);', susfs_routing + r'\1return __do_nothing();', t, count=1)

p.write_text(t)
print("✅ dispatch.c patché")
PY

# ==================== 6. INTÉGRATION KERNELSU ====================
log_info "Intégration KernelSU"

rm -rf drivers/kernelsu
ln -s /tmp/KernelSU/kernel drivers/kernelsu

grep -q "obj-\$(CONFIG_KSU)" drivers/Makefile || echo "obj-\$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig

# ==================== 7. CONFIG ET BUILD ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG="$(find arch/arm64/configs -name '*lito*' -o -name '*kiev*' | head -1)"
[ -n "$CONFIG" ] || { log_err "Config kernel introuvable"; exit 1; }

CONFIG_NAME="${CONFIG#arch/arm64/configs/}"
log_info "Config : $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" "$CONFIG_NAME"

./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_TAMPER_SYSCALL_TABLE \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KALLSYMS --enable KALLSYMS_ALL \
    --disable KSU_SUSFS_SUS_MOUNT --disable KSU_SUSFS_SUS_KSTAT \
    --disable KPROBES --disable CC_WERROR >/dev/null 2>&1 || true

make O=out LLVM=1 olddefconfig

# Vérifier config
for cfg in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_KSU_TAMPER_SYSCALL_TABLE; do
    grep -q "^${cfg}=y$" out/.config || { log_err "$cfg manquant"; exit 1; }
done

log_info "Config validée"

# Patch signatures module
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c 2>/dev/null || true

# BUILD
log_info "Compilation du kernel..."
make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" Image 2>&1 | grep -E "^  (CC|LD|Image)" | tail -20

[ -f out/arch/arm64/boot/Image ] || { log_err "Compilation échouée"; exit 1; }
log_info "Kernel compilé ✅"

# ==================== 8. KSUD ====================
cd "$SCRIPT_DIR"

if ! command -v cargo >/dev/null 2>&1; then
    log_info "Installation Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
fi

rustup target add aarch64-linux-android 2>/dev/null || true

# Télécharger NDK
NDK=""
for v in r27c r27b r27 r26d; do
    if wget --spider -q "https://dl.google.com/android/repository/android-ndk-${v}-linux.zip" 2>/dev/null; then
        wget -q "https://dl.google.com/android/repository/android-ndk-${v}-linux.zip"
        NDK="android-ndk-${v}"
        break
    fi
done

[ -n "$NDK" ] || { log_err "NDK non trouvé"; exit 1; }

unzip -q "${NDK}-linux.zip"
NDK_ROOT="$(pwd)/$NDK"

export ANDROID_NDK_ROOT="$NDK_ROOT"
export AARCH64_CLANG="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

rm -rf ksud-src
git clone --depth=1 https://github.com/backslashxx/KernelSU.git ksud-src
cd ksud-src
git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null && git checkout v3.3.0-52 || true

cd userspace/ksud
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX"
AR_aarch64_linux_android = "$AR"
EOF

log_info "Build ksud..."
cargo build --release --target aarch64-linux-android 2>&1 | tail -5

KSUD="$SCRIPT_DIR/ksud-src/target/aarch64-linux-android/release/ksud"
[ -f "$KSUD" ] || { log_err "ksud build échoué"; exit 1; }

cp "$KSUD" "$SCRIPT_DIR/ksud"
chmod 755 "$SCRIPT_DIR/ksud"
log_info "ksud compilé ✅"

# ==================== 9. REPACK BOOT ====================
cd "$SCRIPT_DIR"

log_info "Téléchargement boot.img..."
for date in 20260920 20260913 20260830 20260815; do
    if wget --spider -q "https://mirrorbits.lineageos.org/full/kiev/${date}/boot.img" 2>/dev/null; then
        wget -q -O boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/${date}/boot.img"
        break
    fi
done

[ -f boot-stock.img ] || { log_err "boot.img non trouvé"; exit 1; }

mkdir -p repack
cp boot-stock.img repack/boot.img

# MagiskBoot
cd repack
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so magiskboot
chmod +x magiskboot
rm -rf Magisk-v27.0.apk lib/

log_info "Repacking..."
./magiskboot unpack boot.img
cp "$SCRIPT_DIR/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" "add 0755 data/adb/ksud/ksud $SCRIPT_DIR/ksud"
./magiskboot repack boot.img new-boot.img

mv new-boot.img "$SCRIPT_DIR/final_boot.img"
cd "$SCRIPT_DIR"

# ==================== 10. OUTPUT ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SuSFS-IOCTL-boot.img
[ -f repack/dtbo ] && cp repack/dtbo output/dtbo.img 2>/dev/null || true
cp ksud output/

echo ""
echo "=== ✅ BUILD RÉUSSI ==="
ls -lh output/
