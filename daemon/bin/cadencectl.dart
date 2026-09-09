import 'dart:convert';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'Usage: cadencectl SOCKET get|post|put|delete PATH [JSON_BODY]',
    );
    exitCode = 64;
    return;
  }
  final client = CadenceClient(UnixMediaTransport(args[0]));
  try {
    stdout.writeln(
      jsonEncode(
        await client.call(
          args[1],
          args[2],
          args.length > 3
              ? (jsonDecode(args[3]) as Map).cast<String, Object?>()
              : null,
        ),
      ),
    );
  } catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    await client.close();
  }
}
