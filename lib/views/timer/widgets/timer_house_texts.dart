import 'dart:async';

import 'package:flutter/material.dart';
import 'package:medito/models/timer/timer_house_content.dart';

/// Línea del día de práctica: solo en la fecha local que publicó la
/// organización, con su texto tal cual. Se vuelve a revisar a la siguiente
/// medianoche local mientras la pantalla está abierta y al volver a la app
/// (R95). Sin día publicado para hoy no ocupa espacio.
class TimerPracticeDayLine extends StatefulWidget {
  const TimerPracticeDayLine({
    super.key,
    required this.content,
    this.clock = DateTime.now,
  });

  final TimerHouseContent content;

  /// Hora local actual; las pruebas la reemplazan.
  final DateTime Function() clock;

  @override
  State<TimerPracticeDayLine> createState() => _TimerPracticeDayLineState();
}

class _TimerPracticeDayLineState extends State<TimerPracticeDayLine>
    with WidgetsBindingObserver {
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleMidnight();
  }

  @override
  void didUpdateWidget(TimerPracticeDayLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) _scheduleMidnight();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // En segundo plano el reloj puede haber cruzado la medianoche sin que
    // corriera el temporizador: se revisa la fecha y se vuelve a programar.
    if (state != AppLifecycleState.resumed || !mounted) return;
    setState(() {});
    _scheduleMidnight();
  }

  /// Programa la revisión para la siguiente medianoche local; cada vez que
  /// se cumple se vuelve a programar.
  void _scheduleMidnight() {
    _midnight?.cancel();
    final now = widget.clock();
    final next = DateTime(now.year, now.month, now.day + 1);
    // Un segundo de margen para no caer todavía en el día anterior.
    final wait = next.difference(now) + const Duration(seconds: 1);
    _midnight = Timer(wait, () {
      if (!mounted) return;
      setState(() {});
      _scheduleMidnight();
    });
  }

  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final day = practiceDayFor(widget.content, widget.clock());
    if (day == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        day.text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

/// Texto de apertura de la organización, justo arriba de «Empezar», con el
/// estilo de texto normal. Se ve antes de empezar, o sea antes de la campana
/// de inicio. Sin texto no ocupa espacio.
class TimerOpeningText extends StatelessWidget {
  const TimerOpeningText({super.key, required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final value = text;
    if (value == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    // Hasta 500 letras: con letra grande se desplaza en vez de empujar el
    // botón fuera de la pantalla.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.25;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }
}
