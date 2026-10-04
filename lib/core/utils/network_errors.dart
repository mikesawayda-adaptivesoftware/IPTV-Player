import 'package:dio/dio.dart';

/// Plain-English reason for a failed request, for showing to a user.
///
/// Dio's own `message` is written for developers - a bad status reads "This
/// exception was thrown because the response has a status code of 404 and
/// RequestOptions.validateStatus was configured to throw..." - and it is what
/// the error screens used to print verbatim.
String describeNetworkError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'The server took too long to respond. It may be busy - try '
          'again in a moment.';
    case DioExceptionType.connectionError:
      return "Couldn't reach the server. Check the address and your internet "
          'connection.';
    case DioExceptionType.badCertificate:
      return "The server's security certificate isn't valid.";
    case DioExceptionType.badResponse:
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        return 'The server refused the login (HTTP $code). Check the '
            'username and password, and that the subscription is active.';
      }
      if (code == 404) {
        return 'Nothing was found at that address (HTTP 404). Check the URL.';
      }
      if (code != null && code >= 500) {
        return 'The server had a problem (HTTP $code). Try again later.';
      }
      return 'The server answered with an error (HTTP ${code ?? '?'}).';
    case DioExceptionType.cancel:
      return 'The request was cancelled.';
    case DioExceptionType.unknown:
      return "Couldn't reach the server. Check the address and your internet "
          'connection.';
  }
}

/// Strips the `Exception: ` prefix Dart puts on `Exception('...').toString()`,
/// which is how most load errors reach the UI.
String userFacingError(Object error) {
  var text = error.toString();
  while (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length);
  }
  return text;
}
