// Pur (VM) — catégories de bannissement (table `ban_categories`, migration
// 0094 : liste FERMÉE, route EF `moderation/categories`). P4b-3, lot L2.
//
// Décision D4 du propriétaire : un ban MANUEL ne propose que les catégories
// dont `auto_allowed = false` (Modération par défaut, Spam, Abus, Autre) ;
// « Injection IA » est réservée au ban automatique (filtrage au panneau, le
// serveur reste tel quel).
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM.
import 'package:flutter/foundation.dart';

/// Une catégorie de bannissement telle que renvoyée par
/// `moderation/categories` (`code`, `label_fr`, `auto_allowed`), dans l'ordre
/// voulu par le serveur.
@immutable
class BanCategory {
  const BanCategory({
    required this.code,
    required this.labelFr,
    required this.autoAllowed,
  });

  /// Code stable (`moderation`, `spam`, `abus`, `injection_ia`, `autre`).
  final String code;

  /// Libellé français à afficher.
  final String labelFr;

  /// Vrai si la catégorie est réservée / permise au ban AUTOMATIQUE.
  final bool autoAllowed;

  /// Lecture tolérante : `code` texte non vide requis (sinon `null`, élément
  /// ignoré) ; `label_fr` absent ou vide → le code ; `auto_allowed` absent ou
  /// non booléen → `false`.
  static BanCategory? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? code = j['code'];
    if (code is! String || code.trim().isEmpty) return null;
    final Object? label = j['label_fr'];
    final Object? auto = j['auto_allowed'];
    return BanCategory(
      code: code,
      labelFr: label is String && label.trim().isNotEmpty ? label : code,
      autoAllowed: auto is bool && auto,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BanCategory &&
      other.code == code &&
      other.labelFr == labelFr &&
      other.autoAllowed == autoAllowed;

  @override
  int get hashCode => Object.hash(code, labelFr, autoAllowed);

  @override
  String toString() => 'BanCategory($code)';
}

/// Code de la catégorie réservée au ban automatique (jamais proposée au ban
/// manuel, D4).
const String kAutoOnlyBanCategory = 'injection_ia';

/// Repli si `moderation/categories` échoue : les 4 codes manuels de 0094
/// (M94:104-113, liste fermée par CHECK M94:90-91 et `BAN_CATEGORIES`
/// de moderation.ts:45), dans l'ordre serveur.
const List<BanCategory> kManualBanCategoriesFallback = <BanCategory>[
  BanCategory(code: 'moderation', labelFr: 'Modération', autoAllowed: false),
  BanCategory(code: 'spam', labelFr: 'Spam', autoAllowed: false),
  BanCategory(code: 'abus', labelFr: 'Abus', autoAllowed: false),
  BanCategory(code: 'autre', labelFr: 'Autre', autoAllowed: false),
];

/// Catégorie par défaut d'un ban manuel (défaut serveur : moderation.ts:616,
/// index.ts:4439).
const String kDefaultManualBanCategory = 'moderation';

/// D4 : catégories proposées au ban MANUEL = `auto_allowed == false`, dans
/// l'ordre serveur, sans doublon de code. `injection_ia` est exclue même si
/// le serveur la marquait un jour `auto_allowed = false` (réservée au ban
/// automatique). Liste résultante vide → repli [kManualBanCategoriesFallback].
List<BanCategory> manualBanCategories(List<BanCategory> all) {
  final Set<String> seen = <String>{};
  final List<BanCategory> out = <BanCategory>[
    for (final BanCategory c in all)
      if (!c.autoAllowed && c.code != kAutoOnlyBanCategory && seen.add(c.code))
        c,
  ];
  return out.isEmpty
      ? kManualBanCategoriesFallback
      : List<BanCategory>.unmodifiable(out);
}

/// Libellé d'un code de catégorie : liste [known] (réponse serveur), sinon
/// repli [kManualBanCategoriesFallback], sinon « Injection IA » pour
/// `injection_ia`, sinon le code brut. Code absent ou vide → « — ».
String banCategoryLabel(String? code, [List<BanCategory> known = const []]) {
  if (code == null || code.isEmpty) return '—';
  for (final BanCategory c in known) {
    if (c.code == code) return c.labelFr;
  }
  for (final BanCategory c in kManualBanCategoriesFallback) {
    if (c.code == code) return c.labelFr;
  }
  if (code == kAutoOnlyBanCategory) return 'Injection IA';
  return code;
}
