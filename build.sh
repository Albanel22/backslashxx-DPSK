#!/bin/bash
set -Eeuo pipefail

# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU + SusFS
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche lineage-23.2)
# KernelSU : backslashxx/KernelSU (commit 32651c = Manager v3.3.0-50)
# SusFS    : patch cyberc3dr nGKI 4.19 + routage dispatch.c
# Profil   : SUS_PATH + core + logs
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

log_info()  { echo "[$(date +'%H:%M:%S')] ✅ $*"; }
log_warn()  { echo "[$(date +'%H:%M:%S')] ⚠️ $*"; }
log_err()   { echo "[$(date +'%H:%M:%S')] ❌ $*" >&2; }

trap 'log_err "Erreur détectée. Le script a été interrompu."; exit 1' ERR

echo "=== BUILD backslashxx KernelSU 32651c + SusFS (SUS_PATH + core + logs) ==="
df -h

# ==================== 0. INSTALLATION DES OUTILS ====================
log_info "Installation des outils de compilation"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 \
    mkbootimg perl rsync wget

# ==================== 0b. VÉRIFICATIONS PRÉALABLES ====================
for cmd in git curl wget unzip zip python3 gcc make aarch64-linux-gnu-gcc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_err "Commande manquante : $cmd"
        exit 1
    fi
done
log_info "Toutes les commandes sont disponibles"

# ==================== 1. CLONAGE DU NOYAU ====================
cd "$SCRIPT_DIR"
if [ -d "kernel_sources" ]; then
    log_warn "Le dossier kernel_sources existe déjà. Nettoyage..."
    rm -rf kernel_sources
fi

git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources
git log --oneline -1
log_info "Kernel cloné"

# ==================== 2. BACKPORT get_cred_rcu (4.19.325) ====================
log_info "Backport get_cred_rcu"

python3 - <<'PY'
import re
from pathlib import Path

def ensure_file(path):
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Fichier introuvable : {path}")
    return p

cred_h = ensure_file("include/linux/cred.h")
content = cred_h.read_text()

if "get_cred_rcu" not in content:
    pattern = r"(static inline const struct cred \*get_cred\(const struct cred \*cred\)\s*\{.*?\})"
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        raise RuntimeError("Impossible de trouver get_cred() dans include/linux/cred.h")
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
}
'''
    content = content[:match.end()] + insertion + content[match.end():]
    cred_h.write_text(content)
    print("✅ get_cred_rcu ajouté dans include/linux/cred.h")
else:
    print("✅ get_cred_rcu déjà présent")

cred_c = ensure_file("kernel/cred.c")
content = cred_c.read_text()
if "get_cred_rcu(cred)" not in content:
    replaced = False
    for old, new in [
        ("while (!atomic_long_inc_not_zero(&((struct cred *)cred)->usage));", "while (!get_cred_rcu(cred));"),
        ("while (!atomic_inc_not_zero(&((struct cred *)cred)->usage));", "while (!get_cred_rcu(cred));"),
    ]:
        if old in content:
            content = content.replace(old, new)
            replaced = True
    if replaced:
        cred_c.write_text(content)
        print("✅ kernel/cred.c modifié")
    else:
        print("⚠️ Aucun remplacement effectué dans kernel/cred.c")
else:
    print("✅ get_cred_rcu déjà utilisé dans kernel/cred.c")
PY

# ==================== 3. CLONE KERNELSU (commit 32651c) ====================
log_info "Clone KernelSU (commit 32651c)"

if [ -d "/tmp/KernelSU" ]; then
    rm -rf /tmp/KernelSU
fi

git clone https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU

KSU_COMMIT="32651c"
if git fetch origin "$KSU_COMMIT" 2>/dev/null; then
    git checkout "$KSU_COMMIT"
    log_info "✅ Commit KernelSU checkout: $KSU_COMMIT"
else
    log_warn "Commit $KSU_COMMIT introuvable, essai avec le tag..."
    if git checkout v3.3.0-52 2>/dev/null; then
        log_info "✅ Tag v3.3.0-52 checkout"
    else
        log_err "Ni commit ni tag trouvé"
        exit 1
    fi
fi
git log --oneline -1

cd "$SCRIPT_DIR/kernel_sources"

# ==================== 4. PATCH SUSFS nGKI ====================
log_info "Préparation SusFS via nGKI_Kernel_Build"

NGKI_DIR="/tmp/nGKI_Kernel_Build"
if [ -d "$NGKI_DIR" ]; then
    rm -rf "$NGKI_DIR"
fi

git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git "$NGKI_DIR"

SUSFS_PATCH="$NGKI_DIR/Patches/Patch/susfs_patch_to_4.19.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
    log_err "Patch nGKI SusFS 4.19 introuvable : $SUSFS_PATCH"
    exit 1
fi

set +e
patch --batch --forward -p1 < "$SUSFS_PATCH" > "$SCRIPT_DIR/susfs_patch.log" 2>&1
PATCH_RC=$?
set -e

if [ "$PATCH_RC" -ne 0 ]; then
    log_warn "Le patch principal a échoué ; vérification des rejets..."
fi

REJECTS=$(find . -type f -name '*.rej' -print)
if [ -n "$REJECTS" ]; then
    log_warn "Fichiers .rej détectés :"
    echo "$REJECTS"
fi

find . -type f \( -name '*.rej' -o -name '*.orig' \) -delete

# Ajout include fs/stat.c
if [ -f "fs/stat.c" ]; then
    python3 - <<'PY'
from pathlib import Path
p = Path("fs/stat.c")
text = p.read_text()
if "#include <linux/susfs_def.h>" not in text:
    marker = "#include <asm/unistd.h>\n"
    include = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n"
    if marker in text:
        text = text.replace(marker, marker + "\n" + include, 1)
        p.write_text(text)
        print("✅ Include susfs_def.h ajouté dans fs/stat.c")
    else:
        print("⚠️ include asm/unistd.h non trouvé dans fs/stat.c")
else:
    print("✅ susfs_def.h déjà présent")
PY
else
    log_err "fs/stat.c introuvable"
    exit 1
fi

# Correction de susfs_run_sus_path_loop
if [ -f "fs/susfs.c" ]; then
    python3 - <<'PY'
from pathlib import Path
p = Path("fs/susfs.c")
text = p.read_text()
old = "static void susfs_run_sus_path_loop(void)"
new = "void susfs_run_sus_path_loop(void)"
if old in text:
    text = text.replace(old, new, 1)
    p.write_text(text)
    print("✅ susfs_run_sus_path_loop rendue globale")
else:
    print("✅ susfs_run_sus_path_loop déjà globale ou absente")
PY
else
    log_err "fs/susfs.c introuvable"
    exit 1
fi

log_info "Patch SusFS nGKI appliqué"

# ==================== 5. AJOUT DES DÉFINITIONS SUSFS MANQUANTES ====================
if [ ! -f "fs/susfs.c" ]; then
    log_err "fs/susfs.c introuvable"
    exit 1
fi

python3 - <<'PY'
import re
from pathlib import Path

p = Path("fs/susfs.c")
text = p.read_text()
added = []

checks = [
    ("bool susfs_is_current_ksu_domain(void)", "bool susfs_is_current_ksu_domain(void)\n{\n    const struct cred *cred = current_cred();\n    return (cred->uid.val == 0 || cred->uid.val == 2000);\n}\nEXPORT_SYMBOL(susfs_is_current_ksu_domain);\n"),
    ("u32 susfs_ksu_sid", "u32 susfs_ksu_sid = 0;\nEXPORT_SYMBOL(susfs_ksu_sid);\n"),
    ("u32 susfs_priv_app_sid", "u32 susfs_priv_app_sid = 0;\nEXPORT_SYMBOL(susfs_priv_app_sid);\n"),
]

for pattern, block in checks:
    if not re.search(rf"^{re.escape(pattern)}", text, re.MULTILINE):
        text += "\n/* SUSFS_FIX */\n" + block + "\n"
        added.append(pattern)

if added:
    p.write_text(text)
    print("✅ Définitions ajoutées :", ", ".join(added))
else:
    print("✅ Définitions SUSFS déjà présentes")
PY

for sym in susfs_is_current_ksu_domain susfs_ksu_sid susfs_priv_app_sid; do
    if ! grep -q "$sym" fs/susfs.c; then
        log_err "Symbole manquant dans fs/susfs.c : $sym"
        exit 1
    fi
done

log_info "Toutes les définitions manquantes sont présentes"

# ==================== 6. AJOUT SHOW_VERSION + SHOW_VARIANT ====================
python3 - <<'PY'
from pathlib import Path
p = Path("fs/susfs.c")
text = p.read_text()

if "susfs_show_version" not in text:
    text += '''
/* SUSFS_FIX: susfs_show_version */
void susfs_show_version(void __user **user_info)
{
    struct st_susfs_version info = {0};

    if (copy_from_user(&info, (struct st_susfs_version __user *)*user_info, sizeof(info))) {
        info.err = -EFAULT;
        goto out_copy_to_user;
    }

    strscpy(info.susfs_version, SUSFS_VERSION, SUSFS_MAX_VERSION_BUFSIZE - 1);
    info.err = 0;

out_copy_to_user:
    if (copy_to_user((struct st_susfs_version __user *)*user_info, &info, sizeof(info))) {
        info.err = -EFAULT;
    }
    SUSFS_LOGI("CMD_SUSFS_SHOW_VERSION -> ret: %d\\n", info.err);
}
'''
    print("✅ susfs_show_version ajouté")

if "susfs_show_variant" not in text:
    text += '''
/* SUSFS_FIX: susfs_show_variant */
void susfs_show_variant(void __user **user_info)
{
    struct st_susfs_variant info = {0};

    if (copy_from_user(&info, (struct st_susfs_variant __user *)*user_info, sizeof(info))) {
        info.err = -EFAULT;
        goto out_copy_to_user;
    }

    strscpy(info.susfs_variant, SUSFS_VARIANT, SUSFS_MAX_VARIANT_BUFSIZE - 1);
    info.err = 0;

out_copy_to_user:
    if (copy_to_user((struct st_susfs_variant __user *)*user_info, &info, sizeof(info))) {
        info.err = -EFAULT;
    }
    SUSFS_LOGI("CMD_SUSFS_SHOW_VARIANT -> ret: %d\\n", info.err);
}
'''
    print("✅ susfs_show_variant ajouté")

p.write_text(text)
PY

for sym in susfs_show_version susfs_show_variant; do
    grep -q "$sym" fs/susfs.c || {
        log_err "Symbole manquant : $sym"
        exit 1
    }
done

# ==================== 7. PATCH KernelSU :: dispatch.c pour SUSFS routing ====================
log_info "Patch du routage SusFS dans dispatch.c"

DISPATCH_C="$(find /tmp/KernelSU -name 'dispatch.c' -type f | head -n 1 || true)"
if [ -z "$DISPATCH_C" ]; then
    log_err "dispatch.c introuvable dans /tmp/KernelSU"
    exit 1
fi
log_info "dispatch.c trouvé : $DISPATCH_C"

python3 - <<'PY'
import re
from pathlib import Path

path = Path("/tmp/KernelSU/kernel/supercall/dispatch.c")
if not path.exists():
    raise FileNotFoundError(f"dispatch.c introuvable : {path}")

text = path.read_text()
orig = text

if '#include <linux/susfs.h>' not in text:
    first_include = re.search(r'(#include\s+[<"][^\n>"]+(>|")\n)', text)
    if first_include:
        insert_pos = first_include.end()
        includes = '''#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#include <linux/susfs_def.h>
#endif
'''
        text = text[:insert_pos] + includes + text[insert_pos:]
        print("✅ Includes SusFS ajoutés")

wrappers = '''
#ifdef CONFIG_KSU_SUSFS
static int susfs_wrap_show_version(void __user *arg) {
    void __user **ptr = &arg;
    susfs_show_version(ptr);
    return 0;
}
static int susfs_wrap_show_variant(void __user *arg) {
    void __user **ptr = &arg;
    susfs_show_variant(ptr);
    return 0;
}
static int susfs_wrap_enable_log(void __user *arg) {
    void __user **ptr = &arg;
    susfs_enable_log(ptr);
    return 0;
}
static int susfs_wrap_get_enabled_features(void __user *arg) {
    void __user **ptr = &arg;
    susfs_get_enabled_features(ptr);
    return 0;
}
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
static int susfs_wrap_add_sus_path(void __user *arg) {
    void __user **ptr = &arg;
    susfs_add_sus_path(ptr);
    return 0;
}
static int susfs_wrap_add_sus_path_loop(void __user *arg) {
    void __user **ptr = &arg;
    susfs_add_sus_path_loop(ptr);
    return 0;
}
#endif
#endif
'''

handlers_pattern = r'(static\s+const\s+struct\s+ksu_ioctl_cmd_map\s+ksu_ioctl_handlers)'
if re.search(handlers_pattern, text):
    match = re.search(handlers_pattern, text)
    text = text[:match.start(1)] + wrappers + '\n' + text[match.start(1):]
    print("✅ Wrappers SusFS ajoutés")

susfs_entries = '''#ifdef CONFIG_KSU_SUSFS
	{ .cmd = 0x55550, .name = "SUSFS_ADD_SUS_PATH", .handler = susfs_wrap_add_sus_path, .perm_check = manager_or_root },
	{ .cmd = 0x55553, .name = "SUSFS_ADD_SUS_PATH_LOOP", .handler = susfs_wrap_add_sus_path_loop, .perm_check = manager_or_root },
	{ .cmd = 0x555a0, .name = "SUSFS_ENABLE_LOG", .handler = susfs_wrap_enable_log, .perm_check = only_root },
	{ .cmd = 0x555e1, .name = "SUSFS_SHOW_VERSION", .handler = susfs_wrap_show_version, .perm_check = manager_or_root },
	{ .cmd = 0x555e2, .name = "SUSFS_SHOW_ENABLED_FEATURES", .handler = susfs_wrap_get_enabled_features, .perm_check = manager_or_root },
	{ .cmd = 0x555e3, .name = "SUSFS_SHOW_VARIANT", .handler = susfs_wrap_show_variant, .perm_check = manager_or_root },
#endif
'''

sentinel_pattern = r'(\{\s*\.cmd\s*=\s*0,\s*\.name\s*=\s*NULL,\s*\.handler\s*=\s*NULL)'
match = re.search(sentinel_pattern, text)
if match:
    text = text[:match.start(1)] + susfs_entries + '\t' + text[match.start(1):]
    print("✅ Entrées SusFS ajoutées dans ksu_ioctl_handlers")
else:
    print("⚠️ Sentinel non trouvé dans ksu_ioctl_handlers")

if text != orig:
    path.write_text(text)
    print("✅ dispatch.c patché")
else:
    print("⚠️ Aucune modification dans dispatch.c")
PY

if grep -q "0x555e1" /tmp/KernelSU/kernel/supercall/dispatch.c; then
    log_info "✅ CMD 0x555e1 présent dans dispatch.c"
else
    log_err "Échec du patch de dispatch.c"
    exit 1
fi

# ==================== 8. INTÉGRATION KERNELSU ====================
log_info "Intégration KernelSU"

if [ -e "drivers/kernelsu" ]; then
    rm -rf "drivers/kernelsu"
fi
ln -s /tmp/KernelSU/kernel drivers/kernelsu

if ! grep -q "obj-\$(CONFIG_KSU) += kernelsu/" drivers/Makefile 2>/dev/null; then
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
fi

if ! grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig 2>/dev/null; then
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi

log_info "KernelSU intégré"

# ==================== 9. CONFIGURATION ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

find_kernel_config() {
    local dir
    for dir in "arch/arm64/configs/vendor" "arch/arm64/configs"; do
        [ -d "$dir" ] || continue
        find "$dir" \( -name "*lito*" -o -name "*kiev*" \) 2>/dev/null | head -n 1
    done
}

CONFIG=$(find_kernel_config || true)
if [ -z "${CONFIG:-}" ]; then
    log_err "Aucune configuration kernel trouvée pour kiev/lito"
    exit 1
fi

CONFIG_NAME="${CONFIG#arch/arm64/configs/}"
log_info "Config utilisée : $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" "$CONFIG_NAME"

./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_LSM_SECURITY_HOOKS \
    --enable KSU_TAMPER_SYSCALL_TABLE \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_SUS_PATH \
    --disable KSU_SUSFS_SUS_MOUNT \
    --disable KSU_SUSFS_SUS_KSTAT \
    --disable KSU_SUSFS_SPOOF_UNAME \
    --disable KSU_SUSFS_TRY_UMOUNT \
    --disable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --disable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --disable KSU_SUSFS_OPEN_REDIRECT \
    --disable KSU_SUSFS_SUS_MAP \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --enable THREAD_INFO_IN_TASK \
    --disable CC_WERROR >/dev/null 2>&1 || true

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" olddefconfig || true

for cfg in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_ENABLE_LOG CONFIG_KSU_TAMPER_SYSCALL_TABLE; do
    if ! grep -q "^${cfg}=y$" out/.config; then
        log_err "$cfg non activé dans .config"
        exit 1
    fi
done

log_info "Profil validé : SUS_PATH + core + logs + TAMPER_SYSCALL_TABLE"

# ==================== 10. PATCH SIGNATURES MODULE ====================
if [ -f "kernel/module.c" ]; then
    sed -i 's/if (!check_version(/if (0 && !check_version(/g' kernel/module.c
fi

# ==================== 11. PATCH TACTILE ====================
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
        cat >> techpack/display/msm/msm_drv.c <<'EOF'

/* --- Début Patch Tactile --- */
#include <linux/notifier.h>
#include <linux/module.h>

static BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);

int panel_register_notifier(struct notifier_block *nb)
{
    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_register_notifier);

int panel_unregister_notifier(struct notifier_block *nb)
{
    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_unregister_notifier);

void touch_set_state(int state) { return; }
EXPORT_SYMBOL(touch_set_state);
/* --- Fin Patch Tactile --- */
EOF
        log_info "Patch tactile appliqué"
    fi
fi

# ==================== 12. COMPILATION DU NOYAU ====================
log_info "Compilation du noyau"
make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" -j"$(nproc)" Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    log_err "BUILD FAILED"
    grep -i "error:" build.log | head -n 50 || true
    exit 1
fi
log_info "Compilation noyau réussie"

# ==================== 13. COMPILATION KSUD ====================
cd "$SCRIPT_DIR"

if ! command -v cargo >/dev/null 2>&1; then
    log_info "Installation de Rust"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
fi

rustup target add aarch64-linux-android || true

NDK_ZIP=""
for ver in r27c r27b r27 r26d; do
    url="https://dl.google.com/android/repository/android-ndk-${ver}-linux.zip"
    if timeout 20 wget --spider -q "$url" 2>/dev/null; then
        NDK_ZIP="android-ndk-${ver}-linux.zip"
        wget -q "$url"
        break
    fi
done

if [ -z "$NDK_ZIP" ]; then
    log_err "Aucun NDK Android compatible trouvé"
    exit 1
fi

unzip -q "$NDK_ZIP"
NDK_DIR="$(find "$SCRIPT_DIR" -maxdepth 1 -type d -name 'android-ndk-*' | head -n 1)"
if [ -z "$NDK_DIR" ]; then
    log_err "Répertoire NDK non extrait"
    exit 1
fi

export ANDROID_NDK_ROOT="$NDK_DIR"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

if [ ! -f "$AARCH64_CLANG_PATH" ]; then
    log_err "Clang NDK introuvable : $AARCH64_CLANG_PATH"
    exit 1
fi

rm -rf "$SCRIPT_DIR/ksud-src"
git clone https://github.com/backslashxx/KernelSU.git "$SCRIPT_DIR/ksud-src"
cd "$SCRIPT_DIR/ksud-src"

KSU_COMMIT="32651c"
if git fetch origin "$KSU_COMMIT" 2>/dev/null; then
    git checkout "$KSU_COMMIT"
    log_info "✅ Commit KernelSU checkout pour ksud: $KSU_COMMIT"
else
    log_warn "Commit $KSU_COMMIT introuvable pour ksud"
fi

find "$SCRIPT_DIR/ksud-src" -name "build.rs" -exec sed -i 's/std=gnu23/std=gnu17/g' {} \; 2>/dev/null || true

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

KSUD_BINARY="$SCRIPT_DIR/ksud-src/target/aarch64-linux-android/release/ksud"
if [ ! -f "$KSUD_BINARY" ]; then
    log_err "ksud non compilé"
    exit 1
fi

cp "$KSUD_BINARY" "$SCRIPT_DIR/ksud"
chmod 755 "$SCRIPT_DIR/ksud"
log_info "ksud compilé"

# ==================== 14. TÉLÉCHARGEMENT BOOT.IMG ET REPACK ====================
cd "$SCRIPT_DIR"

download_boot_img() {
    local device="$1"
    local base_url="https://mirrorbits.lineageos.org/full/${device}"
    local dates=(
        "20260920"
        "20260913"
        "20260830"
        "20260815"
        "20260730"
        "20260715"
    )

    for d in "${dates[@]}"; do
        local url="${base_url}/${d}/boot.img"
        if timeout 30 wget --spider -q "$url" 2>/dev/null; then
            log_info "Téléchargement du boot.img depuis ${d}"
            wget -q -O boot-stock.img "$url"
            return 0
        fi
    done

    log_err "Aucun boot.img trouvé pour ${device}"
    return 1
}

download_boot_img "kiev" || exit 1

if [ ! -f "boot-stock.img" ]; then
    log_err "boot-stock.img absent après téléchargement"
    exit 1
fi

if timeout 15 wget --spider -q "https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img" 2>/dev/null; then
    wget -q -O dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img"
fi

mkdir -p repack
cp boot-stock.img repack/boot.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mkdir -p repack
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/

cd repack
./magiskboot unpack boot.img || {
    log_err "Échec de unpack boot.img"
    exit 1
}

cp "$SCRIPT_DIR/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $SCRIPT_DIR/ksud" >/dev/null 2>&1 || true

cp "$SCRIPT_DIR/ksud" local_su_binary
chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary" >/dev/null 2>&1 || true
rm -f local_su_binary

./magiskboot repack boot.img new-boot.img || {
    log_err "Échec de repack boot.img"
    exit 1
}

mv new-boot.img "$SCRIPT_DIR/final_boot.img"
cd "$SCRIPT_DIR"

# ==================== 15. MODULE USERSPACE SUSFS ====================
log_info "Préparation du module SusFS"

mkdir -p output

if [ ! -d "$SCRIPT_DIR/susfs4ksu-module" ]; then
    git clone --depth=1 --branch v1.5.2+ https://github.com/sidex15/susfs4ksu-module.git "$SCRIPT_DIR/susfs4ksu-module" || true
fi

if [ -d "$SCRIPT_DIR/susfs4ksu-module" ]; then
    (cd "$SCRIPT_DIR/susfs4ksu-module" && zip -qr "$SCRIPT_DIR/output/susfs4ksu-module.zip" . -x '.git/*' '.github/*') || true
fi

# ==================== 16. SORTIE ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SuSFS-IOCTL-boot.img
[ -f dtbo-stock.img ] && cp dtbo-stock.img output/dtbo.img
cp build.log output/ 2>/dev/null || true
cp ksud output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/

exit 0
