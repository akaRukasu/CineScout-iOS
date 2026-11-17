# CinéScout iOS

Application native SwiftUI pour iOS 17 et versions ultérieures, avec Liquid Glass sur iOS 26.

## Première utilisation

1. Dans **Réglages → Jellyfin**, connectez-vous à votre serveur. Le serveur est prérempli. Dans **Jellyfin**, **Actualiser** relance la synchronisation.
2. Dans les [réglages API de TMDb](https://www.themoviedb.org/settings/api), récupérez votre jeton de lecture ou votre clé API v3. Saisissez cette valeur dans **Réglages → TMDb**, puis enregistrez.
3. Dans **Découvrir**, choisissez films ou séries, appliquez vos filtres, puis explorez le catalogue. L’option **Selon mes goûts** utilise les genres de la bibliothèque, en donnant plus de poids aux titres vus, favoris ou ajoutés aux envies. Un genre choisi manuellement a priorité.
4. Les films et séries présents dans Jellyfin sont exclus de Découvrir et des suggestions similaires. Le rapprochement utilise le type de média et l’identifiant TMDb, ou le titre et l’année si Jellyfin n’a pas cet identifiant. Les envies restent sur l’appareil.

Le logo Jellyfin identifie l’intégration. Il est fourni par le [projet Jellyfin](https://github.com/jellyfin/jellyfin-ux/blob/master/branding/SVG/icon-transparent.svg) sous [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

Le mot de passe Jellyfin sert à ouvrir la session. Le jeton Jellyfin et la clé TMDb sont conservés dans le trousseau iOS. CinéScout utilise TMDb et n’est ni approuvé ni certifié par TMDb.

## Recherche et sélections

Dans **Rechercher**, saisis le titre français ou original et choisis **Tout**, **Films**, **Séries** ou **Animes**. La recherche inclut aussi les titres présents dans Jellyfin.

Dans **Découvrir**, **Au cinéma** présente les sorties françaises des 35 derniers jours et **En streaming** permet de filtrer par plateforme. Les fiches détaillent les offres en France par type. Les disponibilités proviennent de JustWatch via TMDb. **À redécouvrir** présente des titres plus anciens, des notes de CinéScout et des liens vers les critiques publiées.

## Roulette

Dans **Découvrir → Roulette**, choisis **1**, **3**, **5** ou **10** suggestions, puis sélectionne un ou plusieurs formats et genres. Les notes et nombres de votes proviennent de TMDb. Le tirage privilégie les titres bien notés et répartit les choix entre les époques quand le catalogue le permet. L’historique local écarte les titres déjà tirés.

Avant chaque tirage, CinéScout synchronise toutes les vues accessibles au compte Jellyfin, y compris les vues masquées, puis vérifie le catalogue global du même compte. Les identifiants TMDb, le titre et l’année ainsi que les identifiants IMDb et TVDb disponibles servent au rapprochement. Les dossiers auxquels le compte n’a pas accès restent hors de portée. Aucun tirage ne démarre si l’inventaire échoue.

## Disponibilité via Prowlarr

Dans **Réglages → Prowlarr**, entrez l’adresse HTTPS de l’instance et la clé API de **Prowlarr → Paramètres → Général**, puis touchez **Vérifier et enregistrer**. CinéScout consulte les indexeurs torrent pour les films affichés et indique les résultats correspondants ainsi que les seeders signalés. La clé reste dans le trousseau iOS. Les demandes continuent de passer par Seerr.

## Demandes Seerr

Dans **Réglages → Seerr**, indiquez l’adresse HTTPS de votre instance et la clé API affichée dans **Seerr → Paramètres → Général**. Utilisez **Vérifier et enregistrer** pour tester l’accès. La clé donne des droits administrateur et reste dans le trousseau iOS.

Ouvrez un titre pour consulter ses détails TMDb, sa distribution et les suggestions similaires. Demandez un film ou choisissez les saisons d’une série, puis confirmez. Les demandes utilisent le profil standard de Seerr et son statut d’approbation. Seerr doit déjà être configuré avec Radarr pour les films ou Sonarr pour les séries.

## Compilation et installation

Dans GitHub Actions, ouvrez **Build iOS IPA** et choisissez **Run workflow**. Les mises à jour de `main` déclenchent également un build. Dans un run réussi, téléchargez **CineScout-unsigned-IPA** et extrayez `CineScout-unsigned.ipa`.

L’IPA pour iPhone est non signée. Sous Windows, [installez AltStore Classic avec AltServer](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). Activez le **Mode développeur** sur l’iPhone, puis ouvrez **My Apps → +** dans AltStore Classic et sélectionnez l’IPA dans Fichiers. Gardez AltServer actif pendant l’installation. Avec un compte Apple gratuit, rafraîchissez la signature avant son expiration.

Pour ouvrir le projet dans Xcode 26 ou plus récent, installez XcodeGen et exécutez `xcodegen generate`. Sélectionnez votre équipe de signature et votre iPhone dans Xcode.
