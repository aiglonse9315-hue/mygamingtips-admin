// Confirmation FORTE (P4b-3, lot L5, S-01, UX-01, conception §6.6, §6.9) :
// titre, texte, contenu supplémentaire (compteurs, avertissement, lien
// d'événement), case OBLIGATOIRE, bouton d'action DÉSACTIVÉ tant que la case
// n'est pas cochée, « Annuler » par défaut. Rend `true` SEULEMENT si la case
// est cochée puis le bouton pressé ; `false` sinon (Annuler, Échap, clic
// hors du dialogue). Utilisée pour « Allumer » ET « Réarmer » le ban
// automatique (même corps envoyé : `{auto_ban_enabled: true}`).
//
// Motif : `DeletePlusUserDialog` (delete_plus_user_dialog.dart).
//
// Widgets « de présentation » (aucun Provider) → testables en VM. Clés :
// `moderation-strong-checkbox`, `moderation-strong-confirm`,
// `moderation-strong-cancel`.
import 'package:flutter/material.dart';

import '../../../domain/moderation_actions.dart';
import 'moderation_ui.dart';

class StrongConfirmDialog extends StatefulWidget {
  const StrongConfirmDialog({
    super.key,
    required this.title,
    required this.text,
    this.extra = const <Widget>[],
    required this.checkboxLabel,
    required this.confirmLabel,
    this.confirmColor,
  });

  final String title;
  final String text;

  /// Contenu sous le texte (compteurs, avertissement, lien d'événement).
  final List<Widget> extra;
  final String checkboxLabel;
  final String confirmLabel;

  /// Couleur du bouton (ex. orange pour « Réarmer »).
  final Color? confirmColor;

  /// Ouvre le dialogue ; `true` seulement si la case a été cochée puis le
  /// bouton pressé.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String text,
    List<Widget> extra = const <Widget>[],
    required String checkboxLabel,
    required String confirmLabel,
    Color? confirmColor,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (_) => StrongConfirmDialog(
        title: title,
        text: text,
        extra: extra,
        checkboxLabel: checkboxLabel,
        confirmLabel: confirmLabel,
        confirmColor: confirmColor,
      ),
    );
    return ok == true;
  }

  @override
  State<StrongConfirmDialog> createState() => _StrongConfirmDialogState();
}

class _StrongConfirmDialogState extends State<StrongConfirmDialog> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(widget.text),
              if (widget.extra.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                ...widget.extra,
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('moderation-strong-checkbox'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _checked,
                onChanged: (bool? v) => setState(() => _checked = v ?? false),
                title: Text(widget.checkboxLabel),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('moderation-strong-cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('moderation-strong-confirm'),
          style: FilledButton.styleFrom(backgroundColor: widget.confirmColor),
          onPressed: _checked ? () => Navigator.of(context).pop(true) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Compteurs des bans automatiques et avertissement si un plafond est DÉJÀ
/// atteint (`rearmWarning`) : les compteurs ne sont pas remis à zéro, le
/// disjoncteur se redéclencherait au prochain ban éligible (UX-01). À passer
/// dans [StrongConfirmDialog.extra] pour « Allumer » et « Réarmer ».
class AutoBanCountersNotice extends StatelessWidget {
  const AutoBanCountersNotice({
    super.key,
    required this.hour,
    required this.maxHour,
    required this.day,
    required this.maxDay,
  });

  final int hour;
  final int maxHour;
  final int day;
  final int maxDay;

  @override
  Widget build(BuildContext context) {
    final ({String counters, String? warning}) w = rearmWarning(
      hour: hour,
      maxHour: maxHour,
      day: day,
      maxDay: maxDay,
    );
    final String? warning = w.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Bans automatiques : ${w.counters}',
          key: const Key('moderation-counters'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (warning != null) ...<Widget>[
          const SizedBox(height: 8),
          ModerationNotice(
            key: const Key('moderation-ceiling-warning'),
            text: warning,
            color: ModerationColors.warning,
            icon: Icons.warning_amber_rounded,
          ),
        ],
      ],
    );
  }
}
