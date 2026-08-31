import 'dart:ffi';

@Native<Int32 Function()>(symbol: 'rules_flutter_test_symbol')
external int rulesFlutterTestSymbol();
