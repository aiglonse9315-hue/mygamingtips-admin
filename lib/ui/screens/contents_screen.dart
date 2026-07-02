import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  ContentCategory? _catFilter; // null = toutes

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();

    List<Content> list = store.contents.where((c) => c.validated).toList()
      ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));

    if (_gameFilter != null) {
      list = list.where((c) => c.gameId == _gameFilter).toList();
    }
    if (_catFilter != null) {
      list = list.where((c) => c.category == _catFilter).toList();
    }

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
                    : _catFilter!.label,
                items: ContentCategory.values.map((c) => c.label).toList(),
                values: ContentCategory.values
                    .map((c) => c.name)
                    .toList(),
                selectedValue: _catFilter?.name,
                onChanged: (v) => setState(() =>
                    _catFilter = v == null
                        ? null
                        : ContentCategory.values
                            .firstWhere((c) => c.name == v)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdminDataTable(
            columns: const [
              'Titre',
              'Jeu',
              'Catégorie',
              'Date',
              'Actions'
            ],
            rows: list
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Modifier le titre',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _showContentDialog(context, c),
                          ),
                          IconButton(
                            tooltip: 'Ouvrir l\'URL',
                            icon: const Icon(Icons.open_in_new_rounded,
                                size: 18),
                            onPressed: () {},
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

  void _showContentDialog(BuildContext context, Content? existing) {
    showDialog<void>(
      context: context,
      builder: (_) => ContentEditDialog(content: existing),
    );
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Menu déroulant de filtre stylisé.
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
          PopupMenuButton<String?>(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                const Icon(Icons.arrow_drop_down_rounded, size: 18),
              ],
            ),
            onSelected: onChanged,
            itemBuilder: (_) => [
              const PopupMenuItem<String?>(value: null, child: Text('Tous')),
              ...List.generate(items.length,
                  (i) => PopupMenuItem(value: values[i], child: Text(items[i]))),
            ],
          ),
        ],
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

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.content?.url ?? '');
    _title = TextEditingController(
        text: widget.content?.titleAdmin ?? widget.content?.titleSource ?? '');
    _image = TextEditingController(text: widget.content?.imageUrl ?? '');
    _gameId = widget.content?.gameId;
    _category = widget.content?.category ?? ContentCategory.video;
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
      store.updateContentTitle(widget.content!, _title.text);
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
          ? 'Modifier le titre administrateur'
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
            // En édition, on ne change que le titre.
            if (edit) ...[
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Titre administrateur *',
                  helperText: 'C\'est ce titre que verront les utilisateurs.'),
                autofocus: true,
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
