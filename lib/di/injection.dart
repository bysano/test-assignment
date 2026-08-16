import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'injection.config.dart';

final GetIt getIt = GetIt.instance;

/// Registers everything in [AppModule] plus the `@injectable` blocs.
///
/// Regenerate after changing registrations:
/// `dart run build_runner build --delete-conflicting-outputs`
@InjectableInit(preferRelativeImports: true, asExtension: true)
void configureDependencies() => getIt.init();
