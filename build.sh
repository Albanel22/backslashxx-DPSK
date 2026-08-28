#!/bin/bash
set -e

echo "============================================================"
echo " Backslashxx KernelSU - Kernel 4.19 - LineageOS 23.2"
echo " kiev / lito-perf / UAPI validation"
echo "============================================================"

df -h

export DEBIAN_FRONTEND=noninteractive

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

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
# 1. CLONE BACKSLASHXX UNE SEULE FOIS
# ============================================================

echo ""
echo "=== 1. Clone Backslashxx KernelSU ==="

rm -rf KernelSU-src

git clone \
    --depth=1 \
    https://github.com/backslashxx/KernelSU.git \
    KernelSU-src

cd KernelSU-src

KSU_COMMIT="$(git rev-parse HEAD)"

echo "KernelSU commit:"
echo "$KSU_COMMIT"

git log -1 --oneline

cd "$GITHUB_WORKSPACE"


# ============================================================
# 2. CLONE KERNEL LINEAGEOS 23.2
# ============================================================

echo ""
echo "=== 2. Clone kernel Motorola kiev ==="

rm -rf kernel_sources

git clone \
    --depth=1 \
    -b lineage-23.2 \
    https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
    kernel_sources

cd kernel_sources

echo "Kernel commit:"
git log -1 --oneline


# ============================================================
# 3. INTEGRATION BACKSLASHXX
# ============================================================

echo ""
echo "=== 3. Integration Backslashxx ==="

rm -rf drivers/kernelsu kernelSU susfs4ksu || true

if [ ! -f "$GITHUB_WORKSPACE/KernelSU-src/kernel/setup.sh" ]; then
    echo "ERROR: setup.sh Backslashxx absent"
    exit 1
fi

echo "Utilisation du setup.sh du commit:"
echo "$KSU_COMMIT"

chmod +x "$GITHUB_WORKSPACE/KernelSU-src/kernel/setup.sh"

(
    cd "$GITHUB_WORKSPACE/KernelSU-src/kernel"
    ./setup.sh "$GITHUB_WORKSPACE/kernel_sources"
)


# ============================================================
# 4. VERIFICATION INTEGRATION
# ============================================================

echo ""
echo "=== 4. Vérification intégration KernelSU ==="

if [ ! -d drivers/kernelsu ]; then
    echo "ERROR: drivers/kernelsu absent après setup.sh"
    exit 1
fi

echo "drivers/kernelsu trouvé."

find drivers/kernelsu -maxdepth 2 -type f | head -50


# ============================================================
# 5. CONFIGURATION KERNEL
# ============================================================

echo ""
echo "=== 5. Configuration kernel ==="

export ARCH=arm64
export SUBARCH=arm64

export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

echo "Recherche defconfig..."

CONFIG=$(find arch/arm64/configs/ \
    \( -name "*lito*" -o -name "*kiev*" -o -name "*sm8250*" \) \
    | head -1)

if [ -z "$CONFIG" ]; then
    echo "ERROR: aucun defconfig lito/kiev/sm8250 trouvé"
    exit 1
fi

CONFIG_NAME="${CONFIG#arch/arm64/configs/}"

echo "Defconfig trouvé:"
echo "$CONFIG_NAME"


make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$CONFIG_NAME"


# ============================================================
# 6. CONFIG KERNELSU VIA SCRIPTS/CONFIG
# ============================================================

echo ""
echo "=== 6. Activation KernelSU via Kconfig ==="

if [ ! -x scripts/config ]; then
    echo "ERROR: scripts/config absent"
    exit 1
fi

scripts/config --file out/.config \
    --enable CONFIG_KSU

scripts/config --file out/.config \
    --enable CONFIG_KSU_MANUAL_HOOK

# KernelSU legacy/non-GKI peut nécessiter KALLSYMS.
scripts/config --file out/.config \
    --enable CONFIG_KALLSYMS

scripts/config --file out/.config \
    --enable CONFIG_KALLSYMS_ALL


# KPROBES désactivés pour le mode manual hook.
scripts/config --file out/.config \
    --disable CONFIG_KPROBES || true

scripts/config --file out/.config \
    --disable CONFIG_KPROBE_EVENTS || true


echo ""
echo "=== olddefconfig ==="

make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig


# ============================================================
# 7. CONFIG CHECK
# ============================================================

echo ""
echo "=== 7. CONFIG CHECK ==="

grep -E \
    '^CONFIG_KSU=|^CONFIG_KSU_MANUAL_HOOK=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=|^# CONFIG_KPROBES|^# CONFIG_KPROBE_EVENTS' \
    out/.config || true

if ! grep -q '^CONFIG_KSU=y$' out/.config; then
    echo "ERROR: CONFIG_KSU n'est pas activé"
    exit 1
fi

if ! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' out/.config; then
    echo "ERROR: CONFIG_KSU_MANUAL_HOOK n'est pas activé"
    exit 1
fi

echo "KernelSU configuration OK."


# ============================================================
# 8. COMPILATION KERNEL
# ============================================================

echo ""
echo "=== 8. Compilation kernel ==="

make O=out \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    -j"$(nproc)" \
    Image \
    2>&1 | tee build.log


if [ ! -f out/arch/arm64/boot/Image ]; then
    echo ""
    echo "ERROR: Image kernel absente"
    exit 1
fi

echo ""
echo "Kernel compilé avec succès."


# ============================================================
# 9. VERIFICATION KERNELSU DANS IMAGE
# ============================================================

echo ""
echo "=== 9. Vérification KernelSU dans Image ==="

strings \
    out/arch/arm64/boot/Image \
    | grep -iE 'ksu|kernelsu' \
    | head -100 || true


# ============================================================
# 10. RUST
# ============================================================

cd "$GITHUB_WORKSPACE"

echo ""
echo "=== 10. Installation Rust ==="

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
# 11. ANDROID NDK
# ============================================================

echo ""
echo "=== 11. Android NDK ==="

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
# 12. BUILD KSUD DU MEME COMMIT
# ============================================================

echo ""
echo "=== 12. Compilation ksud ==="

cd "$GITHUB_WORKSPACE/KernelSU-src/userspace/ksud"

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


KSUD_BINARY="$GITHUB_WORKSPACE/KernelSU-src/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -f "$KSUD_BINARY" ]; then
    echo "ERROR: ksud absent après compilation"
    exit 1
fi

cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"

chmod 755 "$GITHUB_WORKSPACE/ksud"

echo ""
echo "ksud compilé:"
"$GITHUB_WORKSPACE/ksud" -V


# ============================================================
# 13. RECHERCHE DU SU BACKSLASHXX
# ============================================================

cd "$GITHUB_WORKSPACE"

echo ""
echo "=== 13. Recherche du binaire su ==="

rm -f su

SU_CANDIDATES=$(find KernelSU-src/userspace \
    -type f \
    -name su \
    2>/dev/null || true)

if [ -n "$SU_CANDIDATES" ]; then

    echo "Binaire(s) su trouvé(s):"
    echo "$SU_CANDIDATES"

    SU_BINARY=$(echo "$SU_CANDIDATES" | head -1)

    cp "$SU_BINARY" "$GITHUB_WORKSPACE/su"
    chmod 755 "$GITHUB_WORKSPACE/su"

    echo "SU sélectionné:"
    "$GITHUB_WORKSPACE/su" -v || true

else

    echo "Aucun binaire su séparé trouvé."
    echo "Le mécanisme SU intégré sera utilisé."

fi


# ============================================================
# 14. BOOT STOCK
# ============================================================

echo ""
echo "=== 14. Téléchargement boot.img stock ==="

rm -f boot-stock.img dtbo-stock.img

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
# 15. MAGISKBOOT
# ============================================================

echo ""
echo "=== 15. Préparation magiskboot ==="

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
# 16. UNPACK
# ============================================================

echo ""
echo "=== 16. Unpack boot.img ==="

./magiskboot unpack boot.img


if [ ! -f kernel ]; then
    echo "ERROR: kernel absent après unpack"
    exit 1
fi

if [ ! -f ramdisk.cpio ]; then
    echo "ERROR: ramdisk.cpio absent après unpack"
    exit 1
fi


# ============================================================
# 17. REMPLACEMENT KERNEL
# ============================================================

echo ""
echo "=== 17. Installation Image compilée ==="

cp \
    "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" \
    kernel


# ============================================================
# 18. INSTALLATION KSUD
# ============================================================

echo ""
echo "=== 18. Installation ksud ==="

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"


# ============================================================
# 19. INSTALLATION SU
# ============================================================

if [ -f "$GITHUB_WORKSPACE/su" ]; then

    echo ""
    echo "=== 19. Installation su Backslashxx ==="

    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" \
        "mkdir 0755 system/bin" \
        "add 06755 system/bin/su $GITHUB_WORKSPACE/su"

else

    echo ""
    echo "=== 19. Aucun su séparé ==="
    echo "Le mécanisme KernelSU intégré sera conservé."

fi


# ============================================================
# 20. VERIFICATION RAMDISK
# ============================================================

echo ""
echo "=== 20. Vérification ramdisk ==="

./magiskboot cpio ramdisk.cpio list \
    | grep -E '(^|/)(su|ksud)$' \
    || true


# ============================================================
# 21. REPACK
# ============================================================

echo ""
echo "=== 21. Repack boot.img ==="

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
# 22. OUTPUT
# ============================================================

echo ""
echo "=== 22. Output ==="

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

printf '%s\n' "$KSU_COMMIT" \
    > output/kernelsu-commit.txt


# ============================================================
# 23. RAPPORT
# ============================================================

echo ""
echo "============================================================"
echo " BUILD TERMINÉ"
echo "============================================================"

echo ""
echo "KernelSU commit:"
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
echo "Image:"
ls -lh \
    kernel_sources/out/arch/arm64/boot/Image

echo ""
echo "Boot final:"
ls -lh \
    Backslashxx-KernelSU-kiev-4.19.img

echo ""
echo "Output:"
ls -lh output/

echo ""
echo "============================================================"
echo " TEST APRÈS FLASH"
echo "============================================================"

echo ""
echo "1. su -c 'id'"
echo "2. su -c 'ksud -V'"
echo "3. su -c 'ksud debug version'"
echo "4. su -c 'ksud debug info'"

echo ""
echo "Résultat recherché:"
echo "version: 2"
echo "uapi_version: 2"

echo ""
echo "============================================================"

