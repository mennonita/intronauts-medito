import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_background.dart';

void main() {
  test('cada opción se guarda con su tipo e identificador', () {
    const values = [
      'animation:respiracion',
      'animation:ondas',
      'animation:particulas',
      'image:amanecer',
      'image:bruma',
      'image:noche',
      'color:pizarra',
      'color:bosque',
      'color:ciruela',
      'color:oceano',
      'color:crema',
      'color:hielo',
      'color:rosa',
      'color:lavanda',
      'black:negro',
    ];
    expect(TimerBackground.values.map((option) => option.serialize()), values);
    expect(values.map(TimerBackground.parse), TimerBackground.values);
  });

  test('un valor ausente, roto o desconocido usa respiración', () {
    for (final raw in [
      null,
      '',
      'respiracion',
      'animation:',
      'image:respiracion',
      'animation:nuevo',
      'animation:respiracion:extra',
    ]) {
      expect(TimerBackground.parse(raw).serialize(), 'animation:respiracion');
    }
  });
}
