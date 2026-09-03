*** Begin Patch
*** Update File: fs/open.c
@@
-int do_truncate2(struct vfsmount *mnt, struct dentry *dentry, loff_t length,
-        u
-nsigned int time_attrs, struct file *filp)
+int do_truncate2(struct vfsmount *mnt, struct dentry *dentry, loff_t length,
+        unsigned int time_attrs, struct file *filp)
@@
 }
*** End Patch
