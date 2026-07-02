import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'ui/screens/admin_shell.dart';

/// Racine [MaterialApp] du panneau admin (thème sombre néon par défaut).
class MgtAdminApp extends StatelessWidget {
  const MgtAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyGamingTips — Admin',
      debugShowCheckedModeBanner: false,
      theme: AdminTheme.dark,
      darkTheme: AdminTheme.dark,
      themeMode: ThemeMode.dark,
      home: const AdminShell(),
    );
  }
}
