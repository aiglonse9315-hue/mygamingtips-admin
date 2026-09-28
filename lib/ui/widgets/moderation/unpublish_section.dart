// « Retirer aussi ces N contenus publiés » du rapport de ban d'une chaîne
// (P4b-3, lot L5, S-02, conception §6.9, §6.12).
//
// Avant P4b-3, un seul clic SUPPRIMAIT les contenus (route
// `contents/unpublish-by-channel`, suppression définitive). Désormais un
// clic ouvre D'ABORD une confirmation ROUGE (« Annuler » / « Supprimer ») qui
// rappelle que la liste est RECALCULÉE par le serveur (rapprochement par nom
// ou identifiant de la chaîne : des homonymes peuvent être concernés) ; le
// bilan affiché est celui RENVOYÉ par le serveur (`deleted` + `removed`,
// titres / URL révélés, non cliquables) ; rejeu à 0 → message de rejeu.
//
// 401 : la section appelle [onAuthError] ; l'appelant (le dialogue de
// rapport) y ferme son dialogue puis déconnecte (S-08).
//
// [onRunningChanged] (revue P4b-3, ARC-02) : signale le début et la fin du
// retrait (requête destructive) — le dialogue de rapport ne peut pas être
// fermé pendant ce temps.
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart' show AdminAuthException, errorText;
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_text.dart';
import '../confirm_dialog.dart';
import 'moderation_ui.dart';

/// Réponse de `contents/unpublish-by-channel` (= `SupabaseSync.unpublishByChannel`).
typedef UnpublishResult = ({
  int deleted,
  List<Map<String, dynamic>> removed,
  bool replayed,
});

/// Titre de la confirmation rouge.
String unpublishConfirmTitle(int count) =>
    'Supprimer définitivement $count contenu(s) publié(s) ?';

/// Texte de la confirmation rouge.
const String kUnpublishConfirmMessage =
    'Action irréversible. La liste est RECALCULÉE par le serveur au moment de '
    "la suppression (rapprochement par le nom ou l'identifiant de la chaîne : "
    'des homonymes peuvent être concernés, et le nombre réel peut différer de '
    'la liste affichée).';

class UnpublishPublishedSection extends StatefulWidget {
  const UnpublishPublishedSection({
    super.key,
    required this.count,
    required this.channelLabel,
    required this.unpublish,
    required this.onAuthError,
    this.onRunningChanged,
  });

  /// Nombre de contenus publiés AFFICHÉS dans le rapport.
  final int count;

  /// Libellé de la chaîne (révélé).
  final String channelLabel;
  final Future<UnpublishResult> Function() unpublish;

  /// 401 (l'appelant ferme son dialogue puis déconnecte).
  final VoidCallback onAuthError;

  /// Retrait en cours (vrai) / terminé (faux), quelle que soit l'issue.
  final ValueChanged<bool>? onRunningChanged;

  @override
  State<UnpublishPublishedSection> createState() =>
      _UnpublishPublishedSectionState();
}

class _UnpublishPublishedSectionState extends State<UnpublishPublishedSection> {
  bool _running = false;
  UnpublishResult? _result;
  String? _error;

  Future<void> _onPressed() async {
    if (_running) return;
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: unpublishConfirmTitle(widget.count),
        message: kUnpublishConfirmMessage,
        confirmLabel: 'Supprimer',
        destructive: true,
        onConfirm: () => confirmed = true,
      ),
    );
    if (!confirmed || !mounted) return;
    // Rappels lus AVANT l'attente (appelés même si la section a disparu).
    final VoidCallback onAuthError = widget.onAuthError;
    final ValueChanged<bool>? onRunning = widget.onRunningChanged;
    setState(() {
      _running = true;
      _error = null;
    });
    onRunning?.call(true);
    try {
      final UnpublishResult r = await widget.unpublish();
      onRunning?.call(false);
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = r;
      });
    } on AdminAuthException {
      onRunning?.call(false);
      if (mounted) setState(() => _running = false);
      onAuthError();
    } catch (e) {
      onRunning?.call(false);
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = errorText(e);
      });
    }
  }

  static String _itemLabel(Map<String, dynamic> m) {
    final Object? title = m['title'];
    final Object? url = m['url'];
    final Object? id = m['id'];
    if (title is String && title.isNotEmpty) return title;
    if (url is String && url.isNotEmpty) return url;
    return id?.toString() ?? '—';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UnpublishResult? r = _result;
    if (r != null) {
      final String text =
          replayNotice(replayed: r.replayed, count: r.deleted) ??
          '✅ ${r.deleted} contenu(s) publié(s) retiré(s) de '
              '${oneLinePreview(widget.channelLabel, max: 60)}.';
      final double height = (r.removed.length * 22.0).clamp(0.0, 220.0);
      return Column(
        key: const Key('moderation-unpublish-result'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            text,
            key: const Key('moderation-unpublish-summary'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: ModerationColors.success,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (r.removed.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            SizedBox(
              height: height,
              child: ListView.builder(
                itemCount: r.removed.length,
                itemExtent: 22,
                itemBuilder: (BuildContext context, int i) => UntrustedLine(
                  '• ${_itemLabel(r.removed[i])}',
                  max: 122,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FilledButton.icon(
          key: const Key('moderation-unpublish-button'),
          style: FilledButton.styleFrom(
            backgroundColor: ModerationColors.danger,
          ),
          onPressed: _running ? null : _onPressed,
          icon: _running
              ? kButtonSpinner
              : const Icon(Icons.delete_outline_rounded, size: 18),
          label: Text('Retirer aussi ces ${widget.count} contenus publiés'),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            _error!,
            key: const Key('moderation-unpublish-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}
