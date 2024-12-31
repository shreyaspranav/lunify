import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lunify/image_util.dart';
import 'package:lunify/models/album_model.dart';
import 'package:lunify/models/song_model.dart';
import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:messagepack/messagepack.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class AudioPlaylist {
  String playlistName;
  List<SongModel> songs = [];

  AudioPlaylist({
    required this.playlistName
  });
}

// This class is the heart of the music functionality.
// This class should be able to:
//  - Scan for music files and have a record of it. (also cache it and load from the cache if required)
//  - Deal with playlists
//    - There is a playlist called the "current playlist", from where the music should be played.
//    - During the initial stages, the entire library would be read and added to the current playlist
//  - Play/Pause/Next/Prev/Shuffle/Loop playlists
class AudioServiceProvider extends ChangeNotifier {
  // List that contatins the URLs of the folders where the audio files are located.
  // Maybe not cross platform friendly?
  List<String> _audioLibraryUrls = <String>["/storage/emulated/0/Music"];
  final String _audioCacheFileName = "audio_cache.bin";

  // This audio player object is owned by this class
  final _audioPlayer = AudioPlayer();
  
  // List of playlists
  List<AudioPlaylist> _playlists = [];

  AudioPlaylist _currentPlaylist = AudioPlaylist(playlistName: "Current Playlist");
  AudioPlaylist _library = AudioPlaylist(playlistName: "Library");  // Contains all the audio files that the device has to offer.

  // Convinient list of albums. This will be filled when deserializing from cache or loading from disk.
  List<AlbumModel> _albums = [];

  bool _audioMetadataLoaded = false;
  bool _audioMetadataLoadingAsync = false;

  // These are used to switch to the player tab when a song is clicked.
  late TabController _currentTabs;
  late int _playerTabIndex;
  
  // The current song playing: initially it contains empty values.
  SongModel _currentSongPlaying = SongModel(
    songUrl: "", 
    songName: "", 
    songAlbum: "", 
    songArtist: "", 
    coverPicture: null,
    coverPictureRaw: [],
    trackNumber: 0
  );

  int _currentSongPlayingIndexInCurrentPlaylist = 0;

  // The progress of loading the metadata of the songs. 0 represents 0% done, 1.0 repesents 100% done
  double _audioMetadataLoadingProgress = 0.0; 

  AudioServiceProvider(List<String> additionalAudioLibraryUrls) {
    // Add the additional URLs
    for (String url in additionalAudioLibraryUrls) {
      _audioLibraryUrls.add(url);
    }
  }

  SongModel getCurrentSongPlaying()             { return _currentSongPlaying; }
  AudioPlaylist getCurrentPlaylist()            { return _currentPlaylist; }

  void setCurrentSongPlaying(SongModel model)   { _currentSongPlaying = model; notifyListeners(); }

  Future<String> getCacheEntryPath() async {
    final Directory? directory = await getExternalStorageDirectory();
    final String cacheFilePath = "${directory!.path}/$_audioCacheFileName";

    return cacheFilePath;
  }

  Future<bool> loadAudioMetadata(void Function(double)onProgressCallback, [bool forceReload = false]) async {
    // This is what this should do:
    //  During Startup, check if the cache exists
    //   If exists, get the last modified dates of the library directories
    //   If the last modified dates match with that of the existing directories, load from cache.
    //   If not, reload only that directory and rebuild cache.  

    if(_audioMetadataLoaded) return true;

    if(_audioMetadataLoadingAsync) return false;
     _audioMetadataLoadingAsync = true;

    bool returnValue = false;

    // Check if the cache exists:
    File audioCacheFile = File(await getCacheEntryPath());
    bool cacheFileExists = await audioCacheFile.exists();

    if(!cacheFileExists) {
      returnValue = await loadAudioMetadataFromDisk(onProgressCallback, null);
    } 
    else {
      returnValue = true; // WTF??.

      File cacheFile = File(await getCacheEntryPath());
      Uint8List cacheBytes = await cacheFile.readAsBytes();

      Unpacker unpacker = Unpacker(cacheBytes);

      int? libUrlCount = unpacker.unpackInt();
      print("Audio Library URL Count: $libUrlCount");

      List<String> loadFromCacheEntries = [];   // URL's that require loading from the cache.
      List<String> loadFromDiskEntries  = [];   // URL's that require loading from the disk.

      // Get the last modified time for the audio library URLs
      for(int i = 0; i < libUrlCount!; i++) {
        String? audioLibUrl = unpacker.unpackString();
        String? lastModified = unpacker.unpackString();
        DateTime lastModifiedTimeStamp = DateTime.parse(lastModified!);

        if(!_audioLibraryUrls.contains(audioLibUrl)) continue; // Skip entries that is not present in the current audio library URLs

        print("Path: $audioLibUrl Last Modified: $lastModifiedTimeStamp");

        // Get the last modified time of the url entries that are present in _audioLibraryUrls
        Directory d = Directory(audioLibUrl!);
        FileStat fileStat = await d.stat();

        if(fileStat.modified != lastModifiedTimeStamp) {
          loadFromDiskEntries.add(audioLibUrl);
        } else {
          loadFromCacheEntries.add(audioLibUrl);
        }
      }

      await deserializeAudioLibrary(unpacker, loadFromCacheEntries);
      await loadAudioMetadataFromDisk(onProgressCallback, loadFromDiskEntries);
      onProgressCallback(1.0);
    }
    serializeAudioLibrary();
    
    _audioMetadataLoaded = true;

    _audioMetadataLoadingAsync = false;
    return returnValue;
  }

  Future<bool> loadAudioMetadataFromDisk(void Function(double)onProgressCallback, List<String>? urlEntries) async {
    var status = await Permission.storage.status;
    if (status.isDenied) {
      var result = await Permission.storage.request();
      if(result.isDenied) {
        return false;
      }
    } 
    
    print("Storage Permission Accepted!");
      
    int totalFiles = 0;
    int fileCount = 0;
      
    List<List<FileSystemEntity>> fileEachAudioUrl = [];
      
    // Load from _audioLibraryUrls if urlEntries is empty, else load from urlEntries.
    for(String url in urlEntries ?? _audioLibraryUrls) {
      Directory urlDirectory = Directory(url);
      List<FileSystemEntity> files = urlDirectory.listSync(recursive: true);
      fileEachAudioUrl.add(files);
      totalFiles += files.length;
    }
      
    for(List<FileSystemEntity> files in fileEachAudioUrl) {
      for(var file in files) {
        print("--------------------------------------------------------------------------------------------------");
        if(file is File && (file.path.endsWith('mp3') || file.path.endsWith('flac'))) {
          var songMetadata = await AudioMetadata.extract(file);
          if(songMetadata != null) {
            Image? imageToAdd = null;
            if(ImageUtil.isValidImage(songMetadata.coverData ?? [])) {
              imageToAdd = Image.memory(Uint8List.fromList(songMetadata.coverData ?? []));
            }
            _library.songs.add(
              SongModel(
                songUrl: file.path,
                songName: songMetadata.trackName ?? "Unknown name", 
                songAlbum: songMetadata.album ?? "Unknown Album", 
                trackNumber: decodeTrackNumber(songMetadata.trackNo ?? "0"),
                songArtist: songMetadata.firstArtists  ?? "Unknown artist", 
                coverPicture: imageToAdd,
                coverPictureRaw: songMetadata.coverData
              )
            );

            if(_albums.any((album) => album.name == songMetadata.album)) {
              AlbumModel? album = _albums.firstWhere(
                (album) => album.name == songMetadata.album,
              );
              album.trackCount++;
              album.tracks.add(_library.songs[_library.songs.length - 1]);
            }
            else {
              _albums.add(
                AlbumModel(
                  name: songMetadata.album ?? "Unknown Album", 
                  artist: songMetadata.firstArtists ?? "Unknown artist", 
                  trackCount: 1,
                  coverImage: imageToAdd,
                )
              );
              _albums[_albums.length - 1].tracks.add(_library.songs[_library.songs.length - 1]);
            }
          }
        }
      
        fileCount++;
        onProgressCallback(fileCount / totalFiles);
        _audioMetadataLoadingProgress = fileCount / totalFiles;
      }
    }

    // Sort all the songs in the albums according to the track number.
    for(AlbumModel album in _albums) {
      album.tracks.sort((a, b) => a.trackNumber.compareTo(b.trackNumber));
    }
      
    // TEMP
    // _currentPlaylist = _library;
    List<AudioSource> _currentPlaylistAudioSources = [];
    for(SongModel song in _currentPlaylist.songs) {
      _currentPlaylistAudioSources.add(AudioSource.uri(Uri.parse(song.songUrl)));
    }

    // Create the playlist in the "audio player"
    final playlist = ConcatenatingAudioSource(
      useLazyPreparation: false,
      shuffleOrder: null,
      children: _currentPlaylistAudioSources
    );
      
    _audioPlayer.setAudioSource(playlist, initialIndex: 0, initialPosition: Duration.zero);
    return true;
  }

  Future<void> serializeAudioLibrary() async {
    Packer p = Packer();

    // Pack the last modified time.
    p.packInt(_audioLibraryUrls.length);
    for(String url in _audioLibraryUrls) {
      Directory d = Directory(url);
      final FileStat stats = await d.stat();
      p.packString(url);
      p.packString(stats.modified.toIso8601String());
    }

    p.packInt(_library.songs.length);
    for(SongModel audioFile in _library.songs) {
      p.packString(audioFile.songUrl);
      p.packString(audioFile.songName);
      p.packString(audioFile.songAlbum);
      p.packInt(audioFile.trackNumber);
      p.packString(audioFile.songArtist);
      p.packBinary(audioFile.coverPictureRaw);
    }
    
    File cacheFile = File(await getCacheEntryPath());
    await cacheFile.writeAsBytes(p.takeBytes());
  }

  // urlEntries refers to the list of URL's from where the audio files are that needs to be reloaded from cache.
  Future<void> deserializeAudioLibrary(Unpacker unpacker, List<String> urlEntries) async { 
    // This function is called knowing that the cache file exists.

    int? songCount = unpacker.unpackInt();

    for(int i = 0; i < songCount!; i++) {
      
      String? sUrl = unpacker.unpackString();
      String? sName = unpacker.unpackString();
      String? sAlbum = unpacker.unpackString();
      int? sTrackNumber = unpacker.unpackInt();
      String? sArtist = unpacker.unpackString();
      
      List<int>? sCoverPic = unpacker.unpackBinary();

      SongModel model = SongModel(
        songUrl: sUrl ?? "", 
        songName: sName ?? "Unknown Song", 
        songAlbum: sAlbum ?? "Unknown Album", 
        trackNumber: sTrackNumber ?? 0,
        songArtist: sArtist ?? "Unknown Artist", 
        coverPicture: sCoverPic.isEmpty ? null : Image.memory(Uint8List.fromList(sCoverPic)), 
        coverPictureRaw: sCoverPic,
      );

      // Check if parent path of sUrl is present in urlEntries
      // Add to the library only if the parent path is present in urlEntries
      String parentPath = Directory(sUrl!).parent.path;
      bool within = false;
      for(String parentPath in urlEntries) {
        String normalizedParent = p.normalize(p.absolute(parentPath));
        String normalizedChild = p.normalize(p.absolute(sUrl));

        if(p.isWithin(normalizedParent, normalizedChild)) {
          within = true;
          break;
        }
      }

      if(within) {
        _library.songs.add(model);

        if(_albums.any((album) => album.name == sAlbum)) {
          AlbumModel? album = _albums.firstWhere(
            (album) => album.name == sAlbum,
          );
          album.trackCount++;
          album.tracks.add(_library.songs[_library.songs.length - 1]);
        }
        else {
          _albums.add(
            AlbumModel(
              name: sAlbum ?? "Unknown Album", 
              artist: sArtist ?? "Unknown artist", 
              trackCount: 1,
              coverImage: sCoverPic.isEmpty ? null : Image.memory(Uint8List.fromList(sCoverPic))
            )
          );
          _albums[_albums.length - 1].tracks.add(_library.songs[_library.songs.length - 1]);
        }
      }
    }

    for(AlbumModel album in _albums) {
      album.tracks.sort((a, b) => a.trackNumber.compareTo(b.trackNumber));
    }

    print("Read $songCount items from the cache.");
  }

  // This method is used to decode track numbers of various types:
  int decodeTrackNumber(String trackNumber) {
    // Split the track number by '/' to handle formats like '5/12'
    List<String> parts = trackNumber.split('/');

    try {
      // Parse the first part as an integer
      return int.parse(parts[0].trim());
    } catch (e) {
      // Return 0 or an appropriate fallback if parsing fails
      print("Error decoding track number: $e");
      return 0;
    }
  }


  double getAudioMetadataLoadingProgress() { return _audioMetadataLoadingProgress; }
  AudioPlaylist getAudioLibrary() { return _library; }
  List<AlbumModel> getAlbums() { return _albums; }

  void addAudioLibraryUrl(String url) {
    _audioLibraryUrls.add(url);
  }

  bool isMetadataLoaded() { 
    return _audioMetadataLoaded; 
  }

  void setLoadMetadataFlag() { 
    _audioMetadataLoaded = false; 
  }

  void setTabController(TabController controller) {
    _currentTabs = controller;
  }

  void setPlayerTabIndex(int index) {
    _playerTabIndex = index;
  }

  AudioPlayer getAudioPlayer() {
    return _audioPlayer;
  }

  void setPlaybackSpeed(double speedFactor) {
    _audioPlayer.setSpeed(speedFactor);
  }

  void setPlaybackPitch(double pitchFactor) {
    _audioPlayer.setPitch(pitchFactor);
  }

  void songClickedCallback(int indexInCurrentPlaylist) {
    _currentSongPlayingIndexInCurrentPlaylist = indexInCurrentPlaylist;
    print("Song: $_currentSongPlayingIndexInCurrentPlaylist");
    _currentTabs.animateTo(_playerTabIndex);
    _currentSongPlaying = _currentPlaylist.songs[indexInCurrentPlaylist];
    _audioPlayer.seek(Duration.zero, index: _currentSongPlayingIndexInCurrentPlaylist);
    _audioPlayer.play();
  }

  void previousSong() {
    if (_currentSongPlayingIndexInCurrentPlaylist > -1) {
      _audioPlayer.seekToPrevious();
      _currentSongPlaying = _currentPlaylist.songs[
        _currentSongPlayingIndexInCurrentPlaylist == 0 ? 
        0 :
        --_currentSongPlayingIndexInCurrentPlaylist 
      ];
    }
  }

  void nextSong() {    
    if (_currentSongPlayingIndexInCurrentPlaylist < _currentPlaylist.songs.length) {
      _audioPlayer.seekToNext();
      _currentSongPlaying = _currentPlaylist.songs[
        _currentSongPlayingIndexInCurrentPlaylist == _currentPlaylist.songs.length - 1 ? 
        _currentPlaylist.songs.length - 1 :
        ++_currentSongPlayingIndexInCurrentPlaylist
      ];
    }
  }
}