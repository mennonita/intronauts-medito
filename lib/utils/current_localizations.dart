import 'package:flutter/widgets.dart';
import 'package:medito/l10n/app_localizations.dart';

AppLocalizations currentLocalizations() =>
    lookupAppLocalizations(_currentLocale());

String currentLanguageTag() => _currentLocale().toLanguageTag();

Locale _currentLocale() => basicLocaleListResolution(
  WidgetsBinding.instance.platformDispatcher.locales,
  AppLocalizations.supportedLocales,
);
