import 'dart:io';
import 'package:serverpod_shared/serverpod_shared.dart';

void main() {
  var passwords = PasswordManager(runMode: 'development').loadPasswords(
    serverDirectory: Directory('empty'),
  );

  stdout.write(passwords.toString());
}
