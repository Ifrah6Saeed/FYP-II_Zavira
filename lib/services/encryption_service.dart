import 'package:encrypt/encrypt.dart';

class EncryptionService {
  static final Key key = Key.fromUtf8("1234567890123456");
  static final IV iv = IV.fromUtf8("abcdefghijklmnop");

  static final Encrypter encrypter = Encrypter(AES(key));

  static String encryptMessage(String message) {
    return encrypter.encrypt(message, iv: iv).base64;
  }

  static String decryptMessage(String encryptedText) {
    return encrypter.decrypt64(encryptedText, iv: iv);
  }
}