import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../state/store_controller.dart';
import '../widgets/stat_card.dart' show StatusBadge;

/// Page Contributeurs : top 20 des utilisateurs ayant le plus de suggestions
/// acceptées. Vision (le bot IA) est affiché séparément "dans le ciel",
/// au-dessus du podium humain, avec une animation.
class ContributorsScreen extends StatefulWidget {
  const ContributorsScreen({super.key});

  @override
  State<ContributorsScreen> createState() => _ContributorsScreenState();
}

class _ContributorsScreenState extends State<ContributorsScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _contributors = const [];
  bool _loading = true;
  String? _error;

  /// Animation pour le flottement de Vision.
  late final AnimationController _floatCtrl;

  @override
  void initState() {
    super.initState();
    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _load();
  }

  @override
  void dispose() {
    _floatCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() {
        _loading = false;
        _error =
            'Mode aperçu : les contributeurs ne sont disponibles qu\'en mode production.';
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

  /// Sépare Vision des contributeurs humains.
  Map<String, dynamic>? get _vision {
    try {
      return _contributors.firstWhere((c) => c['isVision'] == true);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> get _humans {
    return _contributors.where((c) => c['isVision'] != true).toList();
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
            _buildError()
          else ...[
            // Section Vision "dans le ciel" (si présent).
            if (_vision != null) ...[
              _buildVisionSection(),
              const SizedBox(height: 24),
              const _CloudDivider(),
              const SizedBox(height: 24),
            ],
            // Podium humain.
            if (_humans.isNotEmpty)
              ..._buildPodium()
            else if (_vision == null)
              _buildEmpty(),
            if (_humans.length > 3) ...[
              const SizedBox(height: 16),
              const Text(
                'Classement complet',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ..._buildList(),
            ],
          ],
        ],
      ),
    );
  }

  // ── Section Vision "dans le ciel" ──

  Widget _buildVisionSection() {
    final count = _vision!['acceptedCount'] as int;
    return AnimatedBuilder(
      animation: _floatCtrl,
      builder: (context, child) {
        // Flottement vertical : ±6px.
        final float = math.sin(_floatCtrl.value * math.pi) * 6;
        return Transform.translate(
          offset: Offset(0, -float),
          child: child,
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.neonViolet.withValues(alpha: 0.12),
              AppColors.neonCyan.withValues(alpha: 0.08),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.neonViolet.withValues(alpha: 0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.neonViolet.withValues(alpha: 0.15),
              blurRadius: 24,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          children: [
            // Étoiles scintillantes autour de Vision.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4),
                  child: _Sparkle(delaySeconds: i * 0.3),
                );
              }),
            ),
            const SizedBox(height: 8),
            // Avatar Vision.
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppColors.neonViolet, AppColors.neonCyan],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.neonCyan.withValues(alpha: 0.5),
                    blurRadius: 20,
                    spreadRadius: 3,
                  ),
                ],
              ),
              child: const Icon(
                Icons.smart_toy_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 10),
            // Nom.
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [AppColors.neonViolet, AppColors.neonCyan],
              ).createShader(b),
              child: const Text(
                'Vision',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Badge "IA".
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.neonCyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppColors.neonCyan.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                '🤖 IA Vision veille sur vous .',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.neonCyan,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Compteur.
            Text(
              '$count suggestion(s) acceptée(s)',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.neonViolet,
              ),
            ),
            const SizedBox(height: 8),
            // Étoiles du bas.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4),
                  child: _Sparkle(delaySeconds: i * 0.4 + 0.5),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // ── Podium humain (top 3) ──

  List<Widget> _buildPodium() {
    final podium = _humans.take(3).toList();
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

  // ── Liste détaillée (rangs 4+) ──

  List<Widget> _buildList() {
    final others = _humans.skip(3).toList();
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
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }).toList();
  }

  // ── Helpers ──

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.categoryVideo.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.categoryVideo.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: AppColors.categoryVideo, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_error!, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Container(
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
    );
  }
}

/// Étoile scintillante animée (décoration autour de Vision).
class _Sparkle extends StatefulWidget {
  const _Sparkle({required this.delaySeconds});
  final double delaySeconds;

  @override
  State<_Sparkle> createState() => _SparkleState();
}

class _SparkleState extends State<_Sparkle> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // Démarre après le délai.
    Future.delayed(Duration(milliseconds: (widget.delaySeconds * 1000).round()),
        () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Opacity(
          opacity: 0.3 + (_ctrl.value * 0.7),
          child: Transform.scale(
            scale: 0.8 + (_ctrl.value * 0.4),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 14,
              color: AppColors.neonCyan,
            ),
          ),
        );
      },
    );
  }
}

/// Séparateur nuageux entre Vision et le podium humain.
class _CloudDivider extends StatelessWidget {
  const _CloudDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Icon(Icons.cloud_rounded,
              size: 20,
              color: Theme.of(context).textTheme.bodySmall?.color ??
                  Colors.grey),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}
