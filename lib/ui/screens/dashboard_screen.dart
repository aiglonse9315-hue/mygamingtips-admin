import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/category.dart';
import '../../domain/models/plus_user.dart';
import '../../domain/models/suggestion.dart';
import '../../state/store_controller.dart';
import '../widgets/stat_card.dart';

/// Tableau de bord : vue d'ensemble statistiques + dernières suggestions.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.onOpenSuggestions});

  final VoidCallback onOpenSuggestions;

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();

    final int gamesCount = store.games.length;
    final int contentsCount = store.contents.where((c) => c.validated).length;
    final int pending = store.pendingSuggestionsCount;
    final int videos = store.contents
        .where((c) => c.category == ContentCategory.video && c.validated)
        .length;
    final int guides = store.contents
        .where((c) => c.category == ContentCategory.guides && c.validated)
        .length;
    final int links = store.contents
        .where((c) => c.category == ContentCategory.links && c.validated)
        .length;

    final List<Suggestion> recent = store.suggestionsByDate.take(5).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stats principales : Wrap responsive (pas de LayoutBuilder pour
          // éviter un bug de largeur non bornée dans le scroll).
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              SizedBox(
                width: 240,
                child: StatCard(
                  label: 'Jeux',
                  value: '$gamesCount',
                  icon: Icons.sports_esports_rounded,
                  color: AppColors.neonViolet,
                ),
              ),
              SizedBox(
                width: 240,
                child: StatCard(
                  label: 'Contenus validés',
                  value: '$contentsCount',
                  icon: Icons.collections_bookmark_rounded,
                  color: AppColors.neonCyan,
                  subtitle: '$videos V • $guides G • $links L',
                ),
              ),
              SizedBox(
                width: 240,
                child: StatCard(
                  label: 'Suggestions en attente',
                  value: '$pending',
                  icon: Icons.inbox_rounded,
                  color: AppColors.plusGold,
                ),
              ),
              SizedBox(
                width: 240,
                child: StatCard(
                  label: 'Abonnés Plus',
                  value: '${store.activePlusCount}',
                  icon: Icons.bolt_rounded,
                  color: AppColors.plus,
                  subtitle:
                      '${store.plus.length} au total',
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          // Répartition par catégorie
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Répartition des contenus',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 16),
                  ...ContentCategory.values.map((c) {
                    final int count = store.contents
                        .where((x) => x.category == c && x.validated)
                        .length;
                    final double ratio = contentsCount == 0
                        ? 0
                        : count / contentsCount;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          Icon(c.icon, color: c.color, size: 18),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 80,
                            child: Text(c.label,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13)),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            flex: 3,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: ratio,
                                minHeight: 10,
                                backgroundColor: c.color
                                    .withValues(alpha: 0.15),
                                color: c.color,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('$count',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // ---------- Utilisateurs Plus (accordéon) ----------
          _PlusAccordion(),
          const SizedBox(height: 24),
          // Dernières suggestions
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Dernières suggestions',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
              ),
              TextButton.icon(
                onPressed: onOpenSuggestions,
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: const Text('Voir tout'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: recent.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Aucune suggestion.')),
                  )
                : Column(
                    children: recent
                        .map((s) => ListTile(
                              leading: Icon(
                                s.status == SuggestionStatus.pending
                                    ? Icons.hourglass_top_rounded
                                    : (s.status == SuggestionStatus.accepted
                                        ? Icons.check_circle_rounded
                                        : Icons.cancel_rounded),
                                size: 20,
                                color: s.status == SuggestionStatus.pending
                                    ? AppColors.plusGold
                                    : (s.status == SuggestionStatus.accepted
                                        ? AppColors.neonGreen
                                        : AppColors.categoryVideo),
                              ),
                              title: Text(s.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(
                                _formatDate(s.sharedAt),
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: Text(
                                s.status.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ))
                        .toList(),
                  ),
          ),
          const SizedBox(height: 24),
          // Comptes bannis (modération)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Comptes bannis',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.categoryVideo,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    onPressed: () =>
                        showDialog<void>(
                            context: context,
                            builder: (_) => const _AddBannedUserDialog()),
                    icon: const Icon(Icons.block_rounded, size: 18),
                    label: const Text('Bannir'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: onOpenSuggestions,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Voir les suggestions'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: store.banned.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Aucun compte banni.')),
                  )
                : Column(
                    children: store.banned
                        .map((b) => ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: AppColors.categoryVideo,
                                child: Icon(Icons.block_rounded,
                                    color: Colors.white, size: 18),
                              ),
                              title: Text(b.displayName,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700)),
                              subtitle: Text(
                                '${b.id} • ${b.reason ?? "Sans motif"}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: TextButton.icon(
                                onPressed: () => store.unban(b.id),
                                icon: const Icon(Icons.lock_open_rounded,
                                    size: 18),
                                label: const Text('Débannir'),
                              ),
                            ))
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
        '${d.hour.toString().padLeft(2, '0')}h${d.minute.toString().padLeft(2, '0')}';
  }
}

/// Accordéon « Utilisateurs Plus » : liste + ajout manuel.
class _PlusAccordion extends StatefulWidget {
  @override
  State<_PlusAccordion> createState() => _PlusAccordionState();
}

class _PlusAccordionState extends State<_PlusAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();
    final List<PlusUser> plus = store.plus;

    return Card(
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.plus.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.bolt_rounded,
                  color: AppColors.plus, size: 20),
            ),
            title: const Text('Abonnés Plus',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            subtitle: Text(
              '${store.activePlusCount} actif(s) • ${plus.length} au total',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.plus,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                  ),
                  onPressed: () => _showAddDialog(context),
                  icon: const Icon(Icons.person_add_rounded, size: 18),
                  label: const Text('Ajouter'),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: plus.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(
                          vertical: 16, horizontal: 16),
                      child: Text('Aucun abonné Plus.',
                          style: TextStyle(fontSize: 13)),
                    )
                  : Column(
                      children: plus.map((n) => _plusTile(context, n)).toList(),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _plusTile(BuildContext context, PlusUser n) {
    final StoreController store = context.read<StoreController>();
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor:
            AppColors.plus.withValues(alpha: n.active ? 0.2 : 0.06),
        child: Icon(Icons.bolt_rounded,
            size: 16, color: n.active ? AppColors.plus : Colors.grey),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(n.displayName,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: n.active ? null : Colors.grey)),
          ),
          const SizedBox(width: 6),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: (n.plan == 'yearly'
                      ? AppColors.plusGold
                      : AppColors.plus)
                  .withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              n.plan == 'yearly' ? 'Annuel' : 'Mensuel',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: n.plan == 'yearly'
                      ? AppColors.plusGold
                      : AppColors.plus),
            ),
          ),
          if (!n.active) ...[
            const SizedBox(width: 6),
            StatusBadge(label: 'Expiré', color: Colors.grey),
          ],
        ],
      ),
      subtitle: Text(
        '${n.email ?? "—"} • depuis le ${_shortDate(n.startedAt)}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Bouton "Suspendre" : affiché uniquement si l'abonné est actif.
          // La réactivation est volontairement verrouillée (abonnés inactifs
          // = expirés, gérés côté Google Play Billing).
          if (n.active)
            IconButton(
              tooltip: 'Suspendre',
              icon: const Icon(Icons.pause_circle_outline_rounded,
                  size: 20, color: AppColors.plusGold),
              onPressed: () => store.togglePlusUser(n),
            ),
          PopupMenuButton<String>(
            tooltip: 'Changer la formule',
            icon: const Icon(Icons.swap_horiz_rounded, size: 20),
            onSelected: (plan) => store.setPlusPlan(n, plan),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'monthly', child: Text('Mensuel')),
              PopupMenuItem(value: 'yearly', child: Text('Annuel')),
            ],
          ),
          IconButton(
            tooltip: 'Supprimer',
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: AppColors.categoryVideo,
            onPressed: () => store.deletePlusUser(n.id),
          ),
        ],
      ),
    );
  }

  void _showAddDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _AddPlusUserDialog(),
    );
  }

  static String _shortDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Dialog d'ajout manuel d'un utilisateur Plus.
class _AddPlusUserDialog extends StatefulWidget {
  const _AddPlusUserDialog();

  @override
  State<_AddPlusUserDialog> createState() => _AddPlusUserDialogState();
}

class _AddPlusUserDialogState extends State<_AddPlusUserDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  String _plan = 'monthly';
  bool _loading = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    final StoreController store = context.read<StoreController>();
    final sync = store.sync;

    // Mode aperçu local (sans Supabase) : ajout manuel direct.
    if (sync == null) {
      store.addPlusUser(
        displayName: _name.text.trim().isEmpty ? email : _name.text,
        email: email,
        plan: _plan,
      );
      if (mounted) Navigator.pop(context);
      return;
    }

    setState(() => _loading = true);
    try {
      final String? uuid = await sync.findProfileByEmail(email);
      if (uuid == null) {
        if (mounted) {
          setState(() => _loading = false);
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Utilisateur introuvable'),
              content: const Text(
                'Aucun utilisateur trouvé avec cet email. '
                'L\'utilisateur doit s\'être connecté au moins une fois.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }
      await sync.upsertSubscription(userId: uuid, plan: _plan);
      // Ajoute l'utilisateur à la liste locale (optimiste) pour qu'il apparaisse
      // immédiatement dans le dashboard. Sans ça, l'utilisateur est créé côté
      // Supabase mais invisible dans le panneau admin.
      store.addPlusByUserId(
        userId: uuid,
        displayName: _name.text.trim().isEmpty ? email : _name.text,
        plan: _plan,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Abonné Plus ajouté avec succès.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ajouter un abonné Plus'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Nom / Pseudo (optionnel)',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              decoration: const InputDecoration(
                labelText: 'Email Google de l\'utilisateur *',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _plan,
              decoration: const InputDecoration(
                labelText: 'Formule *',
                prefixIcon: Icon(Icons.bolt_rounded),
              ),
              items: const [
                DropdownMenuItem(
                    value: 'monthly', child: Text('Mensuel (0,99 €/mois)')),
                DropdownMenuItem(
                    value: 'yearly', child: Text('Annuel (9 €/an)')),
              ],
              onChanged: (v) => setState(() => _plan = v ?? 'monthly'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: _loading ? null : _save,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: const Text('Ajouter'),
        ),
      ],
    );
  }
}

/// Dialog de bannissement manuel d'un compte utilisateur.
class _AddBannedUserDialog extends StatefulWidget {
  const _AddBannedUserDialog();

  @override
  State<_AddBannedUserDialog> createState() => _AddBannedUserDialogState();
}

class _AddBannedUserDialogState extends State<_AddBannedUserDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) return;
    context.read<StoreController>().banManually(
          displayName: _name.text,
          email: _email.text,
          reason: _reason.text,
        );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.block_rounded, color: AppColors.categoryVideo),
          SizedBox(width: 8),
          Text('Bannir un compte'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Nom / Pseudo du compte *',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              decoration: const InputDecoration(
                labelText: 'Email du compte (optionnel)',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              decoration: const InputDecoration(
                labelText: 'Motif du bannissement (optionnel)',
                prefixIcon: Icon(Icons.report_outlined),
                helperText: 'Ex. : contenu inapproprié, spam...',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.categoryVideo.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.categoryVideo.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppColors.categoryVideo),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Le compte banni ne pourra plus soumettre de '
                      'suggestions dans l\'application.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
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
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.categoryVideo,
          ),
          onPressed: _save,
          icon: const Icon(Icons.block_rounded),
          label: const Text('Bannir'),
        ),
      ],
    );
  }
}
