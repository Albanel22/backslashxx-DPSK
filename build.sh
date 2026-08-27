#!/bin/bash
set -e

echo "=== Début du build Backslashxx KernelSU + SusFS ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd "$GITHUB_WORKSPACE"

echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
  -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

echo "=== Intégration Backslashxx KernelSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

echo "=== Téléchargement du repo JackA1ltman ==="
git clone --depth=1 \
  https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git \
  /tmp/jack_repo 2>/dev/null || true

echo "=== Sauvegarde pré-patch de lockdep.c (AVANT tout patch) ==="
mkdir -p /tmp/kernel_backup/locking
cp kernel/locking/lockdep.c /tmp/kernel_backup/locking/lockdep.c.orig

echo "=== Application du patch SusFS 4.19 ==="
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)

if [ -z "$PATCH_419" ]; then
  echo "❌ Patch 4.19 non trouvé dans le repo JackA1ltman"
  find /tmp/jack_repo/Patches -name "*.patch" | head -20
  exit 1
fi

echo "Application du patch: $PATCH_419"
set +e
patch -p1 --no-backup-if-mismatch < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log
PATCH_EXIT=$?
set -e

if [ "$PATCH_EXIT" -ne 0 ] && [ "$PATCH_EXIT" -ne 1 ]; then
  echo "❌ Échec critique du patch (code $PATCH_EXIT)"
  exit 1
fi

echo "=== Vérification des .rej ==="
REJ_COUNT=$(find . -name "*.rej" -type f | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
  echo "⚠️ $REJ_COUNT fichier(s) .rej détecté(s) :"
  find . -name "*.rej" -type f | while read -r rej; do
    echo "REJ: $rej"
    echo "----- Contenu de $rej -----"
    cat "$rej" 2>/dev/null || true
  done
  mkdir -p ../output/manual-hooks-diag
  for f in fs/exec.c fs/open.c fs/stat.c fs/namespace.c fs/proc/task_mmu.c kernel/sys.c security/selinux/avc.c; do
    cp --parents "$f" ../output/manual-hooks-diag/ 2>/dev/null || true
  done
fi

echo "=== Application du script officiel susfs_inline_hook_patches.sh (backslashxx) ==="

cat > ./susfs_inline_hook_patches.sh << 'HOOKSCRIPT_EOF'
#!/bin/bash
# Patches author: simonpunk @ Gitlab
#                 backslashxx @ Github
# Shell authon: JackA1ltman <cs2dtzq@163.com>
# Tested kernel versions: 5.4, 4.19, 4.14, 4.9, 4.4, 3.18
# 20251120

# This Hook is only available for SuSFS v2.1.00 onwards.

patch_files=(
    fs/exec.c
    fs/open.c
    fs/read_write.c
    fs/stat.c
    fs/namei.c
    drivers/input/input.c
    security/security.c
    security/selinux/hooks.c
    security/selinux/ss/services.c
    kernel/reboot.c
    kernel/sys.c
    include/linux/seccomp.h
)

PATCH_LEVEL="2.2.00"
KERNEL_VERSION=$(head -n 3 Makefile | grep -E 'VERSION|PATCHLEVEL' | awk '{print $3}' | paste -sd '.')
FIRST_VERSION=$(echo "$KERNEL_VERSION" | awk -F '.' '{print $1}')
SECOND_VERSION=$(echo "$KERNEL_VERSION" | awk -F '.' '{print $2}')

echo "Current susfs patch version:$PATCH_LEVEL"

for i in "${patch_files[@]}"; do

    if grep -q "ksu_handle" "$i"; then
        echo "[-] Warning: $i contains KernelSU"
        echo "[+] Code in here:"
        grep -n "ksu_handle" "$i"
        echo "[-] End of file."
        echo "======================================"
        continue
    fi

    case $i in
    # fs/ changes
    ## exec.c
    fs/exec.c)
        echo "======================================"

        if grep -q "vmalloc.h" "fs/exec.c"; then
            sed -i '/#include <linux\/vmalloc.h>/a\#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' fs/exec.c
        else
            sed -i '/#include <linux\/user_namespace.h>/a\#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' fs/exec.c
        fi

        if grep -q "__do_execve_file" "fs/exec.c"; then
            sed -i '/static int __do_execve_file(int fd, struct filename \*filename,/i #ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_su_compat_enabled;\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\tvoid *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\tvoid *envp, int *flags);\n#endif' fs/exec.c
        else
            sed -i '/^static int do_execveat_common(int fd, struct filename \*filename,/i\#ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_su_compat_enabled;\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\tvoid *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n\t\t\t\t void *argv, void *envp, int *flags);\n#endif\n' fs/exec.c
        fi
        sed -i '/return PTR_ERR(filename);/a\#ifdef CONFIG_KSU_SUSFS\n\tif (likely(susfs_is_current_proc_no_su()))\n\t\tgoto orig_flow;\n\tif (static_branch_likely(&ksu_su_compat_enabled)) {\n\t\tif (static_branch_unlikely(\&susfs_is_sdcard_android_data_not_decrypted))\n\t\tksu_handle_execveat(\&fd, \&filename, \&argv, \&envp, \&flags);\n\telse\n\t\tksu_handle_execveat_sucompat(\&fd, \&filename, \&argv, \&envp, \&flags);\n\t}\norig_flow:\n#endif' fs/exec.c

        if grep -q "ksu_handle_execveat_sucompat" "fs/exec.c"; then
            echo "[+] fs/exec.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_execveat_sucompat" "fs/exec.c")"
        else
            echo "[-] fs/exec.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;
    ## open.c
    fs/open.c)
        sed -i '/#include <linux\/compat.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux\/susfs_def.h>\n#endif' fs/open.c
        if grep -q "do_faccessat" "fs/open.c" >/dev/null 2>&1; then
            sed -i '/long do_faccessat(int dfd, const char __user \*filename, int mode)/i #ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_su_compat_enabled;\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\tint *flags);\n#endif' fs/open.c
        else
            sed -i '/SYSCALL_DEFINE3(faccessat/i #ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_su_compat_enabled;\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n             int *flags);\n#endif' fs/open.c
        fi
        sed -i '/if (mode & ~S_IRWXO)/i #ifdef CONFIG_KSU_SUSFS\n\tif (likely(susfs_is_current_proc_no_su()))\n\t\tgoto orig_flow;\n\tif (static_branch_likely(\&ksu_su_compat_enabled))\n\t\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val))) {\n\t\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n\t}\n\norig_flow:\n#endif' fs/open.c

        if grep -q "ksu_handle_faccessat" "fs/open.c"; then
            echo "[+] fs/open.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_faccessat" "fs/open.c")"
        else
            echo "[-] fs/open.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;
    ## read_write.c
    fs/read_write.c)
        sed -i '/SYSCALL_DEFINE3(read,/i #ifdef CONFIG_KSU\nextern struct static_key_true ksu_is_init_rc_hook_enabled;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd);\n#endif' fs/read_write.c
        if grep -q "ksys_read" "fs/read_write.c" >/dev/null 2>&1; then
            sed -i '/return ksys_read(fd, buf, count);/i #ifdef CONFIG_KSU\n\tif (static_branch_unlikely(\&ksu_is_init_rc_hook_enabled))\n\t\tksu_handle_sys_read(fd);\n#endif' fs/read_write.c
        else
            sed -i '0,/if (f\.file) {/{s/if (f\.file) {/\n#ifdef CONFIG_KSU\n\tif (static_branch_unlikely(\&ksu_is_init_rc_hook_enabled))\n\t\tksu_handle_sys_read(fd);\n#endif\n\tif (f.file) {/}' fs/read_write.c
        fi

        if grep -q "ksu_init_rc_hook" "fs/read_write.c"; then
            echo "[+] fs/read_write.c Patched!"
            echo "[+] Count: $(grep -c "ksu_init_rc_hook" "fs/read_write.c")"
        elif grep -q "ksu_handle_sys_read" "fs/read_write.c"; then
            echo "[+] fs/read_write.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_sys_read" "fs/read_write.c")"
        else
            echo "[-] fs/read_write.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;
    ## stat.c
    fs/stat.c)
        if grep -q "unistd" "fs/stat.c" && ! grep -q "susfs_def.h" "fs/stat.c"; then
            sed -i '/#include <asm\/unistd.h>/a\#ifdef CONFIG_KSU_SUSFS\n#include <linux\/susfs_def.h>\n#endif' fs/stat.c
        elif ! grep -q "susfs_def.h" "fs/stat.c"; then
            sed -i '/#include <asm\/uaccess.h>/i #ifdef CONFIG_KSU_SUSFS\n#include <linux\/susfs_def.h>\n#endif' fs/stat.c
        fi

        if grep -q "vfs_statx_fd" "fs/stat.c"; then
            sed -i '/int vfs_statx_fd(unsigned int fd, struct kstat \*stat,/i\#ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_is_init_rc_hook_enabled;\nextern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS\n' fs/stat.c

        elif grep -q "vfs_fstat" "fs/stat.c"; then
            sed -i '/int vfs_fstat(unsigned int fd, struct kstat \*stat)/i\#ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_is_init_rc_hook_enabled;\nextern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS\n' fs/stat.c

        else
            echo "[-] Kernel have no vfs_statx_fd and vfs_fstat."
        fi

        if grep -q "vfs_statx" "fs/stat.c"; then
            sed -i '/^int vfs_statx(int dfd, const char __user \*filename, int flags,/i\#ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_su_compat_enabled;\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' fs/stat.c
            sed -i '/if ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |/i\#ifdef CONFIG_KSU_SUSFS\n\tif (likely(susfs_is_current_proc_no_su()))\n\t\tgoto orig_flow;\n\tif (static_branch_likely(\&ksu_su_compat_enabled)) {\n\t\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))\n\t\t\tksu_handle_stat(\&dfd, \&filename, \&flags);\n\t}\norig_flow:\n#endif\n' fs/stat.c

        elif grep -q "vfs_fstatat" "fs/stat.c"; then
            sed -i '/^int vfs_fstatat(int dfd, const char __user \*filename, struct kstat \*stat,/i\#ifdef CONFIG_KSU_SUSFS\nextern struct static_key_true ksu_su_compat_enabled;\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' fs/stat.c
            sed -i '/if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |/i\#ifdef CONFIG_KSU_SUSFS\n\tif (likely(susfs_is_current_proc_no_su()))\n\t\tgoto orig_flow;\n\tif (static_branch_likely(\&ksu_su_compat_enabled)) {\n\t\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))\n\t\t\tksu_handle_stat(\&dfd, \&filename, \&flag);\n\t}\norig_flow:\n#endif\n' fs/stat.c

        else
            echo "[-] Kernel have no vfs_statx and vfs_fstatat."
        fi

        sed -i '/fdput(f);/i\#ifdef CONFIG_KSU_SUSFS\n\t\tif (static_branch_unlikely(\&ksu_is_init_rc_hook_enabled))\n\t\t\tksu_handle_vfs_fstat(fd, \&stat->size);\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS\n' fs/stat.c

        if grep -q "ksu_handle_stat" "fs/stat.c"; then
            echo "[+] fs/stat.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_stat" "fs/stat.c")"
        else
            echo "[-] fs/stat.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;
    ## namei.c
    fs/namei.c)
        if grep "throne_tracker" "fs/namei.c" >/dev/null 2>&1; then
            echo "[-] Warning: fs/namei.c contains KernelSU"
            echo "[+] Code in here:"
            grep -n "throne_tracker" "fs/namei.c"
            echo "[-] End of file."
        elif [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 19 ]; then
            sed -i '/if (unlikely(err)) {/a \#ifdef CONFIG_KSU\n\t\tif (unlikely(strstr(current->comm, "throne_tracker"))) {\n\t\t\terr = -ENOENT;\n\t\t\tgoto out_err;\n\t\t}\n#endif' fs/namei.c

            if grep -q "throne_tracker" "fs/namei.c"; then
                echo "[+] fs/namei.c Patched!"
                echo "[+] Count: $(grep -c "throne_tracker" "fs/namei.c")"
            else
                echo "[-] fs/namei.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] Kernel needn't throne_tracker, Skipped."
        fi

        echo "======================================"
        ;;

    # drivers/ changes
    ## input/input.c
    drivers/input/input.c)
        sed -i '/^static void input_handle_event(struct input_dev \*dev,/i\#ifdef CONFIG_KSU\nextern struct static_key_true ksu_is_input_hook_enabled;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif\n' drivers/input/input.c
        sed -i '/input_get_disposition(dev, type, code, \&value);/a\#ifdef CONFIG_KSU_SUSFS\n\tif (static_branch_unlikely(\&ksu_is_input_hook_enabled))\n\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\n#endif\n' drivers/input/input.c

        if grep -q "ksu_handle_input_handle_event" "drivers/input/input.c"; then
            echo "[+] drivers/input/input.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_input_handle_event" "drivers/input/input.c")"
        else
            echo "[-] drivers/input/input.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;

    # security/ changes
    ## security.c
    security/security.c)
        if [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 19 ]; then
            sed -i '/int security_binder_set_context_mgr(struct task_struct/i \#ifdef CONFIG_KSU\n\extern int ksu_bprm_check(struct linux_binprm *bprm);\n\extern int ksu_handle_rename(struct dentry *old_dentry, struct dentry *new_dentry);\n\extern int ksu_handle_setuid(struct cred *new, const struct cred *old);\n\#endif' security/security.c
            sed -i '/ret = security_ops->bprm_check_security(bprm);/i \#ifdef CONFIG_KSU\n\tksu_bprm_check(bprm);\n\#endif' security/security.c
            sed -i '/if (unlikely(IS_PRIVATE(old_dentry->d_inode) ||/i \#ifdef CONFIG_KSU\n\tksu_handle_rename(old_dentry, new_dentry);\n\#endif' security/security.c
            sed -i '/return security_ops->task_fix_setuid(new, old, flags);/i \#ifdef CONFIG_KSU\n\tksu_handle_setuid(new, old);\n\#endif' security/security.c

            if grep -q "ksu_handle_setuid" "security/security.c"; then
                echo "[+] security/security.c Patched!"
                echo "[+] Count: $(grep -c "ksu_handle_setuid" "security/security.c")"
            else
                echo "[-] security/security.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] Kernel needn't setuid, Skipped."
        fi

        echo "======================================"
        ;;
    ## selinux/hooks.c
    security/selinux/hooks.c)
        if grep "security_secid_to_secctx" "security/selinux/hooks.c"; then
            echo "[-] Detected security_secid_to_secctx existed, security/selinux/hooks.c Patched!"
        else
            sed -i '/int nnp = (bprm->unsafe & LSM_UNSAFE_NO_NEW_PRIVS);/i\#ifdef CONFIG_KSU\n    static u32 ksu_sid;\n    char *secdata;\n#endif' security/selinux/hooks.c
            sed -i '/if (!nnp && !nosuid)/i\#ifdef CONFIG_KSU\n    int error;\n    u32 seclen;\n#endif' security/selinux/hooks.c
            sed -i '/return 0; \/\* No change in credentials \*\//a\\n#ifdef CONFIG_KSU\n    if (!ksu_sid)\n        security_secctx_to_secid("u:r:su:s0", strlen("u:r:su:s0"), &ksu_sid);\n\n    error = security_secid_to_secctx(old_tsec->sid, &secdata, &seclen);\n    if (!error) {\n        rc = strcmp("u:r:init:s0", secdata);\n        security_release_secctx(secdata, seclen);\n        if (rc == 0 && new_tsec->sid == ksu_sid)\n            return 0;\n    }\n#endif' security/selinux/hooks.c
        fi

        if grep -q "security_secid_to_secctx" "security/selinux/hooks.c"; then
            echo "[+] security/selinux/hooks.c Patched!"
            echo "[+] Count: $(grep -c "security_secid_to_secctx" "security/selinux/hooks.c")"
        else
            echo "[-] security/selinux/hooks.c patch failed for unknown reasons, please provide feedback in time."
        fi

        if grep -rq --include="*.c" --include="*.h" "ksu_hide_setprocattr" "drivers/kernelsu/" >/dev/null 2>&1; then
            if [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 19 ]; then
                echo "[-] Kernel could not hook ksu_hide_setprocattr, Skipped."

            elif [ "$FIRST_VERSION" -lt 5 ] && [ "$SECOND_VERSION" -lt 10 ]; then
                sed -i '/static int selinux_setprocattr(struct task_struct \*p,/i\#ifdef CONFIG_KSU\nextern int ksu_hide_setprocattr(const char *name, void *value, size_t size);\n#endif\n' security/selinux/hooks.c
            else
                sed -i '/static int selinux_setprocattr(const char \*name, void \*value, size_t size)/i\#ifdef CONFIG_KSU\nextern int ksu_hide_setprocattr(const char *name, void *value, size_t size);\n#endif\n' security/selinux/hooks.c
            fi

            count=$(grep -rEho "char\s*\*?\s*str\s*=\s*value\s*;" "security/selinux/hooks.c" | wc -l)

            if [ "$count" -eq 1 ]; then
                sed -i '/char \*str = value;/a\#ifdef CONFIG_KSU\n\tksu_hide_setprocattr(name, value, size);\n#endif\n' security/selinux/hooks.c
            else
                sed -i '0,/char \*str = value;/b; /char \*str = value;/a\#ifdef CONFIG_KSU\n    ksu_hide_setprocattr(name, value, size);\n#endif\n' security/selinux/hooks.c
            fi

            if grep -q "ksu_hide_setprocattr" "security/selinux/hooks.c"; then
                echo "[+] security/selinux/hooks.c Part II Patched!"
                echo "[+] Count: $(grep -c "ksu_hide_setprocattr" "security/selinux/hooks.c")"
            else
                echo "[-] security/selinux/hooks.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] KernelSU needn't ksu_hide_setprocattr, Skipped."
        fi

        echo "======================================"
        ;;
    ## selinux/ss/services.c
    security/selinux/ss/services.c)
        if grep -q "selinux_state" "security/selinux/include/security.h" >/dev/null 2>&1; then
            echo "[-] Kernel needn't selinux_state fix, Skipped."

        elif [ "$FIRST_VERSION" -lt 5 ] && [ "$SECOND_VERSION" -lt 15 ]; then
            sed -i 's/static DEFINE_RWLOCK(policy_rwlock);/DEFINE_RWLOCK(policy_rwlock);/' security/selinux/ss/services.c

            if ! grep -q "static DEFINE_RWLOCK" "security/selinux/ss/services.c"; then
                echo "[+] security/selinux/hooks.c Patched!"
                echo "[+] Count: $(grep -c "static DEFINE_RWLOCK" "security/selinux/ss/services.c")"
            else
                echo "[-] security/selinux/hooks.c patch failed for unknown reasons, please provide feedback in time."
            fi
        fi

        echo "======================================"
        ;;

    # kernel/ changes
    ## reboot.c
    kernel/reboot.c)
        sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#ifdef CONFIG_KSU_SUSFS\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\
#endif\
' kernel/reboot.c
        sed -i '/int ret = 0;/a\
#ifdef CONFIG_KSU_SUSFS\
    if (system_state == SYSTEM_RUNNING) {\
        ksu_handle_sys_reboot(magic1, magic2, cmd, \&arg);\
    }\
#endif\
' kernel/reboot.c

        if grep -q "ksu_handle_sys_reboot" "kernel/reboot.c"; then
            echo "[+] kernel/reboot.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_sys_reboot" "kernel/reboot.c")"
        else
            echo "[-] kernel/reboot.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;
    ## sys.c
    kernel/sys.c)
        if grep -rq --include="*.c" --include="*.h" "ksu_handle_setresuid" "drivers/kernelsu/" >/dev/null 2>&1; then

            if grep -q "__sys_setresuid" "kernel/sys.c" >/dev/null 2>&1; then
                sed -i '/^SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n' kernel/sys.c
                sed -i '/return __sys_setresuid(ruid, euid, suid);/i\#ifdef CONFIG_KSU_SUSFS\n\tif (ksu_handle_setresuid(ruid, euid, suid)) {\n\t\tpr_info("Something wrong with ksu_handle_setresuid()\\\\n");\n\t}\n#endif\n' kernel/sys.c
            else
                sed -i '/^SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n' kernel/sys.c
                sed -i '0,/\tif ((ruid != (uid_t) -1) && !uid_valid(kruid))/b; /\tif ((ruid != (uid_t) -1) && !uid_valid(kruid))/i\#ifdef CONFIG_KSU_SUSFS\n\tif (ksu_handle_setresuid(ruid, euid, suid)) {\n\t\tpr_info("Something wrong with ksu_handle_setresuid()\\\\n");\n\t}\n#endif' kernel/sys.c
            fi

            if grep -q "ksu_handle_setresuid" "kernel/sys.c"; then
                echo "[+] kernel/sys.c Patched!"
                echo "[+] Count: $(grep -c "ksu_handle_setresuid" "kernel/sys.c")"
            else
                echo "[-] kernel/sys.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] KernelSU have no ksu_handle_setresuid, Skipped."
        fi

        echo "======================================"
        ;;

    # include/ changes
    ## linux/seccomp.h
    include/linux/seccomp.h)
        echo "======================================"

        if grep -q "filter_count" "include/linux/seccomp.h" >/dev/null 2>&1; then
            echo "[-] Detected filter_count in kernel, Skipped."
        else
            sed -i '/#include <linux\/thread_info.h>/a\#include <linux\/atomic.h>' include/linux/seccomp.h
            sed -i '/struct seccomp_filter \*filter;/i\ \tatomic_t filter_count;' include/linux/seccomp.h

            if grep -q "filter_count" "include/linux/seccomp.h"; then
                echo "[+] include/linux/seccomp.h Patched!"
                echo "[+] Count: $(grep -c "filter_count" "include/linux/seccomp.h")"
            else
                echo "[-] include/linux/seccomp.h patch failed for unknown reasons, please provide feedback in time."
            fi
        fi

        echo "======================================"
        ;;
    esac

done
HOOKSCRIPT_EOF

chmod +x ./susfs_inline_hook_patches.sh
bash ./susfs_inline_hook_patches.sh 2>&1 | tee /tmp/susfs_hook_script.log

echo "=== Vérification robuste : les sources SusFS sont-elles compilées ? ==="
if [ -f "fs/susfs.c" ] && ! grep -q "susfs" fs/Makefile 2>/dev/null; then
  echo "[+] Ajout de susfs.o au fs/Makefile"
  echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile
fi
for susfs_file in kernel/susfs.c security/susfs.c; do
  if [ -f "$susfs_file" ]; then
    dir=$(dirname "$susfs_file")
    if ! grep -q "susfs" "$dir/Makefile" 2>/dev/null; then
      echo "[+] Ajout de susfs.o au $dir/Makefile"
      echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> "$dir/Makefile"
    fi
  fi
done

echo "=== Diagnostic: symboles SusFS dans drivers/kernelsu ==="
for sym in ksu_is_init_rc_hook_enabled ksu_handle_sys_read ksu_hide_setprocattr; do
  echo "--- $sym ---"
  grep -rn "$sym" drivers/kernelsu/ --include="*.c" --include="*.h" || echo "(aucune occurrence trouvée)"
done

echo "=== Ajout manuel des entrées Kconfig KSU_SUSFS (absentes de backslashxx/KernelSU) ==="
if ! grep -q "config KSU_SUSFS" drivers/kernelsu/Kconfig; then
  python3 - << 'PYEOF'
with open('drivers/kernelsu/Kconfig', 'r') as f:
    content = f.read()

susfs_block = '''
menuconfig KSU_SUSFS
	bool "KernelSU SUSFS support"
	depends on KSU
	default y
	help
	  Enable SUSFS (Susfs4KSU) root hiding features.

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

config KSU_SUSFS_SUS_MAP
	bool "sus_map"
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

endif # KSU_SUSFS
'''

content = content.replace('endmenu', susfs_block + '\nendmenu')

with open('drivers/kernelsu/Kconfig', 'w') as f:
    f.write(content)

print("OK: bloc KSU_SUSFS ajouté à drivers/kernelsu/Kconfig")
PYEOF
else
  echo "KSU_SUSFS déjà présent dans le Kconfig, rien à faire."
fi

echo "=== Corrections post-patch (fallback si le patch 4.19 a des rejets) ==="

# ---------- Correction fs/namespace.c ----------
python3 - << 'PYEOF'
import re

with open('fs/namespace.c', 'r') as f:
    content = f.read()

if 'susfs_def.h' not in content:
    content = content.replace(
        '#include <linux/sched/task.h>',
        '''#include <linux/sched/task.h>
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif'''
    )
    print("OK: includes + externs ajoutés dans namespace.c")

if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
    old = '''\tif (!type)\n\t\treturn ERR_PTR(-ENODEV);\n\n\tmnt = alloc_vfsmnt(name);\n\tif (!mnt)\n\t\treturn ERR_PTR(-ENOMEM);'''
    new = '''\tif (!type)\n\t\treturn ERR_PTR(-ENODEV);\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\t// - We will just stop checking for ksu process if /sdcard/Android is accessible,\n\t//   for the sake of performance\n\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {\n\t\tif (susfs_is_current_ksu_domain()) {\n\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");\n\t\t\tgoto bypass_orig_flow;\n\t\t}\n\t}\n#endif\n\n\tmnt = alloc_vfsmnt(name);\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nbypass_orig_flow:\n#endif\n\tif (!mnt)\n\t\treturn ERR_PTR(-ENOMEM);'''

    if old in content:
        content = content.replace(old, new, 1)
        print("OK: bloc vfs_kern_mount ajouté dans namespace.c")
    else:
        pattern = r'(if\s*\(\s*!type\s*\)\s*\n\s*return ERR_PTR\(-ENODEV\);\s*\n\s*)(mnt\s*=\s*alloc_vfsmnt\(name\);)'
        replacement = r'''\1#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\t// - We will just stop checking for ksu process if /sdcard/Android is accessible,\n\t//   for the sake of performance\n\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {\n\t\tif (susfs_is_current_ksu_domain()) {\n\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");\n\t\t\tgoto bypass_orig_flow;\n\t\t}\n\t}\n#endif\n\n\t\2\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nbypass_orig_flow:\n#endif'''
        content_new, n = re.subn(pattern, replacement, content, count=1)
        if n:
            content = content_new
            print("OK: bloc vfs_kern_mount ajouté (regex) dans namespace.c")
        else:
            print("ATTENTION: pattern vfs_kern_mount non trouvé exactement")

with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

# ---------- Correction fs/proc/task_mmu.c ----------
python3 - << 'PYEOF'
import re

with open('fs/proc/task_mmu.c', 'r') as f:
    content = f.read()

if 'SUSFS_IS_INODE_SUS_MAP' not in content:
    old = '''\t\tret = down_read_killable(&mm->mmap_sem);\n\t\tif (ret)\n\t\t\tgoto out_free;\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n\t\tup_read(&mm->mmap_sem);'''
    new = '''\t\tret = down_read_killable(&mm->mmap_sem);\n\t\tif (ret)\n\t\t\tgoto out_free;\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tup_read(&mm->mmap_sem);'''

    if old in content:
        content = content.replace(old, new, 1)
        print("OK: bloc SUS_MAP ajouté dans task_mmu.c")
    else:
        pattern = r'(ret\s*=\s*down_read_killable\(&mm->mmap_sem\);\s*\n\s*if\s*\(ret\)\s*\n\s*goto out_free;\s*\n\s*)(ret\s*=\s*walk_page_range\(start_vaddr,\s*end,\s*&pagemap_walk\);)'
        replacement = r'''\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif\n\t\t\2\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif'''
        content_new, n = re.subn(pattern, replacement, content, count=1)
        if n:
            content = content_new
            print("OK: bloc SUS_MAP ajouté (regex) dans task_mmu.c")
        else:
            print("ATTENTION: pattern pagemap_read non trouvé exactement")

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)
PYEOF

echo "=== Corrections post-patch (suite) ==="
sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true

if ! grep -q "susfs_def.h" fs/namespace.c; then
  sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
cat > /tmp/hook_setresuid.py << 'PYEOF'
import re

with open('kernel/sys.c', 'r') as f:
    content = f.read()

if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    pattern = r'(long __sys_setresuid)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

    old_code = '''\tbool ruid_new, euid_new, suid_new;'''
    new_code = '''\tbool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
\t(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''

    if old_code in content:
        content = content.replace(old_code, new_code, 1)
    else:
        old_code2 = '''\tkuid_t kruid, keuid, ksuid;'''
        new_code2 = '''\tkuid_t kruid, keuid, ksuid;
#ifdef CONFIG_KSU_SUSFS
\t(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
        if old_code2 in content:
            content = content.replace(old_code2, new_code2, 1)

with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
fi

echo "=== Contenu Kconfig KernelSU ==="
cat drivers/kernelsu/Kconfig
echo "=== Fin Kconfig KernelSU ==="

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG=$(find arch/arm64/configs/ \
  \( -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" \) \
  | head -1)
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  "$CONFIG_NAME"

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KPROBES is not set"
  echo "# CONFIG_HAVE_KPROBES is not set"
  echo "# CONFIG_KPROBE_EVENTS is not set"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
} >> out/.config

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  olddefconfig

echo "=== Vérification ==="
grep -E "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KPROBES|CONFIG_KSU_SUSFS" out/.config

echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "=== Restauration INFAILLIBLE de lockdep.c (cp depuis backup) ==="
cp /tmp/kernel_backup/locking/lockdep.c.orig kernel/locking/lockdep.c
if grep -q "get_pending_free\|call_rcu_zapped\|__lockdep_free_key_range" kernel/locking/lockdep.c 2>/dev/null; then
  echo "❌ lockdep.c est encore corrompu après restauration cp, abandon"
  exit 1
else
  echo "[+] kernel/locking/lockdep.c est propre (restauré depuis backup)"
fi

echo "=== Compilation finale ==="
make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  -j"$(nproc)" Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi
echo "✅ Compilation réussie"

echo "=== Vérification KernelSU ==="
grep -E "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KSU_SUSFS" out/.config || true
strings out/arch/arm64/boot/Image | grep -i "ksu_" | head -50 || true

echo "=== Compilation de ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/backslashxx/KernelSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

echo "=== Vérification SU Backslashxx ==="
test -f src/su.rs
test -f src/cli.rs
grep -n "pub fn root_shell" src/su.rs
grep -n 'arg0 == "su"' src/cli.rs

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

cd "$GITHUB_WORKSPACE"
echo "=== Téléchargement des images stock ==="
curl -fLo boot-stock.img \
  "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img" \
  2>/dev/null || {
    mkbootimg \
      --kernel kernel_sources/out/arch/arm64/boot/Image \
      --ramdisk /dev/null \
      --output final_boot.img \
      --header_version 2 \
      --pagesize 4096 \
      --base 0x00000000 \
      --kernel_offset 0x00008000 \
      --ramdisk_offset 0x01000000 \
      --tags_offset 0x00000100 \
      --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
  }

curl -fLo dtbo-stock.img \
  "https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" \
  2>/dev/null || true

if [ -f "boot-stock.img" ]; then
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
  UNPACK_EXIT=$?
  set -e

  if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec réel du unpack"
    exit 1
  fi

  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

  echo "=== Installation de ksud ==="
  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

  echo "=== Installation de SU ==="
  cp "$GITHUB_WORKSPACE/ksud" local_su_binary
  chmod 755 local_su_binary
  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
  rm -f local_su_binary

  echo "=== Vérification SU/ksud dans ramdisk ==="
  ./magiskboot cpio ramdisk.cpio list | grep -E '(^|/)(su|ksud)$' || true

  ./magiskboot repack boot.img new-boot.img || {
    echo "❌ Échec du repack"
    exit 1
  }
  mv new-boot.img ../final_boot.img
  cd ..
fi

echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
