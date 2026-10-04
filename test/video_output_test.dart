import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/player/video_output.dart';

void main() {
  test('fallback walks hardware, direct, software, then stops', () {
    final visited = <VideoOutput>[];
    VideoOutput? output = VideoOutput.hardware;
    while (output != null) {
      visited.add(output);
      output = output.fallback;
    }
    expect(visited, [
      VideoOutput.hardware,
      VideoOutput.direct,
      VideoOutput.software,
    ]);
  });

  test('effective follows a pinned preference over what was learned', () {
    addTearDown(() {
      VideoOutput.preference = VideoOutput.auto;
      VideoOutput.learned = VideoOutput.hardware;
    });

    VideoOutput.learned = VideoOutput.direct;
    expect(VideoOutput.effective, VideoOutput.direct);

    VideoOutput.preference = VideoOutput.software;
    expect(VideoOutput.effective, VideoOutput.software);
  });
}
