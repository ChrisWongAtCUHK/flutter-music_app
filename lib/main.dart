import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

void main() => runApp(
  const MaterialApp(
    home: LocalMusicPlayer(),
    // 移除右上角的 Debug 標籤
    debugShowCheckedModeBanner: false,
  ),
);

class LocalMusicPlayer extends StatefulWidget {
  const LocalMusicPlayer({super.key});

  @override
  State<LocalMusicPlayer> createState() => _LocalMusicPlayerState();
}

// 加上 WidgetsBindingObserver 用來監聽權限視窗關閉、回到 App 的事件
class _LocalMusicPlayerState extends State<LocalMusicPlayer>
    with WidgetsBindingObserver {
  final OnAudioQuery _audioQuery = OnAudioQuery();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _hasPermission = false;
  bool _isLoading = true; // 新增：讀取狀態鎖

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 註冊監聽器
    _checkAndRequestPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 註銷監聽器
    _audioPlayer.dispose();
    super.dispose();
  }

  // 當 App 生命週期改變時觸發（例如從權限視窗回到 App）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 當使用者點完「允許」回到 App 時，重新檢查並強制重整畫面
      _checkAndRequestPermission();
    }
  }

  Future<void> _checkAndRequestPermission() async {
    bool status = false;
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      if (Theme.of(context).platform == TargetPlatform.android) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        if (!mounted) return;

        if (androidInfo.version.sdkInt >= 33) {
          status = await Permission.audio.request().isGranted;
        } else {
          status = await Permission.storage.request().isGranted;
        }
      } else if (Theme.of(context).platform == TargetPlatform.iOS) {
        status = await Permission.mediaLibrary.request().isGranted;
      }
    } catch (e) {
      print("權限請求出錯: $e");
    }

    if (!mounted) return;
    setState(() {
      _hasPermission = status;
      _isLoading = false; // 關閉讀取圈圈
    });
  }

  void _playSong(String? uri) async {
    if (uri == null) return;
    try {
      await _audioPlayer.setAudioSource(AudioSource.uri(Uri.parse(uri)));
      _audioPlayer.play();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("播放失敗: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("本地 MP3 播放器"),
        actions: [
          // 右上角放一個手動整理按鈕，方便測試
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _checkAndRequestPermission,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator()) // 讀取中
          : !_hasPermission
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("需要儲存空間權限才能讀取音樂"),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _checkAndRequestPermission,
                    child: const Text("授予權限"),
                  ),
                ],
              ),
            )
          : FutureBuilder<List<SongModel>>(
              // 每次 _hasPermission 改變或手動點 refresh，這裡就會重新掃描
              future: _audioQuery.querySongs(
                sortType: null,
                orderType: OrderType.ASC_OR_SMALLER,
                uriType: UriType.EXTERNAL,
                ignoreCase: true,
              ),
              builder: (context, item) {
                if (item.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (item.data == null || item.data!.isEmpty) {
                  return const Center(
                    child: Text("未找到本地音樂檔案\n請確認手機記憶體內有 .mp3 檔案"),
                  );
                }

                return ListView.builder(
                  itemCount: item.data!.length,
                  itemBuilder: (context, index) {
                    SongModel song = item.data![index];
                    return ListTile(
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(song.artist ?? "未知歌手"),
                      leading: QueryArtworkWidget(
                        id: song.id,
                        type: ArtworkType.AUDIO,
                        nullArtworkWidget: const Icon(
                          Icons.music_note,
                          size: 40,
                        ),
                      ),
                      trailing: const Icon(Icons.play_arrow),
                      onTap: () => _playSong(song.uri),
                    );
                  },
                );
              },
            ),
    );
  }
}
