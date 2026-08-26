import 'package:http/http.dart' as http;
import 'package:obsi_instrumentation_http/obsi_instrumentation_http.dart';

void main() {
  final client = ObsiHttpClient(http.Client());
  client.close();
}
