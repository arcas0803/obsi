import 'package:obsi_instrumentation_shelf/obsi_instrumentation_shelf.dart';
import 'package:shelf/shelf.dart';

void main() {
  final handler = const Pipeline()
      .addMiddleware(obsiMiddleware())
      .addHandler((_) => Response.ok('ok'));
  handler;
}
