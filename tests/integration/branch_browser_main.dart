import 'package:flutter/material.dart';

import 'core/di/service_locator.dart';
import 'core/routing/app_router.dart';
import 'features/auth/domain/repositories/auth_repository.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'features/auth/presentation/bloc/auth_event.dart';
import 'main.dart' show RmsApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initServiceLocator();
  final session = await sl<AuthRepository>().getCurrentSession();
  if (session == null) throw StateError('The disposable browser session is missing');
  final auth = sl<AuthBloc>();
  final restored = auth.stream.firstWhere((state) => state.isAuthenticated);
  auth.add(SessionRestored(session));
  await restored;
  appRouter.go('/branches');
  runApp(const RmsApp());
}
