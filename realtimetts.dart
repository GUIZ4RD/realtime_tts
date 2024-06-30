import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

enum TTSStatus { ready, loading, speaking }

class RealtimeTTS {
  final AudioPlayer _audioPlayer = AudioPlayer();

  int _currentPlaying = 0;
  int _currentDownloading = 0;
  int _endIndex = -1;

  int _receivedBytes = 0;
  final int bufferThreshold;

  final String ttsServerUrl;

  RealtimeTTS(this.ttsServerUrl, {this.bufferThreshold = 100000});

  late final StreamController<TTSStatus> _onStatusChangedController =
      StreamController<TTSStatus>.broadcast();
  Stream<TTSStatus> get onStatusChanged => _onStatusChangedController.stream;

  Future<String> getCurrentFilePath(int index) async {
    final tempDir = await getTemporaryDirectory();
    final fname = 'temp_audio_$index.mp3';
    return path.join(tempDir.path, fname);
  }

  void _setCompletionHandler() {
    _audioPlayer.onPlayerComplete.listen((_) async {
      debugPrint('Audio completed');
      if (_currentPlaying >= _endIndex && _endIndex != -1) {
        await _audioPlayer.stop();
        await _audioPlayer.dispose();
        debugPrint('Audio player disposed');
        _onStatusChangedController.add(TTSStatus.ready);
      } else {
        _playAudioclip();
      }
    });
  }

  Future<http.StreamedResponse> ttsRequest(String text) {
    final client = http.Client();
    final request = http.Request('POST', Uri.parse(ttsServerUrl));
    request.body = json.encode({"text": text});
    request.headers['Content-Type'] = 'application/json';
    return client.send(request);
  }

  Future<void> _playAudioclip() async {
    try {
      String fpath = await getCurrentFilePath(_currentPlaying);
      if (await File(fpath).exists()) {
        await _audioPlayer.setSourceDeviceFile(fpath);
        debugPrint('Playing audio: $fpath');
        await _audioPlayer.resume();
        _currentPlaying++;
      } else {
        debugPrint('File does not exist: $fpath');
      }
    } catch (e) {
      debugPrint('Error playing audio: $e');
      _onStatusChangedController.add(TTSStatus.ready);
    }
  }

  Future<void> _storeAudioclip(List<int> buffer) async {
    try {
      String fpath = await getCurrentFilePath(_currentDownloading);
      final tempFile = File(fpath);
      debugPrint('Writing to file: $fpath');
      await tempFile.writeAsBytes(buffer);
      _currentDownloading++;
    } catch (e) {
      debugPrint('Error storing audio clip: $e');
      _onStatusChangedController.add(TTSStatus.ready);
    }
  }

  Future<void> play(String text) async {
    try {
      _onStatusChangedController.add(TTSStatus.loading);

      final response = await ttsRequest(text);

      if (response.statusCode == 200) {
        _currentPlaying = 0;

        final List<int> buffer = [];
        _setCompletionHandler();

        response.stream.listen(
          (data) async {
            buffer.addAll(data);
            _receivedBytes += data.length;

            debugPrint('RECEIVED BYTES: $_receivedBytes / $bufferThreshold');

            if (_receivedBytes >= bufferThreshold) {
              _receivedBytes = 0;
              await _storeAudioclip(List.from(buffer));
              buffer.clear();

              if (_audioPlayer.state != PlayerState.playing) {
                await _playAudioclip();
                _onStatusChangedController.add(TTSStatus.speaking);
              }
            }
          },
          onDone: () async {
            debugPrint('Stream completed');
            if (buffer.isNotEmpty) {
              debugPrint('Writing remaining buffer to file');
              await _storeAudioclip(List.from(buffer));
              _endIndex = _currentDownloading;
            }
          },
          onError: (error) {
            debugPrint('An error occurred during streaming: $error');
            _onStatusChangedController.add(TTSStatus.ready);
          },
          cancelOnError: true,
        );
      } else {
        debugPrint('An error occurred during request: ${response.statusCode}');
        _onStatusChangedController.add(TTSStatus.ready);
      }
    } catch (e) {
      debugPrint('An error occurred: $e');
      _onStatusChangedController.add(TTSStatus.ready);
    }
  }

  void dispose() {
    _onStatusChangedController.close();
    _audioPlayer.dispose();
  }
}
