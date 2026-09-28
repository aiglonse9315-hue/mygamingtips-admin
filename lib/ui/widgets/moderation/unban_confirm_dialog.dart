// « Débannir <nom> ? » — levée d'un ban MANUEL (compte ou chaîne ; P4b-3,
// lot L5, T3, T10, conception §6.11, §6.12, §6.9) : le texte dit que les
// partages ANTÉRIEURS à la levée seront exemptés du bannissement
// automatique ; « Annuler » / « Débannir ».
//
// Attend `submit()` (NON optimiste : `store.unbanAccount(id)` ou le déban
// d'une chaîne) qui rend un `UnbanOutcome` :
// - levé / n'était plus banni / introuvable / ban AUTOMATIQUE (409, liste
//   périmée) → ferme en rendant l'issue (l'écran affiche `unbanMessage` ou
//   ouvre la levée d'un ban automatique) ;
// - échec → message DANS le dialogue, qui reste ouvert ;
// - session expirée (401 déjà traité) → ferme (S-08).
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart' show errorText;
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_text.dart';
import 'moderation_ui.dart';

/// Texte du déban d'un COMPTE.
const String kUnbanAccountMessage =
    'Le compte pourra de nouveau partager des contenus. Ses partages '
    'ANTÉRIEURS à cette levée seront exemptés du bannissement automatique.';

/// Texte du déban d'une CHAÎNE.
const String kUnbanChannelMessage =
    'Les bots pourront de nouveau la proposer. Les suggestions déjà rejetées '
    'ne sont pas restaurées. Ses partages antérieurs seront exemptés du '
    'bannissement automatique.';

class UnbanConfirmDialog extends StatefulWidget {
  const UnbanConfirmDialog({
    super.key,
    required this.name,
    this.channel = false,
    required this.submit,
  });

  /// Nom du compte ou libellé de la chaîne (révélé, 60 points de code).
  final String name;
  final bool channel;
  final Future<UnbanOutcome> Function() submit;

  /// Ouvre le dialogue ; rend l'issue (null si annulé).
  static Future<UnbanOutcome?> show(
    BuildContext context, {
    required String name,
    bool channel = false,
    required Future<UnbanOutcome> Function() submit,
  }) => showDialog<UnbanOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        UnbanConfirmDialog(name: name, channel: channel, submit: submit),
  );

  @override
  State<UnbanConfirmDialog> createState() => _UnbanConfirmDialogState();
}

class _UnbanConfirmDialogState extends State<UnbanConfirmDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final UnbanOutcome o = await widget.submit();
      if (!mounted) return;
      if (o.kind == UnbanKind.failure) {
        setState(() {
          _saving = false;
          _error = unbanMessage(
            o,
            name: oneLinePreview(widget.name, max: 60),
            channel: widget.channel,
          );
        });
        return;
      }
      Navigator.of(context).pop(o);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String name = oneLinePreview(widget.name, max: 60);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('Débannir $name ?'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.channel ? kUnbanChannelMessage : kUnbanAccountMessage,
                key: const Key('ban-unban-message'),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const Key('ban-unban-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('ban-unban-cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('ban-unban-submit'),
            onPressed: _saving ? null : _submit,
            child: _saving ? kButtonSpinner : const Text('Débannir'),
          ),
        ],
      ),
    );
  }
}
