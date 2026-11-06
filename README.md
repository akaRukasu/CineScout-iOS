# CinéScout iOS

Application native SwiftUI pour iOS 17 et versions ultérieures.

## Première utilisation

1. Dans **Réglages**, connectez-vous à Jellyfin. Le serveur est prérempli. Dans **Jellyfin**, **Actualiser** relance la synchronisation.
2. Dans les [réglages API de TMDb](https://www.themoviedb.org/settings/api), récupérez votre jeton de lecture ou votre clé API v3. Saisissez cette valeur dans **Réglages**, puis enregistrez.
3. Dans **Découvrir**, choisissez films ou séries, appliquez vos filtres, puis explorez le catalogue. L’option **Selon mes goûts** utilise les genres de la bibliothèque, en donnant plus de poids aux titres vus, favoris ou ajoutés aux envies. Un genre choisi manuellement a priorité.
4. Les titres sont comparés par type de média et identifiant TMDb. Un titre sans identifiant TMDb dans Jellyfin ne peut pas être rapproché automatiquement. Les envies restent sur l’appareil.

Le mot de passe Jellyfin sert à ouvrir la session. Le jeton Jellyfin et la clé TMDb sont conservés dans le trousseau iOS. CinéScout utilise TMDb et n’est ni approuvé ni certifié par TMDb.

## Compilation et installation

Dans GitHub Actions, ouvrez **Build iOS IPA** et choisissez **Run workflow**. Les mises à jour de `main` déclenchent également un build. Dans un run réussi, téléchargez **CineScout-unsigned-IPA** et extrayez `CineScout-unsigned.ipa`.

L’IPA pour iPhone est non signée. Sous Windows, [installez AltStore Classic avec AltServer](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). Activez le **Mode développeur** sur l’iPhone, puis ouvrez **My Apps → +** dans AltStore Classic et sélectionnez l’IPA dans Fichiers. Gardez AltServer actif pendant l’installation. Avec un compte Apple gratuit, rafraîchissez la signature avant son expiration.

Pour ouvrir le projet dans Xcode, installez XcodeGen et exécutez `xcodegen generate`. Sélectionnez votre équipe de signature et votre iPhone dans Xcode.
