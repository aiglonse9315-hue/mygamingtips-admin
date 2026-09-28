// Onglet « Réglages » de l'écran Modération (P4b-3, lot L7, conception §6.6)
// : lecture `moderation/settings-get` ; chaque écriture =
// `updateModerationSettings(<clés modifiées seules>)` puis remplacement des
// réglages par la réponse ; 400 → message du serveur (+ champs refusés
// traduits seulement si la liste n'est pas vide, C-02) ; erreur incertaine
// → relecture (T2) ; 401 → déconnexion ; 403 → état 403.
//
// Sections : 1. interrupteur (« Allumer » = confirmation FORTE, S-01 ;
// « Éteindre » = confirmation simple) ; 2. disjoncteur (« Voir
// l'événement », « Réarmer » = même corps qu'« Allumer », confirmation FORTE
// avec compteurs et avertissement si un plafond est déjà atteint, UX-01) ;
// 3. plafonds (champs changés seuls, confirmation d'une HAUSSE, S-07) ;
// 4. empreintes autorisées (liste ENTIÈRE remplacée ; relecture serveur
// avant l'envoi : liste changée ailleurs → avertissement + « Recharger »,
// rien envoyé ; sinon dialogue des différences, S-07) ; 5. compteurs ;
// 6. purge des preuves anciennes (aperçu puis confirmation).
//
// Onglet gardé en vie (saisies conservées au changement d'onglet). Aucun
// Provider : testable en VM.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        FilteringTextInputFormatter,
        TextInputFormatter;

import '../../../data/supabase_sync.dart'
    show
        AdminApiException,
        AdminAuthException,
        AdminForbiddenException,
        SupabaseSync,
        errorText,
        isUncertainFailure;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_screen_rules.dart';
import '../../../domain/moderation_text.dart';
import '../../widgets/moderation/moderation_ui.dart';
import '../../widgets/moderation/review_detail_dialog.dart';
import '../../widgets/moderation/strong_confirm_dialog.dart';
import 'moderation_common.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.sync,
    required this.onAuthError,
    this.onSettings,
    this.refreshSeq = 0,
  });

  final SupabaseSync sync;
  final VoidCallback onAuthError;

  /// Réglages lus ou écrits : l'écran met à jour son en-tête.
  final ValueChanged<ModerationSettings>? onSettings;
  final int refreshSeq;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab>
    with AutomaticKeepAliveClientMixin {
  ModerationSettings? _s;
  bool _loading = false;
  bool _forbidden = false;
  bool _busy = false;
  String? _error;
  int _loadSeq = 0;

  final TextEditingController _hour = TextEditingController();
  final TextEditingController _day = TextEditingController();
  final TextEditingController _sha = TextEditingController();
  final TextEditingController _days = TextEditingController(
    text: '$kPurgeDaysDefault',
  );
  String? _hourError;
  String? _dayError;
  String? _shaError;
  String? _daysError;

  /// Liste chargée (référence de la comparaison S-07) et liste en cours
  /// d'édition.
  List<String> _baselineRules = const <String>[];
  List<String> _draftRules = const <String>[];
  bool _rulesChangedOnServer = false;

  EvidencePurgeResult? _evidencePreview;
  int? _previewDays;
  String? _evidenceResult;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(SettingsTab old) {
    super.didUpdateWidget(old);
    if (old.refreshSeq != widget.refreshSeq) unawaited(_load());
  }

  @override
  void dispose() {
    _hour.dispose();
    _day.dispose();
    _sha.dispose();
    _days.dispose();
    super.dispose();
  }

  // ── Lecture / écriture ─────────────────────────────────────────────────────

  /// Lecture des réglages ; [full] : saisies en cours (plafonds, liste)
  /// remplacées par les valeurs du serveur.
  Future<void> _load({bool full = true}) async {
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ModerationSettings s = await widget.sync.fetchModerationSettings();
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _apply(s, resetCeilings: full, resetRules: full);
        _loading = false;
        _forbidden = false;
      });
      widget.onSettings?.call(s);
    } on AdminAuthException {
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
      widget.onAuthError();
    } on AdminForbiddenException {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _forbidden = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  /// Remplace les réglages affichés. Un champ de plafond NON modifié suit la
  /// nouvelle valeur ; une liste d'empreintes NON modifiée aussi (sinon la
  /// référence de comparaison S-07 est gardée).
  void _apply(
    ModerationSettings s, {
    required bool resetCeilings,
    required bool resetRules,
  }) {
    final ModerationSettings? old = _s;
    _s = s;
    if (resetCeilings ||
        old == null ||
        _hour.text.trim() == '${old.maxPerHour}') {
      _hour.text = '${s.maxPerHour}';
      _hourError = null;
    }
    if (resetCeilings ||
        old == null ||
        _day.text.trim() == '${old.maxPerDay}') {
      _day.text = '${s.maxPerDay}';
      _dayError = null;
    }
    if (resetRules || sameRulesList(_draftRules, _baselineRules)) {
      _baselineRules = List<String>.unmodifiable(s.allowedRulesSha256);
      _draftRules = <String>[
        for (final String x in s.allowedRulesSha256) x.trim().toLowerCase(),
      ]..sort();
      _rulesChangedOnServer = false;
    }
  }

  /// Relecture des réglages JUSTE AVANT une action sensible (revue P4b-3,
  /// SEC-P4b3-04) : ouverture d'un dialogue fort (compteurs et état à jour)
  /// et envoi d'une liste d'empreintes (avant le dialogue des différences
  /// ET après sa confirmation). L'affichage suit le serveur sans écraser les
  /// saisies en cours ; null = échec (401 → déconnexion, 403 → état
  /// réservé, autre → SnackBar rouge).
  Future<ModerationSettings?> _reread() async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final ModerationSettings s = await widget.sync.fetchModerationSettings();
      if (!mounted) return null;
      // Plus récente que toute lecture en cours : celle-ci est ignorée.
      _loadSeq++;
      setState(() {
        _apply(s, resetCeilings: false, resetRules: false);
        _loading = false;
        _error = null;
      });
      widget.onSettings?.call(s);
      return s;
    } on AdminAuthException {
      widget.onAuthError();
      return null;
    } on AdminForbiddenException {
      if (mounted) setState(() => _forbidden = true);
      return null;
    } catch (e) {
      if (mounted) {
        showModerationSnack(context, errorText(e), tone: OutcomeTone.error);
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Écriture des SEULES clés non nulles ; rend les réglages relus (null :
  /// échec, déjà signalé).
  Future<ModerationSettings?> _write({
    bool? enabled,
    int? perHour,
    int? perDay,
    List<String>? rules,
  }) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final ModerationSettings s = await widget.sync.updateModerationSettings(
        autoBanEnabled: enabled,
        maxPerHour: perHour,
        maxPerDay: perDay,
        allowedRulesSha256: rules,
      );
      if (!mounted) return s;
      // Réponse plus récente que toute lecture en cours : celle-ci est ignorée.
      _loadSeq++;
      setState(() {
        _apply(
          s,
          resetCeilings: perHour != null || perDay != null,
          resetRules: rules != null,
        );
        _loading = false;
        _error = null;
      });
      widget.onSettings?.call(s);
      return s;
    } on AdminAuthException {
      widget.onAuthError();
      return null;
    } on AdminForbiddenException {
      if (mounted) setState(() => _forbidden = true);
      return null;
    } catch (e) {
      if (!mounted) return null;
      final String msg = e is AdminApiException && e.statusCode == 400
          ? settingsErrorText(e.message, e.reasons)
          : errorText(e);
      showModerationSnack(context, msg, tone: OutcomeTone.error);
      if (isUncertainFailure(e)) unawaited(_load());
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 1. Interrupteur ────────────────────────────────────────────────────────

  Future<void> _toggle(bool on) async {
    if (_s == null || _busy) return;
    if (on) {
      // SEC-P4b3-04 : état et compteurs relus à l'ouverture du dialogue fort.
      final ModerationSettings? s = await _reread();
      if (s == null || !mounted) return;
      if (s.autoBanEnabled) return; // déjà allumé : l'affichage suit
      final bool ok = await StrongConfirmDialog.show(
        context,
        title: kTurnOnTitle,
        text: turnOnText(maxPerHour: s.maxPerHour, maxPerDay: s.maxPerDay),
        extra: <Widget>[_counters(s)],
        checkboxLabel: kTurnOnCheckbox,
        confirmLabel: kTurnOnButton,
      );
      if (!ok || !mounted) return;
      final ModerationSettings? r = await _write(enabled: true);
      if (r != null && mounted) showModerationSnack(context, kTurnedOnMessage);
    } else {
      final bool ok = await confirmModerationAction(
        context,
        title: kTurnOffTitle,
        message: kTurnOffMessage,
        confirmLabel: kTurnOffButton,
      );
      if (!ok || !mounted) return;
      final ModerationSettings? r = await _write(enabled: false);
      if (r != null && mounted) showModerationSnack(context, kTurnedOffMessage);
    }
  }

  Widget _counters(ModerationSettings s) => AutoBanCountersNotice(
    hour: s.autoBansLastHour,
    maxHour: s.maxPerHour,
    day: s.autoBansLastDay,
    maxDay: s.maxPerDay,
  );

  // ── 2. Disjoncteur ─────────────────────────────────────────────────────────

  void _viewEvent(int eventId) {
    unawaited(
      openEventDetail(
        context,
        sync: widget.sync,
        eventId: eventId,
        onAuthError: widget.onAuthError,
      ),
    );
  }

  Future<void> _rearm() async {
    final ModerationSettings? shown = _s;
    if (shown == null || !shown.breakerOpen || _busy) return;
    // SEC-P4b3-04 : disjoncteur et compteurs relus à l'ouverture du
    // dialogue fort (déjà réarmé ailleurs : l'affichage suit, rien ouvert).
    final ModerationSettings? s = await _reread();
    if (s == null || !mounted || !s.breakerOpen) return;
    final int? eventId = s.breakerEventId;
    final bool ok = await StrongConfirmDialog.show(
      context,
      title: kRearmTitle,
      text: rearmText(
        date: formatModerationDate(s.breakerTrippedAt),
        reason: s.breakerReason,
      ),
      extra: <Widget>[
        if (eventId != null)
          Builder(
            builder: (BuildContext dialogContext) => Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('moderation-rearm-view-event'),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: Text(viewEventLabel(eventId)),
                // Ouvre le détail PAR-DESSUS le dialogue (sans le fermer) ;
                // 401 : le dialogue fort se ferme aussi avant la déconnexion.
                onPressed: () => unawaited(
                  ReviewDetailDialog.show(
                    dialogContext,
                    load: () => widget.sync.fetchReviewDetail(eventId),
                    onAuthError: () {
                      Navigator.of(dialogContext).pop(false);
                      widget.onAuthError();
                    },
                  ),
                ),
              ),
            ),
          ),
        _counters(s),
      ],
      checkboxLabel: kRearmCheckbox,
      confirmLabel: kRearmButton,
      confirmColor: ModerationColors.warning,
    );
    if (!ok || !mounted) return;
    final ModerationSettings? r = await _write(enabled: true);
    if (r != null && mounted) showModerationSnack(context, kRearmedMessage);
  }

  // ── 3. Plafonds ────────────────────────────────────────────────────────────

  Future<void> _saveCeilings() async {
    final ModerationSettings? s = _s;
    if (s == null || _busy) return;
    final ({int? value, String? error}) h = parseCeiling(
      _hour.text,
      max: kMaxPerHourLimit,
    );
    final ({int? value, String? error}) d = parseCeiling(
      _day.text,
      max: kMaxPerDayLimit,
    );
    setState(() {
      _hourError = h.error;
      _dayError = d.error;
    });
    final int? newHour = h.value;
    final int? newDay = d.value;
    if (newHour == null || newDay == null) return;
    final Map<String, int> patch = ceilingsPatch(
      oldHour: s.maxPerHour,
      oldDay: s.maxPerDay,
      newHour: newHour,
      newDay: newDay,
    );
    if (patch.isEmpty) {
      showModerationSnack(
        context,
        kNothingChangedMessage,
        tone: OutcomeTone.info,
      );
      return;
    }
    final List<String> increases = ceilingIncreases(
      oldHour: s.maxPerHour,
      oldDay: s.maxPerDay,
      newHour: newHour,
      newDay: newDay,
    );
    if (increases.isNotEmpty) {
      final bool ok = await confirmModerationAction(
        context,
        title: kCeilingIncreaseTitle,
        message: ceilingIncreaseText(increases),
        confirmLabel: kCeilingIncreaseButton,
      );
      if (!ok || !mounted) return;
    }
    final ModerationSettings? r = await _write(
      perHour: patch['max_auto_bans_per_hour'],
      perDay: patch['max_auto_bans_per_day'],
    );
    if (r != null && mounted) {
      showModerationSnack(context, kCeilingsSavedMessage);
    }
  }

  // ── 4. Empreintes autorisées ───────────────────────────────────────────────

  void _addSha() {
    final ({List<String>? list, String? error}) r = addRulesSha(
      _draftRules,
      _sha.text,
    );
    setState(() {
      final List<String>? list = r.list;
      if (list == null) {
        _shaError = r.error;
      } else {
        _draftRules = list;
        _sha.clear();
        _shaError = null;
      }
    });
  }

  void _removeSha(String sha) {
    setState(() {
      _draftRules = <String>[
        for (final String x in _draftRules)
          if (x != sha) x,
      ];
    });
  }

  Future<void> _copySha(String sha) async {
    await Clipboard.setData(ClipboardData(text: sha));
    if (!mounted) return;
    showModerationSnack(context, 'Empreinte copiée.');
  }

  Future<void> _saveRules() async {
    if (_busy) return;
    if (sameRulesList(_draftRules, _baselineRules)) {
      showModerationSnack(
        context,
        kNothingChangedMessage,
        tone: OutcomeTone.info,
      );
      return;
    }
    // S-07 : relecture AVANT l'envoi (la liste ENTIÈRE remplace l'actuelle).
    if (!await _rulesStillCurrent() || !mounted) return;
    final List<String> draft = List<String>.of(_draftRules);
    final bool ok = await confirmModerationAction(
      context,
      title: kRulesSaveTitle,
      message: rulesDiffLines(_baselineRules, draft).join('\n'),
      confirmLabel: kRulesSaveConfirmButton,
      destructive: draft.isEmpty,
    );
    if (!ok || !mounted) return;
    // SEC-P4b3-04 : nouvelle relecture APRÈS la confirmation (la liste a pu
    // changer pendant que le dialogue était ouvert) ; changée → rien envoyé.
    if (!await _rulesStillCurrent() || !mounted) return;
    final ModerationSettings? r = await _write(rules: draft);
    if (r != null && mounted) showModerationSnack(context, kRulesSavedMessage);
  }

  /// Relit la liste d'empreintes du serveur et la compare à la référence
  /// chargée : identique → vrai ; changée → avertissement « liste modifiée »
  /// et faux ; lecture impossible → faux (déjà signalé).
  Future<bool> _rulesStillCurrent() async {
    final ModerationSettings? fresh = await _reread();
    if (fresh == null || !mounted) return false;
    if (sameRulesList(fresh.allowedRulesSha256, _baselineRules)) return true;
    setState(() => _rulesChangedOnServer = true);
    return false;
  }

  // ── 6. Preuves anciennes ───────────────────────────────────────────────────

  Future<void> _previewEvidence() async {
    if (_busy) return;
    final String? err = validatePurgeDays(_days.text);
    if (err != null) {
      setState(() => _daysError = err);
      return;
    }
    final int days = int.parse(_days.text.trim());
    setState(() {
      _busy = true;
      _daysError = null;
      _evidenceResult = null;
      _evidencePreview = null;
    });
    try {
      final EvidencePurgeResult r = await widget.sync.purgeEvidence(
        olderThanDays: days,
        apply: false,
      );
      if (!mounted) return;
      setState(() {
        _evidencePreview = r;
        _previewDays = days;
      });
    } on AdminAuthException {
      widget.onAuthError();
    } on AdminForbiddenException {
      if (mounted) setState(() => _forbidden = true);
    } catch (e) {
      if (mounted) {
        showModerationSnack(context, errorText(e), tone: OutcomeTone.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeEvidence() async {
    final EvidencePurgeResult? p = _evidencePreview;
    final int? days = _previewDays;
    if (_busy || p == null || days == null || p.count <= 0) return;
    final bool ok = await confirmModerationAction(
      context,
      title: evidencePurgeConfirmTitle(p.count),
      message: kEvidencePurgeKeepsJournal,
      confirmLabel: 'Supprimer',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final EvidencePurgeResult r = await widget.sync.purgeEvidence(
        olderThanDays: days,
        apply: true,
      );
      if (!mounted) return;
      setState(() {
        _evidenceResult = evidencePurgedText(r);
        _evidencePreview = null;
      });
      unawaited(_load(full: false));
    } on AdminAuthException {
      widget.onAuthError();
    } on AdminForbiddenException {
      if (mounted) setState(() => _forbidden = true);
    } catch (e) {
      if (!mounted) return;
      showModerationSnack(context, errorText(e), tone: OutcomeTone.error);
      if (isUncertainFailure(e)) unawaited(_load(full: false));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Affichage ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_forbidden) return const ModerationForbiddenView();
    final ModerationSettings? s = _s;
    final String? error = _error;
    if (s == null) {
      if (error != null) {
        return ListView(
          padding: const EdgeInsets.only(top: 16),
          children: <Widget>[
            ModerationErrorBanner(message: error, onRetry: _load),
          ],
        );
      }
      return const ModerationLoadingView();
    }
    final ThemeData theme = Theme.of(context);
    final TextStyle small = theme.textTheme.bodySmall ?? const TextStyle();
    return ListView(
      key: const Key('moderation-settings'),
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      children: <Widget>[
        if (error != null) ...<Widget>[
          ModerationErrorBanner(message: error, onRetry: _load),
          const SizedBox(height: 12),
        ],
        if (_loading || _busy)
          const Align(alignment: Alignment.centerRight, child: kButtonSpinner),
        _section(theme, 'Interrupteur'),
        SwitchListTile(
          key: const Key('moderation-settings-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text(kAutoBanSwitchTitle),
          subtitle: Text(autoBanSubtitle(s.autoBanEnabled)),
          value: s.autoBanEnabled,
          onChanged: _busy ? null : (bool v) => unawaited(_toggle(v)),
        ),
        _section(theme, 'Disjoncteur'),
        _breaker(s, small),
        _section(theme, 'Plafonds'),
        _ceilings(),
        _section(theme, 'Empreintes de règles autorisées'),
        _rules(small),
        _section(theme, 'Compteurs'),
        _countersSection(s, small),
        _section(theme, 'Preuves anciennes'),
        _evidence(small),
      ],
    );
  }

  static Widget _section(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    ),
  );

  Widget _breaker(ModerationSettings s, TextStyle small) {
    if (!s.breakerOpen) {
      return Text(
        kBreakerNormalText,
        key: const Key('moderation-settings-breaker-normal'),
        style: small,
      );
    }
    final int? eventId = s.breakerEventId;
    return Container(
      key: const Key('moderation-settings-breaker'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ModerationColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ModerationColors.danger, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            breakerBoxText(
              date: formatModerationDate(s.breakerTrippedAt),
              reason: s.breakerReason,
              eventId: eventId,
            ),
            key: const Key('moderation-settings-breaker-text'),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: ModerationColors.danger,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              if (eventId != null)
                OutlinedButton(
                  key: const Key('moderation-settings-view-event'),
                  onPressed: () => _viewEvent(eventId),
                  child: const Text("Voir l'événement"),
                ),
              FilledButton(
                key: const Key('moderation-settings-rearm'),
                style: FilledButton.styleFrom(
                  backgroundColor: ModerationColors.warning,
                ),
                onPressed: _busy ? null : () => unawaited(_rearm()),
                child: const Text(kRearmButton),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ceilingField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String? error,
  }) {
    final String? warning = ceilingWarning(controller.text);
    return SizedBox(
      width: 300,
      child: TextField(
        key: key,
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          errorText: error,
          helperText: error == null ? warning : null,
          helperMaxLines: 2,
          helperStyle: TextStyle(color: Colors.orange.shade700),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _ceilings() => Wrap(
    spacing: 16,
    runSpacing: 12,
    crossAxisAlignment: WrapCrossAlignment.start,
    children: <Widget>[
      _ceilingField(
        key: const Key('moderation-settings-hour'),
        controller: _hour,
        label: kCeilingHourLabel,
        error: _hourError,
      ),
      _ceilingField(
        key: const Key('moderation-settings-day'),
        controller: _day,
        label: kCeilingDayLabel,
        error: _dayError,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: FilledButton(
          key: const Key('moderation-settings-save-ceilings'),
          onPressed: _busy ? null : () => unawaited(_saveCeilings()),
          child: const Text(kSaveCeilingsButton),
        ),
      ),
    ],
  );

  Widget _rules(TextStyle small) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(kRulesNote, style: small),
        const SizedBox(height: 8),
        if (_rulesChangedOnServer) ...<Widget>[
          Container(
            key: const Key('moderation-settings-rules-changed'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 8),
                const Expanded(child: Text(kRulesChangedOnServerMessage)),
                OutlinedButton(
                  key: const Key('moderation-settings-rules-reload'),
                  onPressed: _busy ? null : () => unawaited(_load()),
                  child: const Text(kRulesReloadButton),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          rulesCounterText(_draftRules.length),
          key: const Key('moderation-settings-rules-count'),
          style: small.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        if (_draftRules.isEmpty)
          Text(kRulesEmptyListWarning, style: small)
        else
          for (final String sha in _draftRules)
            Row(
              key: ValueKey<String>('moderation-settings-rule-$sha'),
              children: <Widget>[
                Expanded(
                  child: UntrustedLine(
                    sha,
                    max: 64,
                    monospace: true,
                    style: small,
                  ),
                ),
                if (kSha256Re.hasMatch(sha))
                  TextButton(
                    onPressed: () => unawaited(_copySha(sha)),
                    child: const Text('Copier'),
                  ),
                TextButton(
                  key: ValueKey<String>('moderation-settings-rule-remove-$sha'),
                  onPressed: _busy ? null : () => _removeSha(sha),
                  child: const Text('Retirer'),
                ),
              ],
            ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 560,
              child: TextField(
                key: const Key('moderation-settings-rule-field'),
                controller: _sha,
                enabled: !_busy,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  labelText: kRulesFieldLabel,
                  isDense: true,
                  errorText: _shaError,
                ),
                onSubmitted: (_) => _addSha(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                key: const Key('moderation-settings-rule-add'),
                onPressed: _busy ? null : _addSha,
                child: const Text(kRulesAddButton),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FilledButton(
                key: const Key('moderation-settings-rules-save'),
                onPressed: _busy ? null : () => unawaited(_saveRules()),
                child: const Text(kRulesSaveButton),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _countersSection(ModerationSettings s, TextStyle small) => Column(
    key: const Key('moderation-settings-counters'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(settingsCountersText(s)),
      const SizedBox(height: 4),
      Text('File de revue : ${s.reviewQueueSize}'),
      const SizedBox(height: 4),
      Text('Preuves conservées : ${s.evidenceRows}'),
      const SizedBox(height: 4),
      Text(chainThresholdText(s)),
      const SizedBox(height: 4),
      Directionality(
        textDirection: TextDirection.ltr,
        child: ClipRect(
          child: Text(
            lastModifiedText(
              date: formatModerationDate(s.updatedAt),
              by: s.updatedBy,
            ),
            key: const Key('moderation-settings-updated'),
            style: small,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ],
  );

  Widget _evidence(TextStyle small) {
    final EvidencePurgeResult? p = _evidencePreview;
    final String? result = _evidenceResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            const Text(kPurgeDaysPrefix),
            SizedBox(
              width: 90,
              child: TextField(
                key: const Key('moderation-settings-purge-days'),
                controller: _days,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(isDense: true),
                onChanged: (_) => setState(() {
                  _evidencePreview = null;
                  _evidenceResult = null;
                  _daysError = null;
                }),
              ),
            ),
            const Text(kPurgeDaysSuffix),
            OutlinedButton(
              key: const Key('moderation-settings-purge-preview'),
              onPressed: _busy ? null : () => unawaited(_previewEvidence()),
              child: const Text(kEvidencePreviewButton),
            ),
          ],
        ),
        if (_daysError != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            _daysError!,
            key: const Key('moderation-settings-purge-days-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (p != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            evidencePreviewText(p.count),
            key: const Key('moderation-settings-purge-preview-text'),
          ),
          if (p.count > 0) ...<Widget>[
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('moderation-settings-purge-apply'),
              style: FilledButton.styleFrom(
                backgroundColor: ModerationColors.danger,
              ),
              onPressed: _busy ? null : () => unawaited(_purgeEvidence()),
              child: Text(evidencePurgeButtonLabel(p.count)),
            ),
          ],
        ],
        if (result != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            result,
            key: const Key('moderation-settings-purge-result'),
            style: small.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ],
    );
  }
}
