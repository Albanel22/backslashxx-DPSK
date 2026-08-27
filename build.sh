#!/bin/bash
set -e

echo "=== Backslashxx KernelSU 4.19 UAPI Build ==="

df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean

sudo apt-get update

sudo apt-get install -y \
bc bison build-essential ccache flex \
libelf-dev libssl-dev libncurses-dev \
gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
clang llvm lld device-tree-compiler \
zip unzip curl git python3 perl \
mkbootimg wget

cd "$GITHUB_WORKSPACE"


############################################
# KernelSU SOURCE UNIQUE
############################################

echo "=== Clone Backslashxx KernelSU ==="

rm -rf KernelSU-src

git clone --depth=1 \
https://github.com/backslashxx/KernelSU.git \
KernelSU-src

cd KernelSU-src

KSU_COMMIT=$(git rev-parse HEAD)

echo "KernelSU commit:"
echo "$KSU_COMMIT"

cd "$GITHUB_WORKSPACE"


############################################
# KERNEL SOURCE
############################################

echo "=== Clone kernel kiev ==="

rm -rf kernel_sources

git clone \
--depth=1 \
-b lineage-23.2 \
https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
kernel_sources


cd kernel_sources


############################################
# INTEGRATION KERNELSU
############################################

echo "=== Integration KernelSU depuis commit unique ==="

cp -r \
../KernelSU-src/kernel \
drivers/kernelsu


if [ ! -d drivers/kernelsu ]; then
    echo "Erreur KernelSU absent"
    exit 1
fi


echo "KernelSU installé :"

ls drivers/kernelsu | head


cd "$GITHUB_WORKSPACE"


############################################
# CONFIG
############################################

cd kernel_sources

export ARCH=arm64
export SUBARCH=arm64

export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-


mkdir -p out


echo "=== Defconfig ==="

make O=out \
LLVM=1 \
CROSS_COMPILE=$CROSS_COMPILE \
CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
vendor/lito-perf_defconfig


############################################
# ENABLE KSU
############################################

echo "=== Enable KernelSU ==="

cat >> out/.config <<EOF

CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
EOF


make O=out \
LLVM=1 \
CROSS_COMPILE=$CROSS_COMPILE \
CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
olddefconfig


echo "=== CONFIG CHECK ==="

grep CONFIG_KSU out/.config

############################################
# BUILD KERNEL
############################################

echo "=== Compilation kernel ==="

make O=out \
LLVM=1 \
CROSS_COMPILE=$CROSS_COMPILE \
CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
-j$(nproc) Image \
2>&1 | tee build.log


if [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ Image kernel absente"
    exit 1
fi

echo "✅ Kernel compilé"


############################################
# VERIFICATION KERNELSU DANS IMAGE
############################################

echo "=== Vérification symboles KernelSU ==="

strings out/arch/arm64/boot/Image | \
grep -i "ksu" | head -50 || true


############################################
# BUILD USERSPACE KSUD + SU
############################################

cd "$GITHUB_WORKSPACE"


echo "=== Préparation Rust ==="

curl --proto '=https' \
--tlsv1.2 \
-sSf https://sh.rustup.rs \
| sh -s -- -y


source "$HOME/.cargo/env"


rustup target add aarch64-linux-android


############################################
# ANDROID NDK
############################################

echo "=== Installation NDK ==="

wget -q \
https://dl.google.com/android/repository/android-ndk-r26d-linux.zip

unzip -q android-ndk-r26d-linux.zip


export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"

export TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"


export CC_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android26-clang"

export CXX_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android26-clang++"

export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"



############################################
# KSUD
############################################

cd KernelSU-src


echo "=== Build ksud même commit ==="


cd userspace/ksud


mkdir -p .cargo


cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$CC_aarch64_linux_android"

[env]
CC_aarch64_linux_android = "$CC_aarch64_linux_android"
CXX_aarch64_linux_android = "$CXX_aarch64_linux_android"
AR_aarch64_linux_android = "$AR_aarch64_linux_android"
EOF


cargo build \
--release \
--target aarch64-linux-android



KSUD="$GITHUB_WORKSPACE/KernelSU-src/userspace/ksud/target/aarch64-linux-android/release/ksud"


if [ ! -f "$KSUD" ]; then
    echo "❌ ksud non trouvé"
    exit 1
fi


cp "$KSUD" "$GITHUB_WORKSPACE/ksud"

chmod 755 "$GITHUB_WORKSPACE/ksud"


echo "✅ ksud compilé"

"$GITHUB_WORKSPACE/ksud" -V

############################################
# VERIFICATION SU BACKSLASHXX
############################################

cd "$GITHUB_WORKSPACE"

echo "=== Recherche binaire SU Backslashxx ==="

SU_BINARY=$(find KernelSU-src -type f -name su | head -1 || true)


if [ -n "$SU_BINARY" ]; then

    echo "SU trouvé:"
    echo "$SU_BINARY"

    cp "$SU_BINARY" "$GITHUB_WORKSPACE/su"

else

    echo "⚠️ Pas de binaire su séparé trouvé"
    echo "Utilisation du mécanisme KernelSU intégré"

fi


############################################
# BOOT IMAGE STOCK
############################################

echo "=== Téléchargement boot stock kiev ==="


curl -fLo boot-stock.img \
"https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img" \
|| {
echo "❌ boot.img impossible à récupérer"
exit 1
}


curl -fLo dtbo-stock.img \
"https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" \
|| true



############################################
# MAGISKBOOT
############################################

mkdir -p repack

cp boot-stock.img repack/boot.img


cd repack


wget -q \
https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
-O magisk.apk


unzip -q magisk.apk lib/x86_64/libmagiskboot.so


mv lib/x86_64/libmagiskboot.so magiskboot

chmod +x magiskboot


rm -rf lib magisk.apk



############################################
# UNPACK
############################################

echo "=== Unpack boot ==="


./magiskboot unpack boot.img


if [ ! -f kernel ]; then

echo "❌ Kernel absent après unpack"

exit 1

fi



############################################
# REMPLACEMENT KERNEL
############################################

echo "=== Installation kernel compilé ==="


cp \
"$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" \
kernel



############################################
# INSTALLATION KSUD
############################################

echo "=== Installation ksud ==="


./magiskboot cpio ramdisk.cpio \
"mkdir 0755 data" \
"mkdir 0755 data/adb" \
"mkdir 0755 data/adb/ksud" \
"add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"



############################################
# INSTALLATION SU SI DISPONIBLE
############################################

if [ -f "$GITHUB_WORKSPACE/su" ]; then

echo "=== Installation su Backslashxx ==="


chmod 6755 "$GITHUB_WORKSPACE/su"


./magiskboot cpio ramdisk.cpio \
"mkdir 0755 system" \
"mkdir 0755 system/bin" \
"add 06755 system/bin/su $GITHUB_WORKSPACE/su"


else

echo "Pas de su séparé"
echo "KernelSU utilisera son mécanisme intégré"

fi



############################################
# VERIFICATION RAMDISK
############################################


echo "=== Contenu KernelSU ramdisk ==="


./magiskboot cpio ramdisk.cpio list | \
grep -E "(su|ksud)" || true

############################################
# REPACK BOOT
############################################

echo "=== Repack boot.img ==="


./magiskboot repack boot.img new-boot.img


if [ ! -f new-boot.img ]; then

    echo "❌ Repack échoué"

    exit 1

fi


mv new-boot.img \
"$GITHUB_WORKSPACE/Backslashxx-KernelSU-kiev-4.19.img"


cd "$GITHUB_WORKSPACE"



############################################
# OUTPUT
############################################

mkdir -p output


cp \
Backslashxx-KernelSU-kiev-4.19.img \
output/boot.img


cp \
dtbo-stock.img \
output/dtbo.img 2>/dev/null || true


cp \
ksud \
output/ksud


cp \
kernel_sources/build.log \
output/build.log



############################################
# RAPPORT FINAL
############################################

echo ""
echo "================================"
echo " BUILD TERMINE "
echo "================================"


echo ""
echo "KernelSU commit:"
cat KernelSU-src/.git/HEAD


echo ""
echo "ksud:"
./ksud -V



############################################
# CONTROLE FINAL
############################################

echo ""
echo "=== Vérification KernelSU ==="


echo "--- Kernel config ---"

grep \
-E "CONFIG_KSU|CONFIG_KSU_MANUAL_HOOK" \
kernel_sources/out/.config || true



echo "--- Image kernel ---"

strings \
kernel_sources/out/arch/arm64/boot/Image \
| grep -i ksu \
| head -30 || true



echo "--- Fichiers output ---"

ls -lh output/


echo ""
echo "Flash boot.img puis tester :"

echo "su -c 'ksud debug info'"
echo "su -c 'ksud debug version'"


echo ""
echo "Résultat attendu :"

echo "version: 2"
echo "uapi_version: 2"

echo ""
echo "=== FIN ==="
