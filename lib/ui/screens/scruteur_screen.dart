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
//
// Annuaire de sites (plan Scruteur V3 §4.4, EF v85) : le bouton
// « 📂 Annuaire (N sites) » EN HAUT de l'écran (exigence propriétaire) ouvre
// le dialog de gestion des domaines découverts (candidats / actifs / ignorés
// / protégés anti-bot). Lazy load STRICT : aucun fetch au démarrage ni à
// l'ouverture du menu — uniquement au premier clic sur le bouton.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

import '../../core/theme/colors.dart';
import '../../core/i18n/language_chip.dart' show LanguageBadge, BadgeSize;
import '../../domain/models/category.dart';
import '../../domain/models/suggestion.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';
import 'contents_screen.dart' show ContentEditDialog;

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
              const SizedBox(width: 16),
              // Bouton « 📂 Annuaire (N sites) » EN HAUT de l'écran (exigence
              // propriétaire — plan Scruteur V3 §4.4). Lazy load STRICT : le
              // premier clic déclenche le chargement ; le badge n'apparaît
              // qu'après un chargement réussi (annuaireTotalAll = total tous
              // statuts, jamais écrasé par l'onglet « Protégés anti-bot »).
              FilledButton.icon(
                onPressed: () => _openAnnuaire(store),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: Text(
                  store.annuaireEverLoaded
                      ? '📂 Annuaire (${store.annuaireTotalAll} sites)'
                      : '📂 Annuaire',
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

  /// Ouvre le dialog « Annuaire de sites ». Le premier clic déclenche le
  /// premier chargement (lazy load strict) ; les clics suivants réutilisent
  /// l'état en mémoire (le dialog recharge si besoin selon l'onglet actif).
  void _openAnnuaire(StoreController store) {
    if (!store.annuaireEverLoaded && !store.annuaireLoading) {
      store.loadAnnuaire();
    }
    showDialog<void>(
      context: context,
      builder: (_) => const _AnnuaireAdminDialog(),
    );
  }

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

// ===========================================================================
// Dialog « Annuaire de sites » (plan Scruteur V3 §4.4, EF v85)
// ===========================================================================
// Gestion des domaines découverts par le Scruteur, en 2 onglets :
//   - « Annuaire » : tous statuts (candidat / actif / ignoré / anti-bot) —
//     ajout manuel de domaine + liste paginée (50/page, tri serveur par
//     frequence desc) avec actions par ligne (activer / ignorer / ajouter un
//     contenu / supprimer).
//   - « Protégés anti-bot » : filtre status='bot_protected', chargé au
//     premier clic sur l'onglet ; bouton « Re-tester » (repasse en candidat,
//     Vision.exe retentera via le fallback Jina).
// L'état vit dans le StoreController (lazy load strict — rien n'est chargé
// avant le premier clic sur le bouton d'en-tête) : ce dialog ne fait
// qu'afficher et déléguer ; il rebuild via context.watch à chaque action.
class _AnnuaireAdminDialog extends StatefulWidget {
  const _AnnuaireAdminDialog();

  @override
  State<_AnnuaireAdminDialog> createState() => _AnnuaireAdminDialogState();
}

class _AnnuaireAdminDialogState extends State<_AnnuaireAdminDialog>
    with SingleTickerProviderStateMixin {
  /// Taille de page — DOIT rester alignée sur le défaut de
  /// `SupabaseSync.fetchAnnuaire` (50/page, recommandé par le backend v85).
  static const int _pageSize = 50;

  late final TabController _tabController;
  final TextEditingController _domaineCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    // Cohérence de la vue partagée : si le dialog précédent a été fermé sur
    // l'onglet « Protégés anti-bot », la vue courante du store est filtrée —
    // on recharge la vue complète pour l'onglet principal. Post-frame :
    // jamais de notifyListeners pendant la phase de build du dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<StoreController>();
      if (store.annuaireStatus != null && !store.annuaireLoading) {
        store.loadAnnuaire();
      }
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _domaineCtrl.dispose();
    super.dispose();
  }

  /// Chargement à la demande au changement d'onglet (listener du
  /// TabController) : l'onglet « Protégés anti-bot » est chargé au premier
  /// clic ; le retour à l'onglet principal recharge la vue non filtrée.
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final store = context.read<StoreController>();
    if (_tabController.index == 1) {
      if (store.annuaireStatus != 'bot_protected' && !store.annuaireLoading) {
        store.loadAnnuaire(status: 'bot_protected');
      }
    } else if (store.annuaireStatus != null && !store.annuaireLoading) {
      store.loadAnnuaire();
    }
  }

  /// Ajout manuel d'un domaine (champ + bouton ➕ de l'onglet principal).
  void _ajouterDomaine(StoreController store) {
    final String domain = _domaineCtrl.text;
    if (domain.trim().isEmpty) return;
    store.annuaireAdd(domain);
    _domaineCtrl.clear();
  }

  /// « ➕ Ajouter un contenu » : ouvre le ContentEditDialog pré-rempli
  /// (URL = sample_url ou racine du domaine, catégorie links, jeu
  /// présélectionné si jeux_detectes contient EXACTEMENT un nom qui matche
  /// un jeu du catalogue, insensible à la casse).
  void _ajouterContenu(StoreController store, Map<String, dynamic> row) {
    final String domain = row['root_domain']?.toString() ?? '';
    final String sampleUrl = row['sample_url']?.toString() ?? '';
    final String url = sampleUrl.isNotEmpty ? sampleUrl : 'https://$domain';
    String? gameId;
    final List<dynamic> jeux =
        row['jeux_detectes'] as List? ?? const <dynamic>[];
    if (jeux.length == 1) {
      final String nom = jeux.first?.toString() ?? '';
      for (final g in store.games) {
        if (g.name.toLowerCase() == nom.toLowerCase()) {
          gameId = g.id;
          break;
        }
      }
    }
    showDialog<void>(
      context: context,
      builder: (_) => ContentEditDialog(
        initialUrl: url,
        initialCategory: ContentCategory.links,
        initialGameId: gameId,
      ),
    );
  }

  /// « 🗑️ » : confirmation explicite puis suppression de l'entrée.
  void _supprimer(StoreController store, Map<String, dynamic> row) {
    final String domain = row['root_domain']?.toString() ?? '?';
    showDialog<void>(
      context: context,
      builder: (ctx) => ConfirmDialog(
        title: 'Supprimer « $domain » ?',
        message: 'L\'entrée sera retirée de l\'annuaire. Le Scruteur pourra '
            'la redécouvrir lors d\'un prochain passage.',
        confirmLabel: 'Supprimer',
        destructive: true,
        onConfirm: () => store.annuaireDelete(row['id']?.toString() ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Le dialog rebuild à chaque action (loadAnnuaire / annuaireSetStatus /
    // annuaireDelete / annuaireAdd notifient tous le store).
    final store = context.watch<StoreController>();
    return AlertDialog(
      title: const Text('📂 Annuaire de sites'),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                  text: store.annuaireEverLoaded
                      ? 'Annuaire (${store.annuaireTotalAll})'
                      : 'Annuaire',
                ),
                Tab(
                  text: store.annuaireStatus == 'bot_protected'
                      ? 'Protégés anti-bot (${store.annuaireTotal})'
                      : 'Protégés anti-bot',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildOngletAnnuaire(store),
                  _buildOngletProteges(store),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  /// Onglet 1 « Annuaire » : ajout manuel + liste paginée tous statuts.
  Widget _buildOngletAnnuaire(StoreController store) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _domaineCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ajouter un domaine manuellement',
                  hintText: 'ex. gamefaqs.gamespot.com',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _ajouterDomaine(store),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Ajouter (statut actif, source manuelle)',
              icon: const Icon(Icons.add_circle_rounded,
                  color: AppColors.neonGreen),
              onPressed: () => _ajouterDomaine(store),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: _buildListe(store, filtreAttendu: null)),
        _buildPagination(store, filtreAttendu: null),
      ],
    );
  }

  /// Onglet 2 « Protégés anti-bot » : liste filtrée status='bot_protected',
  /// chargée au premier clic sur l'onglet (listener du TabController).
  Widget _buildOngletProteges(StoreController store) {
    return Column(
      children: [
        Expanded(child: _buildListe(store, filtreAttendu: 'bot_protected')),
        _buildPagination(store, filtreAttendu: 'bot_protected'),
      ],
    );
  }

  /// Liste paginée de la vue dont le filtre est [filtreAttendu]. Si la vue
  /// courante du store ne correspond PAS à cet onglet (changement d'onglet
  /// en cours de chargement), on affiche un spinner — ou un bouton de
  /// (re)chargement explicite si aucun fetch n'est en vol (auto-récupération,
  /// jamais de boucle de retry automatique).
  Widget _buildListe(StoreController store, {required String? filtreAttendu}) {
    if (store.annuaireStatus != filtreAttendu) {
      return _chargementOuFallback(store, filtreAttendu);
    }
    if (store.annuaireLoading && store.annuaireRows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!store.annuaireEverLoaded) {
      // Filet de sécurité : normalement le bouton d'en-tête a déjà déclenché
      // le premier chargement (lazy load strict).
      return Center(
        child: TextButton.icon(
          onPressed: () => store.loadAnnuaire(status: filtreAttendu),
          icon: const Icon(Icons.download_rounded, size: 16),
          label: const Text('Clique pour charger'),
        ),
      );
    }
    if (store.annuaireRows.isEmpty) {
      return const _EmptyHint(text: 'Aucun site dans cette vue.');
    }
    return ListView.separated(
      itemCount: store.annuaireRows.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.grey.withValues(alpha: 0.15)),
      itemBuilder: (_, i) => filtreAttendu == 'bot_protected'
          ? _buildLigneProtege(store, store.annuaireRows[i])
          : _buildLigne(store, store.annuaireRows[i]),
    );
  }

  /// Vue transitoire : spinner si un fetch est en vol, sinon bouton de
  /// chargement explicite (ex. premier affichage de l'onglet « Protégés »
  /// avant que le listener n'ait déclenché le fetch).
  Widget _chargementOuFallback(StoreController store, String? filtreAttendu) {
    if (store.annuaireLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: TextButton.icon(
        onPressed: () => store.loadAnnuaire(status: filtreAttendu),
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: const Text('Charger cette vue'),
      ),
    );
  }

  /// Ligne de l'onglet « Annuaire » : badge statut, domaine, icônes méthode,
  /// frequence, trust_tier, puis les actions (✅ ⚪ ➕ 🗑️).
  Widget _buildLigne(StoreController store, Map<String, dynamic> row) {
    final String domain = row['root_domain']?.toString() ?? '?';
    final String status = row['status']?.toString() ?? 'candidat';
    final String? trustTier = row['trust_tier']?.toString();
    final int frequence = (row['frequence'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _badgeStatut(status),
          const SizedBox(width: 8),
          Expanded(
            child:
                SelectableText(domain, style: const TextStyle(fontSize: 13)),
          ),
          _iconesMethode(row),
          const SizedBox(width: 8),
          // Indice de fréquence (pertinence estimée par le Scruteur).
          Text('×$frequence',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 8),
          _badgeConfiance(trustTier),
          const SizedBox(width: 8),
          if (status != 'actif')
            IconButton(
              tooltip: 'Activer',
              visualDensity: VisualDensity.compact,
              icon: const Text('✅', style: TextStyle(fontSize: 16)),
              onPressed: () => store.annuaireSetStatus(row, 'actif'),
            ),
          if (status != 'ignore')
            IconButton(
              tooltip: 'Ignorer',
              visualDensity: VisualDensity.compact,
              icon: const Text('⚪', style: TextStyle(fontSize: 16)),
              onPressed: () => store.annuaireSetStatus(row, 'ignore'),
            ),
          IconButton(
            tooltip: 'Ajouter un contenu (lien pré-rempli)',
            visualDensity: VisualDensity.compact,
            icon: const Text('➕', style: TextStyle(fontSize: 16)),
            onPressed: () => _ajouterContenu(store, row),
          ),
          IconButton(
            tooltip: 'Supprimer de l\'annuaire',
            visualDensity: VisualDensity.compact,
            icon: const Text('🗑️', style: TextStyle(fontSize: 16)),
            onPressed: () => _supprimer(store, row),
          ),
        ],
      ),
    );
  }

  /// Ligne de l'onglet « Protégés anti-bot » : domaine + bouton
  /// « Re-tester » (repasse le domaine en candidat).
  Widget _buildLigneProtege(StoreController store, Map<String, dynamic> row) {
    final String domain = row['root_domain']?.toString() ?? '?';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child:
                SelectableText(domain, style: const TextStyle(fontSize: 13)),
          ),
          Tooltip(
            message: 'Vision.exe re-testera ce domaine via le fallback Jina '
                'au prochain passage',
            child: OutlinedButton.icon(
              onPressed: () => store.annuaireSetStatus(row, 'candidat'),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Re-tester'),
            ),
          ),
        ],
      ),
    );
  }

  /// Badge de statut coloré : candidat ambre, actif vert, ignoré gris,
  /// bot_protected rouge.
  Widget _badgeStatut(String status) {
    final (Color color, String label) = switch (status) {
      'actif' => (AppColors.neonGreen, 'actif'),
      'ignore' => (Colors.grey, 'ignoré'),
      'bot_protected' => (AppColors.categoryVideo, 'anti-bot'),
      _ => (AppColors.plusGold, 'candidat'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Icônes de méthode de récupération : 🔌 feed (feed_url), 🗺️ sitemap
  /// (sitemap_url), 🔎 recherche interne, 📚 API MediaWiki.
  Widget _iconesMethode(Map<String, dynamic> row) {
    final List<String> icones = <String>[];
    if (row['feed_url'] != null) icones.add('🔌');
    if (row['sitemap_url'] != null) icones.add('🗺️');
    final String? method = row['search_method']?.toString();
    if (method == 'internal_search') icones.add('🔎');
    if (method == 'mediawiki_api') icones.add('📚');
    if (icones.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: 'feed_url : ${row['feed_url'] ?? '—'}\n'
          'sitemap_url : ${row['sitemap_url'] ?? '—'}\n'
          'search_method : ${method ?? '—'}',
      child: Text(icones.join(' '), style: const TextStyle(fontSize: 13)),
    );
  }

  /// Trust tier : 🔒 sure_99 / ❓ a_verifier / — si null ou inconnu.
  Widget _badgeConfiance(String? trustTier) {
    final (String emoji, String message) = switch (trustTier) {
      'sure_99' => ('🔒', 'Domaine sûr (sure_99)'),
      'a_verifier' => ('❓', 'Domaine à vérifier'),
      _ => ('—', 'Confiance inconnue'),
    };
    return Tooltip(
      message: message,
      child: Text(emoji, style: const TextStyle(fontSize: 13)),
    );
  }

  /// Pagination partagée des 2 onglets : ‹ › + « page X / Y ». Masquée tant
  /// que la vue affichée ne correspond pas à l'onglet (filtre transitoire)
  /// ou qu'il n'y a rien à paginer.
  Widget _buildPagination(StoreController store,
      {required String? filtreAttendu}) {
    if (store.annuaireStatus != filtreAttendu ||
        !store.annuaireEverLoaded ||
        store.annuaireTotal == 0) {
      return const SizedBox(height: 40);
    }
    final int totalPages = (store.annuaireTotal + _pageSize - 1) ~/ _pageSize;
    final int pageCourante = store.annuairePage + 1;
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Page précédente',
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: store.annuairePage > 0 && !store.annuaireLoading
                ? () => store.loadAnnuaire(
                    page: store.annuairePage - 1, status: store.annuaireStatus)
                : null,
          ),
          Text('page $pageCourante / $totalPages',
              style: const TextStyle(fontSize: 12)),
          IconButton(
            tooltip: 'Page suivante',
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed:
                store.annuairePage < totalPages - 1 && !store.annuaireLoading
                    ? () => store.loadAnnuaire(
                        page: store.annuairePage + 1,
                        status: store.annuaireStatus)
                    : null,
          ),
        ],
      ),
    );
  }
}
