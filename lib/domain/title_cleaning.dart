// §123 (25/09/2026) — nettoyage des titres pour insertion, extrait de
// StoreController en Dart PUR.
//
// ⚠️ Ce fichier est volontairement SANS dépendance Flutter ni dart:html
// (même principe que analytics_calc.dart) : il est testable en VM
// (`flutter test test/title_clean_test.dart`). StoreController délègue ici.
//
// COPIE AUTONOME de SentinelleRunner.cleanTitleForInsertion (tools/vision)
// et de GameMatcher (normalize + alias) : l'admin ne peut pas importer
// tools/vision. ⚠️ Toute évolution de GameMatcher._aliases doit être
// reportée ici (et dans tools/sentinelle/lib/game_matcher.dart).
//
// ⚠️ Les titres DÉJÀ en base avec le nom du jeu ne sont PAS rétro-modifiés :
// l'admin les édite à la main via le champ « Titre pour insertion ».

/// Nettoyage des titres pour insertion et titre des pages web (fonctions
/// PURES, statiques).
abstract final class TitleCleaning {
  /// Variantes accentuées par lettre ASCII, pour la comparaison insensible
  /// aux accents de [cleanTitleForInsertion].
  static const Map<String, String> _accentVariants = {
    'a': 'àâäãåā',
    'e': 'éèêëē',
    'i': 'îïíìī',
    'o': 'ôöõòóōø',
    'u': 'ùûüúū',
    'y': 'ýÿ',
    'c': 'ç',
    'n': 'ñ',
  };

  /// Alias connus → nom canonique normalisé. Copie de GameMatcher._aliases
  /// (tools/vision/lib/game_matcher.dart) — clés et valeurs déjà normalisées.
  static const Map<String, String> gameAliases = {
    'd4': 'diablo 4',
    'diablo iv': 'diablo 4',
    'diablo 4': 'diablo 4',
    'poe': 'path of exile',
    'poe 2': 'path of exile 2',
    'poe2': 'path of exile 2',
    'path of exile 2': 'path of exile 2',
    'lol': 'league of legends',
    'league of legends': 'league of legends',
    'tft': 'league of legends teamfight tactics',
    'teamfight tactics': 'league of legends teamfight tactics',
    'tft set': 'league of legends teamfight tactics',
    'lol tft': 'league of legends teamfight tactics',
    'league of legends tft': 'league of legends teamfight tactics',
    'league of legends teamfight tactics': 'league of legends teamfight tactics',
    'bo7': 'call of duty black ops 7',
    'black ops 7': 'call of duty black ops 7',
    'cod bo7': 'call of duty black ops 7',
    'call of duty black ops 7': 'call of duty black ops 7',
    'oni': 'oxygen not included',
    'oxygen not included': 'oxygen not included',
    'oxygene not included': 'oxygen not included',
    'oxygène not included': 'oxygen not included',
    'sc': 'star citizen',
    'wf': 'warframe',
    'la': 'lost ark',
    'drg': 'deep rock galactic',
    'total war warhammer 3': 'total war warhammer 3',
    'warhammer 3': 'total war warhammer 3',
    'mortal shell 2': 'mortal shell 2',
    'mortal shell ii': 'mortal shell 2',
    'dc universe online': 'dc universe online',
    'dcuo': 'dc universe online',
    'the blood of dawnwalker': 'the blood of dawnwalker',
    'the blood of dawnwalker eclipse edition': 'the blood of dawnwalker',
    'the legend of zelda breath of the wild':
        'the legend of zelda breath of the wild',
    'botw': 'the legend of zelda breath of the wild',
    'breath of the wild': 'the legend of zelda breath of the wild',
    'the legend of zelda tears of the kingdom':
        'the legend of zelda tears of the kingdom',
    'totk': 'the legend of zelda tears of the kingdom',
    'tears of the kingdom': 'the legend of zelda tears of the kingdom',
    'metal gear solid 5 the phantom pain':
        'metal gear solid 5 the phantom pain',
    'mgsv': 'metal gear solid 5 the phantom pain',
    'resident evil requiem': 'resident evil requiem',
    'resident evil 9 requiem': 'resident evil requiem',
    'reanimal': 'reanimal',
    's t a l k e r 2': 's t a l k e r 2',
    'stalker 2': 's t a l k e r 2',
    'stalker 2 heart of chornobyl': 's t a l k e r 2',
    'call of duty b o 7': 'call of duty black ops 7',
    'senuas saga hellblade 2': 'senuas saga hellblade 2',
    'hellblade 2': 'senuas saga hellblade 2',
    'hellblade 2 senuas saga': 'senuas saga hellblade 2',
    'death stranding 2 on the beach': 'death stranding 2 on the beach',
    'death stranding 2': 'death stranding 2 on the beach',
    'assassins creed black flag resynced':
        'assassins creed black flag resynced',
    'ac black flag resynced': 'assassins creed black flag resynced',
    // Hogwarts Legacy : L'Héritage de Poudlard — titre FR officiel du même
    // jeu (12/09/2026, §60 — rattrapage de synchro avec les copies bots).
    'hogwarts legacy': 'hogwarts legacy',
    'hogwarts legacy lheritage de poudlard': 'hogwarts legacy',
    'lheritage de poudlard': 'hogwarts legacy',
  };

  /// Conversion des chiffres romains courants en chiffres arabes (copie de
  /// GameMatcher._romanToArabic). « I » seul est volontairement exclu.
  static const Map<String, String> _romanToArabic = {
    'ii': '2',
    'iii': '3',
    'iv': '4',
    'v': '5',
    'vi': '6',
    'vii': '7',
    'viii': '8',
    'ix': '9',
    'x': '10',
    'xi': '11',
    'xii': '12',
  };

  /// Chiffre romain en limite de mot (copie de GameMatcher._romanPattern).
  static final RegExp _romanPattern = RegExp(
    r'(^|[^a-z0-9])(viii|vii|xii|iii|xi|ix|vi|iv|ii|x|v)(?![a-z0-9])',
  );

  /// Jeux pour lesquels les HASHTAGS sont conservés dans les titres
  /// (12/09/2026 — Roblox : les hashtags différencient ses jeux/modes
  /// internes ; même règle côté bots, voir passation §56).
  static const Set<String> _keepHashtagsGames = {'roblox'};

  /// Normalise un nom de jeu pour la comparaison (copie fidèle de
  /// GameMatcher.normalize : minuscules, accents, romains → arabes,
  /// suffixes d'édition, apostrophes, ponctuation, puis résolution d'alias).
  static String normalizeGameName(String name) {
    final n = normalizeGameNameNoAlias(name);
    // Résolution d'alias : la base (couche distante) d'abord, comme
    // GameMatcher.normalize des bots, puis les alias codés en dur.
    return _remoteAliases[n] ?? gameAliases[n] ?? n;
  }

  /// Couche DISTANTE des alias (§123 — table `game_aliases`, route EF
  /// `games/aliases/list-all`) : forme clé de l'alias → forme clé du nom du
  /// jeu, comme `GameMatcher._remoteAliases` des bots. Sans elle, un alias
  /// ajouté en base (« GTA 5 » pour Grand Theft Auto V) restait dans le
  /// titre recalculé par le panneau alors que Sentinelle le retire.
  static Map<String, String> _remoteAliases = const {};

  /// Remplace la couche distante. Chaque côté est re-normalisé SANS
  /// résolution d'alias (même règle que `GameMatcher._applyRemoteAliases`) ;
  /// les entrées vides ou identiques au nom du jeu sont ignorées.
  static void setRemoteAliases(
      Iterable<({String aliasNorm, String gameName})> entries) {
    final rebuilt = <String, String>{};
    for (final e in entries) {
      final alias = normalizeGameNameNoAlias(e.aliasNorm);
      final game = normalizeGameNameNoAlias(e.gameName);
      if (alias.isEmpty || game.isEmpty || alias == game) continue;
      rebuilt[alias] = game;
    }
    _remoteAliases = Map.unmodifiable(rebuilt);
  }

  /// Alias connus pour le nettoyage des titres : codés en dur ∪ base (la
  /// base gagne les conflits — `GameMatcher.knownAliases`).
  static Map<String, String> get knownAliases =>
      {...gameAliases, ..._remoteAliases};

  /// Normalisation SANS résolution d'alias (équivalent du
  /// `_normalizeCore` de GameMatcher côté bots) : la forme CLÉ d'un nom
  /// ou d'un alias. Base de [normalizeGameName] et de
  /// `StoreController.normalizeGameAlias` (B-001 : l'alias_norm persisté doit être la
  /// forme clé, JAMAIS la forme canonique résolue — sinon la ligne est
  /// inerte pour les bots).
  static String normalizeGameNameNoAlias(String name) {
    var n = _stripAccentsForNorm(name);
    // Chiffres romains → arabes (en limite de mot).
    n = n.replaceAllMapped(
      _romanPattern,
      (m) => '${m.group(1)}${_romanToArabic[m.group(2)]!}',
    );
    // Suffixes d'édition courants. D1.8 : « remaster », « remastered » et
    // « remake » (formes avec espace ou « : ») sont désormais retirés AU
    // MATCHING — « Elden Ring Remaster » rattache à « Elden Ring » — MAIS
    // la mention d'édition n'est jamais une forme retirée du titre pour
    // insertion (normalize l'enlève du canonique : elle reste VISIBLE dans
    // le titre proposé, choix du brief item 6).
    const suffixesToRemove = [
      ': wild hunt',
      ': enhanced edition',
      ' remaster',
      ' remastered',
      ' remake',
      ': remaster',
      ': remastered',
      ': remake',
      ' game of the year edition',
      ' goty edition',
      ' definitive edition',
      ' complete edition',
      ' standard edition',
      ' deluxe edition',
      ' ultimate edition',
    ];
    for (final suffix in suffixesToRemove) {
      if (n.endsWith(suffix)) {
        n = n.substring(0, n.length - suffix.length).trim();
      }
    }
    // Apostrophes → RIEN (pas d'espace) : « Assassin's » → « assassins ».
    n = n.replaceAll("'", '');
    n = n.replaceAll('’', '');
    // Ponctuation → espaces, puis espaces multiples → un seul.
    n = n.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
    return n;
  }

  /// Strip accents + minuscules (étape commune des normalisations).
  static String _stripAccentsForNorm(String name) {
    var n = name.toLowerCase().trim();
    n = n.replaceAll('é', 'e');
    n = n.replaceAll('è', 'e');
    n = n.replaceAll('ê', 'e');
    n = n.replaceAll('ë', 'e');
    n = n.replaceAll('à', 'a');
    n = n.replaceAll('â', 'a');
    n = n.replaceAll('ä', 'a');
    n = n.replaceAll('ã', 'a');
    n = n.replaceAll('å', 'a');
    n = n.replaceAll('î', 'i');
    n = n.replaceAll('ï', 'i');
    n = n.replaceAll('í', 'i');
    n = n.replaceAll('ì', 'i');
    n = n.replaceAll('ô', 'o');
    n = n.replaceAll('ö', 'o');
    n = n.replaceAll('õ', 'o');
    n = n.replaceAll('ò', 'o');
    n = n.replaceAll('ó', 'o');
    n = n.replaceAll('ù', 'u');
    n = n.replaceAll('û', 'u');
    n = n.replaceAll('ü', 'u');
    n = n.replaceAll('ú', 'u');
    n = n.replaceAll('ý', 'y');
    n = n.replaceAll('ÿ', 'y');
    n = n.replaceAll('ā', 'a');
    n = n.replaceAll('ē', 'e');
    n = n.replaceAll('ī', 'i');
    n = n.replaceAll('ō', 'o');
    n = n.replaceAll('ū', 'u');
    n = n.replaceAll('ç', 'c');
    n = n.replaceAll('ñ', 'n');
    n = n.replaceAll('æ', 'ae');
    n = n.replaceAll('œ', 'oe');
    n = n.replaceAll('ø', 'o');
    n = n.replaceAll('ð', 'd');
    n = n.replaceAll('þ', 'th');
    return n;
  }

  /// Construit la regex de détection d'une forme NORMALISÉE de nom de jeu
  /// (cf. [cleanTitleForInsertion]) dans un titre brut :
  /// - mots joints par `[\W_]+` → « Prince of Persia The Lost Crown »
  ///   matche « Prince of Persia: The Lost Crown » ou « ... - The ... » ;
  /// - chaque lettre matche ses variantes accentuées ([_accentVariants]) ;
  /// - une apostrophe optionnelle est admise entre les lettres →
  ///   « Assassin's » matche la forme normalisée « assassins » ;
  /// - limites de mot Unicode des deux côtés → jamais de retrait à
  ///   l'intérieur d'un mot plus long (« la » dans « large »).
  /// Retourne null si la forme est inexploitable (vide).
  static RegExp? _gameMentionPattern(String normalizedForm) {
    final words =
        normalizedForm.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    final buffer = StringBuffer();
    var first = true;
    for (final word in words) {
      if (!first) buffer.write(r'[\W_]+');
      first = false;
      for (final unit in word.codeUnits) {
        final ch = String.fromCharCode(unit);
        final variants = _accentVariants[ch];
        final escaped = RegExp.escape(ch);
        buffer.write(variants != null ? '[$escaped$variants]' : escaped);
        // Apostrophe optionnelle (droite U+0027 ou typographique U+2019).
        buffer.write("['’]?");
      }
    }
    return RegExp(
      '(^|[^\\p{L}\\p{N}])$buffer(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
  }

  /// Nettoie un titre avant insertion (copie autonome de
  /// SentinelleRunner.cleanTitleForInsertion, tools/vision) :
  /// (a) retire les hashtags (règle 11/09/2026) — D1.1 : les hashtags
  ///     NUMÉRIQUES (`#328` — suites/séries) sont conservés ;
  /// (b) retire TOUTES les mentions du jeu [gameName] — nom canonique ET
  ///     chaque alias connu pointant vers lui (règle 12/09/2026 : le contenu
  ///     est déjà associé au jeu dans l'app, répéter le nom est inutile) —
  ///     D1.4 : [translatedNames] (titres `game_translations` du jeu, cache
  ///     best-effort du StoreController) ajoutés aux formes retirées ;
  ///     D1.5 : formes partielles (préfixe avant « : » ≥ 10 car. et ≥ 2
  ///     mots) ; D1.2 : mention encadrée de `()`/`[]` → encadrement retiré ;
  /// (c) nettoie les artefacts du retrait (espaces multiples, paires vides,
  ///     prépositions orphelines BORNÉES aux bordures/après séparateur
  ///     (D1.3, [_orphanPreps]) ET conditionnées à un retrait effectif
  ///     (B-002), mentions de langue (D1.6, [_stripLanguageMentions]),
  ///     séparateurs orphelins en bordure, séparateurs doublés au milieu) ;
  ///     D1.7 : première lettre en majuscule.
  ///     Révision D1 (correctifs de revue prouvés par exécution) : B-001
  ///     (`()`/`[]` retirés des classes de bordure — la purge D1.2 des
  ///     paires vides suffit), B-002 (orphelins seulement si une mention du
  ///     jeu a été retirée — cicatrice de retrait), I-001 (re-collapse des
  ///     espaces après la passe après-séparateur) ;
  /// (d) garde-fou : si le résultat fait moins de 3 caractères ou est vide,
  ///     retourne le titre seulement dé-hashtagué (jamais de titre vide).
  ///
  /// §123 (25/09/2026, même algorithme que Sentinelle) : entités HTML
  /// décodées, 【4K】/nom de la plateforme bilibili retirés, noms traduits non
  /// latins retirés, et REPÈRES de retrait : seuls les fragments collés à une
  /// mention retirée partent (« Do this in Arma Reforger » → « Do this » ;
  /// « … fast in #armareforger » → « … fast » ; « 's » après le nom).
  /// Au plus UNE préposition retirée par mention (« What to do in Elden
  /// Ring » → « What to do ») ; prépositions des packs de langues (es, pt,
  /// it, de, ru), particules 的/の/의, mention encadrée retirée avec son
  /// encadrement. Parité vérifiée par tools/vision/test/
  /// admin_title_parity_test.dart.
  /// §125 : [channelName] (nom de la chaîne) retiré quand il est détaché
  /// de la phrase — voir [stripChannelName].
  static String cleanTitleForInsertion(String title,
      {String? gameName,
      List<String>? translatedNames,
      String? channelName}) {
    // §123 (G) — entités HTML décodées (« &#039; » → « ' ») ; (F) repères
    // techniques 【4K】… et nom de la plateforme (bilibili, 哔哩哔哩) retirés.
    final base = _stripPlatformNoise(decodeHtmlEntities(title));
    // (a) Hashtags — SAUF pour les jeux d'exception (Roblox : les hashtags
    // différencient les jeux/modes internes). D1.1 : les hashtags numériques
    // (#328) sont conservés pour tous les jeux.
    final game = gameName?.trim();
    final keepHashtags = game != null &&
        _keepHashtagsGames.contains(normalizeGameName(game));
    // §125 — nom de la chaîne retiré s'il est détaché ([stripChannelName]).
    final withoutHashtags = stripChannelName(
        keepHashtags
            ? base.replaceAll(RegExp(r'\s+'), ' ').trim()
            : base
                .replaceAll(_hashtagPattern, '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim(),
        channelName,
        gameName: game);

    if (game == null || game.isEmpty) return withoutHashtags;

    // (b) Formes à retirer : le nom canonique normalisé + les alias connus
    //     dont la cible == ce canonique. Les alias de moins de 3 caractères
    //     (« sc », « la », « wf », « d4 ») sont exclus : trop courts, ils
    //     risqueraient de découper un mot courant (même convention que le
    //     SnifeurChaîne).
    final canonical = normalizeGameName(game);
    if (canonical.isEmpty) return withoutHashtags;
    final forms = <String>{canonical};
    // §123 : alias codés en dur ET alias de la base ([knownAliases]).
    for (final entry in knownAliases.entries) {
      if (entry.value == canonical && entry.key.length >= 3) {
        forms.add(entry.key);
      }
    }
    // D1.4 — titres TRADUITS du jeu (table game_translations), fournis par
    // l'appelant (null = non disponibles : comportement antérieur inchangé).
    if (translatedNames != null) {
      for (final t in translatedNames) {
        final norm = normalizeGameName(t);
        if (norm.length >= 3) forms.add(norm);
      }
    }
    // D1.5 — formes PARTIELLES : préfixe avant « : » du nom canonique brut
    // et de chaque traduction brute (« Horizon Forbidden West » pour
    // « Horizon Forbidden West: Burning Shores »).
    _addColonPrefixForm(game, forms);
    if (translatedNames != null) {
      for (final t in translatedNames) {
        _addColonPrefixForm(t, forms);
      }
    }
    // §123 (F) — noms traduits NON LATINS (chinois, japonais, coréen,
    // cyrillique…) : la normalisation latine les efface, ils n'étaient donc
    // jamais retirés (« 艾尔登法环 » restait dans les titres bilibili).
    final rawForms = <String>{
      if (translatedNames != null)
        for (final t in translatedNames)
          if (_hasNonLatinLetter(t)) t.trim(),
    };

    // §123 (B/C) — chaque mention du jeu devient un REPÈRE ([_gameMark]) ;
    // seuls les fragments COLLÉS à un repère sont ensuite retirés
    // (préposition juste avant, « 's » juste après). Avant, les passes
    // orphelines agissaient sur les BORDS du titre dès qu'une mention était
    // retirée n'importe où : « Do this in Arma Reforger » perdait « Do ».
    // Un hashtag qui NOMME le jeu (#armareforger) devient aussi un repère :
    // « … fast in #armareforger » perd son « in » orphelin.
    final compactForms = {
      for (final f in forms)
        if (f.replaceAll(' ', '').length >= 3) f.replaceAll(' ', ''),
    };
    var result = keepHashtags
        ? base
        : base.replaceAllMapped(_hashtagPattern, (m) {
            final tag = m.group(0)!.substring(1);
            // Forme clé OU forme résolue par alias (« #d4 » → diablo 4).
            final isGame = compactForms.contains(
                    normalizeGameNameNoAlias(tag).replaceAll(' ', '')) ||
                compactForms
                    .contains(normalizeGameName(tag).replaceAll(' ', ''));
            return isGame ? ' $_gameMark ' : '';
          });
    // Mentions de langue retirées (D1.6 — accents conservés).
    result =
        _stripLanguageMentions(result.replaceAll(RegExp(r'\s+'), ' ').trim());
    // §125 — nom de la chaîne (après les hashtags : « … - Chaîne #jeu » ;
    // avant les mentions du jeu : « 紫雨carol《jeu》… »).
    result = stripChannelName(result, channelName, gameName: game);
    // Retrait insensible à la casse, aux accents et à la ponctuation ;
    // formes les plus longues d'abord (jamais de retrait partiel).
    final sorted = forms.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final form in sorted) {
      // Chaque mention devient un repère ; la préposition qui la précède
      // (« dans », « in », « pour », « для »…) est retirée ENSUITE, une
      // seule fois ([_orphanPrepBeforeMark]) — « Comment jouer son
      // nécromancien Dans Albion » → « Comment jouer son nécromancien ».
      final pattern = _gameMentionPattern(form);
      // Le caractère de limite avant la mention (groupe 1) est réinséré.
      if (pattern != null) {
        result = result.replaceAllMapped(
            pattern, (m) => '${m.group(1) ?? ''}$_gameMark');
      }
    }
    for (final raw in rawForms) {
      final p = _rawNamePattern(raw);
      if (p != null) result = result.replaceAll(p, _gameMark);
    }
    // Mention ENCADRÉE (« (Elden Ring) », « 【艾尔登法环】 ») : l'encadrement
    // part avec elle — « Guide for (Elden Ring) » → « Guide » (avant :
    // « Guide ) »).
    result = result.replaceAll(_bracketedMark, _gameMark);
    // Fragments orphelins COLLÉS à un repère — UNE SEULE passe : au plus une
    // préposition retirée par mention. En boucle, « What to do in Elden
    // Ring » perdait « in », puis « do », puis « to » (→ « What »).
    result = result
        .replaceAllMapped(
            _orphanPrepBeforeMark, (m) => '${m.group(1)}$_gameMark')
        .replaceAllMapped(
            _ptContractionBeforeMark, (m) => '${m.group(1)}$_gameMark')
        .replaceAll(_possessiveAfterMark, _gameMark)
        .replaceAll(_cjkParticleAfterMark, _gameMark)
        .replaceAll(_orphanPrepAfterMarkAtEnd, _gameMark);
    result = result.replaceAll(_gameMark, ' ');

    // (c) Nettoyage post-retrait.
    // D1.2 — purge des paires vides laissées par une mention encadrée du jeu
    // (« Guide complet () » → « Guide complet ») ; en boucle pour les
    // imbrications (« ( []) »). §123 : aussi 【】《》「」（）.
    var prevPairs = '';
    while (prevPairs != result) {
      prevPairs = result;
      result = result.replaceAll(_emptyPair, '');
    }
    result = result.replaceAll(RegExp(r'\s+'), ' ');
    // Séparateurs doublés au milieu (« - - » → « - », « - : » → « - »).
    result = result.replaceAllMapped(
      RegExp(r'\s*([-–—:|•：｜])(?:\s*[-–—:|•：｜])+\s*'),
      (m) => ' ${m.group(1)} ',
    );
    // Séparateurs orphelins en bordure (« - Ep 1 » → « Ep 1 »).
    // B-001 : `()` et `[]` RETIRÉS de la classe (ils mangeaient les
    // encadrements légitimes, ex. « boss (spoiler) » → « boss (spoiler ») —
    // la purge D1.2 des paires vides couvre « Guide complet () »/« [] Guide ».
    // §123 : aussi —, · et la ponctuation pleine chasse (：｜，、).
    result = result.replaceAll(RegExp(r'^[\s\-–—:|•/,·：｜，、]+'), '');
    result = result.replaceAll(RegExp(r'[\s\-–—:|•/,·：｜，、]+$'), '');
    result = result.trim();

    // D1.7 — normalisation finale : première lettre en majuscule (correction
    // de casse minimale et sûre — le reste du titre n'est pas touché).
    if (result.isNotEmpty) {
      final first = result[0].toUpperCase();
      if (first != result[0]) result = first + result.substring(1);
    }

    // (d) Garde-fou : jamais de titre vide ou quasi vide en base.
    // §123 : 2 caractères suffisent en écriture sans espaces (« 攻略 » =
    // « guide »).
    if (result.length < (_isUnspacedScript(result) ? 2 : 3)) {
      return withoutHashtags;
    }
    return result;
  }

  // ── §123 — repères de retrait, bruit de plateforme, noms non latins ─────

  /// Repère temporaire d'une mention du jeu retirée (caractère de contrôle,
  /// jamais présent dans un titre).
  static const String _gameMark = '\u0001';

  /// Préposition/fragment de [_orphanPreps] juste AVANT un repère (le
  /// caractère de limite, groupe 1, est conservé).
  static final RegExp _orphanPrepBeforeMark = RegExp(
    '(^|[^\\p{L}\\p{N}])(?:$_orphanPrepAlt)[\\s\\-–—:|•/：｜]*$_gameMark',
    caseSensitive: false,
    unicode: true,
  );

  /// « no »/« na » portugais juste AVANT un repère (« Como upar rápido no
  /// Elden Ring ») — SEULEMENT en milieu de titre (un mot juste avant) :
  /// en anglais, « No Elden Ring spoilers » garde son « No ».
  static final RegExp _ptContractionBeforeMark = RegExp(
    '(?<=[\\p{L}\\p{N}])(\\s+)(?:no|na|nos|nas)\\s+$_gameMark',
    caseSensitive: false,
    unicode: true,
  );

  /// Fragment de [_orphanPreps] juste APRÈS un repère, en FIN de titre
  /// (« Astuces pour Elden Ring in the » → « Astuces ») — jamais ailleurs :
  /// après la mention, « Elden Ring - Do this now » garde son « Do ».
  static final RegExp _orphanPrepAfterMarkAtEnd = RegExp(
    '$_gameMark[\\s\\-–—:|•/：｜]*(?:$_orphanPrepAlt)[\\s\\-–—:|•/：｜]*\$',
    caseSensitive: false,
    unicode: true,
  );

  /// Possessif juste APRÈS un repère : « Arma Reforger's », « …’s »,
  /// « …´s », « …ʼs » ou « … s » isolé (minuscule — « S rank » gardé).
  static final RegExp _possessiveAfterMark = RegExp(
    "$_gameMark(?:\\s*['’´‘ʼ`]\\s?s|\\s+s)(?![\\p{L}\\p{N}])",
    unicode: true,
  );

  /// Particule COLLÉE juste après un repère : possessif chinois 的 et
  /// japonais の (« 艾尔登法环的攻略 » → « 攻略 ») ; particules coréennes
  /// suivies d'une limite de mot (« 엘든링의 공략 » → « 공략 »).
  static final RegExp _cjkParticleAfterMark = RegExp(
    '$_gameMark(?:[的の]|(?:에서|으로|의|에|은|는|이|가|을|를|도|와|과|로)(?![\\p{L}\\p{N}]))',
    unicode: true,
  );

  /// Mention ENCADRÉE devenue repère : « (■) », « [■] », « 【■】 »…
  static final RegExp _bracketedMark =
      RegExp('[(\\[【《「『（]\\s*$_gameMark\\s*[)\\]】》」』）]');

  /// Paire vide (y compris les crochets CJK) laissée par un retrait.
  static final RegExp _emptyPair =
      RegExp(r'\(\s*\)|\[\s*\]|【\s*】|《\s*》|「\s*」|『\s*』|（\s*）');

  /// Repère TECHNIQUE encadré, sans intérêt dans l'app : 【4K】, [1080P],
  /// (60帧), 【4K HDR】, 【超清】… (§123 — titres bilibili).
  static final RegExp _techTag = RegExp(
    r'[【\[(（]\s*(?:(?:[248]\s*k|\d{3,4}\s*p|\d{2,3}\s*(?:帧|fps)|hdr(?:10)?\+?|超高清|超清|高清|蓝光|原画|无损|杜比(?:视界)?)[\s/+·|&,，、]*)+[】\])）]',
    caseSensitive: false,
    unicode: true,
  );

  /// Suffixe des titres de page bilibili : « …_哔哩哔哩_bilibili ».
  static final RegExp _biliTitleSuffix =
      RegExp(r'[\s_\-|]*哔哩哔哩[\s_\-|]*bilibili\s*$', caseSensitive: false);

  /// Nom de la plateforme dans un titre : « bilibili » (mot entier),
  /// « 哔哩哔哩 », « B站 ».
  static final RegExp _platformWords = RegExp(
    r'(?<![A-Za-z0-9])bilibili(?![A-Za-z0-9])|哔哩哔哩|(?<![A-Za-z0-9])[bB]站',
    caseSensitive: false,
  );

  /// §123 (F) — retire les repères techniques ([_techTag]) et le nom de la
  /// plateforme bilibili d'un titre.
  static String _stripPlatformNoise(String s) => s
      .replaceAll(_techTag, ' ')
      .replaceAll(_biliTitleSuffix, '')
      .replaceAll(_platformWords, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Écriture SANS espaces entre les mots (idéogrammes, kana) ou à
  /// particules collées (hangul) : pas de limite de mot exigée.
  static bool _isUnspacedScript(String s) => s.runes.any((r) =>
      (r >= 0x3040 && r <= 0x30FF) || // hiragana, katakana
      (r >= 0x31F0 && r <= 0x31FF) ||
      (r >= 0x3400 && r <= 0x4DBF) || // CJK ext. A
      (r >= 0x4E00 && r <= 0x9FFF) || // CJK
      (r >= 0xAC00 && r <= 0xD7AF) || // hangul
      (r >= 0xFF66 && r <= 0xFF9F)); // katakana demi-chasse

  /// §123 (F) — motif d'un nom traduit NON LATIN tel qu'en base (espaces
  /// souples), encadrement 【】《》「」[]() compris. Nom de 2 caractères :
  /// seulement ENCADRÉ (souvent un mot courant : 杀手 « tueur » = HITMAN).
  static RegExp? _rawNamePattern(String raw) {
    final t = raw.trim();
    final letters = _letterOrDigit.allMatches(t).length;
    if (letters < 2) return null;
    final body = t.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s*');
    const open = r'[【《「『\[(（]';
    const close = r'[】》」』\])）]';
    if (letters <= 2) {
      return RegExp('$open\\s*$body\\s*$close', unicode: true);
    }
    final core = '$open?\\s*$body\\s*$close?';
    return _isUnspacedScript(t)
        ? RegExp(core, unicode: true)
        : RegExp('(?<![\\p{L}\\p{N}])$core(?![\\p{L}\\p{N}])',
            caseSensitive: false, unicode: true);
  }

  // ── §125 — nom de la CHAÎNE retiré des titres (s'il est détaché) ────────

  /// §125 — retire le NOM DE LA CHAÎNE [channelName] de [title] quand il est
  /// DÉTACHÉ de la phrase (demande du propriétaire, 25/09/2026 : « … -
  /// Director Glitching - DarkViperAU » → « … - Director Glitching ») :
  /// - encadré, crédit compris : « [GOG] », « 【李思明】 », « (by Vman) » ;
  /// - mention « @Chaîne » n'importe où, crédit compris (« feat. @X ») ;
  /// - segment complet entre deux séparateurs (« … | Yanni | Arjun
  ///   Venkatesh | Instrumental » → « … | Yanni | Instrumental ») ;
  /// - FIN de titre après un séparateur (« … | GameStop »), un crédit
  ///   (« … (Full) By Vman », « … Outside Xbox on IGN ») ou un espace qui
  ///   suit une ponctuation / un emoji (« … (Guide) rus199410 ») ;
  /// - DÉBUT de titre suivi d'un séparateur ou d'un encadrement CJK
  ///   (« Kayane - … », « 紫雨carol《…》 ») ;
  /// GARDÉ quand il fait partie de la phrase (« How IGN Won… », « Caedo
  /// Plays #69 », « … boss guide » pour la chaîne « Guide ») : le retirer la
  /// casserait. Ignoré : nom de moins de 3 lettres/chiffres (« TV »), ou
  /// CONTENU dans le nom du jeu [gameName] (chaîne officielle « Call of
  /// Duty » pour « Call of Duty: Modern Warfare III » : le retrait du jeu,
  /// plus long, s'en charge). Garde-fou : titre trop court après retrait →
  /// rendu inchangé ; sans retrait, titre rendu tel quel. PUR.
  /// ⚠️ Copie à l'identique dans tools/vision/lib/sentinelle_runner.dart (admin_title_parity_test).
  static String stripChannelName(String title, String? channelName,
      {String? gameName}) {
    final name = decodeHtmlEntities(channelName ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceFirst(RegExp(r'^@+'), '')
        .trim();
    if (_letterOrDigit.allMatches(name).length < 3 ||
        _channelIsInGameName(name, gameName)) {
      return title;
    }
    final body = _channelNameSource(name);
    final ch = '@?$body';
    final credit = '(?:(?<![\\p{L}\\p{N}_])(?:$_channelCreditAlt)\\s*)';
    RegExp re(String source) =>
        RegExp(source, caseSensitive: false, unicode: true);
    var t = title
        // Encadré, crédit compris : « [GOG] », « (by Vman) », « 【李思明】 ».
        .replaceAllMapped(
            re('[(\\[【《「『（]\\s*$credit?$ch\\s*[)\\]】》」』）]'),
            _channelGap)
        // Mention « @Chaîne » n'importe où, crédit compris (« feat. @X »).
        .replaceAllMapped(re('$credit?@$body'), _channelGap)
        // Segment complet entre deux séparateurs.
        .replaceAll(re('$_channelSep$ch(?=$_channelSep)'), '')
        // Fin de titre ; les symboles qui suivent (« ! », emoji) partent aussi.
        .replaceAll(
            re('(?:$_channelSep$credit?|\\s+$credit|(?<=[^\\p{L}\\p{N}\\s])\\s+)'
                '$ch[^\\p{L}\\p{N}]*\$'),
            '')
        // Début de titre, suivi d'un séparateur ou d'un encadrement.
        .replaceAll(
            re('^[\\s$_gameMark]*$ch'
                '(?:$_channelSep|\\s*(?=[【《「『]))'),
            '');
    if (t == title) return title;
    // Chaque retrait emporte son séparateur : seuls les espaces et les
    // bords sont nettoyés (« —— », « ··· » d'origine intacts).
    t = t
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s\-–—:|•/,·~：｜丨，、]+'), '')
        .replaceAll(RegExp(r'[\s\-–—:|•/,·~：｜丨，、]+$'), '')
        .trim();
    final visible = t.replaceAll(_gameMark, '').trim();
    if (visible.length < (_isUnspacedScript(visible) ? 2 : 3)) return title;
    final first = t[0].toUpperCase();
    return first == t[0] ? t : first + t.substring(1);
  }

  /// §125 — remplacement d'un retrait au MILIEU du titre (encadré,
  /// mention) : une espace entre deux mots d'écriture espacée, rien à côté
  /// d'un caractère CJK ou d'une ponctuation pleine chasse (« 謎團！【頻道】
  /// 李家名 » → « 謎團！李家名 »).
  static String _channelGap(Match m) {
    final s = m.input;
    bool wordSide(String c) {
      if (c.trim().isEmpty) return false;
      final r = c.codeUnitAt(0);
      return !_isUnspacedScript(c) &&
          !(r >= 0x3000 && r <= 0x303F) &&
          !(r >= 0xFF00 && r <= 0xFFEF);
    }

    final before = m.start > 0 ? s[m.start - 1] : '';
    final after = m.end < s.length ? s[m.end] : '';
    return wordSide(before) && wordSide(after) ? ' ' : '';
  }

  /// §125 — crédit juste avant le nom de la chaîne, retiré avec lui (« by »,
  /// « feat. », « w/ », « on », « par », « von »…).
  static const List<String> _channelCredits = [
    // Anglais.
    'featuring', 'feat.', 'feat', 'ft.', 'ft', 'w/', 'with', 'by', 'from',
    'via', 'on', 'of',
    // Français.
    'avec', 'par', 'sur', 'chez', 'de',
    // Espagnol, portugais, italien.
    'por', 'con', 'com', 'da', 'di', 'per',
    // Allemand.
    'von', 'mit', 'bei', 'auf',
    // Russe.
    'от', 'с', 'на',
  ];

  /// Alternation regex de [_channelCredits] (formes longues d'abord).
  static final String _channelCreditAlt = (List<String>.of(_channelCredits)
        ..sort((a, b) => b.length.compareTo(a.length)))
      .map(_escapeRegex)
      .join('|');

  /// §125 — séparateur de SEGMENT : barres, puces, deux-points, tildes
  /// (collés ou non) ; tiret et barre oblique seulement avec un espace d'un
  /// côté au moins (« Spider-Man », « 1/12 » ne séparent rien).
  static const String _channelSep =
      r'(?:\s*[|｜丨•·:：~]+\s*|\s+[-–—/]+\s*|\s*[-–—/]+\s+)';

  /// Échappement SÛR en mode `unicode: true` : seuls les caractères de
  /// syntaxe sont échappés (un échappement inutile, « \- » ou « \: », est
  /// refusé en mode unicode). Identique en VM et en JavaScript.
  static String _escapeRegex(String s) => s
      .split('')
      .map((c) => r'\^$.*+?()[]{}|'.contains(c) ? '\\$c' : c)
      .join();

  /// §125 — source regex du nom de chaîne [name] (casse insensible à la
  /// compilation) : espaces souples, apostrophes interchangeables ; limite
  /// de mot à chaque bord en écriture ESPACÉE (latin, cyrillique…), aucune
  /// en écriture sans espaces (« 紫雨carol », « 志祺七七 »).
  static String _channelNameSource(String name) {
    bool spacedWord(int rune) {
      final c = String.fromCharCode(rune);
      return _letterOrDigit.hasMatch(c) && !_isUnspacedScript(c);
    }

    final runes = name.runes.toList();
    final buf = StringBuffer();
    if (spacedWord(runes.first)) buf.write(r'(?<![\p{L}\p{N}_])');
    var space = false;
    for (final rune in runes) {
      final c = String.fromCharCode(rune);
      if (c.trim().isEmpty) {
        space = true;
        continue;
      }
      if (space) buf.write(r'\s*');
      space = false;
      buf.write("'’´‘ʼ`".contains(c) ? "['’´‘ʼ`]" : _escapeRegex(c));
    }
    if (spacedWord(runes.last)) buf.write(r'(?![\p{L}\p{N}_])');
    return buf.toString();
  }

  /// §125 — vrai si le nom de chaîne [channel] est CONTENU (mots entiers)
  /// dans le nom du jeu [gameName] : chaîne officielle ou de la licence,
  /// retirée par le nettoyage du jeu lui-même.
  static bool _channelIsInGameName(String channel, String? gameName) {
    final game = gameName?.trim() ?? '';
    final c = normalizeGameNameNoAlias(channel);
    if (game.isEmpty || c.isEmpty) return false;
    return ' ${normalizeGameNameNoAlias(game)} '.contains(' $c ') ||
        ' ${normalizeGameName(game)} '.contains(' $c ');
  }

  /// §123 — lettre d'une écriture NON LATINE (chinois, japonais, coréen,
  /// cyrillique, arabe…).
  static final RegExp _nonLatinLetter =
      RegExp(r'(?!\p{Script=Latin})\p{L}', unicode: true);

  static bool _hasNonLatinLetter(String s) => _nonLatinLetter.hasMatch(s);

  /// §123 (G) — décode les entités HTML d'un titre (« &#039; » → « ' »,
  /// « &amp; » → « & »…), deux passes (double encodage). Copie de
  /// `decodeSearchHtmlEntities` (tools/vision/lib/scruteur_web_search.dart).
  static String decodeHtmlEntities(String s) {
    var out = s;
    for (var pass = 0; pass < 2; pass++) {
      out = out
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAll('&#39;', "'")
          .replaceAll('&rsquo;', "'")
          .replaceAll('&lsquo;', "'")
          .replaceAll('&ldquo;', '"')
          .replaceAll('&rdquo;', '"');
      out = out.replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      );
      out = out.replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      );
    }
    return out;
  }

  /// §123 — suffixes publics à deux étiquettes (« foo.co.uk »).
  static const Set<String> _multiLabelSuffixes = {
    'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'com.br', 'com.au', 'co.jp',
    'co.kr', 'com.cn', 'com.tw', 'net.cn', 'co.in', 'com.mx', 'com.ar',
    'com.tr', 'co.nz', 'com.es', 'com.pt',
  };

  /// §123 — domaine « enregistrable » d'un hôte (« www.gamerant.com » →
  /// « gamerant.com », « foo.co.uk » gardé entier). Meilleur effort, même
  /// règle que `registrableDomain` des bots.
  static String _registrableDomain(String host) {
    var h = host.trim().toLowerCase();
    if (h.startsWith('www.')) h = h.substring(4);
    final labels = h.split('.').where((l) => l.isNotEmpty).toList();
    if (labels.length <= 2) return labels.join('.');
    final twoLast = labels.sublist(labels.length - 2).join('.');
    if (_multiLabelSuffixes.contains(twoLast)) {
      return labels.sublist(labels.length - 3).join('.');
    }
    return twoLast;
  }

  /// §123 — URL d'une plateforme VIDÉO (YouTube, bilibili dont b23.tv,
  /// RUTUBE, Twitch) — même règle que Sentinelle (`isVideoPlatformUrl`).
  static bool isVideoPlatformUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('youtube.com') ||
        u.contains('youtu.be') ||
        u.contains('bilibili.com') ||
        u.contains('b23.tv') ||
        u.contains('rutube.ru') ||
        u.contains('twitch.tv');
  }

  /// §123 (A) — titre d'une PAGE WEB : titre + domaine du site
  /// (« Walkthrough … (gamerant.com) ») ; un segment de marque final qui
  /// répète le site (« … | Game Rant ») est retiré. Même règle que
  /// Sentinelle (`webTitleWithDomain`). PUR.
  static String webTitleWithDomain(String cleanedTitle, String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return cleanedTitle;
    final domain = _registrableDomain(host);
    if (domain.isEmpty) return cleanedTitle;
    String squash(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final brand = squash(domain.split('.').first);
    var t = cleanedTitle.trim();
    final m = RegExp(r'\s+[|\-–—:·•]\s+([^|\-–—:·•]+)$').firstMatch(t);
    if (m != null) {
      final seg = squash(m.group(1)!);
      if (seg.isNotEmpty && (seg == brand || seg == squash(domain))) {
        t = t.substring(0, m.start).trim();
      }
    }
    if (t.toLowerCase().contains(domain.toLowerCase())) return t;
    return t.isEmpty ? domain : '$t ($domain)';
  }

  // ── D1 — listes partagées et helpers du nettoyage de titre ──────────────

  /// D1.1 — hashtag NON numérique : `#BOTW` est retiré, `#328` (suite/série)
  /// est conservé. Le lookahead exige que le hashtag ne soit pas composé
  /// uniquement de chiffres (`#328abc` est retiré, `#328` ou `#328,` gardés).
  static final RegExp _hashtagPattern = RegExp(
    r'#(?!\d+(?![\p{L}\p{N}_]))\S+',
    unicode: true,
  );

  /// D1.3 — prépositions/fragments orphelins retirés quand ils TOUCHENT une
  /// mention retirée du jeu ([_orphanPrepBeforeMark] : une seule fois par
  /// mention ; [_orphanPrepAfterMarkAtEnd] : en fin de titre). §123 : langues
  /// des packs Vision ajoutées (espagnol, portugais, italien, allemand,
  /// russe) et élisions françaises. Le tiret isolé « - » est couvert par les
  /// séparateurs orphelins de bordure (étape c).
  static const List<String> _orphanPreps = [
    // Anglais (« do » : aussi portugais « do » = « du »).
    'in the', 'for', 'at', 'to', 'of', 'do', 'in', 'on', 'with', 'about',
    'from', 'into', "'s",
    // Français.
    'de', 'à', 'en', 'pour', 'dans', 'sur', 'avec', 'du', 'au', "d'", "l'",
    // Espagnol, portugais, italien.
    'para', 'pra', 'del', 'al', 'con', 'com', 'sobre', 'em', 'da', 'per',
    'su', 'nel', 'di',
    // Allemand.
    'für', 'im', 'mit', 'bei', 'von', 'zu',
    // Russe.
    'в', 'во', 'на', 'для', 'по', 'про', 'из',
  ];

  /// Alternation regex de [_orphanPreps] : formes longues d'abord, espaces
  /// = `\s+`, apostrophe droite ou typographique (« 's », « d' », « l' »).
  static final String _orphanPrepAlt = (List<String>.of(_orphanPreps)
        ..sort((a, b) => b.length.compareTo(a.length)))
      .map((p) => p
          .split(' ')
          .map((w) => RegExp.escape(w).replaceAll("'", "['’]"))
          .join(r'\s+'))
      .join('|');

  /// D1.5 — ajoute à [forms] la forme PARTIELLE d'un nom brut contenant
  /// « : » : le préfixe avant les deux-points (« Horizon Forbidden West:
  /// Burning Shores » → « horizon forbidden west »), SEULEMENT s'il fait
  /// ≥ 10 caractères ET ≥ 2 mots (anti « diablo » pour « diablo 4 »).
  static void _addColonPrefixForm(String rawName, Set<String> forms) {
    final colon = rawName.indexOf(':');
    if (colon <= 0) return;
    final prefix = rawName.substring(0, colon).trim();
    if (prefix.length < 10) return;
    if (prefix.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length < 2) {
      return;
    }
    final norm = normalizeGameName(prefix);
    if (norm.length >= 3) forms.add(norm);
  }

  /// D1.6 — les 12 langues de l'app : formes longues/natives retirées des
  /// titres (bordures, après séparateur, encadrement).
  static const List<String> _languageLongForms = [
    'español',
    'français',
    'english',
    'deutsch',
    'português',
    'italiano',
    'русский',
    '日本語',
    '中文',
    '한국어',
    'العربية',
    'हिन्दी',
  ];

  /// D1.6 — codes langue : 2 lettres (codes canoniques du pack) + variantes
  /// ISO-3 fréquentes dans les titres YouTube ([ESP], (FRA)…). Retirés
  /// uniquement en MAJUSCULES, entre crochets/parenthèses ou accolés à un
  /// séparateur en bordure — JAMAIS nus en milieu de titre.
  static const List<String> _languageCodes = [
    'FR', 'EN', 'ES', 'PT', 'DE', 'IT', 'RU', 'JA', 'ZH', 'KO', 'AR', 'HI',
    'ESP', 'FRA', 'ENG', 'DEU', 'POR', 'ITA', 'RUS', 'JPN', 'KOR', 'ARA',
    'HIN',
  ];

  static final String _langLongAlt =
      _languageLongForms.map(RegExp.escape).join('|');
  static final String _langCodeAlt = _languageCodes.join('|');

  /// Mention de langue entre crochets/parenthèses : codes (MAJUSCULES
  /// seulement) ou formes longues (casse insensible) — retirés AVEC
  /// l'encadrement.
  static final RegExp _langBracketedCode =
      RegExp('[\\(\\[]\\s*(?:$_langCodeAlt)\\s*[\\)\\]]');
  static final RegExp _langBracketedLong = RegExp(
      '[\\(\\[]\\s*(?:$_langLongAlt)\\s*[\\)\\]]',
      caseSensitive: false);

  /// Grappe de mentions de langue en FIN de titre (formes longues et/ou
  /// codes, séparés par espaces/séparateurs).
  static final RegExp _langEndCluster = RegExp(
      '(?:[\\s\\-–:|/]+(?:$_langLongAlt|$_langCodeAlt))+[\\s\\-–:|/]*\$',
      caseSensitive: false);

  /// Test « contient une forme longue » pour une grappe de fin.
  static final RegExp _langLongWord =
      RegExp(_langLongAlt, caseSensitive: false);

  /// Forme(s) longue(s) en DÉBUT de titre (« Español Guide… »).
  static final RegExp _langStartCluster = RegExp(
      '^(?:$_langLongAlt)(?:[\\s\\-–:|/]+(?:$_langLongAlt))*(?=[\\s\\-–:|/]|\$)',
      caseSensitive: false);

  /// Code MAJUSCULE en bordure accolé à un séparateur (« | EN », « EN - »).
  static final RegExp _langCodeEndSep =
      RegExp('\\s*[-–:|/]+\\s*(?:$_langCodeAlt)\\s*\$');
  static final RegExp _langCodeStartSep =
      RegExp('^(?:$_langCodeAlt)\\s*[-–:|/]+\\s*');

  /// Forme longue juste APRÈS un séparateur (milieu de titre).
  static final RegExp _langLongAfterSep = RegExp(
      '([-–:|/])\\s+(?:$_langLongAlt)(?=\\s|\$)',
      caseSensitive: false);

  /// D1.6 — retire les mentions de langue résiduelles d'un titre (le contenu
  /// est déjà classé par langue dans l'app) : formes longues/natives des 12
  /// langues et codes MAJUSCULES, BORNÉS aux bordures du titre, après un
  /// séparateur ou entre crochets/parenthèses. Une grappe de fin n'est
  /// retirée que si elle contient au moins une forme longue — un code court
  /// nu en bordure (« act 1 walkthrough FR ») est CONSERVÉ.
  static String _stripLanguageMentions(String input) {
    var out = input;
    // 1. Encadrements : [ESP], (FR), (Español)…
    out = out.replaceAll(_langBracketedCode, '');
    out = out.replaceAll(_langBracketedLong, '');
    // 2. Grappe en fin de titre (« Guide complet EN Español ») — retirée si
    //    elle contient au moins une forme longue ; bouclée par sécurité.
    var prev = '';
    while (prev != out) {
      prev = out;
      out = out.replaceAllMapped(_langEndCluster,
          (m) => _langLongWord.hasMatch(m.group(0)!) ? '' : m.group(0)!);
    }
    // 3. Forme(s) longue(s) en début de titre.
    out = out.replaceAll(_langStartCluster, '');
    // 4. Code MAJUSCULE en bordure accolé à un séparateur.
    out = out.replaceAll(_langCodeEndSep, '');
    out = out.replaceAll(_langCodeStartSep, '');
    // 5. Forme longue juste après un séparateur (milieu de titre).
    out = out.replaceAllMapped(_langLongAfterSep, (m) => m.group(1)!);
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
