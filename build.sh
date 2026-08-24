#!/bin/bash
set -e

echo "=== Début du build Backslashxx KernelSU + SusFS (Manual Hook) ==="
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

echo "=== Hooks manuels sucompat (fs/exec.c, fs/open.c, fs/stat.c) ==="

mkdir -p ../output/manual-hooks-diag

hook_insert() {
  local file="$1" sig_re="$2" extern_block="$3" call_line="$4"

  if [ ! -f "$file" ]; then
    echo "❌ $file introuvable."
    return 1
  fi

  if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then
    echo "❌ Signature attendue introuvable dans $file — hook NON inséré."
    return 1
  fi

  perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"

  echo "[+] Hook inséré dans $file"
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
  echo "❌ Ni do_faccessat ni SYSCALL_DEFINE3(faccessat...) trouvé dans fs/open.c"
  HOOKS_FAILED=1
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
  echo "❌ Ni vfs_statx ni vfs_fstatat trouvé dans fs/stat.c"
  HOOKS_FAILED=1
fi

if [ "$HOOKS_FAILED" -eq 1 ]; then
  echo "❌ Au moins un hook sucompat n'a pas pu être inséré automatiquement."

  for f in fs/exec.c fs/open.c fs/stat.c; do
    cp --parents "$f" ../output/manual-hooks-diag/ 2>/dev/null || true
  done

  exit 1
fi

echo "✅ Les 3 hooks sucompat sont en place."

echo "=== Téléchargement du repo JackA1ltman ==="

git clone --depth=1 \
  https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git \
  /tmp/jack_repo 2>/dev/null || true

echo "=== Application du patch SusFS 4.19 ==="

PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)

if [ -n "$PATCH_419" ]; then
  echo "Application du patch: $PATCH_419"
  patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
else
  echo "Recherche des patches..."
  find /tmp/jack_repo/Patches -name "*.patch" | head -20
fi

echo "=== Vérification des .rej ==="

find . -name "*.rej" -type f | while read -r rej; do
  echo "REJ: $rej"
  echo "----- Contenu de $rej -----"
  cat "$rej" 2>/dev/null || true
done

echo "=== Application du script officiel susfs_inline_hook_patches.sh (backslashxx) ==="

cat > ./susfs_inline_hook_patches.sh << 'HOOKSCRIPT_EOF'
#!/bin/bash
# Patches author: backslashxx @ Github
# Shell author: JackA1ltman <cs2dtzq@163.com>
# Tested kernel versions: 5.4, 4.19, 4.14, 4.9, 4.4, 3.18
# 20250309

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

PATCH_LEVEL="2.2"
KERNEL_VERSION=$(head -n 3 Makefile | grep -E 'VERSION|PATCHLEVEL' | awk '{print $3}' | paste -sd '.')
FIRST_VERSION=$(echo "$KERNEL_VERSION" | awk -F '.' '{print $1}')
SECOND_VERSION=$(echo "$KERNEL_VERSION" | awk -F '.' '{print $2}')

echo "Current syscall patch version:$PATCH_LEVEL"

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

        sed -i '/int do_execve(struct filename \*filename,/i\#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n\t\t\t\tvoid *argv, void *envp, int *flags);\n#endif\n' fs/exec.c
        sed -i '/return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);/i\#ifdef CONFIG_KSU\n\tksu_handle_execveat((int \*)AT_FDCWD, \&filename, \&argv, \&envp, 0);\n#endif\n' fs/exec.c

        if grep -q "ksu_handle_execveat" "fs/exec.c"; then
            echo "[+] fs/exec.c Patched!"
            echo "[+] Count: $(grep -c "ksu_handle_execveat" "fs/exec.c")"
        else
            echo "[-] fs/exec.c patch failed for unknown reasons, please provide feedback in time."
        fi

        echo "======================================"
        ;;
    ## open.c
    fs/open.c)
        if [ "$FIRST_VERSION" -lt 5 ] && [ "$SECOND_VERSION" -lt 19 ]; then
            sed -i '/^SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/i\#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *mode, int *flags);\n#endif\n' fs/open.c
            sed -i '/if (mode & ~S_IRWXO)/i \#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif' fs/open.c
        else
            sed -i '/^SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/i\#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *mode, int *flags);\n#endif\n' fs/open.c
            sed -i '/return do_faccessat(dfd, filename, mode);/i \#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif' fs/open.c
        fi

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
        if grep -rq --include="*.c" --include="*.h" "ksu_handle_sys_read_fd" "drivers/kernelsu/" && ! grep -rqw --include="*.c" --include="*.h" "ksu_handle_sys_read" "drivers/kernelsu/" >/dev/null 2>&1; then
            echo "[-] KernelSU have no ksu_handle_sys_read, Skipped."

        elif grep -rq --include="*.c" --include="*.h" "ksu_handle_sys_read" "drivers/kernelsu/" >/dev/null 2>&1; then
            if grep -rq --include="*.c" --include="*.h" "ksu_init_rc_hook" "drivers/kernelsu/" >/dev/null 2>&1; then
                sed -i '/SYSCALL_DEFINE3(read, unsigned int, fd, char __user \*, buf, size_t, count)/i\#ifdef CONFIG_KSU\nextern bool ksu_init_rc_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,\n\t\t\t\tchar __user **buf_ptr, size_t *count_ptr);\n#endif\n' fs/read_write.c

                if [ "$FIRST_VERSION" -lt 5 ] && [ "$SECOND_VERSION" -lt 19 ]; then
                    sed -i '0,/if (f\.file) {/{s/if (f\.file) {/\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd, \&buf, \&count);\n#endif\n\tif (f.file) {/}' fs/read_write.c
                else
                    sed -i '/return ksys_read(fd, buf, count);/i\#ifdef CONFIG_KSU\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif' fs/read_write.c
                fi
            else
                sed -i '/SYSCALL_DEFINE3(read, unsigned int, fd, char __user \*, buf, size_t, count)/i\#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,\n\t\t\t\tchar __user **buf_ptr, size_t *count_ptr);\n#endif\n' fs/read_write.c

                if [ "$FIRST_VERSION" -lt 5 ] && [ "$SECOND_VERSION" -lt 19 ]; then
                    sed -i '0,/if (f\.file) {/{s/if (f\.file) {/\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, \&buf, \&count);\n#endif\n\tif (f.file) {/}' fs/read_write.c
                else
                    sed -i '/return ksys_read(fd, buf, count);/i\#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif' fs/read_write.c
                fi
            fi

            if grep -q "ksu_handle_sys_read" "fs/read_write.c"; then
                echo "[+] fs/read_write.c Patched!"
                echo "[+] Count: $(grep -c "ksu_handle_sys_read" "fs/read_write.c")"
            else
                echo "[-] fs/read_write.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] KernelSU have no ksu_handle_sys_read, Skipped."
        fi

        echo "======================================"
        ;;
    ## stat.c
    fs/stat.c)
        if grep -rq --include="*.c" --include="*.h" "ksu_handle_newfstat_ret" "drivers/kernelsu/" >/dev/null 2>&1; then
            sed -i '/#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)/i\#ifdef CONFIG_KSU\nextern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);\n#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)\nextern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);\n#endif\n#endif\n' fs/stat.c
            sed -i '/extern void ksu_handle_newfstat_ret/i\__attribute__((hot))\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *flags);\n' fs/stat.c
        elif grep -q "vfs_statx_fd" "fs/stat.c" >/dev/null 2>&1; then
            sed -i '/EXPORT_SYMBOL(vfs_statx_fd);/a\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' fs/stat.c
        else
            sed -i '/EXPORT_SYMBOL(vfs_fstat);/a\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' fs/stat.c
        fi

        sed -i '/error = vfs_fstatat(dfd, filename, \&stat, flag);/i\#ifdef CONFIG_KSU\n\tksu_handle_stat(\&dfd, \&filename, \&flag);\n#endif\n' fs/stat.c

        if grep -rq --include="*.c" --include="*.h" "ksu_handle_newfstat_ret" "drivers/kernelsu/" >/dev/null 2>&1; then
            sed -i '/error = cp_new_stat(\&stat, statbuf);/a\#ifdef CONFIG_KSU\n\tksu_handle_newfstat_ret(\&fd, \&statbuf);\n#endif\n' fs/stat.c
            sed -i '0,/error = cp_new_stat64(\&stat, statbuf);/b; 0,/error = cp_new_stat64(\&stat, statbuf);/b; /error = cp_new_stat64(\&stat, statbuf);/a\#ifdef CONFIG_KSU\n\tksu_handle_fstat64_ret(\&fd, \&statbuf);\n#endif\n' fs/stat.c
        fi

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

    # drivers changes
    ## input/input.c
    drivers/input/input.c)
        if grep -rq --include="*.c" --include="*.h" "ksu_handle_input_handle_event" "drivers/kernelsu/" >/dev/null 2>&1; then
            sed -i '/^void input_event(struct input_dev \*dev,/i \#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_input_handle_event(\n\t\t\tunsigned int *type, unsigned int *code, int *value);\n#endif' drivers/input/input.c
            sed -i '0,/if (is_event_supported(type, dev->evbit, EV_MAX)) {/{s/if (is_event_supported(type, dev->evbit, EV_MAX)) {/\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\n#endif\n\tif (is_event_supported(type, dev->evbit, EV_MAX)) {/}' drivers/input/input.c

            if grep -q "ksu_handle_input_handle_event" "drivers/input/input.c"; then
                echo "[+] drivers/input/input.c Patched!"
                echo "[+] Count: $(grep -c "ksu_handle_input_handle_event" "drivers/input/input.c")"
            else
                echo "[-] drivers/input/input.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] KernelSU have no ksu_input_hook, Skipped."
        fi

        echo "======================================"
        ;;

    # security/ changes
    ## security.c
    security/security.c)
        if [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 19 ] && ! grep -rq --include="*.c" --include="*.h" "ksu_inode_rename" "drivers/kernelsu/" >/dev/null 2>&1; then
            if grep -rq --include="*.c" --include="*.h" "sys_read" "drivers/kernelsu/" >/dev/null 2>&1; then
                echo "[+] Checked sys_read existed in KernelSU!"

                sed -i '/int security_binder_set_context_mgr(struct task_struct/i \#ifdef CONFIG_KSU\n\extern int ksu_bprm_check(struct linux_binprm *bprm);\n\extern int ksu_handle_rename(struct dentry *old_dentry, struct dentry *new_dentry);\n\extern int ksu_handle_setuid(struct cred *new, const struct cred *old);\n\#endif' security/security.c
            else
                sed -i '/int security_binder_set_context_mgr(struct task_struct/i \#ifdef CONFIG_KSU\n\extern int ksu_bprm_check(struct linux_binprm *bprm);\n\extern int ksu_handle_rename(struct dentry *old_dentry, struct dentry *new_dentry);\n\extern int ksu_handle_setuid(struct cred *new, const struct cred *old);\nextern int ksu_file_permission(struct file *file, int mask);\n\#endif' security/security.c
            fi

            sed -i '/ret = security_ops->bprm_check_security(bprm);/i \#ifdef CONFIG_KSU\n\tksu_bprm_check(bprm);\n\#endif' security/security.c
            sed -i '0,/if (unlikely(IS_PRIVATE(old_dentry->d_inode) ||/b; /if (unlikely(IS_PRIVATE(old_dentry->d_inode) ||/i\#ifdef CONFIG_KSU\n\tksu_handle_rename(old_dentry, new_dentry);\n#endif\n' security/security.c

            if ! grep -q "sys_read" "drivers/kernelsu/arch.h" >/dev/null 2>&1; then
                sed -i '/ret = security_ops->file_permission(file, mask);/i\#ifdef CONFIG_KSU\n\tksu_file_permission(file, mask);\n#endif\n' security/security.c
            fi

            sed -i '/return security_ops->task_fix_setuid(new, old, flags);/i \#ifdef CONFIG_KSU\n\tksu_handle_setuid(new, old);\n\#endif' security/security.c

            if grep -q "ksu_handle_setuid" "security/security.c"; then
                echo "[+] security/security.c Patched!"
                echo "[+] Count: $(grep -c "ksu_handle_setuid" "security/security.c")"
            else
                echo "[-] security/security.c patch failed for unknown reasons, please provide feedback in time."
            fi
        elif grep -rq --include="*.c" --include="*.h" "ksu_inode_rename" "drivers/kernelsu/" >/dev/null 2>&1; then
            echo "[-] KernelSU needn't security.c hooks, Skipped."

        else
            echo "[-] Kernel needn't setuid, Skipped."
        fi

        echo "======================================"
        ;;
    ## selinux/hooks.c
    security/selinux/hooks.c)
        if grep -q "security_secid_to_secctx" "security/selinux/hooks.c" >/dev/null 2>&1; then
            echo "[-] Detected security_secid_to_secctx existed, security/selinux/hooks.c Patched!"
        elif [ "$FIRST_VERSION" -lt 5 ] && [ "$SECOND_VERSION" -lt 10 ]; then
            sed -i '/int nnp = (bprm->unsafe & LSM_UNSAFE_NO_NEW_PRIVS);/i\#ifdef CONFIG_KSU\n    static u32 ksu_sid;\n    char *secdata;\n#endif' security/selinux/hooks.c
            sed -i '/if (!nnp && !nosuid)/i\#ifdef CONFIG_KSU\n    int error;\n    u32 seclen;\n#endif' security/selinux/hooks.c
            sed -i '/return 0; \/\* No change in credentials \*\//a\\n#ifdef CONFIG_KSU\n    if (!ksu_sid)\n        security_secctx_to_secid("u:r:su:s0", strlen("u:r:su:s0"), &ksu_sid);\n\n    error = security_secid_to_secctx(old_tsec->sid, &secdata, &seclen);\n    if (!error) {\n        rc = strcmp("u:r:init:s0", secdata);\n        security_release_secctx(secdata, seclen);\n        if (rc == 0 && new_tsec->sid == ksu_sid)\n            return 0;\n    }\n#endif' security/selinux/hooks.c

            if grep -q "security_secid_to_secctx" "security/selinux/hooks.c"; then
                echo "[+] security/selinux/hooks.c Patched!"
                echo "[+] Count: $(grep -c "security_secid_to_secctx" "security/selinux/hooks.c")"
            else
                echo "[-] security/selinux/hooks.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] Kernel needn't selinux fix, Skipped."
        fi

        if [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 19 ]; then
            sed -i 's/static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c

            if ! grep -q "static struct security_operations selinux_ops" "security/selinux/hooks.c"; then
                echo "[+] security/selinux/hooks.c Part II Patched!"
                echo "[+] Count: $(grep -c "static struct security_operations selinux_ops" "security/selinux/hooks.c")"
            else
                echo "[-] security/selinux/hooks.c patch failed for unknown reasons, please provide feedback in time."
            fi

        else
            echo "[-] Kernel needn't selinux fix Part II, Skipped."

        fi

        if grep -rq --include="*.c" --include="*.h" "ksu_hide_setprocattr" "drivers/kernelsu/" && ! grep -rq --include="*.c" --include="*.h" "ksu_inode_rename" "drivers/kernelsu/" >/dev/null 2>&1; then
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
                echo "[+] security/selinux/hooks.c Part III Patched!"
                echo "[+] Count: $(grep -c "ksu_hide_setprocattr" "security/selinux/hooks.c")"
            else
                echo "[-] security/selinux/hooks.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] KernelSU needn't security extra hooks, Skipped."
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
    ## kernel/reboot.c
    kernel/reboot.c)
        if grep -rq --include="*.c" --include="*.h" "ksu_handle_sys_reboot" "drivers/kernelsu/" >/dev/null 2>&1; then
            echo "[+] Checked ksu_handle_sys_reboot existed in KernelSU!"

            sed -i '/SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,/i\
#ifdef CONFIG_KSU\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\
#endif\
' kernel/reboot.c
            sed -i '/if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))/i\
#ifdef CONFIG_KSU\
\tif (system_state == SYSTEM_RUNNING) {\
\t\tksu_handle_sys_reboot(magic1, magic2, cmd, \&arg);\
\t}\
#endif\
' kernel/reboot.c

            if grep -q "ksu_handle_sys_reboot" "kernel/reboot.c"; then
                echo "[+] kernel/reboot.c Patched!"
                echo "[+] Count: $(grep -c "ksu_handle_sys_reboot" "kernel/reboot.c")"
            else
                echo "[-] kernel/reboot.c patch failed for unknown reasons, please provide feedback in time."
            fi
        else
            echo "[-] KernelSU needn't ksu_handle_sys_reboot, Skipped."
        fi

        echo "======================================"
        ;;
    ## kernel/sys.c
    kernel/sys.c)
        if grep -rq --include="*.c" --include="*.h" "ksu_handle_setresuid_cred" "drivers/kernelsu/" >/dev/null 2>&1; then
            echo "[-] KernelSU needn't ksu_handle_setresuid, Skipped."

        elif grep -rq --include="*.c" --include="*.h" "ksu_handle_setresuid" "drivers/kernelsu/" >/dev/null 2>&1; then

            if grep -q "__sys_setresuid" "kernel/sys.c" >/dev/null 2>&1; then
                sed -i '/long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n' kernel/sys.c
                if grep -q "ruid_new" "kernel/sys.c"; then
                    sed -i '/bool ruid_new, euid_new, suid_new;/a\#ifdef CONFIG_KSU\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n' kernel/sys.c
                else
                    sed -i '/kuid_t kruid, keuid, ksuid;/a\#ifdef CONFIG_KSU\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n' kernel/sys.c
                fi
            else
                sed -i '/^SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n' kernel/sys.c
                sed -i '/kuid_t kruid, keuid, ksuid;/a\#ifdef CONFIG_KSU\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n' kernel/sys.c
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

echo "=== Diagnostic: pourquoi ces symboles ont-ils été détectés comme existants ? ==="
for sym in ksu_is_init_rc_hook_enabled ksu_handle_sys_read ksu_hide_setprocattr; do
  echo "--- $sym ---"
  grep -rn "$sym" drivers/kernelsu/ --include="*.c" --include="*.h" || echo "(aucune occurrence trouvée — étrange si le hook a été inséré)"
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

echo "=== Corrections manuelles des rejets SusFS ==="

# ---------- Correction fs/namespace.c ----------
python3 - << 'PYEOF'
import re

with open('fs/namespace.c', 'r') as f:
    content = f.read()

# 1. Includes + externs
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

# 2. Bloc vfs_kern_mount
if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
    old = '''	if (!type)
		return ERR_PTR(-ENODEV);

	mnt = alloc_vfsmnt(name);
	if (!mnt)
		return ERR_PTR(-ENOMEM);'''

    new = '''	if (!type)
		return ERR_PTR(-ENODEV);

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	// - We will just stop checking for ksu process if /sdcard/Android is accessible,
	//   for the sake of performance
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
			goto bypass_orig_flow;
		}
	}
#endif

	mnt = alloc_vfsmnt(name);

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif
	if (!mnt)
		return ERR_PTR(-ENOMEM);'''

    if old in content:
        content = content.replace(old, new, 1)
        print("OK: bloc vfs_kern_mount ajouté dans namespace.c")
    else:
        pattern = r'(if\s*\(\s*!type\s*\)\s*\n\s*return ERR_PTR\(-ENODEV\);\s*\n\s*)(mnt\s*=\s*alloc_vfsmnt\(name\);)'
        replacement = r'''\1#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	// - We will just stop checking for ksu process if /sdcard/Android is accessible,
	//   for the sake of performance
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
			goto bypass_orig_flow;
		}
	}
#endif

	\2

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif'''
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
    old = '''		ret = down_read_killable(&mm->mmap_sem);
		if (ret)
			goto out_free;
		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
		up_read(&mm->mmap_sem);'''

    new = '''		ret = down_read_killable(&mm->mmap_sem);
		if (ret)
			goto out_free;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
		up_read(&mm->mmap_sem);'''

    if old in content:
        content = content.replace(old, new, 1)
        print("OK: bloc SUS_MAP ajouté dans task_mmu.c")
    else:
        pattern = r'(ret\s*=\s*down_read_killable\(&mm->mmap_sem\);\s*\n\s*if\s*\(ret\)\s*\n\s*goto out_free;\s*\n\s*)(ret\s*=\s*walk_page_range\(start_vaddr,\s*end,\s*&pagemap_walk\);)'
        replacement = r'''\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif
		\2
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif'''
        content_new, n = re.subn(pattern, replacement, content, count=1)
        if n:
            content = content_new
            print("OK: bloc SUS_MAP ajouté (regex) dans task_mmu.c")
        else:
            print("ATTENTION: pattern pagemap_read non trouvé exactement")

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)
PYEOF

echo "=== Corrections post-patch ==="

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
    content = re.sub(
        pattern,
        extern_decl + '\n' + r'\1',
        content,
        count=1
    )

    old_code = '''	bool ruid_new, euid_new, suid_new;'''

    new_code = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''

    if old_code in content:
        content = content.replace(old_code, new_code, 1)
    else:

        old_code2 = '''	kuid_t kruid, keuid, ksuid;'''

        new_code2 = '''	kuid_t kruid, keuid, ksuid;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
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

grep -E \
  "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KPROBES|CONFIG_KSU_SUSFS" \
  out/.config

echo "=== Patch signatures + tactile ==="

sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "=== Compilation finale ==="

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  -j"$(nproc)" Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi

echo "=== Vérification KernelSU ==="

grep -E \
  "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KSU_SUSFS" \
  out/.config || true

strings out/arch/arm64/boot/Image | grep -i "ksu_" | head -50 || true

echo "=== Compilation de ksud ==="

cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf \
  https://sh.rustup.rs | sh -s -- -y

source "$HOME/.cargo/env"

rustup target add aarch64-linux-android

wget -q \
  https://dl.google.com/android/repository/android-ndk-r26d-linux.zip

unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"

git clone --depth=1 \
  https://github.com/backslashxx/KernelSU.git \
  "$GITHUB_WORKSPACE/ksud-src"

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

  wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O Magisk-v27.0.apk

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

  ./magiskboot cpio ramdisk.cpio list | \
    grep -E '(^|/)(su|ksud)$' || true

  ./magiskboot repack boot.img new-boot.img || {
    echo "❌ Échec du repack"
    exit 1
  }

  mv new-boot.img ../final_boot.img

  cd ..
fi

echo "=== Copie vers output ==="

mkdir -p output

cp final_boot.img \
  output/Backslashxx-SusFS-boot.img

cp dtbo-stock.img \
  output/dtbo.img 2>/dev/null || true

cp kernel_sources/build.log \
  output/

cp "$GITHUB_WORKSPACE/ksud" \
  output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="

ls -lh output/
