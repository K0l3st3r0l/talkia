// Cubre la lógica pura de precarga OTA de ota_service.dart: nombre de
// archivo por build, validación de tamaño contra Content-Length, decisión de
// precargar según wifi/audio/espacio, y el backoff de reintentos. No
// requiere emulador, Dio ni disco real.
import 'package:flutter_test/flutter_test.dart';
import 'package:talkia/features/ota_update/ota_service.dart';

void main() {
  group('otaApkFileName', () {
    test('nombra el archivo con el build para no confundir builds', () {
      expect(otaApkFileName(32), 'talkia-update-32.apk');
      expect(otaApkFileName(29), 'talkia-update-29.apk');
    });

    test('builds distintos producen nombres distintos', () {
      expect(otaApkFileName(31), isNot(otaApkFileName(32)));
    });
  });

  group('isValidApkFile', () {
    test('archivo vacío es inválido aunque no se conozca el tamaño esperado', () {
      expect(isValidApkFile(actualBytes: 0, expectedBytes: 0), isFalse);
    });

    test('tamaño exacto contra Content-Length es válido', () {
      expect(isValidApkFile(actualBytes: 57000000, expectedBytes: 57000000), isTrue);
    });

    test('descarga cortada (menos bytes que Content-Length) es inválida', () {
      expect(isValidApkFile(actualBytes: 30000000, expectedBytes: 57000000), isFalse);
    });

    test('más bytes que Content-Length también es inválido (corrupción)', () {
      expect(isValidApkFile(actualBytes: 60000000, expectedBytes: 57000000), isFalse);
    });

    test('sin Content-Length disponible, cualquier tamaño positivo pasa', () {
      expect(isValidApkFile(actualBytes: 1234, expectedBytes: 0), isTrue);
    });
  });

  group('shouldPreloadUpdate', () {
    test('wifi + sin audio + espacio suficiente: precarga', () {
      expect(
        shouldPreloadUpdate(isWifi: true, audioActive: false, freeSpaceMb: 500),
        isTrue,
      );
    });

    test('en datos móviles nunca precarga', () {
      expect(
        shouldPreloadUpdate(isWifi: false, audioActive: false, freeSpaceMb: 500),
        isFalse,
      );
    });

    test('con audio activo (transmitting/receiving) nunca precarga aunque haya wifi', () {
      expect(
        shouldPreloadUpdate(isWifi: true, audioActive: true, freeSpaceMb: 500),
        isFalse,
      );
    });

    test('sin espacio suficiente no precarga', () {
      expect(
        shouldPreloadUpdate(isWifi: true, audioActive: false, freeSpaceMb: 50),
        isFalse,
      );
    });

    test('espacio exactamente en el límite requerido sí precarga', () {
      expect(
        shouldPreloadUpdate(
          isWifi: true,
          audioActive: false,
          freeSpaceMb: kOtaRequiredFreeSpaceMb,
        ),
        isTrue,
      );
    });

    test('un byte menos que el límite requerido no precarga', () {
      expect(
        shouldPreloadUpdate(
          isWifi: true,
          audioActive: false,
          freeSpaceMb: kOtaRequiredFreeSpaceMb - 0.01,
        ),
        isFalse,
      );
    });
  });

  group('otaPreloadRetryDelay', () {
    test('crece exponencialmente entre intentos', () {
      final d0 = otaPreloadRetryDelay(0);
      final d1 = otaPreloadRetryDelay(1);
      final d2 = otaPreloadRetryDelay(2);
      expect(d0.inMilliseconds, 2000);
      expect(d1.inMilliseconds, 4000);
      expect(d2.inMilliseconds, 8000);
    });

    test('nunca supera el tope de 30s ni con intentos altos (sin reintentar en bucle)', () {
      expect(otaPreloadRetryDelay(10).inMilliseconds, 30000);
      expect(otaPreloadRetryDelay(100).inMilliseconds, 30000);
    });
  });
}
