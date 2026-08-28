#!/bin/bash
set -e

echo "============================================================"
echo " Backslashxx KernelSU - Kernel 4.19 / LineageOS 23.2"
echo " Motorola kiev / ARM64"
echo "============================================================"

df -h

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. DEPENDANCES
# ============================================================

echo "=== Installation des dépendances ==="

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean

sudo sed -i \
    's/azure.archive.ubuntu.com/archive.ubuntu.com/g' \
    /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update

sudo apt-get install -y \
    bc \
    bison \
    build-essential \
    ccache \
    flex \
    libelf-dev \
    libssl-dev \
    libncurses-dev \
    gcc-aarch64-linux-gnu \
    gcc-arm-linux-gnueabi \
    clang \
    llvm \
    lld \
    device-tree-compiler \
    zip \
    unzip \
    curl \
    git \
    python3 \
    perl \
    wget \
    mkbootimg

cd "$GITHUB_WORKSPACE"

rm -rf output
mkdir -p output


# ============================================================
# 2. KERNEL LINEAGEOS 23.2
# ============================================================

echo ""
echo "=== Clone kernel LineageOS 23.2 ==="

rm -rf kernel_sources

git clone \
    --depth=1 \
    -b lineage-23.2 \
    https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    kernel_sources

cd kernel_sources

echo "Kernel commit:"
git rev-parse HEAD

echo "Kernel:"
git log -1 --oneline


# ============================================================
# 3. BACKSLASHXX SETUP.SH
# ============================================================

echo ""
echo "=== Intégration Backslashxx KernelSU ==="

rm -rf KernelSU
rm -rf drivers/kernelsu

KSU_REF="${KSU_REF:-master}"

echo "KSU_REF = $KSU_REF"

curl -fL \
    https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh \
    -o /tmp/backslashxx-setup.sh

chmod +x /tmp/backslashxx-setup.sh

/tmp/backslashxx-setup.sh "$KSU_REF"


# ============================================================
# 4. VERIFICATION SETUP
# ============================================================

echo ""
echo "=== Vérification intégration ==="

if [ ! -d KernelSU ]; then
    echo "ERROR: KernelSU/ absent"
    exit 1
fi

if [ ! -L drivers/kernelsu ]; then
    echo "ERROR: drivers/kernelsu n'est pas un symlink"
    ls -la drivers/kernelsu 2>/dev/null || true
    exit 1
fi

echo "drivers/kernelsu ->"
readlink -f drivers/kernelsu

KSU_COMMIT="$(cd KernelSU && git rev-parse HEAD)"
KSU_VERSION="$(cd KernelSU && git describe --tags --always --dirty 2>/dev/null || true)"

echo ""
echo "KernelSU commit:"
echo "$KSU_COMMIT"

echo "KernelSU version:"
echo "$KSU_VERSION"


# ============================================================
# 5. VERIFICATION KCONFIG KSU
# ============================================================

echo ""
echo "=== Inspection Kconfig KernelSU ==="

if [ -f KernelSU/kernel/Kconfig ]; then
    grep -nE \
        'KSU|SULOG|sulog' \
        KernelSU/kernel/Kconfig \
        | head -100 \
        || true
fi


# ============================================================
# 6. DESACTIVATION SU LOG
#
# Le kernel 4.19 / toolchain actuel ne fournit pas :
#
#     __aarch64_cas4_rel
#
# L'erreur provient de write_sulog() / xarray.c.
#
# Nous désactivons le composant SU log pour le premier
# kernel fonctionnel.
# ============================================================

echo ""
echo "=== Désactivation du composant SU log ==="

if grep -Rqs \
    'config KSU_SULOG\|config KSU.*SULOG' \
    KernelSU/kernel; then

    echo "Kconfig SU log détecté."

    # Le nom exact peut varier selon le commit.
    # On désactive toutes les options KSU_SULOG présentes.
    while read -r symbol; do

        [ -z "$symbol" ] && continue

        echo "Désactivation CONFIG_$symbol"

        scripts/config \
            --file out/.config \
            --disable "CONFIG_$symbol" \
            2>/dev/null || true

    done < <(
        grep -RhoE \
            'config KSU_[A-Z0-9_]*SULOG[A-Z0-9_]*' \
            KernelSU/kernel \
            | sed 's/config //' \
            | sort -u
    )

else
    echo "Aucune option Kconfig SU log trouvée."
fi


# ============================================================
# 7. ARCH / TOOLCHAIN
# ============================================================

export ARCH=arm64
export SUBARCH=arm64

export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out


# ============================================================
# 8. DEFCONFIG
# ============================================================

echo ""
echo "=== Recherche du defconfig ==="

CONFIG=$(find arch/arm64/configs/ \
    \( -name "*lito*" -o -name "*kiev*" -o -name "*sm8250*" \) \
    | head -1)

if [ -z "$CONFIG" ]; then
    echo "ERROR: aucun defconfig trouvé"
    exit 1
fi

CONFIG_NAME="${CONFIG#arch/arm64/configs/}"

echo "Defconfig:"
echo "$CONFIG_NAME"

make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$CONFIG_NAME"


# ============================================================
# 9. CONFIG KERNELSU
# ============================================================

echo ""
echo "=== Configuration KernelSU ==="

scripts/config \
    --file out/.config \
    --enable CONFIG_KSU

scripts/config \
    --file out/.config \
    --enable CONFIG_KALLSYMS

scripts/config \
    --file out/.config \
    --enable CONFIG_KALLSYMS_ALL

# ARM64 / 4.19+
scripts/config \
    --file out/.config \
    --enable CONFIG_KSU_HACK_ARM64_BRANCH_LINK


# KPROBES OFF
scripts/config \
    --file out/.config \
    --disable CONFIG_KPROBES \
    || true

scripts/config \
    --file out/.config \
    --disable CONFIG_HAVE_KPROBES \
    || true

scripts/config \
    --file out/.config \
    --disable CONFIG_KPROBE_EVENTS \
    || true


# ============================================================
# 10. DESACTIVER EVENTUELLEMENT CONFIG SULOG APRES DEFCONFIG
# ============================================================

echo ""
echo "=== Recherche options SU log dans .config ==="

grep -E \
    '^CONFIG_.*SULOG' \
    out/.config \
    || true

while read -r line; do

    case "$line" in

        CONFIG_*SULOG=y)

            symbol="${line%%=*}"

            echo "Désactivation $symbol"

            scripts/config \
                --file out/.config \
                --disable "$symbol" \
                || true

            ;;

    esac

done < <(
    grep -E '^CONFIG_.*SULOG=y' out/.config \
    || true
)


# ============================================================
# 11. OLDDEFCONFIG
# ============================================================

echo ""
echo "=== olddefconfig ==="

make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig


# ============================================================
# 12. CONFIG CHECK
# ============================================================

echo ""
echo "=== CONFIG CHECK ==="

grep -E \
    '^CONFIG_KSU=|^CONFIG_KSU_HACK_ARM64_BRANCH_LINK=|^CONFIG_KSU_KPROBES_KSUD=|^CONFIG_KSU_LSM_SECURITY_HOOKS=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=|^CONFIG_.*SULOG=|^# CONFIG_.*SULOG|^# CONFIG_KPROBES|^# CONFIG_HAVE_KPROBES|^# CONFIG_KPROBE_EVENTS' \
    out/.config \
    || true

echo ""

if ! grep -q '^CONFIG_KSU=y$' out/.config; then
    echo "ERROR: CONFIG_KSU=y absent"
    exit 1
fi

if ! grep -q '^CONFIG_KALLSYMS=y$' out/.config; then
    echo "ERROR: CONFIG_KALLSYMS=y absent"
    exit 1
fi

if ! grep -q '^CONFIG_KALLSYMS_ALL=y$' out/.config; then
    echo "ERROR: CONFIG_KALLSYMS_ALL=y absent"
    exit 1
fi

if grep -q '^CONFIG_KPROBES=y$' out/.config; then
    echo "ERROR: CONFIG_KPROBES=y actif"
    exit 1
fi

if grep -q '^CONFIG_.*SULOG=y$' out/.config; then
    echo ""
    echo "WARNING: une option SULOG reste activée:"
    grep '^CONFIG_.*SULOG=y' out/.config
fi

echo ""
echo "KernelSU configuration: OK"


# ============================================================
# 13. COMPILATION KERNEL
# ============================================================

echo ""
echo "=== Compilation kernel ==="

make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    -j"$(nproc)" \
    Image \
    2>&1 | tee build.log

BUILD_STATUS=${PIPESTATUS[0]}

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo ""
    echo "ERROR: compilation kernel échouée"
    exit "$BUILD_STATUS"
fi

if [ ! -f out/arch/arm64/boot/Image ]; then
    echo "ERROR: Image absente"
    exit 1
fi

echo ""
echo "Kernel compilé avec succès."


# ============================================================
# 14. VERIFICATION KERNELSU IMAGE
# ============================================================

echo ""
echo "=== Recherche KernelSU dans Image ==="

strings \
    out/arch/arm64/boot/Image \
    | grep -iE 'ksu|kernelsu' \
    | head -100 \
    || true


# ============================================================
# 15. RUST
# ============================================================

cd "$GITHUB_WORKSPACE"

echo ""
echo "=== Rust ==="

if ! command -v cargo >/dev/null 2>&1; then

    curl \
        --proto '=https' \
        --tlsv1.2 \
        -sSf \
        https://sh.rustup.rs \
        | sh -s -- -y

fi

source "$HOME/.cargo/env"

rustup target add aarch64-linux-android


# ============================================================
# 16. ANDROID NDK
# ============================================================

echo ""
echo "=== Android NDK r26d ==="

if [ ! -d "$GITHUB_WORKSPACE/android-ndk-r26d" ]; then

    wget -q \
        https://dl.google.com/android/repository/android-ndk-r26d-linux.zip

    unzip -q android-ndk-r26d-linux.zip

    rm -f android-ndk-r26d-linux.zip

fi

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

export TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"

export AARCH64_CLANG_PATH="$TOOLCHAIN/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$TOOLCHAIN/aarch64-linux-android26-clang++"
export AR_PATH="$TOOLCHAIN/llvm-ar"

export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"


# ============================================================
# 17. KSUD
# ============================================================

echo ""
echo "=== Compilation ksud ==="

cd "$GITHUB_WORKSPACE/kernel_sources/KernelSU/userspace/ksud"

if [ ! -f Cargo.toml ]; then
    echo "ERROR: Cargo.toml ksud absent"
    exit 1
fi

rm -rf .cargo
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

cargo build \
    --release \
    --target aarch64-linux-android

KSUD_BINARY="$GITHUB_WORKSPACE/kernel_sources/KernelSU/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -f "$KSUD_BINARY" ]; then
    echo "ERROR: ksud absent"
    exit 1
fi

cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"

chmod 755 "$GITHUB_WORKSPACE/ksud"

echo ""
echo "ksud:"
"$GITHUB_WORKSPACE/ksud" -V


# ============================================================
# 18. COMMIT CHECK
# ============================================================

KSUD_SOURCE_COMMIT="$(
    cd "$GITHUB_WORKSPACE/kernel_sources/KernelSU"
    git rev-parse HEAD
)"

echo ""
echo "=== Commit Kernel / ksud ==="

echo "KernelSU commit : $KSU_COMMIT"
echo "ksud source     : $KSUD_SOURCE_COMMIT"

if [ "$KSU_COMMIT" != "$KSUD_SOURCE_COMMIT" ]; then
    echo "ERROR: MISMATCH KernelSU / ksud"
    exit 1
fi

echo "SAME COMMIT : OK"


# ============================================================
# 19. BOOT STOCK
# ============================================================

cd "$GITHUB_WORKSPACE"

echo ""
echo "=== Téléchargement boot.img ==="

curl -fLo boot-stock.img \
    "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"

if [ ! -f boot-stock.img ]; then
    echo "ERROR: boot-stock.img absent"
    exit 1
fi

curl -fLo dtbo-stock.img \
    "https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" \
    || true


# ============================================================
# 20. MAGISKBOOT
# ============================================================

echo ""
echo "=== Préparation magiskboot ==="

rm -rf repack
mkdir -p repack

cp boot-stock.img repack/boot.img

cd repack

wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O Magisk.apk

unzip -q \
    Magisk.apk \
    lib/x86_64/libmagiskboot.so

mv \
    lib/x86_64/libmagiskboot.so \
    magiskboot

chmod +x magiskboot

rm -rf lib Magisk.apk


# ============================================================
# 21. UNPACK
# ============================================================

echo ""
echo "=== Unpack boot ==="

./magiskboot unpack boot.img

if [ ! -f kernel ]; then
    echo "ERROR: kernel absent"
    exit 1
fi

if [ ! -f ramdisk.cpio ]; then
    echo "ERROR: ramdisk.cpio absent"
    exit 1
fi


# ============================================================
# 22. KERNEL
# ============================================================

echo ""
echo "=== Installation Image ==="

cp \
    "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" \
    kernel


# ============================================================
# 23. KSUD
# ============================================================

echo ""
echo "=== Installation ksud ==="

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"


# ============================================================
# 24. RAMDISK CHECK
# ============================================================

echo ""
echo "=== Vérification ramdisk ==="

./magiskboot cpio ramdisk.cpio list \
    | grep -E '(^|/)ksud$' \
    || true


# ============================================================
# 25. REPACK
# ============================================================

echo ""
echo "=== Repack boot.img ==="

./magiskboot repack boot.img new-boot.img

if [ ! -f new-boot.img ]; then
    echo "ERROR: new-boot.img absent"
    exit 1
fi

mv \
    new-boot.img \
    "$GITHUB_WORKSPACE/Backslashxx-KernelSU-kiev-4.19.img"

cd "$GITHUB_WORKSPACE"


# ============================================================
# 26. OUTPUT
# ============================================================

echo ""
echo "=== Output ==="

mkdir -p output

cp \
    Backslashxx-KernelSU-kiev-4.19.img \
    output/boot.img

cp \
    dtbo-stock.img \
    output/dtbo.img \
    2>/dev/null || true

cp \
    ksud \
    output/ksud

cp \
    kernel_sources/build.log \
    output/build.log

cp \
    kernel_sources/out/.config \
    output/kernel.config

echo "$KSU_COMMIT" \
    > output/kernelsu-commit.txt

echo "$KSU_VERSION" \
    > output/kernelsu-version.txt


# ============================================================
# 27. RAPPORT
# ============================================================

echo ""
echo "============================================================"
echo " BUILD TERMINE"
echo "============================================================"

echo ""
echo "KernelSU:"
echo "$KSU_VERSION"

echo ""
echo "Commit:"
echo "$KSU_COMMIT"

echo ""
echo "ksud:"
./ksud -V

echo ""
echo "CONFIG:"

grep -E \
    '^CONFIG_KSU=|^CONFIG_KSU_HACK_ARM64_BRANCH_LINK=|^CONFIG_KSU_KPROBES_KSUD=|^CONFIG_KSU_LSM_SECURITY_HOOKS=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=|^CONFIG_.*SULOG=' \
    kernel_sources/out/.config \
    || true

echo ""
echo "Kernel:"
ls -lh \
    kernel_sources/out/arch/arm64/boot/Image

echo ""
echo "Boot:"
ls -lh \
    Backslashxx-KernelSU-kiev-4.19.img

echo ""
echo "Output:"
ls -lh output/

echo ""
echo "============================================================"
echo " TEST APRES FLASH"
echo "============================================================"

echo ""
echo "su -c 'id'"
echo "su -c 'ksud -V'"
echo "su -c 'ksud debug version'"
echo "su -c 'ksud debug info'"

echo ""
echo "Objectif:"
echo "version: 2"
echo "uapi_version: 2"

echo ""
echo "============================================================"
echo " FIN"
echo "============================================================"

