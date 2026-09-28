// Lien ouvrable d'une URL de suggestion (P4b-3, lot L6, S-16, conception
// §6.11) : seulement http / https avec un hôte ; tout autre schéma ou une
// URL non analysable reste un texte non cliquable.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/web_link.dart';

void main() {
  test('http et https avec hôte → ouvrables (URI rendue telle quelle)', () {
    expect(
      webLinkUri('https://www.youtube.com/watch?v=abc')?.host,
      'www.youtube.com',
    );
    expect(webLinkUri('http://exemple.test/page')?.path, '/page');
    expect(webLinkUri('HTTPS://Exemple.test/x'), isNotNull, reason: 'casse');
  });

  test('schémas non web → non ouvrables', () {
    for (final String raw in <String>[
      'javascript:alert(1)',
      'JavaScript:void(0)',
      'data:text/html;base64,AAAA',
      'file:///etc/hosts',
      'intent://scan#Intent;end',
      'mailto:contact@exemple.test',
      'ftp://exemple.test/f',
      'vbscript:x',
    ]) {
      expect(webLinkUri(raw), isNull, reason: raw);
    }
  });

  test('sans schéma, sans hôte ou non analysable → non ouvrable', () {
    for (final String raw in <String>[
      '',
      'exemple.test/page',
      '//exemple.test/page',
      'http:///chemin',
      'https:',
      'http://[::1',
    ]) {
      expect(webLinkUri(raw), isNull, reason: raw);
    }
  });

  test('infobulle du texte non cliquable', () {
    expect(kNonWebLinkTooltip, 'Lien non ouvrable (schéma non web).');
  });
}
