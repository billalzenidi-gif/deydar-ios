# Deydar — app iOS (Xcode)

App iPhone de Deydar. Elle affiche le site Deydar hébergé sur le VPS **brazil**
(**https://deydar.com**) avec des fonctions natives :

- **Toutes les fonctions et API du site** : comptes, recherche, réservations, messages, espace hôte, 8 langues, etc.
  Chaque mise à jour publiée sur le VPS (`bash deploy/vps.sh`) arrive **immédiatement** dans l'app, sans republier sur l'App Store.
- **Connexion Google native** : la feuille sécurisée d'iOS, avec le client OAuth « Deydar iOS » du projet Google Cloud `deydar`.
- **GPS natif** (CoreLocation) pour « Près de moi » : une seule demande d'autorisation, celle d'iOS.
- **Photos** : caméra ou photothèque pour les annonces, les véhicules et les documents.
- **Confort d'app** :
  - écran de démarrage, icône brune « D », « tirer pour actualiser » et retour par balayage ;
  - écran « Pas de connexion » avec un bouton Réessayer ;
  - les liens externes (WhatsApp, téléphone, e-mail, autres sites) s'ouvrent dans l'app concernée ou dans Safari ;
  - les liens `deydar://chemin` ouvrent directement une page de l'app.
- Au premier lancement, l'app prend **la langue du téléphone** (anglais, français, arabe, espagnol, portugais, allemand, italien ou néerlandais).

## Lancer l'app sur ton iPhone (Mac + Xcode 15 ou plus récent)

1. Ouvre `Deydar.xcodeproj` dans Xcode.
2. Clique sur le projet **Deydar** (à gauche), puis sur la cible **Deydar**, puis sur l'onglet **Signing & Capabilities**.
   Dans **Team**, choisis ton compte Apple. Un identifiant Apple gratuit suffit pour l'installer sur ton propre iPhone.
3. Branche ton iPhone et choisis-le en haut de la fenêtre, puis clique sur ▶︎ (Run).
   La première fois, sur l'iPhone, va dans **Réglages > Général > VPN et gestion de l'appareil** et fais confiance au développeur.

Le simulateur marche aussi : choisis par exemple « iPhone 16 », puis ▶︎.

> Si Xcode dit que l'identifiant `com.deydar.app` est déjà pris, remplace-le par le tien dans **Signing & Capabilities**
> (par exemple `com.tonnom.deydar`), puis préviens-moi : il faudra mettre à jour le client Google iOS avec ce nouvel identifiant.

## Publier sur l'App Store

1. Il te faut un compte Apple Developer payant (99 $/an).
2. Dans Xcode, menu **Product > Archive**, puis **Distribute App > App Store Connect**.
3. Dans App Store Connect :
   - **Politique de confidentialité** : `https://deydar.com/privacy` ;
   - **Conditions d'utilisation** : `/terms`.

### Sans Mac : envoi automatique vers TestFlight (GitHub Actions)

Le workflow `.github/workflows/testflight.yml` archive l'app sur un Mac de GitHub, la fait signer par Apple
(signature automatique, certificat de distribution géré par Apple), l'envoie à App Store Connect, puis l'ajoute
au groupe externe « Amis testeurs » (celui du lien public) et la soumet à la Beta Review.

1. Une seule fois, dans App Store Connect > **Utilisateurs et accès > Intégrations > API App Store Connect** :
   demande l'accès, puis crée une **clé d'équipe** avec le rôle **Admin** et télécharge le fichier `AuthKey_XXXXXXXXXX.p8`
   (téléchargeable une seule fois).
2. Sur GitHub, **Settings > Secrets and variables > Actions > New repository secret** :
   `ASC_KEY_ID` (ID de la clé), `ASC_ISSUER_ID` (ID de l'émetteur, en haut de la page des clés),
   `ASC_KEY_P8` (tout le contenu du fichier `.p8`).
3. **Actions > TestFlight > Run workflow**, avec le numéro de build (plus grand que le dernier envoyé).

Sans les secrets, le workflow fait une répétition (archive non signée) pour vérifier la compilation.
Le contrat Apple Developer à jour doit être accepté par le titulaire du compte, sinon Apple refuse l'envoi.

Points de la relecture Apple à connaître :
- **Règle 4.8** : une app qui propose « Continuer avec Google » doit aussi proposer « Se connecter avec Apple ».
  Le bouton Apple de Deydar indique pour l'instant « bientôt disponible ». À brancher avant la soumission.
- **Règle 4.2** : Apple refuse les apps qui ne sont qu'un site web. Deydar a de vraies fonctions natives
  (GPS, appareil photo, connexion native, mode hors ligne), ce qui aide. Garde-les en avant dans la description.

## Réglages

Tout est dans `Deydar/AppConfig.swift` :
- `baseURL` : l'adresse du site. Si tu passes sur un vrai nom de domaine, change-la ici et ajoute-la aussi dans `appHosts`.
- `googleClientID` : le client OAuth iOS. Il n'est pas secret.

## Fichiers

| Fichier | Rôle |
|---|---|
| `DeydarApp.swift` | point d'entrée (SwiftUI) |
| `WebViewController.swift` | vue web, navigation, alertes, hors ligne, pont natif |
| `NativeBridge.swift` | script injecté : `window.DeydarNative`, GPS, langue |
| `GoogleSignIn.swift` | connexion Google (ASWebAuthenticationSession + PKCE) |
| `LocationBridge.swift` | GPS (CoreLocation) |
| `Assets.xcassets` | icône, logo et couleurs du démarrage |
| `.github/workflows/ios.yml` | compilation automatique sur un Mac GitHub + captures du simulateur |
| `.github/workflows/testflight.yml` | archive signée + envoi TestFlight + groupe « Amis testeurs » et Beta Review |
