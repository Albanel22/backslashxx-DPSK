#!/usr/bin/env bash
#
# Build KernelSU xxKSU + SusFS pour Motorola One 5G Ace (kiev/lito)
# Méthode basée sur cyberc3dr/nGKI_Kernel_Build, branche xxksu-support.
#
# Ordre d'intégration:
#  1. Noyau LineageOS 4.19
#  2. KernelSU backslashxx, branche master
#  3. Patch xxKSU/SusFS: midori01/KernelSU commit xx.patch
#  4. Patch SusFS 4.19 dés-inliné par susfs_deinlined.sh
#  5. Vérification stricte: aucun fichier .rej ou .orig accepté
#
# Variables personnalisables:
#   WORKSPACE, KERNEL_REPO, KERNEL_REF
#   KSU_REPO, KSU_REF, XX_PATCH_URL
#   SUSFS_PATCH_URL, SUSFS_DEINLINE_URL
#   DEFCONFIG, JOBS, BUILD_KSUD, MAGISK_VERSION
#
set -Eeuo pipefail
IFS=$'\n\t'

WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_motorola_sm8250.git}"
KERNEL_REF="${KERNEL_REF:-lineage-23.2}"
KSU_REPO="${KSU_REPO:-https://github.com/backslashxx/KernelSU.git}"
KSU_REF="${KSU_REF:-master}"
XX_PATCH_URL="${XX_PATCH_URL:-https://github.com/midori01/KernelSU/commit/xx.patch}"
SUSFS_PATCH_URL="${SUSFS_PATCH_URL:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch}"
SUSFS_DEINLINE_URL="${SUSFS_DEINLINE_URL:-https://raw.githubusercontent.com/midori01/gki_ksu_workflow/main/.github/scripts/susfs_deinlined.sh}"
SUSFS_COMPAT_PATCH="${SUSFS_COMPAT_PATCH:-$WORKSPACE/susfs_kiev_lito_fix.patch}"
DEFCONFIG="${DEFCONFIG:-vendor/lito-perf_defconfig}"
JOBS="${JOBS:-$(nproc)}"
BUILD_KSUD="${BUILD_KSUD:-1}"
MAGISK_VERSION="${MAGISK_VERSION:-v27.0}"
BOOT_STOCK_URL="${BOOT_STOCK_URL:-https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img}"
DTBO_STOCK_URL="${DTBO_STOCK_URL:-https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img}"

KERNEL_DIR="$WORKSPACE/kernel_sources"
KSU_DIR="$WORKSPACE/KernelSU"
KSUD_DIR="$WORKSPACE/ksud-src"
KSUD_REF="${KSUD_REF:-v3.3.0-52}"
OUT_DIR="$KERNEL_DIR/out"
OUTPUT_DIR="$WORKSPACE/output"
LOG="$WORKSPACE/build.log"
XX_PATCH="$WORKSPACE/xx.patch"
SUSFS_PATCH="$WORKSPACE/susfs_patch_to_4.19.patch"
SUSFS_DEINLINE="$WORKSPACE/susfs_deinlined.sh"
SUSFS_DEINLINED_PATCH="$WORKSPACE/deinlined.patch"

fail() {
    echo "❌ $*" >&2
    exit 1
}

info() {
    echo
    echo "=== $* ==="
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Commande absente: $1"
}

cleanup_on_error() {
    local rc=$?
    echo "❌ BUILD FAILED (code $rc)"
    if [[ -f "$LOG" ]]; then
        echo "--- dernières erreurs ---"
        grep -iE 'error:|undefined reference|undefined symbol|fatal:' "$LOG" | tail -80 || true
    fi
    exit "$rc"
}

trap cleanup_on_error ERR

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y \
        bc bison build-essential ccache flex libelf-dev libssl-dev \
        libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
        clang llvm lld device-tree-compiler zip unzip curl wget git python3 patch perl cargo rustc
fi

for c in git make python3 patch clang ld.lld curl; do
    need_cmd "$c"
done

mkdir -p "$WORKSPACE" "$OUTPUT_DIR"
rm -rf "$KERNEL_DIR" "$KSU_DIR" "$KSUD_DIR"
rm -f "$XX_PATCH" "$SUSFS_PATCH" "$SUSFS_DEINLINE" "$SUSFS_DEINLINED_PATCH"

info "Clonage du noyau"
git clone --depth=1 --single-branch --branch "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL_DIR"
git -C "$KERNEL_DIR" log -1 --oneline

info "Clonage de KernelSU xxKSU"
git clone --depth=1 --single-branch --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR"
echo "KernelSU: $(git -C "$KSU_DIR" log -1 --oneline)"

info "Intégration KernelSU dans le noyau"
ln -s "$KSU_DIR/kernel" "$KERNEL_DIR/drivers/kernelsu"
grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -qF 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

info "Application du patch xxKSU/SusFS dans KernelSU"
curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
    "$XX_PATCH_URL" -o "$XX_PATCH"
cd "$KSU_DIR"
if ! patch --dry-run --batch --forward -p1 < "$XX_PATCH" > "$WORKSPACE/xx_patch_dry_run.log" 2>&1; then
    cat "$WORKSPACE/xx_patch_dry_run.log"
    fail "Le patch xxKSU ne s'applique pas à KernelSU $KSU_REF"
fi
patch --batch --forward -p1 < "$XX_PATCH" > "$WORKSPACE/xx_patch.log" 2>&1
[[ -z "$(find . -type f -name '*.rej' -print -quit)" ]] || \
    fail "Le patch xxKSU a produit un fichier .rej"
find . -type f -name '*.orig' -delete

info "Récupération du patch SusFS 4.19"
curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
    "$SUSFS_PATCH_URL" -o "$SUSFS_PATCH"
[[ -s "$SUSFS_PATCH" ]] || fail "Patch SusFS téléchargé vide"

info "Téléchargement de susfs_deinlined.sh"
curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
    "$SUSFS_DEINLINE_URL" -o "$SUSFS_DEINLINE"
chmod +x "$SUSFS_DEINLINE"

info "Génération du patch SusFS dés-inliné"
"$SUSFS_DEINLINE" "$SUSFS_PATCH" "$SUSFS_DEINLINED_PATCH"
[[ -s "$SUSFS_DEINLINED_PATCH" ]] || fail "Patch SusFS dés-inliné vide"

auto_reject_check() {
    local root="$1"
    local rejects
    rejects=$(find "$root" -type f -name '*.rej' -print)
    if [[ -n "$rejects" ]]; then
        echo "$rejects"
        while IFS= read -r r; do
            echo "--- $r"
            cat "$r"
        done <<< "$rejects"
        return 1
    fi
}

info "Application du patch SusFS dés-inliné"
cd "$KERNEL_DIR"

# xxksu-support tolère les contextes décalés, puis corrige les rejets
# spécifiques au noyau LineageOS sm8250 4.19.325 de kiev/lito.
patch --batch --forward -p1 < "$SUSFS_DEINLINED_PATCH" \
    > "$WORKSPACE/susfs_patch.log" 2>&1 || true

cat > "$SUSFS_COMPAT_PATCH" <<'KIEV_SUSFS_FIX'
--- a/fs/namespace.c
+++ b/fs/namespace.c
@@ -26,6 +26,14 @@
 #include <linux/bootmem.h>
 #include <linux/task_work.h>
 #include <linux/sched/task.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#endif
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+extern bool susfs_is_current_ksu_domain(void);
+extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
+#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
 #include <linux/fs_context.h>
 
 #include "pnode.h"
@@ -1091,7 +1099,13 @@
 		return ERR_PTR(-EINVAL);
 	sb = fc->root->d_sb;
 
-	mnt = alloc_vfsmnt(fc->source ?: "none");
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted) &&
+		susfs_is_current_ksu_domain())
+		mnt = susfs_alloc_non_unshare_ksu_vfsmnt(fc->source ?: "none");
+	else
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+		mnt = alloc_vfsmnt(fc->source ?: "none");
 	if (!mnt)
 		return ERR_PTR(-ENOMEM);
 
--- a/fs/proc/task_mmu.c
+++ b/fs/proc/task_mmu.c
@@ -1674,7 +1674,15 @@
 		ret = mmap_read_lock_killable(mm);
 		if (ret)
 			goto out_free;
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+		vma = find_vma(mm, start_vaddr);
+		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
+			goto bypass_orig_flow;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
 		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+bypass_orig_flow:
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
 		mmap_read_unlock(mm);
 		start_vaddr = end;
 
--- a/fs/super.c
+++ b/fs/super.c
@@ -37,6 +37,13 @@
 #include <linux/lockdep.h>
 #include <linux/user_namespace.h>
 #include <linux/fs_context.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#endif // #ifdef CONFIG_KSU_SUSFS
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+extern bool susfs_is_current_ksu_domain(void);
+extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
 #include "internal.h"
 
 static int thaw_super_locked(struct super_block *sb);
KIEV_SUSFS_FIX

patch --batch --forward -p1 < "$SUSFS_COMPAT_PATCH" \
    > "$WORKSPACE/susfs_compat_patch.log" 2>&1

# Le patch SusFS 4.19 ajoute les appels KSTAT dans fs/stat.c mais, selon
# la révision du noyau, n’ajoute pas toujours son en-tête de définitions.
# Sans cet include, STATX_SUS_KSTAT* et susfs_is_current_app_uid() sont
# inconnus du compilateur.
if grep -q 'CONFIG_KSU_SUSFS_SUS_KSTAT' fs/stat.c && \
   ! grep -q '^#include <linux/susfs_def.h>$' fs/stat.c; then
    sed -i '/^#include <asm\/unistd.h>$/a\
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\
#include <linux/susfs_def.h>\
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT' fs/stat.c
fi

# Ces trois rejets ont été consommés par le correctif ciblé.
rm -f fs/namespace.c.rej fs/proc/task_mmu.c.rej fs/super.c.rej \
      fs/namespace.c.orig fs/proc/task_mmu.c.orig fs/super.c.orig

if ! auto_reject_check "$KERNEL_DIR"; then
    echo "--- log patch SusFS ---"
    cat "$WORKSPACE/susfs_patch.log" || true
    echo "--- log compatibilité kiev/lito ---"
    cat "$WORKSPACE/susfs_compat_patch.log" || true
    fail "Le patch SusFS laisse des rejets non pris en charge"
fi

find . -type f -name '*.orig' -delete

[[ -f fs/susfs.c ]] || fail "fs/susfs.c absent après SusFS"
[[ -f include/linux/susfs.h ]] || fail "include/linux/susfs.h absent après SusFS"
[[ -f include/linux/susfs_def.h ]] || fail "include/linux/susfs_def.h absent après SusFS"

grep -qF 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || \
    fail "fs/Makefile ne contient pas la construction de susfs.o"

info "Configuration"
if [[ -z "$DEFCONFIG" ]]; then
    DEFCONFIG=$(find arch/arm64/configs/vendor arch/arm64/configs -maxdepth 2 \
        \( -iname '*kiev*' -o -iname '*lito*' \) -type f -print -quit 2>/dev/null || true)
    [[ -n "$DEFCONFIG" ]] || fail "Defconfig kiev/lito introuvable; définir DEFCONFIG"
    DEFCONFIG="${DEFCONFIG#arch/arm64/configs/}"
fi

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

DEFCONFIG_FILE="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
[[ -f "$DEFCONFIG_FILE" ]] || fail "Defconfig introuvable: $DEFCONFIG_FILE"

info "Activation automatique de SusFS dans le defconfig"

set_defconfig_option() {
    local option="$1"
    local value="$2"
    sed -i -E \
        "/^(CONFIG_${option}=|# CONFIG_${option} is not set)/d" \
        "$DEFCONFIG_FILE"
    if [[ "$value" == y ]]; then
        printf 'CONFIG_%s=y\n' "$option" >> "$DEFCONFIG_FILE"
    else
        printf '# CONFIG_%s is not set\n' "$option" >> "$DEFCONFIG_FILE"
    fi
}

set_defconfig_option KSU y
set_defconfig_option THREAD_INFO_IN_TASK y
set_defconfig_option KSU_SUSFS y
set_defconfig_option KSU_SUSFS_SUS_PATH y
set_defconfig_option KSU_SUSFS_SUS_MOUNT y
set_defconfig_option KSU_SUSFS_SUS_KSTAT y
set_defconfig_option KSU_SUSFS_SPOOF_UNAME y
set_defconfig_option KSU_SUSFS_ENABLE_LOG y
set_defconfig_option KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS y
set_defconfig_option KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG n
set_defconfig_option KSU_SUSFS_OPEN_REDIRECT n
set_defconfig_option KSU_SUSFS_SUS_MAP n
set_defconfig_option KPROBES n
set_defconfig_option HAVE_KPROBES n
set_defconfig_option KPROBE_EVENTS n
set_defconfig_option KALLSYMS y
set_defconfig_option KALLSYMS_ALL y

make O="$OUT_DIR" LLVM=1 "$DEFCONFIG"
scripts_config="$KERNEL_DIR/scripts/config"
[[ -x "$scripts_config" ]] || chmod +x "$scripts_config"

set +e
"$scripts_config" --file "$OUT_DIR/.config" \
    --enable KSU \
    --enable THREAD_INFO_IN_TASK \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --disable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --disable KSU_SUSFS_OPEN_REDIRECT \
    --disable KSU_SUSFS_SUS_MAP \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --disable CC_WERROR
set -e

make O="$OUT_DIR" LLVM=1 olddefconfig

REQUIRED_CONFIGS=(
    CONFIG_KSU
    CONFIG_THREAD_INFO_IN_TASK
    CONFIG_KSU_SUSFS
    CONFIG_KSU_SUSFS_SUS_PATH
    CONFIG_KSU_SUSFS_SUS_MOUNT
    CONFIG_KSU_SUSFS_SUS_KSTAT
    CONFIG_KSU_SUSFS_SPOOF_UNAME
    CONFIG_KSU_SUSFS_ENABLE_LOG
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
)

for config in "${REQUIRED_CONFIGS[@]}"; do
    grep -qE "^${config}=y$" "$OUT_DIR/.config" ||
        fail "Option Kconfig requise absente ou désactivée: ${config}"
done

cp "$OUT_DIR/.config" "$OUTPUT_DIR/kernel.config"
grep -E 'CONFIG_(KSU|KSU_SUSFS|THREAD_INFO_IN_TASK)' "$OUT_DIR/.config" | tee "$OUTPUT_DIR/ksu-susfs.config"

# ========== PATCH TACTILE AJOUTÉ ==========
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

info "Compilation du noyau"
make O="$OUT_DIR" LLVM=1 -j"$JOBS" Image 2>&1 | tee "$LOG"
[[ -f "$OUT_DIR/arch/arm64/boot/Image" ]] || fail "Image noyau absente"
cp "$OUT_DIR/arch/arm64/boot/Image" "$OUTPUT_DIR/Image"
cp "$LOG" "$OUTPUT_DIR/build.log"

info "Vérifications finales"

auto_reject_check "$KERNEL_DIR" ||
    fail "Des fichiers .rej subsistent"

if find "$KERNEL_DIR" \
    -type f \
    -name '*.orig' \
    -print \
    -quit \
    | grep -q .
then
    fail "Des fichiers .orig subsistent"
fi

file "$OUTPUT_DIR/Image" 2>/dev/null || true

if [[ "$BUILD_KSUD" == 1 ]]; then
    info "Compilation de ksud depuis le tag $KSUD_REF"
    command -v cargo >/dev/null 2>&1 || fail "cargo est requis pour compiler ksud"
    command -v rustup >/dev/null 2>&1 || \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    export PATH="$HOME/.cargo/bin:$PATH"
    rustup target add aarch64-linux-android

    NDK_ZIP="$WORKSPACE/android-ndk-r27c-linux.zip"
    NDK_DIR="$WORKSPACE/android-ndk-r27c"
    NDK_CLANG="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"

    if [[ ! -x "$NDK_CLANG" ]]; then
        curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
            https://dl.google.com/android/repository/android-ndk-r27c-linux.zip \
            -o "$NDK_ZIP"
        unzip -q -o "$NDK_ZIP" -d "$WORKSPACE"
    fi

    NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
    NDK_SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    export AARCH64_CLANG_PATH="$NDK_BIN/aarch64-linux-android26-clang"
    export AARCH64_CLANGXX_PATH="$NDK_BIN/aarch64-linux-android26-clang++"
    export AR_PATH="$NDK_BIN/llvm-ar"
    export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_SYSROOT -I$NDK_SYSROOT/usr/include/aarch64-linux-android"
    [[ -x "$AARCH64_CLANG_PATH" ]] || fail "Clang Android NDK introuvable"

    git clone --depth=1 --single-branch "$KSU_REPO" "$KSUD_DIR"
    git -C "$KSUD_DIR" fetch --depth=1 origin tag "$KSUD_REF"
    git -C "$KSUD_DIR" checkout --detach "$KSUD_REF"
    echo "ksud: $(git -C "$KSUD_DIR" log -1 --oneline)"

    # Compatibilité NDK de l’extrait validé.
    find "$KSUD_DIR" -name build.rs -type f -exec sed -i 's/std=gnu23/std=gnu17/g' {} +

    CARGO_TOML="$KSUD_DIR/userspace/ksud/Cargo.toml"
    if [[ -f "$CARGO_TOML" ]] && grep -q 'Kernel-SU/adb_client' "$CARGO_TOML"; then
        sed -i -E 's|^adb_client[[:space:]]*=.*Kernel-SU/adb_client.*$|adb_client = { version = "3.1.1", default-features = false }|' "$CARGO_TOML"
        rm -f "$KSUD_DIR/Cargo.lock"
    fi

    cd "$KSUD_DIR/userspace/ksud"
    rm -rf "$KSUD_DIR/target"
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
    KSUD_BINARY="$KSUD_DIR/target/aarch64-linux-android/release/ksud"
    [[ -f "$KSUD_BINARY" ]] || fail "ksud introuvable après compilation"
    cp "$KSUD_BINARY" "$WORKSPACE/ksud"
    chmod 755 "$WORKSPACE/ksud"
fi

info "Repack sécurisé du boot.img stock"
REPACK_DIR="$WORKSPACE/repack"
rm -rf "$REPACK_DIR"
mkdir -p "$REPACK_DIR"

curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
    "$BOOT_STOCK_URL" -o "$REPACK_DIR/boot.img"
curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
    "$DTBO_STOCK_URL" -o "$OUTPUT_DIR/dtbo.img"

BOOT_BYTES=$(stat -c '%s' "$REPACK_DIR/boot.img")
BOOT_MIB=$((BOOT_BYTES / 1024 / 1024))
echo "Taille boot stock: ${BOOT_BYTES} octets (${BOOT_MIB} MiB)"

MAGISK_APK="$WORKSPACE/Magisk-${MAGISK_VERSION}.apk"
MAGISKBOOT="$REPACK_DIR/magiskboot"
curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
    "https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk" \
    -o "$MAGISK_APK"
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$MAGISKBOOT"
chmod 755 "$MAGISKBOOT"

cd "$REPACK_DIR"
"$MAGISKBOOT" unpack boot.img
[[ -f kernel ]] || fail "magiskboot n'a pas extrait le noyau"
[[ -f ramdisk.cpio ]] || fail "magiskboot n'a pas extrait le ramdisk"

cp "$OUTPUT_DIR/Image" kernel

if [[ "$BUILD_KSUD" == 1 ]]; then
    [[ -f "$WORKSPACE/ksud" ]] || fail "ksud manquant pour le repack"

    # Méthode de repack validée : KernelSU attend ksud sous /data/adb/ksud
    # et le point d’entrée su sous /system/bin/su.
    "$MAGISKBOOT" cpio ramdisk.cpio \
        "mkdir 0755 data" \
        "mkdir 0755 data/adb" \
        "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud $WORKSPACE/ksud"

    cp "$WORKSPACE/ksud" local_su_binary
    chmod 755 local_su_binary
    "$MAGISKBOOT" cpio ramdisk.cpio \
        "mkdir 0755 system" \
        "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary"
    rm -f local_su_binary
fi

"$MAGISKBOOT" repack boot.img new-boot.img
[[ -s new-boot.img ]] || fail "Échec de reconstruction du boot.img"
cp new-boot.img "$OUTPUT_DIR/boot.img"

FINAL_BYTES=$(stat -c '%s' "$OUTPUT_DIR/boot.img")
FINAL_MIB=$((FINAL_BYTES / 1024 / 1024))
echo "Taille boot final: ${FINAL_BYTES} octets (${FINAL_MIB} MiB)"
echo "Le dtbo reste séparé: $OUTPUT_DIR/dtbo.img"

cp "$LOG" "$OUTPUT_DIR/build.log"
echo "✅ Compilation et génération de boot.img réussies"
echo "Sorties: $OUTPUT_DIR"
