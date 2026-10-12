/// P5 (lot L6) — détection d'une vidéo YouTube par l'HÔTE de son URL.
///
/// COPIE de `packages/mgt_core/lib/platform_host.dart` (`kYouTubeVideoHosts`,
/// `parseUrlForPlatform`, `normalizePlatformHost`, `youTubeVideoIdOf`) : le
/// panneau ne dépend pas de `mgt_core` (dépôt miroir publié par
/// `sync-admin`). Toute modification du cœur se reporte ici ;
/// `test/sentinelle_sections_test.dart` fige la même table d'URL. Jamais une
/// recherche de sous-chaîne (une page web qui CITE youtube.com n'est pas une
/// vidéo YouTube). Fonctions PURES : ne lèvent jamais.
library;

/// Hôtes YouTube (liste fermée) : site, mobile, Music, lien court et
/// lecteur intégré « sans cookie ».
const Set<String> kYouTubeVideoHosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtu.be',
  'youtube-nocookie.com',
  'www.youtube-nocookie.com',
};

/// Id YouTube : 11 caractères de l'alphabet base64 « URL ».
final RegExp _ytIdPrefix = RegExp(r'^[A-Za-z0-9_-]{11}');

/// Paramètre `v=` de la REQUÊTE.
final RegExp _ytQueryV = RegExp(r'(?:^|&)v=([A-Za-z0-9_-]{11})');

/// URL parsée : espaces de bord retirés, `https://` ajouté sans schéma ;
/// null si illisible ou hors http(s).
Uri? _parseUrlForPlatform(String url) {
  final s = url.trim();
  if (s.isEmpty) return null;
  try {
    var uri = Uri.parse(s);
    if (!uri.hasScheme) uri = Uri.parse('https://$s');
    if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
    return uri;
  } catch (_) {
    return null;
  }
}

/// Hôte comparable (minuscules, points finaux retirés) ; null si vide.
String? _normalizeHost(String host) {
  var h = host.trim().toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h.isEmpty ? null : h;
}

/// Segments non vides du chemin (ne lève jamais).
List<String> _segments(Uri uri) {
  try {
    return uri.pathSegments.where((s) => s.isNotEmpty).toList();
  } catch (_) {
    return const <String>[];
  }
}

/// Id vidéo YouTube (11 caractères) lu SEULEMENT sur un hôte YouTube ;
/// null sinon (chaîne, liste de lecture, autre site). Même ordre que le
/// cœur : paramètre `v=`, puis `youtu.be/<id>`, puis `/embed/<id>`, puis
/// `/shorts/<id>`.
String? youTubeVideoIdOf(String url) {
  final uri = _parseUrlForPlatform(url);
  if (uri == null) return null;
  final host = _normalizeHost(uri.host);
  if (host == null || !kYouTubeVideoHosts.contains(host)) return null;
  final q = _ytQueryV.firstMatch(uri.query);
  if (q != null) return q.group(1);
  final segs = _segments(uri);
  if (host == 'youtu.be') {
    return segs.isEmpty ? null : _ytIdPrefix.firstMatch(segs.first)?.group(0);
  }
  for (final marker in const ['embed', 'shorts']) {
    final i = segs.indexOf(marker);
    if (i >= 0 && i + 1 < segs.length) {
      final m = _ytIdPrefix.firstMatch(segs[i + 1]);
      if (m != null) return m.group(0);
    }
  }
  return null;
}

/// Vrai pour une VIDÉO YouTube (hôte de la liste fermée ET id lisible).
bool isYouTubeVideoUrl(String url) => youTubeVideoIdOf(url) != null;
