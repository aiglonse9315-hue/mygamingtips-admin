import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

/// Élément de la barre latérale de navigation admin.
class NavItem {
  final String label;
  final IconData icon;
  final String route;
  const NavItem(this.label, this.icon, this.route);
}

/// Barre latérale fixe du panneau admin.
class AdminSidebar extends StatelessWidget {
  const AdminSidebar({
    super.key,
    required this.items,
    required this.current,
    required this.onSelected,
  });

  final List<NavItem> items;
  final String current;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 230,
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        border: Border(
          right: BorderSide(
            color: dark
                ? AppColors.neonViolet.withValues(alpha: 0.4)
                : Theme.of(context).dividerColor,
            width: dark ? 1.5 : 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Logo
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [AppColors.neonViolet, AppColors.neonCyan],
              ).createShader(b),
              child: const Text(
                'MyGamingTips',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              'Administration',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
                color: AppColors.neonCyan,
              ),
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          // Items
          ...items.map((item) => _SidebarTile(
                item: item,
                selected: item.route == current,
                onTap: () => onSelected(item.route),
              )),
          const Spacer(),
        ],
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: dark ? 0.18 : 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: selected && dark
                ? Border.all(color: accent.withValues(alpha: 0.5), width: 1)
                : null,
          ),
          child: Row(
            children: [
              Icon(item.icon,
                  size: 20,
                  color: selected
                      ? accent
                      : (dark ? Colors.white60 : Colors.black54)),
              const SizedBox(width: 12),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected
                      ? accent
                      : (dark ? Colors.white : Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
