// « Activer les jeux prêts » (P4b-3, lot L5, D2, T7, EF-02, conception
// §6.13, §6.9) : aperçu (une case par jeu, TOUTES cochées par défaut, au
// plus 500), « Tout cocher » / « Tout décocher », confirmation, appel
// `apply(ids)`, bilan (activés, ignorés avec leur raison, rejeu).
//
// Le serveur accepte 1 à 500 ids par activation alors que l'aperçu n'est
// pas borné : au-delà de 500 jeux prêts, seuls les 500 PREMIERS sont cochés
// et le message de `readySelectionError` explique la limite ; « Activer »
// reste désactivé tant que la sélection n'est pas envoyable (0 ou > 500).
//
// Erreurs : 401 → fermeture + `onAuthError` ; 403 → « Réservé au compte
// principal. » ; autre → message du serveur tel quel (le bouton reste
// disponible : l'activation est idempotente côté serveur, un jeu déjà
// actif est ignoré).
//
// Widget « de présentation » (aucun Provider) → testable en VM. Clés :
// `games-ready-<id>` (cases), `games-ready-apply`, `games-ready-all`,
// `games-ready-none`, `games-ready-close`.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, errorText;
import '../../../domain/game_patch.dart';
import '../../../domain/ids.dart';
import '../../../domain/models/ready_games.dart';
import '../../../domain/moderation_labels.dart';
import '../moderation/moderation_ui.dart';

/// Message d'un aperçu vide.
String noReadyGamesText(ReadyGamesPreview p) =>
    'Aucun jeu prêt : ${p.inactiveTotal} jeu(x) inactif(s), seuil : '
    '${p.threshold} contenus validés.';

/// Message quand, après un rejeu, tous les jeux étaient déjà actifs.
const String kReadyGamesAllAlreadyActive =
    'Tous les jeux étaient déjà actifs (activation probablement faite au '
    'premier essai).';

/// Rappel affiché quand l'aperçu compte plus de 500 jeux prêts et que la
/// sélection est envoyable (les 500 premiers sont cochés par défaut).
const String kReadyGamesOverLimitNotice =
    '$kActivateReadyMax jeux au plus par activation (limite du serveur) : seuls '
    'les $kActivateReadyMax premiers sont cochés ; relancez « Activer les jeux '
    'prêts » pour les suivants.';

/// Ligne d'un jeu de l'aperçu.
String readyGameLine(ReadyGame g) =>
    '${g.name} — ${g.validatedTotal} contenus '
    '(V ${g.video} · G ${g.guides} · L ${g.links})';

class ReadyGamesDialog extends StatefulWidget {
  const ReadyGamesDialog({
    super.key,
    required this.preview,
    required this.apply,
    required this.onAuthError,
  });

  final ReadyGamesPreview preview;

  /// `store.activateReadyGames(ids)`.
  final Future<ActivateReadyResult> Function(List<String> ids) apply;

  /// 401 : appelé APRÈS la fermeture.
  final VoidCallback onAuthError;

  /// Ouvre le dialogue ; rend le bilan (null si annulé ou erreur).
  static Future<ActivateReadyResult?> show(
    BuildContext context, {
    required ReadyGamesPreview preview,
    required Future<ActivateReadyResult> Function(List<String> ids) apply,
    required VoidCallback onAuthError,
  }) => showDialog<ActivateReadyResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ReadyGamesDialog(
      preview: preview,
      apply: apply,
      onAuthError: onAuthError,
    ),
  );

  @override
  State<ReadyGamesDialog> createState() => _ReadyGamesDialogState();
}

class _ReadyGamesDialogState extends State<ReadyGamesDialog> {
  late final Set<String> _selected;
  bool _applying = false;
  String? _error;
  ActivateReadyResult? _result;

  @override
  void initState() {
    super.initState();
    _selected = <String>{
      for (final ReadyGame g in widget.preview.games.take(kActivateReadyMax))
        g.id,
    };
  }

  /// Ids cochés, dans l'ordre de l'aperçu.
  List<String> get _ids => <String>[
    for (final ReadyGame g in widget.preview.games)
      if (_selected.contains(g.id)) g.id,
  ];

  Future<void> _activate() async {
    final List<String> ids = _ids;
    if (_applying || readySelectionError(ids.length) != null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('Activer ${ids.length} jeu(x) ?'),
        content: const Text("Ils deviendront visibles dans l'application."),
        actions: <Widget>[
          TextButton(
            key: const Key('games-ready-confirm-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('games-ready-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Activer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final ActivateReadyResult r = await widget.apply(ids);
      if (!mounted) return;
      setState(() {
        _applying = false;
        _result = r;
      });
    } on AdminAuthException {
      if (mounted) Navigator.of(context).pop();
      widget.onAuthError();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = e is AdminForbiddenException
            ? 'Réservé au compte principal.'
            : errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReadyGamesPreview p = widget.preview;
    final ActivateReadyResult? r = _result;
    final Widget body;
    final List<Widget> actions;
    if (r != null) {
      body = _report(context, r);
      actions = <Widget>[
        FilledButton(
          key: const Key('games-ready-close'),
          onPressed: () => Navigator.of(context).pop(r),
          child: const Text('Fermer'),
        ),
      ];
    } else if (p.games.isEmpty) {
      body = Text(noReadyGamesText(p), key: const Key('games-ready-empty'));
      actions = <Widget>[
        FilledButton(
          key: const Key('games-ready-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ];
    } else {
      body = _selection(context);
      final int n = _selected.length;
      final bool canApply = !_applying && readySelectionError(n) == null;
      actions = <Widget>[
        TextButton(
          key: const Key('games-ready-cancel'),
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('games-ready-apply'),
          onPressed: canApply ? _activate : null,
          child: _applying ? kButtonSpinner : Text('Activer $n jeu(x)'),
        ),
      ];
    }
    return PopScope(
      canPop: !_applying,
      child: AlertDialog(
        title: Text(
          'Jeux prêts à activer (seuil : ${p.threshold} contenus validés)',
        ),
        content: SizedBox(width: 600, child: body),
        actions: actions,
      ),
    );
  }

  Widget _selection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ReadyGame> games = widget.preview.games;
    // Sélection non envoyable (0 ou > 500) : message de readySelectionError ;
    // sinon, plus de 500 jeux prêts : rappel de la limite (les 500 premiers
    // sont cochés, une nouvelle ouverture traitera les suivants).
    final String? limit =
        readySelectionError(_selected.length) ??
        (games.length > kActivateReadyMax ? kReadyGamesOverLimitNotice : null);
    // Liste bornée par la hauteur de l'écran (le dialogue ne défile pas).
    final double maxList = (MediaQuery.sizeOf(context).height * 0.45).clamp(
      64.0,
      380.0,
    );
    final double height = (games.length * 64.0).clamp(64.0, maxList);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            TextButton(
              key: const Key('games-ready-all'),
              onPressed: _applying
                  ? null
                  : () => setState(() {
                      _selected
                        ..clear()
                        ..addAll(games.map((ReadyGame g) => g.id));
                    }),
              child: const Text('Tout cocher'),
            ),
            TextButton(
              key: const Key('games-ready-none'),
              onPressed: _applying ? null : () => setState(_selected.clear),
              child: const Text('Tout décocher'),
            ),
            const Spacer(),
            Text(
              '${_selected.length} / ${games.length} sélectionné(s)',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        if (limit != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            limit,
            key: const Key('games-ready-limit'),
            style: TextStyle(color: ModerationColors.warning, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 6),
        SizedBox(
          height: height,
          child: ListView.builder(
            itemCount: games.length,
            itemBuilder: (BuildContext context, int i) {
              final ReadyGame g = games[i];
              final int dup = g.validatedTotal - g.distinctUrls;
              return CheckboxListTile(
                key: ValueKey<String>('games-ready-${g.id}'),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(g.id),
                onChanged: _applying
                    ? null
                    : (bool? v) => setState(() {
                        if (v ?? false) {
                          _selected.add(g.id);
                        } else {
                          _selected.remove(g.id);
                        }
                      }),
                title: Text(
                  readyGameLine(g),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: g.hasDuplicateUrls
                    ? Text(
                        '$dup URL en double',
                        style: TextStyle(color: ModerationColors.warning),
                      )
                    : null,
              );
            },
          ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('games-ready-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _report(BuildContext context, ActivateReadyResult r) {
    final ThemeData theme = Theme.of(context);
    final Map<String, String> names = <String, String>{
      for (final ReadyGame g in widget.preview.games) g.id: g.name,
    };
    final bool allAlreadyActive =
        r.replayed &&
        r.activated.isEmpty &&
        r.skipped.isNotEmpty &&
        r.skipped.every((SkippedGame s) => s.reason == 'already_active');
    String nameOf(String id) {
      final String? n = names[id];
      return n != null && n.isNotEmpty ? n : shortId(id);
    }

    return SingleChildScrollView(
      child: Column(
        key: const Key('games-ready-report'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (allAlreadyActive)
            const Text(
              kReadyGamesAllAlreadyActive,
              key: Key('games-ready-replayed'),
              style: TextStyle(fontWeight: FontWeight.w700),
            )
          else ...<Widget>[
            Text(
              '${r.activated.length} jeu(x) activé(s)',
              key: const Key('games-ready-activated'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final ActivatedGame g in r.activated)
              Text(
                '• ${g.name.isNotEmpty ? g.name : shortId(g.id)}',
                style: theme.textTheme.bodySmall,
              ),
            if (r.skipped.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Ignoré(s) :',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              for (final SkippedGame s in r.skipped)
                Text(
                  '• ${nameOf(s.id)} : ${skippedGameLabel(s.reason)}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ],
      ),
    );
  }
}
