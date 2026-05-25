import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';

late MyAudioHandler audioHandler;

void main() async {
  // 1. 確保 Flutter 引擎初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 2. 初始化音訊背景服務
  audioHandler = await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.musicplayer.channel.audio',
      androidNotificationChannelName: '音樂播放器',
      androidNotificationOngoing: true, // 讓通知欄不可被輕易劃掉
      androidShowNotificationBadge: true,
    ),
  );
  runApp(
    const MaterialApp(
      home: LocalMusicPlayer(),
      // 移除右上角的 Debug 標籤
      debugShowCheckedModeBanner: false,
    ),
  );
}

class LocalMusicPlayer extends StatefulWidget {
  const LocalMusicPlayer({super.key});

  @override
  State<LocalMusicPlayer> createState() => _LocalMusicPlayerState();
}

// 加上 WidgetsBindingObserver 用來監聽權限視窗關閉、回到 App 的事件
class _LocalMusicPlayerState extends State<LocalMusicPlayer>
    with WidgetsBindingObserver {
  final OnAudioQuery _audioQuery = OnAudioQuery();

  // 記錄目前加進播放佇列裡的歌曲物件（給播放佇列畫面 UI 使用）
  final List<SongModel> _myCurrentQueue = [];
  bool _hasPermission = false;
  bool _isLoading = true; // 新增：讀取狀態鎖

  SongModel? _currentSong;

  // 新增：搜尋與歌單暫存變數
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();
  List<SongModel> _allSongsList = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 註冊監聽器

    // 直接從全域 audioHandler 獲取它唯一的播放器，保持狀態同步
    final player = audioHandler.player;

    // 在 App 啟動、畫面還沒畫出來前，先讓播放器載入 audioHandler 內部的播放佇列
    player.setAudioSource(audioHandler.playlist, preload: false).catchError((
      e,
    ) {
      debugPrint("播放器初始載入失敗: $e");
      return null;
    });

    _checkAndRequestPermission();

    // 在 App 啟動時，自動從手機空間找回上次沒播完的歌單
    _loadQueueFromStorage();

    // 監聽播放器目前播到第幾首，自動更新 Mini Player 的 UI
    audioHandler.player.currentIndexStream.listen((index) {
      if (index != null && index < _myCurrentQueue.length && mounted) {
        setState(() {
          _currentSong = _myCurrentQueue[index];
        });
      }
    });

    // 監聽播放器目前播到第幾首，自動更新 Mini Player 與主畫面的歌曲資訊 UI
    player.currentIndexStream.listen((index) {
      if (index != null && index < _myCurrentQueue.length && mounted) {
        setState(() {
          _currentSong = _myCurrentQueue[index];
        });
      }
    });
  }

  @override
  void dispose() {
    final player = audioHandler.player;
    WidgetsBinding.instance.removeObserver(this); // 註銷監聽器
    player.dispose();
    _searchController.dispose();
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
      // 1. 先檢查目前是否已經擁有權限
      status = await _audioQuery.permissionsStatus();

      // 2. 如果沒有權限，則發起請求
      if (!status) {
        status = await _audioQuery.permissionsRequest();
      }
    } catch (e) {
      debugPrint("權限請求出錯: $e");
      // 如果在桌面模擬器或特定環境報錯，可以選擇開啟此行當作保底：
      // status = true;
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
      await audioHandler.playlist.add(source);

      // 將 SongModel 轉換為 MediaItem 並更新至背景 queue
      final mediaItem = MediaItem(
        id: song.id.toString(),
        album: "本地音樂",
        title: song.title,
        artist: song.artist ?? "未知歌手",
        duration: Duration(milliseconds: song.duration ?? 0),
      );
      final currentQueue = audioHandler.queue.value;
      audioHandler.queue.add([...currentQueue, mediaItem]); // 確保系統能讀取到 queue

      // 3. 同步加到我們自己的 UI 歌單陣列裡
      setState(() {
        _myCurrentQueue.add(song);
      });

      await _saveQueueToStorage(); // 加入歌曲後立刻儲存

      // 4. 如果這是加入的第一首歌（目前播放器是停止或剛啟動狀態），就直接播放
      if (audioHandler.player.processingState == ProcessingState.idle ||
          audioHandler.playlist.length == 1) {
        setState(() {
          _currentSong = song;
        });
        audioHandler.player
            .seek(Duration.zero, index: audioHandler.playlist.length - 1)
            .catchError((e) => {debugPrint("播放失敗: $e")});
        audioHandler.player.play();
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

  // 將目前的播放佇列儲存到手機空間
  Future<void> _saveQueueToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    // 將 SongModel 列表轉換為 Map，再轉換為 JSON 字串清單
    List<String> jsonList = _myCurrentQueue
        .map((song) => jsonEncode(song.getMap))
        .toList();
    await prefs.setStringList('saved_music_queue', jsonList);
  }

  // 從手機空間還原上次沒播完的佇列
  Future<void> _loadQueueFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? jsonList = prefs.getStringList('saved_music_queue');

    if (jsonList != null && jsonList.isNotEmpty) {
      List<SongModel> loadedSongs = [];
      List<AudioSource> audioSources = [];

      for (String jsonStr in jsonList) {
        Map<dynamic, dynamic> songMap = jsonDecode(jsonStr);
        SongModel song = SongModel(songMap);
        loadedSongs.add(song);
        audioSources.add(AudioSource.uri(Uri.parse(song.uri!), tag: song));
      }

      final player = audioHandler.player;
      final playlist = audioHandler.playlist; // ★ 改用 audioHandler 內部的佇列

      await playlist.clear();
      await playlist.addAll(audioSources);

      List<MediaItem> mediaItems = loadedSongs
          .map(
            (song) => MediaItem(
              id: song.id.toString(),
              album: "本地音樂",
              title: song.title,
              artist: song.artist ?? "未知歌手",
              duration: Duration(milliseconds: song.duration ?? 0),
            ),
          )
          .toList();
      audioHandler.queue.add(mediaItems);

      setState(() {
        _myCurrentQueue.addAll(loadedSongs);
        // 預設將當前歌曲設為佇列的第一首，但先不自動播放
        if (_myCurrentQueue.isNotEmpty) {
          _currentSong = _myCurrentQueue.first;
        }
      });

      // 主動告訴播放器，將初始位置對準第 0 首（第一個音訊來源），但先不呼叫 .play()
      // 這樣當使用者在 Mini Player 按下播放鍵時，播放器才能順利找到音軌開始播放
      if (_myCurrentQueue.isNotEmpty) {
        await player.setAudioSource(playlist, initialIndex: 0, preload: false);
      }
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
              : Column(
                  children: [
                    // 中英日文搜尋框
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.black),
                        decoration: InputDecoration(
                          hintText: "搜尋歌名、歌手 (Search, 検索)...",
                          hintStyle: const TextStyle(color: Colors.grey),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.blue,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.clear,
                                    color: Colors.grey,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = "";
                                    });
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: Colors.grey[100],
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30.0),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                        },
                      ),
                    ),

                    // 音樂列表區域
                    Expanded(
                      child: FutureBuilder<List<SongModel>>(
                        future: _audioQuery.querySongs(
                          sortType: null,
                          orderType: OrderType.ASC_OR_SMALLER,
                          uriType: UriType.EXTERNAL,
                          ignoreCase: true,
                        ),
                        builder: (context, item) {
                          if (item.connectionState == ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (item.data == null || item.data!.isEmpty) {
                            return const Center(child: Text("未找到本地音樂檔案"));
                          }

                          // 記錄原始獲取的全域歌單
                          _allSongsList = item.data!;

                          // 進行即時中英日文關鍵字過濾
                          List<SongModel> filteredSongs = _allSongsList.where((
                            song,
                          ) {
                            final query = _searchQuery.toLowerCase().trim();
                            if (query.isEmpty) return true;

                            final title = (song.title).toLowerCase();
                            final artist = (song.artist ?? "").toLowerCase();

                            return title.contains(query) ||
                                artist.contains(query);
                          }).toList();

                          if (filteredSongs.isEmpty) {
                            return const Center(
                              child: Text(
                                "找不到相符的歌曲",
                                style: TextStyle(color: Colors.grey),
                              ),
                            );
                          }

                          return ListView.builder(
                            // 動態預留底部間距，有播歌時塞 100 像素阻擋 Mini Player，沒播歌時回歸 16 像素
                            padding: EdgeInsets.only(
                              bottom: _currentSong != null ? 100.0 : 16.0,
                            ),
                            itemCount: filteredSongs.length,
                            itemBuilder: (context, index) {
                              SongModel song = filteredSongs[index];
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
                                  errorBuilder: (context, exception, giddig) {
                                    return const Icon(
                                      Icons.music_note,
                                      size: 40,
                                    );
                                  },
                                ),
                                trailing: const Icon(Icons.play_arrow),
                                // 點擊直接將當前這一首加進自訂的播放佇列
                                onTap: () => _playSong(song),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
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
              errorBuilder: (context, exception, giddig) {
                return const Icon(
                  Icons.music_note,
                  color: Colors.white,
                  size: 30,
                );
              },
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
              stream: audioHandler.player.playerStateStream,
              builder: (context, snapshot) {
                final playerState = snapshot.data;
                final playing = playerState?.playing ?? false;

                return Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => audioHandler.player.seekToPrevious(),
                    ),
                    // 1. 播放 / 暫停 控制鈕
                    IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      color: Colors.white,
                      onPressed: () {
                        if (playing) {
                          audioHandler.player.pause(); // 執行暫停：停在當前秒數
                        } else {
                          audioHandler.player.play(); // 執行續播：從剛才地方繼續
                        }
                      },
                    ),
                    // 2. 停止 控制鈕
                    IconButton(
                      icon: const Icon(Icons.stop),
                      color: Colors.redAccent,
                      onPressed: () async {
                        await audioHandler.player.stop(); // 執行停止：關閉音訊並重設進度
                        setState(() {
                          _currentSong = null; // 關閉底部的 Mini Player 介面
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => audioHandler.player.seekToNext(),
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
                            return StatefulBuilder(
                              builder:
                                  (
                                    BuildContext context,
                                    StateSetter sheetState,
                                  ) {
                                    return Container(
                                      padding: const EdgeInsets.all(16),
                                      height:
                                          MediaQuery.of(context).size.height *
                                          0.6, // 60% screen height
                                      child: _buildPlaylistViewer(
                                        _myCurrentQueue,
                                        sheetState,
                                      ),
                                    );
                                  },
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

  Widget _buildPlaylistViewer(
    List<SongModel> playlistSongs,
    StateSetter sheetState,
  ) {
    return StreamBuilder<int?>(
      stream: audioHandler.player.currentIndexStream,
      builder: (context, snapshot) {
        final currentIndex = snapshot.data;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "播放隊列",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (playlistSongs.isNotEmpty)
                  TextButton.icon(
                    onPressed: () async {
                      await audioHandler.playlist.clear(); // 清空播放器佇列
                      audioHandler.player.stop(); // 停止播放

                      // 同步刷新主畫面（Mini Player 會消失）
                      setState(() {
                        _myCurrentQueue.clear();
                        _currentSong = null;
                      });

                      await _saveQueueToStorage(); // 清空後把手機裡的記憶也清空

                      audioHandler.queue.add([]);

                      // 同步刷新彈出視窗內部（列表立刻變空，不需點擊兩次）
                      sheetState(() {});
                    },
                    icon: const Icon(Icons.delete_sweep, color: Colors.red),
                    label: const Text(
                      "清空全部",
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
            const Divider(),
            Expanded(
              child: playlistSongs.isEmpty
                  ? const Center(
                      child: Text(
                        "播放佇列是空的",
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap:
                          true, // Useful if you place this inside a ModalBottomSheet or Column
                      physics: const ClampingScrollPhysics(),
                      itemCount: playlistSongs.length,
                      itemBuilder: (context, index) {
                        final song = playlistSongs[index];
                        final isPlaying = currentIndex == index;

                        // 使用 Dismissible 實作側滑刪除
                        return Dismissible(
                          key: Key(
                            song.id.toString() + index.toString(),
                          ), // 確保 Key 唯一
                          direction: DismissDirection.endToStart, // 只能從右往左滑
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(
                              Icons.delete,
                              color: Colors.white,
                            ),
                          ),
                          onDismissed: (direction) async {
                            final messenger = ScaffoldMessenger.of(context);

                            // 1. 從 just_audio 播放器佇列中移除
                            await audioHandler.playlist.removeAt(index);

                            // 獲取當前鎖定畫面的舊佇列，複製一份並移除該歌曲，這就是 updatedQueue
                            final List<MediaItem> updatedQueue = List.from(
                              audioHandler.queue.value,
                            );
                            if (index < updatedQueue.length) {
                              updatedQueue.removeAt(index); // 移除背景系統中的同一首歌
                            }
                            audioHandler.queue.add(
                              updatedQueue,
                            ); // 將更新後的佇列送回給鎖定畫面系統

                            // 2. 從我們的 UI 陣列中移除
                            setState(() {
                              playlistSongs.removeAt(index);
                              // 如果刪除的是當前播放的歌，且佇列空了，清除當前歌曲狀態
                              if (playlistSongs.isEmpty) {
                                _currentSong = null;
                              }
                            });

                            await _saveQueueToStorage(); // 刪除歌曲後更新記憶

                            messenger.showSnackBar(
                              SnackBar(
                                content: Text("已移出佇列: ${song.title}"),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                          child: ListTile(
                            leading: QueryArtworkWidget(
                              id: song.id,
                              type: ArtworkType.AUDIO,
                              errorBuilder: (context, exception, giddig) {
                                return const Icon(
                                  Icons.music_note,
                                  color: Colors.blue,
                                );
                              },
                            ),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isPlaying
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isPlaying ? Colors.blue : Colors.black,
                              ),
                            ),
                            subtitle: Text(song.artist ?? "未知藝術家"),
                            trailing: isPlaying
                                ? const Icon(
                                    Icons.volume_up,
                                    color: Colors.blue,
                                  )
                                : const Icon(
                                    Icons.dehaze,
                                  ), // Visual cue for list reordering/queue
                            onTap: () async {
                              // Jump directly to the clicked song in the active playlist
                              await audioHandler.player
                                  .seek(Duration.zero, index: index)
                                  .catchError((e) => {debugPrint("播放失敗: $e")});
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // 將播放器本體搬進 Handler 內部，作為唯一的真相來源
  final AudioPlayer _player = AudioPlayer();

  // 將播放佇列管理本體也搬進背景服務中
  final ConcatenatingAudioSource _playlist = ConcatenatingAudioSource(
    children: [],
  );

  // 提供外部介面讓 State 能夠拿得到播放器實例
  AudioPlayer get player => _player;

  // 提供對外的公開 Getter，讓主畫面的 initState 能夠存取到它
  ConcatenatingAudioSource get playlist => _playlist;

  MyAudioHandler() {
    // 監聽播放器的各種事件，並即時回傳給 Android 鎖定畫面系統
    _player.playbackEventStream.listen((event) {
      playbackState.add(_transformEvent(event));
    });

    // 監聽當前播放歌曲的索引，用來更新通知欄上的歌名、歌手與封面
    _player.currentIndexStream.listen((index) {
      if (index != null &&
          queue.value.isNotEmpty &&
          index < queue.value.length) {
        // A. 拿到目前正在播的那首 MediaItem 歌曲
        final currentMediaItem = queue.value[index];

        // B. 強制發送給系統的 mediaItem 管道（這能解鎖 Android 下拉通知欄的按鈕功能）
        mediaItem.add(currentMediaItem);
      }
    });
  }

  // 將 just_audio 的事件包裝轉化為系統通知欄能看懂的格式
  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
    );
  }

  // 實作系統鎖定畫面的 播放/暫停/停止 控制
  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    // 發送終止狀態，通知欄會優雅消失或重置
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    }
  }

  // 外部可以透過這個方法，隨時更新鎖定畫面的播放狀態
  void updateState(
    bool isPlaying,
    Duration position,
    Duration buffered,
    Duration total,
  ) {
    playbackState.add(
      playbackState.value.copyWith(
        playing: isPlaying,
        controls: [
          MediaControl.skipToPrevious,
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        updatePosition: position,
        bufferedPosition: buffered,
        // 依據播放器狀態調整系統狀態
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  // 外部點擊新歌曲時，用來更新鎖定畫面上的歌名、歌手與封面
  void updateMetadata(
    String title,
    String artist,
    String? artworkUri,
    Duration duration,
  ) {
    mediaItem.add(
      MediaItem(
        id: title,
        album: "本地音樂",
        title: title,
        artist: artist,
        duration: duration,
        artUri: artworkUri != null ? Uri.parse(artworkUri) : null,
      ),
    );
  }
}
