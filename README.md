# CinéScout iOS

Application SwiftUI iOS 17+ de découverte de films et séries reliée à Jellyfin.

## Fonctions
- Connexion Jellyfin par identifiant/mot de passe, serveur prérempli.
- Bibliothèque films et séries, recherche, affiches, détails.
- Découverte TMDb (clé API personnelle facultative), filtres par type, genre, années, note.
- Détection des titres déjà présents par identifiant TMDb.
- Liste de souhaits locale.

## Compiler
GitHub Actions > Build iOS IPA > Run workflow. Le résultat est une **IPA non signée**, non installable telle quelle sur iPhone. Il faut la signer avec un certificat/profil Apple valide ou utiliser un outil de signature compatible.

Le mot de passe Jellyfin n'est jamais stocké. Le jeton Jellyfin et la clé TMDb sont conservés dans le trousseau iOS. Les requêtes vont directement vers les serveurs configurés.

Pour TMDb, créez une clé API sur https://www.themoviedb.org/settings/api puis renseignez-la dans Réglages. CinéScout n'est pas affilié à TMDb.
