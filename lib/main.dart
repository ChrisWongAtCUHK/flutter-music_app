import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';

void main() => runApp(const MaterialApp(home: LocalMusicPlayer()));

class LocalMusicPlayer extends StatefulWidget {
  const LocalMusicPlayer({super.key});

  @override
  State<LocalMusicPlayer> createState() => _LocalMusicPlayerState();
}

class _LocalMusicPlayerState extends State<LocalMusicPlayer> {
  final OnAudioQuery _audioQuery = OnAudioQuery();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    _checkAndRequestPermission();
  }

  // 1. 檢查並動態申請手機儲存權限
  Future<void> _checkAndRequestPermission() async {
    // 檢查目前是否已擁有權限
    bool permissionStatus = await _audioQuery.permissionsStatus();

    if (!permissionStatus) {
      // 如果沒有，向系統發起請求
      permissionStatus = await _audioQuery.permissionsStatus(); // 內部封裝的權限請求
    }

    setState(() {
      _hasPermission = permissionStatus;
    });
  }

  // 2. 播放選中的本地歌曲
  void _playSong(String? uri) async {
    if (uri == null) return;
    try {
      // just_audio 可以直接解析 on_audio_query 提供的本地 Uri 檔案路徑
      await _audioPlayer.setAudioSource(AudioSource.uri(Uri.parse(uri)));
      if (!mounted) return;

      _audioPlayer.play();
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("播放失敗: $e")));
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose(); // 記得關閉播放器釋放記憶體
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("本地 MP3 播放器")),
      body: !_hasPermission
          ? Center(
              child: ElevatedButton(
                onPressed: _checkAndRequestPermission,
                child: const Text("授權讀取手機音樂"),
              ),
            )
          : FutureBuilder<List<SongModel>>(
              // 3. 自動掃描裝置內的所有音訊檔案
              future: _audioQuery.querySongs(
                sortType: null,
                orderType: OrderType.ASC_OR_SMALLER,
                uriType: UriType.EXTERNAL,
                ignoreCase: true,
              ),
              builder: (context, item) {
                // 載入中的讀取圈圈
                if (item.data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                // 手機內沒撈到任何 MP3 檔案
                if (item.data!.isEmpty) {
                  return const Center(child: Text("未找到本地音樂檔案"));
                }

                // 4. 渲染音樂列表 UI
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
                      // 顯示內嵌在 MP3 檔案裡的專輯封面，若無則顯示預設音樂圖示
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
