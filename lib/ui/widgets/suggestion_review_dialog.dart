/// Dialogue de validation d'une suggestion (jeu, catégorie, titre admin),
/// partagé par les menus Suggestions et Sentinelle (« À vérifier » →
/// « Ajouter manuellement »).
///
/// Sorti de `ui/screens/suggestions_screen.dart` le 12/10/2026 (P5, lot L6),
/// code inchangé : cet écran importe `core/auth/auth_controller.dart`, qui
/// dépend de `dart:html` ; l'écran Sentinelle, qui n'a besoin que de ce
/// dialogue, se compile désormais dans la VM (`flutter test`).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/category.dart';
import '../../domain/models/game.dart';
import '../../domain/models/suggestion.dart';
import '../../state/store_controller.dart';

/// Dialog de validation d'une suggestion : choix du jeu + catégorie + titre admin.
class SuggestionReviewDialog extends StatefulWidget {
  const SuggestionReviewDialog({
    super.key,
    required this.suggestion,
    this.initialTitle,
    this.aliasCandidateChecked = false,
  });
  final Suggestion suggestion;

  /// Titre pour insertion déjà édité par l'admin en amont (colonne « Titre
  /// pour insertion » du tableau Sentinelle « À vérifier »). S'il est fourni
  /// et non vide après trim, il pré-remplit le champ titre à la place du
  /// titre calculé automatiquement.
  final String? initialTitle;

  /// D3.3/D3.4 — état de la case « Ajouter cet alias à la base à la
  /// validation » de la ligne Sentinelle (cochée par défaut). L'alias
  /// candidat n'est créé QUE si cette case est cochée et que le jeu choisi
  /// est celui du candidat.
  final bool aliasCandidateChecked;

  @override
  State<SuggestionReviewDialog> createState() =>
      _SuggestionReviewDialogState();
}

class _SuggestionReviewDialogState extends State<SuggestionReviewDialog> {
  String? _gameId;
  ContentCategory _category = ContentCategory.video;
  late final TextEditingController _title;
  late final TextEditingController _image;

  @override
  void initState() {
    super.initState();
    // Pré-remplissage intelligent du titre (par ordre de priorité) :
    // 0. Titre déjà édité par l'admin en amont ([initialTitle], colonne
    //    « Titre pour insertion » du tableau Sentinelle « À vérifier »).
    // 1. Titre réel YouTube (récupéré par Sentinelle via l'API YouTube).
    // 2. Texte partagé nettoyé (sans URL).
    // 3. URL brute.
    final ai = widget.suggestion.aiRecommendation;
    final provided = widget.initialTitle?.trim();
    String title = widget.suggestion.url;
    if (provided != null && provided.isNotEmpty) {
      title = provided;
    } else if (ai?.proposedTitle != null &&
        ai!.proposedTitle!.trim().isNotEmpty) {
      // §123 : titre proposé par Sentinelle (toutes plateformes).
      title = ai.proposedTitle!.trim();
    } else if (ai != null && ai.youtubeTitle != null && ai.youtubeTitle!.trim().isNotEmpty) {
      title = ai.youtubeTitle!.trim();
    } else {
      final sharedText = widget.suggestion.sharedText;
      if (sharedText != null && sharedText.trim().isNotEmpty) {
        final cleaned =
            sharedText.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
        title = cleaned.isEmpty ? sharedText : cleaned;
      }
    }
    _title = TextEditingController(text: title);
    _image = TextEditingController();

    // Auto-remplissage de la catégorie — §123 : page web → Links ; vidéo
    // (YouTube, bilibili, RUTUBE, Twitch) → Vidéo, ou Patch & MoD si une
    // analyse §123+ l'y a classée (avant, « guides » = guide écrit).
    if (!StoreController.isVideoPlatformUrl(widget.suggestion.url)) {
      _category = ContentCategory.links;
    } else {
      final suggested = ai?.suggestedCategory?.trim().toLowerCase();
      _category = (suggested == 'guides' &&
              (ai?.categoryVersion ?? 0) >= 2)
          ? ContentCategory.guides
          : ContentCategory.video;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _image.dispose();
    super.dispose();
  }

  void _validate() {
    final StoreController store = context.read<StoreController>();
    if (_gameId == null || _title.text.trim().isEmpty) return;
    store.acceptSuggestion(
      suggestion: widget.suggestion,
      gameId: _gameId!,
      category: _category,
      titleAdmin: _title.text,
      imageUrl: _image.text,
      // D3.4 — l'alias candidat n'est créé QUE si la case de la ligne
      // Sentinelle était cochée (défaut) à l'ouverture du dialogue.
      aliasCandidateChecked: widget.aliasCandidateChecked,
    );
    Navigator.pop(context);
  }

  /// Ouvre un mini-dialog pour créer un jeu rapidement sans quitter le
  /// dialogue de validation. Une fois créé, le jeu est automatiquement
  /// sélectionné comme jeu cible.
  void _quickCreateGame() {
    final nameCtrl = TextEditingController();
    final publisherCtrl = TextEditingController();
    final coverCtrl = TextEditingController();

    // Pré-remplit le nom avec le jeu suggéré par l'IA si disponible.
    final ai = widget.suggestion.aiRecommendation;
    if (ai != null && ai.suggestedGame != null) {
      nameCtrl.text = ai.suggestedGame!;
    }

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Créer un jeu'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nom du jeu *',
                  hintText: 'ex. Fortnite',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: publisherCtrl,
                decoration: const InputDecoration(
                  labelText: 'Éditeur (optionnel)',
                  hintText: 'ex. Epic Games',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: coverCtrl,
                decoration: const InputDecoration(
                  labelText: 'URL image de couverture (optionnel)',
                  hintText: 'https://...',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Créer et sélectionner'),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final store = context.read<StoreController>();
              Navigator.pop(dialogCtx); // ferme le mini-dialog
              // Crée le jeu (await pour récupérer le vrai UUID).
              await store.addGame(
                name: name,
                publisher: publisherCtrl.text.trim().isEmpty
                    ? null
                    : publisherCtrl.text.trim(),
                coverUrl: coverCtrl.text.trim().isEmpty
                    ? null
                    : coverCtrl.text.trim(),
              );
              // Sélectionne automatiquement le jeu fraîchement créé.
              // addGame l'ajoute en fin de liste, on le retrouve par son nom.
              final created = store.games.firstWhere(
                (g) => g.name.toLowerCase() == name.toLowerCase(),
                orElse: () => store.games.last,
              );
              setState(() => _gameId = created.id);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final List<Game> games = store.games;
    final bool isVideo = widget.suggestion.url.contains('youtube') ||
        widget.suggestion.url.contains('youtu.be');

    // Auto-sélection du jeu depuis la recommandation IA (si pas déjà choisi).
    if (_gameId == null) {
      final ai = widget.suggestion.aiRecommendation;
      if (ai != null && ai.suggestedGame != null) {
        final match = games.firstWhere(
          (g) => g.name.toLowerCase() == ai.suggestedGame!.toLowerCase(),
          orElse: () => games.firstWhere(
            (g) =>
                g.name.toLowerCase().contains(ai.suggestedGame!.toLowerCase()),
            orElse: () => games.first,
          ),
        );
        if (games.isNotEmpty) _gameId = match.id;
      }
    }

    return AlertDialog(
      title: const Text('Valider la suggestion'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Aperçu de l'URL source
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: AppColors.neonCyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.neonCyan.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(isVideo ? Icons.smart_display_rounded : Icons.link_rounded,
                      size: 18, color: AppColors.neonCyan),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.suggestion.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (games.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Ajoutez d\'abord un jeu pour pouvoir valider.',
                  style: TextStyle(color: AppColors.categoryVideo, fontSize: 13),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _gameId,
                    decoration: const InputDecoration(labelText: 'Jeu cible *'),
                    items: games
                        .map((g) =>
                            DropdownMenuItem(value: g.id, child: Text(g.name)))
                        .toList(),
                    onChanged: (v) => setState(() => _gameId = v),
                  ),
                ),
                const SizedBox(width: 8),
                // Bouton "+" pour créer un jeu rapidement sans quitter le dialog.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: IconButton.filled(
                    tooltip: 'Créer un nouveau jeu',
                    onPressed: () => _quickCreateGame(),
                    icon: const Icon(Icons.add_rounded, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ContentCategory>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Catégorie *'),
              items: ContentCategory.values
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Row(children: [
                          Icon(c.icon, size: 18, color: c.color),
                          const SizedBox(width: 8),
                          Text(c.label),
                        ]),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v ?? _category),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Titre administrateur *',
                helperText: 'Titre affiché dans l\'app mobile.'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _image,
              decoration: const InputDecoration(
                  labelText: 'URL image d\'aperçu (optionnel)',
                  helperText: 'Sinon, extraction auto pour YouTube'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: _validate,
          icon: const Icon(Icons.check_rounded),
          label: const Text('Valider et ajouter'),
        ),
      ],
    );
  }
}
