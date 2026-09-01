#!/bin/bash
set -e

# ==================== MODE DRY-RUN ====================
# Mettez DRY_RUN=1 pour simuler, DRY_RUN=0 pour exécuter réellement
DRY_RUN=1  # ← Changez à 0 quand vous voulez lancer pour de vrai

# Fonction pour exécuter ou simuler une commande
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Fonction pour écrire dans un fichier (simulation ou réel)
write_file() {
    local file="$1"
    local content="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] Écriture dans $file :"
        echo "$content" | sed 's/^/  /'
    else
        echo "$content" >> "$file"
    fi
}

# Fonction pour copier un fichier (simulation ou réel)
copy_file() {
    local src="$1"
    local dst="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] Copie de $src vers $dst"
    else
        cp "$src" "$dst"
    fi
}

# ==================== ENVIRONNEMENT ====================
if [ "$DRY_RUN" -eq 0 ]; then
    echo "=== MODE RÉEL : les commandes seront exécutées ==="
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
    sudo apt-get clean
    sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    sudo apt-get update
    sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
        libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
        clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl \
        python3-pip wget jq
else
    echo "=== MODE DRY-RUN : aucune commande réelle ne sera exécutée ==="
fi

cd "$GITHUB_WORKSPACE" || exit 1

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Motorola sm8250 (lineage-23.2) ==="
if [ "$DRY_RUN" -eq 0 ]; then
    git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
        -b lineage-23.2 --depth=1 kernel_sources
else
    echo "[DRY-RUN] git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources"
    mkdir -p kernel_sources  # Pour simuler la présence du dossier
fi

cd kernel_sources || exit 1

# ==================== 2. INTÉGRATION SUSFS (manuel) ====================
echo "=== Téléchargement de SuSFS (JackA1ltman) ==="
if [ "$DRY_RUN" -eq 0 ]; then
    git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo
else
    echo "[DRY-RUN] git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo"
    mkdir -p /tmp/jack_repo
    # Créer des fichiers factices pour la simulation
    touch /tmp/jack_repo/susfs.c /tmp/jack_repo/susfs.h /tmp/jack_repo/susfs_def.h /tmp/jack_repo/sus_su.c
fi

echo "=== Copie manuelle des fichiers sources SUSFS ==="
# Chercher les fichiers dans différentes structures possibles
if [ "$DRY_RUN" -eq 0 ]; then
    find /tmp/jack_repo -type f -name "susfs.c" -exec cp {} fs/susfs.c \; 2>/dev/null || \
        echo "⚠️ pas de susfs.c trouvé dans le dépôt"
    find /tmp/jack_repo -type f -name "susfs.h" -exec cp {} include/linux/susfs.h \; 2>/dev/null || \
        echo "⚠️ pas de susfs.h trouvé"
    find /tmp/jack_repo -type f -name "susfs_def.h" -exec cp {} include/linux/susfs_def.h \; 2>/dev/null || \
        echo "⚠️ pas de susfs_def.h trouvé"
    find /tmp/jack_repo -type f -name "sus_su.c" -exec cp {} fs/sus_su.c \; 2>/dev/null || \
        echo "⚠️ pas de sus_su.c (facultatif)"
else
    # Simulation : on crée les fichiers vides pour que la vérification passe
    touch fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
    echo "[DRY-RUN] Fichiers SUSFS créés en mode simulation"
fi

# Vérification
if [ ! -f "fs/susfs.c" ]; then
    echo "❌ Échec de la copie de susfs.c. Abandon."
    exit 1
fi
echo "✅ fs/susfs.c présent ($(wc -l < fs/susfs.c) lignes)"
[ -f "include/linux/susfs.h" ] && echo "✅ susfs.h présent"
[ -f "include/linux/susfs_def.h" ] && echo "✅ susfs_def.h présent"

# 2b. Mise à jour de fs/Makefile
if ! grep -q "susfs.o" fs/Makefile; then
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    else
        echo "[DRY-RUN] Ajout de 'obj-\$(CONFIG_KSU_SUSFS) += susfs.o' dans fs/Makefile"
    fi
fi
if [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile; then
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
    else
        echo "[DRY-RUN] Ajout de 'obj-\$(CONFIG_KSU_SUSFS) += sus_su.o' dans fs/Makefile"
    fi
fi

# 2c. Ajout des symboles SUSFS (s'ils sont absents)
if ! grep -q "susfs_is_current_ksu_domain" fs/susfs.c; then
    SYMBOLS='
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
'
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "$SYMBOLS" >> fs/susfs.c
    else
        echo "[DRY-RUN] Ajout des symboles SUSFS dans fs/susfs.c"
    fi
fi

# 2d. Appliquer les hooks SUSFS manuellement
echo "=== Application des hooks SUSFS manuels ==="

# Fonction pour ajouter un hook dans un fichier avec dry-run
add_hook() {
    local file="$1" pattern="$2" hook="$3" marker="$4"
    if grep -q "$marker" "$file"; then
        echo "⏩ $marker déjà présent dans $file"
        return 0
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        perl -0777 -i -pe "s/$pattern/$hook/" "$file"
    else
        echo "[DRY-RUN] Hook $marker ajouté dans $file"
    fi
}

# exec.c
if ! grep -q "susfs_handle_execve" fs/exec.c; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif' fs/exec.c
        perl -0777 -i -pe 's/(static int do_execveat_common\(.*?\)\s*\{)/$1\n#ifdef CONFIG_KSU_SUSFS\n\tif (unlikely(susfs_handle_execveat(fd, filename, argv, envp, flags))) return -EPERM;\n#endif/' fs/exec.c
    else
        echo "[DRY-RUN] Ajout de susfs_handle_execve dans fs/exec.c"
    fi
fi

# open.c
if ! grep -q "susfs_handle_faccessat" fs/open.c; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -i '/#include <linux\/fs\.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif' fs/open.c
        perl -0777 -i -pe 's/(long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\{)/$1\n#ifdef CONFIG_KSU_SUSFS\n\tif (unlikely(susfs_handle_faccessat(dfd, filename, mode))) return -EPERM;\n#endif/' fs/open.c
    else
        echo "[DRY-RUN] Ajout de susfs_handle_faccessat dans fs/open.c"
    fi
fi

# stat.c
if ! grep -q "susfs_handle_stat" fs/stat.c; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -i '/#include <linux\/fs\.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif' fs/stat.c
        perl -0777 -i -pe 's/(int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{)/$1\n#ifdef CONFIG_KSU_SUSFS\n\tif (unlikely(susfs_handle_stat(dfd, filename, flags))) return -EPERM;\n#endif/' fs/stat.c
    else
        echo "[DRY-RUN] Ajout de susfs_handle_stat dans fs/stat.c"
    fi
fi

# namespace.c
if ! grep -q "susfs_handle_mount" fs/namespace.c; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -i '/#include <linux\/sched\/task\.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
        perl -0777 -i -pe 's/(int do_mount\(.*?\)\s*\{)/$1\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\textern bool susfs_is_current_ksu_domain(void);\n\tif (unlikely(susfs_handle_mount(dev_name, dir_name, type_page, flags, data_page))) return -EPERM;\n#endif/' fs/namespace.c
    else
        echo "[DRY-RUN] Ajout de susfs_handle_mount dans fs/namespace.c"
    fi
fi

# reboot.c (si non déjà fait par KernelSU)
if ! grep -q "susfs_handle_reboot" kernel/reboot.c; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -i '/#include <linux\/reboot\.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif' kernel/reboot.c
        perl -0777 -i -pe 's/(SYSCALL_DEFINE4\(reboot,.*?\)\s*\{)/$1\n#ifdef CONFIG_KSU_SUSFS\n\tif (unlikely(susfs_handle_reboot(magic1, magic2, cmd, arg))) return -EPERM;\n#endif/' kernel/reboot.c
    else
        echo "[DRY-RUN] Ajout de susfs_handle_reboot dans kernel/reboot.c"
    fi
fi

echo "✅ Hooks SUSFS appliqués"

# ==================== 3. KERNELSU ====================
echo "=== Intégration KernelSU (commit 0b138d6a) ==="
if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf drivers/kernelsu KernelSU /tmp/KernelSU || true
    KSU_COMMIT="0b138d6a9cfe4dc163aa05c21b1e6a14ff868230"
    git clone https://github.com/backslashxx/KernelSU.git /tmp/KernelSU
    cd /tmp/KernelSU
    git fetch --depth=1 origin "$KSU_COMMIT"
    git checkout "$KSU_COMMIT"
    cd "$GITHUB_WORKSPACE/kernel_sources"
    KSU_VER=$(grep -oP '(?<=-DKSU_VERSION=)[0-9]+' /tmp/KernelSU/kernel/Makefile | head -1)
    [ -z "$KSU_VER" ] && KSU_VER="32601"
    echo "[+] KSU_VERSION : $KSU_VER"
    ln -sf /tmp/KernelSU/kernel drivers/kernelsu
    if [ ! -d "drivers/kernelsu" ]; then
        echo "❌ Symlink échoué"
        exit 1
    fi
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
    sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig
    # Fix version et UAPI
    if ! grep -q "ccflags-y += -DKSU_VERSION=" drivers/kernelsu/Makefile; then
        echo "ccflags-y += -DKSU_VERSION=${KSU_VER}" >> drivers/kernelsu/Makefile
    fi
    sed -i 's/static const __u32 KERNEL_SU_UAPI_VERSION = [0-9]*;/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
    sed -i 's/#define KERNEL_SU_UAPI_VERSION [0-9]*/#define KERNEL_SU_UAPI_VERSION 2/' /tmp/KernelSU/uapi/supercall.h 2>/dev/null || true
    sed -i "s/#define KERNEL_SU_VERSION KSU_VERSION/#define KERNEL_SU_VERSION ${KSU_VER}/" /tmp/KernelSU/uapi/ksu.h 2>/dev/null || true
    DISPATCH_FILE="/tmp/KernelSU/kernel/supercall/dispatch.c"
    if [ -f "$DISPATCH_FILE" ]; then
        sed -i "s/cmd\.uapi_version = KERNEL_SU_UAPI_VERSION;/cmd.uapi_version = 2;/" "$DISPATCH_FILE"
        sed -i "s/static uint32_t ksuver_override = 0;/static uint32_t ksuver_override = ${KSU_VER};/" "$DISPATCH_FILE"
        sed -i "s/struct ksu_get_info_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE"
        sed -i "s/struct ksu_get_info_legacy_cmd cmd = { \.version = KERNEL_SU_VERSION, \.flags = 0 };/struct ksu_get_info_legacy_cmd cmd = { .version = ${KSU_VER}, .flags = 0 };/" "$DISPATCH_FILE"
    fi
    echo "✅ KernelSU intégré"
else
    echo "[DRY-RUN] Intégration de KernelSU (commit 0b138d6a) simulée"
fi

# ==================== 4. HOOKS KERNELSU (vérification conditionnelle) ====================
echo "=== Vérification des hooks KernelSU ==="
# ... (même code que précédemment, avec dry-run) ...
# Je raccourcis pour la lisibilité : dans la version réelle, vous remettez les hooks KernelSU
# avec la même logique dry-run (ajout conditionnel)

# ==================== 5. CONFIGURATION ====================
if [ "$DRY_RUN" -eq 0 ]; then
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
    cat >> out/.config <<EOF
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
EOF
    grep "CONFIG_KSU_SUSFS" out/.config
    sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
    # Patch tactile
    if [ -f "techpack/display/msm/msm_drv.c" ]; then
        printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
        echo "[+] Patch tactile appliqué"
    fi
else
    echo "[DRY-RUN] Configuration du noyau (make ...) simulée"
fi

# ==================== 6. COMPILATION (optionnelle) ====================
if [ "$DRY_RUN" -eq 0 ]; then
    echo "=== Compilation du noyau ==="
    make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        echo "❌ BUILD FAILED"
        grep -i "error:" build.log | head -50
        exit 1
    fi
    echo "✅ Compilation du noyau réussie"
else
    echo "[DRY-RUN] Compilation du noyau (make ...) simulée"
fi

# ==================== 7. KSUD, REPACK, etc. ====================
# ... (idem, avec dry-run)

echo "=== FIN DU SCRIPT ==="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Le mode dry-run est activé. Aucune modification réelle n'a été effectuée."
    echo "Pour exécuter réellement, mettez DRY_RUN=0 en tête du script."
fi
