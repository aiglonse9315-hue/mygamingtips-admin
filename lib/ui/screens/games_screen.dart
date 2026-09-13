import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/app_languages.dart';
import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/game.dart';
import '../../domain/models/game_alias.dart';
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

  /// Synchronisation des alias connus en cours (désactive le bouton).
  bool _aliasesSyncRunning = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Confirmation avant la synchronisation globale des alias connus
  /// (v72, passation §67). Sémantique documentée : AJOUT SEUL.
  Future<void> _confirmSyncKnownAliases(
      BuildContext context, StoreController store) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Synchroniser les alias connus ?'),
        content: const Text(
          'Pour chaque jeu du catalogue, les alias connus du panneau '
          '(acronymes, noms alternatifs — ex. « D4 » pour Diablo 4) '
          'manquants en base seront AJOUTÉS.\n\n'
          'Aucun alias existant n\'est supprimé : la synchronisation ne '
          'fait qu\'enrichir la base, qui alimente les bots Vision et '
          'Sentinelle (source de vérité).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Synchroniser'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runSyncKnownAliases(store);
  }

  /// Exécute la synchronisation puis affiche le rapport.
  Future<void> _runSyncKnownAliases(StoreController store) async {
    setState(() => _aliasesSyncRunning = true);
    final log = <String>[];
    try {
      final report = await store.syncKnownGameAliases(
        onProgress: (m) {
          log.add(m);
          if (mounted) setState(() {});
        },
      );
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Alias synchronisés'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${report.gamesPushed} jeu(x) mis à jour — '
                    '${report.aliasesAdded} alias ajouté(s).'),
                if (report.gamesUpToDate > 0)
                  Text('${report.gamesUpToDate} jeu(x) déjà à jour.'),
                if (report.orphanCanonicals.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Alias ignorés (jeu absent du catalogue) : '
                    '${report.orphanCanonicals.join(', ')}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(dialogContext).hintColor,
                    ),
                  ),
                ],
                if (log.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    log.take(50).join('\n'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Fermer'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Échec de la synchronisation'),
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Fermer'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _aliasesSyncRunning = false);
    }
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
              Row(
                children: [
                  Tooltip(
                    message:
                        'Pousse les alias connus (acronymes, noms alternatifs)\n'
                        'vers la base pour TOUS les jeux du catalogue.\n'
                        'Ajout seul — jamais de suppression ; la base est la\n'
                        'source qui alimente les bots (Vision/Sentinelle).',
                    child: OutlinedButton.icon(
                      onPressed: _aliasesSyncRunning
                          ? null
                          : () => _confirmSyncKnownAliases(context, store),
                      icon: _aliasesSyncRunning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_rounded),
                      label: const Text('Synchroniser alias connus'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _showGameDialog(context, null),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Ajouter un jeu'),
                  ),
                ],
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
                            tooltip: 'Traductions',
                            icon: const Icon(Icons.translate_rounded, size: 20),
                            onPressed: () => _showTranslationsDialog(context, g),
                          ),
                          IconButton(
                            tooltip: 'Alias',
                            icon: const Icon(Icons.alternate_email_rounded,
                                size: 20),
                            onPressed: () => _showAliasesDialog(context, g),
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

  void _showTranslationsDialog(BuildContext context, Game game) {
    showDialog<void>(
      context: context,
      builder: (_) => GameTranslationsDialog(game: game),
    );
  }

  void _showAliasesDialog(BuildContext context, Game game) {
    showDialog<void>(
      context: context,
      builder: (_) => GameAliasesDialog(game: game),
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration:
                        const InputDecoration(labelText: 'Nom du jeu *'),
                  ),
                ),
                // Bouton "+" : ouvre le dialog des traductions (12 langues).
                // Visible seulement en mode édition (un jeu existant a un ID).
                if (edit) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Traductions (12 langues)',
                    icon: const Icon(Icons.translate_rounded, size: 22),
                    onPressed: () {
                      // Construit un Game à jour avec le nom actuellement saisi
                      // (pour que le dialog affiche le bon nom par défaut).
                      final currentGame = widget.game!.copyWith(
                        name: _name.text.trim().isEmpty
                            ? widget.game!.name
                            : _name.text.trim(),
                      );
                      showDialog(
                        context: context,
                        builder: (_) =>
                            GameTranslationsDialog(game: currentGame),
                      );
                    },
                  ),
                ],
              ],
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

/// Dialog d'édition des traductions du titre d'un jeu (12 langues).
///
/// Charge les traductions existantes au démarrage (via la route
/// `games/translations-list`), pré-remplit les champs (ou le nom du jeu par
/// défaut si aucune traduction n'existe pour une langue), puis sauvegarde via
/// `games/translate` au clic sur "Sauvegarder".
///
/// Le dialog est scrollable (12 langues = grand). Les champs vides ne sont
/// pas envoyés au serveur (filtre côté caller).
class GameTranslationsDialog extends StatefulWidget {
  const GameTranslationsDialog({super.key, required this.game});
  final Game game;

  @override
  State<GameTranslationsDialog> createState() => _GameTranslationsDialogState();
}

class _GameTranslationsDialogState extends State<GameTranslationsDialog> {
  /// Un TextEditingController par langue (code majuscule).
  late final Map<String, TextEditingController> _controllers;

  /// État de chargement des traductions existantes.
  bool _loading = true;

  /// Message de statut après sauvegarde (succès ou erreur).
  String? _statusMessage;
  bool _statusError = false;

  /// Indique qu'une sauvegarde est en cours (désactive le bouton).
  bool _saving = false;

  /// Vrai si l'utilisateur a modifié au moins un champ (anti-fermeture accidentelle).
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // Initialise tous les contrôleurs vides (seront remplis après le fetch).
    _controllers = {
      for (final lang in kSupportedLanguages)
        lang.code: TextEditingController(),
    };
    _loadTranslations();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadTranslations() async {
    final StoreController store = context.read<StoreController>();
    try {
      final existing = await store.loadTranslationsForGame(widget.game.id);
      if (!mounted) return;
      // Pré-remplit chaque champ : traduction existante si présente, sinon le
      // nom du jeu par défaut (l'admin peut ainsi traduire rapidement sans
      // repartir de zéro, ou vider le champ s'il ne veut pas de traduction).
      for (final lang in kSupportedLanguages) {
        final value = existing[lang.code] ?? widget.game.name;
        _controllers[lang.code]!.text = value;
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      // En cas d'échec (non auth), on pré-remplit quand même avec le nom du
      // jeu pour ne pas bloquer l'édition.
      for (final lang in kSupportedLanguages) {
        _controllers[lang.code]!.text = widget.game.name;
      }
      setState(() {
        _loading = false;
        _statusMessage = 'Traductions existantes indisponibles : $e';
        _statusError = true;
      });
    }
  }

  Future<void> _save() async {
    // Filtre les valeurs non vides (on ne persiste pas les titres vides).
    final Map<String, String> translations = {};
    for (final entry in _controllers.entries) {
      final value = entry.value.text.trim();
      if (value.isNotEmpty) {
        translations[entry.key] = value;
      }
    }
    setState(() {
      _saving = true;
      _statusMessage = null;
    });
    final StoreController store = context.read<StoreController>();
    final ok =
        await store.updateGameTranslations(widget.game, translations);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _statusMessage = ok
          ? 'Traductions enregistrées (${translations.length}).'
          : (store.lastActionError ?? 'Erreur lors de l\'enregistrement.');
      _statusError = !ok;
    });
    // Ferme le dialog automatiquement après une sauvegarde réussie.
    if (ok && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Empêche la fermeture accidentelle (Échap / clic hors dialog) si
      // l'utilisateur a modifié des champs sans sauvegarder.
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _dirty && !_saving) {
          // Affiche une confirmation avant de fermer.
          _confirmDiscardChanges();
        }
      },
      child: AlertDialog(
        title: Row(
          children: [
            Text('Traductions — ${widget.game.name}'),
            const Spacer(),
            // Bouton de fermeture explicite (X) — sauvegarde puis ferme.
            IconButton(
              tooltip: 'Sauvegarder et fermer',
              icon: const Icon(Icons.check_circle_outline, size: 24),
              onPressed: _loading || _saving ? null : _save,
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          // Hauteur bornée pour forcer le scroll interne (12 langues = grand).
          height: MediaQuery.of(context).size.height * 0.7,
          child: _loading
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Chargement des traductions…'),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final lang in kSupportedLanguages) ...[
                        TextField(
                          controller: _controllers[lang.code],
                          decoration: InputDecoration(
                            labelText:
                                '${lang.flag} ${lang.code} — ${lang.label}',
                            isDense: true,
                          ),
                          onChanged: (_) {
                            if (!_dirty) setState(() => _dirty = true);
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (_statusMessage != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _statusMessage!,
                          style: TextStyle(
                            fontSize: 12,
                            color: _statusError
                                ? AppColors.categoryVideo
                                : AppColors.neonGreen,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () {
                    // Annuler : si modifs non sauvegardées, confirme.
                    if (_dirty) {
                      _confirmDiscardChanges();
                    } else {
                      Navigator.pop(context);
                    }
                  },
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded, size: 18),
            label: const Text('Sauvegarder'),
          ),
        ],
      ),
    );
  }

  /// Demande confirmation avant de fermer le dialog avec des changements
  /// non sauvegardés. Évite de perdre les modifications accidentellement
  /// (Échap, clic "Annuler", clic hors dialog).
  void _confirmDiscardChanges() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modifications non sauvegardées'),
        content: const Text(
            'Vous avez modifié des traductions sans sauvegarder.\n'
            'Voulez-vous vraiment fermer ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx); // Ferme la confirmation.
              Navigator.pop(context); // Ferme le dialog de traductions.
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.categoryVideo,
            ),
            child: const Text('Fermer sans sauvegarder'),
          ),
        ],
      ),
    );
  }
}


/// Dialog d'édition des alias d'un jeu (table `game_aliases`).
///
/// Les alias (noms raccourcis, acronymes, noms communautaires — ex. « D4 »
/// pour Diablo 4) servent au matching des titres YouTube par Vision et
/// Sentinelle. À l'ouverture, les alias existants sont chargés via la route
/// EF `games/aliases/list` ; le bouton « Importer les alias connus » ajoute
/// EN MÉMOIRE les alias en dur du panneau ([StoreController.knownAliasesFor])
/// correspondant à ce jeu (pas de sauvegarde automatique). La sauvegarde
/// REMPLACE toute la liste côté serveur (`games/aliases/set`), avec la forme
/// normalisée calculée par [StoreController.normalizeGameAlias] — strictement
/// identique au matching des bots.
class GameAliasesDialog extends StatefulWidget {
  const GameAliasesDialog({super.key, required this.game});
  final Game game;

  @override
  State<GameAliasesDialog> createState() => _GameAliasesDialogState();
}

class _GameAliasesDialogState extends State<GameAliasesDialog> {
  /// Alias en mémoire, tels que saisis (la normalisation est calculée à la
  /// sauvegarde).
  List<String> _aliases = <String>[];

  final TextEditingController _addCtrl = TextEditingController();

  /// État de chargement des alias existants.
  bool _loading = true;

  /// Indique qu'une sauvegarde est en cours (désactive le bouton).
  bool _saving = false;

  /// Vrai si la liste a été modifiée sans sauvegarde (anti-fermeture).
  bool _dirty = false;

  /// Message de statut (succès, erreur ou information).
  String? _statusMessage;
  bool _statusError = false;

  /// Alias connus en dur importables pour ce jeu (calculé une fois — la map
  /// [_gameAliases] du StoreController est constante).
  late final List<String> _knownImportable =
      StoreController.knownAliasesFor(widget.game.name);

  @override
  void initState() {
    super.initState();
    _loadAliases();
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAliases() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() {
        _loading = false;
        _statusMessage = 'Mode aperçu : alias non disponibles.';
        _statusError = true;
      });
      return;
    }
    try {
      final List<GameAlias> existing =
          await sync.fetchGameAliases(widget.game.id);
      if (!mounted) return;
      setState(() {
        _aliases = [for (final a in existing) a.alias];
        _loading = false;
      });
    } on AdminAuthException {
      // 401 : session expirée → logout forcé (même règle que les écritures).
      if (!mounted) return;
      Navigator.pop(context);
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusMessage = 'Alias existants indisponibles : $e';
        _statusError = true;
      });
    }
  }

  /// Extrait un message d'erreur lisible : retire le préfixe « Exception: »
  /// produit par le `toString()` des exceptions Dart.
  static String _errorMessage(Object e) {
    const prefix = 'Exception: ';
    final String msg = e.toString();
    return msg.startsWith(prefix) ? msg.substring(prefix.length) : msg;
  }

  /// Formes normalisées déjà présentes (déduplication à l'ajout/import).
  Set<String> get _existingNorms =>
      _aliases.map(StoreController.normalizeGameAlias).toSet();

  /// Ajoute un alias saisi à la liste en mémoire (dédupliqué sur la forme
  /// normalisée).
  void _addAlias(String raw) {
    final String alias = raw.trim();
    if (alias.isEmpty) return;
    final String norm = StoreController.normalizeGameAlias(alias);
    if (norm.isEmpty) {
      setState(() {
        _statusMessage = '« $alias » est inexploitable après normalisation.';
        _statusError = true;
      });
      return;
    }
    if (_existingNorms.contains(norm)) {
      setState(() {
        _statusMessage = '« $alias » existe déjà (forme normalisée : $norm).';
        _statusError = true;
      });
      return;
    }
    setState(() {
      _aliases = [..._aliases, alias];
      _dirty = true;
      _statusMessage = null;
    });
    _addCtrl.clear();
  }

  /// Ajoute en mémoire les alias en dur connus pour ce jeu (pas de
  /// sauvegarde automatique — l'admin valide avec « Sauvegarder »).
  void _importKnownAliases() {
    final Set<String> norms = _existingNorms;
    final List<String> toAdd = [
      for (final alias in _knownImportable)
        if (!norms.contains(StoreController.normalizeGameAlias(alias))) alias,
    ];
    if (toAdd.isEmpty) {
      setState(() {
        _statusMessage = 'Tous les alias connus sont déjà dans la liste.';
        _statusError = false;
      });
      return;
    }
    setState(() {
      _aliases = [..._aliases, ...toAdd];
      _dirty = true;
      _statusMessage =
          '${toAdd.length} alias importé(s) — pensez à sauvegarder.';
      _statusError = false;
    });
  }

  void _removeAlias(String alias) {
    setState(() {
      _aliases = _aliases.where((a) => a != alias).toList();
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final StoreController store = context.read<StoreController>();
    final sync = store.sync;
    if (sync == null) {
      setState(() {
        _statusMessage = 'Mode aperçu : alias non persistés.';
        _statusError = true;
      });
      return;
    }
    // Déduplication finale sur la forme normalisée (première occurrence
    // conservée) + calcul de `alias_norm` avec le normaliseur du panneau
    // (identique à GameMatcher.normalize côté bots).
    final Set<String> seen = <String>{};
    final List<Map<String, String>> payload = [
      for (final alias in _aliases)
        if (alias.trim().isNotEmpty &&
            seen.add(StoreController.normalizeGameAlias(alias)))
          {
            'alias': alias.trim(),
            'alias_norm': StoreController.normalizeGameAlias(alias),
          },
    ];
    setState(() {
      _saving = true;
      _statusMessage = null;
    });
    try {
      final int count = await sync.setGameAliases(widget.game.id, payload);
      if (!mounted) return;
      // Ferme le dialog automatiquement après une sauvegarde réussie.
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('Alias enregistrés ($count) pour ${widget.game.name}.'),
          duration: const Duration(seconds: 4),
        ),
      );
    } on AdminAuthException {
      if (!mounted) return;
      Navigator.pop(context);
      store.onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _statusMessage = _errorMessage(e);
        _statusError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Alias connus en dur pas encore dans la liste (compteur du bouton
    // d'import).
    final int knownRemaining = _knownImportable
        .where((a) =>
            !_existingNorms.contains(StoreController.normalizeGameAlias(a)))
        .length;

    return PopScope(
      // Empêche la fermeture accidentelle (Échap / clic hors dialog) si
      // la liste a été modifiée sans sauvegarde.
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _dirty && !_saving) {
          _confirmDiscardChanges();
        }
      },
      child: AlertDialog(
        title: Text('Alias — ${widget.game.name}'),
        content: SizedBox(
          width: 480,
          // Hauteur bornée pour forcer le scroll interne si beaucoup d'alias.
          height: MediaQuery.of(context).size.height * 0.6,
          child: _loading
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Chargement des alias…'),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Texte d'aide.
                      Text(
                        'Noms raccourcis, acronymes, noms communautaires. '
                        'Les alias normalisés servent au matching des titres '
                        'par Vision/Sentinelle.',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Champ d'ajout + bouton « + ».
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _addCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Nouvel alias',
                                hintText: 'Ex. D4, BotW, Star Citizen…',
                                isDense: true,
                              ),
                              onSubmitted: _saving ? null : _addAlias,
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Ajouter',
                            icon: const Icon(
                                Icons.add_circle_outline_rounded),
                            onPressed: _saving
                                ? null
                                : () => _addAlias(_addCtrl.text),
                          ),
                        ],
                      ),
                      // Bouton d'import des alias en dur connus.
                      if (_knownImportable.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        TextButton.icon(
                          onPressed: _saving || knownRemaining == 0
                              ? null
                              : _importKnownAliases,
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(
                            'Importer les alias connus ($knownRemaining)',
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      // Compteur.
                      Text(
                        '${_aliases.length} alias',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Liste des alias en chips avec suppression.
                      if (_aliases.isEmpty)
                        Text(
                          'Aucun alias pour ce jeu.',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final alias in _aliases)
                              Tooltip(
                                message:
                                    'Forme normalisée : ${StoreController.normalizeGameAlias(alias)}',
                                child: InputChip(
                                  label: Text(alias),
                                  onDeleted: _saving
                                      ? null
                                      : () => _removeAlias(alias),
                                ),
                              ),
                          ],
                        ),
                      if (_statusMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _statusMessage!,
                          style: TextStyle(
                            fontSize: 12,
                            color: _statusError
                                ? AppColors.categoryVideo
                                : AppColors.neonGreen,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () {
                    // Annuler : si modifs non sauvegardées, confirme.
                    if (_dirty) {
                      _confirmDiscardChanges();
                    } else {
                      Navigator.pop(context);
                    }
                  },
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded, size: 18),
            label: const Text('Sauvegarder'),
          ),
        ],
      ),
    );
  }

  /// Demande confirmation avant de fermer le dialog avec des changements
  /// non sauvegardés. Évite de perdre les modifications accidentellement
  /// (Échap, clic "Annuler", clic hors dialog).
  void _confirmDiscardChanges() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modifications non sauvegardées'),
        content: const Text(
            'Vous avez modifié la liste des alias sans sauvegarder.\n'
            'Voulez-vous vraiment fermer ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx); // Ferme la confirmation.
              Navigator.pop(context); // Ferme le dialog d'alias.
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.categoryVideo,
            ),
            child: const Text('Fermer sans sauvegarder'),
          ),
        ],
      ),
    );
  }
}
