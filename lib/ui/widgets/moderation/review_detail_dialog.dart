// Détail d'un événement de modération (P4b-3, lot L5, conception §6.4 a,
// §6.9) : en-tête, cible, décision du détecteur, relecture serveur, preuve
// en texte brut, boutons d'action passés par l'appelant.
//
// Chargé par un `Future<ReviewDetail> Function()` injecté. Erreurs : 401 →
// fermeture PUIS `onAuthError` (S-08) ; 404 « Événement introuvable. » ;
// 403 « Réservé au compte principal. » ; autre : message + « Réessayer ».
// Un clic sur une action ferme le dialogue en rendant l'action (et appelle
// `onAction` s'il est fourni) : l'écran enchaîne sur la décision.
//
// Tous les textes du serveur qui peuvent venir d'un tiers (cible, clé de
// contenu, motif, nom d'acteur, hôtes, preuve) sont révélés et jamais
// cliquables ; seules les empreintes (64 hex) ont un bouton « Copier ».
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../data/supabase_sync.dart'
    show
        AdminApiException,
        AdminAuthException,
        AdminForbiddenException,
        errorText;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_text.dart';
import 'evidence_view.dart';
import 'moderation_ui.dart';
import 'reason_chips.dart';
import 'status_badges.dart';

class ReviewDetailDialog extends StatefulWidget {
  const ReviewDetailDialog({
    super.key,
    required this.load,
    this.actions = const <ReviewAction>[],
    this.onAction,
    required this.onAuthError,
  });

  final Future<ReviewDetail> Function() load;

  /// Boutons proposés (« Détail » est ignoré : on y est déjà).
  final List<ReviewAction> actions;

  /// Appelé APRÈS la fermeture, avec l'action choisie.
  final void Function(ReviewAction action)? onAction;

  /// 401 : appelé APRÈS la fermeture du dialogue.
  final VoidCallback onAuthError;

  /// Ouvre le détail ; rend l'action choisie (null : fermé).
  static Future<ReviewAction?> show(
    BuildContext context, {
    required Future<ReviewDetail> Function() load,
    List<ReviewAction> actions = const <ReviewAction>[],
    required VoidCallback onAuthError,
  }) => showDialog<ReviewAction>(
    context: context,
    builder: (_) => ReviewDetailDialog(
      load: load,
      actions: actions,
      onAuthError: onAuthError,
    ),
  );

  @override
  State<ReviewDetailDialog> createState() => _ReviewDetailDialogState();
}

class _ReviewDetailDialogState extends State<ReviewDetailDialog> {
  bool _loading = true;
  ReviewDetail? _detail;
  String? _error;
  bool _retryable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_detail == null && _error != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final ReviewDetail d = await widget.load();
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on AdminAuthException {
      if (mounted) Navigator.of(context).pop();
      widget.onAuthError();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _retryable = false;
        if (e is AdminForbiddenException) {
          _error = 'Réservé au compte principal.';
        } else if (e is AdminApiException && e.isNotFound) {
          _error = 'Événement introuvable.';
        } else {
          _error = errorText(e);
          _retryable = true;
        }
      });
    }
  }

  void _choose(ReviewAction a) {
    Navigator.of(context).pop(a);
    widget.onAction?.call(a);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    final ReviewDetail? d = _detail;
    final String title = d == null
        ? "Détail de l'événement"
        : 'Événement #${d.event.id} — ${eventActionLabel(d.event.action)}';
    final List<ReviewAction> actions = <ReviewAction>[
      for (final ReviewAction a in widget.actions)
        if (a != ReviewAction.detail) a,
    ];

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                title,
                key: const Key('moderation-detail-title'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _body(theme),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  if (d != null)
                    for (final ReviewAction a in actions)
                      reviewActionButton(
                        a,
                        key: ValueKey<String>(
                          'moderation-detail-action-${a.name}',
                        ),
                        onPressed: () => _choose(a),
                      ),
                  if (_error != null && _retryable)
                    OutlinedButton.icon(
                      key: const Key('moderation-detail-retry'),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Réessayer'),
                    ),
                  TextButton(
                    key: const Key('moderation-detail-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Fermer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
      );
    }
    final String? error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
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
                error,
                key: const Key('moderation-detail-error'),
                style: TextStyle(color: Colors.orange.shade300),
              ),
            ),
          ],
        ),
      );
    }
    final ReviewDetail d = _detail!;
    final BanEvent e = d.event;
    final TextStyle? small = theme.textTheme.bodySmall;
    final Map<String, dynamic>? snap = e.snapshot;
    final bool hasReadback =
        snap != null && (snap['suggestion'] is Map || snap['serveur'] is Map);
    final int othersMembers = d.groupSize - 1 - d.groupMembers.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 1. En-tête.
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            ModerationPill(
              label: banOriginLabel(e.origin),
              color: e.origin == 'auto'
                  ? ModerationColors.warning
                  : ModerationColors.neutral,
            ),
            ModerationPill(
              label: actorKindLabel(e.actorKind),
              color: ModerationColors.info,
            ),
            CategoryChip(code: e.category),
            Text(formatModerationDate(e.createdAt), style: small),
            if (e.actorUsername != null && e.actorUsername!.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: UntrustedLine(
                  'par ${e.actorUsername!}',
                  max: 44,
                  style: small,
                ),
              ),
          ],
        ),
        // 2. Cible.
        _section(theme, 'Cible'),
        Text(targetKindLabel(e.targetKind), style: small),
        const SizedBox(height: 2),
        UntrustedSelectable(
          e.targetKey ?? '—',
          key: const Key('moderation-detail-target'),
          maxLines: 6,
        ),
        if (e.platform != null)
          _kv(
            theme,
            'Plateforme',
            Text(platformLabel(e.platform), style: small),
          ),
        if (e.contentKey != null)
          _kv(
            theme,
            'Contenu',
            UntrustedLine(e.contentKey!, monospace: true, style: small),
          ),
        // 3. Décision du détecteur.
        _section(theme, 'Décision du détecteur'),
        if (e.reasons.isEmpty)
          Text('Aucune raison.', style: small)
        else
          ReasonChips(codes: e.reasons, showCode: true),
        const SizedBox(height: 6),
        if (e.detectorVersion != null)
          _kv(
            theme,
            'Version du détecteur',
            UntrustedLine(e.detectorVersion!, max: 128, style: small),
          ),
        if (e.rulesSha256 != null)
          _hash(theme, 'Empreinte des règles', e.rulesSha256!, 'rules'),
        if (e.rules != null && e.rules!.isNotEmpty)
          _kv(
            theme,
            'Règles fondatrices',
            UntrustedSelectable(
              e.rules!.join(', '),
              maxLines: 4,
              fontSize: 11.5,
            ),
          ),
        if (e.field != null || e.level != null)
          _kv(
            theme,
            'Champ / niveau',
            UntrustedLine(
              '${e.field ?? '—'} / ${levelLabel(e.level)}',
              max: 100,
              style: small,
            ),
          ),
        if (e.evidenceSha256 != null)
          _hash(theme, 'Empreinte de la preuve', e.evidenceSha256!, 'evidence'),
        if (e.rawSha256 != null)
          _hash(theme, 'Empreinte brute', e.rawSha256!, 'raw'),
        if (d.groupSize > 1 || d.groupHeadId != e.id) ...<Widget>[
          _kv(
            theme,
            'Groupe',
            Text(
              'Tête #${d.groupHeadId} — ${d.groupSize} événement(s)',
              style: small,
            ),
          ),
          if (d.groupMembers.isNotEmpty)
            _kv(
              theme,
              'Membres',
              Text(
                '${d.groupMembers.map((int m) => '#$m').join(', ')}'
                '${othersMembers > 0 ? ' … et $othersMembers autres' : ''}',
                key: const Key('moderation-detail-members'),
                style: small,
              ),
            ),
        ],
        if (e.refEventId != null)
          _kv(theme, 'Référence', Text('#${e.refEventId}', style: small)),
        if (e.note != null && e.note!.isNotEmpty)
          _kv(
            theme,
            'Motif',
            UntrustedSelectable(
              e.note!,
              key: const Key('moderation-detail-note'),
              maxLines: 6,
              monospace: false,
              fontSize: 12.5,
            ),
          ),
        // 4. Relecture serveur.
        if (hasReadback) ...<Widget>[
          _section(theme, 'Relecture serveur'),
          ServerReadbackView(snapshot: snap),
        ],
        // 5. Preuve.
        _section(theme, 'Preuve (texte brut)'),
        EvidenceView(detail: d),
        const SizedBox(height: 8),
      ],
    );
  }

  static Widget _section(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    ),
  );

  static Widget _kv(ThemeData theme, String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 170,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(child: value),
      ],
    ),
  );

  /// Empreinte + « Copier » (seulement si c'est bien 64 hex).
  Widget _hash(ThemeData theme, String label, String sha, String id) {
    final bool valid = kSha256Re.hasMatch(sha);
    return _kv(
      theme,
      label,
      Row(
        children: <Widget>[
          Expanded(
            child: UntrustedLine(
              sha,
              max: 64,
              monospace: true,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (valid)
            TextButton(
              key: ValueKey<String>('moderation-copy-$id'),
              onPressed: () => _copy(sha),
              child: const Text('Copier'),
            ),
        ],
      ),
    );
  }

  Future<void> _copy(String sha) async {
    await Clipboard.setData(ClipboardData(text: sha));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Empreinte copiée.'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
