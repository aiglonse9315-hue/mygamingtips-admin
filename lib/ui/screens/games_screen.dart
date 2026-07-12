import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/game.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';

/// Gestion des jeux : liste + ajout + activation + suppression + recherche.
class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key});

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();

  // ── Pagination ──
  int _currentPage = 0;
  static const int _pageSize = 200;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();

    // Filtre par recherche (nom ou éditeur) — sur l'ensemble des jeux.
    List<Game> games = store.games;
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      games = games
          .where((g) =>
              g.name.toLowerCase().contains(q) ||
              (g.publisher?.toLowerCase().contains(q) ?? false))
          .toList();
    }

    // ── Pagination locale : découpe la liste filtrée en pages de 200 ──
    final totalPages = (games.length / _pageSize).ceil();
    if (_currentPage >= totalPages && totalPages > 0) {
      _currentPage = totalPages - 1;
    }
    if (_currentPage < 0) _currentPage = 0;
    final startIndex = _currentPage * _pageSize;
    final endIndex = startIndex + _pageSize > games.length
        ? games.length
        : startIndex + _pageSize;
    final pagedGames = games.sublist(startIndex, endIndex);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Jeux du catalogue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              FilledButton.icon(
                onPressed: () => _showGameDialog(context, null),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter un jeu'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Barre de recherche (identique au menu Contenus).
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Rechercher un jeu…',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
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
                  ' (${startIndex + 1}-$endIndex sur ${games.length})',
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
            columns: const ['Jeu', 'Éditeur', 'Contenus', 'Statut', 'Actions'],
            rows: pagedGames
                .map((g) => [
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 32,
                              height: 42,
                              child: g.coverUrl == null
                                  ? Container(
                                      color: AppColors.darkSurfaceAlt,
                                      child: const Icon(
                                          Icons.sports_esports_rounded,
                                          size: 18,
                                          color: Colors.white54),
                                    )
                                  : Image.network(g.coverUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                            color: AppColors.darkSurfaceAlt,
                                          )),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(g.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 13)),
                          ),
                        ],
                      ),
                      Text(g.publisher ?? '—',
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      Text('${store.contentCountFor(g.id)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13)),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: g.active
                                  ? AppColors.neonGreen
                                  : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(g.active ? 'Actif' : 'Inactif',
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: g.active
                                ? 'Désactiver'
                                : 'Activer',
                            icon: Icon(
                              g.active
                                  ? Icons.toggle_on_rounded
                                  : Icons.toggle_off_outlined,
                              color: g.active
                                  ? AppColors.neonGreen
                                  : null,
                            ),
                            onPressed: () =>
                                store.toggleGameActive(g),
                          ),
                          IconButton(
                            tooltip: 'Modifier',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _showGameDialog(context, g),
                          ),
                          IconButton(
                            tooltip: 'Supprimer',
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 20),
                            color: AppColors.categoryVideo,
                            onPressed: () => _confirmDelete(context, g),
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

  void _showGameDialog(BuildContext context, Game? existing) {
    showDialog<void>(
      context: context,
      builder: (_) => GameEditDialog(game: existing),
    );
  }

  void _confirmDelete(BuildContext context, Game game) {
    showDialog<void>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: 'Supprimer ${game.name} ?',
        message:
            'Le jeu et tous ses contenus (${context.read<StoreController>().contentCountFor(game.id)}) seront supprimés.',
        confirmLabel: 'Supprimer',
        destructive: true,
        onConfirm: () => context.read<StoreController>().deleteGame(game.id),
      ),
    );
  }
}

/// Dialog d'ajout / édition d'un jeu.
class GameEditDialog extends StatefulWidget {
  const GameEditDialog({super.key, this.game});
  final Game? game;

  @override
  State<GameEditDialog> createState() => _GameEditDialogState();
}

class _GameEditDialogState extends State<GameEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _publisher;
  late final TextEditingController _cover;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.game?.name ?? '');
    _publisher = TextEditingController(text: widget.game?.publisher ?? '');
    _cover = TextEditingController(text: widget.game?.coverUrl ?? '');
    _active = widget.game?.active ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _publisher.dispose();
    _cover.dispose();
    super.dispose();
  }

  void _save() {
    final StoreController store = context.read<StoreController>();
    final String name = _name.text.trim();
    if (name.isEmpty) return;
    if (widget.game == null) {
      store.addGame(
        name: name,
        publisher: _publisher.text,
        coverUrl: _cover.text,
        active: _active,
      );
    } else {
      store.updateGame(widget.game!.copyWith(
        name: name,
        publisher: () => _publisher.text.trim(),
        coverUrl: () => _cover.text.trim(),
        active: _active,
      ));
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bool edit = widget.game != null;
    return AlertDialog(
      title: Text(edit ? 'Modifier le jeu' : 'Ajouter un jeu'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nom du jeu *'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _publisher,
              decoration:
                  const InputDecoration(labelText: 'Éditeur (optionnel)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cover,
              decoration: const InputDecoration(
                  labelText: 'URL de la pochette (optionnel)',
                  helperText: 'Lien direct vers l\'image'),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Jeu actif (visible dans l\'app)'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              activeColor: Theme.of(context).colorScheme.primary,
            ),
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
