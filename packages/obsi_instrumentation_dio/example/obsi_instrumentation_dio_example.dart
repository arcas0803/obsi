import 'package:dio/dio.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_dio/obsi_instrumentation_dio.dart';

Future<void> main() async {
  final dio = Dio();
  dio.interceptors.add(
    ObsiDioInterceptor(tracer: Obsi.tracer, meter: Obsi.meter('http.client')),
  );
  await dio.get<void>('https://example.com');
}
