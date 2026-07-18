import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../core/i18n/app_languages.dart';
import '../../core/i18n/language_chip.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/category.dart';
import '../../domain/models/content.dart';
import '../../domain/models/game.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/stat_card.dart' show StatusBadge;
import '../widgets/confirm_dialog.dart';

/// Gestion des contenus : liste filtrable + ajout manuel + édition titre + suppression.
class ContentsScreen extends StatefulWidget {
  const ContentsScreen({super.key});

  @override
  State<ContentsScreen> createState() => _ContentsScreenState();
}

class _ContentsScreenState extends State<ContentsScreen> {
  String? _gameFilter; // null = tous
  /// Filtre catégorie : 'media' = vidéo+guides fusionnés, 'links' = liens, null = toutes.
  String? _catFilter;
  /// Filtre langue multi-sélection : codes MAJUSCULES actifs.
  /// Vide = toutes les langues (sauf cas « Sans langue » ci-dessous).
  Set<String> _activeLanguages = <String>{};
  /// Si vrai, inclut aussi les contenus sans langue (`videoLanguage` null).
  /// Cumulable avec [_activeLanguages].
  bool _showNoLanguage = false;
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();

  // ── État du tri des colonnes ──
  /// Index de la colonne triée (null = tri par défaut publishedAt DESC).
  /// 0=Titre, 1=Jeu, 2=Catégorie, 3=Créé le, 4=Langue, 5=Checked.
  int? _sortColumnIndex;
  bool _sortAscending = false; // false = décroissant par défaut.

  // ── Pagination ──
  int _currentPage = 0;
  static const int _pageSize = 250;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();

    List<Content> list = store.contents.where((c) => c.validated).toList();

    // ── Filtres ──
    if (_gameFilter != null) {
      list = list.where((c) => c.gameId == _gameFilter).toList();
    }
    // Filtre catégorie fusionné : 'media' = vidéo OU guides, 'links' = liens.
    if (_catFilter == 'media') {
      list = list.where((c) =>
          c.category == ContentCategory.video ||
          c.category == ContentCategory.guides).toList();
    } else if (_catFilter == 'links') {
      list = list.where((c) => c.category == ContentCategory.links).toList();
    }
    // Filtre langue multi-sélection.
    // - Si _showNoLanguage est vrai, on inclut les contenus sans langue.
    // - Si _activeLanguages est vide ET !_showNoLanguage, on garde tout.
    // - Sinon, on ne garde que les contenus dont la langue est dans l'ensemble.
    if (_activeLanguages.isNotEmpty || _showNoLanguage) {
      list = list.where(passesLanguageFilter).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((c) => c.displayTitle.toLowerCase().contains(q))
          .toList();
    }

    // ── Tri par colonne ──
    _applySort(list, store);

    // ── Pagination locale : découpe la liste filtrée+triée en pages de 250 ──
    final totalPages = (list.length / _pageSize).ceil();
    if (_currentPage >= totalPages && totalPages > 0) {
      _currentPage = totalPages - 1;
    }
    if (_currentPage < 0) _currentPage = 0;
    final startIndex = _currentPage * _pageSize;
    final endIndex = startIndex + _pageSize > list.length
        ? list.length
        : startIndex + _pageSize;
    final pagedList = list.sublist(startIndex, endIndex);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Contenus du catalogue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              FilledButton.icon(
                onPressed: () => _showContentDialog(context, null),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter un contenu'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Barre de recherche
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Rechercher un contenu…',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 16),
          // Filtres
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _FilterChip(
                label: 'Jeu',
                value: _gameFilter == null
                    ? 'Tous'
                    : store.gameById(_gameFilter!)?.name ?? '—',
                items: store.games.map((g) => g.name).toList(),
                values: store.games.map((g) => g.id).toList(),
                selectedValue: _gameFilter,
                onChanged: (v) => setState(() => _gameFilter = v),
              ),
              _FilterChip(
                label: 'Catégorie',
                value: _catFilter == null
                    ? 'Toutes'
                    : _catFilter == 'media'
                        ? 'Vidéos & Guides'
                        : 'Liens',
                items: const ['Vidéos & Guides', 'Liens'],
                values: const ['media', 'links'],
                selectedValue: _catFilter,
                onChanged: (v) => setState(() => _catFilter = v),
              ),
              // Filtre langue multi-sélection (dialogue avec checkboxes).
              _LanguageFilterButton(
                label: _languageFilterLabel,
                hasSelection:
                    _activeLanguages.isNotEmpty || _showNoLanguage,
                onTap: _showLanguageFilterDialog,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ── Barre de pagination ──
          if (totalPages > 1) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.first_page_rounded),
                  onPressed: _currentPage > 0
                      ? () => setState(() => _currentPage = 0)
                      : null,
                  tooltip: 'Première page',
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: _currentPage > 0
                      ? () => setState(() => _currentPage--)
                      : null,
                  tooltip: 'Page précédente',
                ),
                const SizedBox(width: 8),
                Text(
                  'Page ${_currentPage + 1} / $totalPages'
                  ' (${startIndex + 1}-$endIndex sur ${list.length})',
                  style:
                      const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  onPressed: _currentPage < totalPages - 1
                      ? () => setState(() => _currentPage++)
                      : null,
                  tooltip: 'Page suivante',
                ),
                IconButton(
                  icon: const Icon(Icons.last_page_rounded),
                  onPressed: _currentPage < totalPages - 1
                      ? () => setState(() => _currentPage = totalPages - 1)
                      : null,
                  tooltip: 'Dernière page',
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          AdminDataTable(
            columns: const [
              'Titre',
              'Jeu',
              'Catégorie',
              'Publié le',
              'Ajouté le',
              'Langue',
              'Checked',
              'Actions'
            ],
            sortColumnIndex: _sortColumnIndex,
            sortAscending: _sortAscending,
            nonSortableColumns: const ['Actions'],
            onSort: (colIdx) {
              setState(() {
                if (_sortColumnIndex == colIdx) {
                  // Même colonne : on inverse le sens.
                  _sortAscending = !_sortAscending;
                } else {
                  _sortColumnIndex = colIdx;
                  _sortAscending = true;
                }
              });
            },
            rows: pagedList
                .map((c) => [
                      Text(c.displayTitle,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13)),
                      Text(store.gameById(c.gameId)?.name ?? '—',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      StatusBadge(
                          label: c.category.label, color: c.category.color),
                      Text(_formatDate(c.publishedAt),
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      // Date d'ajout dans la base (created_at).
                      Text(
                          c.createdAt != null
                              ? _formatDate(c.createdAt!)
                              : '—',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      // Badge de langue (drapeau + code + couleur sémantique).
                      LanguageBadge(
                        languageCode: c.videoLanguage,
                        size: BadgeSize.small,
                      ),
                      // Indicateur "Checked" (vert = vérifié, rouge = non vérifié).
                      Icon(
                        c.checkedAt != null
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 16,
                        color: c.checkedAt != null
                            ? Colors.green
                            : Colors.red,
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Modifier le titre et l\'URL',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _showContentDialog(context, c),
                          ),
                          IconButton(
                            tooltip: 'Ouvrir l\'URL',
                            icon: const Icon(Icons.open_in_new_rounded,
                                size: 18),
                            onPressed: () async {
                              final uri = Uri.parse(c.url);
                              if (await ul.canLaunchUrl(uri)) {
                                await ul.launchUrl(uri,
                                    mode: ul.LaunchMode
                                        .externalApplication);
                              }
                            },
                          ),
                          IconButton(
                            tooltip: 'Supprimer',
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 20),
                            color: AppColors.categoryVideo,
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => ConfirmDialog(
                                title: 'Supprimer ce contenu ?',
                                message:
                                    '« ${c.displayTitle} » sera retiré du catalogue.',
                                confirmLabel: 'Supprimer',
                                destructive: true,
                                onConfirm: () =>
                                    store.deleteContent(c.id),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ])
                .toList(),
          ),
        ],
      ),
    );
  }

  /// Applique le tri sur [list] en place, selon la colonne et le sens choisis.
  /// Si aucune colonne n'est sélectionnée (_sortColumnIndex == null),
  /// tri par défaut : publishedAt décroissant (plus récent en premier).
  void _applySort(List<Content> list, StoreController store) {
    if (_sortColumnIndex == null) {
      // Tri par défaut : publishedAt décroissant.
      list.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
      return;
    }

    int compare(Content a, Content b) {
      int cmp;
      switch (_sortColumnIndex) {
        case 0: // Titre
          cmp = a.displayTitle
              .toLowerCase()
              .compareTo(b.displayTitle.toLowerCase());
          break;
        case 1: // Jeu
          final nameA = store.gameById(a.gameId)?.name ?? '';
          final nameB = store.gameById(b.gameId)?.name ?? '';
          cmp = nameA.toLowerCase().compareTo(nameB.toLowerCase());
          break;
        case 2: // Catégorie
          cmp = a.category.label.compareTo(b.category.label);
          break;
        case 3: // Publié le (publishedAt = date YouTube)
          cmp = a.publishedAt.compareTo(b.publishedAt);
          break;
        case 4: // Ajouté le (createdAt = date d'ajout en base)
          final createdA = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final createdB = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          cmp = createdA.compareTo(createdB);
          break;
        case 5: // Langue (null remonte en premier en ascendant)
          final langA = a.videoLanguage?.toUpperCase() ?? '';
          final langB = b.videoLanguage?.toUpperCase() ?? '';
          cmp = langA.compareTo(langB);
          break;
        case 6: // Checked (vérifiés en premier en ascendant)
          final checkedA = a.checkedAt != null ? 1 : 0;
          final checkedB = b.checkedAt != null ? 1 : 0;
          cmp = checkedA.compareTo(checkedB);
          break;
        default:
          cmp = 0;
      }
      return _sortAscending ? cmp : -cmp;
    }

    list.sort(compare);
  }

  void _showContentDialog(BuildContext context, Content? existing) {
    showDialog<void>(
      context: context,
      builder: (_) => ContentEditDialog(content: existing),
    );
  }

  /// Vrai si [c] passe le filtre de langue courant (multi-sélection).
  ///
  /// Règles :
  /// - contenu sans langue → gardé seulement si [_showNoLanguage] est vrai ;
  /// - contenu avec langue → gardé si [_activeLanguages] est vide (= pas de
  ///   filtre actif sur les langues) ou si sa langue est dans l'ensemble.
  bool passesLanguageFilter(Content c) {
    final lang = c.videoLanguage?.toUpperCase();
    if (lang == null || lang.isEmpty) return _showNoLanguage;
    if (_activeLanguages.isEmpty) return true; // pas de filtre actif
    return _activeLanguages.contains(lang);
  }

  /// Ouvre un dialogue de multi-sélection des langues (12 entrées générées
  /// depuis [kSupportedLanguages] + 1 case « Sans langue »).
  Future<void> _showLanguageFilterDialog() async {
    // Copie de travail locale, appliquée à la fermeture.
    Set<String> tmpActive = Set<String>.of(_activeLanguages);
    bool tmpNoLang = _showNoLanguage;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              title: const Text('Filtrer par langue'),
              content: SizedBox(
                width: 340,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Les 12 langues supportées.
                      for (final lang in kSupportedLanguages)
                        CheckboxListTile(
                          dense: true,
                          value: tmpActive.contains(lang.code),
                          onChanged: (v) {
                            setStateDialog(() {
                              if (v == true) {
                                tmpActive.add(lang.code);
                              } else {
                                tmpActive.remove(lang.code);
                              }
                            });
                          },
                          title: Text('${lang.flag} ${lang.label} '
                              '(${lang.code})'),
                        ),
                      const Divider(height: 16),
                      // Cas « Sans langue ».
                      CheckboxListTile(
                        dense: true,
                        value: tmpNoLang,
                        onChanged: (v) {
                          setStateDialog(() => tmpNoLang = v ?? false);
                        },
                        title: const Text('🔇 Sans langue'),
                        subtitle: const Text(
                            'Contenus sans langue associée',
                            style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // Réinitialise le filtre.
                    setStateDialog(() {
                      tmpActive = <String>{};
                      tmpNoLang = false;
                    });
                  },
                  child: const Text('Tout réinitialiser'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Appliquer'),
                ),
              ],
            );
          },
        );
      },
    );

    // Applique la sélection à l'état du widget parent.
    setState(() {
      _activeLanguages = tmpActive;
      _showNoLanguage = tmpNoLang;
      _currentPage = 0; // reset pagination après changement de filtre.
    });
  }

  /// Libellé résumant l'état du filtre langue pour le chip.
  String get _languageFilterLabel {
    final hasLang = _activeLanguages.isNotEmpty;
    final hasNoLang = _showNoLanguage;
    if (!hasLang && !hasNoLang) return 'Toutes';
    // Construit le résumé : « FR, EN (+2) » si > 2 langues, + « +sans ».
    final codes = _activeLanguages.toList()..sort();
    final List<String> parts = <String>[];
    if (codes.length <= 2) {
      parts.addAll(codes);
    } else {
      parts
        ..addAll(codes.sublist(0, 2))
        ..add('+${codes.length - 2}');
    }
    if (hasNoLang) parts.add('∅');
    return parts.join(', ');
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Menu déroulant de filtre stylé.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.value,
    required this.items,
    required this.values,
    required this.selectedValue,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> items;
  final List<String> values;
  final String? selectedValue;
  final ValueChanged<String?> onChanged;

  /// Valeur sentinel représentant "Tous" (aucun filtre).
  /// ⚠️ On ne peut pas utiliser `null` comme valeur de PopupMenuItem car
  /// Flutter interprète `onSelected(null)` comme "pas de sélection" et ne
  /// déclenche pas le callback. On utilise donc une chaîne sentinel.
  static const String _allValue = '__all__';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label : ',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontWeight: FontWeight.w700)),
          PopupMenuButton<String>(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                const Icon(Icons.arrow_drop_down_rounded, size: 18),
              ],
            ),
            onSelected: (v) {
              // La valeur sentinel "__all__" est convertie en null (= pas de filtre).
              onChanged(v == _allValue ? null : v);
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                  value: _allValue, child: Text('Tous')),
              ...List.generate(items.length,
                  (i) => PopupMenuItem(value: values[i], child: Text(items[i]))),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bouton de filtre langue multi-sélection, visuellement cohérent avec
/// [_FilterChip] mais qui ouvre un dialogue (cases à cocher) au lieu d'un
/// popup mono-sélection.
class _LanguageFilterButton extends StatelessWidget {
  const _LanguageFilterButton({
    required this.label,
    required this.hasSelection,
    required this.onTap,
  });

  /// Texte résumant la sélection courante (ex: « Toutes », « FR, EN », « +2 »).
  final String label;

  /// Vrai si au moins une langue (ou « Sans langue ») est sélectionnée —
  /// met en évidence le chip visuellement.
  final bool hasSelection;

  /// Appelé au tap : ouvre le dialogue de multi-sélection.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).canvasColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hasSelection
                ? accent.withValues(alpha: 0.6)
                : Theme.of(context).dividerColor,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Langue : ',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                    fontWeight: FontWeight.w700)),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: hasSelection ? accent : null)),
            const Icon(Icons.tune_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}

/// Dialog d'ajout / édition d'un contenu.
class ContentEditDialog extends StatefulWidget {
  const ContentEditDialog({super.key, this.content});
  final Content? content;

  @override
  State<ContentEditDialog> createState() => _ContentEditDialogState();
}

class _ContentEditDialogState extends State<ContentEditDialog> {
  late final TextEditingController _url;
  late final TextEditingController _title;
  late final TextEditingController _image;
  String? _gameId;
  ContentCategory _category = ContentCategory.video;
  DateTime? _publishedAt;
  String? _videoLanguage;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.content?.url ?? '');
    _title = TextEditingController(
        text: widget.content?.titleAdmin ?? widget.content?.titleSource ?? '');
    _image = TextEditingController(text: widget.content?.imageUrl ?? '');
    _gameId = widget.content?.gameId;
    _category = widget.content?.category ?? ContentCategory.video;
    _publishedAt = widget.content?.publishedAt;
    _videoLanguage = widget.content?.videoLanguage;
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    _image.dispose();
    super.dispose();
  }

  void _save() {
    final StoreController store = context.read<StoreController>();
    final String url = _url.text.trim();
    if (url.isEmpty || _gameId == null) return;

    if (widget.content == null) {
      store.addContent(
        gameId: _gameId!,
        category: _category,
        url: url,
        titleAdmin: _title.text,
        imageUrl: _image.text,
      );
    } else {
      // Édition : met à jour le titre, l'URL, le jeu, la catégorie et la date.
      store.updateContent(
        widget.content!,
        titleAdmin: _title.text,
        url: url,
        category: _category,
        publishedAt: _publishedAt,
        gameId: _gameId,
        videoLanguage: _videoLanguage,
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final bool edit = widget.content != null;
    final List<Game> games = store.games;

    return AlertDialog(
      title: Text(edit
          ? 'Modifier le contenu'
          : 'Ajouter une vidéo / un guide / un lien'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (games.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Ajoutez d\'abord au moins un jeu.',
                  style: TextStyle(color: AppColors.categoryVideo, fontSize: 13),
                ),
              ),
            // En édition, on peut changer le titre, l'URL et la catégorie.
            if (edit) ...[
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Titre administrateur *',
                  helperText: 'C\'est ce titre que verront les utilisateurs.'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'URL *',
                  helperText: 'Lien YouTube (vidéo) ou page web'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ContentCategory>(
                value: _category,
                decoration: const InputDecoration(labelText: 'Catégorie'),
                items: ContentCategory.values
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Row(children: [
                            Icon(c.icon, size: 18, color: c.color),
                            const SizedBox(width: 8),
                            Text(c.label),
                          ]),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 12),
              // Champ date de création (modifiable manuellement).
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _publishedAt ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _publishedAt = picked);
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date de création',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                  ),
                  child: Text(
                    _publishedAt != null
                        ? '${_publishedAt!.day.toString().padLeft(2, '0')}/${_publishedAt!.month.toString().padLeft(2, '0')}/${_publishedAt!.year}'
                        : 'Non définie',
                    style: TextStyle(
                      fontSize: 14,
                      color: _publishedAt != null
                          ? null
                          : Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Jeu (modifiable en édition pour déplacer le contenu).
              DropdownButtonFormField<String>(
                value: _gameId,
                decoration: const InputDecoration(labelText: 'Jeu'),
                items: games
                    .map((g) => DropdownMenuItem(
                          value: g.id,
                          child: Text(g.name),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _gameId = v),
              ),
              const SizedBox(height: 12),
              // Langue de la vidéo (12 langues + Aucune).
              DropdownButtonFormField<String>(
                value: _videoLanguage,
                decoration: const InputDecoration(labelText: 'Langue vidéo'),
                items: [
                  // Option « Aucune » = null (langue non définie).
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('Aucune'),
                  ),
                  ...kSupportedLanguages.map(
                    (lang) => DropdownMenuItem<String>(
                      value: lang.code,
                      child: Text('${lang.flag} ${lang.label} (${lang.code})'),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _videoLanguage = v),
              ),
            ] else ...[
              DropdownButtonFormField<String>(
                value: _gameId,
                decoration: const InputDecoration(labelText: 'Jeu *'),
                items: games
                    .map((g) => DropdownMenuItem(
                          value: g.id,
                          child: Text(g.name),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _gameId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ContentCategory>(
                value: _category,
                decoration: const InputDecoration(labelText: 'Catégorie *'),
                items: ContentCategory.values
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Row(children: [
                            Icon(c.icon, size: 18, color: c.color),
                            const SizedBox(width: 8),
                            Text(c.label),
                          ]),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                    labelText: 'URL *',
                    helperText: 'Lien YouTube (vidéo) ou page web'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                    labelText: 'Titre administrateur *',
                    helperText: 'Titre affiché dans l\'app mobile'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _image,
                decoration: const InputDecoration(
                    labelText: 'URL image d\'aperçu (optionnel)',
                    helperText: 'Sinon, extraction auto pour YouTube'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(edit ? 'Enregistrer' : 'Ajouter'),
        ),
      ],
    );
  }
}
