#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU + SusFS
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche lineage-23.2)
# KernelSU : backslashxx/KernelSU v3.3.0-52
# Hooks    : KSU_TAMPER_SYSCALL_TABLE + hooks manuels (sys_reboot)
# SusFS    : patch cyberc3dr nGKI 4.19 + routage direct dans supercall.c
# Profil   : SUS_PATH + core + logs + SUS_MOUNT + SUS_KSTAT + TRY_UMOUNT + SPOOF_UNAME + HIDE_KSU_SUSFS_SYMBOLS + SPOOF_CMDLINE_OR_BOOTCONFIG
# =============================================================================
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "=== BUILD backslashxx KernelSU v3.3.0-52 + SusFS (routage supercall.c) ==="
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

# ==================== 2. CLONE KERNELSU v3.3.0-52 (backslashxx) ====================
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

# ==================== 2a. SUSFS nGKI ====================
echo "=== Préparation SusFS via nGKI_Kernel_Build ==="
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

# ==================== 2a-ter. DÉFINITIONS MANQUANTES SUSFS ====================
echo "=== Ajout des définitions manquantes SuSFS ==="

if [ ! -f "fs/susfs.c" ]; then
    echo "❌ fs/susfs.c introuvable"
    exit 1
fi

python3 << 'PYEOF'
from pathlib import Path
import re

path = Path("fs/susfs.c")
text = path.read_text()
original_len = len(text)
added = []

if not re.search(r'^bool\s+susfs_is_current_ksu_domain\s*\(void\)', text, re.MULTILINE):
    text += '''

/* ═══ SUSFS_FIX: susfs_is_current_ksu_domain ═══ */
bool susfs_is_current_ksu_domain(void)
{
	const struct cred *cred = current_cred();
	return (cred->uid.val == 0 || cred->uid.val == 2000);
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);
'''
    added.append("susfs_is_current_ksu_domain")

if not re.search(r'^u32\s+susfs_ksu_sid\b', text, re.MULTILINE):
    text += '''

/* ═══ SUSFS_FIX: susfs_ksu_sid ═══ */
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);
'''
    added.append("susfs_ksu_sid")

if not re.search(r'^u32\s+susfs_priv_app_sid\b', text, re.MULTILINE):
    text += '''

/* ═══ SUSFS_FIX: susfs_priv_app_sid ═══ */
u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
'''
    added.append("susfs_priv_app_sid")

if added:
    path.write_text(text)
    print(f"[+] Ajouté : {', '.join(added)}")
else:
    print("[i] Aucune modification")
PYEOF

for sym in susfs_is_current_ksu_domain susfs_ksu_sid susfs_priv_app_sid; do
    grep -q "$sym" fs/susfs.c || { echo "❌ $sym manquant"; exit 1; }
done
echo "✅ Toutes les définitions présentes"

# ==================== 2a-quater. AJOUT SHOW_VERSION + SHOW_VARIANT ====================
echo "=== Ajout de susfs_show_version et susfs_show_variant ==="

python3 << 'PYEOF_SHOW'
from pathlib import Path

path = Path("fs/susfs.c")
text = path.read_text()
added = []

if 'susfs_show_version' not in text:
    text += '''

/* ═══ SUSFS_FIX: susfs_show_version ═══ */
void susfs_show_version(void __user **user_info) {
	struct st_susfs_version info = {0};

	if (copy_from_user(&info, (struct st_susfs_version __user*)*user_info, sizeof(info))) {
		info.err = -EFAULT;
		goto out_copy_to_user;
	}

	strscpy(info.susfs_version, SUSFS_VERSION, SUSFS_MAX_VERSION_BUFSIZE-1);
	info.err = 0;
out_copy_to_user:
	if (copy_to_user((struct st_susfs_version __user*)*user_info, &info, sizeof(info))) {
		info.err = -EFAULT;
	}
	SUSFS_LOGI("CMD_SUSFS_SHOW_VERSION -> ret: %d\\n", info.err);
}
'''
    added.append("susfs_show_version")

if 'susfs_show_variant' not in text:
    text += '''

/* ═══ SUSFS_FIX: susfs_show_variant ═══ */
void susfs_show_variant(void __user **user_info) {
	struct st_susfs_variant info = {0};

	if (copy_from_user(&info, (struct st_susfs_variant __user*)*user_info, sizeof(info))) {
		info.err = -EFAULT;
		goto out_copy_to_user;
	}

	strscpy(info.susfs_variant, SUSFS_VARIANT, SUSFS_MAX_VERSION_BUFSIZE-1);
	info.err = 0;
out_copy_to_user:
	if (copy_to_user((struct st_susfs_variant __user*)*user_info, &info, sizeof(info))) {
		info.err = -EFAULT;
	}
	SUSFS_LOGI("CMD_SUSFS_SHOW_VARIANT -> ret: %d\\n", info.err);
}
'''
    added.append("susfs_show_variant")

if added:
    path.write_text(text)
    print(f"[+] Ajouté : {', '.join(added)}")
else:
    print("[i] susfs_show_version et susfs_show_variant déjà présents")
PYEOF_SHOW

grep -q "susfs_show_version" fs/susfs.c || { echo "❌ susfs_show_version manquant"; exit 1; }
grep -q "susfs_show_variant" fs/susfs.c || { echo "❌ susfs_show_variant manquant"; exit 1; }
echo "✅ susfs_show_version et susfs_show_variant présents"

# ==================== 2a-quinquies. ROUTAGE SUSFS DANS supercall.c ====================
echo "=== Ajout du routage SusFS dans supercall.c (méthode directe) ==="

SUPERCALL_C="/tmp/KernelSU/kernel/supercall/supercall.c"

if [ ! -f "$SUPERCALL_C" ]; then
    echo "❌ supercall.c introuvable: $SUPERCALL_C"
    exit 1
fi

python3 << 'PYEOF_SUPERCALL'
from pathlib import Path
import re

path = Path("/tmp/KernelSU/kernel/supercall/supercall.c")
text = path.read_text()
original = text
added = []

# ═══ 1. AJOUTER LES INCLUDES SUSFS ═══
if '#include <linux/susfs_def.h>' not in text:
    match = re.search(r'(#include\s+[^\n]+\n)', text)
    if match:
        includes_block = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#include <linux/susfs_def.h>
#endif
'''
        text = text[:match.end(1)] + includes_block + text[match.end(1):]
        added.append("includes SusFS")
        print("[+] Includes SusFS ajoutés")

# ═══ 2. AJOUTER UN FALLBACK LOCAL DES CONSTANTES SUSFS ═══
if 'CMD_SUSFS_SHOW_VERSION' not in text.split('int ksu_handle_sys_reboot')[0]:
    print("[i] Constantes SusFS non trouvées avant la fonction, ajout de fallback local")
    func_match = re.search(r'(int ksu_handle_sys_reboot\s*\([^)]*\)\s*\{)', text)
    if func_match:
        local_defs = '''
#ifdef CONFIG_KSU_SUSFS
/* ═══ Fallback local pour les constantes SusFS ═══ */
#ifndef CMD_SUSFS_ADD_SUS_PATH
#define CMD_SUSFS_ADD_SUS_PATH 0x55550
#endif
#ifndef CMD_SUSFS_ADD_SUS_PATH_LOOP
#define CMD_SUSFS_ADD_SUS_PATH_LOOP 0x55553
#endif
#ifndef CMD_SUSFS_ENABLE_LOG
#define CMD_SUSFS_ENABLE_LOG 0x555a0
#endif
#ifndef CMD_SUSFS_SHOW_VERSION
#define CMD_SUSFS_SHOW_VERSION 0x555e1
#endif
#ifndef CMD_SUSFS_SHOW_ENABLED_FEATURES
#define CMD_SUSFS_SHOW_ENABLED_FEATURES 0x555e2
#endif
#ifndef CMD_SUSFS_SHOW_VARIANT
#define CMD_SUSFS_SHOW_VARIANT 0x555e3
#endif
#endif

'''
        text = text[:func_match.start()] + local_defs + text[func_match.start():]
        added.append("fallback constantes SusFS")
        print("[+] Fallback local des constantes ajouté")

# ═══ 3. INSÉRER LE ROUTAGE ═══
susfs_routing = '''
#ifdef CONFIG_KSU_SUSFS
	/* ═══ Routage SusFS (direct dans supercall.c) ═══ */
	pr_info("SUSFS_ROUTING_C: magic1=0x%x magic2=0x%x cmd=0x%x\\n", magic1, magic2, cmd);
	if (magic2 == 0xFAFAFAFA) {
		pr_info("SUSFS_ROUTING_C: detected SUSFS_MAGIC, switching on cmd=0x%x\\n", cmd);
		switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
		case CMD_SUSFS_ADD_SUS_PATH:
			susfs_add_sus_path(arg);
			return 0;
		case CMD_SUSFS_ADD_SUS_PATH_LOOP:
			susfs_add_sus_path_loop(arg);
			return 0;
#endif
		case CMD_SUSFS_ENABLE_LOG:
			susfs_enable_log(arg);
			return 0;
		case CMD_SUSFS_SHOW_VERSION:
			susfs_show_version(arg);
			return 0;
		case CMD_SUSFS_SHOW_ENABLED_FEATURES:
			susfs_get_enabled_features(arg);
			return 0;
		case CMD_SUSFS_SHOW_VARIANT:
			susfs_show_variant(arg);
			return 0;
		default:
			pr_info("susfs: unknown command 0x%x\\n", cmd);
			break;
		}
		return 0;
	}
#endif
'''

pattern = r'(\s*)toolkit_handle_sys_reboot\(magic1, magic2, cmd, arg\);'
match = re.search(pattern, text)

if match:
    indent = match.group(1)
    text = text[:match.start()] + susfs_routing + '\n' + indent + 'toolkit_handle_sys_reboot(magic1, magic2, cmd, arg);' + text[match.end():]
    added.append("routage SusFS dans supercall.c")
    print("[+] Routage inséré AVANT toolkit_handle_sys_reboot")
else:
    print("[!] Pattern toolkit_handle_sys_reboot non trouvé")

if text != original:
    path.write_text(text)
    print(f"[+] Modifications : {', '.join(added)}")
else:
    print("[!] AUCUNE MODIFICATION")

# ═══ DEBUG ═══
print("")
print("=== DEBUG supercall.c ===")
if 'SUSFS_ROUTING_C' in text:
    print("✅ SUSFS_ROUTING_C présent")
if 'CMD_SUSFS_SHOW_VERSION' in text:
    print("✅ CMD_SUSFS_SHOW_VERSION présent")
PYEOF_SUPERCALL

if grep -q "SUSFS_ROUTING_C" "$SUPERCALL_C"; then
    echo "✅ Routage SusFS ajouté dans supercall.c"
else
    echo "❌ Échec du routage dans supercall.c"
    exit 1
fi

if grep -q "CMD_SUSFS_SHOW_VERSION" "$SUPERCALL_C"; then
    echo "✅ Constantes SusFS présentes"
else
    echo "❌ Constantes SusFS manquantes"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# VÉRIFICATION FINALE
# ═══════════════════════════════════════════════════════════════
set +e

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "=== VÉRIFICATION FINALE supercall.c ==="
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "=== 1. Routage SUSFS_ROUTING_C présent ? ==="
grep -n "SUSFS_ROUTING_C" "$SUPERCALL_C" 2>/dev/null

echo ""
echo "=== 2. Constantes SusFS définies ? ==="
grep -n "CMD_SUSFS_SHOW_VERSION\|CMD_SUSFS_ADD_SUS_PATH" "$SUPERCALL_C" 2>/dev/null | head -10

echo ""
echo "=== 3. Contenu de ksu_handle_sys_reboot (30 lignes) ==="
grep -n -A30 "int ksu_handle_sys_reboot" "$SUPERCALL_C" 2>/dev/null | head -40

echo ""
echo "═══════════════════════════════════════════════════════════════"

set -e

# ==================== 2b. SYMLINK DRIVER ====================
ln -sf /tmp/KernelSU/kernel drivers/kernelsu

if [ ! -d "drivers/kernelsu" ]; then
    echo "❌ Symlink ÉCHOUÉ"
    exit 1
fi
echo "✅ Symlink OK"

# Kconfig SusFS
python3 - <<'PYEOF_KCONFIG'
from pathlib import Path

path = Path("/tmp/KernelSU/kernel/Kconfig")
text = path.read_text()
marker = "\nconfig KSU_SUSFS\n"
if marker not in text:
    block = r'''

config KSU_SUSFS
	bool "SUSFS core (nGKI 4.19)"
	depends on KSU
	default n

config KSU_SUSFS_ENABLE_LOG
	bool "SUSFS logging"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_SUS_PATH
	bool "SUSFS path hiding"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_SUS_MOUNT
	bool "SUSFS mount hiding"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_SUS_KSTAT
	bool "SUSFS kstat hiding"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_SPOOF_UNAME
	bool "SUSFS uname spoofing"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_TRY_UMOUNT
	bool "SUSFS try umount"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "SUSFS hide symbols"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "SUSFS cmdline spoofing"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_OPEN_REDIRECT
	bool "SUSFS open redirect"
	depends on KSU_SUSFS
	default n

config KSU_SUSFS_SUS_MAP
	bool "SUSFS map hiding"
	depends on KSU_SUSFS
	default n
'''
    if "\nendmenu" not in text:
        raise SystemExit("KSU Kconfig endmenu not found")
    text = text.replace("\nendmenu", block + "\nendmenu", 1)
    path.write_text(text)
    print("✅ Déclarations Kconfig SUSFS ajoutées")
else:
    print("✅ Déclarations Kconfig SUSFS déjà présentes")
PYEOF_KCONFIG

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
    --disable KSU_HACK_ARM64_BRANCH_LINK \
    --enable KSU_TAMPER_SYSCALL_TABLE \
    --disable KSU_KPROBES_KSUD \
    --enable KSU_LSM_SECURITY_HOOKS \
    --enable KSU_FEATURE_SULOG \
    --enable KSU_FEATURE_ADBROOT \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_TRY_UMOUNT \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
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

# Vérification des options essentielles
grep -q '^CONFIG_KSU_SUSFS=y$' out/.config || { echo "❌ KSU_SUSFS pas activé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS_SUS_PATH=y$' out/.config || { echo "❌ KSU_SUSFS_SUS_PATH pas activé"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS_ENABLE_LOG=y$' out/.config || { echo "❌ KSU_SUSFS_ENABLE_LOG pas activé"; exit 1; }
grep -q '^CONFIG_KSU_TAMPER_SYSCALL_TABLE=y$' out/.config || { echo "❌ KSU_TAMPER_SYSCALL_TABLE pas activé"; exit 1; }

# Vérification des nouvelles options progressives
for symbol in \
    KSU_SUSFS_SUS_MOUNT \
    KSU_SUSFS_SUS_KSTAT \
    KSU_SUSFS_SPOOF_UNAME \
    KSU_SUSFS_TRY_UMOUNT \
    KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG; do
    if grep -q "^CONFIG_${symbol}=y$" out/.config; then
        echo "✅ CONFIG_${symbol} activé"
    else
        echo "❌ CONFIG_${symbol} manquant"
        exit 1
    fi
done

# Vérification que les options risquées sont toujours désactivées
for symbol in \
    KSU_SUSFS_OPEN_REDIRECT \
    KSU_SUSFS_SUS_MAP; do
    if grep -q "^CONFIG_${symbol}=y$" out/.config; then
        echo "❌ CONFIG_${symbol} ne doit pas être activé"
        exit 1
    fi
done

# Vérification que HIDE_KSU_SUSFS_SYMBOLS est bien activé
if grep -q "^CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y$" out/.config; then
    echo "✅ CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS activé"
else
    echo "❌ CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS manquant"
    exit 1
fi
echo "✅ Profil validé : SUS_PATH + core + logs + SUS_MOUNT + SUS_KSTAT + TRY_UMOUNT + SPOOF_UNAME + HIDE_KSU_SUSFS_SYMBOLS + SPOOF_CMDLINE_OR_BOOTCONFIG"

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

# ==================== 6b. HOOKS MANUELS KERNELSU ====================
echo "=== Application des hooks manuels KernelSU ==="

if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
    sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\
#endif' kernel/reboot.c

    sed -i '/int ret = 0;/a\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\
#endif' kernel/reboot.c

    echo "✅ Hook sys_reboot inséré"
else
    echo "✅ Hook sys_reboot déjà présent"
fi

grep -c "ksu_handle_sys_reboot" kernel/reboot.c || echo "sys_reboot: absent"

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
cp final_boot.img output/Backslashxx-SuSFS-IOCTL-boot.img
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
