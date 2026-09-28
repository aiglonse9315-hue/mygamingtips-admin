// Briques communes aux 5 onglets de l'écran « Modération » (P4b-3, lot L7,
// conception §6.2-§6.8) : SnackBar selon le ton, confirmation simple, états
// (chargement, erreur, 403, vide), barre de pagination, tableau à colonnes
// pondérées, cellule de texte non fiable, en-tête de l'écran, et les
// ENCHAÎNEMENTS de décision : détail d'un événement → décision avec motif →
// SnackBar → purge proposée d'une chaîne (id de ligne, §6.4 e).
//
// AUCUN import de StoreController, AuthController ni Provider (chaîne
// dart:html) : l'écran passe l'accès serveur (`SupabaseSync`), le statut
// « compte principal » et `onAuthError` (401 → déconnexion) en paramètres →
// onglets testables en VM (`test/moderation_tabs_test.dart`).
//
// Texte non fiable (clés de cible, hôtes, URL, noms, motifs) : `Text`
// seulement, révélé (`oneLinePreview` / `revealInvisibles`), écrit de gauche
// à droite, rogné ; jamais de lien.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, SupabaseSync, errorText;
import '../../../domain/models/banned_channel.dart';
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_screen_rules.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/moderation/auto_ban_lift_dialog.dart';
import '../../widgets/moderation/moderation_alert_view.dart'
    show breakerBannerText, kModerationAlertError;
import '../../widgets/moderation/moderation_ui.dart';
import '../../widgets/moderation/purge_auto_dialog.dart';
import '../../widgets/moderation/review_decision_dialog.dart';
import '../../widgets/moderation/review_detail_dialog.dart';

// ── Messages ─────────────────────────────────────────────────────────────────

/// SnackBar selon le ton (conventions §6 : succès / info 4 s par défaut,
/// avertissement orange 6 s, erreur rouge 5 s).
void showModerationSnack(
  BuildContext context,
  String message, {
  OutcomeTone tone = OutcomeTone.success,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final SnackBar bar = switch (tone) {
    OutcomeTone.error => SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 5),
    ),
    OutcomeTone.warning => SnackBar(
      content: Text(message),
      backgroundColor: Colors.orange.shade700,
      duration: const Duration(seconds: 6),
    ),
    OutcomeTone.success || OutcomeTone.info => SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
    ),
  };
  messenger.showSnackBar(bar);
}

/// Confirmation simple (« Annuler » / [confirmLabel]) : `true` si confirmé.
Future<bool> confirmModerationAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  bool ok = false;
  await showDialog<void>(
    context: context,
    builder: (_) => ConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: destructive,
      onConfirm: () => ok = true,
    ),
  );
  return ok;
}

// ── États ────────────────────────────────────────────────────────────────────

/// Indicateur de chargement centré.
class ModerationLoadingView extends StatelessWidget {
  const ModerationLoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 48),
    child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
  );
}

/// État 403 : « Réservé au compte principal. » (icône cadenas 40, motif
/// `logs_screen.dart`).
class ModerationForbiddenView extends StatelessWidget {
  const ModerationForbiddenView({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.lock_outline_rounded,
              size: 40,
              color: theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(height: 12),
            Text(
              kModerationForbiddenMessage,
              key: const Key('moderation-forbidden'),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Icône + message centrés (état vide, mode démo).
class ModerationEmptyView extends StatelessWidget {
  const ModerationEmptyView({
    super.key,
    required this.icon,
    required this.message,
    this.messageKey,
  });

  final IconData icon;
  final String message;
  final Key? messageKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.textTheme.bodySmall?.color),
            const SizedBox(height: 12),
            Text(
              message,
              key: messageKey,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Erreur de lecture : message orange + « Réessayer ».
class ModerationErrorBanner extends StatelessWidget {
  const ModerationErrorBanner({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: Colors.orange.shade300,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              key: const Key('moderation-tab-error'),
              style: TextStyle(color: Colors.orange.shade300),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('moderation-tab-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Réessayer'),
          ),
        ],
      ),
    );
  }
}

// ── Pagination ───────────────────────────────────────────────────────────────

/// « Page X / N (a–b sur T) » + 4 boutons (motif `logs_screen.dart`).
class ModerationPaginationBar extends StatelessWidget {
  const ModerationPaginationBar({
    super.key,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.loading,
    required this.onPage,
    this.range = true,
  });

  final int page;
  final int pageSize;
  final int total;
  final bool loading;
  final ValueChanged<int> onPage;

  /// Faux : « Page X / N » seulement.
  final bool range;

  @override
  Widget build(BuildContext context) {
    final int pages = totalPages(total, pageSize);
    final bool canBack = page > 0 && !loading;
    final bool canForward = page < pages - 1 && !loading;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          key: const Key('moderation-page-first'),
          icon: const Icon(Icons.first_page_rounded),
          onPressed: canBack ? () => onPage(0) : null,
          tooltip: 'Première page',
        ),
        IconButton(
          key: const Key('moderation-page-previous'),
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: canBack ? () => onPage(page - 1) : null,
          tooltip: 'Page précédente',
        ),
        const SizedBox(width: 8),
        Text(
          paginationLabel(
            page: page,
            pageSize: pageSize,
            total: total,
            range: range,
          ),
          key: const Key('moderation-page-label'),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const Key('moderation-page-next'),
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: canForward ? () => onPage(page + 1) : null,
          tooltip: 'Page suivante',
        ),
        IconButton(
          key: const Key('moderation-page-last'),
          icon: const Icon(Icons.last_page_rounded),
          onPressed: canForward ? () => onPage(pages - 1) : null,
          tooltip: 'Dernière page',
        ),
        if (loading) ...<Widget>[const SizedBox(width: 8), kButtonSpinner],
      ],
    );
  }
}

// ── Tableau ──────────────────────────────────────────────────────────────────

/// Colonne d'un [ModerationTable] (largeur relative [flex]).
@immutable
class ModerationColumn {
  const ModerationColumn(this.label, {this.flex = 1});

  final String label;
  final int flex;
}

/// Tableau à colonnes pondérées, sans ligne cliquable (aucun `InkWell`).
/// En dessous de [minWidth] px, défile horizontalement.
class ModerationTable extends StatelessWidget {
  const ModerationTable({
    super.key,
    required this.columns,
    required this.rows,
    this.rowKeys,
    this.minWidth = 900,
  });

  final List<ModerationColumn> columns;
  final List<List<Widget>> rows;
  final List<Key>? rowKeys;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final Color border = theme.dividerColor;
    final Color muted = theme.textTheme.bodySmall?.color ?? Colors.grey;

    Widget line(List<Widget> cells, {Key? key, bool last = false}) => Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < columns.length; i++)
            Expanded(
              flex: columns[i].flex,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: i < cells.length ? cells[i] : const SizedBox(),
              ),
            ),
        ],
      ),
    );

    final Widget table = Container(
      decoration: BoxDecoration(
        color: theme.canvasColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            color: dark
                ? Colors.white.withValues(alpha: 0.03)
                : Colors.black.withValues(alpha: 0.02),
            child: line(<Widget>[
              for (final ModerationColumn c in columns)
                Text(
                  c.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: muted,
                  ),
                ),
            ]),
          ),
          for (int r = 0; r < rows.length; r++)
            line(
              rows[r],
              key: rowKeys != null && r < rowKeys!.length ? rowKeys![r] : null,
              last: r == rows.length - 1,
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (!c.hasBoundedWidth || c.maxWidth >= minWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: minWidth, child: table),
        );
      },
    );
  }
}

/// Cellule de texte DÉJÀ révélé (une ligne, gauche-à-droite, rognée),
/// infobulle facultative (texte révélé lui aussi).
class RevealedCell extends StatelessWidget {
  const RevealedCell(
    this.text, {
    super.key,
    this.tooltip,
    this.monospace = false,
    this.style,
  });

  final String text;
  final String? tooltip;
  final bool monospace;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = style ?? const TextStyle(fontSize: 12.5);
    final Widget cell = Directionality(
      textDirection: TextDirection.ltr,
      child: ClipRect(
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: monospace ? base.copyWith(fontFamily: 'monospace') : base,
        ),
      ),
    );
    final String? tip = tooltip;
    return tip == null ? cell : Tooltip(message: tip, child: cell);
  }
}

// ── En-tête de l'écran ───────────────────────────────────────────────────────

/// En-tête de l'écran (§6.2) : titre, pastilles « Ban automatique :
/// allumé / éteint » et « File : N », bandeau rouge du disjoncteur avec
/// « Voir les réglages », bouton ↻ « Actualiser ».
class ModerationHeader extends StatelessWidget {
  const ModerationHeader({
    super.key,
    required this.settings,
    this.loading = false,
    this.error,
    required this.onRefresh,
    required this.onOpenSettings,
  });

  final ModerationSettings? settings;
  final bool loading;

  /// Erreur de lecture des réglages (message déjà traduit).
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ModerationSettings? s = settings;
    final DateTime? tripped = s?.breakerTrippedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      kModerationScreenTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  if (s != null) ...<Widget>[
                    ModerationPill(
                      key: const Key('moderation-header-state'),
                      label: autoBanPillLabel(s.autoBanEnabled),
                      color: s.autoBanEnabled
                          ? ModerationColors.success
                          : ModerationColors.neutral,
                    ),
                    ModerationPill(
                      key: const Key('moderation-header-queue'),
                      label: queueSizePillLabel(s.reviewQueueSize),
                      color: ModerationColors.info,
                    ),
                  ] else if (error != null)
                    Text(
                      error!,
                      key: const Key('moderation-header-error'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.orange.shade300,
                      ),
                    ),
                ],
              ),
            ),
            if (loading) ...<Widget>[kButtonSpinner, const SizedBox(width: 8)],
            IconButton(
              key: const Key('moderation-refresh'),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Actualiser',
            ),
          ],
        ),
        if (s != null && tripped != null) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            key: const Key('moderation-header-breaker'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: ModerationColors.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ModerationColors.danger, width: 1.5),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    breakerBannerText(tripped, s.breakerReason),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: ModerationColors.danger,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const Key('moderation-header-open-settings'),
                  onPressed: onOpenSettings,
                  child: const Text('Voir les réglages'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Erreur de lecture des réglages de l'en-tête : 403 → « Réservé au compte
/// principal. » ; autre → « État de la modération illisible. ».
String headerSettingsError({required bool forbidden}) =>
    forbidden ? kModerationForbiddenMessage : kModerationAlertError;

// ── Enchaînements de décision ────────────────────────────────────────────────

/// Rappel appelé JUSTE APRÈS une décision (avant la purge proposée) : retrait
/// de l'élément, relecture. Le rappel vérifie lui-même `mounted`.
typedef OutcomeHandler = void Function(DecisionOutcome outcome);

/// Décision de revue sur [eventId] : dialogue avec motif (levée depuis une
/// LISTE : `AutoBanLiftDialog`, détail replié), [onOutcome], SnackBar selon
/// le ton, puis purge proposée d'une chaîne confirmée / appliquée (§6.4 d-e).
/// Rend l'issue (null : annulé ou session expirée).
Future<DecisionOutcome?> runReviewDecision(
  BuildContext context, {
  required SupabaseSync sync,
  required int eventId,
  required ReviewDecision decision,
  required String targetLabel,
  String? targetKind,
  int groupSize = 1,
  bool manualBanPresent = false,
  int? channelRowId,
  bool liftFromList = false,
  required VoidCallback onAuthError,
  OutcomeHandler? onOutcome,
}) async {
  Future<ReviewDecideResult> submit(String? reason) =>
      sync.reviewDecide(eventId, decision, reason: reason);
  final DecisionDialogOutcome? r =
      liftFromList && decision == ReviewDecision.lift
      ? await AutoBanLiftDialog.show(
          context,
          loadDetail: () => sync.fetchReviewDetail(eventId),
          submit: submit,
          targetLabel: targetLabel,
          manualBanPresent: manualBanPresent,
          onAuthError: onAuthError,
        )
      : await ReviewDecisionDialog.show(
          context,
          decision: decision,
          targetLabel: targetLabel,
          targetKind: targetKind,
          groupSize: groupSize,
          manualBanPresent: manualBanPresent,
          submit: submit,
          onAuthError: onAuthError,
        );
  if (r == null) return null;
  final DecisionOutcome o = r.outcome;
  onOutcome?.call(o);
  if (!context.mounted) return o;
  showModerationSnack(context, o.message, tone: o.tone);
  if (o.offerPurge) {
    await offerChannelPurge(
      context,
      sync: sync,
      rowId: purgeRowIdFromItem(
        decision: decision.code,
        channelRowId: channelRowId,
      ),
      lookupEventId: purgeLookupEventId(
        decision.code,
        itemId: eventId,
        resultEventId: r.result?.eventId,
      ),
      channelLabel: targetLabel,
      onAuthError: onAuthError,
    );
  }
  return o;
}

/// Purge d'une chaîne bannie automatiquement et confirmée : id de ligne
/// [rowId] s'il est connu, sinon recherché par `ban_event_id ==
/// lookupEventId` (`findBannedChannelByEventId`) ; introuvable → SnackBar
/// « Ligne de chaîne introuvable… ».
Future<void> offerChannelPurge(
  BuildContext context, {
  required SupabaseSync sync,
  int? rowId,
  int? lookupEventId,
  required String channelLabel,
  required VoidCallback onAuthError,
}) async {
  int? id = rowId;
  if (id == null && lookupEventId != null) {
    try {
      final BannedChannel? c = await sync.findBannedChannelByEventId(
        lookupEventId,
      );
      if (c != null && c.id > 0) id = c.id;
    } on AdminAuthException {
      onAuthError();
      return;
    } catch (e) {
      if (context.mounted) {
        showModerationSnack(context, errorText(e), tone: OutcomeTone.error);
      }
      return;
    }
  }
  if (!context.mounted) return;
  if (id == null) {
    showModerationSnack(
      context,
      kPurgeRowNotFoundMessage,
      tone: OutcomeTone.warning,
    );
    return;
  }
  final int row = id;
  await PurgeAutoDialog.show(
    context,
    channelLabel: channelLabel,
    loadPreview: () => sync.purgeAutoChannel(id: row, apply: false),
    apply: () => sync.purgeAutoChannel(id: row, apply: true),
    onAuthError: onAuthError,
  );
}

/// Détail de [eventId] (`review-detail` fonctionne pour tout événement) ;
/// une action choisie parmi [actions] enchaîne : décision
/// ([runReviewDecision], cible tirée du détail si [targetLabel] est nul) ou
/// purge (ligne cherchée par `ban_event_id == eventId`). Rend l'issue de la
/// décision (null : fermé, purge ou session expirée).
Future<DecisionOutcome?> openEventDetail(
  BuildContext context, {
  required SupabaseSync sync,
  required int eventId,
  List<ReviewAction> actions = const <ReviewAction>[],
  String? targetLabel,
  String? targetKind,
  bool manualBanPresent = false,
  required VoidCallback onAuthError,
  OutcomeHandler? onOutcome,
}) async {
  ReviewDetail? loaded;
  final ReviewAction? a = await ReviewDetailDialog.show(
    context,
    load: () async {
      final ReviewDetail d = await sync.fetchReviewDetail(eventId);
      loaded = d;
      return d;
    },
    actions: actions,
    onAuthError: onAuthError,
  );
  final ReviewDetail? d = loaded;
  if (a == null || d == null || !context.mounted) return null;
  final String label = targetLabel ?? eventTargetLabel(d.event);
  if (a == ReviewAction.purge) {
    await offerChannelPurge(
      context,
      sync: sync,
      lookupEventId: eventId,
      channelLabel: label,
      onAuthError: onAuthError,
    );
    return null;
  }
  final ReviewDecision? decision = decisionForAction(a);
  if (decision == null) return null;
  return runReviewDecision(
    context,
    sync: sync,
    eventId: eventId,
    decision: decision,
    targetLabel: label,
    targetKind: targetKind ?? d.event.targetKind,
    groupSize: d.groupSize,
    manualBanPresent: manualBanPresent,
    onAuthError: onAuthError,
    onOutcome: onOutcome,
  );
}
