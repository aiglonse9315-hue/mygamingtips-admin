import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/app_languages.dart';
import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/game.dart';
import '../../domain/models/trusted_channel.dart';
import '../../domain/trusted_channels_paging.dart';
import '../../state/store_controller.dart';
import '../widgets/banned_channels_panel.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/trusted_channels_table.dart';

/// Écran « Chaînes YT » — gestion des chaînes YouTube de confiance par jeu,
/// accessible à **tous les administrateurs**.
///
/// Ces chaînes alimentent la collecte automatique (Snifeur / Vision) : seules
/// les vidéos des chaînes actives sont exploitées pour le jeu correspondant.
/// Une même chaîne (handle) peut être liée à plusieurs jeux (une ligne par
/// jeu, gérable indépendamment).
///
/// Pagination SERVEUR PAR JEU (migration 0088 — demande propriétaire du
/// 25/09/2026 : l'écran chargeait les ~1 500 chaînes et construisait ~1 900
/// cartes d'un coup) : tableau de 5 jeux par page, recherche SERVEUR
/// (handle, nom de chaîne ou nom du jeu) avec anti-rebond, totaux exacts.
/// Les données viennent de la route Edge Function `trusted-channels/list`
/// en mode page (service_role). Comme Contributeurs et Comptes, cet écran
/// fait ses propres appels (pas de dataset synchronisé) : états chargement /
/// erreur / vide / données, refresh par bouton + tirer-pour-actualiser.
class TrustedChannelsScreen extends StatefulWidget {
  const TrustedChannelsScreen({super.key});

  @override
  State<TrustedChannelsScreen> createState() => _TrustedChannelsScreenState();
}

class _TrustedChannelsScreenState extends State<TrustedChannelsScreen> {
  /// Délai entre la dernière frappe et la recherche serveur.
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  /// Page affichée (réponse serveur) — null tant qu'aucune page n'a été
  /// chargée.
  TrustedChannelsPage? _data;

  /// Recherche correspondant à la page affichée (message de l'état vide).
  String _shownSearch = '';

  bool _loading = false;
  String? _error;

  /// Recherche serveur courante (handle, nom de chaîne ou nom du jeu),
  /// normalisée : rognée, 100 caractères max.
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  /// Numéro du dernier chargement : seule la réponse la plus récente est
  /// affichée (frappes rapides, clics de pagination successifs).
  int _loadSeq = 0;

  /// Identifiants des lignes en cours d'opération (switch Actif ou
  /// suppression) — une opération à la fois par ligne.
  final Set<String> _busyIds = <String>{};

  /// Page affichée (0 tant que rien n'est chargé).
  int get _page => _data?.page ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Charge le catalogue de jeux (paresseux : skip si déjà frais) pour le
      // sélecteur de jeu des dialogs d'ajout.
      context.read<StoreController>().ensureDatasets({SyncDataset.games});
      _load(0);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Charge la page [page] (5 jeux) pour la recherche courante via la route
  /// EF `trusted-channels/list` en mode page. Si cette page n'existe plus
  /// (ex. dernière chaîne du dernier jeu de la dernière page retirée), recule
  /// sur la dernière page existante.
  Future<void> _load(int page) async {
    final SupabaseSync? sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() => _error = 'Mode démo : pas de connexion Supabase.');
      return;
    }
    final int seq = ++_loadSeq;
    final String search = _search;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final TrustedChannelsPage res = await sync.fetchTrustedChannelsPage(
        search: search,
        page: page,
        gamesPerPage: kTrustedGamesPerPage,
      );
      // Réponse obsolète (une recherche ou une page plus récente a été
      // demandée entre-temps) : ignorée.
      if (!mounted || seq != _loadSeq) return;
      final int? fallback = res.fallbackPage;
      if (fallback != null) {
        unawaited(_load(fallback));
        return;
      }
      setState(() {
        _data = res;
        _shownSearch = search;
        _loading = false;
      });
    } on AdminAuthException {
      // 401 : session expirée → logout forcé (même règle que les écritures).
      if (!mounted) return;
      if (seq == _loadSeq) setState(() => _loading = false);
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = _errorMessage(e);
        _loading = false;
      });
      // Si une page est déjà affichée, elle reste visible : l'erreur de
      // rafraîchissement est signalée par SnackBar, pas en pleine page.
      if (_data != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rafraîchissement échoué : ${_errorMessage(e)}'),
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Va à la page [page], bornée aux pages existantes de [data].
  void _goTo(TrustedChannelsPage data, int page) {
    _load(clampTrustedPage(page, data.totalGames, data.gamesPerPage));
  }

  /// Recharge la page affichée (après un ajout ou une suppression ; recule
  /// d'une page si elle est devenue vide — voir [_load]).
  void _reloadCurrentPage() {
    if (mounted) _load(_page);
  }

  /// Recherche serveur, lancée 350 ms après la dernière frappe (retour à la
  /// première page).
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      final String q = normalizeTrustedSearch(value);
      if (!mounted || q == _search) return;
      _search = q;
      _load(0);
    });
  }

  /// Extrait un message d'erreur lisible : retire le préfixe « Exception: »
  /// produit par le `toString()` des exceptions Dart.
  static String _errorMessage(Object e) {
    const prefix = 'Exception: ';
    final String msg = e.toString();
    return msg.startsWith(prefix) ? msg.substring(prefix.length) : msg;
  }

  // ── Actions ──

  /// Active/désactive une chaîne (upsert de la ligne existante avec la
  /// nouvelle valeur `active`), puis met à jour la ligne en mémoire.
  Future<void> _toggleActive(TrustedChannel channel, bool active) async {
    final SupabaseSync? sync = context.read<StoreController>().sync;
    if (sync == null || _busyIds.contains(channel.id)) return;
    setState(() => _busyIds.add(channel.id));
    try {
      final TrustedChannel updated = await sync.upsertTrustedChannel(
        id: channel.id,
        gameId: channel.gameId,
        channelHandle: channel.channelHandle,
        channelName: channel.channelName,
        channelId: channel.channelId,
        langs: channel.langs,
        active: active,
        source: channel.source,
      );
      if (!mounted) return;
      final TrustedChannelsPage? data = _data;
      if (data != null) {
        setState(() {
          _data = data.withChannels(replaceTrustedRow(data.channels, updated));
        });
      }
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e)),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(channel.id));
    }
  }

  /// Demande confirmation puis supprime la ligne (la chaîne YouTube et le
  /// jeu ne sont pas touchés).
  void _confirmDelete(TrustedChannel channel) {
    showDialog<void>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: 'Retirer ${channel.channelHandle} ?',
        message:
            'La chaîne ${channel.channelHandle} ne sera plus exploitée '
            'pour « ${channel.gameName} ». La chaîne YouTube et le jeu ne '
            'sont pas supprimés.',
        confirmLabel: 'Retirer',
        destructive: true,
        onConfirm: () => _delete(channel),
      ),
    );
  }

  /// Supprime la ligne : retrait immédiat du tableau, puis rechargement de
  /// la page courante (totaux à jour, jeu suivant qui remonte ; recul d'une
  /// page si elle devient vide).
  Future<void> _delete(TrustedChannel channel) async {
    final SupabaseSync? sync = context.read<StoreController>().sync;
    if (sync == null || _busyIds.contains(channel.id)) return;
    setState(() => _busyIds.add(channel.id));
    try {
      await sync.deleteTrustedChannel(channel.id);
      if (!mounted) return;
      final TrustedChannelsPage? data = _data;
      if (data != null) {
        setState(() {
          _data = data.withChannels(
            data.channels.where((c) => c.id != channel.id).toList(),
          );
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Chaîne ${channel.channelHandle} retirée de '
            '« ${channel.gameName} ».',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      _reloadCurrentPage();
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e)),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(channel.id));
    }
  }

  /// Ouvre le dialog d'ajout d'une nouvelle chaîne (rechargement de la page
  /// courante après enregistrement).
  void _showAddDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => ChannelEditDialog(
        linkedGameIds: const <String>{},
        onSaved: _reloadCurrentPage,
      ),
    );
  }

  /// Ouvre le dialog « Ajouter un jeu » pour une chaîne existante : même
  /// handle (verrouillé), autre jeu, langues pré-remplies de la chaîne.
  /// Les jeux déjà liés à ce handle sont lus au serveur à l'OUVERTURE
  /// (toute la table, hors des pages) ; en cas d'échec, seuls ceux de la
  /// page sont exclus (le serveur dédoublonne jeu + handle de toute façon).
  Future<void> _showAddGameDialog(TrustedChannel channel) async {
    final SupabaseSync? sync = context.read<StoreController>().sync;
    if (_busyIds.contains(channel.id)) return;
    List<String> serverIds = const <String>[];
    if (sync != null) {
      setState(() => _busyIds.add(channel.id));
      try {
        serverIds =
            await sync.fetchTrustedChannelGameIds(channel.channelHandle);
      } on AdminAuthException {
        if (mounted) context.read<StoreController>().onAuthError?.call();
        return;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Jeux déjà liés non lus (${_errorMessage(e)}) : seuls '
                'ceux de la page sont exclus.',
              ),
              backgroundColor: Colors.orange.shade700,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _busyIds.remove(channel.id));
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ChannelEditDialog(
        existing: channel,
        // Exclut du sélecteur les jeux déjà liés à CE handle.
        linkedGameIds: linkedGameIdsForHandle(
          channel,
          _data?.channels ?? const <TrustedChannel>[],
          serverGameIds: serverIds,
        ),
        onSaved: _reloadCurrentPage,
      ),
    );
  }

  // ── Construction ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHelpCard(theme),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  // Recherche SERVEUR (anti-rebond 350 ms, retour page 1).
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Rechercher une chaîne ou un jeu…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Actualiser',
                onPressed: _loading ? null : _reloadCurrentPage,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _showAddDialog,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Ajouter une chaîne'),
              ),
              const SizedBox(width: 8),
              // Chantier B (§70.3) : panneau des chaînes bannies (purge auto
              // de la file pending au ban ; publiés rapportés, retrait
              // manuel au clic du rapport).
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.categoryVideo,
                  side: BorderSide(
                    color: AppColors.categoryVideo.withValues(alpha: 0.6),
                  ),
                ),
                onPressed: () => BannedChannelsPanel.show(context),
                icon: const Icon(Icons.block_rounded, size: 18),
                label: const Text('🚫 Bannir'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  /// Encart d'aide en tête d'écran.
  Widget _buildHelpCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.neonCyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.neonCyan.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.video_library_outlined,
            size: 20,
            color: AppColors.neonCyan,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Chaînes YouTube de confiance exploitées par la collecte '
              '(Snifeur / Vision). Une même chaîne peut être liée à '
              'plusieurs jeux.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final TrustedChannelsPage? data = _data;

    if (data == null) {
      // État erreur pleine page SEULEMENT s'il n'y a rien à montrer
      // (premier chargement échoué, mode démo) ; sinon la page reste
      // visible (l'erreur a été signalée par SnackBar).
      if (_error != null) return _buildErrorState();
      // État chargement initial.
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }

    // Page vidée pendant un rechargement (ex. dernière ligne retirée) :
    // indicateur plutôt qu'un faux « aucun résultat ».
    if (data.channels.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }

    // État vide.
    if (data.channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 40,
              color: theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(height: 12),
            Text(
              _shownSearch.isEmpty
                  ? 'Aucune chaîne de confiance pour le moment.'
                  : 'Aucune chaîne ne correspond à « $_shownSearch ».',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (_shownSearch.isEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Ajoutez une chaîne avec le bouton « Ajouter une chaîne ».',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
    }

    // Données : barre de pagination + tableau des 5 jeux de la page.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPageBar(data),
        SizedBox(
          height: 2,
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(_page),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                TrustedChannelsTable(
                  channels: data.channels,
                  busyIds: _busyIds,
                  onToggleActive: _toggleActive,
                  onAddGame: (TrustedChannel c) =>
                      unawaited(_showAddGameDialog(c)),
                  onDelete: _confirmDelete,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Erreur pleine page (rien à montrer) + bouton « Réessayer ».
  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: Colors.orange.shade300,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _error!,
                    style: TextStyle(color: Colors.orange.shade300),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading ? null : _reloadCurrentPage,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Réessayer'),
          ),
        ],
      ),
    );
  }

  /// Barre de pagination (même présentation que Contenus / Abonnements) :
  /// première / précédente / « Page X / N (jeux a-b sur T · C chaînes) » /
  /// suivante / dernière. Boutons grisés pendant un chargement.
  Widget _buildPageBar(TrustedChannelsPage data) {
    final int lastPage = data.pageCount - 1;
    final bool canBack = data.page > 0 && !_loading;
    final bool canForward = data.page < lastPage && !_loading;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.first_page_rounded),
          onPressed: canBack ? () => _goTo(data, 0) : null,
          tooltip: 'Première page',
        ),
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: canBack ? () => _goTo(data, data.page - 1) : null,
          tooltip: 'Page précédente',
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            data.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: canForward ? () => _goTo(data, data.page + 1) : null,
          tooltip: 'Page suivante',
        ),
        IconButton(
          icon: const Icon(Icons.last_page_rounded),
          onPressed: canForward ? () => _goTo(data, lastPage) : null,
          tooltip: 'Dernière page',
        ),
      ],
    );
  }
}

/// Dialog d'ajout d'une chaîne de confiance.
///
/// Deux modes :
/// - **Nouvelle chaîne** ([existing] null) : handle libre (préfixe `@`
///   automatique), sélecteur de jeu sur tout le catalogue, langues FR/EN
///   cochées par défaut.
/// - **Ajouter un jeu** ([existing] fourni) : handle VERROUILLÉ en lecture
///   seule, sélecteur limité aux jeux pas encore liés à ce handle
///   ([linkedGameIds]), langues pré-remplies de la chaîne. L'upsert crée une
///   nouvelle ligne (même handle, autre `game_id`).
class ChannelEditDialog extends StatefulWidget {
  const ChannelEditDialog({
    super.key,
    this.existing,
    required this.linkedGameIds,
    required this.onSaved,
  });

  /// Chaîne existante (mode « Ajouter un jeu ») — null en mode création.
  final TrustedChannel? existing;

  /// Identifiants des jeux déjà liés à ce handle (exclus du sélecteur).
  final Set<String> linkedGameIds;

  /// Callback appelé après un enregistrement réussi (rechargement).
  final VoidCallback onSaved;

  @override
  State<ChannelEditDialog> createState() => _ChannelEditDialogState();
}

class _ChannelEditDialogState extends State<ChannelEditDialog> {
  late final TextEditingController _handle;
  late final TextEditingController _channelName;
  String? _gameId;
  late final Set<String> _langs;

  bool _saving = false;
  String? _statusMessage;
  bool _statusError = false;

  @override
  void initState() {
    super.initState();
    _handle = TextEditingController(
      text: widget.existing?.channelHandle ?? '',
    );
    _channelName = TextEditingController(
      text: widget.existing?.channelName ?? '',
    );
    // Mode création : FR/EN cochées par défaut. Mode « Ajouter un jeu » :
    // langues pré-remplies de la chaîne (FR/EN si la chaîne n'en a pas).
    _langs = widget.existing != null
        ? {...widget.existing!.langs}
        : {'FR', 'EN'};
    if (_langs.isEmpty) _langs.addAll({'FR', 'EN'});
  }

  @override
  void dispose() {
    _handle.dispose();
    _channelName.dispose();
    super.dispose();
  }

  /// Normalise le handle saisi : espaces retirés, préfixe `@` garanti.
  static String _normalizeHandle(String raw) {
    var h = raw.trim();
    while (h.startsWith('@')) {
      h = h.substring(1);
    }
    return h.isEmpty ? '' : '@$h';
  }

  Future<void> _save() async {
    final StoreController store = context.read<StoreController>();
    final sync = store.sync;
    if (_saving) return;
    if (sync == null) {
      setState(() {
        _statusMessage = 'Mode démo : chaînes non persistées.';
        _statusError = true;
      });
      return;
    }

    final String handle = _normalizeHandle(_handle.text);
    final String? gameId = _gameId;
    if (gameId == null || handle.isEmpty || _langs.isEmpty) {
      setState(() {
        _statusMessage = 'Jeu, handle et au moins une langue sont requis.';
        _statusError = true;
      });
      return;
    }

    setState(() {
      _saving = true;
      _statusMessage = null;
    });
    try {
      await sync.upsertTrustedChannel(
        // Pas d'id : toujours une NOUVELLE ligne (même en mode « Ajouter un
        // jeu » — même handle, autre game_id).
        gameId: gameId,
        channelHandle: handle,
        channelName: _channelName.text.trim().isEmpty
            ? null
            : _channelName.text.trim(),
        langs: _langs.toList()..sort(),
        active: true,
        source: 'admin',
      );
      if (!mounted) return;
      Navigator.pop(context);
      widget.onSaved();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Chaîne $handle enregistrée.'),
          duration: const Duration(seconds: 4),
        ),
      );
    } on AdminAuthException {
      if (!mounted) return;
      Navigator.pop(context);
      store.onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _statusMessage = _TrustedChannelsScreenState._errorMessage(e);
        _statusError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool addGameMode = widget.existing != null;
    final List<Game> games = context.watch<StoreController>().games.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    // En mode « Ajouter un jeu » : uniquement les jeux pas encore liés.
    final List<Game> selectable = addGameMode
        ? games.where((g) => !widget.linkedGameIds.contains(g.id)).toList()
        : games;
    // Garde-fou : la valeur du dropdown doit exister dans les items.
    final String? dropdownValue =
        selectable.any((g) => g.id == _gameId) ? _gameId : null;

    return AlertDialog(
      title: Text(
        addGameMode
            ? 'Ajouter un jeu — ${widget.existing!.channelHandle}'
            : 'Ajouter une chaîne',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle : verrouillé en mode « Ajouter un jeu ».
              TextField(
                controller: _handle,
                readOnly: addGameMode,
                enabled: !addGameMode,
                decoration: const InputDecoration(
                  labelText: 'Handle YouTube *',
                  hintText: '@NomDeLaChaine',
                  helperText: 'Le préfixe @ est ajouté automatiquement',
                ),
              ),
              if (!addGameMode) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _channelName,
                  decoration: const InputDecoration(
                    labelText: 'Nom de la chaîne (optionnel)',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                // initialValue (et non value, déprécié) : le FormField gère
                // ensuite sa propre sélection ; _gameId la suit via onChanged.
                initialValue: dropdownValue,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: addGameMode ? 'Autre jeu *' : 'Jeu *',
                ),
                items: selectable
                    .map((g) => DropdownMenuItem(
                          value: g.id,
                          child: Text(
                            g.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _gameId = v),
              ),
              if (selectable.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    games.isEmpty
                        ? 'Chargement du catalogue de jeux…'
                        : 'Cette chaîne est déjà liée à tous les jeux.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Langues exploitées *',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final lang in kSupportedLanguages)
                    FilterChip(
                      label: Text('${lang.flag} ${lang.code}'),
                      selected: _langs.contains(lang.code),
                      onSelected: _saving
                          ? null
                          : (selected) => setState(() {
                                if (selected) {
                                  _langs.add(lang.code);
                                } else {
                                  _langs.remove(lang.code);
                                }
                              }),
                    ),
                ],
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _statusMessage!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _statusError
                        ? AppColors.categoryVideo
                        : AppColors.neonGreen,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: _saving || selectable.isEmpty ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_rounded, size: 18),
          label: Text(addGameMode ? 'Ajouter' : 'Enregistrer'),
        ),
      ],
    );
  }
}
