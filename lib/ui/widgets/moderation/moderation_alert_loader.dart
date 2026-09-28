// Chargement de la carte « Modération automatique » du tableau de bord
// (P4b-3, lot L6, T9, D1, conception §6.10) : lit les réglages au montage
// (après la première image, motif `limits_alert_card.dart`) et sur ↻ —
// jamais de minuterie — puis monte `ModerationAlertView` (lot L5).
//
// - 403 (`AdminForbiddenException`, claims « compte principal » périmés) →
//   la carte DISPARAÎT ;
// - 401 (`AdminAuthException`) → `onAuthError` (déconnexion), rien affiché ;
// - autre erreur → ligne « État de la modération illisible. » + ↻, sans
//   SnackBar ; les réglages déjà lus restent affichés.
// Seule la lecture la plus récente est appliquée (clics ↻ rapprochés).
//
// Le chargeur est INJECTÉ (`sync.fetchModerationSettings`) : widget « de
// présentation » sans Provider → testable en VM. La colle Provider est
// `moderation_alert_card.dart`.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, errorText;
import '../../../domain/models/moderation.dart';
import 'moderation_alert_view.dart';

class ModerationAlertLoader extends StatefulWidget {
  const ModerationAlertLoader({
    super.key,
    required this.load,
    required this.onAuthError,
    required this.onOpen,
    this.padding = EdgeInsets.zero,
  });

  /// `sync.fetchModerationSettings()`.
  final Future<ModerationSettings> Function() load;

  /// 401 : déconnexion (`store.onAuthError`).
  final VoidCallback onAuthError;

  /// « Ouvrir la modération ».
  final VoidCallback onOpen;

  /// Marge autour de la carte (disparaît avec elle sur un 403).
  final EdgeInsetsGeometry padding;

  @override
  State<ModerationAlertLoader> createState() => _ModerationAlertLoaderState();
}

class _ModerationAlertLoaderState extends State<ModerationAlertLoader> {
  ModerationSettings? _settings;
  bool _loading = false;
  String? _error;

  /// 403 ou 401 : la carte n'est plus affichée.
  bool _hidden = false;

  /// Numéro de la dernière lecture (seule la plus récente compte).
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    final int seq = ++_seq;
    // Lu AVANT l'attente : appelé même si la carte a disparu entre-temps.
    final VoidCallback onAuthError = widget.onAuthError;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ModerationSettings s = await widget.load();
      if (!mounted || seq != _seq) return;
      setState(() {
        _settings = s;
        _loading = false;
      });
    } on AdminForbiddenException {
      if (!mounted || seq != _seq) return;
      setState(() {
        _hidden = true;
        _loading = false;
      });
    } on AdminAuthException {
      // Revue P4b-3 (ARC-04) : seule la mise à jour de la carte dépend de
      // mounted / de la séquence ; la déconnexion a lieu DANS TOUS LES CAS
      // (carte quittée pendant la lecture comprise), comme les onglets de
      // Modération.
      if (mounted && seq == _seq) {
        setState(() {
          _hidden = true;
          _loading = false;
        });
      }
      onAuthError();
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: ModerationAlertView(
        settings: _settings,
        loading: _loading,
        error: _error,
        onRefresh: _refresh,
        onOpen: widget.onOpen,
      ),
    );
  }
}
