import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart' hide Block;
import 'package:distr_bis/auth/auth_provider.dart';
import 'package:distr_bis/auth/forgot_password_screen.dart';
import 'package:distr_bis/auth/login_screen.dart';
import 'package:distr_bis/auth/reset_password_screen.dart';
import 'package:distr_bis/models/block.dart';
import 'package:distr_bis/chain/block_detail_screen.dart';
import 'package:distr_bis/chain/chain_log_screen.dart';
import 'package:distr_bis/inventory/inventory_screen.dart';
import 'package:distr_bis/notifications/notification_provider.dart';
import 'package:distr_bis/notifications/notifications_screen.dart';
import 'package:distr_bis/profile/profile_screen.dart';
import 'package:distr_bis/profile/users_management_screen.dart';
import 'package:provider/provider.dart';

class AppRouter {
  final AuthProvider authProvider;

  AppRouter({required this.authProvider});

  GoRouter get router => _router;

  late final GoRouter _router = GoRouter(
    refreshListenable: authProvider,
    routes: <RouteBase>[
      // Main application shell with bottom navigation
      ShellRoute(
        builder: (context, state, child) {
          return MainScaffold(state: state, child: child);
        },
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const InventoryScreen(),
          ),
          GoRoute(
            path: '/chain-log',
            builder: (context, state) => const ChainLogScreen(),
            routes: [
              GoRoute(
                path: ':blockId',
                builder: (context, state) {
                  final blockId = state.pathParameters['blockId']!;
                  return BlockDetailScreen(
                    blockId: blockId,
                    block: state.extra is Block ? state.extra as Block : null,
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
            routes: [
              GoRoute(
                path: 'users-management',
                builder: (context, state) => const UsersManagementScreen(),
              ),
            ],
          ),
        ],
      ),
      // Standalone routes
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
        routes: [
          GoRoute(
            path: 'forgot-password',
            builder: (context, state) => const ForgotPasswordScreen(),
            routes: [
              GoRoute(
                path: 'reset-password',
                builder: (context, state) {
                  final email = state.uri.queryParameters['email']!;
                  return ResetPasswordScreen(email: email);
                },
              ),
            ],
          ),
        ],
      ),
    ],
    redirect: (context, state) {
      final isAuthenticated = authProvider.isAuthenticated;
      final isAuthRoute = state.uri.toString().startsWith('/login');

      if (!isAuthenticated && !isAuthRoute) return '/login';
      if (isAuthenticated && isAuthRoute) return '/';

      return null;
    },
  );
}

class MainScaffold extends StatelessWidget {
  final Widget child;
  final GoRouterState state;

  const MainScaffold({super.key, required this.child, required this.state});

  int _calculateSelectedIndex() {
    final location = state.uri.toString();
    if (location.startsWith('/chain-log')) return 1;
    if (location.startsWith('/notifications')) return 2;
    if (location.startsWith('/profile')) return 3;
    if (location.startsWith('/')) return 0;
    return 0;
  }

  void _onItemTapped(int index, BuildContext context) {
    switch (index) {
      case 0:
        GoRouter.of(context).go('/');
        break;
      case 1:
        GoRouter.of(context).go('/chain-log');
        break;
      case 2:
        GoRouter.of(context).go('/notifications');
        break;
      case 3:
        GoRouter.of(context).go('/profile');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isAtHome = _calculateSelectedIndex() == 0;

    return PopScope(
      canPop: isAtHome,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) {
          _onItemTapped(0, context);
        }
      },
      child: Scaffold(
        body: child,
        bottomNavigationBar: Consumer<NotificationProvider>(
          builder: (context, notificationProvider, child) {
            final hasUnreadNotifications =
                notificationProvider.hasUnreadNotifications;
            return BottomNavigationBar(
              currentIndex: _calculateSelectedIndex(),
              onTap: (index) => _onItemTapped(index, context),
              type: BottomNavigationBarType.fixed,
              items: [
                const BottomNavigationBarItem(
                  icon: Icon(Icons.inventory_2_outlined),
                  label: 'Inventario',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.swap_horiz),
                  label: 'Transazioni',
                ),
                BottomNavigationBarItem(
                  icon: Stack(
                    children: [
                      const Icon(Icons.notifications_outlined),
                      if (hasUnreadNotifications)
                        Positioned(
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(1),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 8,
                              minHeight: 8,
                            ),
                          ),
                        ),
                    ],
                  ),
                  label: 'Notifiche',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  label: 'Profilo',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
