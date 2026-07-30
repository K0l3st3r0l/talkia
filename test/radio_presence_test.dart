// Cubre la lógica pura de presencia y orden de radio_screen.dart: detección
// de ingresos genuinos vs. reconexiones, formato del aviso y orden de la
// hoja inferior. No requiere emulador ni RadioService real.
import 'package:flutter_test/flutter_test.dart';
import 'package:talkia/features/radio/presentation/radio_screen.dart';
import 'package:talkia/features/radio/services/radio_service.dart';

RoomUser _u(String id, String name, {int build = 30}) =>
    RoomUser(id: id, name: name, build: build);

void main() {
  group('presenceKeyFor', () {
    test('usa el client_id cuando existe', () {
      expect(presenceKeyFor(_u('abc123', 'Ana')), 'abc123');
    });

    test('cae al nombre cuando el id viene vacío (legacy)', () {
      expect(presenceKeyFor(_u('', 'Ana')), 'name:Ana');
    });
  });

  group('newArrivals', () {
    test('lista vacía no produce ingresos', () {
      final arrivals = newArrivals(
        newUsers: const [],
        previousKeys: {},
        lastSeenAt: {},
        now: DateTime(2026, 1, 1),
      );
      expect(arrivals, isEmpty);
    });

    test('primer usuario nunca visto es un ingreso genuino', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final arrivals = newArrivals(
        newUsers: [_u('a1', 'Mau')],
        previousKeys: {},
        lastSeenAt: {},
        now: now,
      );
      expect(arrivals, ['Mau']);
    });

    test('reconexión dentro de 60s se suprime', () {
      final now = DateTime(2026, 1, 1, 12, 0, 30);
      final arrivals = newArrivals(
        newUsers: [_u('a1', 'Mau')],
        previousKeys: {}, // ya no estaba en el roster inmediatamente anterior
        lastSeenAt: {'a1': now.subtract(const Duration(seconds: 30))},
        now: now,
      );
      expect(arrivals, isEmpty);
    });

    test('reingreso después de 60s sí se muestra', () {
      final now = DateTime(2026, 1, 1, 12, 2, 0);
      final arrivals = newArrivals(
        newUsers: [_u('a1', 'Mau')],
        previousKeys: {},
        lastSeenAt: {'a1': now.subtract(const Duration(seconds: 90))},
        now: now,
      );
      expect(arrivals, ['Mau']);
    });

    test('usuario ya presente en el snapshot anterior no es un ingreso', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final arrivals = newArrivals(
        newUsers: [_u('a1', 'Mau')],
        previousKeys: {'a1'},
        lastSeenAt: {'a1': now},
        now: now,
      );
      expect(arrivals, isEmpty);
    });

    test('no deduplica por nombre — dos client_id distintos con mismo nombre cuentan aparte', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final arrivals = newArrivals(
        newUsers: [_u('a1', 'Mau'), _u('a2', 'Mau')],
        previousKeys: {'a1'},
        lastSeenAt: {'a1': now},
        now: now,
      );
      expect(arrivals, ['Mau']);
    });

    test('20 ingresos simultáneos nunca vistos se reportan todos', () {
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final users = List.generate(20, (i) => _u('id$i', 'User$i'));
      final arrivals = newArrivals(
        newUsers: users,
        previousKeys: {},
        lastSeenAt: {},
        now: now,
      );
      expect(arrivals.length, 20);
    });
  });

  group('formatJoinBanner', () {
    test('lista vacía da texto vacío', () {
      expect(formatJoinBanner(const []), '');
    });

    test('un nombre', () {
      expect(formatJoinBanner(const ['Mau']), 'Mau se conectó');
    });

    test('dos nombres', () {
      expect(formatJoinBanner(const ['Mau', 'Ana']), 'Mau y Ana se conectaron');
    });

    test('tres o más nombres se agrupan', () {
      expect(formatJoinBanner(const ['Mau', 'Ana', 'Beto']), 'Mau y 2 más se conectaron');
    });

    test('nombre largo (32 caracteres) no rompe el formato', () {
      final longName = 'N' * 32;
      expect(formatJoinBanner([longName]), '$longName se conectó');
    });
  });

  group('orderUsersForSheet', () {
    bool Function(RoomUser) isMeById(String meId) => (RoomUser u) => u.id == meId;

    test('lista vacía', () {
      final ordered = orderUsersForSheet(users: const [], speakerName: null, isMe: (_) => false);
      expect(ordered, isEmpty);
    });

    test('un solo usuario (yo mismo)', () {
      final users = [_u('me', 'Ana')];
      final ordered = orderUsersForSheet(users: users, speakerName: null, isMe: isMeById('me'));
      expect(ordered.map((u) => u.id), ['me']);
    });

    test('4 usuarios: hablante primero, luego yo, luego el resto en orden de llegada', () {
      final users = [_u('1', 'Ana'), _u('2', 'Beto'), _u('3', 'Caro'), _u('me', 'Yo')];
      final ordered = orderUsersForSheet(users: users, speakerName: 'Caro', isMe: isMeById('me'));
      expect(ordered.map((u) => u.id), ['3', 'me', '1', '2']);
    });

    test('el resto nunca se reordena alfabéticamente', () {
      final users = [_u('1', 'Zeta'), _u('2', 'Alfa'), _u('me', 'Yo')];
      final ordered = orderUsersForSheet(users: users, speakerName: null, isMe: isMeById('me'));
      // "Zeta" llegó antes que "Alfa": debe mantenerse en ese orden pese al nombre.
      expect(ordered.map((u) => u.name), ['Yo', 'Zeta', 'Alfa']);
    });

    test('20 usuarios preservan el orden de llegada del servidor', () {
      final users = List.generate(20, (i) => _u('id$i', 'User$i'));
      final ordered = orderUsersForSheet(users: users, speakerName: null, isMe: (_) => false);
      expect(ordered.map((u) => u.id).toList(), users.map((u) => u.id).toList());
    });

    test('nombre largo de 32 caracteres se conserva íntegro', () {
      final longName = 'N' * 32;
      final users = [_u('1', longName)];
      final ordered = orderUsersForSheet(users: users, speakerName: null, isMe: (_) => false);
      expect(ordered.single.name.length, 32);
    });
  });
}
