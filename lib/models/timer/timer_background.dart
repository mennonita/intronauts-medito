enum TimerBackgroundKind { animation, image, color, black }

enum TimerBackground {
  breathing(TimerBackgroundKind.animation, 'respiracion'),
  waves(TimerBackgroundKind.animation, 'ondas'),
  particles(TimerBackgroundKind.animation, 'particulas'),
  sunrise(TimerBackgroundKind.image, 'amanecer'),
  mist(TimerBackgroundKind.image, 'bruma'),
  night(TimerBackgroundKind.image, 'noche'),
  slate(TimerBackgroundKind.color, 'pizarra'),
  forest(TimerBackgroundKind.color, 'bosque'),
  plum(TimerBackgroundKind.color, 'ciruela'),
  ocean(TimerBackgroundKind.color, 'oceano'),
  cream(TimerBackgroundKind.color, 'crema'),
  ice(TimerBackgroundKind.color, 'hielo'),
  rose(TimerBackgroundKind.color, 'rosa'),
  lavender(TimerBackgroundKind.color, 'lavanda'),
  black(TimerBackgroundKind.black, 'negro');

  const TimerBackground(this.kind, this.id);

  final TimerBackgroundKind kind;
  final String id;

  static const defaultValue = breathing;

  String serialize() => '${kind.name}:$id';

  static TimerBackground parse(String? value) {
    return values.firstWhere(
      (option) => option.serialize() == value,
      orElse: () => defaultValue,
    );
  }
}
