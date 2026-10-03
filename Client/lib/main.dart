import 'package:flutter/material.dart';
import 'package:myapp/auth/auth_provider.dart';
import 'package:myapp/notifications/notification_provider.dart';
import 'package:myapp/router.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;

void main() {
  // Set the default locale for timeago
  timeago.setLocaleMessages('it', timeago.ItMessages());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AuthProvider()),
        ChangeNotifierProvider(create: (context) => NotificationProvider()),
      ],
      child: Builder(
        builder: (context) {
          final authProvider = Provider.of<AuthProvider>(context, listen: false);
          final router = AppRouter(authProvider: authProvider).router;

          return MaterialApp.router(
            title: 'BIS',
            theme: ThemeData(
              primarySwatch: Colors.blue,
              visualDensity: VisualDensity.adaptivePlatformDensity,
              scaffoldBackgroundColor: Colors.grey[50],
            ),
            routerConfig: router,
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}
