import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/store_controller.dart';

/// Écran « Limite » : vue centralisée des limites de prise en compte des
/// listes dans chaque composant du projet, avec les valeurs actuelles en
/// base (comptées via HEAD `Prefer: count=exact` — 0 ligne transférée).
///
/// Pourquoi cet écran existe : PostgREST plafonne chaque réponse à 1000
/// lignes. Un composant qui oublie de paginer (ou qui plafonne sa
/// pagination) produit des ERREURS SILENCIEUSES (données manquantes sans
/// message). Cet écran documente les plafonds réels pour les repérer.
class LimitesScreen extends StatefulWidget {
  const LimitesScreen({super.key});

  @override
  State<LimitesScreen> createState() => _LimitesScreenState();
}

class _LimitesScreenState extends State<LimitesScreen> {
  bool _loading = false;
  String? _error;

  // Compteurs live (−1 = indisponible, null = pas encore chargé).
  int? _gamesTotal;
  int? _gamesActifs;
  int? _contents;
  int? _translations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() => _error = 'Mode démo : pas de connexion Supabase.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        sync.fetchTableCount('games'),
        sync.fetchTableCount('games', filter: 'active=eq.true'),
        sync.fetchTableCount('contents'),
        sync.fetchTableCount('game_translations'),
      ]);
      if (!mounted) return;
      setState(() {
        _gamesTotal = results[0];
        _gamesActifs = results[1];
        _contents = results[2];
        _translations = results[3];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _fmt(int? v) {
    if (v == null) return '…';
    if (v < 0) return 'n/d';
    // Format français : espace fine insécable comme séparateur de milliers.
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
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Limites de prise en compte des listes',
                  style: theme.textTheme.titleLarge),
              const Spacer(),
              if (_loading)
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Rafraîchir les compteurs',
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'PostgREST plafonne chaque réponse à 1 000 lignes : tous les '
            'composants paginent par pages de 1 000. Les plafonds ci-dessous '
            'sont les maxima pris en compte APRÈS pagination.',
            style: theme.textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Colors.orange.shade300)),
          ],
          const SizedBox(height: 20),

          // ── Valeurs actuelles en base ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Valeurs actuelles en base',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      _countCard('Jeux actifs', _gamesActifs, 100000,
                          subtitle: '${_fmt(_gamesTotal)} au total '
                              '(actifs + inactifs)'),
                      _countCard('Contenus validés', _contents, 500000),
                      _countCard('Traductions de jeux', _translations, null,
                          subtitle: 'lignes game_translations (12 langues/jeu)'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Plafonds par composant ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Maximum pris en compte par composant',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Composant')),
                        DataColumn(label: Text('Donnée')),
                        DataColumn(label: Text('Maximum'), numeric: true),
                        DataColumn(label: Text('Méthode')),
                      ],
                      rows: [
                        _row('PostgREST (serveur)', 'Toutes tables',
                            '1 000', 'par requête — pagination obligatoire'),
                        _row('Edge Function admin-catalog', 'pageSize / appel',
                            '1 000', 'pagination interne illimitée'),
                        _row('Panneau admin', 'Jeux', '100 000',
                            'pages de 1 000'),
                        _row('Panneau admin', 'Contenus', '500 000',
                            'pages de 1 000'),
                        _row('Panneau admin', 'Abonnés', '100 000',
                            'pages de 1 000'),
                        _row('Panneau admin', 'Suggestions', 'Illimité',
                            'pages de 500'),
                        _row('Application mobile', 'Jeux', 'Illimité',
                            'pages de 1 000 + cache SQLite'),
                        _row('Application mobile', 'Contenus par jeu',
                            'Illimité', 'sync incrémentale + cache SQLite'),
                        _row('Application mobile', 'Mes suggestions',
                            '500 000', 'pages de 250'),
                        _row('Vision.exe (4 bots)', 'Jeux / contenus / URLs',
                            'Illimité', 'pages de 1 000'),
                        _row('mydesktopTip (Windows)', 'Jeux / contenus',
                            'Illimité', 'pages de 1 000 + cache local'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Quotas API externes ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quotas API externes (Vision.exe)',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('API')),
                        DataColumn(label: Text('Plafond'), numeric: true),
                        DataColumn(label: Text('Reset')),
                      ],
                      rows: [
                        _row('YouTube Data API v3', '10 000 unités/jour '
                            '(100/search)', '9h00 (minuit Pacifique)'),
                        _row('Gemini API — free tier (flash-lite)',
                            '≈ 1 000 requêtes/jour, 15 req/min',
                            '9h00 (minuit Pacifique)'),
                        _row('Brave Search', '2 000 requêtes/mois',
                            '1er du mois (UTC)'),
                        _row('SearXNG (local)', 'Illimité', '—'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Les barres de quota correspondantes sont affichées dans '
                    'Vision.exe (compteurs internes, sans requête dédiée).',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  DataRow _row(String component, String data, String max, [String? method]) {
    return DataRow(cells: [
      DataCell(Text(component,
          style: const TextStyle(fontWeight: FontWeight.w600))),
      DataCell(Text(data)),
      DataCell(Text(max)),
      if (method != null) DataCell(Text(method)),
    ]);
  }

  Widget _countCard(String label, int? value, int? max, {String? subtitle}) {
    final theme = Theme.of(context);
    final ratio = (value != null && value >= 0 && max != null && max > 0)
        ? (value / max).clamp(0.0, 1.0)
        : null;
    final color = ratio == null
        ? Colors.cyan.shade300
        : ratio < 0.60
            ? Colors.green.shade400
            : ratio < 0.85
                ? Colors.amber.shade400
                : Colors.red.shade400;
    return SizedBox(
      width: 240,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(_fmt(value),
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700, color: color)),
            if (max != null) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              const SizedBox(height: 4),
              Text('max pris en compte : ${_fmt(max)}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }
}
