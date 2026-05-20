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
  // 初始化一個空的可追加播放佇列
  final ConcatenatingAudioSource _playlist = ConcatenatingAudioSource(
    children: [],
  );

  // 記錄目前加進播放佇列裡的歌曲物件（給播放佇列畫面 UI 使用）
  final List<SongModel> _myCurrentQueue = [];
  bool _hasPermission = false;
  bool _isLoading = true; // 新增：讀取狀態鎖

  SongModel? _currentSong;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 註冊監聽器
    _checkAndRequestPermission();

    // 讓播放器載入這個空的佇列
    _audioPlayer.setAudioSource(_playlist);

    // 監聽播放器目前播到第幾首，自動更新 Mini Player 的 UI
    _audioPlayer.currentIndexStream.listen((index) {
      if (index != null && index < _myCurrentQueue.length && mounted) {
        setState(() {
          _currentSong = _myCurrentQueue[index];
        });
      }
    });
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
      debugPrint("權限請求出錯: $e");
    }

    if (!mounted) return;
    setState(() {
      _hasPermission = status;
      _isLoading = false; // 關閉讀取圈圈
    });
  }

  void _playSong(SongModel song) async {
    try {
      // 1. 檢查這首歌是否已經在佇列中（若不想重複加入可以加這行判斷，若允許重複可刪除）
      // if (_myCurrentQueue.any((element) => element.id == song.id)) return;

      // 2. 包裝成 AudioSource 並追加到 just_audio 的佇列結尾
      final source = AudioSource.uri(Uri.parse(song.uri!), tag: song);
      await _playlist.add(source);

      // 3. 同步加到我們自己的 UI 歌單陣列裡
      setState(() {
        _myCurrentQueue.add(song);
      });

      // 4. 如果這是加入的第一首歌（目前播放器是停止或剛啟動狀態），就直接播放
      if (_audioPlayer.processingState == ProcessingState.idle ||
          _playlist.length == 1) {
        setState(() {
          _currentSong = song;
        });
        await _audioPlayer.seek(Duration.zero, index: _playlist.length - 1);
        _audioPlayer.play();
      } else {
        if (!mounted) return;
        // 如果本來就在放歌，跳出提示告訴用戶已成功加入佇列
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("已加入播放佇列: ${song.title}")));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("加入失敗: $e")));
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
      // 使用 Stack 疊加底部的 Mini Player 控制列
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : !_hasPermission
              ? Center(
                  child: ElevatedButton(
                    onPressed: _checkAndRequestPermission,
                    child: const Text("授予權限"),
                  ),
                )
              : FutureBuilder<List<SongModel>>(
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
                      return const Center(child: Text("未找到本地音樂檔案"));
                    }

                    return ListView.builder(
                      // 留出底部空間給 Mini Player，避免最後一首歌被遮擋
                      padding: EdgeInsets.only(
                        bottom: _currentSong != null ? 80 : 0,
                      ),
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
                          onTap: () => _playSong(item.data![index]),
                        );
                      },
                    );
                  },
                ),

          // 實作底部迷你播放控制列 (Mini Player)
          if (_currentSong != null) _buildMiniPlayer(),
        ],
      ),
    );
  }

  // 底部 Mini Player 元件
  Widget _buildMiniPlayer() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Colors.blueGrey[900], // 深色控制列背景
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // 迷你封面
            QueryArtworkWidget(
              id: _currentSong!.id,
              type: ArtworkType.AUDIO,
              nullArtworkWidget: const Icon(
                Icons.music_note,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(width: 12),
            // 歌名與歌手
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentSong!.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _currentSong!.artist ?? "未知歌手",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),

            // 監聽播放器狀態，動態切換 播放/暫停 按鈕
            StreamBuilder<PlayerState>(
              stream: _audioPlayer.playerStateStream,
              builder: (context, snapshot) {
                final playerState = snapshot.data;
                final playing = playerState?.playing ?? false;

                return Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => _audioPlayer.seekToPrevious(),
                    ),
                    // 1. 播放 / 暫停 控制鈕
                    IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      color: Colors.white,
                      onPressed: () {
                        if (playing) {
                          _audioPlayer.pause(); // 執行暫停：停在當前秒數
                        } else {
                          _audioPlayer.play(); // 執行續播：從剛才地方繼續
                        }
                      },
                    ),
                    // 2. 停止 控制鈕
                    IconButton(
                      icon: const Icon(Icons.stop),
                      color: Colors.redAccent,
                      onPressed: () async {
                        await _audioPlayer.stop(); // 執行停止：關閉音訊並重設進度
                        setState(() {
                          _currentSong = null; // 關閉底部的 Mini Player 介面
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => _audioPlayer.seekToNext(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          builder: (context) {
                            return Container(
                              padding: const EdgeInsets.all(16),
                              height:
                                  MediaQuery.of(context).size.height *
                                  0.6, // 60% screen height
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    "播放隊列",
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Divider(),
                                  Expanded(
                                    // Pass list of songs here
                                    child: _buildPlaylistViewer(
                                      _myCurrentQueue,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistViewer(List<SongModel> playlistSongs) {
    return StreamBuilder<int?>(
      stream: _audioPlayer.currentIndexStream,
      builder: (context, snapshot) {
        final currentIndex = snapshot.data;

        return ListView.builder(
          shrinkWrap:
              true, // Useful if you place this inside a ModalBottomSheet or Column
          physics: const ClampingScrollPhysics(),
          itemCount: playlistSongs.length,
          itemBuilder: (context, index) {
            final song = playlistSongs[index];
            final isPlaying = currentIndex == index;

            return ListTile(
              leading: QueryArtworkWidget(
                id: song.id,
                type: ArtworkType.AUDIO,
                errorBuilder: (context, exception, giddig) {
                  return const Icon(Icons.music_note, color: Colors.blue);
                },
              ),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                  color: isPlaying ? Colors.blue : Colors.black,
                ),
              ),
              subtitle: Text(song.artist ?? "未知藝術家"),
              trailing: isPlaying
                  ? const Icon(Icons.volume_up, color: Colors.blue)
                  : const Icon(
                      Icons.dehaze,
                    ), // Visual cue for list reordering/queue
              onTap: () async {
                // Jump directly to the clicked song in the active playlist
                await _audioPlayer.seek(Duration.zero, index: index);
              },
            );
          },
        );
      },
    );
  }
}
