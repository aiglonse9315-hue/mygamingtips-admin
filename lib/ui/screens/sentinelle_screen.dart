import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../core/theme/colors.dart';
import '../../domain/models/suggestion.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/stat_card.dart' show StatusBadge;
import 'suggestions_screen.dart' show SuggestionReviewDialog;

/// Écran Sentinelle : suggestions analysées par l'IA, triées en 2 catégories.
///
/// 1. **99% sûr** (🟢) : verdict "recommended" + confiance ≥ 0.9 → bouton
///    "Implémenter en 1 clic". Sélection multiple possible (checkbox) + boutons
///    "Tout valider" et "Valider la sélection".
/// 2. **À vérifier** (🟡🔴) : verdict "caution"/"reject" ou confiance < 0.9 →
///    l'admin vérifie le lien puis ajoute manuellement ou rejette.
class SentinelleScreen extends StatefulWidget {
  const SentinelleScreen({super.key});

  @override
  State<SentinelleScreen> createState() => _SentinelleScreenState();
}

class _SentinelleScreenState extends State<SentinelleScreen> {
  /// IDs des suggestions sélectionnées (section 99% sûr).
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
        _selected.clear(); // tout désélectionner
      } else {
        _selected.clear();
        _selected.addAll(trusted.map((s) => s.id));
      }
    });
  }

  /// Valide toutes les suggestions "99% sûr" en une fois.
  Future<void> _validateAll(List<Suggestion> trusted) async {
    final store = context.read<StoreController>();
    for (final s in trusted) {
      await store.acceptOneClick(s);
    }
    setState(() => _selected.clear());
  }

  /// Valide uniquement les suggestions sélectionnées.
  Future<void> _validateSelected(List<Suggestion> trusted) async {
    final store = context.read<StoreController>();
    final selected = trusted.where((s) => _selected.contains(s.id)).toList();
    for (final s in selected) {
      await store.acceptOneClick(s);
    }
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();
    final analyzing = store.sentinelleAnalyzing;
    final trusted = store.sentinelleTrusted;
    final toVerify = store.sentinelleToVerify;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.neonCyan.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.smart_toy_rounded,
                    color: AppColors.neonCyan, size: 22),
              ),
              const SizedBox(width: 12),
              const Text(
                'Sentinelle — Analyses IA',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 12),
              Text(
                '${analyzing.length + trusted.length + toVerify.length} suggestion(s)',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Suggestions en cours d\'analyse et analysées par l\'IA. '
            'L\'admin valide ou rejette — l\'IA ne décide jamais seule.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(height: 24),

          // Section 0 : Analyse en cours (Sentinelle travaille)
          _SectionHeader(
            icon: Icons.hourglass_top_rounded,
            color: AppColors.neonCyan,
            title: 'Analyse en cours',
            count: analyzing.length,
          ),
          const SizedBox(height: 12),
          if (analyzing.isEmpty)
            const _EmptyHint(text: 'Aucune analyse en cours.')
          else
            _AnalyzingTable(suggestions: analyzing),

          const SizedBox(height: 32),

          // Section 1 : 99% sûr (implémentable en 1 clic)
          Row(
            children: [
              _SectionHeader(
                icon: Icons.verified_rounded,
                color: AppColors.neonGreen,
                title: '99% sûr — Implémentable en 1 clic',
                count: trusted.length,
              ),
              const Spacer(),
              if (trusted.isNotEmpty) ...[
                // Bouton : valider la sélection
                if (_selected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => ConfirmDialog(
                          title: 'Valider ${_selected.length} suggestion(s) ?',
                          message:
                              'Les ${_selected.length} suggestion(s) sélectionnée(s) '
                              'seront implémentées automatiquement avec le jeu et '
                              'la catégorie suggérés par l\'IA.',
                          confirmLabel: 'Valider la sélection',
                          onConfirm: () => _validateSelected(trusted),
                        ),
                      ),
                      icon: const Icon(Icons.check_circle_outline_rounded,
                          size: 16),
                      label: Text('Valider sélection (${_selected.length})'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.neonCyan,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ),
                // Bouton : tout valider
                FilledButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ConfirmDialog(
                      title: 'Valider toutes les suggestions (${trusted.length}) ?',
                      message:
                          'Les ${trusted.length} suggestions "99% sûr" seront '
                          'implémentées automatiquement avec le jeu et la '
                          'catégorie suggérés par l\'IA.',
                      confirmLabel: 'Tout valider',
                      onConfirm: () => _validateAll(trusted),
                    ),
                  ),
                  icon: const Icon(Icons.done_all_rounded, size: 16),
                  label: const Text('Tout valider'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.neonGreen,
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (trusted.isEmpty)
            const _EmptyHint(text: 'Aucune suggestion à haute confiance pour le moment.')
          else
            _TrustedTable(
              suggestions: trusted,
              selectedIds: _selected,
              onToggle: _toggleSelect,
              onSelectAll: () => _selectAll(trusted),
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
            const _EmptyHint(text: 'Aucune suggestion à vérifier. 🎉')
          else
            _ToVerifyTable(suggestions: toVerify),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

class _AnalyzingTable extends StatelessWidget {
  const _AnalyzingTable({required this.suggestions});
  final List<Suggestion> suggestions;

  @override
  Widget build(BuildContext context) {
    return AdminDataTable(
      columns: const ['Titre', 'URL', 'Auteur', 'Statut', 'Depuis'],
      rows: suggestions.map((s) {
        final since = s.sentinelleStartedAt;
        final elapsed = since != null
            ? DateTime.now().difference(since)
            : Duration.zero;
        return [
          Text(_cleanTitle(s),
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          Container(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(s.url,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).textTheme.bodySmall?.color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Text(s.author.displayName,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 6),
              Text('En cours…',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.neonCyan,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          Text(_formatElapsed(elapsed),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
        ];
      }).toList(),
    );
  }
}

class _TrustedTable extends StatelessWidget {
  const _TrustedTable({
    required this.suggestions,
    required this.selectedIds,
    required this.onToggle,
    required this.onSelectAll,
  });

  final List<Suggestion> suggestions;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final store = context.read<StoreController>();
    return AdminDataTable(
      columns: const ['☐', 'Titre', 'Titre pour insertion', 'Jeu IA', 'Catégorie', 'Confiance', 'Vues', 'Actions'],
      rows: suggestions.map((s) {
        final ai = s.aiRecommendation!;
        final isSelected = selectedIds.contains(s.id);
        return [
          // Checkbox de sélection (cliquable).
          InkWell(
            onTap: () => onToggle(s.id),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                isSelected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
                color: isSelected ? AppColors.neonGreen : null,
              ),
            ),
          ),
          Text(_cleanTitle(s),
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          // Titre réel de la vidéo YouTube (pour insertion 1 clic).
          Container(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              ai.youtubeTitle ?? _cleanTitle(s),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: ai.youtubeTitle != null
                      ? AppColors.neonCyan
                      : Theme.of(context).textTheme.bodySmall?.color),
            ),
          ),
          Text(ai.suggestedGame ?? '—',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
          StatusBadge(
              label: ai.suggestedCategory ?? '—',
              color: AppColors.neonCyan),
          Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: AppColors.neonGreen, size: 16),
              const SizedBox(width: 4),
              Text('${(ai.confidence * 100).round()}%',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: AppColors.neonGreen)),
            ],
          ),
          Text(_formatViews(ai.youtubeViews),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: () => store.acceptOneClick(s),
                icon: const Icon(Icons.bolt_rounded, size: 16),
                label: const Text('1 clic'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.neonGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              IconButton(
                tooltip: 'Vérifier le lien',
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                onPressed: () => _openUrl(s.url),
              ),
              IconButton(
                tooltip: 'Rejeter',
                icon: const Icon(Icons.close_rounded, size: 20),
                color: AppColors.categoryVideo,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ConfirmDialog(
                    title: 'Rejeter cette suggestion ?',
                    message: '« ${_cleanTitle(s)} » sera marquée comme rejetée.',
                    confirmLabel: 'Rejeter',
                    destructive: true,
                    onConfirm: () => store.rejectSentinelle(s),
                  ),
                ),
              ),
            ],
          ),
        ];
      }).toList(),
    );
  }
}

class _ToVerifyTable extends StatelessWidget {
  const _ToVerifyTable({required this.suggestions});
  final List<Suggestion> suggestions;

  @override
  Widget build(BuildContext context) {
    final store = context.read<StoreController>();
    return AdminDataTable(
      columns: const ['Titre', 'Titre pour insertion', 'Verdict IA', 'Raison', 'Confiance', 'Actions'],
      rows: suggestions.map((s) {
        final ai = s.aiRecommendation;
        final isReject = ai?.verdict == AiVerdict.reject;
        return [
          Text(_cleanTitle(s),
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          // Titre réel de la vidéo YouTube (pour insertion manuelle).
          Container(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              ai?.youtubeTitle ?? _cleanTitle(s),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: ai?.youtubeTitle != null
                      ? AppColors.neonCyan
                      : Theme.of(context).textTheme.bodySmall?.color),
            ),
          ),
          ai == null
              ? const Text('—')
              : StatusBadge(
                  label: ai.verdict.label,
                  color: isReject
                      ? AppColors.categoryVideo
                      : AppColors.plusGold,
                ),
          Container(
            constraints: const BoxConstraints(maxWidth: 250),
            child: Text(
              ai?.reason ?? 'Pas d\'analyse.',
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(ai != null ? '${(ai.confidence * 100).round()}%' : '—',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isReject
                      ? AppColors.categoryVideo
                      : AppColors.plusGold)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Vérifier le lien',
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                onPressed: () => _openUrl(s.url),
              ),
              IconButton(
                tooltip: 'Ajouter manuellement',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SuggestionReviewDialog(suggestion: s),
                ),
              ),
              IconButton(
                tooltip: 'Rejeter',
                icon: const Icon(Icons.close_rounded, size: 20),
                color: AppColors.categoryVideo,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ConfirmDialog(
                    title: 'Rejeter cette suggestion ?',
                    message: '« ${_cleanTitle(s)} » sera marquée comme rejetée.',
                    confirmLabel: 'Rejeter',
                    destructive: true,
                    onConfirm: () => store.rejectSentinelle(s),
                  ),
                ),
              ),
            ],
          ),
        ];
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$count',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w800, color: color),
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
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Center(
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).textTheme.bodySmall?.color)),
      ),
    );
  }
}

void _openUrl(String url) async {
  final uri = Uri.parse(url);
  if (await ul.canLaunchUrl(uri)) {
    await ul.launchUrl(uri, mode: ul.LaunchMode.externalApplication);
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

String _formatViews(int? views) {
  if (views == null) return '—';
  if (views >= 1000000) return '${(views / 1000000).toStringAsFixed(1)}M';
  if (views >= 1000) return '${(views / 1000).toStringAsFixed(1)}k';
  return views.toString();
}

String _formatElapsed(Duration d) {
  if (d.inMinutes > 0) return '${d.inMinutes} min';
  return '${d.inSeconds} s';
}
