import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n/app_languages.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/trusted_channel.dart';
import '../../domain/trusted_channels_paging.dart';

/// Tableau d'une page du menu « Chaînes YT » (5 jeux par page — migration
/// 0088) : colonnes Jeu | Chaîne | Nom | Langues | Source | Active | Actions.
///
/// Les lignes (triées par le serveur : jeu puis handle) sont regroupées par
/// jeu : le nom du jeu et son nombre de chaînes sont affichés en face de la
/// 1re ligne du groupe ; les groupes sont séparés par un trait marqué et un
/// fond alterné.
///
/// Largeurs : Source / Active / Actions fixes, Jeu proportionnelle (bornée),
/// Chaîne / Nom / Langues se partagent le reste ; les textes longs sont
/// tronqués (infobulle avec le texte complet). Aucun débordement horizontal
/// dès [minWidth] — un panneau de 1 024 px laisse ~750 px au tableau (barre
/// latérale de 230 px et marges comprises) ; en dessous de [minWidth],
/// défilement horizontal plutôt qu'une mise en page cassée.
///
/// Aucune dépendance au StoreController ni à dart:html : testable sur VM.
class TrustedChannelsTable extends StatelessWidget {
  const TrustedChannelsTable({
    super.key,
    required this.channels,
    required this.busyIds,
    required this.onToggleActive,
    required this.onAddGame,
    required this.onDelete,
  });

  /// Lignes de la page, dans l'ordre serveur.
  final List<TrustedChannel> channels;

  /// Lignes dont une opération est en cours : switch remplacé par un
  /// indicateur, boutons grisés (une opération à la fois par ligne).
  final Set<String> busyIds;

  /// Switch « Active » basculé.
  final void Function(TrustedChannel channel, bool active) onToggleActive;

  /// Bouton « Ajouter un jeu pour cette chaîne ».
  final void Function(TrustedChannel channel) onAddGame;

  /// Bouton « Retirer cette chaîne du jeu » (la confirmation est à la charge
  /// de l'appelant).
  final void Function(TrustedChannel channel) onDelete;

  /// Largeur minimale du tableau (en dessous : défilement horizontal).
  static const double minWidth = 640;

  static const double _sourceWidth = 80;
  static const double _activeWidth = 68;
  static const double _actionsWidth = 88;
  static const double _hPad = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : minWidth;
        final double width = math.max(available, minWidth);
        final Widget table = SizedBox(
          width: width,
          child: _table(context, width),
        );
        if (available >= minWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: table,
        );
      },
    );
  }

  Widget _table(BuildContext context, double width) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final Color border = theme.dividerColor;
    final Color muted = theme.textTheme.bodySmall?.color ?? Colors.grey;
    // Colonne Jeu : un quart de l'espace flexible, bornée (lisible sans
    // écraser les colonnes Chaîne / Nom / Langues).
    final double flexible =
        width - 2 * _hPad - _sourceWidth - _activeWidth - _actionsWidth;
    final double gameWidth = (flexible * 0.25).clamp(110.0, 260.0);
    final List<TrustedGameGroup> groups = groupTrustedChannelsByGame(channels);

    return Container(
      decoration: BoxDecoration(
        color: theme.canvasColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // En-tête (même style que AdminDataTable).
          Container(
            color: dark
                ? Colors.white.withValues(alpha: 0.03)
                : Colors.black.withValues(alpha: 0.02),
            padding: const EdgeInsets.symmetric(
              horizontal: _hPad,
              vertical: 12,
            ),
            child: Row(
              children: [
                SizedBox(width: gameWidth, child: _headerText('Jeu', muted)),
                Expanded(child: _headerText('Chaîne', muted)),
                Expanded(child: _headerText('Nom', muted)),
                Expanded(child: _headerText('Langues', muted)),
                SizedBox(
                  width: _sourceWidth,
                  child: _headerText('Source', muted),
                ),
                SizedBox(
                  width: _activeWidth,
                  child: _headerText('Active', muted),
                ),
                SizedBox(
                  width: _actionsWidth,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _headerText('Actions', muted),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: border),
          for (int i = 0; i < groups.length; i++)
            _group(groups[i], i, gameWidth, dark, border, muted),
        ],
      ),
    );
  }

  Widget _headerText(String label, Color muted) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: muted,
      ),
    );
  }

  /// Un groupe « jeu » : cellule Jeu (nom + nombre de chaînes) en face de la
  /// 1re ligne, puis les lignes des chaînes du jeu.
  Widget _group(
    TrustedGameGroup group,
    int index,
    double gameWidth,
    bool dark,
    Color border,
    Color muted,
  ) {
    final int n = group.channels.length;
    return Container(
      key: ValueKey<String>('trusted-group-${group.gameId}'),
      decoration: BoxDecoration(
        // Fond alterné d'un groupe sur deux + trait marqué entre groupes.
        color: index.isOdd
            ? (dark
                  ? Colors.white.withValues(alpha: 0.025)
                  : Colors.black.withValues(alpha: 0.025))
            : null,
        border: index == 0
            ? null
            : Border(top: BorderSide(color: border, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: _hPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gameWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 10, right: 8, bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: group.gameName,
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(
                      group.gameName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$n ${n > 1 ? 'chaînes' : 'chaîne'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int r = 0; r < n; r++)
                  _row(group.channels[r], r == 0, border, muted),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Ligne d'une chaîne : handle, nom, langues, source, switch Active,
  /// actions (ajouter un jeu, retirer).
  Widget _row(TrustedChannel c, bool first, Color border, Color muted) {
    final bool busy = busyIds.contains(c.id);
    final String name = (c.channelName ?? '').trim();
    return Container(
      key: ValueKey<String>('trusted-row-${c.id}'),
      constraints: const BoxConstraints(minHeight: 48),
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(
                top: BorderSide(color: border.withValues(alpha: 0.6)),
              ),
            ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Chaîne : icône (rouge = active) + handle tronqué.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.smart_display_rounded,
                    size: 16,
                    color: c.active ? AppColors.categoryVideo : muted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Tooltip(
                      message: c.channelHandle,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        c.channelHandle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: c.active ? null : muted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Nom de la chaîne (optionnel).
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: name.isEmpty
                  ? Text('—', style: TextStyle(fontSize: 12, color: muted))
                  : Tooltip(
                      message: name,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ),
            ),
          ),
          // Langues exploitées.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: c.langs.isEmpty
                  ? Text('—', style: TextStyle(fontSize: 12, color: muted))
                  : Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [for (final code in c.langs) _langChip(code)],
                    ),
            ),
          ),
          // Source.
          SizedBox(
            width: _sourceWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _sourceBadge(c.source),
            ),
          ),
          // Active : switch (ou indicateur pendant une opération).
          SizedBox(
            width: _activeWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.only(left: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Tooltip(
                      message: c.active ? 'Désactiver' : 'Activer',
                      child: Switch(
                        value: c.active,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (bool v) => onToggleActive(c, v),
                      ),
                    ),
            ),
          ),
          // Actions.
          SizedBox(
            width: _actionsWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  key: ValueKey<String>('trusted-add-game-${c.id}'),
                  tooltip: 'Ajouter un jeu pour cette chaîne',
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: busy ? null : () => onAddGame(c),
                  icon: const Icon(Icons.playlist_add_rounded),
                ),
                IconButton(
                  key: ValueKey<String>('trusted-delete-${c.id}'),
                  tooltip: 'Retirer cette chaîne du jeu',
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  color: AppColors.categoryVideo,
                  onPressed: busy ? null : () => onDelete(c),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          ),
        ],
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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
