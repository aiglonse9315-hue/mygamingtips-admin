// Panneau des chaînes bannies — briques de PRÉSENTATION (P4b-3, lot L8, T10,
// conception §6.12) : formulaire de ban (URL / handle, nom affiché,
// « Catégorie » (4, D4), « Motif * » 1-500 points de code), tableau
// (Chaîne · Plateforme · État · Catégorie · Motif · Date · Par · Actions,
// aucune ligne cliquable) et traduction d'un déban de chaîne en
// `UnbanOutcome`.
//
// Widgets « de présentation » (aucun Provider, aucun StoreController) →
// testables en VM ; la colle (appels serveur, dialogues, SnackBars, 401) est
// dans `banned_channels_panel.dart`.
//
// Texte non fiable (clé de chaîne, nom affiché, motif, auteur) : révélé
// (`oneLinePreview` / `revealInvisibles`), écrit de gauche à droite, rogné,
// jamais un lien.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show
        AdminApiException,
        AdminAuthException,
        AdminForbiddenException,
        errorText;
import '../../../domain/banned_channels_rules.dart';
import '../../../domain/models/ban_category.dart';
import '../../../domain/models/banned_channel.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_text.dart';
import '../../screens/moderation/moderation_common.dart'
    show ModerationColumn, ModerationTable;
import 'account_ban_widgets.dart' show kAutoBanReservedTooltip;
import 'ban_category_dropdown.dart';
import 'moderation_ui.dart';
import 'reason_field.dart';
import 'status_badges.dart';

// ── Déban ────────────────────────────────────────────────────────────────────

/// Appelle [unban] (`sync.unbanChannel(id)`) et traduit la réponse :
/// `lifted` / `not_found` (rejeu signalé, INF-01) ; 409
/// `auto_ban_use_review` → ban automatique
/// (événement du corps) ; 401 → session expirée (l'appelant ferme puis
/// déconnecte, S-08) ; 403 et autres erreurs → échec avec le message du
/// serveur (le dialogue de confirmation reste ouvert).
Future<UnbanOutcome> runChannelUnban(
  Future<({String result, bool replayed})> Function() unban,
) async {
  try {
    final ({String result, bool replayed}) r = await unban();
    return unbanOutcomeFromResult(r.result, replayed: r.replayed);
  } on AdminAuthException {
    return const UnbanOutcome(UnbanKind.sessionExpired);
  } on AdminForbiddenException catch (e) {
    return UnbanOutcome(UnbanKind.failure, message: e.message);
  } on AdminApiException catch (e) {
    return unbanOutcomeFromError(
      statusCode: e.statusCode,
      result: e.result,
      banEventId: e.banEventId,
      message: e.message,
    );
  } catch (e) {
    return UnbanOutcome(UnbanKind.failure, message: errorText(e));
  }
}

// ── Formulaire ───────────────────────────────────────────────────────────────

/// Demande de ban d'une chaîne (champs déjà contrôlés).
@immutable
class ChannelBanRequest {
  const ChannelBanRequest({
    required this.handleOrUrl,
    required this.reason,
    this.displayName,
    required this.category,
  });

  /// URL ou handle, coupé (normalisé par le serveur).
  final String handleOrUrl;

  /// Motif coupé (1 à 500 points de code).
  final String reason;

  /// Nom affiché coupé, null s'il est vide.
  final String? displayName;

  /// Code de catégorie proposé au ban manuel (D4).
  final String category;
}

/// Formulaire « Bannir une chaîne » : URL / handle *, nom affiché
/// (optionnel), « Catégorie » (entre le nom et le motif), « Motif * ».
/// [submit] rend null en cas de succès (champs vidés, catégorie remise à
/// « Modération ») ou le message à afficher sous le formulaire.
class ChannelBanForm extends StatefulWidget {
  const ChannelBanForm({
    super.key,
    required this.categories,
    required this.submit,
  });

  /// Catégories connues (réponse serveur ou repli), filtrées par la liste
  /// déroulante (D4 : jamais « Injection IA »).
  final List<BanCategory> categories;
  final Future<String?> Function(ChannelBanRequest request) submit;

  @override
  State<ChannelBanForm> createState() => _ChannelBanFormState();
}

class _ChannelBanFormState extends State<ChannelBanForm> {
  final TextEditingController _handle = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  String _category = kDefaultManualBanCategory;

  /// Change à chaque remise à zéro (la liste déroulante repart du défaut).
  int _resetSeq = 0;
  bool _banning = false;
  String? _error;

  @override
  void dispose() {
    _handle.dispose();
    _name.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_banning) return;
    final String handle = _handle.text.trim();
    final String rawReason = _reason.text;
    final String? invalid = channelBanFormError(handle, rawReason);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final String name = _name.text.trim();
    setState(() {
      _banning = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.submit(
        ChannelBanRequest(
          handleOrUrl: handle,
          reason: normalizeReviewReason(rawReason) ?? rawReason.trim(),
          displayName: name.isEmpty ? null : name,
          category: effectiveBanCategory(widget.categories, _category),
        ),
      );
    } catch (e) {
      error = errorText(e);
    }
    if (!mounted) return;
    setState(() {
      _banning = false;
      _error = error;
      if (error == null) {
        _handle.clear();
        _name.clear();
        _reason.clear();
        _category = kDefaultManualBanCategory;
        _resetSeq++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? error = _error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ModerationColors.danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ModerationColors.danger.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('ban-channel-handle'),
                  controller: _handle,
                  enabled: !_banning,
                  decoration: const InputDecoration(
                    labelText: 'URL ou handle de la chaîne *',
                    hintText: 'https://youtube.com/@xxx ou @xxx',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('ban-channel-name'),
                  controller: _name,
                  enabled: !_banning,
                  decoration: const InputDecoration(
                    labelText: 'Nom affiché (optionnel)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: BanCategoryDropdown(
                  key: ValueKey<int>(_resetSeq),
                  categories: widget.categories,
                  value: _category,
                  enabled: !_banning,
                  onChanged: (String v) => setState(() => _category = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: ReasonField(
                  controller: _reason,
                  required: true,
                  enabled: !_banning,
                  maxLines: 2,
                  fieldKey: const Key('ban-channel-reason'),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: FilledButton.icon(
                  key: const Key('ban-channel-submit'),
                  style: FilledButton.styleFrom(
                    backgroundColor: ModerationColors.danger,
                  ),
                  onPressed: _banning ? null : _submit,
                  icon: _banning
                      ? kButtonSpinner
                      : const Icon(Icons.block_rounded, size: 18),
                  label: const Text('Bannir'),
                ),
              ),
            ],
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              error,
              key: const Key('ban-channel-error'),
              style: const TextStyle(
                fontSize: 12,
                color: ModerationColors.danger,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Tableau ──────────────────────────────────────────────────────────────────

/// Tableau des chaînes bannies (§6.12), sans ligne cliquable. Clés :
/// `ban-channel-row-<id>`, `ban-channel-<id>-unban`,
/// `ban-channel-<id>-<action>` (detail, confirm, lift, purge).
class BannedChannelsTable extends StatelessWidget {
  const BannedChannelsTable({
    super.key,
    required this.channels,
    required this.isOwner,
    this.busyIds = const <int>{},
    this.categories = const <BanCategory>[],
    required this.onUnban,
    required this.onAction,
    this.minWidth = 1000,
  });

  final List<BannedChannel> channels;

  /// Statut « compte principal » de l'interface (T15).
  final bool isOwner;

  /// Lignes dont une action est en cours (boutons désactivés + indicateur).
  final Set<int> busyIds;

  /// Catégories connues (libellé de la catégorie).
  final List<BanCategory> categories;
  final void Function(BannedChannel channel) onUnban;
  final void Function(BannedChannel channel, ReviewAction action) onAction;
  final double minWidth;

  static const List<int> _flex = <int>[5, 2, 4, 3, 4, 3, 2, 7];

  @override
  Widget build(BuildContext context) {
    final TextStyle small =
        Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12);
    return ModerationTable(
      key: const Key('ban-channel-table'),
      minWidth: minWidth,
      columns: <ModerationColumn>[
        for (int i = 0; i < kBannedChannelColumns.length; i++)
          ModerationColumn(kBannedChannelColumns[i], flex: _flex[i]),
      ],
      rowKeys: <Key>[
        for (final BannedChannel c in channels)
          ValueKey<String>('ban-channel-row-${c.id}'),
      ],
      rows: <List<Widget>>[
        for (final BannedChannel c in channels) _row(c, small),
      ],
    );
  }

  List<Widget> _row(BannedChannel c, TextStyle small) {
    final bool busy = busyIds.contains(c.id);
    final String? name = c.displayName;
    return <Widget>[
      Tooltip(
        message: channelCellTooltip(c),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            UntrustedLine(
              c.displayLabel,
              key: ValueKey<String>('ban-channel-label-${c.id}'),
              max: 80,
              monospace: isChannelKeyRow(c),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (name != null && name.trim().isNotEmpty)
              UntrustedLine(name.trim(), max: 60, style: small),
          ],
        ),
      ),
      Text(channelPlatformLabel(c), style: small),
      Wrap(
        spacing: 4,
        runSpacing: 4,
        children: <Widget>[
          BanOriginBadge(
            key: ValueKey<String>('ban-channel-state-${c.id}'),
            status: channelStateStatus(c),
            label: channelStateLabel(c),
          ),
          if (c.hasManualIntent)
            ManualPresentBadge(
              key: ValueKey<String>('ban-channel-intent-${c.id}'),
              label: kManualIntentLabel,
              tooltip: kManualIntentTooltip,
            ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: CategoryChip(code: c.category, known: categories),
      ),
      _reasonCell(c, small),
      Text(formatModerationDate(c.createdAt), style: small),
      UntrustedLine(c.bannedBy ?? '—', max: 40, style: small),
      _actions(c, busy),
    ];
  }

  /// « Motif » : l'état pour une ligne AUTO ; sinon le motif révélé (une
  /// ligne) avec le motif complet révélé en infobulle.
  Widget _reasonCell(BannedChannel c, TextStyle small) {
    final Key key = ValueKey<String>('ban-channel-reason-${c.id}');
    if (c.isAuto) return Text(channelReasonText(c), key: key, style: small);
    final Widget line = UntrustedLine(
      channelReasonText(c),
      key: key,
      max: 80,
      style: small,
    );
    final String? reason = c.reason;
    if (reason == null || reason.trim().isEmpty) return line;
    return Tooltip(
      message: revealInvisibles(reason, maxUnits: 1024).text,
      child: line,
    );
  }

  Widget _actions(BannedChannel c, bool busy) {
    final ChannelRowControl control = channelRowControl(c, isOwner: isOwner);
    switch (control.action) {
      case ChannelRowAction.unban:
        return Align(
          alignment: Alignment.centerLeft,
          child: busy
              ? kButtonSpinner
              : IconButton(
                  key: ValueKey<String>('ban-channel-${c.id}-unban'),
                  tooltip: 'Débannir cette chaîne',
                  onPressed: () => onUnban(c),
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  color: ModerationColors.danger,
                ),
        );
      case ChannelRowAction.reservedToOwner:
        return Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: ValueKey<String>('ban-channel-${c.id}-unban'),
            tooltip: kAutoBanReservedTooltip,
            onPressed: null,
            icon: const Icon(Icons.undo_rounded, size: 18),
          ),
        );
      case ChannelRowAction.review:
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final ReviewAction a in control.actions)
              reviewActionButton(
                a,
                key: ValueKey<String>('ban-channel-${c.id}-${a.name}'),
                onPressed: busy ? null : () => onAction(c, a),
              ),
            if (busy) kButtonSpinner,
          ],
        );
    }
  }
}
