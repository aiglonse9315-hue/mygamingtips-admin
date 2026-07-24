// ============================================================================
// Menu Admin « Scruteur » — Sites web de guides d'astuces découverts par IA
// ============================================================================
// Clone adapté de sentinelle_screen.dart. Affiche les suggestions
// source='scruteur' (sites web de guides) déjà jugées par l'IA, en deux files :
//   - « 95-100% pertinent » (confiance ≥ 0.95 uniforme) → validation 1 clic
//   - « À vérifier » (confiance < 0.95)
//
// Différences avec Sentinelle :
//   - Pas de section « Analyse en cours » (le Scruteur juge à la découverte).
//   - Pas de section « Jeux à créer » (le Scruteur ne crée pas de jeux).
//   - La validation 1 clic demande explicitement un JEU CIBLE (un site de
//     guides peut couvrir plusieurs jeux ; l'admin choisit), là où Sentinelle
//     devine le jeu depuis le titre de la vidéo.
//   - Catégorie forcée 'links', is_video=false, video_language=langue détectée.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../core/theme/colors.dart';
import '../../core/i18n/language_chip.dart' show LanguageBadge, BadgeSize;
import '../../domain/models/suggestion.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';

class ScruteurScreen extends StatefulWidget {
  const ScruteurScreen({super.key});
  @override
  State<ScruteurScreen> createState() => _ScruteurScreenState();
}

class _ScruteurScreenState extends State<ScruteurScreen> {
  final Set<String> _selected = <String>{};

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _selectAll(List<Suggestion> trusted) {
    setState(() {
      if (_selected.length == trusted.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(trusted.map((s) => s.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<StoreController>();
    final trusted = store.scruteurTrusted;
    final toVerify = store.scruteurToVerify;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.neonGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.travel_explore_rounded,
                    color: AppColors.neonGreen, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scruteur — Sites guides IA',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${trusted.length + toVerify.length} site(s) web découvert(s) '
                      'par le bot Scruteur. Catégorie « Liens » à la validation.',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          // Section 1 : 95-100% pertinent
          Row(
            children: [
              _SectionHeader(
                icon: Icons.verified_rounded,
                color: AppColors.neonGreen,
                title: '95-100% pertinent — Implémentable en 1 clic',
                count: trusted.length,
              ),
              const Spacer(),
              if (trusted.isNotEmpty) ...[
                InkWell(
                  onTap: () => _selectAll(trusted),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _selected.length == trusted.length &&
                            trusted.isNotEmpty,
                        onChanged: (_) => _selectAll(trusted),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                      const Text('Tout sélectionner',
                          style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_selected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => _validateSelected(store, trusted),
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: Text('Valider sélection (${_selected.length})'),
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (trusted.isEmpty)
            const _EmptyHint(
                text:
                    'Aucun site à haute confiance pour le moment. Lance le bot Scruteur depuis Vision.exe.')
          else
            RepaintBoundary(
              child: _TrustedTable(
                suggestions: trusted,
                selectedIds: _selected,
                onToggle: _toggleSelect,
                onSelectAll: () => _selectAll(trusted),
                onValidate: (s) => _validateOne(store, s),
              ),
            ),
          const SizedBox(height: 32),

          // Section 2 : À vérifier
          _SectionHeader(
            icon: Icons.visibility_rounded,
            color: AppColors.categoryVideo,
            title: 'À vérifier',
            count: toVerify.length,
          ),
          const SizedBox(height: 12),
          if (toVerify.isEmpty)
            const _EmptyHint(text: 'Aucun site à vérifier. 🎉')
          else
            RepaintBoundary(
              child: _ToVerifyTable(
                suggestions: toVerify,
                onValidate: (s) => _validateOne(store, s),
                onReject: (s) => _reject(store, s),
              ),
            ),
          const SizedBox(height: 32),

          if (store.lastActionError != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.red.withValues(alpha: 0.4)),
              ),
              child: Text('⚠️ ${store.lastActionError}',
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ),
        ],
      ),
    );
  }

  // --- Actions ---

  /// Valide UN site : ouvre un dialog de choix du jeu cible.
  Future<void> _validateOne(StoreController store, Suggestion s) async {
    final gameId = await _pickGameDialog(s);
    if (gameId == null) return; // annulé
    await store.acceptScruteurOneClick(
      s,
      gameId: gameId,
      videoLanguage: s.aiRecommendation?.youtubeLanguage,
    );
  }

  /// Valide la sélection (un par un, avec choix du jeu à chaque fois).
  Future<void> _validateSelected(
      StoreController store, List<Suggestion> trusted) async {
    final selected =
        trusted.where((s) => _selected.contains(s.id)).toList();
    for (final s in selected) {
      await _validateOne(store, s);
      if (!mounted) return;
    }
    _selected.clear();
  }

  Future<void> _reject(StoreController store, Suggestion s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ConfirmDialog(
        title: 'Rejeter ce site ?',
        message: 'Le site sera retiré du menu Scruteur (statut rejected).',
        confirmLabel: 'Rejeter',
        destructive: true,
        onConfirm: () => store.rejectScruteur(s),
      ),
    );
  }

  /// Ouvre un dialog pour choisir à quel jeu associer le site.
  /// Retourne le gameId choisi, ou null si annulé.
  Future<String?> _pickGameDialog(Suggestion s) async {
    final store = context.read<StoreController>();
    final games = store.games;
    if (games.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucun jeu dans le catalogue.')),
      );
      return null;
    }
    String? selectedGameId = games.first.id;
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Associer à un jeu'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Site : ${_cleanTitle(s)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(s.url,
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 16),
                  const Text('Jeu cible :'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: selectedGameId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        border: OutlineInputBorder()),
                    items: games
                        .map((g) => DropdownMenuItem(
                              value: g.id,
                              child: Text(g.name),
                            ))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => selectedGameId = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Annuler'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, selectedGameId),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Valider'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ===========================================================================
// Tableau « 95-100% pertinent »
// ===========================================================================
class _TrustedTable extends StatelessWidget {
  const _TrustedTable({
    required this.suggestions,
    required this.selectedIds,
    required this.onToggle,
    required this.onSelectAll,
    required this.onValidate,
  });

  final List<Suggestion> suggestions;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  final ValueChanged<Suggestion> onValidate;

  @override
  Widget build(BuildContext context) {
    return AdminDataTable(
      columns: const ['', 'Titre', 'URL', 'Langue', 'Confiance', 'Actions'],
      rows: suggestions
          .map((s) => <Widget>[
                Checkbox(
                  value: selectedIds.contains(s.id),
                  onChanged: (_) => onToggle(s.id),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                SelectableText(_cleanTitle(s),
                    style: const TextStyle(fontSize: 12)),
                SelectableText(s.url,
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                LanguageBadge(
                  languageCode: s.aiRecommendation?.youtubeLanguage,
                  size: BadgeSize.small,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle,
                        color: AppColors.neonGreen, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      '${((s.aiRecommendation?.confidence ?? 0) * 100).round()}%',
                      style: const TextStyle(
                          color: AppColors.neonGreen,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => onValidate(s),
                      icon: const Icon(Icons.bolt, size: 14),
                      label: const Text('1 clic'),
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.neonGreen,
                          foregroundColor: Colors.black),
                    ),
                    IconButton(
                      tooltip: 'Vérifier le lien',
                      icon: const Icon(Icons.open_in_new, size: 16),
                      onPressed: () => _openUrl(s.url),
                    ),
                  ],
                ),
              ])
          .toList(),
    );
  }
}

// ===========================================================================
// Tableau « À vérifier »
// ===========================================================================
class _ToVerifyTable extends StatelessWidget {
  const _ToVerifyTable({
    required this.suggestions,
    required this.onValidate,
    required this.onReject,
  });

  final List<Suggestion> suggestions;
  final ValueChanged<Suggestion> onValidate;
  final ValueChanged<Suggestion> onReject;

  @override
  Widget build(BuildContext context) {
    return AdminDataTable(
      columns: const [
        'Titre',
        'URL',
        'Langue',
        'Confiance',
        'Raison IA',
        'Actions'
      ],
      rows: suggestions
          .map((s) => <Widget>[
                SelectableText(_cleanTitle(s),
                    style: const TextStyle(fontSize: 12)),
                SelectableText(s.url,
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                LanguageBadge(
                  languageCode: s.aiRecommendation?.youtubeLanguage,
                  size: BadgeSize.small,
                ),
                Text(
                  '${((s.aiRecommendation?.confidence ?? 0) * 100).round()}%',
                  style: TextStyle(
                    color: (s.aiRecommendation?.confidence ?? 0) >= 0.5
                        ? AppColors.plusGold
                        : AppColors.categoryVideo,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Tooltip(
                  message: s.aiRecommendation?.reason ?? '',
                  child: Text(
                    s.aiRecommendation?.reason ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => onValidate(s),
                      icon: const Icon(Icons.bolt, size: 14),
                      label: const Text('1 clic'),
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.neonCyan),
                    ),
                    IconButton(
                      tooltip: 'Vérifier le lien',
                      icon: const Icon(Icons.open_in_new, size: 16),
                      onPressed: () => _openUrl(s.url),
                    ),
                    IconButton(
                      tooltip: 'Rejeter',
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.red, size: 16),
                      onPressed: () => onReject(s),
                    ),
                  ],
                ),
              ])
          .toList(),
    );
  }
}

// ===========================================================================
// Helpers / composants partagés
// ===========================================================================
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.color,
    required this.title,
    required this.count,
  });
  final IconData icon;
  final Color color;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey, fontSize: 13)),
    );
  }
}

String _cleanTitle(Suggestion s) {
  final shared = s.sharedText;
  if (shared != null && shared.trim().isNotEmpty) {
    final cleaned = shared.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
    return cleaned.isEmpty ? shared : cleaned;
  }
  return s.url;
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (await ul.canLaunchUrl(uri)) {
    await ul.launchUrl(uri, mode: ul.LaunchMode.externalApplication);
  }
}
