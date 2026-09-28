// Preuve d'un événement de modération et relecture serveur (P4b-3, lot L5,
// conception §6.4 a sections 4-5, §4.3, §6.9).
//
// La preuve (lien et texte partagés, demande du bot) est un texte CHOISI PAR
// UN TIERS : texte brut seulement (`SelectableText`, jamais de lien ni de
// rendu), caractères invisibles / bidi / de contrôle rendus visibles
// (`revealInvisibles`, condensés, affichage borné), gauche-à-droite, dans
// des cadres de hauteur FIXE rognés (`ClipRect`) : un texte de 20 000
// caractères, 60 diacritiques empilés ou une demande de 256 Kio ne peuvent
// ni déborder sur les boutons voisins ni figer l'affichage (la demande est
// rendue ligne par ligne par un `ListView.builder`, 64 Kio au plus). Aucun
// bouton « Copier » ici (seules les empreintes en ont, dans le détail).
//
// Widgets « de présentation » (aucun Provider) → testables en VM.
import 'package:flutter/material.dart';

import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_text.dart';
import 'moderation_ui.dart';

/// Avertissement affiché en tête de toute preuve.
const String kEvidenceWarning =
    'Texte choisi par un tiers : affiché en texte brut, caractères invisibles '
    "rendus visibles (⟦…⟧). Ne le copiez dans aucun outil d'IA.";

/// Messages des états sans preuve (§6.4 a, section 5).
const String kEvidenceNotKeptMessage =
    'Preuve non conservée (plafond de 20 par origine ou 200 par 24 h atteint, '
    'membre de groupe ou cible déjà bannie).';
const String kEvidencePurgedMessage = 'Preuve purgée (durée de conservation).';
const String kEvidenceNoneMessage =
    'Aucune preuve pour cet événement (décision de revue ou ban manuel).';

/// Préfixe de la ligne ajoutée par `revealedJsonLines` quand la demande est
/// coupée (une ligne de JSON indenté ne commence jamais par une lettre).
const String _kDemandeTruncatedPrefix = "Demande tronquée à l'affichage";

/// Cadre de hauteur FIXE, défilant, qui affiche un texte DÉJÀ révélé en
/// police à chasse fixe 12, retour à la ligne automatique (un « mot » plus
/// long que la ligne est coupé), gauche-à-droite, rogné.
class RevealedTextBox extends StatelessWidget {
  const RevealedTextBox({
    super.key,
    required this.revealed,
    this.height = 240,
    this.textKey,
  });

  /// Révèle [raw] (`revealInvisibles`, borné à `kRevealDisplayMax`).
  factory RevealedTextBox.fromRaw(
    String raw, {
    Key? key,
    double height = 240,
    Key? textKey,
  }) => RevealedTextBox(
    key: key,
    revealed: revealInvisibles(raw),
    height: height,
    textKey: textKey,
  );

  final RevealedText revealed;
  final double height;

  /// Clé posée sur le `SelectableText` (tests).
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: ClipRect(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              child: SelectableText(
                revealed.text,
                key: textKey,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Section « Preuve (texte brut) » du détail d'un événement.
class EvidenceView extends StatefulWidget {
  const EvidenceView({
    super.key,
    required this.detail,
    this.textHeight = 240,
    this.demandeHeight = 300,
  });

  final ReviewDetail detail;

  /// Hauteur du cadre « Texte partagé ».
  final double textHeight;

  /// Hauteur de la liste « Demande du bot ».
  final double demandeHeight;

  @override
  State<EvidenceView> createState() => _EvidenceViewState();
}

class _EvidenceViewState extends State<EvidenceView> {
  RevealedText? _url;
  RevealedText? _text;

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(covariant EvidenceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.detail, widget.detail)) _reveal();
  }

  void _reveal() {
    final Evidence? ev = widget.detail.evidence;
    _url = ev?.suggestionUrl == null
        ? null
        : revealInvisibles(ev!.suggestionUrl!, maxUnits: 8192);
    _text = ev?.sharedText == null ? null : revealInvisibles(ev!.sharedText!);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ReviewDetail d = widget.detail;
    final EvidenceState state = d.evidenceState;
    final List<Widget> children = <Widget>[
      ModerationNotice(
        text: kEvidenceWarning,
        color: ModerationColors.warning,
        icon: Icons.warning_amber_rounded,
      ),
      const SizedBox(height: 10),
    ];

    switch (state) {
      case EvidenceState.notKept:
      case EvidenceState.purged:
      case EvidenceState.none:
        children.add(
          Text(
            switch (state) {
              EvidenceState.notKept => kEvidenceNotKeptMessage,
              EvidenceState.purged => kEvidencePurgedMessage,
              _ => kEvidenceNoneMessage,
            },
            key: const Key('moderation-evidence-state'),
            style: theme.textTheme.bodyMedium,
          ),
        );
      case EvidenceState.present:
      case EvidenceState.headEvidence:
        final Evidence ev = d.evidence!;
        final int hidden = (_url?.hiddenCount ?? 0) + (_text?.hiddenCount ?? 0);
        if (state == EvidenceState.headEvidence) {
          children.add(
            Text(
              "Preuve de l'événement #${d.evidenceEventId ?? ev.eventId} "
              '(tête du groupe ou événement revu)',
              key: const Key('moderation-evidence-head'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          );
          children.add(const SizedBox(height: 6));
        }
        children.addAll(<Widget>[
          _label(theme, 'Lien partagé'),
          Directionality(
            textDirection: TextDirection.ltr,
            child: ClipRect(
              child: SelectableText(
                _url?.text ?? '—',
                key: const Key('moderation-evidence-url'),
                minLines: 1,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _label(theme, 'Texte partagé'),
          RevealedTextBox(
            key: const Key('moderation-evidence-text-box'),
            textKey: const Key('moderation-evidence-text'),
            revealed:
                _text ??
                const RevealedText(
                  text: '—',
                  hiddenCount: 0,
                  codePoints: <int>{},
                  truncated: false,
                ),
            height: widget.textHeight,
          ),
          if (hidden > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '$hidden caractère(s) invisible(s) ou de contrôle rendus visibles',
              key: const Key('moderation-evidence-hidden-count'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: ModerationColors.warning,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (ev.demande != null) ...<Widget>[
            const SizedBox(height: 6),
            ExpansionTile(
              key: const Key('moderation-evidence-demande'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text(
                'Demande du bot',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              children: <Widget>[
                _DemandeLines(
                  demande: ev.demande,
                  height: widget.demandeHeight,
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (ev.originKey != null)
            Row(
              children: <Widget>[
                Text('Origine : ', style: theme.textTheme.bodySmall),
                Expanded(
                  child: UntrustedLine(
                    ev.originKey!,
                    max: 120,
                    monospace: true,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          Text(
            'Preuve enregistrée le ${formatModerationDate(ev.createdAt)}',
            style: theme.textTheme.bodySmall,
          ),
        ]);
    }

    return Column(
      key: const Key('moderation-evidence'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  static Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// Demande du bot : JSON indenté révélé, ligne par ligne (chargement
/// paresseux), 64 Kio révélés au plus ; mention de troncature AU-DESSUS de
/// la liste (toujours visible).
class _DemandeLines extends StatefulWidget {
  const _DemandeLines({required this.demande, required this.height});

  final Object? demande;
  final double height;

  @override
  State<_DemandeLines> createState() => _DemandeLinesState();
}

class _DemandeLinesState extends State<_DemandeLines> {
  late List<String> _lines;
  String? _truncatedNote;

  @override
  void initState() {
    super.initState();
    final List<String> all = revealedJsonLines(widget.demande);
    if (all.isNotEmpty && all.last.startsWith(_kDemandeTruncatedPrefix)) {
      _truncatedNote = all.last;
      _lines = all.sublist(0, all.length - 1);
    } else {
      _lines = all;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_truncatedNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _truncatedNote!,
              key: const Key('moderation-evidence-demande-truncated'),
              style: TextStyle(
                fontSize: 12,
                color: ModerationColors.warning,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: ClipRect(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _lines.length,
                itemBuilder: (BuildContext context, int i) => Text(
                  _lines[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Section « Relecture serveur » (`snapshot` de l'événement, sans texte
/// d'utilisateur) : longueurs, empreintes, hôtes (RÉVÉLÉS : un hôte peut
/// venir d'une URL choisie par un tiers), motifs de refus / d'examen.
class ServerReadbackView extends StatelessWidget {
  const ServerReadbackView({super.key, required this.snapshot});

  final Map<String, dynamic>? snapshot;

  static Map<String, dynamic>? _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static List<String> _strings(Object? v) =>
      v is List ? v.whereType<String>().toList() : const <String>[];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, dynamic>? sugg = _map(snapshot?['suggestion']);
    final Map<String, dynamic>? srv = _map(snapshot?['serveur']);
    if (sugg == null && srv == null) return const SizedBox.shrink();
    final int? urlChars = _int(sugg?['url_chars']);
    final int? textChars = _int(sugg?['texte_chars']);
    final String? shaText = _str(srv?['sha256_texte']);
    final String? shaUrl = _str(srv?['sha256_url']);
    final String? hostPage = _str(srv?['hote_page']);
    final String? hostSugg = _str(srv?['hote_suggestion']);
    final List<String> refused = _strings(srv?['motifs_refus']);
    final List<String> review = _strings(srv?['motifs_examen']);
    final TextStyle? small = theme.textTheme.bodySmall;

    Widget line(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 170, child: Text(label, style: small)),
          Expanded(child: value),
        ],
      ),
    );

    return Column(
      key: const Key('moderation-readback'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (urlChars != null || textChars != null)
          line(
            'Longueurs',
            Text(
              'lien ${urlChars ?? '—'} · texte ${textChars ?? '—'} caractère(s)',
              style: small,
            ),
          ),
        if (shaText != null)
          line(
            'Empreinte du texte',
            UntrustedLine(shaText, max: 64, monospace: true, style: small),
          ),
        if (shaUrl != null)
          line(
            'Empreinte du lien',
            UntrustedLine(shaUrl, max: 64, monospace: true, style: small),
          ),
        if (hostPage != null)
          line(
            'Hôte de la page',
            UntrustedLine(
              hostPage,
              key: const Key('moderation-readback-host-page'),
              max: 120,
              monospace: true,
              style: small,
            ),
          ),
        if (hostSugg != null)
          line(
            'Hôte du lien partagé',
            UntrustedLine(
              hostSugg,
              key: const Key('moderation-readback-host-suggestion'),
              max: 120,
              monospace: true,
              style: small,
            ),
          ),
        if (refused.isNotEmpty)
          line(
            'Motifs de refus',
            Text(reasonLabels(refused).join(' · '), style: small),
          ),
        if (review.isNotEmpty)
          line(
            "Motifs d'examen",
            Text(reasonLabels(review).join(' · '), style: small),
          ),
      ],
    );
  }
}
