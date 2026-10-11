import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'screens/api_reception_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LeadManagementApp());
}

class LeadManagementApp extends StatefulWidget {
  const LeadManagementApp({super.key});

  @override
  State<LeadManagementApp> createState() => _LeadManagementAppState();
}

class _LeadManagementAppState extends State<LeadManagementApp> {
  late final Future<void>? _initialization = AppConfig.isSupabaseConfigured
      ? Supabase.initialize(
          url: AppConfig.supabaseUrl,
          publishableKey: AppConfig.supabasePublishableKey,
        )
      : null;

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF1667D9);

    return MaterialApp(
      title: 'Lead Management',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          surface: const Color(0xFFF5F7FB),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        useMaterial3: true,
      ),
      home: _initialization == null
          ? const ApiReceptionScreen()
          : FutureBuilder<void>(
              future: _initialization,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _StartupError(error: snapshot.error!);
                }
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                return const _AuthenticatedHome();
              },
            ),
    );
  }
}

class _AuthenticatedHome extends StatelessWidget {
  const _AuthenticatedHome();

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _StartupError(error: snapshot.error!);
        }
        final session = snapshot.data?.session ?? client.auth.currentSession;
        return session == null
            ? const LoginScreen()
            : const DashboardScreen();
      },
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Could not connect to Supabase',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                SelectableText('$error'),
                const SizedBox(height: 12),
                const Text('Check SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
