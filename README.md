# Deydar — app iOS (Xcode)

App iPhone de Deydar. Elle affiche le site Deydar hébergé sur le VPS **brazil**
(**https://deydar.com**) avec des fonctions natives :

- **Toutes les fonctions et API du site** : comptes, recherche, réservations, messages, espace hôte, 8 langues, etc.
  Chaque mise à jour publiée sur le VPS (`bash deploy/vps.sh`) arrive **immédiatement** dans l'app, sans republier sur l'App Store.
- **Se connecter avec Apple natif** (version 2.0) : la feuille système d'Apple (Face ID / Touch ID), au-dessus du bouton Google.
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
  C'est fait depuis la version 2.0 (voir « Se connecter avec Apple » plus bas). L'app 1.0 déjà installée ne montre
  aucun bouton social (ni Apple ni Google) : le site ne les affiche que si `DeydarNative.appleSignIn` existe.
- **Règle 5.1.1(v)** : la suppression du compte se fait dans l'app (Profil > Supprimer le compte) ; pour un compte
  Apple, le serveur révoque aussi les jetons Apple.
- **Règle 4.2** : Apple refuse les apps qui ne sont qu'un site web. Deydar a de vraies fonctions natives
  (GPS, appareil photo, connexion native, mode hors ligne), ce qui aide. Garde-les en avant dans la description.

## Se connecter avec Apple (version 2.0)

Dans l'app, le bouton « Continuer avec Apple » ouvre la feuille native d'Apple (`AppleSignIn.swift`). L'app crée un
nonce aléatoire, Apple renvoie un jeton d'identité signé qui en contient l'empreinte SHA-256, et le site l'envoie au
serveur (`POST /api/auth/apple`), qui vérifie la signature d'Apple, l'audience et le nonce avant d'ouvrir la session.
Au lancement et au retour au premier plan, l'app vérifie que l'identifiant Apple n'a pas été retiré
(Réglages > Mot de passe et sécurité) ; s'il l'a été, le site déconnecte le compte (`window.__ddAppleRevoked`).

Une seule fois, dans le portail **Apple Developer > Certificates, Identifiers & Profiles** :

1. **Identifiers > App IDs > `com.deydar.app`** : coche **Sign in with Apple** (« Enable as a primary App ID ») et
   **Push Notifications**, puis **Save**. Le fichier `Deydar.entitlements` contient déjà les deux droits
   (`com.apple.developer.applesignin` = Default, `aps-environment`).
2. **Identifiers > Services IDs** : crée `com.deydar.web` (connexion Apple sur le **site**), coche Sign in with Apple,
   **Configure** : App ID principal `com.deydar.app`, domaine `deydar.com`, adresse de retour
   `https://deydar.com/api/auth/apple/callback`.
3. **Keys** : crée une clé avec **Sign in with Apple** (App ID principal `com.deydar.app`) et **Apple Push Notifications
   service (APNs)**, télécharge le fichier `AuthKey_XXXXXXXXXX.p8` (une seule fois). Elle sert au serveur pour révoquer les
   jetons Apple à la suppression d'un compte et pour envoyer les notifications push.
4. Sur le VPS, pose les réglages avec `deydar-apple-setup` (Team ID `CKWU62DNSQ`, Key ID, fichier `.p8`,
   `APPLE_BUNDLE_ID=com.deydar.app`, `APPLE_SERVICES_ID=com.deydar.web`). Sans `APPLE_SERVICES_ID`, le bouton Apple
   reste caché sur le site ; il marche quand même dans l'app.

Pour la relecture Apple : le compte de démonstration (e-mail + mot de passe) reste nécessaire dans App Store Connect,
les relecteurs peuvent aussi essayer « Continuer avec Apple » avec leur propre identifiant.

## Réglages

Tout est dans `Deydar/AppConfig.swift` :
- `baseURL` : l'adresse du site (`https://deydar.com`). Si elle change, change-la ici et ajoute le domaine dans `appHosts`
  (aujourd'hui `deydar.com` et `www.deydar.com` seulement).
- `googleClientID` : le client OAuth iOS. Il n'est pas secret.

## Fichiers

| Fichier | Rôle |
|---|---|
| `DeydarApp.swift` | point d'entrée (SwiftUI) |
| `WebViewController.swift` | vue web, navigation, alertes, hors ligne, pont natif |
| `NativeBridge.swift` | script injecté : `window.DeydarNative` (Apple, Google, push), GPS, partage, langue |
| `AppleSignIn.swift` | Se connecter avec Apple (AuthenticationServices, nonce SHA-256, contrôle de révocation) |
| `GoogleSignIn.swift` | connexion Google (ASWebAuthenticationSession + PKCE) |
| `CheckoutSession.swift` | paiement Stripe dans la feuille sécurisée d'Apple |
| `PushBridge.swift` | notifications push (APNs) |
| `LocationBridge.swift` | GPS (CoreLocation) |
| `Assets.xcassets` | icône, logo et couleurs du démarrage |
| `.github/workflows/ios.yml` | compilation automatique sur un Mac GitHub + captures du simulateur |
| `.github/workflows/testflight.yml` | archive signée + envoi TestFlight + groupe « Amis testeurs » et Beta Review |
