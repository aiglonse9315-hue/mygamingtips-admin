import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/app_languages.dart';
import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/game.dart';
import '../../domain/models/trusted_channel.dart';
import '../../state/store_controller.dart';
import '../widgets/banned_channels_panel.dart';
import '../widgets/confirm_dialog.dart';

/// Écran « Chaînes YT » — gestion des chaînes YouTube de confiance par jeu,
/// accessible à **tous les administrateurs**.
///
/// Ces chaînes alimentent la collecte automatique (Snifeur / Vision) : seules
/// les vidéos des chaînes actives sont exploitées pour le jeu correspondant.
/// Une même chaîne (handle) peut être liée à plusieurs jeux (une ligne par
/// jeu, gérable indépendamment).
///
/// Les données viennent des routes Edge Function `trusted-channels/*`
/// (service_role). Comme Contributeurs et Comptes, cet écran fait ses propres
/// appels (pas de dataset synchronisé) : états chargement / erreur / vide /
/// données, refresh par bouton + tirer-pour-actualiser.
class TrustedChannelsScreen extends StatefulWidget {
  const TrustedChannelsScreen({super.key});

  @override
  State<TrustedChannelsScreen> createState() => _TrustedChannelsScreenState();
}

class _TrustedChannelsScreenState extends State<TrustedChannelsScreen> {
  List<TrustedChannel> _channels = <TrustedChannel>[];

  bool _loading = false;
  String? _error;

  /// Filtre texte (handle ou nom de jeu).
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// Identifiants des lignes en cours d'opération (switch Actif ou
  /// suppression) — une opération à la fois par ligne.
  final Set<String> _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Charge le catalogue de jeux (paresseux : skip si déjà frais) pour le
      // sélecteur de jeu des dialogs d'ajout.
      context.read<StoreController>().ensureDatasets({SyncDataset.games});
      _load();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Charge la liste des chaînes via la route EF `trusted-channels/list`.
  Future<void> _load() async {
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
      final channels = await sync.fetchTrustedChannels();
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _loading = false;
      });
    } on AdminAuthException {
      // 401 : session expirée → logout forcé (même règle que les écritures).
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errorMessage(e);
        _loading = false;
      });
      // Si la liste est déjà affichée, elle reste visible : l'erreur de
      // rafraîchissement est signalée par SnackBar, pas en pleine page.
      if (_channels.isNotEmpty) {
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
    final sync = context.read<StoreController>().sync;
    if (sync == null || _busyIds.contains(channel.id)) return;
    setState(() => _busyIds.add(channel.id));
    try {
      final updated = await sync.upsertTrustedChannel(
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
      setState(() {
        _channels = [
          for (final c in _channels)
            if (c.id == channel.id) updated else c,
        ];
      });
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
  /// jeu ne sont pas touchés), puis retire la ligne de la liste.
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

  Future<void> _delete(TrustedChannel channel) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null || _busyIds.contains(channel.id)) return;
    setState(() => _busyIds.add(channel.id));
    try {
      await sync.deleteTrustedChannel(channel.id);
      if (!mounted) return;
      setState(() {
        _channels = _channels.where((c) => c.id != channel.id).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Chaîne ${channel.channelHandle} retirée de '
            '« ${channel.gameName} ».',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
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

  /// Ouvre le dialog d'ajout d'une nouvelle chaîne.
  void _showAddDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => ChannelEditDialog(
        linkedGameIds: const <String>{},
        onSaved: _load,
      ),
    );
  }

  /// Ouvre le dialog « Ajouter un jeu » pour une chaîne existante : même
  /// handle (verrouillé), autre jeu, langues pré-remplies de la chaîne.
  void _showAddGameDialog(TrustedChannel channel) {
    // Exclut du sélecteur les jeux déjà liés à CE handle.
    final linked = _channels
        .where((c) =>
            c.channelHandle.toLowerCase() ==
            channel.channelHandle.toLowerCase())
        .map((c) => c.gameId)
        .toSet();
    showDialog<void>(
      context: context,
      builder: (_) => ChannelEditDialog(
        existing: channel,
        linkedGameIds: linked,
        onSaved: _load,
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
                  onChanged: (v) => setState(() => _search = v),
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
                onPressed: _loading ? null : _load,
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
          const Icon(Icons.video_library_outlined,
              size: 20, color: AppColors.neonCyan),
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
    // État erreur — pleine page SEULEMENT s'il n'y a rien à montrer ; sinon
    // la liste reste visible (l'erreur a été signalée par SnackBar).
    if (_error != null && _channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: Colors.orange.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: Colors.orange.shade300),
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
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      );
    }

    // État chargement initial (aucune donnée à montrer).
    if (_loading && _channels.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }

    // Filtre texte (handle ou nom de jeu).
    final String q = _search.trim().toLowerCase();
    final List<TrustedChannel> filtered = q.isEmpty
        ? _channels
        : _channels
            .where((c) =>
                c.channelHandle.toLowerCase().contains(q) ||
                c.gameName.toLowerCase().contains(q) ||
                (c.channelName?.toLowerCase().contains(q) ?? false))
            .toList();

    // État vide.
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined,
                size: 40, color: theme.textTheme.bodySmall?.color),
            const SizedBox(height: 12),
            Text(
              q.isEmpty
                  ? 'Aucune chaîne de confiance pour le moment.'
                  : 'Aucune chaîne ne correspond à « $_search ».',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (q.isEmpty) ...[
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

    // Regroupement par jeu (nom trié alphabétiquement), chaînes triées par
    // handle au sein de chaque groupe.
    final Map<String, List<TrustedChannel>> byGame =
        <String, List<TrustedChannel>>{};
    for (final c in filtered) {
      byGame.putIfAbsent(c.gameName, () => <TrustedChannel>[]).add(c);
    }
    final List<String> gameNames = byGame.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final list in byGame.values) {
      list.sort((a, b) => a.channelHandle
          .toLowerCase()
          .compareTo(b.channelHandle.toLowerCase()));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          for (final gameName in gameNames) ...[
            _buildGameHeader(theme, gameName, byGame[gameName]!),
            const SizedBox(height: 6),
            for (final channel in byGame[gameName]!) ...[
              _buildChannelCard(theme, channel),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  /// En-tête d'un groupe jeu : nom + nombre de chaînes.
  Widget _buildGameHeader(
    ThemeData theme,
    String gameName,
    List<TrustedChannel> channels,
  ) {
    return Row(
      children: [
        Icon(Icons.sports_esports_rounded,
            size: 18, color: theme.textTheme.bodySmall?.color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            gameName,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          '${channels.length} chaîne(s)',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  /// Carte d'une chaîne : handle, nom, chips langues, badge source, switch
  /// Actif, boutons « Ajouter un jeu » et Supprimer.
  Widget _buildChannelCard(ThemeData theme, TrustedChannel channel) {
    final bool busy = _busyIds.contains(channel.id);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.smart_display_rounded,
              size: 28,
              color: channel.active
                  ? AppColors.categoryVideo
                  : theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        channel.channelHandle,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      _sourceBadge(channel.source),
                      if (!channel.active)
                        _badge('Inactive', theme.textTheme.bodySmall?.color ??
                            Colors.grey),
                    ],
                  ),
                  if (channel.channelName != null &&
                      channel.channelName!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      channel.channelName!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final code in channel.langs) _langChip(code),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Ajouter un jeu pour cette chaîne',
              onPressed: busy ? null : () => _showAddGameDialog(channel),
              icon: const Icon(Icons.playlist_add_rounded, size: 20),
            ),
            if (busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              Tooltip(
                message: channel.active ? 'Désactiver' : 'Activer',
                child: Switch(
                  value: channel.active,
                  onChanged: (v) => _toggleActive(channel, v),
                ),
              ),
              IconButton(
                tooltip: 'Retirer cette chaîne du jeu',
                onPressed: () => _confirmDelete(channel),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: AppColors.categoryVideo,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Chip d'un code langue (drapeau + code si la langue est connue).
  Widget _langChip(String code) {
    final AppLanguage? lang = findLanguage(code);
    final Color color = lang?.color ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        lang != null ? '${lang.flag} ${lang.code}' : code,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// Badge de provenance : `const` (liste initiale), `snifeur` (découverte
  /// automatique) ou `admin` (ajout manuel).
  Widget _sourceBadge(String source) {
    final (String label, Color color) = switch (source) {
      'const' => ('Const', AppColors.categoryLink),
      'snifeur' => ('Snifeur', AppColors.neonViolet),
      'admin' => ('Admin', AppColors.neonCyan),
      _ => (source, Colors.grey),
    };
    return _badge(label, color);
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
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
