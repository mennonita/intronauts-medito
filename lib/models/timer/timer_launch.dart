/// Ajustes para iniciar el temporizador desde un enlace, widget o atajo.
class TimerLaunch {
  const TimerLaunch({this.minutes, this.presetName, this.last = false});

  final int? minutes;
  final String? presetName;
  final bool last;

  bool get isEmpty => minutes == null && presetName == null && !last;

  static TimerLaunch? fromUri(Uri uri) {
    final isTimerStart = switch ((uri.scheme, uri.host, uri.path)) {
      ('org.meditofoundation', 'medito', '/timer/start') ||
      ('https', 'medito.app', '/timer/start') ||
      ('org.meditofoundation', 'timer', '/start') => true,
      _ => false,
    };
    if (!isTimerStart) return null;

    final query = uri.queryParameters;
    final minutes = int.tryParse(query['minutes'] ?? '', radix: 10);
    final preset = query['preset'];
    return TimerLaunch(
      minutes: minutes != null && minutes >= 1 && minutes <= 299
          ? minutes
          : null,
      presetName: preset == null || preset.isEmpty
          ? null
          : String.fromCharCodes(preset.runes.take(30)),
      last: query['last'] == '1',
    );
  }

  static TimerLaunch? fromRoutePath(String path) {
    final uri = Uri.tryParse('org.meditofoundation://medito/$path');
    return uri == null ? null : fromUri(uri);
  }

  Uri toUri() => Uri(
    scheme: 'org.meditofoundation',
    host: 'medito',
    path: '/timer/start',
    queryParameters: isEmpty
        ? null
        : {
            if (minutes != null) 'minutes': '$minutes',
            if (presetName != null) 'preset': presetName,
            if (last) 'last': '1',
          },
  );
}
