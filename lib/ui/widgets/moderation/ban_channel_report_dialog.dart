// Rapport affiché après `channels/ban` (P4b-3, lot L8, T10, S-02, C-09,
// conception §6.12), selon `report.result` :
// - `applied` : « 🚫 <label> bannie », suggestions en file rejetées,
//   contenus déjà publiés (révélés, non cliquables) et
//   `UnpublishPublishedSection` (confirmation ROUGE avant toute suppression,
//   bilan renvoyé par le serveur) ;
// - `updated` : « <label> : bannissement mis à jour » + « Motif et
//   catégorie remplacés. » + le même rapport ;
// - `auto_en_revue` : « Chaîne déjà bannie automatiquement » + texte neutre
//   (intention manuelle enregistrée, rien purgé) ; AUCUN bouton « Retirer
//   aussi… » (`unpublish-by-channel` refuse un handle `auto:…`).
//
// 401 pendant le retrait : le dialogue se FERME puis appelle [onAuthError]
// (l'appelant ferme le panneau et déconnecte, S-08) — la déconnexion a lieu
// dans tous les cas, même si le rapport n'est plus affiché.
//
// Revue P4b-3 (ARC-02) : pendant le retrait des contenus publiés (requête
// DESTRUCTIVE), le rapport ne peut pas être fermé (« Fermer » désactivé,
// `PopScope`, barrière non cliquable) : le bilan du serveur est toujours
// montré et un 401 trouve toujours le rapport ouvert.
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../domain/banned_channels_rules.dart';
import '../../../domain/models/banned_channel.dart';
import 'moderation_ui.dart';
import 'unpublish_section.dart';

class BanChannelReportDialog extends StatefulWidget {
  const BanChannelReportDialog({
    super.key,
    required this.report,
    required this.unpublish,
    required this.onAuthError,
  });

  final BanChannelReport report;

  /// `sync.unpublishByChannel(report.banned.handle)` (appelé seulement après
  /// la confirmation rouge de la section).
  final Future<UnpublishResult> Function() unpublish;

  /// 401 : appelé APRÈS la fermeture du dialogue.
  final VoidCallback onAuthError;

  static Future<void> show(
    BuildContext context, {
    required BanChannelReport report,
    required Future<UnpublishResult> Function() unpublish,
    required VoidCallback onAuthError,
  }) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BanChannelReportDialog(
      report: report,
      unpublish: unpublish,
      onAuthError: onAuthError,
    ),
  );

  @override
  State<BanChannelReportDialog> createState() => _BanChannelReportDialogState();
}

class _BanChannelReportDialogState extends State<BanChannelReportDialog> {
  /// Retrait des contenus publiés en cours : fermeture impossible (ARC-02).
  bool _running = false;

  BanChannelReport get report => widget.report;

  void _onRunningChanged(bool running) {
    if (mounted && running != _running) setState(() => _running = running);
  }

  /// 401 pendant le retrait : fermer le rapport s'il est encore affiché
  /// (S-08), puis déconnecter DANS TOUS LES CAS.
  void _onAuthError() {
    if (mounted) Navigator.of(context).pop();
    widget.onAuthError();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BanReportKind kind = banReportKind(report.result);
    return PopScope(canPop: !_running, child: _dialog(context, theme, kind));
  }

  Widget _dialog(BuildContext context, ThemeData theme, BanReportKind kind) {
    return AlertDialog(
      title: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          banReportTitle(kind, report.banned.displayLabel),
          key: const Key('ban-channel-report-title'),
        ),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: kind == BanReportKind.autoInReview
                ? <Widget>[
                    Text(
                      banReportAutoText(report.banned.status),
                      key: const Key('ban-channel-report-auto'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ]
                : _manualReport(context, theme, kind),
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          key: const Key('ban-channel-report-close'),
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  List<Widget> _manualReport(
    BuildContext context,
    ThemeData theme,
    BanReportKind kind,
  ) {
    final List<Map<String, dynamic>> published = report.published;
    return <Widget>[
      if (kind == BanReportKind.updated) ...<Widget>[
        Text(
          kBanReportUpdatedText,
          key: const Key('ban-channel-report-updated'),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
      ],
      Text(
        banReportPurgedText(report.purged),
        key: const Key('ban-channel-report-purged'),
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: 6),
      Text(kBotsSyncNotice, style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      if (banReportOffersUnpublish(kind, published.length))
        Container(
          key: const Key('ban-channel-report-published'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                banReportPublishedHeader(published.length),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              for (final Map<String, dynamic> c in published.take(
                kBanReportPublishedShown,
              ))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: UntrustedLine(
                    '• ${publishedItemLabel(c)}',
                    max: 122,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (published.length > kBanReportPublishedShown)
                Text(
                  banReportMoreText(
                    published.length - kBanReportPublishedShown,
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              UnpublishPublishedSection(
                count: published.length,
                channelLabel: report.banned.displayLabel,
                unpublish: widget.unpublish,
                onRunningChanged: _onRunningChanged,
                // S-08 : fermer le rapport AVANT la déconnexion.
                onAuthError: _onAuthError,
              ),
            ],
          ),
        )
      else
        Text(
          kBanReportNoPublishedText,
          key: const Key('ban-channel-report-none'),
          style: theme.textTheme.bodySmall,
        ),
    ];
  }
}
