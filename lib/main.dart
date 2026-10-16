import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'controllers/assistant_controller.dart';
import 'core/models/app_settings.dart';
import 'ui/screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AssistantController(settings: settings),
        ),
      ],
      child: const SideAssistantApp(),
    ),
  );
}

class SideAssistantApp extends StatelessWidget {
  const SideAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '随身智能助理',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B),
          brightness: Brightness.light,
        ),
        cardTheme: const CardTheme(
          elevation: 1,
          margin: EdgeInsets.zero,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B),
          brightness: Brightness.dark,
        ),
        cardTheme: const CardTheme(
          elevation: 1,
          margin: EdgeInsets.zero,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
