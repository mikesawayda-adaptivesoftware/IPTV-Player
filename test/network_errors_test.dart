import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/utils/network_errors.dart';

DioException _dio(DioExceptionType type, {int? status}) {
  final options = RequestOptions(path: '/player_api.php');
  return DioException(
    requestOptions: options,
    type: type,
    response: status == null
        ? null
        : Response(requestOptions: options, statusCode: status),
  );
}

void main() {
  group('describeNetworkError', () {
    test('never echoes Dio developer text', () {
      for (final type in DioExceptionType.values) {
        final text = describeNetworkError(_dio(type, status: 418));
        expect(text, isNot(contains('RequestOptions')));
        expect(text, isNot(contains('DioException')));
      }
    });

    test('points at credentials for a refused login', () {
      expect(
        describeNetworkError(_dio(DioExceptionType.badResponse, status: 401)),
        contains('username and password'),
      );
    });

    test('names the status code for other bad responses', () {
      expect(
        describeNetworkError(_dio(DioExceptionType.badResponse, status: 884)),
        contains('884'),
      );
    });
  });

  group('userFacingError', () {
    test('strips nested Exception prefixes', () {
      expect(
        userFacingError(Exception('Exception: Account is not active')),
        'Account is not active',
      );
    });

    test('leaves plain strings alone', () {
      expect(userFacingError('Nope'), 'Nope');
    });
  });
}
