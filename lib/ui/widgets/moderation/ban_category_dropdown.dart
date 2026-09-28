// Liste déroulante « Catégorie » d'un ban MANUEL (P4b-3, lot L5, décision D4,
// conception §4.1, §6.9) : seulement les catégories `auto_allowed == false`
// (Modération par défaut, Spam, Abus, Autre) ; « Injection IA » n'est
// JAMAIS proposée, même si l'appelant la fournit (`manualBanCategories`) ;
// liste vide → repli local des 4 catégories.
//
// Widget « de présentation » (aucun Provider) → testable en VM. Clé :
// `ban-category-dropdown`.
import 'package:flutter/material.dart';

import '../../../domain/models/ban_category.dart';

/// Code effectivement retenu pour [value] parmi les choix de [categories]
/// (D4) : [value] s'il est proposé, sinon « moderation », sinon le premier.
String effectiveBanCategory(List<BanCategory> categories, String value) {
  final List<BanCategory> opts = manualBanCategories(categories);
  if (opts.any((BanCategory c) => c.code == value)) return value;
  if (opts.any((BanCategory c) => c.code == kDefaultManualBanCategory)) {
    return kDefaultManualBanCategory;
  }
  return opts.first.code;
}

class BanCategoryDropdown extends StatelessWidget {
  const BanCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
    this.label = 'Catégorie',
    this.enabled = true,
  });

  /// Catégories connues (réponse serveur ou repli) ; filtrées ici.
  final List<BanCategory> categories;

  /// Code sélectionné ; un code absent des choix → défaut « moderation ».
  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final bool enabled;

  /// Choix proposés (D4).
  List<BanCategory> get options => manualBanCategories(categories);

  /// Code effectivement affiché pour [value].
  String get effectiveValue => effectiveBanCategory(categories, value);

  @override
  Widget build(BuildContext context) {
    final List<BanCategory> opts = options;
    return DropdownButtonFormField<String>(
      key: const Key('ban-category-dropdown'),
      initialValue: effectiveValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.label_outline_rounded),
        border: const OutlineInputBorder(),
      ),
      items: <DropdownMenuItem<String>>[
        for (final BanCategory c in opts)
          DropdownMenuItem<String>(
            value: c.code,
            child: Text(c.labelFr, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled
          ? (String? v) {
              if (v != null) onChanged(v);
            }
          : null,
    );
  }
}
