#!/bin/bash
set -e

echo "=== BUILD kiev : source LineageOS officielle (= source exacte du stock 20260920) + ReSukiSU + modules auto-injectes ==="
df -h

# ==================== PARAMETRES ====================
STOCK_DATE="20260920"
BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/${STOCK_DATE}/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/${STOCK_DATE}/dtbo.img"
# Commit attendu (confirme correspondre exactement a uname -r du stock 20260920).
EXPECTED_COMMIT_PREFIX="c21b90c6860e"
RESUKISU_REF=""   # vide = branche main (dernier commit)
BAKE_SUSFS=0       # laisse a 0 tant qu'on n'a pas l'URL exacte du patch susfs 4.19 valide

# ==================== ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex libssl-dev libncurses-dev \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi device-tree-compiler zip unzip curl git \
    python3 cpio perl

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DE LA SOURCE OFFICIELLE ====================
echo "=== Clonage LineageOS/android_kernel_motorola_sm8250 (branche par defaut) ==="
git clone --depth=1 https://github.com/LineageOS/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources
COMMIT=$(git rev-parse HEAD)
echo "Commit clone : $COMMIT"
git log --oneline -1

if [[ "$COMMIT" != "$EXPECTED_COMMIT_PREFIX"* ]]; then
    echo "::warning::Le commit clone ($COMMIT) ne commence pas par $EXPECTED_COMMIT_PREFIX."
    echo "::warning::La source a peut-etre avance depuis le 20260920 : le noyau compile ne correspondra plus exactement au stock utilise comme reference boot.img/dtbo.img."
    echo "::warning::Le build continue quand meme (les modules sont auto-compiles, donc l'ecart de version est moins critique), mais verifie apres coup."
else
    echo "[+] Commit confirme : source exacte du stock $STOCK_DATE"
fi

# ==================== 2. INTEGRATION RESUKISU ====================
echo "=== Integration ReSukiSU ==="
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" -o /tmp/resukisu_setup.sh
chmod +x /tmp/resukisu_setup.sh
if [ -n "$RESUKISU_REF" ]; then
    /tmp/resukisu_setup.sh "$RESUKISU_REF"
else
    /tmp/resukisu_setup.sh
fi
[ -L drivers/kernelsu ] || { echo "ERREUR: setup.sh n'a pas cree le symlink drivers/kernelsu"; exit 1; }
echo "[+] ReSukiSU integre ($(cd KernelSU && git log --oneline -1))"

if [ -f drivers/kernelsu/Kbuild ] && grep -qi "integrate susfs" drivers/kernelsu/Kbuild; then
    sed -i '/[Ii]ntegrate susfs/d' drivers/kernelsu/Kbuild
    echo "[+] Check Kbuild SuSFS obligatoire contourne"
fi

if [ "$BAKE_SUSFS" = "1" ]; then
    echo "::warning::BAKE_SUSFS=1 demande mais aucune source de patch verifiee n'est cablee dans ce script -- ignore."
fi

# ==================== 3. HOOKS MANUELS ====================
echo "=== Hooks manuels ==="
hook_insert() {
    local file="$1" sig_re="$2" extern_block="$3" call_line="$4"
    [ -f "$file" ] || { echo "ERREUR: $file introuvable."; return 1; }
    grep -Pzo "$sig_re" "$file" > /dev/null 2>&1 || { echo "ERREUR: signature non trouvee dans $file"; return 1; }
    perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"
    echo "[+] Hook insere dans $file"
    return 0
}

HOOKS_FAILED=0

hook_insert "fs/exec.c" \
    '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' \
    'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' \
    || HOOKS_FAILED=1

if grep -Pzo 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
    hook_insert "fs/open.c" \
        'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
        'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
        || HOOKS_FAILED=1
elif grep -Pzo 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then
    hook_insert "fs/open.c" \
        'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
        'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
        || HOOKS_FAILED=1
else
    echo "ERREUR: hook faccessat non trouve"; HOOKS_FAILED=1
fi

if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,' fs/stat.c > /dev/null 2>&1; then
    hook_insert "fs/stat.c" \
        'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
        'ksu_handle_stat(&dfd, &filename, &flags);' \
        || HOOKS_FAILED=1
elif grep -Pzo 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' fs/stat.c > /dev/null 2>&1; then
    hook_insert "fs/stat.c" \
        'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' \
        '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
        'ksu_handle_stat(&dfd, &filename, &flag);' \
        || HOOKS_FAILED=1
else
    echo "ERREUR: hook stat non trouve"; HOOKS_FAILED=1
fi

if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
    sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\
#endif' kernel/reboot.c
    sed -i '/int ret = 0;/a\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_KSUD)\
\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\
#endif' kernel/reboot.c
    echo "[+] Hook sys_reboot OK"
else
    echo "[+] Hook sys_reboot deja present"
fi

[ "$HOOKS_FAILED" -ne 0 ] && echo "::warning::Au moins un hook n'a pas ete insere : le root risque de ne pas fonctionner"

# ==================== 4. FIX get_cred_rcu (si necessaire) ====================
if grep -q "get_cred_rcu" kernel/cred.c 2>/dev/null && ! grep -q "get_cred_rcu" include/linux/cred.h; then
    python3 - << 'PYEOF'
import re
path = 'include/linux/cred.h'
with open(path) as f:
    c = f.read()
block = '''
static inline const struct cred *get_cred_rcu(const struct cred *cred)
{
	struct cred *nonconst_cred = (struct cred *) cred;
	if (!cred)
		return NULL;
	if (!atomic_inc_not_zero(&nonconst_cred->usage))
		return NULL;
	return cred;
}
'''
if 'get_cred_rcu' not in c:
    anchor = 'static inline void put_cred(const struct cred *_cred)'
    c = c.replace(anchor, anchor + '\n' + block, 1) if anchor in c else c + block
    with open(path, 'w') as f:
        f.write(c)
    print("[+] get_cred_rcu ajoute")
PYEOF
fi

sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ==================== 5. CONFIGURATION (gcc classique, modules actives) ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -iname "*kiev*" -o -iname "*lito*" -o -iname "*sm8250*" | head -1)
[ -z "$CONFIG" ] && { echo "ERREUR: aucun defconfig kiev/lito/sm8250 trouve"; find arch/arm64/configs -maxdepth 2 | sort; exit 1; }
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisee: $CONFIG_NAME"

make O=out ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE $CONFIG_NAME

./scripts/config --file out/.config \
    --enable KSU \
    --enable KSU_MANUAL_HOOK \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS \
    --disable KSU_SUSFS

make O=out ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
grep -E "^CONFIG_KSU|^CONFIG_LOCALVERSION" out/.config || true

# ==================== 6. COMPILATION (noyau + TOUS les modules) ====================
echo "=== Compilation Image + modules ==="
make O=out ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE KCFLAGS="-Wno-error" \
    -j"$(nproc)" Image modules 2>&1 | tee build.log

[ -f "out/arch/arm64/boot/Image" ] || { echo "BUILD FAILED"; grep -i "error:" build.log | head -50; exit 1; }
echo "[+] Compilation reussie"
strings out/arch/arm64/boot/Image | grep -m1 "Linux version" || true

KVER=$(cat out/include/config/kernel.release 2>/dev/null || make -s O=out kernelrelease)
echo "Kernel release : $KVER"
MODULE_COUNT=$(find out -name "*.ko" | wc -l)
echo "Modules compiles : $MODULE_COUNT"
[ "$MODULE_COUNT" -eq 0 ] && echo "::warning::Aucun module .ko genere"

# ==================== 7. RECUPERATION DU BOOT/DTBO DE REFERENCE ====================
cd "$GITHUB_WORKSPACE"
echo "=== Telechargement des images de reference ($STOCK_DATE) ==="
curl -fL --retry 3 -o boot-stock.img "$BOOT_URL" || { echo "ERREUR: boot.img introuvable: $BOOT_URL"; exit 1; }
curl -fL --retry 3 -o dtbo.img "$DTBO_URL" || echo "[!] dtbo.img non telecharge (non bloquant)"
ls -l boot-stock.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
mkdir -p mb repack
unzip -q -o Magisk.apk lib/x86_64/libmagiskboot.so -d mb
cp mb/lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot

cd repack
cp ../boot-stock.img boot.img
set +e
./magiskboot unpack boot.img
set -e
[ -f kernel ] || { echo "ERREUR: unpack du boot stock a echoue"; exit 1; }
[ -f ramdisk.cpio ] || { echo "ERREUR: pas de ramdisk.cpio"; exit 1; }

# ==================== 8. INJECTION DU NOYAU + DES MODULES ====================
echo "=== Injection du noyau ==="
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

echo "=== Injection des modules ($MODULE_COUNT .ko) ==="
MODDIR_HOST="mods_tmp/lib/modules/${KVER}"
mkdir -p "$MODDIR_HOST"
: > "$MODDIR_HOST/modules.load"
find "$GITHUB_WORKSPACE/kernel_sources/out" -name "*.ko" | while read -r ko; do
    cp "$ko" "$MODDIR_HOST/$(basename "$ko")"
    basename "$ko" >> "$MODDIR_HOST/modules.load"
done
cp "$MODDIR_HOST/modules.load" "$MODDIR_HOST/modules.order"

CPIO_ADD_ARGS=()
while IFS= read -r f; do
    CPIO_ADD_ARGS+=("add" "0644" "lib/modules/${KVER}/$(basename "$f")" "$f")
done < <(find "$MODDIR_HOST" -name "*.ko")

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 lib" \
    "mkdir 0755 lib/modules" \
    "mkdir 0755 lib/modules/${KVER}" \
    "add 0644 lib/modules/${KVER}/modules.load ${MODDIR_HOST}/modules.load" \
    "add 0644 lib/modules/${KVER}/modules.order ${MODDIR_HOST}/modules.order" \
    "${CPIO_ADD_ARGS[@]}"

./magiskboot repack boot.img new-boot.img || { echo "ERREUR: repack a echoue"; exit 1; }
cd ..

mkdir -p output
cp repack/new-boot.img "output/kiev-resukisu-official-boot.img"
[ -f dtbo.img ] && cp dtbo.img output/dtbo.img
cp kernel_sources/build.log output/

echo "=== BUILD TERMINE ==="
echo "Commit source : $COMMIT"
echo "Kernel release : $KVER"
echo "Modules injectes : $MODULE_COUNT"
ls -lh output/
