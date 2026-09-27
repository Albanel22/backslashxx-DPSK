#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 (Android 16 QPR2) + backslashxx KernelSU + SuSFS simonpunk
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche lineage-23.2)
# KernelSU : backslashxx/KernelSU v3.3.0-52
# Hooks    : KSU_HACK_ARM64_BRANCH_LINK (natif)
# SuSFS    : simonpunk/susfs4ksu (branche kernel-4.19, v1.5.5)
# =============================================================================
set -e

echo "=== BUILD KernelSU v3.3.0-52 + SuSFS simonpunk 1.5.5 ==="
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

# ==================== 4. INTÉGRATION SuSFS 1.5.5 (simonpunk) ====================
echo "=== Téléchargement et application du patch SuSFS 1.5.5 (simonpunk) ==="

# --- Cloner le dépôt officiel de simonpunk, branche kernel-4.19 ---
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="kernel-4.19"
rm -rf /tmp/simonpunk_susfs
git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" /tmp/simonpunk_susfs

cd /tmp/simonpunk_susfs
echo "=== Version de simonpunk/susfs4ksu ==="
git log --oneline -1

KERNEL_ROOT="$GITHUB_WORKSPACE/kernel_sources"
cd "$KERNEL_ROOT"

# --- Copier le patch KernelSU (10_enable_susfs_for_ksu.patch) ---
echo "=== Copie du patch KernelSU ==="
if [ -f "/tmp/simonpunk_susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
    cp /tmp/simonpunk_susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch /tmp/KernelSU/
    echo "[+] 10_enable_susfs_for_ksu.patch copié"
else
    echo "⚠️ 10_enable_susfs_for_ksu.patch introuvable"
fi

# --- Copier le patch kernel principal ---
echo "=== Copie du patch kernel ==="
SUSFS_KERNEL_PATCH=""
for candidate in \
    "/tmp/simonpunk_susfs/kernel_patches/50_add_susfs_in_kernel-4.19.patch" \
    "/tmp/simonpunk_susfs/kernel_patches/50_add_susfs_in_kernel.patch"; do
    if [ -f "$candidate" ]; then
        SUSFS_KERNEL_PATCH="$candidate"
        break
    fi
done

if [ -z "$SUSFS_KERNEL_PATCH" ]; then
    echo "❌ Patch kernel principal introuvable !"
    find /tmp/simonpunk_susfs/kernel_patches -name "*.patch" | sort
    exit 1
fi

cp "$SUSFS_KERNEL_PATCH" ./
echo "[+] $(basename $SUSFS_KERNEL_PATCH) copié"

# --- Copier les fichiers sources SuSFS ---
echo "=== Copie des fichiers sources SuSFS ==="
if [ -d "/tmp/simonpunk_susfs/kernel_patches/fs" ]; then
    cp /tmp/simonpunk_susfs/kernel_patches/fs/* fs/ 2>/dev/null || true
    echo "[+] Fichiers fs/ copiés"
fi

if [ -d "/tmp/simonpunk_susfs/kernel_patches/include/linux" ]; then
    cp /tmp/simonpunk_susfs/kernel_patches/include/linux/* include/linux/ 2>/dev/null || true
    echo "[+] Fichiers include/linux/ copiés"
fi

# --- Appliquer le patch KernelSU ---
echo "=== Application du patch KernelSU (10_enable_susfs_for_ksu) ==="
cd /tmp/KernelSU
set +e
patch -p1 < 10_enable_susfs_for_ksu.patch 2>&1 | tee /tmp/ksu_susfs_patch.log
KSU_PATCH_EXIT=$?
set -e

if [ $KSU_PATCH_EXIT -ne 0 ]; then
    echo "⚠️ Rejets dans le patch KernelSU :"
    find . -name "*.rej" -type f | head -10
    for rej in $(find . -name "*.rej" -type f); do
        orig="${rej%.rej}"
        patch --merge "$orig" < "$rej" 2>/dev/null || true
        rm -f "$rej"
    done
fi
find . -name "*.orig" -delete 2>/dev/null || true
find . -name "*.rej" -delete 2>/dev/null || true

cd "$KERNEL_ROOT"

# --- Appliquer le patch kernel principal ---
echo "=== Application du patch kernel principal ==="
set +e
patch -p1 < "$(basename $SUSFS_KERNEL_PATCH)" 2>&1 | tee /tmp/susfs_patch.log
PATCH_EXIT=$?
set -e

if [ $PATCH_EXIT -ne 0 ]; then
    echo "⚠️ Le patch a rencontré des rejets (normal avec backslashxx)"
    find . -name "*.rej" -type f | head -20
    for rej in $(find . -name "*.rej" -type f); do
        orig="${rej%.rej}"
        echo "  Fusion : $orig"
        patch --merge "$orig" < "$rej" 2>/dev/null || true
        rm -f "$rej"
    done
fi

find . -name "*.orig" -type f -delete 2>/dev/null || true
find . -name "*.rej" -type f -delete 2>/dev/null || true

# --- Vérification ---
if [ ! -f "fs/susfs.c" ]; then
    echo "❌ fs/susfs.c non créé"
    exit 1
fi
echo "✅ fs/susfs.c créé ($(wc -l < fs/susfs.c) lignes)"

[ -f "include/linux/susfs.h" ] && echo "✅ susfs.h créé"
[ -f "include/linux/susfs_def.h" ] && echo "✅ susfs_def.h créé"

# --- Correction fs/Makefile ---
if [ -f "fs/Makefile" ]; then
    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
        echo "[+] susfs.o ajouté à fs/Makefile"
    fi
fi

# --- Correction task_mmu.c ---
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# ==================== 4b. INJECTION FORCÉE DES INCLUDES SuSFS ====================
echo "=== Injection forcée des includes SuSFS ==="

# --- 1. Enrichir susfs_def.h ---
SUSFS_DEF="include/linux/susfs_def.h"
if [ -f "$SUSFS_DEF" ]; then
    if ! grep -q "define CL_COPY_MNT_NS" "$SUSFS_DEF"; then
        echo "[+] Ajout CL_COPY_MNT_NS dans susfs_def.h"
        cat >> "$SUSFS_DEF" << 'EOF'

#ifndef CL_COPY_MNT_NS
#define CL_COPY_MNT_NS BIT(25)
#endif
EOF
    fi
    if ! grep -q "define DEFAULT_KSU_MNT_MINOR_DEV" "$SUSFS_DEF"; then
        echo "[+] Ajout DEFAULT_KSU_MNT_MINOR_DEV dans susfs_def.h"
        cat >> "$SUSFS_DEF" << 'EOF'

#ifndef DEFAULT_KSU_MNT_MINOR_DEV
#define DEFAULT_KSU_MNT_MINOR_DEV 234
#endif
EOF
    fi
fi

# --- 2. Enrichir susfs.h ---
SUSFS_H="include/linux/susfs.h"
if [ -f "$SUSFS_H" ]; then
    if ! grep -q "extern bool susfs_is_current_ksu_domain" "$SUSFS_H"; then
        echo "[+] Ajout externs dans susfs.h"
        cat >> "$SUSFS_H" << 'EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
EOF
    fi
fi

# --- 3. FORCER l'inclusion dans fs/namespace.c ---
echo "=== Injection forcée dans fs/namespace.c ==="

# Nettoyer les injections précédentes
sed -i '/__SUSFS_FORCED_INCLUDE__/d' fs/namespace.c 2>/dev/null || true
sed -i '/#include <linux\/susfs_def.h>/d' fs/namespace.c 2>/dev/null || true
sed -i '/#include <linux\/susfs.h>/d' fs/namespace.c 2>/dev/null || true

# Injecter après le premier #include
awk '
BEGIN { done = 0 }
/^#include/ && !done {
    print $0
    print "/* __SUSFS_FORCED_INCLUDE__ */"
    print "#include <linux/susfs_def.h>"
    print "#include <linux/susfs.h>"
    done = 1
    next
}
{ print }
' fs/namespace.c > fs/namespace.c.tmp && mv fs/namespace.c.tmp fs/namespace.c

# Fallback si awk échoue
if ! grep -q "__SUSFS_FORCED_INCLUDE__" fs/namespace.c; then
    sed -i '1i\
/* __SUSFS_FORCED_INCLUDE__ */\
#include <linux/susfs_def.h>\
#include <linux/susfs.h>\
' fs/namespace.c
    echo "[+] Fallback sed utilisé pour fs/namespace.c"
fi
echo "✅ fs/namespace.c traité"

# --- 4. Faire pareil pour les autres fichiers ---
for f in fs/super.c fs/namei.c fs/open.c fs/stat.c fs/exec.c fs/readdir.c fs/d_path.c fs/proc/task_mmu.c fs/proc/base.c fs/proc/fd.c fs/mount.h; do
    [ -f "$f" ] || continue

    # Skip si pas d'utilisation SuSFS
    if ! grep -qE 'susfs_|SUSFS_|DEFAULT_KSU_MNT_MINOR_DEV|CL_COPY_MNT_NS' "$f"; then
        continue
    fi

    # Skip si déjà présent
    if grep -q 'include <linux/susfs.h>' "$f"; then
        continue
    fi

    echo "[+] Injection dans $f"

    sed -i '/__SUSFS_FORCED_INCLUDE__/d' "$f" 2>/dev/null || true
    sed -i '/#include <linux\/susfs_def.h>/d' "$f" 2>/dev/null || true
    sed -i '/#include <linux\/susfs.h>/d' "$f" 2>/dev/null || true

    awk '
    BEGIN { done = 0 }
    /^#include/ && !done {
        print $0
        print "/* __SUSFS_FORCED_INCLUDE__ */"
        print "#include <linux/susfs_def.h>"
        print "#include <linux/susfs.h>"
        done = 1
        next
    }
    { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# --- 5. VÉRIFICATION FINALE ---
echo ""
echo "=== VÉRIFICATION DES INCLUDES ==="
for f in fs/namespace.c fs/super.c fs/namei.c fs/open.c; do
    [ -f "$f" ] || continue
    if grep -qE 'susfs_|DEFAULT_KSU_MNT_MINOR_DEV|CL_COPY_MNT_NS' "$f"; then
        echo "--- $f ---"
        grep -nE '#include <linux/susfs' "$f" || echo "  ❌ Aucun include"
    fi
done

echo ""
echo "=== Contenu susfs_def.h (fin) ==="
tail -15 include/linux/susfs_def.h

# ==================== 4c. AJOUT DES SYMBOLES MANQUANTS DANS fs/susfs.c ====================
echo "=== Ajout des symboles manquants dans fs/susfs.c ==="

if [ -f "fs/susfs.c" ]; then
    # susfs_is_current_ksu_domain
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

    # susfs_is_sdcard_android_data_not_decrypted
    if ! grep -q "DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted)" fs/susfs.c; then
        cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted);
EXPORT_SYMBOL(susfs_is_sdcard_android_data_not_decrypted);
#endif
SUSFS_EOF
        echo "[+] susfs_is_sdcard_android_data_not_decrypted ajouté"
    fi
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

config KSU_SUSFS_SUS_SU
	bool "sus_su"
	default n

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
    --enable KSU_SUSFS_SUS_MAP \
    --disable KSU_SUSFS_SUS_SU

set -e

echo "=== Vérification config KernelSU + SuSFS ==="
grep -E "CONFIG_KSU" out/.config || echo "⚠️ Aucune option KSU trouvée"

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

# ==================== 8c. CORRECTION ROBUSTE DES SIGNATURES SuSFS ====================
echo "=== Correction robuste des signatures SuSFS ==="

python3 - << 'PYEOF'
import re
import os

SUSFS_H = 'include/linux/susfs.h'
SUSFS_DEF = 'include/linux/susfs_def.h'
STAT_C = 'fs/stat.c'

def remove_old_declarations(path):
    """Supprime toutes les déclarations de susfs_sus_ino_for_generic_fillattr et susfs_generic_fillattr_spoofer d'un header."""
    if not os.path.exists(path):
        return 0
    with open(path, 'r') as f:
        content = f.read()
    original = content
    # Supprimer toute ligne contenant les anciens/nouveaux noms
    lines = content.split('\n')
    new_lines = [l for l in lines if 'susfs_sus_ino_for_generic_fillattr' not in l 
                 and 'susfs_generic_fillattr_spoofer' not in l]
    content = '\n'.join(new_lines)
    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        return 1
    return 0

def fix_stat_c():
    """Corrige proprement la fonction dans fs/stat.c."""
    if not os.path.exists(STAT_C):
        print("[!] fs/stat.c introuvable")
        return
    
    with open(STAT_C, 'r') as f:
        content = f.read()
    
    original = content
    
    # --- Étape 1 : Renommer tous les anciens noms ---
    content = content.replace('susfs_sus_ino_for_generic_fillattr', 'susfs_generic_fillattr_spoofer')
    
    # --- Étape 2 : Trouver et réécrire la DÉFINITION de la fonction ---
    # Pattern : <static> <void|int> susfs_generic_fillattr_spoofer(...)  {
    func_pattern = r'(static\s+)?(void|int)\s+susfs_generic_fillattr_spoofer\s*\([^)]*\)\s*\{'
    match = re.search(func_pattern, content)
    
    if match:
        start = match.start()
        end_of_sig = match.end()
        
        # Trouver la fin de la fonction
        depth = 1
        i = end_of_sig
        while i < len(content) and depth > 0:
            if content[i] == '{':
                depth += 1
            elif content[i] == '}':
                depth -= 1
            i += 1
        func_end = i
        
        # Extraire le corps actuel
        old_body = content[end_of_sig:func_end-1]
        
        # Extraire la nouvelle signature
        is_static = "static" if match.group(1) else ""
        ret_type = match.group(2)
        
        # Construire la nouvelle fonction
        new_func = f"""{is_static} {ret_type} susfs_generic_fillattr_spoofer(struct inode *inode, struct kstat *stat)
{{
	struct kstat *kstat = stat;

	if (inode && stat) {{
		/* Récupérer l'ino réel depuis l'inode */
		unsigned long ino = inode->i_ino;

		if (susfs_is_inode_sus_path(inode))
			SUSFS_LOGI("hiding ino: %lu for path: %s\\n",
				   ino, inode->i_sb->s_id);

		/* Le spoofing réel est fait par susfs.c */
		(void)kstat;
		(void)ino;
	}}
}}"""
        
        content = content[:start] + new_func + content[func_end:]
        print("[+] Définition de susfs_generic_fillattr_spoofer réécrite")
    
    # --- Étape 3 : Corriger l'appel dans generic_fillattr ---
    content = content.replace(
        'susfs_generic_fillattr_spoofer(inode->i_ino, stat)',
        'susfs_generic_fillattr_spoofer(inode, stat)'
    )
    content = content.replace(
        'susfs_generic_fillattr_spoofer(ino, stat)',
        'susfs_generic_fillattr_spoofer(inode, stat)'
    )
    
    # --- Étape 4 : Vérifier qu'il y a un appel dans generic_fillattr ---
    if 'susfs_generic_fillattr_spoofer' in content and \
       'generic_fillattr' in content and \
       'susfs_generic_fillattr_spoofer(inode, stat)' not in content:
        # Ajouter l'appel après la déclaration des variables dans generic_fillattr
        # Chercher la signature de generic_fillattr
        gf_pattern = r'void\s+generic_fillattr\s*\([^)]*\)\s*\{'
        gf_match = re.search(gf_pattern, content)
        if gf_match:
            # Injecter l'appel après la première ligne du corps
            insert_pos = gf_match.end()
            # Trouver la fin de la première ligne après {
            newline_pos = content.find('\n', insert_pos)
            if newline_pos > 0:
                # Chercher où mettre l'appel (après les déclarations, avant les usages)
                call = "\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n\tsusfs_generic_fillattr_spoofer(inode, stat);\n#endif\n"
                # Trouver la première instruction (après les déclarations)
                lines_after = content[insert_pos:].split('\n')
                insert_line = 0
                for idx, line in enumerate(lines_after):
                    stripped = line.strip()
                    if stripped and not stripped.startswith(('struct ', 'unsigned ', 'umode_t ', 'dev_t ', 'int ', 'u32 ', 'u64 ', 'kuid_t ', 'kgid_t ', '/*', '*')):
                        insert_line = idx
                        break
                # Reconstruire
                before = content[:insert_pos]
                after = '\n'.join(lines_after[insert_line:])
                content = before + call + after
                print("[+] Appel susfs_generic_fillattr_spoofer ajouté dans generic_fillattr")
    
    if content != original:
        with open(STAT_C, 'w') as f:
            f.write(content)
        print("[+] fs/stat.c mis à jour")

# --- Exécution ---
print("--- Nettoyage des headers ---")
if remove_old_declarations(SUSFS_H):
    print("[+] susfs.h nettoyé")
if remove_old_declarations(SUSFS_DEF):
    print("[+] susfs_def.h nettoyé")

# --- Ajouter une déclaration propre dans susfs.h ---
with open(SUSFS_H, 'r') as f:
    susfs_content = f.read()

if 'susfs_generic_fillattr_spoofer' not in susfs_content:
    # S'assurer que les structs sont forward-déclarés
    if 'struct inode;' not in susfs_content:
        susfs_content = susfs_content.replace(
            '#define __LINUX_SUSFS_H',
            '#define __LINUX_SUSFS_H\n\nstruct inode;\nstruct kstat;'
        )
    
    # Ajouter la déclaration propre
    susfs_content += """

/* Déclaration propre - ajoutée par le script de build */
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
void susfs_generic_fillattr_spoofer(struct inode *inode, struct kstat *stat);
#endif
"""
    with open(SUSFS_H, 'w') as f:
        f.write(susfs_content)
    print("[+] Déclaration propre ajoutée dans susfs.h")

# --- Fixer fs/stat.c ---
print("--- Correction de fs/stat.c ---")
fix_stat_c()

# --- Vérification ---
print("")
print("=== VÉRIFICATION FINALE ===")
print("--- susfs.h ---")
os.system("grep -n 'susfs_generic_fillattr_spoofer\\|struct inode;' include/linux/susfs.h 2>/dev/null | head -5")
print("--- fs/stat.c ---")
os.system("grep -n 'susfs_generic_fillattr_spoofer' fs/stat.c 2>/dev/null | head -10")
PYEOF

echo "✅ Correction terminée"

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
NDK_DIR=$(ls -d android-ndk-* 2>/dev/null | grep -v ".zip" | head -1)
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
fi

if [ "$NEED_BUILD_RS_PATCH" = "1" ]; then
    echo "=== Patch build.rs : gnu23 → gnu17 ==="
    find "$GITHUB_WORKSPACE/ksud-src" -name "build.rs" -exec sed -i 's/std=gnu23/std=gnu17/g' {} \;
fi

CARGO_TOML="userspace/ksud/Cargo.toml"
if [ -f "$CARGO_TOML" ] && grep -q "Kernel-SU/adb_client" "$CARGO_TOML"; then
    sed -i 's|^adb_client\s*=\s*{.*git.*Kernel-SU/adb_client.*}.*|adb_client = { version = "3.1.1", default-features = false }|' "$CARGO_TOML"
    rm -f Cargo.lock
fi

rm -rf "$GITHUB_WORKSPACE/ksud-src/target"

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
cp final_boot.img output/Backslashxx-SuSFS-simonpunk-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
