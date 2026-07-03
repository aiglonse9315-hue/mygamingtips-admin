import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../state/store_controller.dart';
import '../widgets/stat_card.dart' show StatusBadge;

/// Page Contributeurs : top 20 des utilisateurs ayant le plus de suggestions
/// acceptées. Affiche le rang, le pseudo, l'avatar et le nombre de contributions.
class ContributorsScreen extends StatefulWidget {
  const ContributorsScreen({super.key});

  @override
  State<ContributorsScreen> createState() => _ContributorsScreenState();
}

class _ContributorsScreenState extends State<ContributorsScreen> {
  List<Map<String, dynamic>> _contributors = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() {
        _loading = false;
        _error = 'Mode aperçu : les contributeurs ne sont disponibles qu\'en mode production (Supabase connecté).';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await sync.fetchTopContributors();
      setState(() {
        _contributors = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Erreur lors du chargement : $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Top Contributeurs',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              IconButton(
                tooltip: 'Actualiser',
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: _load,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Classement par nombre de suggestions acceptées.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_error != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.categoryVideo.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.categoryVideo.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: AppColors.categoryVideo, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_error!,
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            )
          else if (_contributors.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                children: [
                  Icon(Icons.emoji_events_outlined,
                      size: 40, color: AppColors.plusGold),
                  SizedBox(height: 12),
                  Text(
                    'Aucune contribution acceptée pour le moment.\n'
                    'Les contributeurs apparaîtront ici dès qu\'une suggestion sera validée.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            )
          else
            // Podium (3 premiers)
            ..._buildPodium(),
          if (_contributors.length > 3) ...[
            const SizedBox(height: 16),
            const Text(
              'Classement complet',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ..._buildList(),
          ],
        ],
      ),
    );
  }

  /// Podium : les 3 premiers avec médailles.
  List<Widget> _buildPodium() {
    final podium = _contributors.take(3).toList();
    const medals = ['🥇', '🥈', '🥉'];
    const colors = [
      AppColors.plusGold,
      Color(0xFFB8C0CC),
      Color(0xFFCD7F32),
    ];

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: podium.asMap().entries.map((e) {
          final i = e.key;
          final c = e.value;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 130,
              child: Column(
                children: [
                  Text(medals[i], style: const TextStyle(fontSize: 28)),
                  const SizedBox(height: 6),
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: colors[i].withValues(alpha: 0.2),
                    child: Text(
                      (c['displayName'] as String)
                          .characters
                          .first
                          .toUpperCase(),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: colors[i],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    c['displayName'] as String,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  StatusBadge(
                    label: '${c['acceptedCount']} acceptée(s)',
                    color: colors[i],
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    ];
  }

  /// Liste détaillée (rangs 4 à 20).
  List<Widget> _buildList() {
    final others = _contributors.skip(3).toList();
    return others.asMap().entries.map((e) {
      final rank = e.key + 4;
      final c = e.value;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text(
                '#$rank',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.plus.withValues(alpha: 0.15),
              child: Text(
                (c['displayName'] as String)
                    .characters
                    .first
                    .toUpperCase(),
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                c['displayName'] as String,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${c['acceptedCount']} acceptée(s)',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }).toList();
  }
}
