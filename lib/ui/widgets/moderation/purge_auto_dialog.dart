// Purge des suggestions d'une chaîne bannie AUTOMATIQUEMENT et confirmée
// (route `channels/purge-auto`, compte principal ; P4b-3, lot L5,
// conception §6.4 d, §6.9).
//
// 1. aperçu (`loadPreview` = `purgeAutoChannel(id, apply: false)`) : titre
//    « Purger les suggestions de <chaîne> ? », texte `purgePreviewText`,
//    contenus déjà publiés (≤ 200, titre ou URL révélés, NON cliquables) ;
// 2. « Plus tard » / « Rejeter N suggestion(s) » (rouge ; « Rien à purger »
//    désactivé si rien n'est en attente) ;
// 3. application (`apply`) → `purgeResultText` (ou le message de rejeu si la
//    réponse a été obtenue après rejeu avec 0 rejetée) + publiés, « Fermer ».
// Erreurs (corps `{error}` SANS `result`) : message du serveur tel quel ;
// 409 / 404 → « Fermer » seul ; 403 → « Réservé au compte principal. » ;
// 401 → fermeture + `onAuthError` ; issue incertaine → message +
// « Réessayer » (rejeu sûr côté serveur).
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show
        AdminApiException,
        AdminAuthException,
        AdminForbiddenException,
        errorText,
        isUncertainFailure;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_text.dart';
import 'moderation_ui.dart';

/// Taille de la liste des publiés renvoyée par le serveur (M94:2221).
const int kPurgePublishedMax = 200;

enum _PurgePhase { loading, preview, applying, done, error }

class PurgeAutoDialog extends StatefulWidget {
  const PurgeAutoDialog({
    super.key,
    required this.channelLabel,
    required this.loadPreview,
    required this.apply,
    required this.onAuthError,
  });

  /// Libellé de la chaîne (révélé ici, 60 points de code).
  final String channelLabel;
  final Future<PurgeAutoResult> Function() loadPreview;
  final Future<PurgeAutoResult> Function() apply;

  /// 401 : appelé APRÈS la fermeture.
  final VoidCallback onAuthError;

  /// Ouvre le dialogue ; rend le résultat de l'application (null sinon).
  static Future<PurgeAutoResult?> show(
    BuildContext context, {
    required String channelLabel,
    required Future<PurgeAutoResult> Function() loadPreview,
    required Future<PurgeAutoResult> Function() apply,
    required VoidCallback onAuthError,
  }) => showDialog<PurgeAutoResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PurgeAutoDialog(
      channelLabel: channelLabel,
      loadPreview: loadPreview,
      apply: apply,
      onAuthError: onAuthError,
    ),
  );

  @override
  State<PurgeAutoDialog> createState() => _PurgeAutoDialogState();
}

class _PurgeAutoDialogState extends State<PurgeAutoDialog> {
  _PurgePhase _phase = _PurgePhase.loading;
  PurgeAutoResult? _preview;
  PurgeAutoResult? _result;
  String? _error;

  /// Étape à rejouer après une erreur incertaine (null : pas de rejeu).
  Future<void> Function()? _retry;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _phase = _PurgePhase.loading;
      _error = null;
    });
    try {
      final PurgeAutoResult p = await widget.loadPreview();
      if (!mounted) return;
      setState(() {
        _preview = p;
        _phase = _PurgePhase.preview;
      });
    } catch (e) {
      _fail(e, _loadPreview);
    }
  }

  Future<void> _apply() async {
    setState(() {
      _phase = _PurgePhase.applying;
      _error = null;
    });
    try {
      final PurgeAutoResult r = await widget.apply();
      if (!mounted) return;
      setState(() {
        _result = r;
        _phase = _PurgePhase.done;
      });
    } catch (e) {
      _fail(e, _apply);
    }
  }

  void _fail(Object e, Future<void> Function() step) {
    if (e is AdminAuthException) {
      if (mounted) Navigator.of(context).pop();
      widget.onAuthError();
      return;
    }
    if (!mounted) return;
    setState(() {
      _phase = _PurgePhase.error;
      _retry = null;
      if (e is AdminForbiddenException) {
        _error = 'Réservé au compte principal.';
      } else if (e is AdminApiException &&
          (e.statusCode == 409 || e.statusCode == 404)) {
        _error = e.message;
      } else {
        _error = errorText(e);
        if (isUncertainFailure(e)) _retry = step;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String label = oneLinePreview(widget.channelLabel, max: 60);
    final bool busy =
        _phase == _PurgePhase.loading || _phase == _PurgePhase.applying;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text('Purger les suggestions de $label ?'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: _body(theme)),
        ),
        actions: _actions(),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    switch (_phase) {
      case _PurgePhase.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
        );
      case _PurgePhase.error:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: Colors.orange.shade300,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error ?? '',
                key: const Key('moderation-purge-error'),
                style: TextStyle(color: Colors.orange.shade300),
              ),
            ),
          ],
        );
      case _PurgePhase.preview:
      case _PurgePhase.applying:
        final PurgeAutoResult p = _preview!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              purgePreviewText(
                p.pending,
                p.pendingByDetection,
                p.pendingByChannelId,
                p.published.length,
              ),
              key: const Key('moderation-purge-text'),
            ),
            ..._published(theme, p.published),
          ],
        );
      case _PurgePhase.done:
        final PurgeAutoResult r = _result!;
        final String text =
            replayNotice(replayed: r.replayed, count: r.purged) ??
            purgeResultText(r.purged ?? 0, r.pending);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              key: const Key('moderation-purge-result'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            ..._published(theme, r.published),
          ],
        );
    }
  }

  List<Widget> _published(ThemeData theme, List<PublishedContent> items) {
    if (items.isEmpty) return const <Widget>[];
    final double height = (items.length * 22.0).clamp(22.0, 220.0);
    return <Widget>[
      const SizedBox(height: 12),
      Text(
        'Contenus déjà publiés'
        '${items.length >= kPurgePublishedMax ? ' ($kPurgePublishedMax premiers)' : ''}'
        ' — retrait manuel :',
        key: const Key('moderation-purge-published-title'),
        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: height,
        child: ListView.builder(
          itemCount: items.length,
          itemExtent: 22,
          itemBuilder: (BuildContext context, int i) {
            final PublishedContent c = items[i];
            return UntrustedLine(
              '• ${c.title ?? c.url ?? c.id}',
              max: 122,
              style: theme.textTheme.bodySmall,
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _actions() {
    switch (_phase) {
      case _PurgePhase.loading:
        return <Widget>[
          const TextButton(onPressed: null, child: Text('Plus tard')),
        ];
      case _PurgePhase.preview:
      case _PurgePhase.applying:
        final bool applying = _phase == _PurgePhase.applying;
        final int pending = _preview?.pending ?? 0;
        return <Widget>[
          TextButton(
            key: const Key('moderation-purge-later'),
            onPressed: applying ? null : () => Navigator.of(context).pop(),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            key: const Key('moderation-purge-apply'),
            style: FilledButton.styleFrom(
              backgroundColor: ModerationColors.danger,
            ),
            onPressed: applying || pending == 0 ? null : _apply,
            child: applying
                ? kButtonSpinner
                : Text(
                    pending == 0
                        ? 'Rien à purger'
                        : 'Rejeter $pending suggestion(s)',
                  ),
          ),
        ];
      case _PurgePhase.done:
        return <Widget>[
          FilledButton(
            key: const Key('moderation-purge-close'),
            onPressed: () => Navigator.of(context).pop(_result),
            child: const Text('Fermer'),
          ),
        ];
      case _PurgePhase.error:
        final Future<void> Function()? retry = _retry;
        return <Widget>[
          if (retry != null)
            OutlinedButton(
              key: const Key('moderation-purge-retry'),
              onPressed: retry,
              child: const Text('Réessayer'),
            ),
          FilledButton(
            key: const Key('moderation-purge-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ];
    }
  }
}
