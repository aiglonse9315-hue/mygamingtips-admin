// Pur (VM) — lien ouvrable d'une URL de suggestion (P4b-3, lot L6, S-16,
// conception §6.11) : l'URL d'un partage `user` n'est soumise à aucune
// contrainte de format côté serveur (M94:2632-2634) ; le panneau ne l'ouvre
// que si elle est analysable ET de schéma `http` / `https` avec un hôte.
// Tout autre schéma (`javascript:`, `data:`, `file:`, `intent:`…) reste un
// texte non cliquable.
//
// Aucune dépendance dart:html ni Flutter UI.

/// Infobulle d'une URL non ouvrable.
const String kNonWebLinkTooltip = 'Lien non ouvrable (schéma non web).';

/// [raw] analysé par `Uri.tryParse` (texte tel quel, jamais corrigé) ; rend
/// l'URI seulement si son schéma est `http` ou `https` et qu'elle porte un
/// hôte non vide, sinon `null` (lien non ouvrable).
Uri? webLinkUri(String raw) {
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null) return null;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}
