library;

import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:video_compress/video_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'camera_state.dart';

class VideoService {
  final FirebaseStorage _storage;

  VideoService({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  Future<String?> compressVideo(
    String inputPath, {
    void Function(double progress)? onProgress,
  }) async {
    Subscription? subscription;
    if (onProgress != null) {
      subscription = VideoCompress.compressProgress$.subscribe((progress) {
        onProgress(progress / 100.0);
      });
    }

    try {
      final MediaInfo? info = await VideoCompress.compressVideo(
        inputPath,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      return info?.file?.path;
    } finally {
      subscription?.unsubscribe();
    }
  }

  Future<String?> uploadToFirebase(
    String filePath, {
    String? storagePath,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    final fileName = storagePath ??
        'videos/${DateTime.now().millisecondsSinceEpoch}.mp4';

    final ref = _storage.ref().child(fileName);

    final uploadTask = ref.putFile(
      file,
      SettableMetadata(contentType: 'video/mp4'),
    );

    if (onProgress != null) {
      uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress(progress);
      });
    }

    await uploadTask;
    return await ref.getDownloadURL();
  }

  /// Full pipeline: compress -> upload, updating notifier state along the way.
  Future<String?> processAndUpload(
    String videoPath,
    CameraNotifier notifier, {
    String? storagePath,
  }) async {
    notifier.setCompressing(videoPath);
    final compressedPath = await compressVideo(
      videoPath,
      onProgress: (p) => notifier.setCompressing(videoPath, progress: p),
    );

    if (compressedPath == null) {
      notifier.setError('Video compression failed');
      return null;
    }

    notifier.setUploading(compressedPath);
    try {
      final downloadUrl = await uploadToFirebase(
        compressedPath,
        storagePath: storagePath,
        onProgress: (p) => notifier.setUploading(compressedPath, progress: p),
      );

      notifier.setDone(downloadUrl: downloadUrl, message: 'Upload complete!');
      return downloadUrl;
    } catch (e) {
      notifier.setError('Upload failed: $e');
      return null;
    }
  }

  void dispose() {
    VideoCompress.cancelCompression();
  }
}

final videoServiceProvider = Provider<VideoService>((ref) {
  final service = VideoService();
  ref.onDispose(() => service.dispose());
  return service;
});