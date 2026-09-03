import 'package:flutter/material.dart';

import 'src/ui/home_screen.dart';
import 'src/ui/theme.dart';

void main() {
  runApp(const SyncnFlasherApp());
}

class SyncnFlasherApp extends StatelessWidget {
  const SyncnFlasherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncN Flasher',
      debugShowCheckedModeBanner: false,
      theme: SyncnTheme.light,
      darkTheme: SyncnTheme.dark,
      // Light is built for a desk, dark for a phone at a job site at night;
      // the phone already knows which situation it is in.
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
