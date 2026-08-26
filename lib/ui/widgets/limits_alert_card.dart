import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../state/store_controller.dart';

/// Bandeau d'alerte de saturation des limites de listes (dashboard admin).
///
/// Compte les lignes en base via HEAD `Prefer: count=exact` (0 ligne
/// transférée) et compare aux plafonds de prise en compte du panneau :
///   - Jeux actifs   → plafond 100 000 (maxGames du StoreController)
///   - Contenus      → plafond 500 000 (maxContents)
///
/// Seuils visuels : < 60 % vert (discret), 60–85 % orange (avertissement),
/// ≥ 85 % rouge (action requise avant saturation silencieuse).
///
/// Le détail complet par composant est dans le menu « Limite ».
class LimitsAlertCard extends StatefulWidget {
  const LimitsAlertCard({super.key});

  @override
  State<LimitsAlertCard> createState() => _LimitsAlertCardState();
}

class _LimitsAlertCardState extends State<LimitsAlertCard> {
  static const int _maxGames = 100000;
  static const int _maxContents = 500000;

  bool _loading = false;
  int? _games; // jeux actifs
  int? _contents;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) return; // Mode démo : pas de comptage possible.
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        sync.fetchTableCount('games', filter: 'active=eq.true'),
        sync.fetchTableCount('contents'),
      ]);
      if (!mounted) return;
      setState(() {
        _games = results[0] >= 0 ? results[0] : null;
        _contents = results[1] >= 0 ? results[1] : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Couleur selon le ratio d'occupation du plafond.
  Color _colorFor(double? ratio) {
    if (ratio == null) return Colors.grey;
    if (ratio >= 0.85) return AppColors.categoryVideo; // rouge
    if (ratio >= 0.60) return AppColors.plusGold; // orange
    return AppColors.neonGreen; // vert
  }

  String _labelFor(double? ratio) {
    if (ratio == null) return 'n/d';
    if (ratio >= 0.85) return 'CRITIQUE';
    if (ratio >= 0.60) return 'ATTENTION';
    return 'OK';
  }

  String _fmt(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202F');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.read<StoreController>().sync;
    if (sync == null) return const SizedBox.shrink(); // mode démo

    final double? gamesRatio =
        _games == null ? null : _games! / _maxGames;
    final double? contentsRatio =
        _contents == null ? null : _contents! / _maxContents;

    // Ratio le plus défavorable → pilote la couleur du titre du bandeau.
    final ratios = [gamesRatio, contentsRatio].whereType<double>().toList();
    final double? worst = ratios.isEmpty
        ? null
        : ratios.reduce((a, b) => a > b ? a : b);
    final Color worstColor = _colorFor(worst);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  worst != null && worst >= 0.60
                      ? Icons.warning_amber_rounded
                      : Icons.shield_outlined,
                  size: 18,
                  color: worstColor,
                ),
                const SizedBox(width: 8),
                Text(
                  'Surveillance des limites',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: worstColor,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    tooltip: 'Rafraîchir',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _gauge('Jeux actifs', _games, _maxGames, gamesRatio),
            const SizedBox(height: 8),
            _gauge('Contenus validés', _contents, _maxContents, contentsRatio),
            if (worst != null && worst >= 0.60) ...[
              const SizedBox(height: 10),
              Text(
                worst >= 0.85
                    ? '⛔ Un compteur dépasse 85 % de son plafond : la '
                        'saturation silencieuse approche — prévoir un '
                        'relevé de limite (voir menu Limite).'
                    : '⚠️ Un compteur dépasse 60 % de son plafond — '
                        'surveiller la croissance (détails : menu Limite).',
                style: TextStyle(fontSize: 11, color: worstColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _gauge(String label, int? value, int max, double? ratio) {
    final color = _colorFor(ratio);
    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio?.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 170,
          child: Text(
            value == null
                ? 'n/d'
                : '${_fmt(value)} / ${_fmt(max)} '
                    '(${((ratio ?? 0) * 100).toStringAsFixed(1)} %)',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: color),
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: Text(
            _labelFor(ratio),
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w800, color: color),
          ),
        ),
      ],
    );
  }
}
