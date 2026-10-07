# 🚀 KernelSU + SUSFS pour Motorola One 5G Ace (kiev/lito)

![Android](https://img.shields.io/badge/Android-16-blue)
![Kernel](https://img.shields.io/badge/Kernel-4.19.325-orange)
![KernelSU](https://img.shields.io/badge/KernelSU-v3.3.0--52-purple)
![SUSFS](https://img.shields.io/badge/SUSFS-v2.3.0-red)

## 📋 Présentation

Ce projet compile un noyau **LineageOS 23.2 (Android 16 QPR2)** avec **KernelSU** (backslashxx v3.3.0-52) et le module **SUSFS** (nGKI 4.19) pour l'appareil **Motorola One 5G Ace** (nom de code : kiev / lito).

L'objectif est de fournir une solution de root kernel-based **furtive et stable**, capable de passer les vérifications d'intégrité les plus strictes tout en restant fonctionnelle au quotidien.

## 🛠️ Fonctionnalités intégrées

### KernelSU
- ✅ Root kernel-based avec hooks manuels (`sys_reboot`)
- ✅ `KSU_TAMPER_SYSCALL_TABLE` activé
- ✅ `KSU_LSM_SECURITY_HOOKS` activé
- ✅ `KSU_FEATURE_SULOG` et `KSU_FEATURE_ADBROOT` activés

### SUSFS (v2.3.0)

| Fonctionnalité | Description |
| :--- | :--- |
| `SUS_PATH` | Masquage des chemins suspects |
| `SUS_MOUNT` | Masquage des points de montage |
| `SUS_KSTAT` | Falsification des statistiques de fichiers |
| `SPOOF_UNAME` | Falsification de la version et de la date du noyau |
| `TRY_UMOUNT` | Démonte les systèmes de fichiers pour les processus non-root |
| `ENABLE_LOG` | Logs de débogage SUSFS |
| `HIDE_KSU_SUSFS_SYMBOLS` | Symboles KernelSU/SUSFS cachés dans `/proc/kallsyms` |
| `SPOOF_CMDLINE_OR_BOOTCONFIG` | Falsification des paramètres de démarrage |

### 🏆 Validation

Ce build a été testé contre les outils de détection les plus stricts du marché.

| Outil de test | Résultat |
| :--- | :--- |
| **RootBeer Fresh** | ✅ NOT ROOTED |
| **Play Integrity API Checker** | ✅ BASIC + DEVICE + STRONG |
| **Play Integrity Check** | ✅ Score 100/100 "Secure" |
| **Native Detector** | ✅ Environment is normal |

### Vérifications système
- ✅ `/proc/kallsyms` ne contient aucun symbole KSU/SUSFS
- ✅ Module userspace opérationnel (`/data/adb/ksu/susfs4ksu/logs/susfs_active`)
- ✅ Routage `supercall.c` fonctionnel (magic `0xFAFAFAFA` détecté)
- ✅ Toutes les fonctionnalités SUSFS communiquent correctement via l'ABI `sys_reboot`

 ### ⚙️ Build depuis les sources

Si tu souhaites compiler ton propre `boot.img` à partir de ce script, il y a **une étape critique** à ne pas oublier : **ajuster les dates des fichiers `boot-stock.img` et `dtbo-stock.img`**.

### Pourquoi c'est important ?

Le noyau compilé doit correspondre **exactement** à la version de LineageOS installée sur ton appareil. Les modules noyau (Wi-Fi, Bluetooth, capteurs, etc.) sont compilés en même temps que la ROM. Si tu flashes un `boot.img` basé sur une version différente de celle de ta ROM, tu risques :

- Un **bootloop** au démarrage
- Un **Wi-Fi ou Bluetooth non fonctionnel**
- Des **capteurs défaillants** (tactile, proximité, etc.)
- Une **instabilité générale** du système

### Comment ajuster ?

Dans le script de build, tu trouveras ces deux lignes (section **9. REPACK**) :

```bash
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img" 2>/dev/null || true

Remplace 20260920 par la date de la version de LineageOS installée sur ton appareil.

Comment trouver la bonne date ?
Via l'application LineageOS :

Paramètres → À propos du téléphone → Numéro de build

La date est souvent intégrée au numéro de build (ex: lineage-23.2-20260920-NIGHTLY-kiev)

Via ADB :

bash
adb shell getprop ro.build.version.incremental

Ou :

bash
adb shell getprop ro.build.date
Via le site LineageOS :

Rends-toi sur download.lineageos.org/kiev

Trouve la version correspondant à celle installée sur ton appareil

La date est dans le nom du fichier (ex: lineage-23.2-20260920-nightly-kiev-signed.zip)

Exemple concret
Si ton téléphone tourne sous lineage-23.2-20261005-NIGHTLY-kiev, tu dois modifier le script ainsi :

bash
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20261005/boot.img"
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20261005/dtbo.img" 2>/dev/null || true

⚠️ Attention
Les anciennes versions peuvent être supprimées des serveurs LineageOS. Si la date n'est plus disponible, tu devras :

Soit mettre à jour ta ROM vers la dernière version disponible

Soit compiler ton propre boot.img à partir des sources du noyau correspondant à ta version

Ne mélange jamais un boot.img d'une version avec une ROM d'une autre version. C'est la cause n°1 des bootloops après un build custom.

## 📥 Installation

### Prérequis
- Motorola One 5G Ace (kiev) avec bootloader déverrouillé
- LineageOS 23.2 installé
- ADB et fastboot configurés

### Étapes

1. **Télécharger les fichiers** depuis les releases :
   - `Backslashxx-SuSFS-IOCTL-boot.img`
   - `susfs4ksu-module.zip`
   - `ksud` (optionnel)

2. **Flasher le boot.img** :
   ```bash
   fastboot flash boot Backslashxx-SuSFS-IOCTL-boot.img
   fastboot reboot
   3. Installer l'application KernelSU :
   · Télécharger et installer l'APK KernelSU v3.3.0-52
4. Installer le module userspace SUSFS :
   · Ouvrir KernelSU → Modules → Installer depuis un fichier
   · Sélectionner susfs4ksu-module.zip
   · Redémarrer
5. Vérifier l'installation :
   ```bash
   su -c 'ksu_susfs show enabled_features'
   ```
   Tu devrais voir la liste des fonctionnalités SUSFS activées.

⚠️ Avertissements

· Ce noyau est destiné aux utilisateurs avancés.
· Le root peut entraîner un bootloop ou une instabilité si mal configuré.
· Sauvegardez toujours votre boot.img d'origine avant de flasher.
· L'auteur n'est pas responsable des dommages causés à votre appareil.
· Cet appareil étant en fin de cycle de support, certaines fonctionnalités peuvent varier selon la version de LineageOS.

🙏 Crédits

· backslashxx — KernelSU v3.3.0-52
· cyberc3dr — nGKI SUSFS patches pour kernel 4.19
· sidex15 — Module userspace susfs4ksu
· simonpunk — SUSFS original
· LineageOS — Source du noyau

📄 Licence

Ce projet est fourni à titre éducatif. Utilisez-le à vos propres risques.
