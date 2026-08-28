#!/bin/bash
set -e

echo "============================================================"
echo " Backslashxx KernelSU - 4.19 / LineageOS 23.2"
echo " Motorola kiev - UAPI validation"
echo "============================================================"

df -h

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. DEPENDANCES
# ============================================================

echo "=== Installation dépendances ==="

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' \
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

echo "Kernel description:"
git log -1 --oneline


# ============================================================
# 3. BACKSLASHXX SETUP.SH
# ============================================================

echo ""
echo "=== Intégration officielle Backslashxx KernelSU ==="

rm -rf KernelSU
rm -rf drivers/kernelsu

# ------------------------------------------------------------
# KSU_REF
#
# master = état actuel du dépôt
#
# On peut remplacer par un commit/tag précis plus tard.
# ------------------------------------------------------------

KSU_REF="${KSU_REF:-master}"

echo "KernelSU ref: $KSU_REF"

curl -fL \
    https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh \
    -o /tmp/backslashxx-setup.sh

chmod +x /tmp/backslashxx-setup.sh

echo ""
echo "Exécution du setup.sh officiel..."

/tmp/backslashxx-setup.sh "$KSU_REF"


# ============================================================
# 4. VERIFICATION SETUP
# ============================================================

echo ""
echo "=== Vérification KernelSU ==="

if [ ! -d KernelSU ]; then
    echo "ERROR: KernelSU/ absent"
    exit 1
fi

if [ ! -L drivers/kernelsu ]; then
    echo "ERROR: drivers/kernelsu n'est pas un symlink"
    ls -la drivers/kernelsu 2>/dev/null || true
    exit 1
fi

echo "drivers/kernelsu:"
readlink -f drivers/kernelsu

KSU_COMMIT="$(cd KernelSU && git rev-parse HEAD)"
KSU_VERSION="$(cd KernelSU && git describe --tags --always --dirty 2>/dev/null || true)"

echo ""
echo "KernelSU commit:"
echo "$KSU_COMMIT"

echo "KernelSU version:"
echo "$KSU_VERSION"

echo "$KSU_COMMIT" > "$GITHUB_WORKSPACE/output/kernelsu-commit.txt"
echo "$KSU_VERSION" > "$GITHUB_WORKSPACE/output/kernelsu-version.txt"


# ============================================================
# 5. VERIFIER MAKEFILE / KCONFIG
# ============================================================

echo ""
echo "=== Vérification Makefile/Kconfig ==="

if ! grep -q "kernelsu" drivers/Makefile; then
    echo "ERROR: drivers/Makefile ne contient pas KernelSU"
    exit 1
fi

if ! grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig; then
    echo "ERROR: drivers/Kconfig ne contient pas KernelSU"
    exit 1
fi

echo "Makefile KernelSU: OK"
echo "Kconfig KernelSU: OK"


# ============================================================
# 6. CONFIGURATION KERNEL
# ============================================================

echo ""
echo "=== Configuration kernel ==="

export ARCH=arm64
export SUBARCH=arm64

export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG=$(find arch/arm64/configs/ \
    \( -name "*lito*" -o -name "*kiev*" -o -name "*sm8250*" \) \
    | head -1)

if [ -z "$CONFIG" ]; then
    echo "ERROR: aucun defconfig lito/kiev/sm8250 trouvé"
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
# 7. CONFIG KSU
# ============================================================

echo ""
echo "=== Activation KernelSU ==="

if [ ! -x scripts/config ]; then
    echo "ERROR: scripts/config absent"
    exit 1
fi

scripts/config \
    --file out/.config \
    --enable CONFIG_KSU

scripts/config \
    --file out/.config \
    --enable CONFIG_KSU_MANUAL_HOOK

scripts/config \
    --file out/.config \
    --enable CONFIG_KALLSYMS

scripts/config \
    --file out/.config \
    --enable CONFIG_KALLSYMS_ALL

# Manual Hook : pas de KPROBES nécessaire.
scripts/config \
    --file out/.config \
    --disable CONFIG_KPROBES || true

scripts/config \
    --file out/.config \
    --disable CONFIG_KPROBE_EVENTS || true


# ============================================================
# 8. OLDDEFCONFIG
# ============================================================

echo ""
echo "=== olddefconfig ==="

make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig


# ============================================================
# 9. CONFIG CHECK
# ============================================================

echo ""
echo "=== CONFIG CHECK ==="

grep -E \
    '^CONFIG_KSU=|^CONFIG_KSU_MANUAL_HOOK=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=|^# CONFIG_KPROBES|^# CONFIG_KPROBE_EVENTS' \
    out/.config || true

if ! grep -q '^CONFIG_KSU=y$' out/.config; then
    echo "ERROR: CONFIG_KSU=y absent"
    exit 1
fi

if ! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' out/.config; then
    echo "ERROR: CONFIG_KSU_MANUAL_HOOK=y absent"
    exit 1
fi

echo "KernelSU config: OK"


# ============================================================
# 10. COMPILATION KERNEL
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
    echo "ERROR: compilation kernel échouée"
    exit "$BUILD_STATUS"
fi

if [ ! -f out/arch/arm64/boot/Image ]; then
    echo "ERROR: Image absente"
    exit 1
fi

echo "Kernel compilé: OK"


# ============================================================
# 11. VERIFICATION KERNELSU DANS IMAGE
# ============================================================

echo ""
echo "=== KernelSU dans Image ==="

strings \
    out/arch/arm64/boot/Image \
    | grep -iE 'ksu|kernelsu' \
    | head -100 || true


# ============================================================
# 12. RUST
# ============================================================

cd "$GITHUB_WORKSPACE"

echo ""
echo "=== Rust ==="

if ! command -v cargo >/dev/null 2>&1; then
    curl --proto '=https' \
        --tlsv1.2 \
        -sSf \
        https://sh.rustup.rs \
        | sh -s -- -y
fi

source "$HOME/.cargo/env"

rustup target add aarch64-linux-android


# ============================================================
# 13. ANDROID NDK
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
# 14. KSUD DU MEME COMMIT
# ============================================================

echo ""
echo "=== Compilation ksud ==="

cd "$GITHUB_WORKSPACE/kernel_sources/KernelSU/userspace/ksud"

if [ ! -f Cargo.toml ]; then
    echo "ERROR: userspace/ksud/Cargo.toml absent"
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
echo "ksud version:"
"$GITHUB_WORKSPACE/ksud" -V


# ============================================================
# 15. VERIFICATION COMMIT KSUD
# ============================================================

KSUD_SOURCE_COMMIT="$(
    cd "$GITHUB_WORKSPACE/kernel_sources/KernelSU"
    git rev-parse HEAD
)"

echo ""
echo "=== Synchronisation Kernel / Userspace ==="

echo "KernelSU commit:"
echo "$KSU_COMMIT"

echo "ksud source commit:"
echo "$KSUD_SOURCE_COMMIT"

if [ "$KSU_COMMIT" != "$KSUD_SOURCE_COMMIT" ]; then
    echo "ERROR: MISMATCH KernelSU / ksud"
    exit 1
fi

echo "Kernel / ksud: SAME COMMIT"


# ============================================================
# 16. BOOT STOCK
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
# 17. MAGISKBOOT
# ============================================================

echo ""
echo "=== Magiskboot ==="

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
# 18. UNPACK
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
# 19. INSTALLATION KERNEL
# ============================================================

echo ""
echo "=== Installation kernel compilé ==="

cp \
    "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" \
    kernel


# ============================================================
# 20. KSUD
# ============================================================

echo ""
echo "=== Installation ksud ==="

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"


# ============================================================
# 21. SU
#
# IMPORTANT:
# On ne cherche PAS un userspace/su qui n'existe pas.
#
# ksud contient le mécanisme userspace nécessaire.
# ============================================================

echo ""
echo "=== SU ==="

echo "Le binaire su sera géré par le mécanisme Backslashxx."
echo "Aucun faux ksud -> /system/bin/su ne sera créé."


# ============================================================
# 22. RAMDISK CHECK
# ============================================================

echo ""
echo "=== Vérification ramdisk ==="

./magiskboot cpio ramdisk.cpio list \
    | grep -E '(^|/)ksud$' \
    || true


# ============================================================
# 23. REPACK
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
# 24. OUTPUT
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
# 25. RAPPORT FINAL
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
echo "Kernel config:"
grep -E \
    '^CONFIG_KSU=|^CONFIG_KSU_MANUAL_HOOK=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=' \
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
echo "su -c 'su -v'"
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
