// Dialogue d'ajout / édition d'un jeu (P4b-3, lot L9, conception §6.13,
// T7, D2, v2 ARC-02 / REG-02 / REG-03). Sorti de `games_screen.dart` pour
// être testé en VM : il ne lit plus le StoreController, l'écran lui passe
// les écritures ([GameEditDialog.savePatch], [GameEditDialog.create]).
//
// - Champs : nom (`validateGameName`), éditeur, pochette, date
//   (`parseReleaseDateInput(..., original:)` : une date stockée non modifiée
//   n'est ni contrôlée ni envoyée ; une date invalide est une ERREUR du
//   champ, plus jamais un effacement silencieux), interrupteur « Actif ».
// - Enregistrer (édition) : validations → `buildGamePatch` → vide : fermeture
//   + « Aucune modification. » ; « Actif » décoché sur un jeu actif → MÊME
//   confirmation que la bascule AVANT l'envoi (Annuler = retour à l'édition,
//   rien envoyé) ; sinon envoi PARTIEL attendu (bouton en chargement),
//   dialogue OUVERT sur échec (message sous les champs), fermé sur succès ou
//   session expirée (la déconnexion est déjà faite par le contrôleur).
// - Ajouter : mêmes validations ; création lancée sans attendre (fermeture
//   immédiate, comme avant) ; « Actif » décoché → « <nom> créé INACTIF
//   (section « Jeux inactifs »). » (pas de confirmation : rien ne disparaît
//   de l'application).
//
// Le dialogue rend le message de la SnackBar à afficher par l'écran (null =
// aucun). Widget « de présentation » (aucun Provider). Clés : `games-edit-*`.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart' show errorText;
import '../../../domain/game_patch.dart';
import '../../../domain/games_screen_rules.dart';
import '../../../domain/models/game.dart';
import '../../../domain/write_outcome.dart';
import 'deactivate_game_dialog.dart';

/// Saisie d'une création (textes BRUTS pour l'éditeur et la pochette :
/// `StoreController.addGame` les coupe et met null pour un texte vide ; la
/// date est déjà normalisée `AAAA-MM-JJ` ou null).
typedef GameDraft = ({
  String name,
  String publisher,
  String coverUrl,
  String? releaseDate,
  bool active,
});

class GameEditDialog extends StatefulWidget {
  const GameEditDialog({
    super.key,
    this.game,
    required this.savePatch,
    required this.create,
    this.onOpenTranslations,
    this.now,
  });

  /// Jeu édité (null = création).
  final Game? game;

  /// `store.saveGamePatch(original, patch)` : envoi partiel attendu.
  final Future<WriteOutcome> Function(Game original, Map<String, Object?> patch)
  savePatch;

  /// `store.addGame(...)` : création (non attendue par le dialogue).
  final Future<void> Function(GameDraft draft) create;

  /// Ouvre les traductions du jeu (édition seulement) ; reçoit le jeu avec le
  /// nom actuellement saisi.
  final void Function(Game current)? onOpenTranslations;

  /// Date du jour pour la borne d'année (tests) ; null = maintenant.
  final DateTime? now;

  @override
  State<GameEditDialog> createState() => _GameEditDialogState();
}

class _GameEditDialogState extends State<GameEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _publisher;
  late final TextEditingController _cover;
  late final TextEditingController _releaseDate;
  bool _active = true;

  String? _nameError;
  String? _publisherError;
  String? _coverError;
  String? _dateError;

  /// Échec de l'envoi (message sous les champs).
  String? _error;

  /// Envoi en cours : champs et boutons désactivés, fermeture bloquée.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final Game? g = widget.game;
    _name = TextEditingController(text: g?.name ?? '');
    _publisher = TextEditingController(text: g?.publisher ?? '');
    _cover = TextEditingController(text: g?.coverUrl ?? '');
    _releaseDate = TextEditingController(text: g?.releaseDate ?? '');
    _active = g?.active ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _publisher.dispose();
    _cover.dispose();
    _releaseDate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final String? nameError = validateGameName(_name.text);
    final String? publisherError = validateGamePublisher(_publisher.text);
    final String? coverError = validateGameCover(_cover.text);
    final ReleaseDateInput date = parseReleaseDateInput(
      _releaseDate.text,
      now: widget.now,
      original: widget.game?.releaseDate,
    );
    setState(() {
      _nameError = nameError;
      _publisherError = publisherError;
      _coverError = coverError;
      _dateError = date.error;
      _error = null;
    });
    if (nameError != null ||
        publisherError != null ||
        coverError != null ||
        !date.isValid) {
      return;
    }

    final Game? original = widget.game;
    if (original == null) {
      final String name = _name.text.trim();
      unawaited(
        widget.create((
          name: name,
          publisher: _publisher.text,
          coverUrl: _cover.text,
          releaseDate: date.value,
          active: _active,
        )),
      );
      Navigator.of(
        context,
      ).pop(_active ? null : gameCreatedInactiveMessage(name));
      return;
    }

    final Map<String, Object?> patch = buildGamePatch(
      original,
      name: _name.text,
      publisher: _publisher.text,
      cover: _cover.text,
      releaseDate: date.value,
      active: _active,
    );
    if (patch.isEmpty) {
      Navigator.of(context).pop(kNoGameChangeMessage);
      return;
    }
    if (needsDeactivationConfirm(original, patch)) {
      final bool ok = await DeactivateGameDialog.confirm(
        context,
        original.name,
      );
      if (!ok || !mounted) return;
    }

    setState(() => _saving = true);
    WriteOutcome out;
    try {
      out = await widget.savePatch(original, patch);
    } catch (e) {
      // Le contrôleur ne lève pas ; garde-fou pour ne jamais rester bloqué.
      out = WriteOutcome.failed(errorText(e));
    }
    if (!mounted) return;
    if (out.ok || out.sessionExpired) {
      Navigator.of(context).pop(out.ok ? out.notice : null);
      return;
    }
    setState(() {
      _saving = false;
      _error = out.message ?? 'Jeu non modifié.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool edit = widget.game != null;
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(edit ? 'Modifier le jeu' : 'Ajouter un jeu'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const Key('games-edit-name'),
                        controller: _name,
                        enabled: !_saving,
                        onChanged: (_) {
                          if (_nameError != null) {
                            setState(() => _nameError = null);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: 'Nom du jeu *',
                          errorText: _nameError,
                        ),
                      ),
                    ),
                    // Traductions (12 langues) : édition seulement (un jeu
                    // existant a un id).
                    if (edit && widget.onOpenTranslations != null) ...<Widget>[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Traductions (12 langues)',
                        icon: const Icon(Icons.translate_rounded, size: 22),
                        onPressed: _saving
                            ? null
                            : () {
                                final Game g = widget.game!;
                                final String typed = _name.text.trim();
                                widget.onOpenTranslations!(
                                  g.copyWith(
                                    name: typed.isEmpty ? g.name : typed,
                                  ),
                                );
                              },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('games-edit-publisher'),
                  controller: _publisher,
                  enabled: !_saving,
                  onChanged: (_) {
                    if (_publisherError != null) {
                      setState(() => _publisherError = null);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Éditeur (optionnel)',
                    errorText: _publisherError,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('games-edit-cover'),
                  controller: _cover,
                  enabled: !_saving,
                  onChanged: (_) {
                    if (_coverError != null) {
                      setState(() => _coverError = null);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'URL de la pochette (optionnel)',
                    helperText: "Lien direct vers l'image",
                    errorText: _coverError,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('games-edit-date'),
                  controller: _releaseDate,
                  enabled: !_saving,
                  onChanged: (_) {
                    if (_dateError != null) {
                      setState(() => _dateError = null);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Date de sortie (optionnel)',
                    helperText:
                        'AAAA, AAAA-MM ou AAAA-MM-JJ — aide Sentinelle à '
                        'différencier les éditions homonymes (ex. CoD MW3 2011 '
                        'vs MW III 2023) : une vidéo plus ancienne que la date '
                        "est rattachée à l'édition précédente.",
                    helperMaxLines: 3,
                    errorText: _dateError,
                    errorMaxLines: 2,
                  ),
                  keyboardType: TextInputType.datetime,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  key: const Key('games-edit-active'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Jeu actif (visible dans l'app)"),
                  value: _active,
                  onChanged: _saving
                      ? null
                      : (bool v) => setState(() => _active = v),
                  activeThumbColor: theme.colorScheme.primary,
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const Key('games-edit-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('games-edit-cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('games-edit-save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(edit ? 'Enregistrer' : 'Ajouter'),
          ),
        ],
      ),
    );
  }
}
