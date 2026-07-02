import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';

/// Écran de connexion sécurisé du panneau admin.
///
/// **Conçu volontairement sobre et neutre** : fond blanc uni, champs
/// identifiant/mot de passe, bouton blanc. Aucun logo, aucun nom, aucune
/// couleur distinctive — la page ne révèle pas la nature de l'interface
/// (sécurité par obscurité). L'apparence propre du panneau admin (thème néon)
/// n'apparaît qu'après authentification réussie.
///
/// ⚠️ Aucun identifiant n'est affiché ni stocké côté client. Les credentials
/// sont vérifiés côté serveur (cf. AuthService + GUIDE_DEPLOIEMENT.md).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSuccess});

  final VoidCallback onSuccess;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final AuthController auth = context.read<AuthController>();
    final bool ok = await auth.login(
        username: _user.text, password: _pass.text);
    if (ok) {
      widget.onSuccess();
    }
    // Le message d'erreur est exposé via auth.error (géré par le contrôleur).
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = context.watch<AuthController>();
    final String? error = auth.error;

    // Thème blanc neutre forcé (sobre, quelle que soit la config).
    const Color bg = Color(0xFFFFFFFF);
    const Color surface = Color(0xFFFFFFFF);
    const Color inputFill = Color(0xFFF5F6F8);
    const Color border = Color(0xFFE0E3E8);
    const Color textPrimary = Color(0xFF1A1C20);
    const Color textMuted = Color(0xFF8A909C);

    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Verrou neutre (sans texte, sans logo, sans couleur d'app).
                const Icon(Icons.lock_outline_rounded,
                    size: 30, color: textMuted),
                const SizedBox(height: 24),

                // Champ identifiant.
                TextField(
                  controller: _user,
                  enabled: !auth.isLoading,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(
                      color: textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Identifiant',
                    hintStyle: const TextStyle(color: textMuted),
                    filled: true,
                    fillColor: inputFill,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                          color: Color(0xFFC4C9D2), width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Champ mot de passe.
                TextField(
                  controller: _pass,
                  enabled: !auth.isLoading,
                  obscureText: _obscure,
                  style: const TextStyle(
                      color: textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Mot de passe',
                    hintStyle: const TextStyle(color: textMuted),
                    filled: true,
                    fillColor: inputFill,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                          color: Color(0xFFC4C9D2), width: 1.5),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: textMuted,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),

                // Message d'erreur éventuel.
                if (error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    error,
                    style: const TextStyle(
                      color: Color(0xFFD14343),
                      fontSize: 12.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),

                // Bouton de connexion (blanc, sobre).
                SizedBox(
                  height: 46,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: surface,
                      foregroundColor: textPrimary,
                      side: const BorderSide(color: border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: auth.isLoading ? null : _submit,
                    child: auth.isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: textMuted),
                          )
                        : const Text(
                            'Connexion',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
                const SizedBox(height: 32),
                // Mention discrète, sans identité.
                const Text(
                  'Accès réservé • Espace sécurisé',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
