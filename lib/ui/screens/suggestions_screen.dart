import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../core/theme/colors.dart';
import '../../domain/models/category.dart';
import '../../domain/models/game.dart';
import '../../domain/models/suggestion.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/stat_card.dart' show StatusBadge;

/// Modération des suggestions : triées par date de partage, valider / refuser.
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({super.key});

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  SuggestionStatus? _statusFilter; // null = toutes
  int _currentPage = 0;
  static const int _pageSize = 500;

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();

    List<Suggestion> list = store.suggestionsByDate;
    if (_statusFilter != null) {
      list = list.where((s) => s.status == _statusFilter).toList();
    }

    // Pagination locale : découpe la liste filtrée en pages de 500.
    final totalPages = (list.length / _pageSize).ceil();
    if (_currentPage >= totalPages && totalPages > 0) _currentPage = totalPages - 1;
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
                'Suggestions utilisateurs',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              if (store.pendingSuggestionsCount > 0)
                StatusBadge(
                  label: '${store.pendingSuggestionsCount} en attente',
                  color: AppColors.plusGold,
                ),
              const SizedBox(width: 8),
              StatusBadge(
                label: '${store.suggestions.length} total',
                color: Colors.grey,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Classées par date de partage (du plus récent au plus ancien).',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color),
          ),
          const SizedBox(height: 16),
          // Filtre statut
          Wrap(
            spacing: 8,
            children: [
              _StatusTab(
                  label: 'Toutes (${store.suggestions.length})',
                  selected: _statusFilter == null,
                  color: AppColors.neonCyan,
                  onTap: () => setState(() => _statusFilter = null)),
              _StatusTab(
                  label:
                      'En attente (${store.pendingSuggestionsCount})',
                  selected: _statusFilter == SuggestionStatus.pending,
                  color: AppColors.plusGold,
                  onTap: () => setState(() =>
                      _statusFilter = SuggestionStatus.pending)),
              _StatusTab(
                  label:
                      'Acceptées (${store.suggestions.where((s) => s.status == SuggestionStatus.accepted).length})',
                  selected: _statusFilter == SuggestionStatus.accepted,
                  color: AppColors.neonGreen,
                  onTap: () => setState(() =>
                      _statusFilter = SuggestionStatus.accepted)),
              _StatusTab(
                  label:
                      'Refusées (${store.suggestions.where((s) => s.status == SuggestionStatus.rejected).length})',
                  selected: _statusFilter == SuggestionStatus.rejected,
                  color: AppColors.categoryVideo,
                  onTap: () => setState(() =>
                      _statusFilter = SuggestionStatus.rejected)),
            ],
          ),
          const SizedBox(height: 16),
          // Barre de pagination.
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
                  ' (${startIndex + 1}-${endIndex} sur ${list.length})',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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
              'URL',
              'Auteur',
              'Message',
              'Créé le',
              'Statut',
              'IA',
              'Actions'
            ],
            rows: pagedList
                .map((s) => [
                      InkWell(
                        onTap: () => ul.launchUrl(Uri.parse(s.url),
                            mode: ul.LaunchMode.externalApplication),
                        child: Text(s.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.neonCyan,
                                decoration: TextDecoration.underline)),
                      ),
                      // Colonne Auteur : avatar + pseudo + id + badge banni.
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor:
                                AppColors.neonViolet.withValues(alpha: 0.2),
                            child: Text(
                              s.author.displayName.isNotEmpty
                                  ? s.author.displayName[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.neonViolet),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(s.author.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700)),
                                    ),
                                    if (store.isAuthorBanned(s.author.id)) ...[
                                      const SizedBox(width: 5),
                                      StatusBadge(
                                          label: 'BANNI',
                                          color: AppColors.categoryVideo),
                                    ],
                                    if (store.isPlusUser(s.author.id)) ...[
                                      const SizedBox(width: 5),
                                      StatusBadge(
                                          label: 'PLUS',
                                          color: AppColors.plus),
                                    ],
                                  ],
                                ),
                                Text(s.author.id,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.color)),
                                // Bouton pour ajouter en Plus directement.
                                if (!store.isPlusUser(s.author.id) &&
                                    !store.isAuthorBanned(s.author.id))
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: SizedBox(
                                      height: 26,
                                      child: FilledButton.icon(
                                        onPressed: () => showDialog<void>(
                                          context: context,
                                          builder: (_) => AlertDialog(
                                            title: const Text(
                                                'Ajouter en membre Plus ?'),
                                            content: Text(
                                              'Activer l\'abonnement Plus pour '
                                              '${s.author.displayName} '
                                              '(${s.author.id.substring(0, 8)}…) ?',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(context),
                                                child: const Text('Annuler'),
                                              ),
                                              FilledButton(
                                                onPressed: () {
                                                  store.addPlusByUserId(
                                                    userId: s.author.id,
                                                    displayName:
                                                        s.author.displayName,
                                                  );
                                                  Navigator.pop(context);
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                          '${s.author.displayName} est maintenant membre Plus ✨'),
                                                      backgroundColor:
                                                          AppColors.plus,
                                                    ),
                                                  );
                                                },
                                                child: const Text('Activer Plus'),
                                              ),
                                            ],
                                          ),
                                        ),
                                        icon: const Icon(
                                            Icons.bolt_rounded,
                                            size: 14),
                                        label: const Text('Plus',
                                            style: TextStyle(fontSize: 11)),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: AppColors.plus,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                          textStyle: const TextStyle(
                                              fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Text(s.sharedText ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      // Affiche la date de création YouTube si disponible,
                      // sinon la date de partage.
                      Text(
                          _formatDate(s.aiRecommendation?.youtubePublishedAt ??
                              s.sharedAt),
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      StatusBadge(
                          label: s.status.label,
                          color: _statusColor(s.status)),
                      _AiBadge(recommendation: s.aiRecommendation),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (s.status == SuggestionStatus.pending) ...[
                            TextButton.icon(
                              onPressed: () => _showReview(context, s),
                              icon: const Icon(Icons.check_circle_outline_rounded,
                                  size: 18),
                              label: const Text('Valider'),
                            ),
                            IconButton(
                              tooltip: 'Refuser',
                              icon: const Icon(
                                  Icons.cancel_outlined,
                                  size: 20),
                              color: AppColors.categoryVideo,
                              onPressed: () => showDialog<void>(
                                context: context,
                                builder: (_) => ConfirmDialog(
                                  title: 'Refuser cette suggestion ?',
                                  message: s.url,
                                  confirmLabel: 'Refuser',
                                  destructive: true,
                                  onConfirm: () =>
                                      store.rejectSuggestion(s),
                                ),
                              ),
                            ),
                          ],
                          // Modération du compte : bannir / débannir l'auteur.
                          if (store.isAuthorBanned(s.author.id))
                            IconButton(
                              tooltip: 'Débannir le compte',
                              icon: const Icon(Icons.lock_open_rounded,
                                  size: 20),
                              color: AppColors.neonGreen,
                              onPressed: () => store.unban(s.author.id),
                            )
                          else
                            IconButton(
                              tooltip: 'Bannir le compte',
                              icon: const Icon(Icons.block_rounded, size: 20),
                              color: AppColors.categoryVideo,
                              onPressed: () => showDialog<void>(
                                context: context,
                                builder: (_) => ConfirmDialog(
                                  title:
                                      'Bannir ${s.author.displayName} ?',
                                  message:
                                      'Le compte Google identifié (${s.author.id}) '
                                      'sera banni. Il ne pourra plus soumettre de '
                                      'suggestions.',
                                  confirmLabel: 'Bannir',
                                  destructive: true,
                                  onConfirm: () => store.banAuthor(s),
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

  void _showReview(BuildContext context, Suggestion suggestion) {
    showDialog<void>(
      context: context,
      builder: (_) => SuggestionReviewDialog(suggestion: suggestion),
    );
  }

  static Color _statusColor(SuggestionStatus s) {
    switch (s) {
      case SuggestionStatus.pending:
        return AppColors.plusGold;
      case SuggestionStatus.accepted:
        return AppColors.neonGreen;
      case SuggestionStatus.rejected:
        return AppColors.categoryVideo;
    }
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}h${d.minute.toString().padLeft(2, '0')}';
}

class _StatusTab extends StatelessWidget {
  const _StatusTab({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? color : Theme.of(context).dividerColor),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? color : null)),
      ),
    );
  }
}

/// Dialog de validation d'une suggestion : choix du jeu + catégorie + titre admin.
class SuggestionReviewDialog extends StatefulWidget {
  const SuggestionReviewDialog({super.key, required this.suggestion});
  final Suggestion suggestion;

  @override
  State<SuggestionReviewDialog> createState() =>
      _SuggestionReviewDialogState();
}

class _SuggestionReviewDialogState extends State<SuggestionReviewDialog> {
  String? _gameId;
  ContentCategory _category = ContentCategory.video;
  late final TextEditingController _title;
  late final TextEditingController _image;

  @override
  void initState() {
    super.initState();
    // Pré-remplissage intelligent du titre (par ordre de priorité) :
    // 1. Titre réel YouTube (récupéré par Sentinelle via l'API YouTube).
    // 2. Texte partagé nettoyé (sans URL).
    // 3. URL brute.
    final ai = widget.suggestion.aiRecommendation;
    String title = widget.suggestion.url;
    if (ai != null && ai.youtubeTitle != null && ai.youtubeTitle!.trim().isNotEmpty) {
      title = ai.youtubeTitle!.trim();
    } else {
      final sharedText = widget.suggestion.sharedText;
      if (sharedText != null && sharedText.trim().isNotEmpty) {
        final cleaned =
            sharedText.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
        title = cleaned.isEmpty ? sharedText : cleaned;
      }
    }
    _title = TextEditingController(text: title);
    _image = TextEditingController();

    // Auto-remplissage de la catégorie depuis la recommandation IA.
    if (ai != null && ai.suggestedCategory != null) {
      final cat = ContentCategory.values.firstWhere(
        (e) => e.name == ai.suggestedCategory,
        orElse: () => ContentCategory.video,
      );
      _category = cat;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _image.dispose();
    super.dispose();
  }

  void _validate() {
    final StoreController store = context.read<StoreController>();
    if (_gameId == null || _title.text.trim().isEmpty) return;
    store.acceptSuggestion(
      suggestion: widget.suggestion,
      gameId: _gameId!,
      category: _category,
      titleAdmin: _title.text,
      imageUrl: _image.text,
    );
    Navigator.pop(context);
  }

  /// Ouvre un mini-dialog pour créer un jeu rapidement sans quitter le
  /// dialogue de validation. Une fois créé, le jeu est automatiquement
  /// sélectionné comme jeu cible.
  void _quickCreateGame() {
    final nameCtrl = TextEditingController();
    final publisherCtrl = TextEditingController();
    final coverCtrl = TextEditingController();

    // Pré-remplit le nom avec le jeu suggéré par l'IA si disponible.
    final ai = widget.suggestion.aiRecommendation;
    if (ai != null && ai.suggestedGame != null) {
      nameCtrl.text = ai.suggestedGame!;
    }

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Créer un jeu'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nom du jeu *',
                  hintText: 'ex. Fortnite',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: publisherCtrl,
                decoration: const InputDecoration(
                  labelText: 'Éditeur (optionnel)',
                  hintText: 'ex. Epic Games',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: coverCtrl,
                decoration: const InputDecoration(
                  labelText: 'URL image de couverture (optionnel)',
                  hintText: 'https://...',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Créer et sélectionner'),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final store = context.read<StoreController>();
              Navigator.pop(dialogCtx); // ferme le mini-dialog
              // Crée le jeu (await pour récupérer le vrai UUID).
              await store.addGame(
                name: name,
                publisher: publisherCtrl.text.trim().isEmpty
                    ? null
                    : publisherCtrl.text.trim(),
                coverUrl: coverCtrl.text.trim().isEmpty
                    ? null
                    : coverCtrl.text.trim(),
              );
              // Sélectionne automatiquement le jeu fraîchement créé.
              // addGame l'ajoute en fin de liste, on le retrouve par son nom.
              final created = store.games.firstWhere(
                (g) => g.name.toLowerCase() == name.toLowerCase(),
                orElse: () => store.games.last,
              );
              setState(() => _gameId = created.id);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final List<Game> games = store.games;
    final bool isVideo = widget.suggestion.url.contains('youtube') ||
        widget.suggestion.url.contains('youtu.be');

    // Auto-sélection du jeu depuis la recommandation IA (si pas déjà choisi).
    if (_gameId == null) {
      final ai = widget.suggestion.aiRecommendation;
      if (ai != null && ai.suggestedGame != null) {
        final match = games.firstWhere(
          (g) => g.name.toLowerCase() == ai.suggestedGame!.toLowerCase(),
          orElse: () => games.firstWhere(
            (g) =>
                g.name.toLowerCase().contains(ai.suggestedGame!.toLowerCase()),
            orElse: () => games.first,
          ),
        );
        if (games.isNotEmpty) _gameId = match.id;
      }
    }

    return AlertDialog(
      title: const Text('Valider la suggestion'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Aperçu de l'URL source
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: AppColors.neonCyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.neonCyan.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(isVideo ? Icons.smart_display_rounded : Icons.link_rounded,
                      size: 18, color: AppColors.neonCyan),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.suggestion.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (games.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Ajoutez d\'abord un jeu pour pouvoir valider.',
                  style: TextStyle(color: AppColors.categoryVideo, fontSize: 13),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _gameId,
                    decoration: const InputDecoration(labelText: 'Jeu cible *'),
                    items: games
                        .map((g) =>
                            DropdownMenuItem(value: g.id, child: Text(g.name)))
                        .toList(),
                    onChanged: (v) => setState(() => _gameId = v),
                  ),
                ),
                const SizedBox(width: 8),
                // Bouton "+" pour créer un jeu rapidement sans quitter le dialog.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: IconButton.filled(
                    tooltip: 'Créer un nouveau jeu',
                    onPressed: () => _quickCreateGame(),
                    icon: const Icon(Icons.add_rounded, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ContentCategory>(
              initialValue: _category,
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
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Titre administrateur *',
                helperText: 'Titre affiché dans l\'app mobile.'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _image,
              decoration: const InputDecoration(
                  labelText: 'URL image d\'aperçu (optionnel)',
                  helperText: 'Sinon, extraction auto pour YouTube'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: _validate,
          icon: const Icon(Icons.check_rounded),
          label: const Text('Valider et ajouter'),
        ),
      ],
    );
  }
}

/// Badge affichant la recommandation de l'IA Sentinelle sur une suggestion.
///
/// Couleurs selon le verdict :
/// - 🟢 recommended (vert) — "Recommandé"
/// - 🟡 caution (orange) — "À vérifier"
/// - 🔴 reject (rouge) — "Risqué"
///
/// Au survol (tooltip), affiche la raison détaillée + vues YouTube.
class _AiBadge extends StatelessWidget {
  const _AiBadge({required this.recommendation});

  final AiRecommendation? recommendation;

  @override
  Widget build(BuildContext context) {
    if (recommendation == null) {
      // Pas encore analysée par l'IA.
      return const Tooltip(
        message: 'Pas encore analysée par l\'IA',
        child: Text('—', style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }

    final rec = recommendation!;
    final (color, icon) = switch (rec.verdict) {
      AiVerdict.recommended => (AppColors.neonGreen, Icons.check_circle_rounded),
      AiVerdict.caution => (const Color(0xFFFFC93C), Icons.warning_rounded),
      AiVerdict.reject => (AppColors.categoryVideo, Icons.dangerous_rounded),
    };

    // Tooltip avec raison + vues.
    final views = rec.youtubeViews != null
        ? '\nVues YouTube: ${_formatCount(rec.youtubeViews!)}'
        : '';
    final likes = rec.youtubeLikes != null
        ? ' • ${_formatCount(rec.youtubeLikes!)} likes'
        : '';
    final game = rec.suggestedGame != null
        ? '\nJeu suggéré: ${rec.suggestedGame}'
        : '';
    final cat = rec.suggestedCategory != null
        ? '\nCatégorie suggérée: ${rec.suggestedCategory}'
        : '';

    return Tooltip(
      message:
          '${rec.verdict.label} (${(rec.confidence * 100).round()}%)\n'
          '${rec.reason}$views$likes$game$cat',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              rec.verdict.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            if (rec.youtubeViews != null) ...[
              const SizedBox(width: 4),
              Text(
                _formatCount(rec.youtubeViews!),
                style: TextStyle(
                  fontSize: 10,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Formate un nombre avec suffixes (1.2k, 3.4M).
  static String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}
