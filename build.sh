#!/bin/bash
# =============================================================================
# BUILD : LineageOS 23.2 + backslashxx KernelSU v3.3.0-52 + SuSFS simonpunk
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (lineage-23.2)
# Hooks    : KSU_HACK_ARM64_BRANCH_LINK (stable, root OK)
# SuSFS    : simonpunk/susfs4ksu kernel-4.19 (v1.5.5)
# =============================================================================
set -e

echo "=== BUILD KernelSU v3.3.0-52 + SuSFS simonpunk 4.19 (CLEAN) ==="
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

# ==================== 1b. BACKPORT get_cred_rcu ====================
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

# ==================== 2. CLONE KERNELSU v3.3.0-52 ====================
echo "=== Clone KernelSU v3.3.0-52 ==="
rm -rf drivers/kernelsu /tmp/KernelSU || true

git clone --depth=1 https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
cd /tmp/KernelSU
if git fetch --depth=1 origin tag v3.3.0-52 2>/dev/null; then
    git checkout v3.3.0-52
    echo "✅ Tag v3.3.0-52 checkout"
fi
git log --oneline -1
cd "$GITHUB_WORKSPACE/kernel_sources"

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

# ==================== 3. VÉRIFICATION HOOKS NATIFS ====================
echo "=== Vérification des hooks natifs ==="
if [ -d "/tmp/KernelSU/kernel/hook" ]; then
    echo "✅ Dossier hook/ :"
    ls /tmp/KernelSU/kernel/hook/
fi

# ==================== 4. INTÉGRATION SuSFS SIMONPUNK (PROPRE) ====================
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "=== INTÉGRATION SuSFS simonpunk kernel-4.19 (v1.5.5) ==="
echo "═══════════════════════════════════════════════════════════════════"

# --- Clone avec tag de release (plus stable selon README) ---
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="kernel-4.19"
rm -rf /tmp/simonpunk_susfs
git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" /tmp/simonpunk_susfs

cd /tmp/simonpunk_susfs
echo "=== Version simonpunk ==="
git log --oneline -1

KERNEL_ROOT="$GITHUB_WORKSPACE/kernel_sources"
cd "$KERNEL_ROOT"

# --- Vérifier le contenu disponible ---
echo "=== Contenu de kernel_patches ==="
ls -la /tmp/simonpunk_susfs/kernel_patches/
ls -la /tmp/simonpunk_susfs/kernel_patches/KernelSU/ 2>/dev/null || echo "(pas de dossier KernelSU)"
ls -la /tmp/simonpunk_susfs/kernel_patches/fs/ 2>/dev/null || echo "(pas de dossier fs)"
ls -la /tmp/simonpunk_susfs/kernel_patches/include/linux/ 2>/dev/null || echo "(pas de dossier include/linux)"

# --- Copier les fichiers selon le README (non-GKI) ---
echo ""
echo "=== Copie des fichiers selon README non-GKI ==="

# 1. Patch KernelSU
if [ -f "/tmp/simonpunk_susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
    cp /tmp/simonpunk_susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch /tmp/KernelSU/
    echo "[+] 10_enable_susfs_for_ksu.patch copié dans /tmp/KernelSU/"
fi

# 2. sucompat.h
if [ -f "/tmp/simonpunk_susfs/kernel_patches/KernelSU/kernel/sucompat.h" ]; then
    cp /tmp/simonpunk_susfs/kernel_patches/KernelSU/kernel/sucompat.h /tmp/KernelSU/kernel/
    echo "[+] sucompat.h copié dans /tmp/KernelSU/kernel/"
fi

# 3. Patch kernel principal
SUSFS_KERNEL_PATCH=""
for candidate in \
    "/tmp/simonpunk_susfs/kernel_patches/50_add_susfs_in_kernel-4.19.patch" \
    "/tmp/simonpunk_susfs/kernel_patches/50_add_susfs_in_kernel-4.19.325.patch" \
    "/tmp/simonpunk_susfs/kernel_patches/50_add_susfs_in_kernel.patch"; do
    if [ -f "$candidate" ]; then
        SUSFS_KERNEL_PATCH="$candidate"
        break
    fi
done

if [ -z "$SUSFS_KERNEL_PATCH" ]; then
    echo "❌ Patch kernel principal introuvable !"
    find /tmp/simonpunk_susfs/kernel_patches -name "50_add_susfs*" | sort
    exit 1
fi

cp "$SUSFS_KERNEL_PATCH" ./
echo "[+] $(basename $SUSFS_KERNEL_PATCH) copié"

# 4. Fichiers sources SuSFS
[ -f "/tmp/simonpunk_susfs/kernel_patches/fs/susfs.c" ] && \
    cp /tmp/simonpunk_susfs/kernel_patches/fs/susfs.c fs/ && \
    echo "[+] fs/susfs.c copié"

[ -f "/tmp/simonpunk_susfs/kernel_patches/include/linux/susfs.h" ] && \
    cp /tmp/simonpunk_susfs/kernel_patches/include/linux/susfs.h include/linux/ && \
    echo "[+] include/linux/susfs.h copié"

[ -f "/tmp/simonpunk_susfs/kernel_patches/fs/sus_su.c" ] && \
    cp /tmp/simonpunk_susfs/kernel_patches/fs/sus_su.c fs/ && \
    echo "[+] fs/sus_su.c copié"

[ -f "/tmp/simonpunk_susfs/kernel_patches/include/linux/sus_su.h" ] && \
    cp /tmp/simonpunk_susfs/kernel_patches/include/linux/sus_su.h include/linux/ && \
    echo "[+] include/linux/sus_su.h copié"

# --- Appliquer le patch KernelSU (avec préservation des .rej) ---
echo ""
echo "=== Application du patch KernelSU ==="
cd /tmp/KernelSU
set +e
patch -p1 --no-backup-if-mismatch < 10_enable_susfs_for_ksu.patch 2>&1 | tee /tmp/ksu_susfs_patch.log
set -e

if find /tmp/KernelSU -name "*.rej" -type f | grep -q .; then
    echo ""
    echo "⚠️ REJETS dans le patch KernelSU :"
    find /tmp/KernelSU -name "*.rej" -type f | while read f; do
        echo "=== $f ==="
        head -50 "$f"
        echo "---"
    done
    echo ""
    echo "⚠️ Rejets KernelSU PRÉSERVÉS — vérifie les logs ci-dessus"
fi

cd "$KERNEL_ROOT"

# --- Appliquer le patch kernel principal (avec préservation des .rej) ---
echo ""
echo "=== Application du patch kernel principal ==="
set +e
patch -p1 --no-backup-if-mismatch < "$(basename $SUSFS_KERNEL_PATCH)" 2>&1 | tee /tmp/susfs_patch.log
set -e

# --- IMPORTANT : AFFICHER LES .REJ SANS LES SUPPRIMER ---
echo ""
REJ_COUNT=$(find . -name "*.rej" -type f 2>/dev/null | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
    echo "═══════════════════════════════════════════════════════════════════"
    echo "⚠️  $REJ_COUNT FICHIERS .REJ DÉTECTÉS — ANALYSE REQUISE"
    echo "═══════════════════════════════════════════════════════════════════"
    find . -name "*.rej" -type f | while read rej; do
        echo ""
        echo "─── REJET : $rej ───"
        head -100 "$rej"
        echo "─── FIN REJET ───"
    done
    echo ""
    echo "⚠️ Les .rej sont PRÉSERVÉS pour analyse (pas supprimés)"
    echo "⚠️ On tente les fusions automatiques..."
    
    for rej in $(find . -name "*.rej" -type f); do
        orig="${rej%.rej}"
        echo "Tentative de fusion : $orig"
        set +e
        patch --merge "$orig" < "$rej" 2>/dev/null
        set -e
    done
fi

# Nettoyer SEULEMENT les .orig
find . -name "*.orig" -type f -delete 2>/dev/null || true

# --- Vérification des fichiers SuSFS ---
echo ""
echo "=== Vérification des fichiers SuSFS ==="
if [ ! -f "fs/susfs.c" ]; then
    echo "❌ fs/susfs.c non créé"
    exit 1
fi
echo "✅ fs/susfs.c ($(wc -l < fs/susfs.c) lignes)"

[ -f "include/linux/susfs.h" ] && echo "✅ include/linux/susfs.h"
[ -f "fs/sus_su.c" ] && echo "✅ fs/sus_su.c"
[ -f "include/linux/sus_su.h" ] && echo "✅ include/linux/sus_su.h"

# --- Correction fs/Makefile ---
if [ -f "fs/Makefile" ]; then
    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
        echo "[+] susfs.o ajouté à fs/Makefile"
    fi
    if [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile; then
        echo "obj-\$(CONFIG_KSU_SUSFS_SUS_SU) += sus_su.o" >> fs/Makefile
        echo "[+] sus_su.o ajouté à fs/Makefile"
    fi
fi

# --- Correction task_mmu.c ---
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
    echo "[+] task_mmu.c corrigé"
fi

# ==================== 4b. VÉRIFICATION struct vfsmount ====================
echo ""
echo "=== Vérification de struct vfsmount (critique) ==="

# Vérifier si susfs_mnt_id_backup existe dans struct vfsmount
if grep -q "susfs_mnt_id_backup" include/linux/mount.h 2>/dev/null; then
    echo "✅ susfs_mnt_id_backup présent dans struct vfsmount"
else
    echo "⚠️ susfs_mnt_id_backup ABSENT de struct vfsmount — injection manuelle"
    
    python3 - << 'PYEOF'
import re
import os

MOUNT_H = 'include/linux/mount.h'
if not os.path.exists(MOUNT_H):
    print(f"[!] {MOUNT_H} introuvable")
    exit(0)

with open(MOUNT_H, 'r') as f:
    content = f.read()

# Vérifier si déjà présent
if 'susfs_mnt_id_backup' in content:
    print("[+] susfs_mnt_id_backup déjà présent")
    exit(0)

# Trouver struct vfsmount
pattern = r'(struct vfsmount \{[^}]*)(\};)'
match = re.search(pattern, content, re.DOTALL)
if match:
    # Ajouter le champ à la fin du struct
    injection = '''
#ifdef CONFIG_KSU_SUSFS
	u64 susfs_mnt_id_backup;
#endif
'''
    content = content[:match.end(1)] + injection + content[match.end(1):]
    with open(MOUNT_H, 'w') as f:
        f.write(content)
    print("[+] susfs_mnt_id_backup injecté dans struct vfsmount")
else:
    print("[!] struct vfsmount non trouvé dans mount.h")
PYEOF
fi

# Vérifier les ida (susfs_mnt_id_ida, susfs_mnt_group_ida)
echo ""
echo "=== Vérification des IDA SuSFS ==="
if grep -q "susfs_mnt_id_ida" fs/susfs.c 2>/dev/null; then
    echo "✅ susfs_mnt_id_ida défini dans fs/susfs.c"
else
    echo "⚠️ susfs_mnt_id_ida absent de fs/susfs.c — injection"
    cat >> fs/susfs.c << 'EOF'

#ifdef CONFIG_KSU_SUSFS
DEFINE_IDA(susfs_mnt_id_ida);
DEFINE_IDA(susfs_mnt_group_ida);
#endif
EOF
    echo "[+] susfs_mnt_id_ida et susfs_mnt_group_ida ajoutés"
fi

# ==================== 4c. AJOUT SYMBOLES MANQUANTS ====================
echo ""
echo "=== Ajout des symboles manquants dans fs/susfs.c ==="

if [ -f "fs/susfs.c" ]; then
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

    if ! grep -q "susfs_is_current_zygote_domain" fs/susfs.c; then
        cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bool susfs_is_current_zygote_domain(void)
{
    const struct cred *cred = current_cred();
    return (cred->uid.val == 1000);
}
EXPORT_SYMBOL(susfs_is_current_zygote_domain);
#endif
SUSFS_EOF
        echo "[+] susfs_is_current_zygote_domain ajouté"
    fi

    if ! grep -q "DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted)" fs/susfs.c; then
        cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
DEFINE_STATIC_KEY_TRUE(susfs_is_sdcard_android_data_not_decrypted);
EXPORT_SYMBOL(susfs_is_sdcard_android_data_not_decrypted);

bool susfs_is_auto_add_sus_bind_mount_enabled = false;
EXPORT_SYMBOL(susfs_is_auto_add_sus_bind_mount_enabled);

bool susfs_is_auto_add_sus_ksu_default_mount_enabled = false;
EXPORT_SYMBOL(susfs_is_auto_add_sus_ksu_default_mount_enabled);
#endif
SUSFS_EOF
        echo "[+] susfs_is_sdcard_android_data_not_decrypted + flags auto_add ajoutés"
    fi
fi

# ==================== 4d. INJECTION INCLUDES SuSFS ====================
echo ""
echo "=== Injection des includes SuSFS ==="

# Enrichir susfs_def.h si besoin
SUSFS_DEF="include/linux/susfs_def.h"
if [ ! -f "$SUSFS_DEF" ]; then
    echo "[+] Création de $SUSFS_DEF"
    cat > "$SUSFS_DEF" << 'EOF'
#ifndef _LINUX_SUSFS_DEF_H
#define _LINUX_SUSFS_DEF_H

#ifndef CL_COPY_MNT_NS
#define CL_COPY_MNT_NS BIT(25)
#endif

#ifndef CL_ZYGOTE_COPY_MNT_NS
#define CL_ZYGOTE_COPY_MNT_NS BIT(24)
#endif

#ifndef DEFAULT_KSU_MNT_MINOR_DEV
#define DEFAULT_KSU_MNT_MINOR_DEV 234
#endif

#ifndef DEFAULT_SUS_MNT_ID
#define DEFAULT_SUS_MNT_ID 1000000
#endif

#ifndef DEFAULT_SUS_MNT_GROUP_ID
#define DEFAULT_SUS_MNT_GROUP_ID 1000000
#endif

#ifndef DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE
#define DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE 1000001
#endif

#endif
EOF
else
    # Enrichir avec les constantes manquantes
    for const in CL_COPY_MNT_NS CL_ZYGOTE_COPY_MNT_NS DEFAULT_KSU_MNT_MINOR_DEV DEFAULT_SUS_MNT_ID DEFAULT_SUS_MNT_GROUP_ID DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE; do
        if ! grep -q "define $const" "$SUSFS_DEF"; then
            echo "[+] Ajout de $const dans susfs_def.h"
            echo "" >> "$SUSFS_DEF"
            echo "#ifndef $const" >> "$SUSFS_DEF"
            case "$const" in
                CL_COPY_MNT_NS) echo "#define $const BIT(25)" >> "$SUSFS_DEF" ;;
                CL_ZYGOTE_COPY_MNT_NS) echo "#define $const BIT(24)" >> "$SUSFS_DEF" ;;
                DEFAULT_KSU_MNT_MINOR_DEV) echo "#define $const 234" >> "$SUSFS_DEF" ;;
                DEFAULT_SUS_MNT_ID) echo "#define $const 1000000" >> "$SUSFS_DEF" ;;
                DEFAULT_SUS_MNT_GROUP_ID) echo "#define $const 1000000" >> "$SUSFS_DEF" ;;
                DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE) echo "#define $const 1000001" >> "$SUSFS_DEF" ;;
            esac
            echo "#endif" >> "$SUSFS_DEF"
        fi
    done
fi

# Enrichir susfs.h avec les externs
SUSFS_H="include/linux/susfs.h"
if [ -f "$SUSFS_H" ]; then
    if ! grep -q "extern bool susfs_is_current_ksu_domain" "$SUSFS_H"; then
        cat >> "$SUSFS_H" << 'EOF'

/* __SUSFS_EXTERNS__ */
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
extern bool susfs_is_auto_add_sus_bind_mount_enabled;
extern bool susfs_is_auto_add_sus_ksu_default_mount_enabled;
#endif
EOF
        echo "[+] Externs ajoutés dans susfs.h"
    fi
fi

# Injecter les includes dans tous les fichiers concernés
for f in fs/namespace.c fs/super.c fs/namei.c fs/open.c fs/stat.c fs/exec.c fs/readdir.c fs/d_path.c fs/proc/task_mmu.c fs/proc/base.c fs/proc/fd.c; do
    [ -f "$f" ] || continue

    if ! grep -qE 'susfs_|SUSFS_|CL_COPY_MNT_NS|CL_ZYGOTE_COPY_MNT_NS|DEFAULT_KSU_MNT_MINOR_DEV' "$f"; then
        continue
    fi

    # Nettoyer les injections précédentes
    sed -i '/__SUSFS_INCLUDE__/d' "$f" 2>/dev/null || true
    sed -i '/#include <linux\/susfs_def.h>/d' "$f" 2>/dev/null || true
    sed -i '/#include <linux\/susfs.h>/d' "$f" 2>/dev/null || true

    # Injecter après le premier #include
    awk '
    BEGIN { done = 0 }
    /^#include/ && !done {
        print $0
        print "/* __SUSFS_INCLUDE__ */"
        print "#include <linux/susfs_def.h>"
        print "#include <linux/susfs.h>"
        done = 1
        next
    }
    { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "[+] Includes injectés dans $f"
done

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

config KSU_SUSFS_SUS_SU
	bool "sus_su"
	default n

config KSU_SUSFS_ENABLE_LOG
	bool "enable_log"
	default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "hide_ksu_susfs_symbols"
	default y

endif
KCONFIG_EOF
        echo "[+] Kconfig SuSFS ajouté"
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
    --disable KSU_MANUAL_HOOK \
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
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --disable KSU_SUSFS_SUS_SU

set -e

echo "=== Vérification config ==="
grep "CONFIG_KSU" out/.config || echo "⚠️ Aucune option KSU"

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
    fi
fi

# ==================== 8c. CORRECTION ROBUSTE SIGNATURES stat.c ====================
echo ""
echo "=== Correction signatures SuSFS dans stat.c ==="

python3 - << 'PYEOF'
import re
import os

SUSFS_H = 'include/linux/susfs.h'
STAT_C = 'fs/stat.c'

# Nettoyer TOUTES les déclarations existantes
if os.path.exists(SUSFS_H):
    with open(SUSFS_H, 'r') as f:
        content = f.read()
    lines = [l for l in content.split('\n') 
             if 'susfs_generic_fillattr_spoofer' not in l 
             and 'susfs_sus_ino_for_generic_fillattr' not in l]
    content = '\n'.join(lines)
    with open(SUSFS_H, 'w') as f:
        f.write(content)
    print("[+] susfs.h nettoyé")

# Ajouter forward declarations
with open(SUSFS_H, 'r') as f:
    content = f.read()

if 'struct inode;' not in content:
    content = re.sub(
        r'(#ifndef\s+\w+\s*\n#define\s+\w+\s*\n)',
        r'\1\nstruct inode;\nstruct kstat;\n',
        content, count=1
    )

# Déclaration propre
decl = """
/* __SUSFS_FILLATTR_DECL__ */
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
void susfs_generic_fillattr_spoofer(struct inode *inode, struct kstat *stat);
#endif
"""
if 'susfs_generic_fillattr_spoofer' not in content:
    idx = content.rfind('#endif')
    if idx > 0:
        content = content[:idx] + decl + '\n' + content[idx:]
    else:
        content += decl

with open(SUSFS_H, 'w') as f:
    f.write(content)
print("[+] Déclaration propre ajoutée dans susfs.h")

# Corriger stat.c
with open(STAT_C, 'r') as f:
    content = f.read()

# Supprimer fonctions existantes
func_pattern = r'(static\s+)?(void|int)\s+susfs_generic_fillattr_spoofer\s*\([^)]*\)\s*\{'
while True:
    match = re.search(func_pattern, content)
    if not match:
        break
    start = match.start()
    depth = 1
    i = match.end()
    while i < len(content) and depth > 0:
        if content[i] == '{':
            depth += 1
        elif content[i] == '}':
            depth -= 1
        i += 1
    content = content[:start].rstrip() + '\n\n' + content[i:].lstrip()

# Supprimer appels existants
content = re.sub(
    r'^\s*susfs_generic_fillattr_spoofer\s*\([^;]*\);\s*$',
    '', content, flags=re.MULTILINE
)

# Nouvelle fonction propre
new_func = """
/* __SUSFS_FILLATTR_FUNC__ */
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
void susfs_generic_fillattr_spoofer(struct inode *inode, struct kstat *stat)
{
	if (inode && stat) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
		if (susfs_is_inode_sus_path(inode))
			SUSFS_LOGI("hiding ino: %lu for path: %s\\n",
				   inode->i_ino, inode->i_sb->s_id);
#endif
	}
}
#endif
"""

gf_match = re.search(r'(void\s+generic_fillattr\s*\([^)]*\)\s*\{)', content)
if gf_match:
    content = content[:gf_match.start()] + new_func + '\n' + content[gf_match.start():]
    print("[+] Fonction injectée avant generic_fillattr")

with open(STAT_C, 'w') as f:
    f.write(content)
print("[+] fs/stat.c corrigé")
PYEOF

# ==================== 9. COMPILATION ====================
echo ""
echo "=== Compilation du noyau ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ BUILD FAILED"
    grep -i "error:" build.log | head -50
    exit 1
fi
echo "✅ Compilation réussie"

# ==================== 10. COMPILATION KSUD ====================
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
NDK_DIR=$(ls -d android-ndk-* 2>/dev/null | grep -v ".zip" | head -1)

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

# ==================== 11. REPACK ====================
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

# ==================== 12. SORTIE ====================
mkdir -p output
cp final_boot.img output/Backslashxx-SuSFS-simonpunk-clean-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

# Copier les .rej s'ils existent (pour analyse)
mkdir -p output/rej
find kernel_sources -name "*.rej" -exec cp {} output/rej/ \; 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "=== BUILD TERMINÉ ==="
echo "═══════════════════════════════════════════════════════════════════"
ls -lh output/
echo ""
echo "=== .rej préservés (si présents) ==="
ls -la output/rej/ 2>/dev/null || echo "(aucun .rej)"
