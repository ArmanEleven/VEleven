import 'dart:ui';

import 'package:defyx_vpn/app/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppModeSwitcher extends StatelessWidget {
  const AppModeSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    final isV11 = GoRouterState.of(context).uri.path.startsWith('/v2ray');
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? Colors.white : const Color(0xFF10233F);
    final muted = dark ? Colors.white60 : const Color(0xFF718096);
    const accent = Color(0xFF2878F0);

    Widget option(String label, bool selected, VoidCallback onTap) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: selected ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              boxShadow: selected
                  ? [BoxShadow(color: accent.withValues(alpha: .28), blurRadius: 16, offset: const Offset(0, 5))]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : muted,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: .2,
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: (dark ? const Color(0xFF111B2A) : Colors.white).withValues(alpha: .78),
                borderRadius: BorderRadius.circular(19),
                border: Border.all(color: accent.withValues(alpha: dark ? .30 : .18)),
              ),
              child: Row(
                children: [
                  option('Automatic', !isV11, () {
                    if (isV11) context.go(DefyxVPNRoutes.main.route);
                  }),
                  const SizedBox(width: 4),
                  option('V11', isV11, () {
                    if (!isV11) context.go(DefyxVPNRoutes.v2ray.route);
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
