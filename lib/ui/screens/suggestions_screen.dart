import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../core/auth/auth_controller.dart';
import '../../core/theme/colors.dart';
import '../../domain/ids.dart';
import '../../domain/models/banned_user.dart';
import '../../domain/models/suggestion.dart';
import '../../domain/moderation_actions.dart' show ModerationFocus;
import '../../domain/moderation_text.dart';
import '../../domain/web_link.dart';
import '../../state/store_controller.dart';
import '../widgets/account_ban_flows.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/moderation/account_ban_widgets.dart';
import '../widgets/moderation/moderation_ui.dart' show UntrustedLine;
import '../widgets/stat_card.dart' show StatusBadge;
import '../widgets/suggestion_review_dialog.dart';

/// Modération des suggestions : triées par date de partage, valider / refuser.
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({super.key, this.onOpenModeration});

  /// Ouvre le menu Modération (« Ouvrir dans Modération » de la levée d'un
  /// ban automatique) ; nul = pas de lien.
  final void Function([ModerationFocus? focus])? onOpenModeration;

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  SuggestionStatus? _statusFilter; // null = toutes
  bool _hideVision = false; // true = exclure les suggestions du bot Vision
  bool _hideScruteur = false; // true = exclure celles du bot Scruteur (§127)
  int _currentPage = 0;
  static const int _pageSize = 500;

  @override
  void initState() {
    super.initState();
    // P4b-3 (§5.2, ETAT-01) : la liste des bannis n'est lue qu'à la
    // connexion — relue à l'ouverture pour que le badge d'origine (T3)
    // reflète l'état serveur (le 409 du déban reste le filet de sécurité).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<StoreController>().reloadBannedList(reportErrors: false),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();
    final bool isOwner = context.watch<AuthController>().isOwner;

    // Filtres d'origine (colonne `source`) : Vision et / ou Scruteur
    // masqués — les deux = suggestions des utilisateurs seules. Les
    // compteurs des onglets de statut portent sur cette liste.
    final List<Suggestion> bySource = store.suggestionsByDate
        .where((s) =>
            !(_hideVision && s.isFromVision) &&
            !(_hideScruteur && s.isFromScruteur))
        .toList();
    int countOf(SuggestionStatus status) =>
        bySource.where((s) => s.status == status).length;
    List<Suggestion> list = bySource;
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
                  label: 'Toutes (${bySource.length})',
                  selected: _statusFilter == null,
                  color: AppColors.neonCyan,
                  onTap: () => setState(() => _statusFilter = null)),
              _StatusTab(
                  label:
                      'En attente (${countOf(SuggestionStatus.pending)})',
                  selected: _statusFilter == SuggestionStatus.pending,
                  color: AppColors.plusGold,
                  onTap: () => setState(() =>
                      _statusFilter = SuggestionStatus.pending)),
              _StatusTab(
                  label:
                      'Acceptées (${countOf(SuggestionStatus.accepted)})',
                  selected: _statusFilter == SuggestionStatus.accepted,
                  color: AppColors.neonGreen,
                  onTap: () => setState(() =>
                      _statusFilter = SuggestionStatus.accepted)),
              _StatusTab(
                  label:
                      'Refusées (${countOf(SuggestionStatus.rejected)})',
                  selected: _statusFilter == SuggestionStatus.rejected,
                  color: AppColors.categoryVideo,
                  onTap: () => setState(() =>
                      _statusFilter = SuggestionStatus.rejected)),
              _StatusTab(
                  label: _hideVision ? 'Vision masqué' : 'Masquer Vision',
                  selected: _hideVision,
                  color: AppColors.neonViolet,
                  onTap: () => setState(() => _hideVision = !_hideVision)),
              _StatusTab(
                  label:
                      _hideScruteur ? 'Scruteur masqué' : 'Masquer Scruteur',
                  selected: _hideScruteur,
                  color: AppColors.neonMagenta,
                  onTap: () =>
                      setState(() => _hideScruteur = !_hideScruteur)),
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
                      // P4b-3 (S-16) : URL révélée sur une ligne ; ouvrable
                      // seulement si http(s) avec un hôte.
                      _SuggestionUrl(url: s.url),
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
                                      // Nom choisi par un tiers (revue
                                      // P4b-3, SEC-P4b3-02) : invisibles
                                      // révélés, longueur bornée.
                                      child: UntrustedLine(
                                          s.author.displayName,
                                          max: 60,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700)),
                                    ),
                                    if (store.isAuthorBanned(s.author.id)) ...[
                                      const SizedBox(width: 5),
                                      StatusBadge(
                                          label: 'BANNI',
                                          color: AppColors.categoryVideo),
                                      if (store
                                              .bannedEntry(s.author.id)
                                              ?.isAuto ??
                                          false) ...[
                                        const SizedBox(width: 4),
                                        AutoBanPill(
                                            status: store
                                                .bannedEntry(s.author.id)
                                                ?.status),
                                      ],
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
                      // Texte partagé par un tiers (revue P4b-3,
                      // SEC-P4b3-02) : une ligne, invisibles révélés, borné.
                      UntrustedLine(s.sharedText ?? '—',
                          max: 120,
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
                          // Modération du compte : bannir / débannir l'auteur
                          // (P4b-3, T3 / T5) — masquée pour un auteur non
                          // UUID (partage d'un bot : rien à bannir).
                          if (isUuid(s.author.id))
                            _authorBanButton(context, store, s, isOwner),
                        ],
                      ),
                    ])
                .toList(),
          ),
        ],
      ),
    );
  }

  /// Bouton de ban de l'auteur : banni → « Débannir » / « Lever » selon
  /// l'origine connue ; sinon « Bannir le compte » (catégorie + motif).
  Widget _authorBanButton(
    BuildContext context,
    StoreController store,
    Suggestion s,
    bool isOwner,
  ) {
    final BannedUser? entry = store.bannedEntry(s.author.id);
    if (entry != null) {
      return AccountUnbanIconButton(
        control: accountUnbanControl(entry, isOwner: isOwner),
        onUnban: () => _unbanAuthor(context, s, entry),
        onLift: () => _unbanAuthor(context, s, entry),
      );
    }
    return IconButton(
      tooltip: 'Bannir le compte',
      icon: const Icon(Icons.block_rounded, size: 20),
      color: AppColors.categoryVideo,
      onPressed: () => banAccountFlow(
        context,
        userId: s.author.id,
        displayName: s.author.displayName,
      ),
    );
  }

  void _unbanAuthor(BuildContext context, Suggestion s, BannedUser entry) {
    unawaited(
      accountUnbanFlow(
        context,
        userId: s.author.id,
        name: s.author.displayName,
        entry: entry,
        onOpenModeration: widget.onOpenModeration,
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

/// URL d'une suggestion (P4b-3, S-16) : texte choisi par l'auteur du
/// partage, affiché révélé sur UNE ligne (`oneLinePreview`, 80 points de
/// code, gauche-à-droite) ; lien seulement pour une URL http(s) avec hôte
/// ([webLinkUri]), sinon texte non cliquable avec infobulle.
class _SuggestionUrl extends StatelessWidget {
  const _SuggestionUrl({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final Uri? uri = webLinkUri(url);
    final Widget text = Directionality(
      textDirection: TextDirection.ltr,
      child: Text(
        oneLinePreview(url, max: 80),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: uri == null
            ? const TextStyle(fontSize: 13)
            : const TextStyle(
                fontSize: 13,
                color: AppColors.neonCyan,
                decoration: TextDecoration.underline,
              ),
      ),
    );
    if (uri == null) {
      return Tooltip(message: kNonWebLinkTooltip, child: text);
    }
    return InkWell(
      onTap: () => ul.launchUrl(uri, mode: ul.LaunchMode.externalApplication),
      child: text,
    );
  }
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
