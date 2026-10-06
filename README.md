# KernelSU + SUSFS pour Motorola One 5G Ace (kiev/lito)

## 📋 Présentation
Ce projet compile un noyau LineageOS 23.2 (Android 16 QPR2) avec KernelSU (backslashxx v3.3.0-52) et le module SUSFS (nGKI 4.19) pour l'appareil Motorola One 5G Ace.

## 🛠️ Fonctionnalités intégrées
- **KernelSU** : Root kernel-based avec hooks manuels (sys_reboot).
- **SUSFS** : Masquage avancé des modifications système.
  - ✅ `SUS_PATH` : Cache les chemins suspects.
  - ✅ `SUS_MOUNT` : Cache les points de montage.
  - ✅ `SUS_KSTAT` : Falsifie les statistiques de fichiers.
  - ✅ `TRY_UMOUNT` : Démonte les systèmes de fichiers pour les processus non-root.
  - ✅ `SPOOF_UNAME` : Falsifie la version et la date du noyau.
  - ⏳ `SUS_MAP` : (En cours de test) Protection des cartographies mémoire.
  - ⏳ `OPEN_REDIRECT` : (En cours de test) Redirection d'ouverture de fichiers.
  - ⏳ `SPOOF_CMDLINE` : (En cours de test) Falsification des paramètres de démarrage.

## 🚀 Installation
1. Flasher `boot.img` via fastboot.
2. Installer l'application KernelSU.
3. Installer le module userspace `susfs4ksu-module.zip` via l'application.
4. Redémarrer.

## ⚠️ Avertissements
- Ce noyau est destiné aux utilisateurs avancés.
- Le root peut entraîner un bootloop ou une instabilité si mal configuré.
- Sauvegardez toujours votre `boot.img` d'origine.

## 🙏 Crédits
- backslashxx (KernelSU)
- cyberc3dr (nGKI SUSFS patches)
- sidex15 (susfs4ksu-module)
- LineageOS (source du noyau)
