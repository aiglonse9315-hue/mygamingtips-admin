// Tests purs (VM) du chantier F3 — attribution d'acquisition : parsing de la
// vue `analytics/acquisition` (EF v78), total avec exclusion (toggle « hors
// redirections site ») et générateur de liens UTM (instructions site §1/§4).
// Aucune dépendance Flutter ni dart:html.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/analytics_calc.dart';

void main() {
  group('AcquisitionStats.fromJson (EF v78)', () {
    test('vue complète : first period/global + clicks', () {
      final s = AcquisitionStats.fromJson({
        'first_period': {'tiktok': 3, 'play_store': 2, 'inconnu': 5},
        'first_global': {'tiktok': 4, 'play_store_via_site': 1},
        'clicks': [
          {'source': 'tiktok', 'campaign': 'lancement', 'n': 12},
          {'source': 'site_web', 'campaign': null, 'n': 3},
        ],
        'clicks_total': 15,
        'clicks_truncated': false,
      });
      expect(s.firstPeriod['tiktok'], 3);
      expect(s.firstPeriod['inconnu'], 5);
      expect(s.firstGlobal['play_store_via_site'], 1);
      expect(s.clicks.length, 2);
      expect(s.clicks.first.source, 'tiktok');
      expect(s.clicks.first.campaign, 'lancement');
      expect(s.clicks.first.n, 12);
      expect(s.clicks.last.campaign, isNull);
      expect(s.clicksTotal, 15);
      expect(s.clicksTruncated, isFalse);
    });

    test('vue vide / champs absents → défauts sûrs', () {
      const s = AcquisitionStats();
      expect(s.firstGlobal, isEmpty);
      expect(s.clicks, isEmpty);
      expect(s.clicksTotal, 0);
      final parsed = AcquisitionStats.fromJson(const {});
      expect(parsed.firstPeriod, isEmpty);
      expect(parsed.clicks, isEmpty);
    });
  });

  group('acquisitionTotal (toggle hors redirections site)', () {
    final bySource = {'tiktok': 3, 'play_store': 2, 'play_store_via_site': 4};

    test('sans exclusion : somme complète', () {
      expect(acquisitionTotal(bySource), 9);
    });

    test('exclusion play_store_via_site', () {
      expect(acquisitionTotal(bySource, exclude: 'play_store_via_site'), 5);
    });

    test('map vide → 0', () {
      expect(acquisitionTotal(const {}), 0);
    });
  });

  group('Générateur de liens UTM (instructions site §1/§4)', () {
    test('isValidUtmCampaign : borne EF acquisition-track', () {
      expect(isValidUtmCampaign('lancement'), isTrue);
      expect(isValidUtmCampaign('a.b_c~d-e9'), isTrue);
      expect(isValidUtmCampaign(''), isFalse);
      expect(isValidUtmCampaign('avec espace'), isFalse);
      expect(isValidUtmCampaign('accentué'), isFalse);
      expect(isValidUtmCampaign('x' * 121), isFalse);
      expect(isValidUtmCampaign('x' * 120), isTrue);
    });

    test('lien site : format §4 avec medium par défaut du canal', () {
      expect(
        buildSiteUtmLink(
          siteBaseUrl: 'https://www.exemple.fr',
          channel: 'tiktok',
          campaign: 'lancement',
        ),
        'https://www.exemple.fr/?utm_source=tiktok&utm_medium=bio'
        '&utm_campaign=lancement',
      );
      expect(
        buildSiteUtmLink(
          siteBaseUrl: 'https://www.exemple.fr',
          channel: 'youtube',
          campaign: 'c1',
        ),
        contains('utm_medium=description'),
      );
    });

    test('lien Play direct : referrer URL-encodé (§1), package applicatif', () {
      final link = buildPlayStoreReferrerLink(
        channel: 'tiktok',
        campaign: 'lancement',
      );
      expect(
        link,
        'https://play.google.com/store/apps/details?id=com.mygamingtips'
        '&referrer=utm_source%3Dtiktok%26utm_medium%3Dbio'
        '%26utm_campaign%3Dlancement',
      );
      // Décodé une fois, le referrer est une query UTM lisible par l'app.
      final referrer = Uri.decodeComponent(Uri.parse(link).queryParameters['referrer']!);
      expect(referrer, 'utm_source=tiktok&utm_medium=bio&utm_campaign=lancement');
    });
  });
}
