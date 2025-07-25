import 'dart:typed_data';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:serverpod_test_client/serverpod_test_client.dart';
import 'package:serverpod_test_server/test_util/config.dart';
import 'package:test/test.dart';

Stream<int> streamBytes() async* {
  int i = 0;
  while (true) yield i++ % 256;
}

extension<T> on Stream<T> {
  Stream<List<T>> inChunksOf(int chunkSize) async* {
    var chunk = <T>[];
    await for (final e in this) {
      chunk.add(e);
      if (chunk.length >= chunkSize) {
        yield chunk;
        chunk = <T>[]; // new
      }
    }
  }
}

ByteData createByteData(int len) {
  var ints = Uint8List(len);
  for (var i = 0; i < len; i++) {
    ints[i] = i % 256;
  }
  return ByteData.view(ints.buffer);
}

bool verifyByteData(ByteData byteData) {
  var ints = byteData.buffer.asUint8List();
  for (var i = 0; i < ints.length; i++) {
    if (ints[i] != i % 256) return false;
  }
  return true;
}

void main() {
  var client = Client(serverUrl);

  setUp(() {});

  group('Database cloud storage', () {
    test('Clear files', () async {
      await client.cloudStorage.reset();
    });

    test('Store file 1', () async {
      await client.cloudStorage
          .storePublicFile('testdir/myfile1.bin', createByteData(256));
    });

    test('Store file 2', () async {
      await client.cloudStorage
          .storePublicFile('testdir/myfile2.bin', createByteData(256));
    });

    test('Replace file 1', () async {
      await client.cloudStorage
          .storePublicFile('testdir/myfile1.bin', createByteData(128));
    });

    test('Retrieve file 1', () async {
      var byteData =
          await client.cloudStorage.retrievePublicFile('testdir/myfile1.bin');
      expect(byteData!.lengthInBytes, equals(128));
      expect(verifyByteData(byteData), equals(true));
    });

    test('Retrieve file 2 through URL', () async {
      var url = Uri.parse(
          '${serverUrl}serverpod_cloud_storage?method=file&path=testdir/myfile2.bin');
      var response = await http.get(url);
      expect(response.statusCode, equals(200));
      var bytes = response.bodyBytes;
      expect(bytes.length, equals(256));
      verifyByteData(ByteData.view(bytes.buffer));
    });

    test('Retrieve file 1 URL', () async {
      var urlStr =
          await client.cloudStorage.getPublicUrlForFile('testdir/myfile1.bin');
      expect(urlStr, isNotNull);
    });

    test('Retrieve file 2 through fetched URL', () async {
      var urlStr =
          await client.cloudStorage.getPublicUrlForFile('testdir/myfile2.bin');
      var url = Uri.parse(urlStr!);
      var response = await http.get(url);
      expect(response.statusCode, equals(200));
      var bytes = response.bodyBytes;
      expect(bytes.length, equals(256));
      verifyByteData(ByteData.view(bytes.buffer));
    });

    test('Retrieve file 2', () async {
      var byteData =
          await client.cloudStorage.retrievePublicFile('testdir/myfile2.bin');
      expect(byteData!.lengthInBytes, equals(256));
      expect(verifyByteData(byteData), equals(true));
    });

    test('Retrieve non existing file', () async {
      var byteData =
          await client.cloudStorage.retrievePublicFile('testdir/myfile3.bin');
      expect(byteData, isNull);
    });

    test('Retrieve non existing file through URL', () async {
      var url = Uri.parse(
          '${serverUrl}serverpod_cloud_storage?method=file&path=testdir/myfile3.bin');
      var response = await http.get(url);
      expect(response.statusCode, equals(404));
    });

    test('Attempt retrieve file through URL with invalid params', () async {
      var url = Uri.parse(
          '${serverUrl}serverpod_cloud_storage?method=file&foo=testdir/myfile2.bin');
      var response = await http.get(url);
      expect(response.statusCode, equals(400));
    });

    test('Attempt retrieve file through URL with invalid method', () async {
      var url = Uri.parse(
          '${serverUrl}serverpod_cloud_storage?foo=file&path=testdir/myfile2.bin');
      var response = await http.get(url);
      expect(response.statusCode, equals(400));
    });

    test('Exists file 1', () async {
      var exists =
          await client.cloudStorage.existsPublicFile('testdir/myfile1.bin');
      expect(exists, true);
    });

    test('Exists non existing file', () async {
      var exists =
          await client.cloudStorage.existsPublicFile('testdir/myfile3.bin');
      expect(exists, false);
    });

    test('Delete file 1', () async {
      await client.cloudStorage.deletePublicFile('testdir/myfile1.bin');
    });

    test('Exists file 1 after deletion', () async {
      var exists =
          await client.cloudStorage.existsPublicFile('testdir/myfile1.bin');
      expect(exists, false);
    });

    test('Direct file upload (ByteData)', () async {
      var uploadDescription = await client.cloudStorage
          .getDirectFilePostUrl('testdir/directupload.bin');
      expect(uploadDescription, isNotNull);
      var byteData = createByteData(1024);

      var uploader = FileUploader(uploadDescription!);
      var result = await uploader.uploadByteData(byteData);

      expect(result, equals(true));

      var verified = await client.cloudStorage
          .verifyDirectFileUpload('testdir/directupload.bin');
      expect(verified, equals(true));
    });

    test('Retrieve directly uploaded file (ByteData)', () async {
      var byteData = await client.cloudStorage
          .retrievePublicFile('testdir/directupload.bin');
      expect(byteData!.lengthInBytes, equals(1024));
      expect(verifyByteData(byteData), equals(true));
    });

    test('Direct file upload (Stream<List<int>>)', () async {
      var uploadDescription = await client.cloudStorage
          .getDirectFilePostUrl('testdir/directupload_stream_binary.bin');
      expect(uploadDescription, isNotNull);

      var uploader = FileUploader(uploadDescription!);
      var result =
          await uploader.upload(streamBytes().take(512).inChunksOf(64));

      expect(result, equals(true));

      var verified = await client.cloudStorage
          .verifyDirectFileUpload('testdir/directupload_stream_binary.bin');
      expect(verified, equals(true));

      var retrievedByteData = await client.cloudStorage
          .retrievePublicFile('testdir/directupload_stream_binary.bin');
      expect(retrievedByteData!.lengthInBytes, equals(512));
      expect(verifyByteData(retrievedByteData), equals(true));
    });

    test('Attempt to upload twice with the same FileUploader', () async {
      var uploadDescription = await client.cloudStorage
          .getDirectFilePostUrl('testdir/directupload_duplicate.bin');
      expect(uploadDescription, isNotNull);
      var byteData = createByteData(100);

      var uploader = FileUploader(uploadDescription!);
      var result = await uploader.uploadByteData(byteData);
      expect(result, equals(true));

      expect(
        () async => await uploader.uploadByteData(byteData),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('Data has already been uploaded using this FileUploader.'),
        )),
      );
    });
  });
}
